use std::sync::OnceLock;
use std::time::Duration;

use courierust::courierust_body::Body;
use courierust::courierust_client::{Client, ClientConfig};
use courierust::courierust_error::ErrorKind;
use courierust::courierust_http::header::HeaderMap;
use courierust::courierust_http::method::Method;
use courierust::courierust_tls::RootStore;
use tokio::sync::mpsc;

use super::error_handler::ChatError;

const STREAM_BACKLOG: usize = 32;
const MAX_ERROR_BODY_BYTES: usize = 8 * 1024;

/// A streaming response delivered as raw byte frames.
///
/// The parser stays on the async side; this type only moves bytes and surfaces
/// transport failures, so SSE handling never depends on the HTTP library.
pub(crate) struct ByteStream {
    receiver: mpsc::Receiver<Result<Vec<u8>, ChatError>>,
}

impl ByteStream {
    pub(crate) async fn next(&mut self) -> Option<Result<Vec<u8>, ChatError>> {
        self.receiver.recv().await
    }
}

pub(crate) struct StreamRequest {
    pub url: String,
    pub headers: HeaderMap,
    pub body: Vec<u8>,
    pub read_timeout: Duration,
}

/// Sends `POST` and returns the response body as a byte stream.
pub(crate) async fn post_stream(request: StreamRequest) -> Result<ByteStream, ChatError> {
    let (sender, receiver) = mpsc::channel(STREAM_BACKLOG);
    tokio::task::spawn_blocking(move || {
        if let Err(error) = drive_request(request, &sender) {
            // The consumer may already be gone; a failed send only means the
            // reader dropped the stream, which discards the error on purpose.
            let _ = sender.blocking_send(Err(error));
        }
    });
    Ok(ByteStream { receiver })
}

/// Buffered request for callers that need the whole body, not a stream.
pub(crate) fn send_buffered(
    method: Method,
    url: &str,
    headers: HeaderMap,
    body: Vec<u8>,
    read_timeout: Duration,
) -> Result<(u16, String), ChatError> {
    let client = shared_client()?;
    let request = client.request(url, method).headers(headers);
    // A body-less request must not carry `Content-Length: 0`: some APIs treat a
    // body on `GET` as a malformed request.
    let request = if body.is_empty() {
        request
    } else {
        request.body(body)
    };
    let response = request.timeout(read_timeout).send().map_err(map_transport_error)?;
    let status = response.status.as_u16();
    let bytes = response
        .body
        .collect_limited(MAX_ERROR_BODY_BYTES * 64)
        .map_err(|error| ChatError::StreamError {
            message: format!("读取响应失败: {}", describe(&error)),
        })?;
    Ok((status, String::from_utf8_lossy(&bytes).into_owned()))
}

const MAX_ATTEMPTS: u32 = 4;

/// Whether another attempt is allowed, and how long to wait before it.
///
/// `None` means give up. Retrying is only safe while nothing has reached the
/// caller: once bytes were emitted a replay would duplicate content, and no
/// amount of backoff fixes that. A rate-limit hint from the server outranks the
/// local exponential schedule, clamped so a bogus header cannot park the app.
fn next_delay(attempt: u32, error: &ChatError, emitted: bool, delay: Duration) -> Option<Duration> {
    if emitted || !error.is_retryable() || attempt + 1 >= MAX_ATTEMPTS {
        return None;
    }
    match error {
        ChatError::RateLimitError { retry_after_secs } => {
            Some(Duration::from_secs((*retry_after_secs).clamp(1, 30)))
        }
        _ => Some(delay),
    }
}

fn drive_request(
    request: StreamRequest,
    sender: &mpsc::Sender<Result<Vec<u8>, ChatError>>,
) -> Result<(), ChatError> {
    let mut delay = Duration::from_millis(1_000);
    let mut last_error: Option<ChatError> = None;
    for attempt in 0..MAX_ATTEMPTS {
        let (emitted, outcome) = attempt_once(&request, sender);
        match outcome {
            Ok(()) => return Ok(()),
            Err(error) => match next_delay(attempt, &error, emitted, delay) {
                None => return Err(error),
                Some(wait) => {
                    std::thread::sleep(wait);
                    delay *= 2;
                    last_error = Some(error);
                }
            },
        }
    }
    Err(last_error.unwrap_or(ChatError::StreamError {
        message: "请求没有产生响应".to_string(),
    }))
}

