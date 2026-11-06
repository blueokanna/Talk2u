use flutter_rust_bridge::frb;
use std::fmt;

#[frb(opaque)]
#[derive(Debug, Clone)]
pub enum ChatError {
    ApiError { status: u16, message: String },
    NetworkError { message: String },
    RateLimitError { retry_after_secs: u64 },
    AuthError { message: String },
    StorageError { message: String },
    ValidationError { message: String },
    StreamError { message: String },
    GlmBusinessError { code: String, message: String },
}

impl fmt::Display for ChatError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ChatError::ApiError { status, message } => {
                write!(f, "API error (status {}): {}", status, message)
            }
            ChatError::NetworkError { message } => {
                write!(f, "Network error: {}", message)
            }
            ChatError::RateLimitError { retry_after_secs } => {
                write!(f, "Rate limited: retry after {} seconds", retry_after_secs)
            }
            ChatError::AuthError { message } => {
                write!(f, "Authentication error: {}", message)
            }
            ChatError::StorageError { message } => {
                write!(f, "Storage error: {}", message)
            }
            ChatError::ValidationError { message } => {
                write!(f, "Validation error: {}", message)
            }
            ChatError::StreamError { message } => {
                write!(f, "Stream error: {}", message)
            }
            ChatError::GlmBusinessError { code, message } => {
                write!(f, "GLM error (code {}): {}", code, message)
            }
        }
    }
}

impl std::error::Error for ChatError {}

impl ChatError {
    pub fn is_retryable(&self) -> bool {
        match self {
            ChatError::NetworkError { .. } => true,
            ChatError::ApiError { status, .. } => *status >= 500,
            ChatError::RateLimitError { .. } => true,
            ChatError::StreamError { .. } => true,
            ChatError::GlmBusinessError { code, .. } => {
                matches!(code.as_str(), "500" | "1302" | "1303" | "1305")
            }
            _ => false,
        }
    }

    /// Classifies a failed HTTP response from its status and body.
    ///
    /// GLM puts a business code in `error.code` where OpenAI-compatible
    /// providers only carry a status, so the body is the only place that
    /// distinction exists. Reading it here — instead of special-casing the
    /// provider at the transport boundary — is what keeps 1302/1303/1305
    /// retryable while everything else stays on the status mapping.
    pub fn from_http_error(status_code: u16, body_text: &str) -> Self {
        let Ok(json) = serde_json::from_str::<serde_json::Value>(body_text) else {
            return ChatError::ApiError {
                status: status_code,
                message: body_text.chars().take(1000).collect(),
            };
        };
        let error_obj = json.get("error");
        let code = error_obj
            .and_then(|error| error.get("code"))
            .and_then(|code| {
                code.as_str()
                    .map(str::to_string)
                    .or_else(|| code.as_u64().map(|value| value.to_string()))
            })
            .unwrap_or_default();
        let message = error_obj
            .and_then(|error| error.get("message"))
            .or_else(|| json.get("message"))
            .and_then(|message| message.as_str())
            .map(str::to_string)
            .unwrap_or_else(|| body_text.chars().take(1000).collect());

        Self::classify_glm_error(status_code, &code, &message)
    }

