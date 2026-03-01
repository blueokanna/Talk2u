use super::data_models::ChatStreamEvent;
use super::error_handler::{ChatError, RetryHandler};
use flutter_rust_bridge::frb;
use futures::StreamExt;

/// 流式请求的超时配置（按模型角色分级）
struct StreamTimeoutConfig {
    connect_timeout_secs: u64,
    read_timeout_secs: u64,
    tcp_keepalive_secs: u64,
}

impl StreamTimeoutConfig {
    /// 根据模型选择合适的超时配置
    /// 推理模型（glm-4-air）需要更长的首 token 等待时间
    /// 长上下文模型（glm-4-long）处理大量输入需要更多时间
    fn for_model(model: &str) -> Self {
        match model {
            "glm-4-air" => Self {
                connect_timeout_secs: 30,
                read_timeout_secs: 300,   // 推理模型思考时间长，5分钟
                tcp_keepalive_secs: 20,
            },
            "glm-4-long" => Self {
                connect_timeout_secs: 30,
                read_timeout_secs: 300,   // 长上下文处理需要更多时间
                tcp_keepalive_secs: 20,
            },
            _ => Self {
                connect_timeout_secs: 30,
                read_timeout_secs: 180,   // 标准对话模型 3 分钟
                tcp_keepalive_secs: 20,
            },
        }
    }
}

#[frb(opaque)]
pub struct StreamingHandler {}