fn attempt_once(
    request: &StreamRequest,
    sender: &mpsc::Sender<Result<Vec<u8>, ChatError>>,
) -> (bool, Result<(), ChatError>) {
    let client = match shared_client() {
        Ok(client) => client,
        Err(error) => return (false, Err(error)),
    };
    let response = match client
        .request(&request.url, Method::POST)
        .headers(request.headers.clone())
        .body(request.body.clone())
        .timeout(request.read_timeout)
        .send()
    {
        Ok(response) => response,
        Err(error) => return (false, Err(map_transport_error(error))),
    };

    let status = response.status.as_u16();
    match response.body {
        Body::Bytes(bytes) => {
            if !is_success(status) {
                return (
                    false,
                    Err(ChatError::from_http_error(
                        status,
                        &String::from_utf8_lossy(&bytes),
                    )),
                );
            }
            (true, send_frame(sender, bytes.to_vec()))
        }
        Body::Channel(chunks) => {
            if !is_success(status) {
                let mut text = String::new();
                while let Ok(chunk) = chunks.recv() {
                    let Ok(chunk) = chunk else { break };
                    if text.len() >= MAX_ERROR_BODY_BYTES {
                        break;
                    }
                    text.push_str(&String::from_utf8_lossy(&chunk));
                }
                return (
                    false,
                    Err(ChatError::from_http_error(status, &text)),
                );
            }
            let mut emitted = false;
            while let Ok(chunk) = chunks.recv() {
                let chunk = match chunk {
                    Ok(chunk) => chunk,
                    Err(error) => return (emitted, Err(map_transport_error(error))),
                };
                if chunk.is_empty() {
                    continue;
                }
                if let Err(error) = send_frame(sender, chunk.to_vec()) {
                    return (emitted, Err(error));
                }
                emitted = true;
            }
            (emitted, Ok(()))
        }
        _ => (
            false,
            Err(ChatError::StreamError {
                message: "服务器返回了无法读取的响应体".to_string(),
            }),
        ),
    }
}

fn send_frame(
    sender: &mpsc::Sender<Result<Vec<u8>, ChatError>>,
    frame: Vec<u8>,
) -> Result<(), ChatError> {
    sender.blocking_send(Ok(frame)).map_err(|_| ChatError::StreamError {
        message: "响应流已被使用者关闭".to_string(),
    })
}

fn is_success(status: u16) -> bool {
    (200..300).contains(&status)
}

fn shared_client() -> Result<&'static Client, ChatError> {
    static CLIENT: OnceLock<Result<Client, String>> = OnceLock::new();
    let cached = CLIENT.get_or_init(|| {
        let roots = trust_anchors().map_err(|error| error.to_string())?;
        Ok(Client::with_config(ClientConfig {
            http2: true,
            tls: Some(courierust::courierust_client::TlsSettings {
                roots,
                verify: true,
                alpn: vec![b"h2".to_vec(), b"http/1.1".to_vec()],
                now: crate::api::clock::now_millis() / 1000,
                ..Default::default()
            }),
            user_agent: Some("Talk2U/1.0 Courierust".to_string()),
            accept_encoding: true,
            ..Default::default()
        }))
    });
    match cached {
        Ok(client) => Ok(client),
        Err(message) => Err(ChatError::NetworkError {
            message: format!("TLS 信任库不可用: {message}"),
        }),
    }
}

/// Trust anchors for outbound HTTPS.
///
/// Android keeps its roots outside the Linux bundle layout the crate looks at,
/// and moving to the Conscrypt APEX on Android 14 means there are two
/// directories to try. Roots are read from the device, never vendored, so an
/// OS trust-store update takes effect without shipping a new APK.
#[cfg(target_os = "android")]
fn trust_anchors() -> Result<RootStore, ChatError> {
    const DIRECTORIES: [&str; 2] = [
        "/apex/com.android.conscrypt/cacerts",
        "/system/etc/security/cacerts",
    ];
    let mut store = RootStore::new();
    let mut added = 0usize;
    for directory in DIRECTORIES {
        let Ok(entries) = std::fs::read_dir(directory) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if !path.is_file() {
                continue;
            }
            let Ok(bytes) = std::fs::read(&path) else {
                continue;
            };
            match std::str::from_utf8(&bytes) {
                Ok(pem) if pem.contains("BEGIN CERTIFICATE") => {
                    added += store.add_pem(pem).unwrap_or(0);
                }
                _ => store.add_der(bytes),
            }
        }
        if added > 0 {
            return Ok(store);
        }
    }
    Err(ChatError::NetworkError {
        message: format!(
            "未能从 {} 读取系统 CA，拒绝在无法验证证书的情况下发起 HTTPS",
            DIRECTORIES.join(" 或 ")
        ),
    })
}

#[cfg(not(target_os = "android"))]
fn trust_anchors() -> Result<RootStore, ChatError> {
    let mut store = RootStore::new();
    store
        .load_system()
        .map_err(|error| ChatError::NetworkError {
            message: format!("未能读取系统 CA: {error:?}"),
        })?;
    Ok(store)
}

