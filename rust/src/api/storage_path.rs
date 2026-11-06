use super::error_handler::ChatError;

pub(crate) fn validate_storage_id(value: &str) -> Result<(), ChatError> {
    let valid = !value.is_empty()
        && value.len() <= 128
        && value
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || character == '-' || character == '_');
    if valid {
        Ok(())
    } else {
        Err(ChatError::StorageError {
            message: "Invalid storage id".to_string(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_uuid_style_ids() {
        assert!(validate_storage_id("2f8a3c9e-0b1d-4f6a-9c7e-1234567890ab").is_ok());
        assert!(validate_storage_id("conversation_42").is_ok());
    }

    #[test]
    fn rejects_path_traversal_and_empty_ids() {
        for value in ["", "..", "../settings", "a/b", "a\\b", "a\0b", "id with space"] {
            assert!(
                validate_storage_id(value).is_err(),
                "expected rejection for {value:?}"
            );
        }
    }
}
