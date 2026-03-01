use flutter_rust_bridge::frb;
use std::fmt;
use std::future::Future;
use tokio::time::sleep;
use std::time::Duration;

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
    /// GLM 业务错误（携带业务错误码，便于精确分类）
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
    /// Returns true if this error type should be retried.
    /// Used by RetryHandler for automatic retry logic on transient failures.
    ///
    /// 参考 GLM 错误码文档：
    /// - 5xx 服务端错误：可重试
    /// - 429 频率/并发限制：可重试（含业务码 1302/1303/1305）
    /// - 400/401/434/435：不可重试
    /// - 业务码 1304/1308/1310（配额耗尽）：不可重试
    /// - 业务码 1113（余额不足）：不可重试
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

    /// 根据 GLM API 响应体解析错误
    /// 响应格式: {"error": {"code": "1002", "message": "..."}}
    ///
    /// 参考: https://docs.bigmodel.cn/cn/api/api-code
    pub fn from_glm_response(status_code: u16, body_text: &str) -> Self {
        let parsed = serde_json::from_str::<serde_json::Value>(body_text);
        if let Ok(json) = parsed {
            let error_obj = json.get("error");
            let code = error_obj
                .and_then(|e| e.get("code"))
                .and_then(|c| {
                    c.as_str()
                        .map(|s| s.to_string())
                        .or_else(|| c.as_u64().map(|n| n.to_string()))
                })
                .unwrap_or_default();
            let message = error_obj
                .and_then(|e| e.get("message"))
                .and_then(|m| m.as_str())
                .unwrap_or("未知错误")
                .to_string();

            Self::classify_glm_error(status_code, &code, &message)
        } else {
            ChatError::ApiError {
                status: status_code,
                message: body_text.to_string(),
            }
        }
    }

    /// 根据 GLM 业务错误码分类为具体 ChatError 变体
    ///
    /// 错误码映射（参考 https://docs.bigmodel.cn/cn/api/api-code）：
    /// - 1001~1004: 认证/Token 错误 → AuthError
    /// - 1110~1121: 账户异常 → AuthError
    /// - 1113: 余额不足 → GlmBusinessError（不可重试）
    /// - 1210~1215: API 参数错误 → ValidationError
    /// - 1301: 内容安全 → ValidationError
    /// - 1302/1303/1305: 并发/频率/流量限制 → RateLimitError（可重试）
    /// - 1304/1308/1310: 配额耗尽 → GlmBusinessError（不可重试）
    /// - 500: 服务端内部错误 → ApiError
    fn classify_glm_error(status_code: u16, code: &str, message: &str) -> Self {
        match code {
            // ── 认证错误 ──
            "1001" => ChatError::AuthError {
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
            // ── 账户错误 ──
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
            // ── API 参数错误 ──
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
            // ── 内容安全 ──
            "1301" => ChatError::ValidationError {
                message: "内容包含不安全或敏感内容，请修改后重试".to_string(),
            },
            // ── 频率/并发限制（可重试）──
            "1302" => ChatError::RateLimitError {
                retry_after_secs: 3,
            },
            "1303" => ChatError::RateLimitError {
                retry_after_secs: 5,
            },
            "1305" => ChatError::RateLimitError {
                retry_after_secs: 5,
            },
            // ── 配额耗尽（不可重试）──
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
            // ── 服务端内部错误 ──
            "500" => ChatError::ApiError {
                status: 500,
                message: format!("服务器内部错误，请稍后重试: {}", message),
            },
            // ── 未知业务码：按 HTTP 状态码回退 ──
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

#[frb(opaque)]
pub struct RetryHandler {
    max_retries: u32,
    initial_delay_ms: u64,
}

impl RetryHandler {
    pub fn new(max_retries: u32, initial_delay_ms: u64) -> Self {
        Self {
            max_retries,
            initial_delay_ms,
        }
    }

    pub async fn execute_with_retry<F, Fut, T>(&self, operation: F) -> Result<T, ChatError>
    where
        F: Fn() -> Fut,
        Fut: Future<Output = Result<T, ChatError>>,
    {
        let mut last_error: Option<ChatError> = None;
        let mut delay_ms = self.initial_delay_ms;

        for attempt in 0..=self.max_retries {
            match operation().await {
                Ok(value) => return Ok(value),
                Err(err) => {
                    if !err.is_retryable() {
                        return Err(err);
                    }

                    last_error = Some(err.clone());
                    if attempt < self.max_retries {
                        let wait_ms = if let ChatError::RateLimitError { retry_after_secs } = &err
                        {
                            retry_after_secs * 1000
                        } else {
                            let current = delay_ms;
                            delay_ms *= 2;
                            current
                        };

                        sleep(Duration::from_millis(wait_ms)).await;
                    }
                }
            }
        }

        Err(last_error.unwrap())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU32, Ordering};
    use std::sync::Arc;

    #[test]
    fn test_chat_error_display() {
        let err = ChatError::ApiError {
            status: 500,
            message: "Internal Server Error".to_string(),
        };
        assert_eq!(err.to_string(), "API error (status 500): Internal Server Error");

        let err = ChatError::RateLimitError { retry_after_secs: 5 };
        assert_eq!(err.to_string(), "Rate limited: retry after 5 seconds");

        let err = ChatError::ValidationError {
            message: "empty message".to_string(),
        };
        assert_eq!(err.to_string(), "Validation error: empty message");
    }

    #[test]
    fn test_chat_error_is_retryable() {
        assert!(ChatError::NetworkError { message: "timeout".into() }.is_retryable());
        assert!(ChatError::ApiError { status: 500, message: "err".into() }.is_retryable());
        assert!(!ChatError::ApiError { status: 400, message: "bad".into() }.is_retryable());
        assert!(!ChatError::ApiError { status: 401, message: "auth".into() }.is_retryable());
        assert!(ChatError::RateLimitError { retry_after_secs: 1 }.is_retryable());

        assert!(!ChatError::ValidationError { message: "bad".into() }.is_retryable());
        assert!(!ChatError::StorageError { message: "io".into() }.is_retryable());
        assert!(!ChatError::AuthError { message: "denied".into() }.is_retryable());
        assert!(ChatError::StreamError { message: "broken".into() }.is_retryable());

        // GLM 业务码
        assert!(ChatError::GlmBusinessError { code: "1302".into(), message: "并发".into() }.is_retryable());
        assert!(ChatError::GlmBusinessError { code: "1303".into(), message: "频率".into() }.is_retryable());
        assert!(!ChatError::GlmBusinessError { code: "1304".into(), message: "限额".into() }.is_retryable());
        assert!(!ChatError::GlmBusinessError { code: "1113".into(), message: "余额".into() }.is_retryable());
    }

    #[tokio::test]
    async fn test_retry_immediate_success() {
        let handler = RetryHandler::new(3, 100);
        let result = handler
            .execute_with_retry(|| async { Ok::<i32, ChatError>(42) })
            .await;
        assert_eq!(result.unwrap(), 42);
    }

    #[tokio::test]
    async fn test_retry_success_after_failures() {
        let handler = RetryHandler::new(3, 10);
        let call_count = Arc::new(AtomicU32::new(0));
        let cc = call_count.clone();

        let result = handler
            .execute_with_retry(move || {
                let count = cc.fetch_add(1, Ordering::SeqCst) + 1;
                async move {
                    if count < 3 {
                        Err(ChatError::NetworkError {
                            message: "timeout".into(),
                        })
                    } else {
                        Ok(42)
                    }
                }
            })
            .await;

        assert_eq!(result.unwrap(), 42);
        assert_eq!(call_count.load(Ordering::SeqCst), 3);
    }

    #[tokio::test]
    async fn test_retry_all_fail_returns_last_error() {
        let handler = RetryHandler::new(2, 10);
        let call_count = Arc::new(AtomicU32::new(0));
        let cc = call_count.clone();

        let result = handler
            .execute_with_retry(move || {
                cc.fetch_add(1, Ordering::SeqCst);
                async {
                    Err::<i32, ChatError>(ChatError::NetworkError {
                        message: "fail".into(),
                    })
                }
            })
            .await;

        assert!(result.is_err());
        // 1 initial + 2 retries = 3 total calls
        assert_eq!(call_count.load(Ordering::SeqCst), 3);
    }

    #[tokio::test]
    async fn test_retry_non_retryable_returns_immediately() {
        let handler = RetryHandler::new(3, 10);
        let call_count = Arc::new(AtomicU32::new(0));
        let cc = call_count.clone();

        let result = handler
            .execute_with_retry(move || {
                cc.fetch_add(1, Ordering::SeqCst);
                async {
                    Err::<i32, ChatError>(ChatError::ValidationError {
                        message: "bad input".into(),
                    })
                }
            })
            .await;

        assert!(result.is_err());
        // Should only be called once — no retries for ValidationError
        assert_eq!(call_count.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn test_retry_storage_error_not_retried() {
        let handler = RetryHandler::new(3, 10);
        let call_count = Arc::new(AtomicU32::new(0));
        let cc = call_count.clone();

        let result = handler
            .execute_with_retry(move || {
                cc.fetch_add(1, Ordering::SeqCst);
                async {
                    Err::<i32, ChatError>(ChatError::StorageError {
                        message: "disk full".into(),
                    })
                }
            })
            .await;

        assert!(result.is_err());
        assert_eq!(call_count.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn test_retry_rate_limit_waits_retry_after() {
        let handler = RetryHandler::new(1, 10);
        let call_count = Arc::new(AtomicU32::new(0));
        let cc = call_count.clone();

        let start = tokio::time::Instant::now();
        let result = handler
            .execute_with_retry(move || {
                let count = cc.fetch_add(1, Ordering::SeqCst) + 1;
                async move {
                    if count == 1 {
                        Err(ChatError::RateLimitError { retry_after_secs: 1 })
                    } else {
                        Ok(99)
                    }
                }
            })
            .await;

        let elapsed = start.elapsed();
        assert_eq!(result.unwrap(), 99);
        // Should have waited ~1 second for the rate limit
        assert!(elapsed >= Duration::from_millis(900));
    }

    #[tokio::test]
    async fn test_retry_success_transparent() {
        // Requirement 7.5: when retry succeeds, result is identical to direct success
        let handler = RetryHandler::new(3, 10);
        let cc = Arc::new(AtomicU32::new(0));
        let cc2 = cc.clone();

        let retried_result = handler
            .execute_with_retry(move || {
                let count = cc2.fetch_add(1, Ordering::SeqCst) + 1;
                async move {
                    if count < 2 {
                        Err(ChatError::NetworkError { message: "err".into() })
                    } else {
                        Ok("hello".to_string())
                    }
                }
            })
            .await;

        assert_eq!(retried_result.unwrap(), "hello".to_string());
    }
}
