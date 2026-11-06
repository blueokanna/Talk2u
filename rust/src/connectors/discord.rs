use std::fs;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde::{Deserialize, Serialize};

use crate::api::chat_engine::ChatEngine;
use crate::api::config_manager::ConfigManager;
use crate::api::conversation_store::ConversationStore;
use crate::api::data_models::{ChatStreamEvent, Message, MessageRole, MessageType};
use crate::api::provider::ProviderRuntime;
use courierust::courierust_http::method::Method;

const DISCORD_API: &str = "https://discord.com/api/v10";
const DEFAULT_POLL_INTERVAL_SECS: u64 = 3;

#[derive(Debug, Deserialize)]
struct DiscordAuthor {
    id: String,
    username: String,
    #[serde(default)]
    global_name: Option<String>,
    #[serde(default)]
    bot: bool,
}

#[derive(Debug, Deserialize)]
struct DiscordMessage {
    id: String,
    content: String,
    author: DiscordAuthor,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct PendingReply {
    chunks: Vec<String>,
    next_chunk: usize,
}

#[derive(Debug, Serialize, Deserialize)]
struct BridgeState {
    conversation_id: String,
    after_message_id: String,
    #[serde(default)]
    pending_reply: Option<PendingReply>,
}

pub struct DiscordBridge {
    data_path: PathBuf,
    channel_id: String,
    token: String,
    provider_id: Option<String>,
    model: Option<String>,
    conversation_override: Option<String>,
    system_prompt: Option<String>,
    enable_thinking: Option<bool>,
    poll_interval: Duration,
    http_timeout: Duration,
}

impl DiscordBridge {
    pub fn from_environment(
        data_path: impl Into<PathBuf>,
        channel_id: impl Into<String>,
        conversation_override: Option<String>,
    ) -> Result<Self, String> {
        let channel_id = channel_id.into();
        if channel_id.is_empty()
            || !channel_id
                .chars()
                .all(|character| character.is_ascii_digit())
        {
            return Err("Discord channel ID must contain digits only".to_string());
        }
        let token = std::env::var("TALK2U_DISCORD_TOKEN")
            .map_err(|_| "TALK2U_DISCORD_TOKEN is not set".to_string())?;
        if token.trim().is_empty() {
            return Err("TALK2U_DISCORD_TOKEN is empty".to_string());
        }
        let poll_interval_secs = std::env::var("TALK2U_DISCORD_POLL_SECONDS")
            .ok()
            .and_then(|value| value.parse::<u64>().ok())
            .unwrap_or(DEFAULT_POLL_INTERVAL_SECS)
            .clamp(2, 60);
        let enable_thinking = std::env::var("TALK2U_DISCORD_ENABLE_THINKING")
            .ok()
            .and_then(|value| match value.trim().to_ascii_lowercase().as_str() {
                "1" | "true" | "yes" => Some(true),
                "0" | "false" | "no" => Some(false),
                _ => None,
            });
        Ok(Self {
            data_path: data_path.into(),
            channel_id,
            token,
            provider_id: std::env::var("TALK2U_DISCORD_PROVIDER").ok(),
            model: std::env::var("TALK2U_DISCORD_MODEL").ok(),
            conversation_override,
            system_prompt: std::env::var("TALK2U_DISCORD_SYSTEM_PROMPT").ok(),
            enable_thinking,
            poll_interval: Duration::from_secs(poll_interval_secs),
            http_timeout: Duration::from_secs(60),
        })
    }

    pub async fn run(self) -> Result<(), String> {
        fs::create_dir_all(&self.data_path).map_err(|error| error.to_string())?;
        let mut state = self.load_or_create_state().await?;
        println!(
            "[{}] Discord bridge ready: channel={}, conversation={}",
            crate::api::clock::format_utc(crate::api::clock::now_millis()),
            self.channel_id,
            state.conversation_id
        );

        loop {
            if let Err(error) = self.poll_once(&mut state).await {
                eprintln!(
                    "[{}] Discord bridge poll failed: {error}",
                    crate::api::clock::format_utc(crate::api::clock::now_millis())
                );
            }
            tokio::time::sleep(self.poll_interval).await;
        }
    }

    async fn load_or_create_state(&self) -> Result<BridgeState, String> {
        let state_path = self.state_path();
        if let Ok(contents) = fs::read_to_string(&state_path) {
            if let Ok(mut state) = serde_json::from_str::<BridgeState>(&contents) {
                if let Some(conversation_id) = &self.conversation_override {
                    state.conversation_id = conversation_id.clone();
                    self.ensure_conversation(&state.conversation_id)?;
                    self.save_state(&state)?;
                } else if self.ensure_conversation(&state.conversation_id).is_err() {
                    state.conversation_id = self.create_conversation()?;
                    self.save_state(&state)?;
                }
                return Ok(state);
            }
        }

        let conversation_id = if let Some(id) = &self.conversation_override {
            self.ensure_conversation(id)?;
            id.clone()
        } else {
            self.create_conversation()?
        };
        let latest = self.fetch_messages(None, 1).await?;
        let after_message_id = latest
            .iter()
            .max_by_key(|message| snowflake_value(&message.id))
            .map(|message| message.id.clone())
            .unwrap_or_else(current_discord_snowflake);
        let state = BridgeState {
            conversation_id,
            after_message_id,
            pending_reply: None,
        };
        self.save_state(&state)?;
        Ok(state)
    }

