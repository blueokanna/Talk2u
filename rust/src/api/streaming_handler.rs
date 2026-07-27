use super::data_models::ChatStreamEvent;
use super::error_handler::{ChatError, RetryHandler};
use super::provider::ProviderRuntime;
use flutter_rust_bridge::frb;
use futures::StreamExt;
use rustglm::{
    ChatCompletionRequest as GlmChatCompletionRequest, HttpConfig as GlmHttpConfig,
    ResponseContent as GlmResponseContent, RetryPolicy as GlmRetryPolicy, SdkError as GlmError,
    ZhipuConfig,
};

struct StreamTimeoutConfig {
    connect_timeout_secs: u64,
    first_chunk_timeout_secs: u64,
    subsequent_chunk_timeout_secs: u64,
    tcp_keepalive_secs: u64,
}

impl StreamTimeoutConfig {
    fn for_model(model: &str) -> Self {
        match model {
            "glm-4-air" => Self {
                connect_timeout_secs: 30,
                first_chunk_timeout_secs: 300,
                subsequent_chunk_timeout_secs: 120,
                tcp_keepalive_secs: 15,
            },
            "glm-4-long" => Self {
                connect_timeout_secs: 30,
                first_chunk_timeout_secs: 300,
                subsequent_chunk_timeout_secs: 120,
                tcp_keepalive_secs: 15,
            },
            _ => Self {
                connect_timeout_secs: 30,
                first_chunk_timeout_secs: 180,
                subsequent_chunk_timeout_secs: 90,
                tcp_keepalive_secs: 15,
            },
        }
    }
}

#[frb(opaque)]
pub struct StreamingHandler {}