impl StreamingHandler {
    /// 流式聊天请求，带完善的中断恢复机制
    ///
    /// 核心改进（解决「AI响应中断」）：
    /// 1. 按模型分级超时：推理模型(5min) > 长上下文(5min) > 对话(3min)
    /// 2. 流中断时保留已收到的内容（partial recovery）
    /// 3. 连接级重试（3次）+ 数据块超时容忍
    /// 4. TCP keepalive防止NAT/代理断开空闲连接
    /// 5. 更细粒度的错误分类，便于上层决策
    pub async fn stream_chat(
        url: &str,
        token: &str,
        request_body: serde_json::Value,
        on_event: impl Fn(ChatStreamEvent),
    ) -> Result<(String, String), ChatError> {
        let retry_handler = RetryHandler::new(3, 1000);  // 重试间隔从800ms提升到1000ms
        let url_owned = url.to_string();
        let token_owned = token.to_string();
        let body_clone = request_body.clone();

        // 记录请求模型和 token 预算，便于调试
        let model_name = request_body.get("model")
            .and_then(|v| v.as_str())
            .unwrap_or("unknown");
        let max_tokens = request_body.get("max_tokens")
            .and_then(|v| v.as_u64())
            .unwrap_or(0);

        // 根据模型选择超时配置
        let timeout_config = StreamTimeoutConfig::for_model(model_name);

        let response = retry_handler
            .execute_with_retry(|| {
                let u = url_owned.clone();
                let t = token_owned.clone();
                let b = body_clone.clone();
                let connect_timeout = timeout_config.connect_timeout_secs;
                let read_timeout = timeout_config.read_timeout_secs;
                let keepalive = timeout_config.tcp_keepalive_secs;
                async move {
                    let client = reqwest::Client::builder()
                        // 不设置 timeout（总超时）— 对 SSE 流式响应，总超时会在
                        // 响应还在正常传输时误杀连接。
                        .connect_timeout(std::time::Duration::from_secs(connect_timeout))
                        .read_timeout(std::time::Duration::from_secs(read_timeout))
                        // 启用 TCP keepalive，防止长时间空闲连接被中间代理/NAT 断开
                        .tcp_keepalive(std::time::Duration::from_secs(keepalive))
                        // 启用连接池保持，减少重复握手开销
                        .pool_idle_timeout(std::time::Duration::from_secs(90))
                        .pool_max_idle_per_host(2)
                        .build()
                        .map_err(|e| ChatError::NetworkError {
                            message: e.to_string(),
                        })?;
                    let resp = client
                        .post(&u)
                        .header("Authorization", format!("Bearer {}", &t))
                        .header("Content-Type", "application/json")
                        // 显式请求 SSE 流
                        .header("Accept", "text/event-stream")
                        .json(&b)
                        .send()
                        .await
                        .map_err(|e| {
                            // 区分超时和其他网络错误，给用户更有意义的提示
                            if e.is_timeout() {
                                ChatError::NetworkError {
                                    message: format!("连接超时，请检查网络后重试: {}", e),
                                }
                            } else if e.is_connect() {
                                ChatError::NetworkError {
                                    message: format!("无法连接到 AI 服务器，请检查网络: {}", e),
                                }
                            } else {
                                ChatError::NetworkError {
                                    message: format!("网络请求失败: {}", e),
                                }
                            }
                        })?;

                    let status = resp.status();
                    if !status.is_success() {
                        let status_code = status.as_u16();
                        // 先尝试读取 retry-after 头（429 专用）
                        let retry_after_header = resp
                            .headers()
                            .get("retry-after")
                            .and_then(|v| v.to_str().ok())
                            .and_then(|v| v.parse::<u64>().ok());

                        let body_text = resp.text().await.unwrap_or_default();

                        // 使用 GLM 错误码精确分类
                        // 参考: https://docs.bigmodel.cn/cn/api/api-code
                        let mut err = ChatError::from_glm_response(status_code, &body_text);

                        // 如果 HTTP 头中有 retry-after，优先使用头部指定的等待时间
                        if let Some(retry_secs) = retry_after_header {
                            if matches!(err, ChatError::RateLimitError { .. }) {
                                err = ChatError::RateLimitError {
                                    retry_after_secs: retry_secs,
                                };
                            }
                        }

                        return Err(err);
                    }

                    Ok(resp)
                }
            })
            .await
            .map_err(|e| {
                let err_msg = format!("[{}] 请求失败: {}", model_name, e);
                on_event(ChatStreamEvent::Error(err_msg));
                e
            })?;

        let mut stream = response.bytes_stream();
        let mut buffer = String::new();
        let mut full_content = String::new();
        let mut full_thinking = String::new();
        let mut raw_response_preview = String::new();
        let mut chunk_count: u32 = 0;

        while let Some(chunk_result) = stream.next().await {
            let chunk = match chunk_result {
                Ok(bytes) => bytes,
                Err(e) => {
                    // ═══ 流中断恢复机制 ═══
                    // 如果已经收到了部分内容，不立即报错，尝试保留已有内容
                    let has_partial_content = !full_content.is_empty() || !full_thinking.is_empty();

                    if has_partial_content {
                        // 已收到部分内容 → 视为「不完整但可用」的响应
                        // 不再抛出错误，让上层 request_with_fallback 决定是否使用
                        let warn_msg = format!(
                            "[{}] 数据流在传输中断开（已收到{}字），保留已接收内容",
                            model_name,
                            full_content.len() + full_thinking.len()
                        );
                        on_event(ChatStreamEvent::Error(warn_msg));
                        // 直接返回已收到的内容（partial recovery）
                        return Ok((full_content, full_thinking));
                    }

                    // 没有收到任何内容 → 才报真正的错误
                    let err_msg = if e.is_timeout() {
                        format!("[{}] 读取超时（服务器长时间未响应），请重试", model_name)
                    } else if e.is_connect() {
                        format!("[{}] 连接中断，请检查网络后重试", model_name)
                    } else {
                        format!("[{}] 数据流中断: {}", model_name, e)
                    };
                    let err = ChatError::StreamError {
                        message: err_msg.clone(),
                    };
                    on_event(ChatStreamEvent::Error(err_msg));
                    return Err(err);
                }
            };

            let text = String::from_utf8_lossy(&chunk);
            chunk_count += 1;

            if raw_response_preview.len() < 2000 {
                raw_response_preview.push_str(&text);
            }

            buffer.push_str(&text);

            while let Some(newline_pos) = buffer.find('\n') {
                let line = buffer[..newline_pos].trim_end_matches('\r').to_string();
                buffer = buffer[newline_pos + 1..].to_string();

                if line.is_empty() {
                    continue;
                }

                if let Some(event) = Self::parse_sse_line(&line) {
                    match &event {
                        ChatStreamEvent::ContentDelta(delta) => {
                            full_content.push_str(delta);
                            on_event(event);
                        }
                        ChatStreamEvent::ThinkingDelta(delta) => {
                            full_thinking.push_str(delta);
                            on_event(event);
                        }
                        ChatStreamEvent::Done => {
                            // Don't forward Done here; caller will send it after saving
                        }
                        ChatStreamEvent::Error(_) => {
                            on_event(event);
                        }
                    }
                }
            }
        }

        if !buffer.trim().is_empty() {
            for line in buffer.lines() {
                let line = line.trim();
                if line.is_empty() {
                    continue;
                }
                if let Some(event) = Self::parse_sse_line(line) {
                    match &event {
                        ChatStreamEvent::ContentDelta(delta) => {
                            full_content.push_str(delta);
                            on_event(event);
                        }
                        ChatStreamEvent::ThinkingDelta(delta) => {
                            full_thinking.push_str(delta);
                            on_event(event);
                        }
                        ChatStreamEvent::Done => {
                            // Don't forward Done here; caller will send it after saving
                        }
                        ChatStreamEvent::Error(_) => {
                            on_event(event);
                        }
                    }
                }
            }
        }

        if full_content.is_empty() && full_thinking.is_empty() && !raw_response_preview.is_empty() {
            let debug_msg = format!(
                "[{}] API 返回了数据但未包含有效内容（共{}个数据块，max_tokens={}）。\n可能原因：1)模型参数格式不被支持 2)内容安全过滤 3)Token预算不足。\n响应预览: {}",
                model_name,
                chunk_count,
                max_tokens,
                raw_response_preview.chars().take(500).collect::<String>()
            );
            on_event(ChatStreamEvent::Error(debug_msg));
        }

        // 流正常结束但没有任何数据块（连接可能被静默断开）
        if chunk_count == 0 {
            let debug_msg = format!(
                "[{}] 未收到任何数据（服务器未返回SSE流）。可能原因：1)网络中断 2)API Key无效 3)服务器过载。请检查网络和API Key后重试。",
                model_name
            );
            on_event(ChatStreamEvent::Error(debug_msg));
        }

        Ok((full_content, full_thinking))
    }

