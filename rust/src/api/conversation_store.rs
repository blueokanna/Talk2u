use std::fs;
use std::path::PathBuf;
use std::sync::{Mutex, MutexGuard};

// Engines and the API construct separate stores for the same files. Keep the
// entire read/modify/write transaction (including legacy migration) exclusive.
static CONVERSATION_IO: Mutex<()> = Mutex::new(());

fn lock_conversations() -> MutexGuard<'static, ()> {
    CONVERSATION_IO
        .lock()
        .unwrap_or_else(|error| error.into_inner())
}

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

    /// Tiny derived index next to the conversation.
    ///
    /// Listing a long chat must not decompress every message just to render a
    /// title and a 50-character preview. The cache is disposable: a missing or
    /// corrupt sidecar falls back to a full decode and is rewritten.
    fn summary_path(&self, id: &str) -> Result<PathBuf, ChatError> {
        super::storage_path::validate_storage_id(id)?;
        Ok(self.conversations_dir()?.join(format!("{}.t2ui", id)))
    }

    fn summary_of(conversation: &Conversation) -> ConversationSummary {
        ConversationSummary {
            id: conversation.id.clone(),
            title: conversation.title.clone(),
            last_message_preview: conversation
                .messages
                .last()
                .map(|message| message.content.chars().take(50).collect())
                .unwrap_or_default(),
            model: conversation.model.clone(),
            updated_at: conversation.updated_at,
        }
    }

    fn write_summary(&self, conversation: &Conversation) -> Result<(), ChatError> {
        let path = self.summary_path(&conversation.id)?;
        let data = serde_json::to_vec(&Self::summary_of(conversation)).map_err(|error| {
            ChatError::StorageError {
                message: format!("Failed to encode conversation summary: {error}"),
            }
        })?;
        let staging = path.with_extension("t2ui.tmp");
        fs::write(&staging, data).map_err(|error| ChatError::StorageError {
            message: format!("Failed to write conversation summary: {error}"),
        })?;
        fs::rename(&staging, &path).map_err(|error| ChatError::StorageError {
            message: format!("Failed to commit conversation summary: {error}"),
        })
    }

    fn read_summary(&self, id: &str) -> Option<ConversationSummary> {
        const MAX_SUMMARY_BYTES: u64 = 64 * 1024;
        let path = self.summary_path(id).ok()?;
        let length = fs::metadata(&path).ok()?.len();
        if length == 0 || length > MAX_SUMMARY_BYTES {
            return None;
        }
        let data = fs::read(path).ok()?;
        let summary: ConversationSummary = serde_json::from_slice(&data).ok()?;
        (summary.id == id).then_some(summary)
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
            let length = fs::metadata(&binary)
                .map_err(|error| ChatError::StorageError {
                    message: format!("Failed to stat conversation file '{id}': {error}"),
                })?
                .len();
            if length > super::storage_codec::MAX_DOCUMENT_BYTES {
                return Err(ChatError::StorageError {
                    message: format!(
                        "Conversation '{id}' is {length} bytes, above the supported limit"
                    ),
                });
            }
            let bytes = fs::read(&binary).map_err(|error| ChatError::StorageError {
                message: format!("Failed to read conversation file '{id}': {error}"),
            })?;
            if bytes.len() as u64 > super::storage_codec::MAX_DOCUMENT_BYTES {
                return Err(ChatError::StorageError {
                    message: format!("Conversation '{id}' grew above the supported limit"),
                });
            }
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
            self.write_conversation(&conversation)?;
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
            self.write_conversation(&conversation)?;
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
        let _guard = lock_conversations();
        self.write_conversation(conversation)
    }

    fn write_conversation(&self, conversation: &Conversation) -> Result<(), ChatError> {
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
        })?;
        // The sidecar is a cache. A failure here must not report the committed
        // conversation as lost; the next list call rebuilds it from the t2ub.
        let _ = self.write_summary(conversation);
        Ok(())
    }

    pub fn load_conversation(&self, id: &str) -> Result<Conversation, ChatError> {
        let _guard = lock_conversations();
        self.read_conversation(id)
    }

    pub(crate) fn update_conversation<T>(
        &self,
        id: &str,
        update: impl FnOnce(&mut Conversation) -> Result<T, ChatError>,
    ) -> Result<T, ChatError> {
        let _guard = lock_conversations();
        let mut conversation = self.read_conversation(id)?;
        let result = update(&mut conversation)?;
        conversation.updated_at = crate::api::clock::now_millis();
        self.write_conversation(&conversation)?;
        Ok(result)
    }

    pub fn list_conversations(&self) -> Vec<ConversationSummary> {
        let _guard = lock_conversations();
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

                match ext {
                    "t2ub" => {
                        let id = path.file_stem()?.to_str()?;
                        if let Some(summary) = self.read_summary(id) {
                            return Some(summary);
                        }
                        if fs::metadata(&path).ok()?.len()
                            > super::storage_codec::MAX_DOCUMENT_BYTES
                        {
                            return None;
                        }
                        let data = fs::read(&path).ok()?;
                        let conversation: Conversation =
                            super::storage_codec::decode(&data).ok()?;
                        let _ = self.write_summary(&conversation);
                        Some(Self::summary_of(&conversation))
                    }
                    "msgpack" => {
                        let data = fs::read(&path).ok()?;
                        let conversation: Conversation = rmp_serde::from_slice(&data).ok()?;
                        Some(Self::summary_of(&conversation))
                    }
                    "json" => {
                        let json = fs::read_to_string(&path).ok()?;
                        let conversation: Conversation = serde_json::from_str(&json).ok()?;
                        Some(Self::summary_of(&conversation))
                    }
                    _ => None,
                }
            })
            .collect();

        summaries.sort_by_key(|summary| std::cmp::Reverse(summary.updated_at));
        summaries
    }

    pub fn delete_conversation(&self, id: &str) -> Result<(), ChatError> {
        let _guard = lock_conversations();
        let path = self.conversation_path(id)?;
        let dir = self.conversations_dir()?;
        for name in [
            format!("{id}.json"),
            format!("{id}.msgpack"),
            format!("{id}.t2ub.tmp"),
            format!("{id}.t2ui"),
            format!("{id}.t2ui.tmp"),
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

    fn append_message(conv: &mut Conversation, message: Message) {
        if conv.title.is_empty() && message.role == MessageRole::User {
            conv.title = message.content.chars().take(20).collect();
        }
        conv.messages.push(message);
    }

    pub fn add_message(&self, conversation_id: &str, message: Message) -> Result<(), ChatError> {
        self.update_conversation(conversation_id, |conv| {
            Self::append_message(conv, message);
            Ok(())
        })
    }

    /// Persist the user turn and capture its prompt in one transaction.
    pub(crate) fn add_user_turn(
        &self,
        conversation_id: &str,
        message: Message,
    ) -> Result<Conversation, ChatError> {
        self.update_conversation(conversation_id, |conv| {
            Self::append_message(conv, message);
            conv.turn_count += 1;
            Ok(conv.clone())
        })
    }

    /// Commit only to the history that produced this reply. A stale generation
    /// must never resurrect a deleted reply or answer a newer/edited user turn.
    /// Metadata-only changes (e.g. memory summaries) are preserved.
    pub(crate) fn commit_reply(
        &self,
        expected: &Conversation,
        mut reply: Message,
    ) -> Result<bool, ChatError> {
        let _guard = lock_conversations();
        let mut current = self.read_conversation(&expected.id)?;
        if current.messages != expected.messages
            || current.dialogue_style != expected.dialogue_style
        {
            return Ok(false);
        }
        let user_index = current
            .messages
            .iter()
            .rposition(|m| m.role == MessageRole::User);
        let Some(user_index) = user_index else {
            return Ok(false);
        };
        if let Some(index) = current
            .messages
            .iter()
            .enumerate()
            .skip(user_index + 1)
            .rev()
            .find_map(|(index, message)| (message.role == MessageRole::Assistant).then_some(index))
        {
            reply.id = current.messages[index].id.clone();
            current.messages[index] = reply;
        } else {
            current.messages.push(reply);
        }
        current.updated_at = crate::api::clock::now_millis();
        self.write_conversation(&current)?;
        Ok(true)
    }

    pub fn delete_message(&self, conversation_id: &str, message_id: &str) -> Result<(), ChatError> {
        self.update_conversation(conversation_id, |conv| {
            let original_len = conv.messages.len();
            conv.messages.retain(|m| m.id != message_id);
            if conv.messages.len() == original_len {
                return Err(ChatError::StorageError {
                    message: format!("Message '{}' not found", message_id),
                });
            }
            conv.turn_count = conv
                .messages
                .iter()
                .filter(|m| m.role == MessageRole::User)
                .count() as u32;
            Ok(())
        })
    }

    pub fn update_memory_summaries(
        &self,
        conversation_id: &str,
        summaries: &[MemorySummary],
    ) -> Result<(), ChatError> {
        self.update_conversation(conversation_id, |conv| {
            conv.memory_summaries = summaries.to_vec();
            Ok(())
        })
    }

    pub fn edit_message(
        &self,
        conversation_id: &str,
        message_id: &str,
        new_content: &str,
    ) -> Result<(), ChatError> {
        self.update_conversation(conversation_id, |conv| {
            let found = conv.messages.iter_mut().find(|m| m.id == message_id);
            match found {
                Some(msg) => {
                    msg.content = new_content.to_string();
                    msg.timestamp = crate::api::clock::now_millis();
                    Ok(())
                }
                None => Err(ChatError::StorageError {
                    message: format!("Message '{}' not found", message_id),
                }),
            }
        })
    }

    pub fn rollback_to_message(
        &self,
        conversation_id: &str,
        message_id: &str,
    ) -> Result<Vec<String>, ChatError> {
        self.update_conversation(conversation_id, |conv| {
            let pos = conv
                .messages
                .iter()
                .position(|m| m.id == message_id)
                .ok_or_else(|| ChatError::StorageError {
                    message: format!("Message '{}' not found", message_id),
                })?;
            let deleted_ids = conv.messages[pos..].iter().map(|m| m.id.clone()).collect();
            conv.messages.truncate(pos);
            conv.turn_count = conv
                .messages
                .iter()
                .filter(|m| m.role == MessageRole::User)
                .count() as u32;
            Ok(deleted_ids)
        })
    }

    pub fn set_dialogue_style(
        &self,
        conversation_id: &str,
        style: DialogueStyle,
    ) -> Result<(), ChatError> {
        self.update_conversation(conversation_id, |conv| {
            conv.dialogue_style = style;
            Ok(())
        })
    }

    pub fn get_turn_count(&self, conversation_id: &str) -> Result<u32, ChatError> {
        let conv = self.load_conversation(conversation_id)?;
        Ok(conv.turn_count)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Barrier};

    fn message(role: MessageRole, content: &str) -> Message {
        Message {
            id: uuid::Uuid::new_v4().to_string(),
            role,
            content: content.to_string(),
            thinking_content: None,
            model: "test-model".to_string(),
            timestamp: 0,
            message_type: MessageType::Say,
        }
    }

    fn fixture() -> (tempfile::TempDir, ConversationStore, Conversation) {
        let dir = tempfile::tempdir().unwrap();
        let store = ConversationStore::new(dir.path().to_str().unwrap());
        let conversation = store.create_conversation();
        store.save_conversation(&conversation).unwrap();
        (dir, store, conversation)
    }

    #[test]
    fn summary_cache_lists_without_decoding_the_conversation() {
        let (_dir, store, conversation) = fixture();
        store
            .add_user_turn(
                &conversation.id,
                message(MessageRole::User, "缓存里的最后一句"),
            )
            .unwrap();
        // Corrupting the main document proves the list path used the sidecar,
        // not a full decode that would have failed and dropped the row.
        fs::write(
            store.conversation_path(&conversation.id).unwrap(),
            b"broken",
        )
        .unwrap();
        let summaries = store.list_conversations();
        assert_eq!(summaries.len(), 1);
        assert_eq!(summaries[0].last_message_preview, "缓存里的最后一句");
        assert!(store.load_conversation(&conversation.id).is_err());
    }

    #[test]
    fn deleting_a_conversation_removes_its_summary_cache() {
        let (_dir, store, conversation) = fixture();
        let summary = store.summary_path(&conversation.id).unwrap();
        assert!(summary.exists());
        store.delete_conversation(&conversation.id).unwrap();
        assert!(!summary.exists());
        assert!(store.list_conversations().is_empty());
    }

    #[test]
    fn concurrent_store_instances_preserve_every_user_turn() {
        let (_dir, store, conversation) = fixture();
        let barrier = Arc::new(Barrier::new(8));
        let workers: Vec<_> = (0..8)
            .map(|worker| {
                let barrier = barrier.clone();
                let path = store.base_path.clone();
                let id = conversation.id.clone();
                std::thread::spawn(move || {
                    let store = ConversationStore::new(&path);
                    barrier.wait();
                    for turn in 0..12 {
                        store
                            .add_user_turn(
                                &id,
                                message(MessageRole::User, &format!("{worker}:{turn}")),
                            )
                            .unwrap();
                    }
                })
            })
            .collect();
        for worker in workers {
            worker.join().unwrap();
        }
        let loaded = store.load_conversation(&conversation.id).unwrap();
        assert_eq!(loaded.messages.len(), 96);
        assert_eq!(loaded.turn_count, 96);
        let unique: std::collections::HashSet<_> =
            loaded.messages.iter().map(|m| &m.content).collect();
        assert_eq!(unique.len(), 96);
    }

    #[test]
    fn stale_reply_cannot_answer_a_newer_user_turn() {
        let (_dir, store, conversation) = fixture();
        let snapshot = store
            .add_user_turn(&conversation.id, message(MessageRole::User, "first"))
            .unwrap();
        store
            .add_user_turn(&conversation.id, message(MessageRole::User, "second"))
            .unwrap();
        assert!(
            !store
                .commit_reply(&snapshot, message(MessageRole::Assistant, "old answer"))
                .unwrap()
        );
        let loaded = store.load_conversation(&conversation.id).unwrap();
        assert_eq!(loaded.messages.len(), 2);
        assert_eq!(loaded.messages.last().unwrap().content, "second");
    }

    #[test]
    fn concurrent_complete_and_partial_commits_have_one_winner() {
        let (_dir, store, conversation) = fixture();
        let snapshot = store
            .add_user_turn(&conversation.id, message(MessageRole::User, "question"))
            .unwrap();
        let barrier = Arc::new(Barrier::new(2));
        let workers: Vec<_> = ["complete", "partial"]
            .into_iter()
            .map(|content| {
                let barrier = barrier.clone();
                let snapshot = snapshot.clone();
                let path = store.base_path.clone();
                std::thread::spawn(move || {
                    let store = ConversationStore::new(&path);
                    barrier.wait();
                    store
                        .commit_reply(&snapshot, message(MessageRole::Assistant, content))
                        .unwrap()
                })
            })
            .collect();
        let committed = workers
            .into_iter()
            .map(|worker| usize::from(worker.join().unwrap()))
            .sum::<usize>();
        assert_eq!(committed, 1);
        assert_eq!(
            store
                .load_conversation(&conversation.id)
                .unwrap()
                .messages
                .len(),
            2
        );
    }

    #[test]
    fn regeneration_replaces_reply_and_preserves_trailing_system() {
        let (_dir, store, conversation) = fixture();
        store
            .add_user_turn(&conversation.id, message(MessageRole::User, "question"))
            .unwrap();
        let previous = message(MessageRole::Assistant, "rejected");
        store
            .add_message(&conversation.id, previous.clone())
            .unwrap();
        let system = message(MessageRole::System, "durable setting");
        store.add_message(&conversation.id, system.clone()).unwrap();
        let snapshot = store.load_conversation(&conversation.id).unwrap();
        assert!(
            store
                .commit_reply(&snapshot, message(MessageRole::Assistant, "replacement"))
                .unwrap()
        );
        let loaded = store.load_conversation(&conversation.id).unwrap();
        assert_eq!(loaded.messages.len(), 3);
        assert_eq!(loaded.messages[1].id, previous.id);
        assert_eq!(loaded.messages[1].content, "replacement");
        assert_eq!(loaded.messages[2], system);
        assert_eq!(loaded.turn_count, 1);
    }

    #[test]
    fn deleted_regeneration_target_is_not_resurrected() {
        let (_dir, store, conversation) = fixture();
        store
            .add_user_turn(&conversation.id, message(MessageRole::User, "question"))
            .unwrap();
        let previous = message(MessageRole::Assistant, "rejected");
        store
            .add_message(&conversation.id, previous.clone())
            .unwrap();
        let snapshot = store.load_conversation(&conversation.id).unwrap();
        store
            .delete_message(&conversation.id, &previous.id)
            .unwrap();
        assert!(
            !store
                .commit_reply(&snapshot, message(MessageRole::Assistant, "replacement"))
                .unwrap()
        );
        assert_eq!(
            store
                .load_conversation(&conversation.id)
                .unwrap()
                .messages
                .len(),
            1
        );
    }

    #[test]
    fn edited_history_invalidates_reply_but_metadata_updates_are_preserved() {
        let (_dir, store, conversation) = fixture();
        let snapshot = store
            .add_user_turn(&conversation.id, message(MessageRole::User, "question"))
            .unwrap();
        store
            .edit_message(
                &conversation.id,
                &snapshot.messages[0].id,
                "changed question",
            )
            .unwrap();
        assert!(
            !store
                .commit_reply(&snapshot, message(MessageRole::Assistant, "stale answer"))
                .unwrap()
        );
        let snapshot = store.load_conversation(&conversation.id).unwrap();
        store
            .update_conversation(&conversation.id, |conv| {
                conv.title = "renamed".to_string();
                Ok(())
            })
            .unwrap();
        assert!(
            store
                .commit_reply(&snapshot, message(MessageRole::Assistant, "fresh answer"))
                .unwrap()
        );
        assert_eq!(
            store.load_conversation(&conversation.id).unwrap().title,
            "renamed"
        );
    }

    #[test]
    fn rollback_recounts_turns_and_rejects_inflight_reply() {
        let (_dir, store, conversation) = fixture();
        store
            .add_user_turn(&conversation.id, message(MessageRole::User, "first"))
            .unwrap();
        let second = message(MessageRole::User, "second");
        let snapshot = store
            .add_user_turn(&conversation.id, second.clone())
            .unwrap();
        assert_eq!(
            store
                .rollback_to_message(&conversation.id, &second.id)
                .unwrap(),
            vec![second.id]
        );
        assert_eq!(store.get_turn_count(&conversation.id).unwrap(), 1);
        assert!(
            !store
                .commit_reply(&snapshot, message(MessageRole::Assistant, "old answer"))
                .unwrap()
        );
    }

    #[test]
    fn deleted_conversation_is_not_recreated_by_reply() {
        let (_dir, store, conversation) = fixture();
        let snapshot = store
            .add_user_turn(&conversation.id, message(MessageRole::User, "question"))
            .unwrap();
        store.delete_conversation(&conversation.id).unwrap();
        assert!(
            store
                .commit_reply(&snapshot, message(MessageRole::Assistant, "answer"))
                .is_err()
        );
        assert!(store.load_conversation(&conversation.id).is_err());
    }

    #[test]
    fn legacy_migration_and_append_share_one_transaction() {
        let (_dir, store, conversation) = fixture();
        fs::remove_file(store.conversation_path(&conversation.id).unwrap()).unwrap();
        fs::write(
            store
                .conversations_dir()
                .unwrap()
                .join(format!("{}.json", conversation.id)),
            serde_json::to_string(&conversation).unwrap(),
        )
        .unwrap();
        store
            .add_user_turn(&conversation.id, message(MessageRole::User, "migrated"))
            .unwrap();
        let loaded = store.load_conversation(&conversation.id).unwrap();
        assert_eq!(loaded.messages[0].content, "migrated");
        assert_eq!(loaded.turn_count, 1);
    }
}
