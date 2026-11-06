use super::error_handler::ChatError;
use nextjson::{NsonDeserialize, NsonSerialize};
use rustbinary::Config;

/// On-disk envelope written by [`encode`].
///
/// `T2UB` + a format byte keeps the payload self-describing: a file written by
/// a future schema is rejected instead of being decoded into nonsense, and a
/// corrupted header fails before rustbinary ever sees the bytes.
const MAGIC: [u8; 4] = *b"T2UB";
const FORMAT_VERSION: u8 = 1;

/// Both limits are mandatory at this boundary: the payload comes from disk and
/// may be attacker-controlled on a rooted device or through a synced backup.
const MAX_DOCUMENT_BYTES: u64 = 64 * 1024 * 1024;
const MAX_COLLECTION_ITEMS: u64 = 1_000_000;

fn config() -> Config {
    Config::standard()
        .with_limit(MAX_DOCUMENT_BYTES)
        .with_collection_limit(MAX_COLLECTION_ITEMS)
        .reject_trailing_bytes()
}

pub(crate) fn encode<T: NsonSerialize + ?Sized>(value: &T) -> Result<Vec<u8>, ChatError> {
    let payload = config()
        .serialize(value)
        .map_err(|error| ChatError::StorageError {
            message: format!("Failed to encode document: {error}"),
        })?;
    let mut out = Vec::with_capacity(payload.len() + 5);
    out.extend_from_slice(&MAGIC);
    out.push(FORMAT_VERSION);
    out.extend_from_slice(&payload);
    Ok(out)
}

pub(crate) fn decode<T: for<'de> NsonDeserialize<'de>>(bytes: &[u8]) -> Result<T, ChatError> {
    if bytes.len() < MAGIC.len() + 1 || bytes[..MAGIC.len()] != MAGIC {
        return Err(ChatError::StorageError {
            message: "Document header is not Talk2U binary".to_string(),
        });
    }
    let version = bytes[MAGIC.len()];
    if version != FORMAT_VERSION {
        return Err(ChatError::StorageError {
            message: format!("Unsupported document version {version}"),
        });
    }
    config()
        .deserialize(&bytes[MAGIC.len() + 1..])
        .map_err(|error| ChatError::StorageError {
            message: format!("Failed to decode document: {error}"),
        })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::data_models::{Conversation, Message, MessageRole, MessageType};

    fn sample() -> Conversation {
        Conversation {
            id: "conversation_1".to_string(),
            title: "夜里的对话".to_string(),
            messages: vec![
                Message {
                    id: "m1".to_string(),
                    role: MessageRole::User,
                    content: "在吗？\n今天有点累。".to_string(),
                    thinking_content: None,
                    model: "glm-4.7".to_string(),
                    timestamp: 1_760_000_000_123,
                    message_type: MessageType::Say,
                },
                Message {
                    id: "m2".to_string(),
                    role: MessageRole::Assistant,
                    content: "*轻轻点头* 我在。".to_string(),
                    thinking_content: Some("先安抚".to_string()),
                    model: "glm-4.7".to_string(),
                    timestamp: 1_760_000_001_000,
                    message_type: MessageType::Mixed,
                },
            ],
            model: "glm-4.7".to_string(),
            created_at: 1,
            updated_at: 2,
            dialogue_style: Default::default(),
            turn_count: 1,
            memory_summaries: Vec::new(),
        }
    }

    #[test]
    fn conversation_round_trips() {
        let original = sample();
        let bytes = encode(&original).unwrap();
        let decoded: Conversation = decode(&bytes).unwrap();
        assert_eq!(decoded, original);
    }

    #[test]
    fn payload_is_smaller_than_the_json_projection() {
        let original = sample();
        let binary = encode(&original).unwrap();
        let json = serde_json::to_vec(&original).unwrap();
        assert!(
            binary.len() < json.len(),
            "binary {} >= json {}",
            binary.len(),
            json.len()
        );
    }

    #[test]
    fn rejects_foreign_and_truncated_documents() {
        let bytes = encode(&sample()).unwrap();
        assert!(decode::<Conversation>(b"not-a-document").is_err());
        for cut in [0, 3, 5, bytes.len() - 1] {
            assert!(
                decode::<Conversation>(&bytes[..cut]).is_err(),
                "truncation at {cut} was accepted"
            );
        }
    }

    #[test]
    fn rejects_unknown_format_version() {
        let mut bytes = encode(&sample()).unwrap();
        bytes[4] = 9;
        assert!(decode::<Conversation>(&bytes).is_err());
    }
}
