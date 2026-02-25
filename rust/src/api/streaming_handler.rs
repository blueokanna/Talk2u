use super::data_models::ChatStreamEvent;
use super::error_handler::{ChatError, RetryHandler};
use flutter_rust_bridge::frb;
use futures::StreamExt;

#[frb(opaque)]
pub struct StreamingHandler {}

impl StreamingHandler {
    pub async fn stream_chat(
        url: &str,
        token: &str,
        request_body: serde_json::Value,
        on_event: impl Fn(ChatStreamEvent),
    ) -> Result<(String, String), ChatError> {
        let retry_handler = RetryHandler::new(3, 800);
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

        let response = retry_handler
            .execute_with_retry(|| {
                let u = url_owned.clone();
                let t = token_owned.clone();
                let b = body_clone.clone();
                async move {
                    let client = reqwest::Client::builder()
                        // 不设置 timeout（总超时）— 对 SSE 流式响应，总超时会在
                        // 响应还在正常传输时误杀连接。
                        // 只设置连接超时和读取超时（两次数据块之间的最大间隔）。
                        .connect_timeout(std::time::Duration::from_secs(30))
                        .read_timeout(std::time::Duration::from_secs(120))
                        .build()
                        .map_err(|e| ChatError::NetworkError {
                            message: e.to_string(),
                        })?;
                    let resp = client
                        .post(&u)
                        .header("Authorization", format!("Bearer {}", &t))
                        .header("Content-Type", "application/json")
                        .json(&b)
                        .send()
                        .await
                        .map_err(|e| ChatError::NetworkError {
                            message: e.to_string(),
                        })?;

                    let status = resp.status();
                    if !status.is_success() {
                        let status_code = status.as_u16();
                        if status_code == 429 {
                            let retry_after = resp
                                .headers()
                                .get("retry-after")
                                .and_then(|v| v.to_str().ok())
                                .and_then(|v| v.parse::<u64>().ok())
                                .unwrap_or(1);
                            return Err(ChatError::RateLimitError {
                                retry_after_secs: retry_after,
                            });
                        }
                        let body_text = resp.text().await.unwrap_or_default();
                        return Err(ChatError::ApiError {
                            status: status_code,
                            message: body_text,
                        });
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
                    let err = ChatError::StreamError {
                        message: e.to_string(),
                    };
                    on_event(ChatStreamEvent::Error(e.to_string()));
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
                "[{}] API 返回了空内容（共{}个数据块，max_tokens={}）。响应预览: {}",
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
                "[{}] 未收到任何数据块，连接可能被中断。请检查网络或重试。",
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
            let data = if trimmed.starts_with("data: ") {
                &trimmed["data: ".len()..]
            } else {
                &trimmed["data:".len()..]
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