pub(crate) fn map_transport_error(error: courierust::courierust_error::Error) -> ChatError {
    let detail = describe(&error);
    match error.kind {
        ErrorKind::Timeout => ChatError::NetworkError {
            message: format!("连接超时，请检查网络后重试: {detail}"),
        },
        ErrorKind::Io => ChatError::NetworkError {
            message: format!("无法连接到 AI 服务器，请检查网络: {detail}"),
        },
        ErrorKind::UnexpectedEof | ErrorKind::Canceled => ChatError::StreamError {
            message: format!("数据流在传输中断开: {detail}"),
        },
        _ => ChatError::StreamError {
            message: format!("网络请求失败: {detail}"),
        },
    }
}

fn describe(error: &courierust::courierust_error::Error) -> String {
    match &error.message {
        Some(message) => message.to_string(),
        None => format!("{:?}", error.kind),
    }
}

/// Header map from plain pairs, rejecting control characters.
pub(crate) fn headers_from_pairs(
    pairs: impl IntoIterator<Item = (&'static str, String)>,
) -> Result<HeaderMap, ChatError> {
    let mut headers = HeaderMap::new();
    for (name, value) in pairs {
        if value.contains('\r') || value.contains('\n') {
            return Err(ChatError::AuthError {
                message: format!("请求头 {name} 包含换行，已拒绝"),
            });
        }
        headers.insert(
            courierust::courierust_http::header::HeaderName::from_static(name),
            courierust::courierust_http::header::HeaderValue::from_bytes(value.as_bytes()).map_err(
                |error| ChatError::AuthError {
                    message: format!("请求头 {name} 的值无效: {error:?}"),
                },
            )?,
        );
    }
    Ok(headers)
}

/// Strict URL check for user-supplied provider endpoints.
///
/// Rejects anything that is not an absolute `http(s)` URL with a host, which is
/// what the client needs and what keeps a pasted endpoint from smuggling
/// credentials or a non-HTTP scheme into the request.
pub(crate) fn validate_http_url(value: &str) -> Result<String, String> {
    let trimmed = value.trim();
    let parsed = courierust::courierust_http::uri::Url::parse(trimmed)
        .map_err(|error| format!("URL 无效: {error:?}"))?;
    if parsed.scheme != "http" && parsed.scheme != "https" {
        return Err(format!("URL 必须是 HTTP(S) 地址，实际为 {}://", parsed.scheme));
    }
    if parsed.host.is_empty() {
        return Err("URL 缺少主机名".to_string());
    }
    Ok(trimmed.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_absolute_http_urls() {
        assert!(validate_http_url("https://open.bigmodel.cn/api/paas/v4/chat/completions").is_ok());
        assert!(validate_http_url("http://192.168.1.10:8080/v1/chat").is_ok());
    }

    #[test]
    fn rejects_relative_and_non_http_urls() {
        for value in [
            "",
            "not a url",
            "/v1/chat",
            "ftp://example.com/x",
            "file:///etc/passwd",
        ] {
            assert!(validate_http_url(value).is_err(), "accepted {value:?}");
        }
    }

    fn transient() -> ChatError {
        ChatError::NetworkError {
            message: "connection reset".into(),
        }
    }

    #[test]
    fn backs_off_while_nothing_has_been_emitted() {
        let delay = Duration::from_millis(1_000);
        assert_eq!(next_delay(0, &transient(), false, delay), Some(delay));
        assert_eq!(next_delay(1, &transient(), false, delay), Some(delay));
    }

    #[test]
    fn gives_up_at_the_attempt_cap() {
        let delay = Duration::from_millis(1_000);
        assert_eq!(next_delay(MAX_ATTEMPTS - 1, &transient(), false, delay), None);
    }

    #[test]
    fn never_replays_after_bytes_reached_the_caller() {
        let delay = Duration::from_millis(1_000);
        assert_eq!(next_delay(0, &transient(), true, delay), None);
    }

    #[test]
    fn does_not_retry_client_errors() {
        let delay = Duration::from_millis(1_000);
        let invalid = ChatError::ApiError {
            status: 400,
            message: "bad request".into(),
        };
        assert_eq!(next_delay(0, &invalid, false, delay), None);
    }

    #[test]
    fn honours_the_rate_limit_hint_within_bounds() {
        let delay = Duration::from_millis(1_000);
        let hint = |secs| ChatError::RateLimitError {
            retry_after_secs: secs,
        };
        assert_eq!(
            next_delay(0, &hint(5), false, delay),
            Some(Duration::from_secs(5))
        );
        assert_eq!(
            next_delay(0, &hint(9_000), false, delay),
            Some(Duration::from_secs(30))
        );
        assert_eq!(
            next_delay(0, &hint(0), false, delay),
            Some(Duration::from_secs(1))
        );
    }

    /// Proves the whole outbound path — trust anchors, TLS, HTTP framing — not
    /// just the parser. Any HTTP status proves the handshake worked, so the
    /// assertion is on a range, not on a particular response code. Needs
    /// network, so it is opt-in:
    /// `cargo test --lib -- --ignored courierust_completes_a_tls_request`
    #[test]
    #[ignore]
    fn courierust_completes_a_tls_request() {
        let headers = headers_from_pairs([("accept", "text/plain".to_string())]).unwrap();
        let (status, body) = send_buffered(
            Method::GET,
            "https://open.bigmodel.cn/",
            headers,
            Vec::new(),
            Duration::from_secs(20),
        )
        .expect("request failed");
        println!("status={status} bytes={}", body.len());
        assert!((200..500).contains(&status), "unexpected status {status}");
    }

    /// The property every provider depends on: a frame reaches the parser while
    /// the server is still holding the response open.
    ///
    /// The server sends one frame, then waits for this test to confirm receipt
    /// before sending the second. A transport that buffered the body until EOF
    /// would deadlock here and fail on the timeout instead of passing by luck —
    /// which is why the assertion is a handshake and not a wall-clock estimate.
    #[tokio::test]
    async fn frames_arrive_before_the_response_is_complete() {
        use courierust::courierust_body::Body as ServerBody;
        use courierust::courierust_http::header::{HeaderName, HeaderValue};
        use courierust::courierust_http::request::Request;
        use courierust::courierust_http::response::Response;
        use courierust::courierust_server::{Server, ServerConfig};
        use courierust::Bytes;
        use std::sync::mpsc::{channel, RecvTimeoutError};
        use std::sync::{Arc, Mutex};

        let (received_first, first_was_received) = channel::<()>();
        // `Handler` must be `Sync` and may be invoked more than once, so the
        // signal channel is shared behind a lock instead of being captured.
        let first_was_received = Arc::new(Mutex::new(first_was_received));
        let server = Server::bind_with_config(
            "127.0.0.1:0",
            ServerConfig {
                http2: true,
                ..ServerConfig::default()
            },
        )
        .expect("bind loopback");
        let address = server.local_addr().expect("local addr");

        let handle = server
            .serve_background(move |_request: Request<ServerBody>| -> Response<ServerBody> {
                let (sender, body) = courierust::courierust_body::channel();
                let signal = Arc::clone(&first_was_received);
                std::thread::spawn(move || {
                    if sender
                        .send(Bytes::from_static(b"data: {\"n\":1}\n\n"))
                        .is_err()
                    {
                        return;
                    }
                    // Blocks until the client proves it saw frame one; on a
                    // buffering transport nothing is ever sent afterwards.
                    let waiting = signal.lock().map(|rx| rx.recv_timeout(Duration::from_secs(5)));
                    match waiting.unwrap_or(Err(RecvTimeoutError::Disconnected)) {
                        Ok(()) => {
                            let _ = sender
                                .send(Bytes::from_static(b"data: [DONE]\n\n"));
                        }
                        Err(RecvTimeoutError::Timeout) => {}
                        Err(RecvTimeoutError::Disconnected) => {}
                    }
                });
                let mut response = Response::with_status(200.into());
                response.headers.insert(
                    HeaderName::from_static("content-type"),
                    HeaderValue::from_static("text/event-stream"),
                );
                response.body = body;
                response
            })
            .expect("serve");

        let mut stream = post_stream(StreamRequest {
            url: format!("http://{address}/v1/chat/completions"),
            headers: headers_from_pairs([("content-type", "application/json".to_string())])
                .expect("headers"),
            body: b"{}".to_vec(),
            read_timeout: Duration::from_secs(10),
        })
        .await
        .expect("stream opens");

        let first = tokio::time::timeout(Duration::from_secs(5), stream.next())
            .await
            .expect("first frame timed out")
            .expect("stream ended early")
            .expect("first frame failed");
        assert_eq!(String::from_utf8_lossy(&first), "data: {\"n\":1}\n\n");

        received_first.send(()).expect("server still waiting");

        let second = tokio::time::timeout(Duration::from_secs(5), stream.next())
            .await
            .expect("second frame timed out")
            .expect("stream ended early")
            .expect("second frame failed");
        assert_eq!(String::from_utf8_lossy(&second), "data: [DONE]\n\n");

        drop(stream);
        // `join` waits for the accept loop and the parked connection, which can
        // outlive the assertion; stopping the listener is what the test needs.
        handle.stop();
    }
}
