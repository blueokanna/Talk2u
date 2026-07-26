use futures::StreamExt;
use rustglm::{ChatCompletionRequest, HttpConfig, ResponseContent, RetryPolicy, ZhipuConfig};

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let api_key = std::env::var("TALK2U_ZHIPU_API_KEY")?;
    let model = std::env::var("TALK2U_ZHIPU_MODEL").unwrap_or_else(|_| "glm-4.6".into());
    let endpoint = std::env::var("TALK2U_ZHIPU_URL")
        .unwrap_or_else(|_| "https://open.bigmodel.cn/api/paas/v4/chat/completions".into());
    let base_url = endpoint
        .trim()
        .trim_end_matches('/')
        .strip_suffix("/chat/completions")
        .unwrap_or(endpoint.trim().trim_end_matches('/'));

    let request: ChatCompletionRequest = serde_json::from_value(serde_json::json!({
        "model": model,
        "messages": [{"role": "user", "content": "Reply with OK."}],
        "stream": true,
        "max_tokens": 64
    }))?;
    let client = ZhipuConfig::new(api_key)
        .base_url(base_url)
        .http(HttpConfig {
            timeout: std::time::Duration::from_secs(90),
            connect_timeout: std::time::Duration::from_secs(30),
            retry: RetryPolicy::default(),
            ..HttpConfig::default()
        })
        .build()?;
    let mut stream = client.chat_completion_stream(&request).await?;
    let mut chunks = 0_u32;
    let mut text = String::new();
    let mut finish_reasons = Vec::new();

    while let Some(item) = stream.next().await {
        let chunk = item?;
        chunks += 1;
        for choice in chunk.choices {
            if let Some(content) = choice.delta.content {
                match content {
                    ResponseContent::Text(value) => text.push_str(&value),
                    ResponseContent::Parts(parts) => {
                        text.extend(parts.into_iter().filter_map(|part| part.text));
                    }
                }
            }
            if let Some(reason) = choice.finish_reason {
                finish_reasons.push(reason);
            }
        }
    }

    println!(
        "rustglm stream complete: chunks={chunks}, text_bytes={}, finish={:?}",
        text.len(),
        finish_reasons
    );
    if !text.is_empty() {
        println!("response={text}");
    }
    Ok(())
}
