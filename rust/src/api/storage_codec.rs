use super::error_handler::ChatError;
use nextjson::{NsonDeserialize, NsonSerialize};
use rustbinary::Config;

const MAGIC: [u8; 4] = *b"T2UB";
// Version 1 is the uncompressed rustbinary payload. Version 2 adds a zlib
// wrapper; both stay readable because every existing conversation on disk was
// written by a previous build.
const FORMAT_VERSION: u8 = 1;
const COMPRESSED_VERSION: u8 = 2;
pub(crate) const MAX_DOCUMENT_BYTES: u64 = 64 * 1024 * 1024;
const MAX_COLLECTION_ITEMS: u64 = 1_000_000;
const COMPRESSION_LEVEL: u8 = 6;

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

    // Compression is chosen only when it actually saves bytes. A one-message
    // conversation can be smaller than the zlib framing overhead.
    let compressed = miniz_oxide::deflate::compress_to_vec_zlib(&payload, COMPRESSION_LEVEL);
    let compressed_is_smaller = compressed.len() + 8 < payload.len();
    let mut out = Vec::with_capacity(if compressed_is_smaller {
        compressed.len() + 13
    } else {
        payload.len() + 5
    });
    out.extend_from_slice(&MAGIC);
    if compressed_is_smaller {
        out.push(COMPRESSED_VERSION);
        out.extend_from_slice(&(payload.len() as u64).to_le_bytes());
        out.extend_from_slice(&compressed);
    } else {
        out.push(FORMAT_VERSION);
        out.extend_from_slice(&payload);
    }
    Ok(out)
}

pub(crate) fn decode<T: for<'de> NsonDeserialize<'de>>(bytes: &[u8]) -> Result<T, ChatError> {
    if bytes.len() < MAGIC.len() + 1 || bytes[..MAGIC.len()] != MAGIC {
        return Err(ChatError::StorageError {
            message: "Document header is not Talk2U binary".to_string(),
        });
    }
    let version = bytes[MAGIC.len()];
    let payload_start = MAGIC.len() + 1;
    let payload = match version {
        FORMAT_VERSION => &bytes[payload_start..],
        COMPRESSED_VERSION => {
            if bytes.len() < payload_start + 8 {
                return Err(ChatError::StorageError {
                    message: "Compressed document header is truncated".to_string(),
                });
            }
            let declared =
                u64::from_le_bytes(bytes[payload_start..payload_start + 8].try_into().map_err(
                    |_| ChatError::StorageError {
                        message: "Compressed document length is invalid".to_string(),
                    },
                )?);
            if declared == 0 || declared > MAX_DOCUMENT_BYTES {
                return Err(ChatError::StorageError {
                    message: format!(
                        "Compressed document declares an invalid size of {declared} bytes"
                    ),
                });
            }
            let payload = miniz_oxide::inflate::decompress_to_vec_zlib_with_limit(
                &bytes[payload_start + 8..],
                declared as usize,
            )
            .map_err(|error| ChatError::StorageError {
                message: format!("Failed to decompress document: {error:?}"),
            })?;
            if payload.len() as u64 != declared {
                return Err(ChatError::StorageError {
                    message: format!(
                        "Compressed document expanded to {} bytes, expected {declared}",
                        payload.len()
                    ),
                });
            }
            // The decompressed buffer is the only full-size allocation on this
            // path; the compressed bytes stay in the caller's file buffer.
            return config()
                .deserialize(&payload)
                .map_err(|error| ChatError::StorageError {
                    message: format!("Failed to decode document: {error}"),
                });
        }
        other => {
            return Err(ChatError::StorageError {
                message: format!("Unsupported document version {other}"),
            });
        }
    };
    config()
        .deserialize(payload)
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

    fn long_conversation() -> Conversation {
        let mut conversation = sample();
        conversation.messages = (0..400)
            .map(|index| Message {
                id: format!("message-{index}"),
                role: if index % 2 == 0 {
                    MessageRole::User
                } else {
                    MessageRole::Assistant
                },
                content: format!(
                    "第{index}轮：这是一段用于验证压缩率和完整解码的较长对话内容。\
                     重复的上下文、标点和空白都应该原样恢复。"
                ),
                thinking_content: None,
                model: "glm-4.7".to_string(),
                timestamp: 1_760_000_000_000 + i64::from(index),
                message_type: MessageType::Say,
            })
            .collect();
        conversation
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
    fn long_conversation_uses_compression_and_round_trips() {
        let original = long_conversation();
        let bytes = encode(&original).unwrap();
        assert_eq!(bytes[MAGIC.len()], COMPRESSED_VERSION);
        let uncompressed = config().serialize(&original).unwrap();
        assert!(
            bytes.len() < uncompressed.len(),
            "compressed {} >= raw {}",
            bytes.len(),
            uncompressed.len()
        );
        let decoded: Conversation = decode(&bytes).unwrap();
        assert_eq!(decoded, original);
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

    #[test]
    fn rejects_a_decompression_bomb() {
        let mut bytes = encode(&long_conversation()).unwrap();
        assert_eq!(bytes[4], COMPRESSED_VERSION);
        bytes[5..13].copy_from_slice(&(MAX_DOCUMENT_BYTES + 1).to_le_bytes());
        assert!(decode::<Conversation>(&bytes).is_err());
    }
}
