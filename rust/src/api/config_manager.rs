use std::fs;
use std::path::Path;

use flutter_rust_bridge::frb;

use super::data_models::AppSettings;
use super::error_handler::ChatError;

#[frb(opaque)]
pub struct ConfigManager {
    config_path: String,
}

impl ConfigManager {
    pub fn new(config_path: &str) -> Self {
        Self {
            config_path: config_path.to_string(),
        }
    }

    /// 加载设置。如果文件不存在或无法解析，返回默认设置。
    pub fn load_settings(&self) -> AppSettings {
        let file_path = Path::new(&self.config_path).join("settings.json");
        match fs::read_to_string(&file_path) {
            Ok(contents) => {
                serde_json::from_str(&contents).unwrap_or_default()
            }
            Err(_) => AppSettings::default(),
        }
    }

    /// 保存设置到 JSON 文件。如果目录不存在则自动创建。
    pub fn save_settings(&self, settings: &AppSettings) -> Result<(), ChatError> {
        let dir = Path::new(&self.config_path);
        if !dir.exists() {
            fs::create_dir_all(dir).map_err(|e| ChatError::StorageError {
                message: format!("Failed to create config directory: {}", e),
            })?;
        }

        let json = serde_json::to_string_pretty(settings).map_err(|e| ChatError::StorageError {
            message: format!("Failed to serialize settings: {}", e),
        })?;

        let file_path = dir.join("settings.json");
        fs::write(&file_path, json).map_err(|e| ChatError::StorageError {
            message: format!("Failed to write settings file: {}", e),
        })?;

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn test_load_defaults_when_no_file() {
        let tmp = TempDir::new().unwrap();
        let manager = ConfigManager::new(tmp.path().to_str().unwrap());

        let settings = manager.load_settings();

        assert_eq!(settings, AppSettings::default());
        assert_eq!(settings.default_model, "glm-4.7");
        assert!(settings.enable_thinking_by_default);
        assert!(settings.api_key.is_none());
    }

    #[test]
    fn test_save_and_load_round_trip() {
        let tmp = TempDir::new().unwrap();
        let manager = ConfigManager::new(tmp.path().to_str().unwrap());

        let settings = AppSettings {
            api_key: Some("user123.secret456".to_string()),
            default_model: "glm-4.7".to_string(),
            enable_thinking_by_default: true,
            chat_model: "glm-4.7".to_string(),
            thinking_model: "glm-4-air".to_string(),
        };

        manager.save_settings(&settings).unwrap();
        let loaded = manager.load_settings();

        assert_eq!(loaded, settings);
    }

    #[test]
    fn test_overwrite_existing_settings() {
        let tmp = TempDir::new().unwrap();
        let manager = ConfigManager::new(tmp.path().to_str().unwrap());

        let first = AppSettings {
            api_key: Some("key1.secret1".to_string()),
            default_model: "glm-4-flash".to_string(),
            enable_thinking_by_default: false,
            chat_model: "glm-4.7".to_string(),
            thinking_model: "glm-4-air".to_string(),
        };
        manager.save_settings(&first).unwrap();

        let second = AppSettings {
            api_key: Some("key2.secret2".to_string()),
            default_model: "glm-4-long".to_string(),
            enable_thinking_by_default: true,
            chat_model: "glm-4.7".to_string(),
            thinking_model: "glm-4-air".to_string(),
        };
        manager.save_settings(&second).unwrap();

        let loaded = manager.load_settings();
        assert_eq!(loaded, second);
    }

    #[test]
    fn test_load_returns_default_for_invalid_json() {
        let tmp = TempDir::new().unwrap();
        let file_path = tmp.path().join("settings.json");
        fs::write(&file_path, "not valid json {{{").unwrap();

        let manager = ConfigManager::new(tmp.path().to_str().unwrap());
        let settings = manager.load_settings();

        assert_eq!(settings, AppSettings::default());
    }

    #[test]
    fn test_save_creates_directory_if_missing() {
        let tmp = TempDir::new().unwrap();
        let nested = tmp.path().join("sub").join("dir");
        let manager = ConfigManager::new(nested.to_str().unwrap());

        let settings = AppSettings {
            api_key: None,
            default_model: "glm-4.7".to_string(),
            enable_thinking_by_default: false,
            chat_model: "glm-4.7".to_string(),
            thinking_model: "glm-4-air".to_string(),
        };

        manager.save_settings(&settings).unwrap();
        let loaded = manager.load_settings();
        assert_eq!(loaded, settings);
    }
}