impl StreamingHandler {
    pub async fn stream_chat(
        provider: &ProviderRuntime,
        request_body: serde_json::Value,
        on_event: impl Fn(ChatStreamEvent),
    ) -> Result<(String, String), ChatError> {
        if let Err(message) = crate::ensure_platform_tls_ready() {
            on_event(ChatStreamEvent::Error(message.clone()));
            return Err(ChatError::NetworkError { message });
        }

        if provider.id == "zhipu" {
            return Self::stream_zhipu_chat(provider, request_body, &on_event).await;
        }

        let retry_handler = RetryHandler::new(3, 1000);
        let url_owned = provider.api_url.clone();
        let headers = provider
            .request_headers()
            .map_err(|message| ChatError::AuthError { message })?;
        let body_clone = provider.adapt_request_body(request_body.clone());

        let model_name = request_body
            .get("model")
            .and_then(|v| v.as_str())
            .unwrap_or("unknown");
        let max_tokens = request_body
            .get("max_tokens")
            .and_then(|v| v.as_u64())
            .unwrap_or(0);

        let timeout_config = StreamTimeoutConfig::for_model(model_name);

        let client = reqwest::Client::builder()
            .connect_timeout(std::time::Duration::from_secs(
                timeout_config.connect_timeout_secs,
            ))
            .tcp_keepalive(std::time::Duration::from_secs(
                timeout_config.tcp_keepalive_secs,
            ))
            .pool_idle_timeout(std::time::Duration::from_secs(90))
            .pool_max_idle_per_host(4)
            .build()
            .map_err(|e| ChatError::NetworkError {
                message: e.to_string(),
            })?;

        let response = retry_handler
            .execute_with_retry(|| {
                let client = client.clone();
                let u = url_owned.clone();
                let h = headers.clone();
                let b = body_clone.clone();
                async move {
                    let resp = client
                        .post(&u)
                        .headers(h)
                        .json(&b)
                        .send()
                        .await
                        .map_err(|e| {
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
                        let retry_after_header = resp
                            .headers()
                            .get("retry-after")
                            .and_then(|v| v.to_str().ok())
                            .and_then(|v| v.parse::<u64>().ok());

                        let body_text = resp.text().await.unwrap_or_default();

                        let mut err = Self::classify_http_error(status_code, &body_text);

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
        let mut buffer = Vec::<u8>::new();
        let mut full_content = String::new();
        let mut full_thinking = String::new();
        let mut raw_response_preview = String::new();
        let mut chunk_count: u32 = 0;
        let mut saw_done = false;

        let first_chunk_timeout =
            std::time::Duration::from_secs(timeout_config.first_chunk_timeout_secs);
        let subsequent_chunk_timeout =
            std::time::Duration::from_secs(timeout_config.subsequent_chunk_timeout_secs);

        loop {
            let chunk_timeout = if chunk_count == 0 {
                first_chunk_timeout
            } else {
                subsequent_chunk_timeout
            };

            let chunk_result = match tokio::time::timeout(chunk_timeout, stream.next()).await {
                Ok(Some(result)) => result,
                Ok(None) => break,
                Err(_elapsed) => {
                    let err_msg = if chunk_count == 0 {
                        format!(
                            "[{}] 等待首个响应超时（{}秒），服务器可能过载，请重试",
                            model_name,
                            chunk_timeout.as_secs()
                        )
                    } else {
                        format!(
                            "[{}] 流式响应中断：{}秒未收到新数据（已收到{}字），截断内容未保存，请重试",
                            model_name, chunk_timeout.as_secs(),
                            full_content.chars().count() + full_thinking.chars().count()
                        )
                    };
                    let err = ChatError::StreamError {
                        message: err_msg.clone(),
                    };
                    on_event(ChatStreamEvent::Error(err_msg));
                    return Err(err);
                }
            };

            let chunk = match chunk_result {
                Ok(bytes) => bytes,
                Err(e) => {
                    let has_partial_content = !full_content.is_empty() || !full_thinking.is_empty();
                    let err_msg = if has_partial_content {
                        format!(
                            "[{}] 数据流在传输中断开（已收到{}字），截断内容未保存，请重试: {}",
                            model_name,
                            full_content.chars().count() + full_thinking.chars().count(),
                            e
                        )
                    } else if e.is_timeout() {
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

            chunk_count += 1;

            buffer.extend_from_slice(&chunk);

            while let Some(newline_pos) = buffer.iter().position(|byte| *byte == b'\n') {
                let mut line_bytes: Vec<u8> = buffer.drain(..=newline_pos).collect();
                line_bytes.pop();
                if line_bytes.last() == Some(&b'\r') {
                    line_bytes.pop();
                }
                let line = match String::from_utf8(line_bytes) {
                    Ok(line) => line,
                    Err(error) => {
                        let message = format!("[{model_name}] SSE 返回了无效 UTF-8: {error}");
                        on_event(ChatStreamEvent::Error(message.clone()));
                        return Err(ChatError::StreamError { message });
                    }
                };

                if raw_response_preview.len() < 2000 {
                    raw_response_preview.push_str(&line);
                    raw_response_preview.push('\n');
                }

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
                            saw_done = true;
                        }
                        ChatStreamEvent::Error(_) => {
                            on_event(event);
                        }
                    }
                }
            }
        }

        if !buffer.is_empty() {
            if buffer.last() == Some(&b'\r') {
                buffer.pop();
            }
            let line = String::from_utf8(buffer).map_err(|error| ChatError::StreamError {
                message: format!("[{model_name}] SSE 末尾包含无效 UTF-8: {error}"),
            })?;
            if let Some(event) = Self::parse_sse_line(line.trim()) {
                match &event {
                    ChatStreamEvent::ContentDelta(delta) => {
                        full_content.push_str(delta);
                        on_event(event);
                    }
                    ChatStreamEvent::ThinkingDelta(delta) => {
                        full_thinking.push_str(delta);
                        on_event(event);
                    }
                    ChatStreamEvent::Done => saw_done = true,
                    ChatStreamEvent::Error(_) => {
                        on_event(event);
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

        if chunk_count == 0 {
            let message = format!(
                "[{}] 未收到任何数据（服务器未返回SSE流）。可能原因：1)网络中断 2)API Key无效 3)服务器过载。请检查网络和API Key后重试。",
                model_name
            );
            on_event(ChatStreamEvent::Error(message.clone()));
            return Err(ChatError::StreamError { message });
        }

        if !saw_done {
            let message = format!(
                "[{model_name}] 服务端在发送完成标记前关闭了流（已收到{}字），截断内容未保存，请重试",
                full_content.chars().count() + full_thinking.chars().count()
            );
            on_event(ChatStreamEvent::Error(message.clone()));
            return Err(ChatError::StreamError { message });
        }

        Ok((full_content, full_thinking))
    }

    async fn stream_zhipu_chat(
        provider: &ProviderRuntime,
        request_body: serde_json::Value,
        on_event: &impl Fn(ChatStreamEvent),
    ) -> Result<(String, String), ChatError> {
        let body = provider.adapt_request_body(request_body);
        let request: GlmChatCompletionRequest =
            serde_json::from_value(body).map_err(|error| ChatError::ValidationError {
                message: format!("智谱请求无法转换为 rustglm 请求: {error}"),
            })?;
        let model_name = request.model.clone();
        let timeout_config = StreamTimeoutConfig::for_model(&model_name);

        let mut retry = GlmRetryPolicy::default();
        retry.max_retries = 3;
        retry.initial_delay = std::time::Duration::from_secs(1);
        retry.max_delay = std::time::Duration::from_secs(4);
        let http = GlmHttpConfig {
            timeout: std::time::Duration::from_secs(60 * 60),
            connect_timeout: std::time::Duration::from_secs(timeout_config.connect_timeout_secs),
            pool_idle_timeout: std::time::Duration::from_secs(90),
            user_agent: "Talk2U/1.0 RustGLM/1.0.0".to_string(),
            retry,
            ..GlmHttpConfig::default()
        };
        let client = ZhipuConfig::new(provider.api_key.clone())
            .base_url(Self::zhipu_base_url(&provider.api_url)?)
            .http(http)
            .build()
            .map_err(Self::map_glm_error)?;
        let mut stream = client
            .chat_completion_stream(&request)
            .await
            .map_err(Self::map_glm_error)?;

        let first_chunk_timeout =
            std::time::Duration::from_secs(timeout_config.first_chunk_timeout_secs);
        let subsequent_chunk_timeout =
            std::time::Duration::from_secs(timeout_config.subsequent_chunk_timeout_secs);
        let mut chunk_count = 0_u32;
        let mut full_content = String::new();
        let mut full_thinking = String::new();
        let mut saw_finished = false;

        loop {
            let timeout = if chunk_count == 0 {
                first_chunk_timeout
            } else {
                subsequent_chunk_timeout
            };
            let item = match tokio::time::timeout(timeout, stream.next()).await {
                Ok(Some(item)) => item,
                Ok(None) => break,
                Err(_) => {
                    let message = format!(
                        "[{model_name}] 智谱流式响应超时（{}秒无新数据，已收到{}字），截断内容未保存，请重试",
                        timeout.as_secs(),
                        full_content.chars().count() + full_thinking.chars().count()
                    );
                    on_event(ChatStreamEvent::Error(message.clone()));
                    return Err(ChatError::StreamError { message });
                }
            };

            let chunk = match item {
                Ok(chunk) => chunk,
                Err(error) => {
                    let mapped = Self::map_glm_error(error);
                    on_event(ChatStreamEvent::Error(format!(
                        "[{model_name}] 智谱流式响应失败: {mapped}"
                    )));
                    return Err(mapped);
                }
            };
            chunk_count += 1;

            for choice in chunk.choices {
                if matches!(choice.finish_reason.as_deref(), Some("stop" | "length")) {
                    saw_finished = true;
                }
                if let Some(thinking) = choice.delta.reasoning_content {
                    if !thinking.is_empty() {
                        full_thinking.push_str(&thinking);
                        on_event(ChatStreamEvent::ThinkingDelta(thinking));
                    }
                }
                if let Some(content) = choice.delta.content {
                    let text = match content {
                        GlmResponseContent::Text(text) => text,
                        GlmResponseContent::Parts(parts) => parts
                            .into_iter()
                            .filter_map(|part| part.text)
                            .collect::<String>(),
                    };
                    if !text.is_empty() {
                        full_content.push_str(&text);
                        on_event(ChatStreamEvent::ContentDelta(text));
                    }
                }
            }
        }

        if chunk_count == 0 || (full_content.is_empty() && full_thinking.is_empty()) {
            let message = format!("[{model_name}] 智谱 API 未返回有效的流式内容");
            on_event(ChatStreamEvent::Error(message.clone()));
            return Err(ChatError::StreamError { message });
        }

        if !saw_finished {
            let message = format!(
                "[{model_name}] 智谱流在完成标记前关闭（已收到{}字），截断内容未保存，请重试",
                full_content.chars().count() + full_thinking.chars().count()
            );
            on_event(ChatStreamEvent::Error(message.clone()));
            return Err(ChatError::StreamError { message });
        }

        Ok((full_content, full_thinking))
    }

    fn zhipu_base_url(api_url: &str) -> Result<String, ChatError> {
        let trimmed = api_url.trim().trim_end_matches('/');
        let base = trimmed.strip_suffix("/chat/completions").unwrap_or(trimmed);
        let parsed = reqwest::Url::parse(base).map_err(|error| ChatError::ValidationError {
            message: format!("智谱 API URL 无效: {error}"),
        })?;
        if !matches!(parsed.scheme(), "http" | "https") || parsed.host().is_none() {
            return Err(ChatError::ValidationError {
                message: "智谱 API URL 必须是完整的 HTTP(S) 地址".to_string(),
            });
        }
        Ok(base.to_string())
    }

    fn map_glm_error(error: GlmError) -> ChatError {
        match error {
            GlmError::Api(error) => {
                if error.body.trim().is_empty() {
                    match error.status.as_u16() {
                        401 | 403 => ChatError::AuthError {
                            message: error.message,
                        },
                        429 => ChatError::RateLimitError {
                            retry_after_secs: 2,
                        },
                        status => ChatError::ApiError {
                            status,
                            message: error.message,
                        },
                    }
                } else {
                    ChatError::from_glm_response(error.status.as_u16(), &error.body)
                }
            }
            GlmError::Transport(error) => ChatError::NetworkError {
                message: error.to_string(),
            },
            GlmError::Timeout(error) => ChatError::NetworkError {
                message: error.to_string(),
            },
            GlmError::Configuration(error) => ChatError::ValidationError {
                message: error.to_string(),
            },
            GlmError::Validation(error) => ChatError::ValidationError {
                message: error.to_string(),
            },
            GlmError::Stream(error) => ChatError::StreamError {
                message: error.to_string(),
            },
            GlmError::Decode { message, .. } => ChatError::StreamError { message },
            GlmError::Unsupported(error) => ChatError::ValidationError {
                message: error.to_string(),
            },
            GlmError::Agent(error) => ChatError::ValidationError {
                message: error.to_string(),
            },
            GlmError::Tool(error) => ChatError::ValidationError {
                message: error.to_string(),
            },
        }
    }

    fn classify_http_error(status_code: u16, body_text: &str) -> ChatError {
        let message = serde_json::from_str::<serde_json::Value>(body_text)
            .ok()
            .and_then(|json| {
                json.pointer("/error/message")
                    .or_else(|| json.get("message"))
                    .and_then(|value| value.as_str())
                    .map(str::to_string)
            })
            .unwrap_or_else(|| body_text.chars().take(1000).collect());
        match status_code {
            401 | 403 => ChatError::AuthError { message },
            429 => ChatError::RateLimitError {
                retry_after_secs: 2,
            },
            status if status >= 500 => ChatError::ApiError { status, message },
            status => ChatError::ApiError { status, message },
        }
    }

    pub fn parse_sse_line(line: &str) -> Option<ChatStreamEvent> {
        let trimmed = line.trim();

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
                return Self::extract_delta(&json);
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

        if json.get("type").and_then(|v| v.as_str()) == Some("error") {
            let message = json
                .pointer("/error/message")
                .and_then(|v| v.as_str())
                .unwrap_or("Anthropic API error");
            return Some(ChatStreamEvent::Error(message.to_string()));
        }
        if let Some(delta) = json.get("delta") {
            match delta.get("type").and_then(|v| v.as_str()) {
                Some("text_delta") => {
                    if let Some(text) = delta.get("text").and_then(|v| v.as_str()) {
                        if !text.is_empty() {
                            return Some(ChatStreamEvent::ContentDelta(text.to_string()));
                        }
                    }
                }
                Some("thinking_delta") => {
                    if let Some(thinking) = delta.get("thinking").and_then(|v| v.as_str()) {
                        if !thinking.is_empty() {
                            return Some(ChatStreamEvent::ThinkingDelta(thinking.to_string()));
                        }
                    }
                }
                _ => {}
            }
        }
        if json.get("type").and_then(|v| v.as_str()) == Some("content_block_start") {
            if let Some(text) = json.pointer("/content_block/text").and_then(|v| v.as_str()) {
                if !text.is_empty() {
                    return Some(ChatStreamEvent::ContentDelta(text.to_string()));
                }
            }
        }
        if json.get("type").and_then(|v| v.as_str()) == Some("message_stop") {
            return Some(ChatStreamEvent::Done);
        }

        if let Some(content) = json.get("content").and_then(|v| v.as_array()) {
            if let Some(text) = content.iter().find_map(|block| {
                block
                    .get("text")
                    .and_then(|v| v.as_str())
                    .filter(|v| !v.is_empty())
            }) {
                return Some(ChatStreamEvent::ContentDelta(text.to_string()));
            }
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

    #[test]
    fn test_parse_anthropic_text_delta() {
        let line = r#"event: content_block_delta"#;
        assert!(StreamingHandler::parse_sse_line(line).is_none());
        let line =
            r#"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"你好"}}"#;
        match StreamingHandler::parse_sse_line(line) {
            Some(ChatStreamEvent::ContentDelta(text)) => assert_eq!(text, "你好"),
            other => panic!("Expected Anthropic ContentDelta, got {:?}", other),
        }
    }

    #[test]
    fn test_parse_anthropic_thinking_delta() {
        let line = r#"data: {"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"分析"}}"#;
        match StreamingHandler::parse_sse_line(line) {
            Some(ChatStreamEvent::ThinkingDelta(text)) => assert_eq!(text, "分析"),
            other => panic!("Expected Anthropic ThinkingDelta, got {:?}", other),
        }
    }

    #[test]
    fn test_parse_anthropic_message_stop() {
        let line = r#"data: {"type":"message_stop"}"#;
        assert!(matches!(
            StreamingHandler::parse_sse_line(line),
            Some(ChatStreamEvent::Done)
        ));
    }

    #[test]
    fn test_parse_anthropic_error() {
        let line =
            r#"data: {"type":"error","error":{"type":"authentication_error","message":"bad key"}}"#;
        match StreamingHandler::parse_sse_line(line) {
            Some(ChatStreamEvent::Error(message)) => assert_eq!(message, "bad key"),
            other => panic!("Expected Anthropic Error, got {:?}", other),
        }
    }

    #[test]
    fn test_parse_raw_anthropic_completion() {
        let line = r#"{"id":"msg_1","type":"message","content":[{"type":"text","text":"完整回复"}],"stop_reason":"end_turn"}"#;
        match StreamingHandler::parse_sse_line(line) {
            Some(ChatStreamEvent::ContentDelta(text)) => assert_eq!(text, "完整回复"),
            other => panic!("Expected raw Anthropic ContentDelta, got {:?}", other),
        }
    }

    #[test]
    fn zhipu_sdk_base_url_strips_chat_endpoint() {
        assert_eq!(
            StreamingHandler::zhipu_base_url(
                "https://open.bigmodel.cn/api/paas/v4/chat/completions/"
            )
            .unwrap(),
            "https://open.bigmodel.cn/api/paas/v4"
        );
        assert!(StreamingHandler::zhipu_base_url("file:///tmp/chat/completions").is_err());
    }

    #[test]
    fn zhipu_request_body_converts_to_rustglm() {
        let body = serde_json::json!({
            "model": "glm-4.7",
            "messages": [
                {"role": "system", "content": "identity"},
                {"role": "user", "content": "hello"}
            ],
            "stream": true,
            "thinking": {"type": "disabled"},
            "max_tokens": 1024
        });
        let request: GlmChatCompletionRequest = serde_json::from_value(body).unwrap();
        assert_eq!(request.model, "glm-4.7");
        assert_eq!(request.messages.len(), 2);
        assert_eq!(request.max_tokens, Some(1024));
    }

    #[test]
    fn zhipu_sdk_decode_error_does_not_expose_response_body() {
        let mapped = StreamingHandler::map_glm_error(GlmError::Decode {
            message: "invalid JSON".into(),
            body: "secret response body".into(),
        });
        match mapped {
            ChatError::StreamError { message } => {
                assert_eq!(message, "invalid JSON");
                assert!(!message.contains("secret"));
            }
            other => panic!("Expected StreamError, got {other:?}"),
        }
    }

    #[test]
    fn zhipu_sdk_unsupported_and_tool_errors_are_not_retryable() {
        let unsupported =
            StreamingHandler::map_glm_error(GlmError::Unsupported("realtime audio".into()));
        let tool = StreamingHandler::map_glm_error(GlmError::Tool("tool execution failed".into()));

        assert!(matches!(unsupported, ChatError::ValidationError { .. }));
        assert!(matches!(tool, ChatError::ValidationError { .. }));
        assert!(!unsupported.is_retryable());
        assert!(!tool.is_retryable());
    }
}