    async fn poll_once(&self, state: &mut BridgeState) -> Result<(), String> {
        self.flush_pending_reply(state).await?;
        let mut messages = self
            .fetch_messages(Some(&state.after_message_id), 50)
            .await?;
        messages.sort_by_key(|message| snowflake_value(&message.id));

        for message in messages {
            if message.author.bot || message.content.trim().is_empty() {
                state.after_message_id = message.id;
                self.save_state(state)?;
                continue;
            }
            let display_name = message
                .author
                .global_name
                .as_deref()
                .unwrap_or(&message.author.username);
            let input = format!("Discord 用户 {display_name}: {}", message.content.trim());
            let response = self.generate_reply(&state.conversation_id, &input).await?;
            state.after_message_id = message.id;
            state.pending_reply = Some(PendingReply {
                chunks: split_discord_content(&response, 1850),
                next_chunk: 0,
            });
            self.save_state(state)?;
            self.flush_pending_reply(state).await?;
            println!(
                "Replied to Discord user {} ({})",
                display_name, message.author.id
            );
        }
        Ok(())
    }

    async fn generate_reply(&self, conversation_id: &str, input: &str) -> Result<String, String> {
        let settings =
            ConfigManager::new(self.data_path.to_string_lossy().as_ref()).load_settings();
        let provider_id = self
            .provider_id
            .as_deref()
            .unwrap_or(&settings.selected_provider);
        let (runtime, provider) = ProviderRuntime::from_settings(&settings, provider_id)?;
        let chat_model = self
            .model
            .as_deref()
            .filter(|value| !value.trim().is_empty())
            .unwrap_or(&provider.chat_model);
        let thinking_model = provider
            .thinking_model
            .as_deref()
            .unwrap_or(&provider.chat_model);
        let enable_thinking = self
            .enable_thinking
            .unwrap_or(settings.enable_thinking_by_default)
            && provider.thinking_model.is_some();
        let engine = ChatEngine::new(
            runtime,
            provider.chat_model.clone(),
            self.data_path.to_string_lossy().as_ref(),
        );
        let stream_error = Arc::new(Mutex::new(None::<String>));
        let error_slot = Arc::clone(&stream_error);
        engine
            .send_message(
                conversation_id,
                input,
                chat_model,
                thinking_model,
                enable_thinking,
                move |event| {
                    if let ChatStreamEvent::Error(message) = event {
                        if message != "__RETRY_RESET__" {
                            if let Ok(mut slot) = error_slot.lock() {
                                *slot = Some(message);
                            }
                        }
                    }
                },
            )
            .await
            .map_err(|error| error.to_string())?;

        let conversation = ConversationStore::new(self.data_path.to_string_lossy().as_ref())
            .load_conversation(conversation_id)
            .map_err(|error| error.to_string())?;
        if let Some(reply) = conversation
            .messages
            .last()
            .filter(|message| message.role == MessageRole::Assistant)
            .map(|message| message.content.trim())
            .filter(|content| !content.is_empty())
        {
            return Ok(reply.to_string());
        }
        let error = stream_error
            .lock()
            .ok()
            .and_then(|slot| slot.clone())
            .unwrap_or_else(|| "AI returned an empty response".to_string());
        Err(error)
    }

    async fn fetch_messages(
        &self,
        after: Option<&str>,
        limit: usize,
    ) -> Result<Vec<DiscordMessage>, String> {
        let mut query = format!("?limit={limit}");
        if let Some(after) = after.filter(|value| is_snowflake_cursor(value)) {
            query.push_str("&after=");
            query.push_str(after);
        }
        let url = format!("{DISCORD_API}/channels/{}/messages{query}", self.channel_id);
        let (status, body) = self.request(Method::GET, url, None).await?;
        if !(200..300).contains(&status) {
            return Err(format!("Discord API {status}: {}", truncate(&body, 500)));
        }
        serde_json::from_str::<Vec<DiscordMessage>>(&body).map_err(|error| error.to_string())
    }

    /// One buffered call through the shared transport. The transport blocks, so
    /// it is pushed onto the blocking pool instead of stalling a worker thread.
    async fn request(
        &self,
        method: Method,
        url: String,
        body: Option<serde_json::Value>,
    ) -> Result<(u16, String), String> {
        let headers = crate::api::transport::headers_from_pairs([
            ("authorization", format!("Bot {}", self.token)),
            ("user-agent", "Talk2U-Discord-Bridge/1.0".to_string()),
            ("content-type", "application/json".to_string()),
        ])
        .map_err(|error| error.to_string())?;
        let payload = match body {
            Some(value) => serde_json::to_vec(&value).map_err(|error| error.to_string())?,
            None => Vec::new(),
        };
        let timeout = self.http_timeout;
        tokio::task::spawn_blocking(move || {
            crate::api::transport::send_buffered(method, &url, headers, payload, timeout)
                .map_err(|error| error.to_string())
        })
        .await
        .map_err(|error| error.to_string())?
    }

