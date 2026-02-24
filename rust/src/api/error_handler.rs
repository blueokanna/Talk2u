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
        }
    }
}

impl std::error::Error for ChatError {}

impl ChatError {
    /// Returns true if this error type should be retried.
    /// Used by RetryHandler for automatic retry logic on transient failures.
    pub fn is_retryable(&self) -> bool {
        matches!(
            self,
            ChatError::NetworkError { .. }
                | ChatError::ApiError { .. }
                | ChatError::RateLimitError { .. }
        )
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
        assert!(ChatError::RateLimitError { retry_after_secs: 1 }.is_retryable());

        assert!(!ChatError::ValidationError { message: "bad".into() }.is_retryable());
        assert!(!ChatError::StorageError { message: "io".into() }.is_retryable());
        assert!(!ChatError::AuthError { message: "denied".into() }.is_retryable());
        assert!(!ChatError::StreamError { message: "broken".into() }.is_retryable());
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

        let direct_result: Result<String, ChatError> = Ok("hello".to_string());
        assert_eq!(retried_result.unwrap(), direct_result.unwrap());
    }
}
