use std::fs;
use std::path::PathBuf;

use flutter_rust_bridge::frb;

use super::data_models::*;
use super::error_handler::ChatError;
#[frb(opaque)]
pub struct ConversationStore {
    pub base_path: String,
}

impl ConversationStore {
    pub fn new(base_path: &str) -> Self {
        Self {
            base_path: base_path.to_string(),
        }
    }

    fn conversations_dir(&self) -> Result<PathBuf, ChatError> {
        let dir = PathBuf::from(&self.base_path).join("conversations");
        if !dir.exists() {
            fs::create_dir_all(&dir).map_err(|e| ChatError::StorageError {
                message: format!("Failed to create conversations directory: {}", e),
            })?;
        }
        Ok(dir)
    }

    fn conversation_path(&self, id: &str) -> Result<PathBuf, ChatError> {
        super::storage_path::validate_storage_id(id)?;
        Ok(self.conversations_dir()?.join(format!("{}.t2ub", id)))
    }

    /// Reads a conversation, migrating legacy encodings in place.
    ///
    /// New writes always use the rustbinary envelope. Files from earlier
    /// builds (`.msgpack`, and the oldest `.json`) are still readable and are
    /// rewritten on first touch, so an upgrade never strands a conversation.
    fn read_conversation(&self, id: &str) -> Result<Conversation, ChatError> {
        super::storage_path::validate_storage_id(id)?;
        let dir = self.conversations_dir()?;
        let binary = dir.join(format!("{id}.t2ub"));
        if binary.exists() {
            let bytes = fs::read(&binary).map_err(|error| ChatError::StorageError {
                message: format!("Failed to read conversation file '{id}': {error}"),
            })?;
            return super::storage_codec::decode(&bytes);
        }

        let msgpack = dir.join(format!("{id}.msgpack"));
        if msgpack.exists() {
            let bytes = fs::read(&msgpack).map_err(|error| ChatError::StorageError {
                message: format!("Failed to read legacy conversation '{id}': {error}"),
            })?;
            let conversation: Conversation =
                rmp_serde::from_slice(&bytes).map_err(|error| ChatError::StorageError {
                    message: format!("Failed to decode legacy conversation '{id}': {error}"),
                })?;
            self.save_conversation(&conversation)?;
            let _ = fs::remove_file(&msgpack);
            return Ok(conversation);
        }

        let json = dir.join(format!("{id}.json"));
        if json.exists() {
            let text = fs::read_to_string(&json).map_err(|error| ChatError::StorageError {
                message: format!("Failed to read json conversation '{id}': {error}"),
            })?;
            let conversation: Conversation =
                serde_json::from_str(&text).map_err(|error| ChatError::StorageError {
                    message: format!("Failed to parse json conversation '{id}': {error}"),
                })?;
            self.save_conversation(&conversation)?;
            let _ = fs::remove_file(&json);
            return Ok(conversation);
        }

        Err(ChatError::StorageError {
            message: format!("Conversation '{id}' does not exist"),
        })
    }

    pub fn create_conversation(&self) -> Conversation {
        let now = crate::api::clock::now_millis();
        Conversation {
            id: uuid::Uuid::new_v4().to_string(),
            title: String::new(),
            messages: Vec::new(),
            model: "glm-4.7".to_string(),
            created_at: now,
            updated_at: now,
            dialogue_style: DialogueStyle::default(),
            turn_count: 0,
            memory_summaries: Vec::new(),
        }
    }

    pub fn save_conversation(&self, conversation: &Conversation) -> Result<(), ChatError> {
        let path = self.conversation_path(&conversation.id)?;
        let data = super::storage_codec::encode(conversation)?;
        // Write-and-rename: a crash mid-write leaves the previous file intact
        // instead of a truncated conversation.
        let staging = path.with_extension("t2ub.tmp");
        fs::write(&staging, data).map_err(|error| ChatError::StorageError {
            message: format!("Failed to write conversation file: {error}"),
        })?;
        fs::rename(&staging, &path).map_err(|error| ChatError::StorageError {
            message: format!("Failed to commit conversation file: {error}"),
        })
    }

    pub fn load_conversation(&self, id: &str) -> Result<Conversation, ChatError> {
        self.read_conversation(id)
    }