    pub fn parse_sse_line(line: &str) -> Option<ChatStreamEvent> {
        let trimmed = line.trim();

        // 处理 SSE event 类型行（忽略）
        if trimmed.starts_with("event:") || trimmed.starts_with(": ") || trimmed.starts_with(":") {
            return None;
        }

        if trimmed.starts_with("data: ") || trimmed.starts_with("data:") {
            let data = if let Some(stripped) = trimmed.strip_prefix("data: ") {
                stripped
            } else if let Some(stripped) = trimmed.strip_prefix("data:") {
                stripped
            } else {
                return None;
            };

            let data = data.trim();

            if data == "[DONE]" {
                return Some(ChatStreamEvent::Done);
            }

            let json: serde_json::Value = match serde_json::from_str(data) {
                Ok(v) => v,
                Err(_) => return None,
            };

            if let Some(error) = json.get("error") {
                let msg = error
                    .get("message")
                    .and_then(|v| v.as_str())
                    .unwrap_or("Unknown API error");
                return Some(ChatStreamEvent::Error(msg.to_string()));
            }

            return Self::extract_delta(&json);
        }

        if trimmed.starts_with('{') {
            if let Ok(json) = serde_json::from_str::<serde_json::Value>(trimmed) {
                if let Some(error) = json.get("error") {
                    let msg = error
                        .get("message")
                        .and_then(|v| v.as_str())
                        .unwrap_or("Unknown API error");
                    return Some(ChatStreamEvent::Error(msg.to_string()));
                }
                if json.get("choices").is_some() {
                    return Self::extract_delta(&json);
                }
            }
        }

        None
    }