    fn classify_glm_error(status_code: u16, code: &str, message: &str) -> Self {
        match code {            "1001" => ChatError::AuthError {
                message: "请求头中未包含 Authorization 参数，请检查 API Key 配置".to_string(),
            },
            "1002" => ChatError::AuthError {
                message: "Authorization Token 非法，请确认 API Key 正确".to_string(),
            },
            "1003" => ChatError::AuthError {
                message: "Authorization Token 已过期，请重新生成".to_string(),
            },
            "1004" => ChatError::AuthError {
                message: "Authorization Token 验证失败，请检查 API Key".to_string(),
            },
            "1110" => ChatError::AuthError {
                message: "账户当前处于非活动状态，请检查账户信息".to_string(),
            },
            "1111" => ChatError::AuthError {
                message: "账户不存在，请确认 API Key 对应的账户".to_string(),
            },
            "1112" => ChatError::AuthError {
                message: "账户已被锁定，请联系智谱客服解锁".to_string(),
            },
            "1113" => ChatError::GlmBusinessError {
                code: code.to_string(),
                message: "账户余额已用完，请充值后重试".to_string(),
            },
            "1120" => ChatError::AuthError {
                message: "无法访问账户，请稍后重试".to_string(),
            },
            "1121" => ChatError::AuthError {
                message: "账户因违规行为已被锁定，请联系客服".to_string(),
            },
            "1210" => ChatError::ValidationError {
                message: format!("API 调用参数有误: {}", message),
            },
            "1211" => ChatError::ValidationError {
                message: format!("模型不存在，请检查模型名称: {}", message),
            },
            "1212" => ChatError::ValidationError {
                message: format!("当前模型不支持此调用方式: {}", message),
            },
            "1213" => ChatError::ValidationError {
                message: format!("缺少必要参数: {}", message),
            },
            "1214" => ChatError::ValidationError {
                message: format!("参数非法: {}", message),
            },
            "1215" => ChatError::ValidationError {
                message: format!("参数冲突: {}", message),
            },
            "1301" => ChatError::ValidationError {
                message: "内容包含不安全或敏感内容，请修改后重试".to_string(),
            },
            "1302" => ChatError::RateLimitError {
                retry_after_secs: 3,
            },
            "1303" => ChatError::RateLimitError {
                retry_after_secs: 5,
            },
            "1305" => ChatError::RateLimitError {
                retry_after_secs: 5,
            },
            "1304" => ChatError::GlmBusinessError {
                code: code.to_string(),
                message: "已达今日 API 调用次数限额，请明日再试或联系客服".to_string(),
            },
            "1308" => ChatError::GlmBusinessError {
                code: code.to_string(),
                message: format!("已达使用上限: {}", message),
            },
            "1310" => ChatError::GlmBusinessError {
                code: code.to_string(),
                message: format!("已达每周/每月使用上限: {}", message),
            },
            "500" => ChatError::ApiError {
                status: 500,
                message: format!("服务器内部错误，请稍后重试: {}", message),
            },
            _ => match status_code {
                401 => ChatError::AuthError {
                    message: message.to_string(),
                },
                429 => ChatError::RateLimitError {
                    retry_after_secs: 2,
                },
                s if s >= 500 => ChatError::ApiError {
                    status: s,
                    message: message.to_string(),
                },
                _ => ChatError::ApiError {
                    status: status_code,
                    message: message.to_string(),
                },
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_chat_error_display() {
        let err = ChatError::ApiError {
            status: 500,
            message: "Internal Server Error".to_string(),
        };
        assert_eq!(
            err.to_string(),
            "API error (status 500): Internal Server Error"
        );

        let err = ChatError::RateLimitError {
            retry_after_secs: 5,
        };
        assert_eq!(err.to_string(), "Rate limited: retry after 5 seconds");

        let err = ChatError::ValidationError {
            message: "empty message".to_string(),
        };
        assert_eq!(err.to_string(), "Validation error: empty message");
    }

    #[test]
    fn test_chat_error_is_retryable() {
        assert!(ChatError::NetworkError {
            message: "timeout".into()
        }
        .is_retryable());
        assert!(ChatError::ApiError {
            status: 500,
            message: "err".into()
        }
        .is_retryable());
        assert!(!ChatError::ApiError {
            status: 400,
            message: "bad".into()
        }
        .is_retryable());
        assert!(!ChatError::ApiError {
            status: 401,
            message: "auth".into()
        }
        .is_retryable());
        assert!(ChatError::RateLimitError {
            retry_after_secs: 1
        }
        .is_retryable());

        assert!(!ChatError::ValidationError {
            message: "bad".into()
        }
        .is_retryable());
        assert!(!ChatError::StorageError {
            message: "io".into()
        }
        .is_retryable());
        assert!(!ChatError::AuthError {
            message: "denied".into()
        }
        .is_retryable());
        assert!(ChatError::StreamError {
            message: "broken".into()
        }
        .is_retryable());

        assert!(ChatError::GlmBusinessError {
            code: "1302".into(),
            message: "并发".into()
        }
        .is_retryable());
        assert!(ChatError::GlmBusinessError {
            code: "1303".into(),
            message: "频率".into()
        }
        .is_retryable());
        assert!(!ChatError::GlmBusinessError {
            code: "1304".into(),
            message: "限额".into()
        }
        .is_retryable());
        assert!(!ChatError::GlmBusinessError {
            code: "1113".into(),
            message: "余额".into()
        }
        .is_retryable());
    }

    #[test]
    fn glm_business_codes_survive_without_the_sdk() {
        // 1302/1303/1305 arrive as an `error.code` in the body, not in the
        // status line. This is the classification the transport has to
        // reproduce itself now that the Zhipu request goes through courierust.
        for code in ["1302", "1303", "1305"] {
            let body = format!(
                r#"{{"error":{{"code":"{code}","message":"并发或频率限制"}}}}"#
            );
            let error = ChatError::from_http_error(200, &body);
            assert!(
                matches!(error, ChatError::RateLimitError { .. }),
                "{code} mapped to {error:?}"
            );
            assert!(error.is_retryable(), "{code} should be retryable");
        }
    }

    #[test]
    fn glm_auth_and_quota_codes_are_not_retryable() {
        let auth = ChatError::from_http_error(
            400,
            r#"{"error":{"code":"1002","message":"Authorization Token 非法"}}"#,
        );
        assert!(matches!(auth, ChatError::AuthError { .. }));
        assert!(!auth.is_retryable());

        let quota = ChatError::from_http_error(
            400,
            r#"{"error":{"code":"1304","message":"今日调用次数已达上限"}}"#,
        );
        assert!(matches!(quota, ChatError::GlmBusinessError { .. }));
        assert!(!quota.is_retryable());
    }

    #[test]
    fn numeric_json_codes_are_read_as_well() {
        let error = ChatError::from_http_error(
            429,
            r#"{"error":{"code":1302,"message":"系统并发数过高"}}"#,
        );
        assert!(matches!(error, ChatError::RateLimitError { .. }));
    }

    #[test]
    fn non_glm_bodies_fall_back_to_the_status_mapping() {
        let openai = ChatError::from_http_error(
            401,
            r#"{"error":{"message":"Incorrect API key provided"}}"#,
        );
        match openai.clone() {
            ChatError::AuthError { message } => {
                assert_eq!(message, "Incorrect API key provided")
            }
            other => panic!("expected AuthError, got {other:?}"),
        }
        assert!(!openai.is_retryable());

        let anthropic = ChatError::from_http_error(
            529,
            r#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#,
        );
        assert!(matches!(anthropic, ChatError::ApiError { status: 529, .. }));
        assert!(anthropic.is_retryable());
    }

    #[test]
    fn plain_text_bodies_stay_readable_and_bounded() {
        let error = ChatError::from_http_error(502, "upstream connect error");
        match error {
            ChatError::ApiError { status, message } => {
                assert_eq!(status, 502);
                assert_eq!(message, "upstream connect error");
            }
            other => panic!("expected ApiError, got {other:?}"),
        }

        let huge = "x".repeat(5_000);
        match ChatError::from_http_error(500, &huge) {
            ChatError::ApiError { message, .. } => assert_eq!(message.chars().count(), 1_000),
            other => panic!("expected ApiError, got {other:?}"),
        }
    }

    #[test]
    fn top_level_message_is_used_when_there_is_no_error_object() {
        match ChatError::from_http_error(404, r#"{"message":"model not found"}"#) {
            ChatError::ApiError { status, message } => {
                assert_eq!(status, 404);
                assert_eq!(message, "model not found");
            }
            other => panic!("expected ApiError, got {other:?}"),
        }
    }
}
