use super::data_models::ChatStreamEvent;
use super::error_handler::ChatError;
use super::provider::ProviderRuntime;
use flutter_rust_bridge::frb;

struct StreamTimeoutConfig {
    first_chunk_timeout_secs: u64,
    subsequent_chunk_timeout_secs: u64,
}

impl StreamTimeoutConfig {
    fn for_model(model: &str) -> Self {
        match model {
            "glm-4-air" => Self {
                first_chunk_timeout_secs: 300,
                subsequent_chunk_timeout_secs: 120,
            },
            "glm-4-long" => Self {
                first_chunk_timeout_secs: 300,
                subsequent_chunk_timeout_secs: 120,
            },
            _ => Self {
                first_chunk_timeout_secs: 180,
                subsequent_chunk_timeout_secs: 90,
            },
        }
    }
}

/// Accumulates a reply from parsed events.
///
/// The main loop and the tail flush both feed this, so "what counts as
/// received text" has exactly one definition.
#[derive(Default)]
struct ReplyBuffer {
    content: String,
    thinking: String,
    saw_done: bool,
    last_error: Option<String>,
}

impl ReplyBuffer {
    /// Records one parsed event and hands it back for emission.
    fn absorb(&mut self, line: &str) -> Option<ChatStreamEvent> {
        let event = StreamingHandler::parse_sse_line(line)?;
        match &event {
            ChatStreamEvent::ContentDelta(delta) => self.content.push_str(delta),
            ChatStreamEvent::ThinkingDelta(delta) => self.thinking.push_str(delta),
            ChatStreamEvent::Done => self.saw_done = true,
            ChatStreamEvent::Error(message) => self.last_error = Some(message.clone()),
        }
        Some(event)
    }

    /// The message of the last error frame, if any.
    fn last_error(&self) -> Option<String> {
        self.last_error.clone()
    }

    fn is_empty(&self) -> bool {
        self.content.is_empty() && self.thinking.is_empty()
    }

    fn chars(&self) -> usize {
        self.content.chars().count() + self.thinking.chars().count()
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
        let body = provider.adapt_request_body(request_body.clone());
        let body_bytes = serde_json::to_vec(&body).map_err(|error| ChatError::ValidationError {
            message: format!("请求体无法序列化: {error}"),
        })?;

        let model_name = request_body
            .get("model")
            .and_then(|value| value.as_str())
            .unwrap_or("unknown");
        let max_tokens = request_body
            .get("max_tokens")
            .and_then(|value| value.as_u64())
            .unwrap_or(0);

        let timeout_config = StreamTimeoutConfig::for_model(model_name);
        let mut stream = crate::api::transport::post_stream(crate::api::transport::StreamRequest {
            url: provider.api_url.clone(),
            headers: provider
                .request_headers()
                .map_err(|message| ChatError::AuthError { message })?,
            body: body_bytes,
            read_timeout: std::time::Duration::from_secs(
                timeout_config.subsequent_chunk_timeout_secs,
            ),
        })
        .await
        .map_err(|error| {
            on_event(ChatStreamEvent::Error(format!(
                "[{model_name}] 请求失败: {error}"
            )));
            error
        })?;

        let mut decoder = super::sse_decoder::SseDecoder::default();
        let mut reply = ReplyBuffer::default();
        let mut raw_response_preview = String::new();
        let mut chunk_count: u32 = 0;

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
                            reply.chars()
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
                Err(error) => {
                    let received = reply.chars();
                    let err_msg = if received > 0 {
                        format!(
                            "[{model_name}] 数据流在传输中断开（已收到{received}字），截断内容未保存，请重试: {error}"
                        )
                    } else {
                        format!("[{model_name}] {error}")
                    };
                    on_event(ChatStreamEvent::Error(err_msg.clone()));
                    return Err(ChatError::StreamError { message: err_msg });
                }
            };

            chunk_count += 1;

