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
    // 同时删除记忆索引
    let memory = MemoryEngine::new(get_data_path());
    let _ = memory.delete_memory_index(&id);
    get_conversation_store().delete_conversation(&id).is_ok()
}

/// Delete a single message from a conversation.
pub fn delete_message(conversation_id: String, message_id: String) -> bool {
    get_conversation_store()
        .delete_message(&conversation_id, &message_id)
        .is_ok()
}

/// Edit a message's content in a conversation.
pub fn edit_message(conversation_id: String, message_id: String, new_content: String) -> bool {
    get_conversation_store()
        .edit_message(&conversation_id, &message_id, &new_content)
        .is_ok()
}

/// Rollback: delete the target user message and all messages after it.
/// Returns the list of deleted message IDs.
pub fn rollback_to_message(conversation_id: String, message_id: String) -> Vec<String> {
    get_conversation_store()
        .rollback_to_message(&conversation_id, &message_id)
        .unwrap_or_default()
}

/// Add a system message to a conversation (used for character system prompts).
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

/// Add an assistant message to a conversation (used for character greetings).
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

// ── Restart story ──

/// 重启剧情：清除对话消息但保留角色设定和开场白
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

// ── Dialogue style ──

/// 设置对话风格
pub fn set_dialogue_style(conversation_id: String, style: DialogueStyle) -> bool {
    get_conversation_store()
        .set_dialogue_style(&conversation_id, style)
        .is_ok()
}

// ── Say/Do detection ──

/// 检测消息的 say/do 类型
pub fn detect_message_type(content: String) -> MessageType {
    ChatEngine::detect_message_type(&content)
}

// ── Memory ──

/// 获取对话的轮次计数
pub fn get_turn_count(conversation_id: String) -> u32 {
    get_conversation_store()
        .get_turn_count(&conversation_id)
        .unwrap_or(0)
}

/// 检查是否需要触发记忆总结
pub fn should_summarize_memory(conversation_id: String) -> bool {
    let turn_count = get_conversation_store()
        .get_turn_count(&conversation_id)
        .unwrap_or(0);
    MemoryEngine::should_summarize(turn_count)
}

/// 搜索相关记忆
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

// ── Settings management ──

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

// ── Model info ──

pub fn get_available_models() -> Vec<ModelInfo> {
    vec![
        ModelInfo {
            id: "glm-4.7".to_string(),
            name: "GLM-4.7（对话）".to_string(),
            context_tokens: 128000,
            supports_thinking: false,
        },
        ModelInfo {
            id: "glm-4-air".to_string(),
            name: "GLM-4-Air（深度推理）".to_string(),
            context_tokens: 128000,
            supports_thinking: true,
        },
        ModelInfo {
            id: "glm-4.7-flash".to_string(),
            name: "GLM-4.7-Flash（快速）".to_string(),
            context_tokens: 128000,
            supports_thinking: false,
        },
    ]
}

// ── Streaming chat ──

/// Send a message and stream SSE events back to Flutter.
pub async fn send_message(
    conversation_id: String,
    content: String,
    model: String,
    enable_thinking: bool,
    sink: crate::frb_generated::StreamSink<ChatStreamEvent>,
) {
    let settings = get_config_manager().load_settings();
    let api_key = match settings.api_key {
        Some(key) => key,
        None => {
            let _ = sink.add(ChatStreamEvent::Error(
                "API key not configured. Please set your API key in Settings.".to_string(),
            ));
            return;
        }
    };

    // 使用传入的模型，不再强制覆盖
    let actual_model = if model.is_empty() {
        settings.chat_model.clone()
    } else {
        model
    };

    let engine = match ChatEngine::new(&api_key, get_data_path()) {
        Ok(e) => e,
        Err(err) => {
            let _ = sink.add(ChatStreamEvent::Error(err));
            return;
        }
    };

    let result = engine
        .send_message(&conversation_id, &content, &actual_model, enable_thinking, |event| {
            let _ = sink.add(event);
        })
        .await;

    if let Err(e) = result {
        let _ = sink.add(ChatStreamEvent::Error(e.to_string()));
    }
}

/// Regenerate AI response without re-adding user message.
/// Used when user clicks "regenerate" on an AI message.
pub async fn regenerate_response(
    conversation_id: String,
    model: String,
    enable_thinking: bool,
    sink: crate::frb_generated::StreamSink<ChatStreamEvent>,
) {
    let settings = get_config_manager().load_settings();
    let api_key = match settings.api_key {
        Some(key) => key,
        None => {
            let _ = sink.add(ChatStreamEvent::Error(
                "API key not configured. Please set your API key in Settings.".to_string(),
            ));
            return;
        }
    };

    let actual_model = if model.is_empty() {
        settings.chat_model.clone()
    } else {
        model
    };

    let engine = match ChatEngine::new(&api_key, get_data_path()) {
        Ok(e) => e,
        Err(err) => {
            let _ = sink.add(ChatStreamEvent::Error(err));
            return;
        }
    };

    let result = engine
        .regenerate_response(&conversation_id, &actual_model, enable_thinking, |event| {
            let _ = sink.add(event);
        })
        .await;

    if let Err(e) = result {
        let _ = sink.add(ChatStreamEvent::Error(e.to_string()));
    }
}

/// 触发记忆总结（在 send_message 完成后由 Flutter 端异步调用）
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
