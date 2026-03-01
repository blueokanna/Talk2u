use std::sync::OnceLock;

use super::chat_engine::ChatEngine;
use super::config_manager::ConfigManager;
use super::conversation_store::ConversationStore;
use super::data_models::*;
use super::jwt_auth::JwtAuth;
use super::knowledge_store::KnowledgeStore;
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
    let knowledge = KnowledgeStore::new(get_data_path());
    let _ = knowledge.delete_knowledge(&id);
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
    // 参考: https://docs.bigmodel.cn/cn/guide/start/concept-param
    vec![
        ModelInfo {
            id: "glm-4.7".to_string(),
            name: "GLM-4.7（对话+思考）".to_string(),
            context_tokens: 128000,
            max_output_tokens: 131072,
            supports_thinking: true,
        },
        ModelInfo {
            id: "glm-4-air".to_string(),
            name: "GLM-4-Air（深度推理）".to_string(),
            context_tokens: 128000,
            max_output_tokens: 4095,
            supports_thinking: true,
        },
        ModelInfo {
            id: "glm-4.7-flash".to_string(),
            name: "GLM-4.7-Flash（快速）".to_string(),
            context_tokens: 128000,
            max_output_tokens: 131072,
            supports_thinking: false,
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
                "未配置 API Key，请在设置中填写您的智谱 API Key".to_string(),
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

    // 使用 done_sent 标记确保 Done 事件只发送一次
    let done_sent = std::sync::atomic::AtomicBool::new(false);

    // 整体管线超时保护（5分钟）：防止多阶段管线累计超过 Flutter 的 10 分钟安全超时
    let pipeline_result = tokio::time::timeout(
        std::time::Duration::from_secs(300),
        engine.send_message(
            &conversation_id,
            &content,
            &chat_model,
            &thinking_model,
            enable_thinking,
            |event| {
                if let ChatStreamEvent::Done = &event {
                    done_sent.store(true, std::sync::atomic::Ordering::Relaxed);
                }
                let _ = sink.add(event);
            },
        )
    )
    .await;

    match pipeline_result {
        Ok(Ok(())) => {}
        Ok(Err(e)) => {
            let _ = sink.add(ChatStreamEvent::Error(e.to_string()));
        }
        Err(_timeout) => {
            let _ = sink.add(ChatStreamEvent::Error(
                "处理超时（5分钟），请缩短对话或重试".to_string(),
            ));
        }
    }

    // 确保 Done 事件一定被发送（兜底机制）
    if !done_sent.load(std::sync::atomic::Ordering::Relaxed) {
        let _ = sink.add(ChatStreamEvent::Done);
    }

    // 等待事件缓冲区刷新，防止 sink 被立即 Drop 导致 FRB Done/close 竞态
    tokio::time::sleep(std::time::Duration::from_millis(50)).await;
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
                "未配置 API Key，请在设置中填写您的智谱 API Key".to_string(),
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

    let done_sent = std::sync::atomic::AtomicBool::new(false);

    // 整体管线超时保护（5分钟）
    let pipeline_result = tokio::time::timeout(
        std::time::Duration::from_secs(300),
        engine.regenerate_response(
            &conversation_id,
            &chat_model,
            &thinking_model,
            enable_thinking,
            |event| {
                if let ChatStreamEvent::Done = &event {
                    done_sent.store(true, std::sync::atomic::Ordering::Relaxed);
                }
                let _ = sink.add(event);
            },
        )
    )
    .await;

    match pipeline_result {
        Ok(Ok(())) => {}
        Ok(Err(e)) => {
            let _ = sink.add(ChatStreamEvent::Error(e.to_string()));
        }
        Err(_timeout) => {
            let _ = sink.add(ChatStreamEvent::Error(
                "处理超时（5分钟），请缩短对话或重试".to_string(),
            ));
        }
    }

    // 确保 Done 事件一定被发送（兜底机制）
    if !done_sent.load(std::sync::atomic::Ordering::Relaxed) {
        let _ = sink.add(ChatStreamEvent::Done);
    }

    // 等待事件缓冲区刷新
    tokio::time::sleep(std::time::Duration::from_millis(50)).await;
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