    pub fn extract_delta(json: &serde_json::Value) -> Option<ChatStreamEvent> {
        if let Some(error) = json.get("error") {
            let msg = error
                .get("message")
                .and_then(|v| v.as_str())
                .unwrap_or("Unknown API error");
            return Some(ChatStreamEvent::Error(msg.to_string()));
        }

        let choice = json.get("choices").and_then(|c| c.get(0))?;

        let delta = choice.get("delta");

        if let Some(delta) = delta {
            if let Some(reasoning) = delta.get("reasoning_content").and_then(|v| v.as_str()) {
                if !reasoning.is_empty() {
                    return Some(ChatStreamEvent::ThinkingDelta(reasoning.to_string()));
                }
            }

            if let Some(content_val) = delta.get("content") {
                if let Some(content) = content_val.as_str() {
                    if !content.is_empty() {
                        return Some(ChatStreamEvent::ContentDelta(content.to_string()));
                    }
                }
            }

            if let Some(text_val) = delta.get("text") {
                if let Some(text) = text_val.as_str() {
                    if !text.is_empty() {
                        return Some(ChatStreamEvent::ContentDelta(text.to_string()));
                    }
                }
            }
        }

        if let Some(message) = choice.get("message") {
            if let Some(content) = message.get("content").and_then(|v| v.as_str()) {
                if !content.is_empty() {
                    return Some(ChatStreamEvent::ContentDelta(content.to_string()));
                }
            }
        }

        if let Some(reason) = choice.get("finish_reason") {
            if let Some(reason_str) = reason.as_str() {
                match reason_str {
                    "stop" | "length" => return Some(ChatStreamEvent::Done),
                    "sensitive" => {
                        return Some(ChatStreamEvent::Error(
                            "内容触发了安全审核，请修改后重试。".to_string(),
                        ));
                    }
                    _ => {}
                }
            }
        }

        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_content_delta() {
        let line = r#"data: {"id":"xxx","choices":[{"index":0,"delta":{"role":"assistant","content":"你"},"finish_reason":null}]}"#;
        let event = StreamingHandler::parse_sse_line(line);
        match event {
            Some(ChatStreamEvent::ContentDelta(text)) => assert_eq!(text, "你"),
            other => panic!("Expected ContentDelta, got {:?}", other),
        }
    }

    #[test]
    fn test_parse_content_delta_without_role() {
        let line = r#"data: {"id":"xxx","choices":[{"index":0,"delta":{"content":"好"},"finish_reason":null}]}"#;
        let event = StreamingHandler::parse_sse_line(line);
        match event {
            Some(ChatStreamEvent::ContentDelta(text)) => assert_eq!(text, "好"),
            other => panic!("Expected ContentDelta, got {:?}", other),
        }
    }

    #[test]
    fn test_parse_thinking_delta() {
        let line = r#"data: {"id":"xxx","choices":[{"index":0,"delta":{"reasoning_content":"让我思考"},"finish_reason":null}]}"#;
        let event = StreamingHandler::parse_sse_line(line);
        match event {
            Some(ChatStreamEvent::ThinkingDelta(text)) => assert_eq!(text, "让我思考"),
            other => panic!("Expected ThinkingDelta, got {:?}", other),
        }
    }

    #[test]
    fn test_parse_done_marker() {
        let line = "data: [DONE]";
        let event = StreamingHandler::parse_sse_line(line);
        match event {
            Some(ChatStreamEvent::Done) => {}
            other => panic!("Expected Done, got {:?}", other),
        }
    }

    #[test]
    fn test_parse_done_marker_with_extra_whitespace() {
        let line = "data:  [DONE] ";
        let event = StreamingHandler::parse_sse_line(line);
        match event {
            Some(ChatStreamEvent::Done) => {}
            other => panic!("Expected Done, got {:?}", other),
        }
    }

    #[test]
    fn test_parse_empty_delta() {
        let line =
            r#"data: {"id":"xxx","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#;
        let event = StreamingHandler::parse_sse_line(line);
        match event {
            Some(ChatStreamEvent::Done) => {}
            other => panic!("Expected Done for finish_reason stop, got {:?}", other),
        }
    }

    #[test]
    fn test_parse_empty_delta_null_finish() {
        let line = r#"data: {"id":"xxx","choices":[{"index":0,"delta":{},"finish_reason":null}]}"#;
        let event = StreamingHandler::parse_sse_line(line);
        assert!(
            event.is_none(),
            "Expected None for empty delta with null finish_reason"
        );
    }

    #[test]
    fn test_parse_non_data_line() {
        assert!(StreamingHandler::parse_sse_line("event: ping").is_none());
        assert!(StreamingHandler::parse_sse_line(": comment").is_none());
        assert!(StreamingHandler::parse_sse_line("").is_none());
        assert!(StreamingHandler::parse_sse_line("random text").is_none());
    }

    #[test]
    fn test_parse_malformed_json() {
        let line = "data: {not valid json}";
        assert!(StreamingHandler::parse_sse_line(line).is_none());
    }

    #[test]
    fn test_parse_json_missing_choices() {
        let line = r#"data: {"id":"xxx"}"#;
        assert!(StreamingHandler::parse_sse_line(line).is_none());
    }

    #[test]
    fn test_parse_json_empty_choices() {
        let line = r#"data: {"id":"xxx","choices":[]}"#;
        assert!(StreamingHandler::parse_sse_line(line).is_none());
    }

    #[test]
    fn test_parse_empty_content_string() {
        let line = r#"data: {"id":"xxx","choices":[{"index":0,"delta":{"content":""},"finish_reason":null}]}"#;
        assert!(StreamingHandler::parse_sse_line(line).is_none());
    }

    #[test]
    fn test_parse_content_with_special_chars() {
        let line = r#"data: {"id":"xxx","choices":[{"index":0,"delta":{"content":"Hello\nWorld"},"finish_reason":null}]}"#;
        match StreamingHandler::parse_sse_line(line) {
            Some(ChatStreamEvent::ContentDelta(text)) => assert_eq!(text, "Hello\nWorld"),
            other => panic!("Expected ContentDelta, got {:?}", other),
        }
    }

    #[test]
    fn test_parse_thinking_takes_priority_over_content() {
        let line = r#"data: {"id":"xxx","choices":[{"index":0,"delta":{"reasoning_content":"think","content":"say"},"finish_reason":null}]}"#;
        match StreamingHandler::parse_sse_line(line) {
            Some(ChatStreamEvent::ThinkingDelta(text)) => assert_eq!(text, "think"),
            other => panic!("Expected ThinkingDelta, got {:?}", other),
        }
    }

    #[test]
    fn test_extract_delta_content() {
        let json: serde_json::Value = serde_json::from_str(
            r#"{"choices":[{"index":0,"delta":{"content":"test"},"finish_reason":null}]}"#,
        )
        .unwrap();
        match StreamingHandler::extract_delta(&json) {
            Some(ChatStreamEvent::ContentDelta(text)) => assert_eq!(text, "test"),
            other => panic!("Expected ContentDelta, got {:?}", other),
        }
    }

    #[test]
    fn test_extract_delta_reasoning() {
        let json: serde_json::Value = serde_json::from_str(
            r#"{"choices":[{"index":0,"delta":{"reasoning_content":"分析中"},"finish_reason":null}]}"#,
        )
        .unwrap();
        match StreamingHandler::extract_delta(&json) {
            Some(ChatStreamEvent::ThinkingDelta(text)) => assert_eq!(text, "分析中"),
            other => panic!("Expected ThinkingDelta, got {:?}", other),
        }
    }

    #[test]
    fn test_extract_delta_finish_stop() {
        let json: serde_json::Value =
            serde_json::from_str(r#"{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#)
                .unwrap();
        match StreamingHandler::extract_delta(&json) {
            Some(ChatStreamEvent::Done) => {}
            other => panic!("Expected Done, got {:?}", other),
        }
    }

    #[test]
    fn test_extract_delta_finish_length() {
        let json: serde_json::Value = serde_json::from_str(
            r#"{"choices":[{"index":0,"delta":{},"finish_reason":"length"}]}"#,
        )
        .unwrap();
        match StreamingHandler::extract_delta(&json) {
            Some(ChatStreamEvent::Done) => {}
            other => panic!("Expected Done for finish_reason=length, got {:?}", other),
        }
    }

    #[test]
    fn test_extract_delta_finish_sensitive() {
        let json: serde_json::Value = serde_json::from_str(
            r#"{"choices":[{"index":0,"delta":{},"finish_reason":"sensitive"}]}"#,
        )
        .unwrap();
        match StreamingHandler::extract_delta(&json) {
            Some(ChatStreamEvent::Error(msg)) => assert!(msg.contains("安全审核")),
            other => panic!(
                "Expected Error for finish_reason=sensitive, got {:?}",
                other
            ),
        }
    }

    #[test]
    fn test_extract_delta_no_delta_field() {
        let json: serde_json::Value = serde_json::from_str(r#"{"choices":[{"index":0}]}"#).unwrap();
        assert!(StreamingHandler::extract_delta(&json).is_none());
    }

    #[test]
    fn test_parse_api_error_in_sse() {
        let line = r#"data: {"error":{"message":"Rate limit exceeded","code":"rate_limit"}}"#;
        match StreamingHandler::parse_sse_line(line) {
            Some(ChatStreamEvent::Error(msg)) => assert!(msg.contains("Rate limit")),
            other => panic!("Expected Error, got {:?}", other),
        }
    }

    #[test]
    fn test_parse_raw_json_error() {
        let line = r#"{"error":{"message":"Invalid token","code":"auth_error"}}"#;
        match StreamingHandler::parse_sse_line(line) {
            Some(ChatStreamEvent::Error(msg)) => assert!(msg.contains("Invalid token")),
            other => panic!("Expected Error, got {:?}", other),
        }
    }

    #[test]
    fn test_parse_raw_json_completion() {
        let line =
            r#"{"choices":[{"index":0,"message":{"content":"Hello"},"finish_reason":"stop"}]}"#;
        match StreamingHandler::parse_sse_line(line) {
            Some(ChatStreamEvent::ContentDelta(text)) => assert_eq!(text, "Hello"),
            other => panic!("Expected ContentDelta, got {:?}", other),
        }
    }
}