    async fn flush_pending_reply(&self, state: &mut BridgeState) -> Result<(), String> {
        while let Some(pending) = state.pending_reply.as_mut() {
            if pending.next_chunk >= pending.chunks.len() {
                state.pending_reply = None;
                self.save_state(state)?;
                break;
            }
            let content = pending.chunks[pending.next_chunk].clone();
            let url = format!("{DISCORD_API}/channels/{}/messages", self.channel_id);
            let (status, body) = self
                .request(
                    Method::POST,
                    url,
                    Some(serde_json::json!({
                        "content": content,
                        "allowed_mentions": {"parse": []}
                    })),
                )
                .await?;
            if !(200..300).contains(&status) {
                return Err(format!("Discord API {status}: {}", truncate(&body, 500)));
            }
            pending.next_chunk += 1;
            self.save_state(state)?;
        }
        Ok(())
    }

    fn create_conversation(&self) -> Result<String, String> {
        let store = ConversationStore::new(self.data_path.to_string_lossy().as_ref());
        let mut conversation = store.create_conversation();
        conversation.title = format!("Discord {}", self.channel_id);
        if let Some(prompt) = self
            .system_prompt
            .as_deref()
            .filter(|value| !value.trim().is_empty())
        {
            conversation.messages.push(Message {
                id: uuid::Uuid::new_v4().to_string(),
                role: MessageRole::System,
                content: prompt.trim().to_string(),
                thinking_content: None,
                model: "system".to_string(),
                timestamp: crate::api::clock::now_millis(),
                message_type: MessageType::Say,
            });
        }
        store
            .save_conversation(&conversation)
            .map_err(|error| error.to_string())?;
        Ok(conversation.id)
    }

    fn ensure_conversation(&self, conversation_id: &str) -> Result<(), String> {
        ConversationStore::new(self.data_path.to_string_lossy().as_ref())
            .load_conversation(conversation_id)
            .map(|_| ())
            .map_err(|error| error.to_string())
    }

    fn state_path(&self) -> PathBuf {
        self.data_path
            .join(format!("discord_bridge_{}.json", self.channel_id))
    }

    fn save_state(&self, state: &BridgeState) -> Result<(), String> {
        let json = serde_json::to_string_pretty(state).map_err(|error| error.to_string())?;
        fs::write(self.state_path(), json).map_err(|error| error.to_string())
    }
}

fn is_snowflake_cursor(value: &str) -> bool {
    !value.is_empty() && value.len() <= 20 && value.bytes().all(|byte| byte.is_ascii_digit())
}

fn truncate(value: &str, limit: usize) -> String {
    value.chars().take(limit).collect()
}

fn snowflake_value(value: &str) -> u128 {
    value.parse().unwrap_or(0)
}

fn current_discord_snowflake() -> String {
    const DISCORD_EPOCH_MILLIS: i64 = 1_420_070_400_000;
    let elapsed = (crate::api::clock::now_millis() - DISCORD_EPOCH_MILLIS).max(0);
    ((elapsed as u128) << 22).to_string()
}

fn split_discord_content(content: &str, max_chars: usize) -> Vec<String> {
    let max_chars = max_chars.max(1);
    let characters = content.chars().collect::<Vec<_>>();
    if characters.is_empty() {
        return vec!["(empty response)".to_string()];
    }
    let mut chunks = characters
        .chunks(max_chars)
        .map(|chunk| chunk.iter().collect::<String>())
        .collect::<Vec<_>>();
    if chunks.len() > 1 {
        let total = chunks.len();
        for (index, chunk) in chunks.iter_mut().enumerate() {
            *chunk = format!("[{}/{}] {}", index + 1, total, chunk);
        }
    }
    chunks
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_unicode_without_breaking_characters() {
        let chunks = split_discord_content("你好abc", 2);
        assert_eq!(chunks, vec!["[1/3] 你好", "[2/3] ab", "[3/3] c"]);
    }

    #[test]
    fn empty_response_has_visible_fallback() {
        assert_eq!(split_discord_content("", 100), vec!["(empty response)"]);
    }

    #[test]
    fn generated_cursor_is_a_valid_positive_snowflake() {
        assert!(snowflake_value(&current_discord_snowflake()) > 0);
    }

    #[test]
    fn only_numeric_cursors_reach_the_query_string() {
        assert!(is_snowflake_cursor("1183573619123380224"));
        assert!(!is_snowflake_cursor("1183573619123380224&limit=100"));
        assert!(!is_snowflake_cursor(""));
        assert!(!is_snowflake_cursor("../../etc/passwd"));
        assert!(!is_snowflake_cursor("123456789012345678901"));
    }
}
