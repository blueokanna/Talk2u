use reqwest::header::{HeaderMap, HeaderValue, ACCEPT, AUTHORIZATION, CONTENT_TYPE};

use super::data_models::{AppSettings, ProviderConfig};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WireProtocol {
    OpenAi,
    Anthropic,
}

#[derive(Debug, Clone)]
pub struct ProviderRuntime {
    pub id: String,
    pub api_url: String,
    pub api_key: String,
    pub protocol: WireProtocol,
    pub max_output_tokens: u32,
}

impl ProviderRuntime {
    pub fn from_settings(
        settings: &AppSettings,
        requested_id: &str,
    ) -> Result<(Self, ProviderConfig), String> {
        let provider_id = if requested_id.trim().is_empty() {
            settings.selected_provider.as_str()
        } else {
            requested_id
        };

        let providers: Vec<ProviderConfig> = serde_json::from_str(&settings.providers_json)
            .map_err(|error| format!("平台配置无法解析: {error}"))?;
        let mut config = providers
            .iter()
            .find(|item| item.id == provider_id)
            .cloned()
            .ok_or_else(|| format!("未找到平台配置: {provider_id}"))?;

        if config.id == "zhipu" && config.api_key.as_deref().unwrap_or("").trim().is_empty() {
            config.api_key = settings.api_key.clone();
        }

        if !config.is_configured() {
            return Err(format!(
                "{} 尚未配置完整的 API Key、调用 URL 和模型",
                config.name
            ));
        }

        let protocol = match config.protocol.trim().to_ascii_lowercase().as_str() {
            "anthropic" => WireProtocol::Anthropic,
            "openai" | "" => WireProtocol::OpenAi,
            other => return Err(format!("不支持的接口协议: {other}")),
        };

        let parsed_url = reqwest::Url::parse(config.api_url.trim())
            .map_err(|error| format!("{} 的调用 URL 无效: {error}", config.name))?;
        if !matches!(parsed_url.scheme(), "http" | "https") || parsed_url.host().is_none() {
            return Err(format!(
                "{} 的调用 URL 必须是完整的 HTTP(S) 地址",
                config.name
            ));
        }

        let runtime = Self {
            id: config.id.clone(),
            api_url: config.api_url.trim().to_string(),
            api_key: config
                .api_key
                .clone()
                .unwrap_or_default()
                .trim()
                .to_string(),
            protocol,
            max_output_tokens: config.max_output_tokens.max(1),
        };
        Ok((runtime, config))
    }

    pub fn request_headers(&self) -> Result<HeaderMap, String> {
        let mut headers = HeaderMap::new();
        headers.insert(CONTENT_TYPE, HeaderValue::from_static("application/json"));
        headers.insert(ACCEPT, HeaderValue::from_static("text/event-stream"));

        match self.protocol {
            WireProtocol::Anthropic => {
                headers.insert(
                    "x-api-key",
                    HeaderValue::from_str(&self.api_key)
                        .map_err(|_| "Anthropic API Key 包含无效字符".to_string())?,
                );
                headers.insert("anthropic-version", HeaderValue::from_static("2023-06-01"));
            }
            WireProtocol::OpenAi => {
                if self.api_key.is_empty() {
                    return Ok(headers);
                }
                headers.insert(
                    AUTHORIZATION,
                    HeaderValue::from_str(&format!("Bearer {}", self.api_key))
                        .map_err(|_| "API Key 包含无效字符".to_string())?,
                );
            }
        }
        Ok(headers)
    }

