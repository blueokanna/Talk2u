use std::fs;
use std::path::Path;

use flutter_rust_bridge::frb;

use super::data_models::{default_provider_configs, AppSettings, ProviderConfig};
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
            Ok(contents) => serde_json::from_str(&contents)
                .map(Self::normalize_provider_settings)
                .unwrap_or_default(),
            Err(_) => AppSettings::default(),
        }
    }

    fn normalize_provider_settings(mut settings: AppSettings) -> AppSettings {
        let mut providers = serde_json::from_str::<Vec<ProviderConfig>>(&settings.providers_json)
            .unwrap_or_default();
        for default_provider in default_provider_configs() {
            if let Some(provider) = providers
                .iter_mut()
                .find(|provider| provider.id == default_provider.id)
            {
                if provider.name.trim().is_empty() {
                    provider.name = default_provider.name;
                }
                if provider.api_url.trim().is_empty() {
                    provider.api_url = default_provider.api_url;
                }
                if provider.chat_model.trim().is_empty() {
                    provider.chat_model = default_provider.chat_model;
                }
                if provider.protocol.trim().is_empty() {
                    provider.protocol = default_provider.protocol;
                }
                if provider.max_output_tokens == 0 {
                    provider.max_output_tokens = default_provider.max_output_tokens;
                }
            } else {
                providers.push(default_provider);
            }
        }

        // Older Talk2U releases stored the Zhipu key only in `api_key`.
        // Keep both representations synchronized so upgrades do not look
        // unconfigured and block the request before rustglm is reached.
        if let Some(zhipu) = providers.iter_mut().find(|provider| provider.id == "zhipu") {
            if zhipu
                .api_key
                .as_deref()
                .map(str::trim)
                .is_none_or(str::is_empty)
            {
                zhipu.api_key = settings
                    .api_key
                    .as_deref()
                    .map(str::trim)
                    .filter(|key| !key.is_empty())
                    .map(str::to_owned);
            }
            if settings
                .api_key
                .as_deref()
                .map(str::trim)
                .is_none_or(str::is_empty)
            {
                settings.api_key = zhipu.api_key.clone();
            }
        }
        if !providers
            .iter()
            .any(|provider| provider.id == settings.selected_provider)
        {
            settings.selected_provider = providers
                .first()
                .map(|provider| provider.id.clone())
                .unwrap_or_else(|| "zhipu".to_string());
        }
        settings.providers_json =
            serde_json::to_string(&providers).unwrap_or_else(|_| "[]".to_string());
        settings
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
            selected_provider: "zhipu".to_string(),
            providers_json: serde_json::to_string(
                &crate::api::data_models::default_provider_configs(),
            )
            .unwrap(),
        };

        manager.save_settings(&settings).unwrap();
        let loaded = manager.load_settings();

        assert_eq!(loaded.api_key, settings.api_key);
        assert_eq!(loaded.selected_provider, settings.selected_provider);
        let providers: Vec<ProviderConfig> = serde_json::from_str(&loaded.providers_json).unwrap();
        let zhipu = providers
            .iter()
            .find(|provider| provider.id == "zhipu")
            .unwrap();
        assert_eq!(zhipu.api_key.as_deref(), Some("user123.secret456"));
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
            selected_provider: "zhipu".to_string(),
            providers_json: serde_json::to_string(
                &crate::api::data_models::default_provider_configs(),
            )
            .unwrap(),
        };
        manager.save_settings(&first).unwrap();

        let second = AppSettings {
            api_key: Some("key2.secret2".to_string()),
            default_model: "glm-4-long".to_string(),
            enable_thinking_by_default: true,
            chat_model: "glm-4.7".to_string(),
            thinking_model: "glm-4-air".to_string(),
            selected_provider: "zhipu".to_string(),
            providers_json: serde_json::to_string(
                &crate::api::data_models::default_provider_configs(),
            )
            .unwrap(),
        };
        manager.save_settings(&second).unwrap();

        let loaded = manager.load_settings();
        assert_eq!(loaded.api_key, second.api_key);
        assert_eq!(loaded.default_model, second.default_model);
        let providers: Vec<ProviderConfig> = serde_json::from_str(&loaded.providers_json).unwrap();
        let zhipu = providers
            .iter()
            .find(|provider| provider.id == "zhipu")
            .unwrap();
        assert_eq!(zhipu.api_key.as_deref(), Some("key2.secret2"));
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
    fn test_load_merges_new_providers_into_existing_settings() {
        let tmp = TempDir::new().unwrap();
        let existing_provider = ProviderConfig {
            id: "zhipu".to_string(),
            name: "智谱清言".to_string(),
            api_key: Some("existing.key".to_string()),
            api_url: "https://custom.example/chat".to_string(),
            chat_model: "custom-glm".to_string(),
            thinking_model: None,
            protocol: "openai".to_string(),
            max_output_tokens: 4096,
        };
        let settings = AppSettings {
            providers_json: serde_json::to_string(&vec![existing_provider]).unwrap(),
            ..AppSettings::default()
        };
        fs::write(
            tmp.path().join("settings.json"),
            serde_json::to_string(&settings).unwrap(),
        )
        .unwrap();

        let loaded = ConfigManager::new(tmp.path().to_str().unwrap()).load_settings();
        let providers: Vec<ProviderConfig> = serde_json::from_str(&loaded.providers_json).unwrap();
        assert!(providers.iter().any(|provider| provider.id == "deepseek"));
        assert!(providers.iter().any(|provider| provider.id == "anthropic"));
        let zhipu = providers
            .iter()
            .find(|provider| provider.id == "zhipu")
            .unwrap();
        assert_eq!(zhipu.api_key.as_deref(), Some("existing.key"));
        assert_eq!(zhipu.api_url, "https://custom.example/chat");
    }

    #[test]
    fn test_load_repairs_incomplete_builtin_provider() {
        let tmp = TempDir::new().unwrap();
        let incomplete_provider = ProviderConfig {
            id: "zhipu".to_string(),
            name: String::new(),
            api_key: Some("saved.key".to_string()),
            api_url: String::new(),
            chat_model: String::new(),
            thinking_model: None,
            protocol: String::new(),
            max_output_tokens: 0,
        };
        let settings = AppSettings {
            api_key: None,
            providers_json: serde_json::to_string(&vec![incomplete_provider]).unwrap(),
            ..AppSettings::default()
        };
        fs::write(
            tmp.path().join("settings.json"),
            serde_json::to_string(&settings).unwrap(),
        )
        .unwrap();

        let loaded = ConfigManager::new(tmp.path().to_str().unwrap()).load_settings();
        let providers: Vec<ProviderConfig> = serde_json::from_str(&loaded.providers_json).unwrap();
        let zhipu = providers
            .iter()
            .find(|provider| provider.id == "zhipu")
            .unwrap();
        assert_eq!(loaded.api_key.as_deref(), Some("saved.key"));
        assert_eq!(
            zhipu.api_url,
            "https://open.bigmodel.cn/api/paas/v4/chat/completions"
        );
        assert_eq!(zhipu.chat_model, "glm-4.7");
        assert_eq!(zhipu.protocol, "openai");
        assert_eq!(zhipu.max_output_tokens, 16_384);
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
            selected_provider: "zhipu".to_string(),
            providers_json: serde_json::to_string(
                &crate::api::data_models::default_provider_configs(),
            )
            .unwrap(),
        };

        manager.save_settings(&settings).unwrap();
        let loaded = manager.load_settings();
        assert_eq!(loaded, settings);
    }
}
