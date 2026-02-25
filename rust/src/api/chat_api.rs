use std::sync::OnceLock;

use super::chat_engine::ChatEngine;
use super::config_manager::ConfigManager;
use super::conversation_store::ConversationStore;
use super::data_models::*;
use super::jwt_auth::JwtAuth;
use super::memory_engine::MemoryEngine;

static CONFIG_MANAGER: OnceLock<ConfigManager> = OnceLock::new();
static CONVERSATION_STORE: OnceLock<ConversationStore> = OnceLock::new();
static DATA_PATH: OnceLock<String> = OnceLock::new();

pub fn init_app(data_path: String) {
    DATA_PATH.get_or_init(|| data_path.clone());
    CONFIG_MANAGER.get_or_init(|| ConfigManager::new(&data_path));
    CONVERSATION_STORE.get_or_init(|| ConversationStore::new(&data_path));
}

fn get_data_path() -> &'static str {
    DATA_PATH.get().map(|s| s.as_str()).unwrap_or("app_data")
}

fn get_config_manager() -> &'static ConfigManager {
    CONFIG_MANAGER.get_or_init(|| ConfigManager::new(get_data_path()))
}

fn get_conversation_store() -> &'static ConversationStore {
    CONVERSATION_STORE.get_or_init(|| ConversationStore::new(get_data_path()))
}

/// 解析对话模型：如果用户选择的是推理模型，自动回退到对话模型
/// （推理模型不直接对话，仅在双模型管线中作为思考引擎使用）
fn resolve_chat_model(requested_model: &str, settings: &AppSettings) -> String {
    if requested_model.is_empty() || requested_model == settings.thinking_model {
        settings.chat_model.clone()
    } else {
        requested_model.to_string()
    }
}

/// 解析推理模型：从设置读取，默认 glm-4-air
fn resolve_thinking_model(settings: &AppSettings) -> String {
    if settings.thinking_model.trim().is_empty() {
        "glm-4-air".to_string()
    } else {
        settings.thinking_model.clone()
    }
}

// ── Conversation management ──

pub fn create_conversation() -> Conversation {
    let conv = get_conversation_store().create_conversation();
    let _ = get_conversation_store().save_conversation(&conv);
    conv
}

pub fn get_conversation_list() -> Vec<ConversationSummary> {
    get_conversation_store().list_conversations()
}

pub fn get_conversation(id: String) -> Option<Conversation> {
    get_conversation_store().load_conversation(&id).ok()
}

pub fn delete_conversation(id: String) -> bool {
    let memory = MemoryEngine::new(get_data_path());
    let _ = memory.delete_memory_index(&id);
    get_conversation_store().delete_conversation(&id).is_ok()
}

pub fn delete_message(conversation_id: String, message_id: String) -> bool {
    get_conversation_store()
        .delete_message(&conversation_id, &message_id)
        .is_ok()
}

pub fn edit_message(conversation_id: String, message_id: String, new_content: String) -> bool {
    get_conversation_store()
        .edit_message(&conversation_id, &message_id, &new_content)
        .is_ok()
}

pub fn rollback_to_message(conversation_id: String, message_id: String) -> Vec<String> {
    get_conversation_store()
        .rollback_to_message(&conversation_id, &message_id)
        .unwrap_or_default()
}

pub fn add_system_message(conversation_id: String, content: String) -> bool {
    let msg = Message {
        id: uuid::Uuid::new_v4().to_string(),
        role: MessageRole::System,
        content,
        thinking_content: None,
        model: "system".to_string(),
        timestamp: chrono::Utc::now().timestamp_millis(),
        message_type: MessageType::Say,
    };
    get_conversation_store()
        .add_message(&conversation_id, msg)
        .is_ok()
}

pub fn add_assistant_message(conversation_id: String, content: String) -> bool {
    let msg = Message {
        id: uuid::Uuid::new_v4().to_string(),
        role: MessageRole::Assistant,
        content,
        thinking_content: None,
        model: "glm-4.7".to_string(),
        timestamp: chrono::Utc::now().timestamp_millis(),
        message_type: MessageType::Say,
    };
    get_conversation_store()
        .add_message(&conversation_id, msg)
        .is_ok()
}

pub fn restart_story(conversation_id: String) -> bool {
    let settings = get_config_manager().load_settings();
    let api_key = match settings.api_key {
        Some(key) => key,
        None => return false,
    };
    match ChatEngine::new(&api_key, get_data_path()) {
        Ok(engine) => engine.restart_story(&conversation_id).is_ok(),
        Err(_) => false,
    }
}

pub fn set_dialogue_style(conversation_id: String, style: DialogueStyle) -> bool {
    get_conversation_store()
        .set_dialogue_style(&conversation_id, style)
        .is_ok()
}

pub fn detect_message_type(content: String) -> MessageType {
    ChatEngine::detect_message_type(&content)
}

pub fn get_turn_count(conversation_id: String) -> u32 {
    get_conversation_store()
        .get_turn_count(&conversation_id)
        .unwrap_or(0)
}

pub fn should_summarize_memory(conversation_id: String) -> bool {
    let turn_count = get_conversation_store()
        .get_turn_count(&conversation_id)
        .unwrap_or(0);
    MemoryEngine::should_summarize(turn_count)
}