            let lines = decoder.push(&chunk).map_err(|error| {
                let message = format!("[{model_name}] {error}");
                on_event(ChatStreamEvent::Error(message.clone()));
                ChatError::StreamError { message }
            })?;
            for line in lines {
                if raw_response_preview.len() < 2000 {
                    raw_response_preview.push_str(&line);
                    raw_response_preview.push('\n');
                }
                let Some(event) = reply.absorb(&line) else {
                    continue;
                };
                // An error frame ends the turn. Waiting for a completion marker
                // the peer will never send would report a second, wrong failure
                // and hide the one the server actually gave.
                let terminal = matches!(event, ChatStreamEvent::Error(_));
                on_event(event);
                if terminal {
                    let message = reply
                        .last_error()
                        .unwrap_or_else(|| format!("[{model_name}] 流式响应中断，服务端没有给出错误原因"));
                    return Err(ChatError::StreamError { message });
                }
            }
        }

        if let Some(line) = decoder.finish().map_err(|error| {
            let message = format!("[{model_name}] {error}");
            on_event(ChatStreamEvent::Error(message.clone()));
            ChatError::StreamError { message }
        })? {
            if let Some(event) = reply.absorb(&line) {
                let terminal = matches!(event, ChatStreamEvent::Error(_));
                on_event(event);
                if terminal {
                    let message = reply
                        .last_error()
                        .unwrap_or_else(|| format!("[{model_name}] 流式响应中断，服务端没有给出错误原因"));
                    return Err(ChatError::StreamError { message });
                }
            }
        }

        if reply.is_empty() && !raw_response_preview.is_empty() {
            let message = format!(
                "[{}] API 返回了数据但未包含有效内容（共{}个数据块，max_tokens={}）。\n可能原因：1)模型参数格式不被支持 2)内容安全过滤 3)Token预算不足。\n响应预览: {}",
                model_name,
                chunk_count,
                max_tokens,
                raw_response_preview.chars().take(500).collect::<String>()
            );
            on_event(ChatStreamEvent::Error(message.clone()));
            return Err(ChatError::StreamError { message });
        }

        if chunk_count == 0 {
            let message = format!(
                "[{}] 未收到任何数据（服务器未返回SSE流）。可能原因：1)网络中断 2)API Key无效 3)服务器过载。请检查网络和API Key后重试。",
                model_name
            );
            on_event(ChatStreamEvent::Error(message.clone()));
            return Err(ChatError::StreamError { message });
        }

        if !reply.saw_done {
            let message = format!(
                "[{model_name}] 服务端在发送完成标记前关闭了流（已收到{}字），截断内容未保存，请重试",
                reply.chars()
            );
            on_event(ChatStreamEvent::Error(message.clone()));
            return Err(ChatError::StreamError { message });
        }

        Ok((reply.content, reply.thinking))
    }

    /// Decodes one `data:` payload as an OpenAI chat-completions chunk.
    ///
    /// The type comes from `rustglm`, so a delta that grows a new field ? or a
    /// content that arrives as parts instead of a string ? is handled by the
    /// crate's own contract instead of being silently dropped by a hand-written
    /// field probe. Returns `None` for shapes this wire never carries, which
    /// lets the caller fall back to the Anthropic or raw-completion parsers.
    fn parse_chunk(data: &str) -> Option<ChatStreamEvent> {
        let chunk: rustglm::ChatCompletionChunk = nextjson::from_str(data).ok()?;

        if let Some(error) = chunk.extra.get("error") {
            let message = error
                .get("message")
                .and_then(|value| value.as_str())
                .unwrap_or("Unknown API error");
            return Some(ChatStreamEvent::Error(message.to_string()));
        }

        let mut event = None;
        for choice in &chunk.choices {
            if event.is_none() {
                if let Some(reasoning) = choice.delta.reasoning_content.as_deref() {
                    if !reasoning.is_empty() {
                        event = Some(ChatStreamEvent::ThinkingDelta(reasoning.to_string()));
                    }
                }
            }
            if event.is_none() {
                if let Some(text) = choice.delta.content.as_ref().and_then(|c| c.joined_text()) {
                    event = Some(ChatStreamEvent::ContentDelta(text));
                }
            }
            if event.is_none() {
                match choice.finish_reason.as_deref() {
                    Some("stop" | "length") => event = Some(ChatStreamEvent::Done),
                    Some("sensitive") => {
                        event = Some(ChatStreamEvent::Error(
                            "内容被服务端的安全策略拦截，本轮回复已中断；请换一种说法或换个话题再试。".to_string(),
                        ))
                    }
                    _ => {}
                }
            }
            if event.is_some() {
                break;
            }
        }
        event
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

            if let Some(event) = Self::parse_chunk(data) {
                return Some(event);
            }

            // Everything below is a shape the OpenAI wire does not produce:
            // Anthropic's block events, or a non-streamed completion.
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
    fn test_parse_content_parts_are_joined() {
        // The OpenAI wire allows `content` to be an array of parts; the previous
        // hand-written probe read it as a string only and silently dropped this.
        let line = r#"data: {"choices":[{"index":0,"delta":{"content":[{"type":"text","text":"你"},{"type":"text","text":"好"}]},"finish_reason":null}]}"#;
        match StreamingHandler::parse_sse_line(line) {
            Some(ChatStreamEvent::ContentDelta(text)) => assert_eq!(text, "你好"),
            other => panic!("Expected ContentDelta from parts, got {:?}", other),
        }
    }

    #[test]
    fn test_typed_error_frame_wins_over_an_empty_chunk() {
        let line = r#"data: {"error":{"code":"1302","message":"模型当前不可用"}}"#;
        match StreamingHandler::parse_sse_line(line) {
            Some(ChatStreamEvent::Error(message)) => assert_eq!(message, "模型当前不可用"),
            other => panic!("Expected Error, got {:?}", other),
        }
    }

    #[test]
    fn test_sensitive_finish_reason_is_a_visible_error() {
        let line = r#"data: {"choices":[{"index":0,"delta":{},"finish_reason":"sensitive"}]}"#;
        match StreamingHandler::parse_sse_line(line) {
            Some(ChatStreamEvent::Error(message)) => assert!(message.contains("安全策略")),
            other => panic!("Expected security Error, got {:?}", other),
        }
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
}