    pub fn adapt_request_body(&self, mut body: serde_json::Value) -> serde_json::Value {
        if let Some(requested) = body.get("max_tokens").and_then(serde_json::Value::as_u64) {
            body["max_tokens"] =
                serde_json::Value::from(requested.min(u64::from(self.max_output_tokens)));
        }
        if self.protocol != WireProtocol::Anthropic {
            return body;
        }

        let messages = body
            .get_mut("messages")
            .and_then(serde_json::Value::as_array_mut)
            .map(std::mem::take)
            .unwrap_or_default();
        let mut system_parts = Vec::new();
        let mut anthropic_messages = Vec::new();
        for message in messages {
            if message.get("role").and_then(|v| v.as_str()) == Some("system") {
                if let Some(content) = message.get("content").and_then(|v| v.as_str()) {
                    system_parts.push(content.to_string());
                }
            } else {
                anthropic_messages.push(message);
            }
        }
        body["messages"] = serde_json::Value::Array(anthropic_messages);
        if !system_parts.is_empty() {
            body["system"] = serde_json::Value::String(system_parts.join("\n\n"));
        }
        body.as_object_mut().map(|object| object.remove("thinking"));
        body
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn runtime(protocol: WireProtocol) -> ProviderRuntime {
        ProviderRuntime {
            id: if protocol == WireProtocol::Anthropic {
                "anthropic"
            } else {
                "openai"
            }
            .into(),
            api_url: "https://example.test/messages".into(),
            api_key: "secret-key".into(),
            protocol,
            max_output_tokens: 4096,
        }
    }

    #[test]
    fn anthropic_body_moves_system_out_of_messages() {
        let provider = runtime(WireProtocol::Anthropic);
        let body = serde_json::json!({
            "model": "claude-test",
            "messages": [
                {"role": "system", "content": "identity"},
                {"role": "user", "content": "hello"}
            ],
            "thinking": {"type": "enabled"},
            "stream": true,
            "max_tokens": 1024
        });
        let adapted = provider.adapt_request_body(body);
        assert_eq!(adapted["system"], "identity");
        assert_eq!(adapted["messages"].as_array().unwrap().len(), 1);
        assert_eq!(adapted["max_tokens"], 1024);
        assert_eq!(adapted["stream"], true);
        assert!(adapted.get("thinking").is_none());
    }

    #[test]
    fn anthropic_headers_use_x_api_key_without_bearer_token() {
        let headers = runtime(WireProtocol::Anthropic).request_headers().unwrap();
        assert_eq!(headers.get("x-api-key").unwrap(), "secret-key");
        assert_eq!(headers.get("anthropic-version").unwrap(), "2023-06-01");
        assert!(headers.get(AUTHORIZATION).is_none());
    }

    #[test]
    fn openai_headers_use_bearer_token() {
        let headers = runtime(WireProtocol::OpenAi).request_headers().unwrap();
        assert_eq!(headers.get(AUTHORIZATION).unwrap(), "Bearer secret-key");
        assert!(headers.get("x-api-key").is_none());
    }

    #[test]
    fn settings_resolve_custom_url_and_model() {
        let config = ProviderConfig {
            id: "custom".into(),
            name: "Local gateway".into(),
            api_key: Some("local-key".into()),
            api_url: "http://127.0.0.1:8000/v1/chat/completions".into(),
            chat_model: "local-model".into(),
            thinking_model: None,
            protocol: "openai".into(),
            max_output_tokens: 4096,
        };
        let settings = AppSettings {
            selected_provider: "custom".into(),
            providers_json: serde_json::to_string(&vec![config]).unwrap(),
            ..AppSettings::default()
        };
        let (resolved, model) = ProviderRuntime::from_settings(&settings, "").unwrap();
        assert_eq!(
            resolved.api_url,
            "http://127.0.0.1:8000/v1/chat/completions"
        );
        assert_eq!(model.chat_model, "local-model");
        assert_eq!(resolved.protocol, WireProtocol::OpenAi);
    }

    #[test]
    fn legacy_zhipu_key_is_migrated_at_runtime() {
        let config = ProviderConfig {
            id: "zhipu".into(),
            name: "Zhipu".into(),
            api_key: None,
            api_url: "https://example.test/chat".into(),
            chat_model: "glm-test".into(),
            thinking_model: None,
            protocol: "openai".into(),
            max_output_tokens: 4096,
        };
        let settings = AppSettings {
            api_key: Some("id.secret".into()),
            providers_json: serde_json::to_string(&vec![config]).unwrap(),
            ..AppSettings::default()
        };
        let (resolved, _) = ProviderRuntime::from_settings(&settings, "zhipu").unwrap();
        assert_eq!(resolved.api_key, "id.secret");
    }

    #[test]
    fn request_body_is_clamped_to_provider_output_limit() {
        let mut provider = runtime(WireProtocol::OpenAi);
        provider.max_output_tokens = 2048;
        let adapted = provider.adapt_request_body(serde_json::json!({
            "model": "test",
            "messages": [],
            "max_tokens": 16384
        }));
        assert_eq!(adapted["max_tokens"], 2048);
    }

    #[test]
    fn custom_openai_endpoint_can_run_without_authentication() {
        let config = ProviderConfig {
            id: "custom".into(),
            name: "Local".into(),
            api_key: None,
            api_url: "http://127.0.0.1:11434/v1/chat/completions".into(),
            chat_model: "local-model".into(),
            thinking_model: None,
            protocol: "openai".into(),
            max_output_tokens: 4096,
        };
        let settings = AppSettings {
            selected_provider: "custom".into(),
            providers_json: serde_json::to_string(&vec![config]).unwrap(),
            ..AppSettings::default()
        };
        let (provider, _) = ProviderRuntime::from_settings(&settings, "custom").unwrap();
        assert!(provider
            .request_headers()
            .unwrap()
            .get(AUTHORIZATION)
            .is_none());
    }

    #[test]
    fn rejects_non_http_provider_urls() {
        let config = ProviderConfig {
            id: "custom".into(),
            name: "Invalid".into(),
            api_key: None,
            api_url: "file:///tmp/completions".into(),
            chat_model: "local-model".into(),
            thinking_model: None,
            protocol: "openai".into(),
            max_output_tokens: 4096,
        };
        let settings = AppSettings {
            selected_provider: "custom".into(),
            providers_json: serde_json::to_string(&vec![config]).unwrap(),
            ..AppSettings::default()
        };
        assert!(ProviderRuntime::from_settings(&settings, "custom").is_err());
    }
}