pub fn search_memories(
    conversation_id: String,
    query: String,
    top_k: usize,
) -> Vec<MemorySearchResult> {
    let memory = MemoryEngine::new(get_data_path());
    let summaries = memory
        .load_memory_index(&conversation_id)
        .unwrap_or_default();
    MemoryEngine::search_memories(&query, &summaries, top_k)
}

pub fn get_settings() -> AppSettings {
    get_config_manager().load_settings()
}

pub fn save_settings(settings: AppSettings) -> bool {
    get_config_manager().save_settings(&settings).is_ok()
}

pub fn set_api_key(api_key: String) -> Result<(), String> {
    if !JwtAuth::validate_api_key_format(&api_key) {
        return Err("Invalid API key format. Expected: user_id.user_secret".to_string());
    }
    let mut settings = get_config_manager().load_settings();
    settings.api_key = Some(api_key);
    get_config_manager()
        .save_settings(&settings)
        .map_err(|e| e.to_string())
}

pub fn validate_api_key(api_key: String) -> bool {
    JwtAuth::validate_api_key_format(&api_key)
}

pub fn get_available_models() -> Vec<ModelInfo> {
    vec![
        ModelInfo {
            id: "glm-4.7".to_string(),
            name: "GLM-4.7（对话）".to_string(),
            context_tokens: 200_000,
            max_output_tokens: 65536,
            supports_thinking: true,
        },
        ModelInfo {
            id: "glm-4-air".to_string(),
            name: "GLM-4-Air（深度推理）".to_string(),
            context_tokens: 128_000,
            max_output_tokens: 4096,
            supports_thinking: true,
        },
        ModelInfo {
            id: "glm-4.7-flash".to_string(),
            name: "GLM-4.7-Flash（快速）".to_string(),
            context_tokens: 200_000,
            max_output_tokens: 65536,
            supports_thinking: true,
        },
    ]
}

pub async fn send_message(
    conversation_id: String,
    content: String,
    model: String,
    enable_thinking: bool,
    sink: crate::frb_generated::StreamSink<ChatStreamEvent>,
) {
    let settings = get_config_manager().load_settings();
    let api_key = match settings.api_key.clone() {
        Some(key) => key,
        None => {
            let _ = sink.add(ChatStreamEvent::Error(
                "API key not configured. Please set your API key in Settings.".to_string(),
            ));
            let _ = sink.add(ChatStreamEvent::Done);
            return;
        }
    };

    let chat_model = resolve_chat_model(&model, &settings);
    let thinking_model = resolve_thinking_model(&settings);

    let engine = match ChatEngine::new(&api_key, get_data_path()) {
        Ok(e) => e,
        Err(err) => {
            let _ = sink.add(ChatStreamEvent::Error(err));
            let _ = sink.add(ChatStreamEvent::Done);
            return;
        }
    };

    let result = engine
        .send_message(
            &conversation_id,
            &content,
            &chat_model,
            &thinking_model,
            enable_thinking,
            |event| {
                let _ = sink.add(event);
            },
        )
        .await;

    match result {
        Ok(()) => {
            // send_message 内部已发送 Done，但为防止 flutter_rust_bridge
            // 在函数返回时关闭流导致 Done 事件丢失，再补发一次。
            // Flutter 端 done: handler 会通过 _isStreaming 标志去重。
            let _ = sink.add(ChatStreamEvent::Done);
        }
        Err(e) => {
            let _ = sink.add(ChatStreamEvent::Error(e.to_string()));
            let _ = sink.add(ChatStreamEvent::Done);
        }
    }
}

pub async fn regenerate_response(
    conversation_id: String,
    model: String,
    enable_thinking: bool,
    sink: crate::frb_generated::StreamSink<ChatStreamEvent>,
) {
    let settings = get_config_manager().load_settings();
    let api_key = match settings.api_key.clone() {
        Some(key) => key,
        None => {
            let _ = sink.add(ChatStreamEvent::Error(
                "API key not configured. Please set your API key in Settings.".to_string(),
            ));
            let _ = sink.add(ChatStreamEvent::Done);
            return;
        }
    };

    let chat_model = resolve_chat_model(&model, &settings);
    let thinking_model = resolve_thinking_model(&settings);

    let engine = match ChatEngine::new(&api_key, get_data_path()) {
        Ok(e) => e,
        Err(err) => {
            let _ = sink.add(ChatStreamEvent::Error(err));
            let _ = sink.add(ChatStreamEvent::Done);
            return;
        }
    };

    let result = engine
        .regenerate_response(
            &conversation_id,
            &chat_model,
            &thinking_model,
            enable_thinking,
            |event| {
                let _ = sink.add(event);
            },
        )
        .await;

    match result {
        Ok(()) => {
            let _ = sink.add(ChatStreamEvent::Done);
        }
        Err(e) => {
            let _ = sink.add(ChatStreamEvent::Error(e.to_string()));
            let _ = sink.add(ChatStreamEvent::Done);
        }
    }
}

pub async fn trigger_memory_summarize(
    conversation_id: String,
    sink: crate::frb_generated::StreamSink<ChatStreamEvent>,
) {
    let settings = get_config_manager().load_settings();
    let api_key = match settings.api_key {
        Some(key) => key,
        None => return,
    };

    let engine = match ChatEngine::new(&api_key, get_data_path()) {
        Ok(e) => e,
        Err(_) => return,
    };

    let _ = engine
        .summarize_memory(&conversation_id, |event| {
            let _ = sink.add(event);
        })
        .await;
}