    pub fn list_conversations(&self) -> Vec<ConversationSummary> {
        let dir = match self.conversations_dir() {
            Ok(d) => d,
            Err(_) => return Vec::new(),
        };

        let entries = match fs::read_dir(&dir) {
            Ok(e) => e,
            Err(_) => return Vec::new(),
        };

        let mut summaries: Vec<ConversationSummary> = entries
            .filter_map(|entry| {
                let entry = entry.ok()?;
                let path = entry.path();
                let ext = path.extension().and_then(|e| e.to_str())?;

                let conv: Conversation = match ext {
                    "t2ub" => {
                        let data = fs::read(&path).ok()?;
                        super::storage_codec::decode(&data).ok()?
                    }
                    "msgpack" => {
                        let data = fs::read(&path).ok()?;
                        rmp_serde::from_slice(&data).ok()?
                    }
                    "json" => {
                        let json = fs::read_to_string(&path).ok()?;
                        serde_json::from_str(&json).ok()?
                    }
                    _ => return None,
                };

                let last_message_preview = conv
                    .messages
                    .last()
                    .map(|m| m.content.chars().take(50).collect::<String>())
                    .unwrap_or_default();

                Some(ConversationSummary {
                    id: conv.id,
                    title: conv.title,
                    last_message_preview,
                    model: conv.model,
                    updated_at: conv.updated_at,
                })
            })
            .collect();

        summaries.sort_by(|a, b| b.updated_at.cmp(&a.updated_at));
        summaries
    }

    pub fn delete_conversation(&self, id: &str) -> Result<(), ChatError> {
        let path = self.conversation_path(id)?;
        let dir = self.conversations_dir()?;
        for name in [
            format!("{id}.json"),
            format!("{id}.msgpack"),
            format!("{id}.t2ub.tmp"),
        ] {
            let _ = fs::remove_file(dir.join(name));
        }

        if path.exists() {
            fs::remove_file(&path).map_err(|e| ChatError::StorageError {
                message: format!("Failed to delete conversation '{}': {}", id, e),
            })
        } else {
            Ok(())
        }
    }

    pub fn add_message(&self, conversation_id: &str, message: Message) -> Result<(), ChatError> {
        let mut conv = self.load_conversation(conversation_id)?;

        if conv.title.is_empty() && message.role == MessageRole::User {
            let title: String = message.content.chars().take(20).collect();
            conv.title = title;
        }

        conv.messages.push(message);
        conv.updated_at = crate::api::clock::now_millis();
        self.save_conversation(&conv)
    }

    pub fn delete_message(&self, conversation_id: &str, message_id: &str) -> Result<(), ChatError> {
        let mut conv = self.load_conversation(conversation_id)?;
        let original_len = conv.messages.len();
        conv.messages.retain(|m| m.id != message_id);
        if conv.messages.len() == original_len {
            return Err(ChatError::StorageError {
                message: format!("Message '{}' not found", message_id),
            });
        }
        conv.updated_at = crate::api::clock::now_millis();
        self.save_conversation(&conv)
    }

    pub fn increment_turn_count(&self, conversation_id: &str) -> Result<(), ChatError> {
        let mut conv = self.load_conversation(conversation_id)?;
        conv.turn_count += 1;
        self.save_conversation(&conv)
    }

    pub fn update_memory_summaries(
        &self,
        conversation_id: &str,
        summaries: &[MemorySummary],
    ) -> Result<(), ChatError> {
        let mut conv = self.load_conversation(conversation_id)?;
        conv.memory_summaries = summaries.to_vec();
        conv.updated_at = crate::api::clock::now_millis();
        self.save_conversation(&conv)
    }

    pub fn edit_message(
        &self,
        conversation_id: &str,
        message_id: &str,
        new_content: &str,
    ) -> Result<(), ChatError> {
        let mut conv = self.load_conversation(conversation_id)?;
        let found = conv.messages.iter_mut().find(|m| m.id == message_id);
        match found {
            Some(msg) => {
                msg.content = new_content.to_string();
                msg.timestamp = crate::api::clock::now_millis();
                conv.updated_at = crate::api::clock::now_millis();
                self.save_conversation(&conv)
            }
            None => Err(ChatError::StorageError {
                message: format!("Message '{}' not found", message_id),
            }),
        }
    }

    pub fn rollback_to_message(
        &self,
        conversation_id: &str,
        message_id: &str,
    ) -> Result<Vec<String>, ChatError> {
        let mut conv = self.load_conversation(conversation_id)?;
        let pos = conv
            .messages
            .iter()
            .position(|m| m.id == message_id)
            .ok_or_else(|| ChatError::StorageError {
                message: format!("Message '{}' not found", message_id),
            })?;
        let deleted_ids: Vec<String> = conv.messages[pos..].iter().map(|m| m.id.clone()).collect();
        conv.messages.truncate(pos);
        conv.updated_at = crate::api::clock::now_millis();
        self.save_conversation(&conv)?;
        Ok(deleted_ids)
    }

    pub fn set_dialogue_style(
        &self,
        conversation_id: &str,
        style: DialogueStyle,
    ) -> Result<(), ChatError> {
        let mut conv = self.load_conversation(conversation_id)?;
        conv.dialogue_style = style;
        conv.updated_at = crate::api::clock::now_millis();
        self.save_conversation(&conv)
    }

    pub fn get_turn_count(&self, conversation_id: &str) -> Result<u32, ChatError> {
        let conv = self.load_conversation(conversation_id)?;
        Ok(conv.turn_count)
    }
}
