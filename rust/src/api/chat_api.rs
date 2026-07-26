use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};

use tokio::sync::watch;

use super::chat_engine::ChatEngine;
use super::config_manager::ConfigManager;
use super::conversation_store::ConversationStore;
use super::data_models::*;
use super::knowledge_store::KnowledgeStore;
use super::memory_engine::MemoryEngine;
use super::provider::ProviderRuntime;
use super::streaming_handler::StreamingHandler;

static CONFIG_MANAGER: OnceLock<ConfigManager> = OnceLock::new();
static CONVERSATION_STORE: OnceLock<ConversationStore> = OnceLock::new();
static DATA_PATH: OnceLock<String> = OnceLock::new();
static ACTIVE_GENERATIONS: OnceLock<Mutex<HashMap<String, ActiveGeneration>>> = OnceLock::new();

struct ActiveGeneration {
    request_id: String,
    cancel: watch::Sender<bool>,
}

fn active_generations() -> &'static Mutex<HashMap<String, ActiveGeneration>> {
    ACTIVE_GENERATIONS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn register_generation(conversation_id: &str) -> (String, watch::Receiver<bool>) {
    let request_id = uuid::Uuid::new_v4().to_string();
    let (cancel, receiver) = watch::channel(false);
    if let Ok(mut active) = active_generations().lock() {
        if let Some(previous) = active.insert(
            conversation_id.to_string(),
            ActiveGeneration {
                request_id: request_id.clone(),
                cancel,
            },
        ) {
            let _ = previous.cancel.send(true);
        }
    }
    (request_id, receiver)
}

fn unregister_generation(conversation_id: &str, request_id: &str) {
    if let Ok(mut active) = active_generations().lock() {
        if active
            .get(conversation_id)
            .is_some_and(|generation| generation.request_id == request_id)
        {
            active.remove(conversation_id);
        }
    }
}

pub fn cancel_generation(conversation_id: String) -> bool {
    let generation = active_generations()
        .lock()
        .ok()
        .and_then(|mut active| active.remove(&conversation_id));
    generation
        .map(|generation| generation.cancel.send(true).is_ok())
        .unwrap_or(false)
}

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

fn resolve_chat_model(requested_model: &str, provider: &ProviderConfig) -> String {
    if requested_model.trim().is_empty()
        || provider.thinking_model.as_deref() == Some(requested_model)
    {
        provider.chat_model.clone()
    } else {
        requested_model.to_string()
    }
}

fn create_engine(
    settings: &AppSettings,
    provider_id: &str,
) -> Result<(ChatEngine, ProviderConfig), String> {
    let (runtime, provider) = ProviderRuntime::from_settings(settings, provider_id)?;
    let engine = ChatEngine::new(runtime, provider.chat_model.clone(), get_data_path());
    Ok((engine, provider))
}

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
    match create_engine(&settings, &settings.selected_provider) {
        Ok((engine, _)) => engine.restart_story(&conversation_id).is_ok(),
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

pub fn add_user_message(conversation_id: String, content: String, model: String) -> bool {
    let msg = Message {
        id: uuid::Uuid::new_v4().to_string(),
        role: MessageRole::User,
        content,
        thinking_content: None,
        model,
        timestamp: chrono::Utc::now().timestamp_millis(),
        message_type: MessageType::Say,
    };
    get_conversation_store()
        .add_message(&conversation_id, msg)
        .is_ok()
}

pub fn add_assistant_message_with_model(
    conversation_id: String,
    content: String,
    model: String,
) -> bool {
    let msg = Message {
        id: uuid::Uuid::new_v4().to_string(),
        role: MessageRole::Assistant,
        content,
        thinking_content: None,
        model,
        timestamp: chrono::Utc::now().timestamp_millis(),
        message_type: MessageType::Say,
    };
    get_conversation_store()
        .add_message(&conversation_id, msg)
        .is_ok()
}

pub fn set_api_key(api_key: String) -> Result<(), String> {
    let mut settings = get_config_manager().load_settings();
    settings.api_key = Some(api_key.clone());
    if let Ok(mut providers) = serde_json::from_str::<Vec<ProviderConfig>>(&settings.providers_json)
    {
        if let Some(zhipu) = providers.iter_mut().find(|p| p.id == "zhipu") {
            zhipu.api_key = Some(api_key);
        }
        if let Ok(json) = serde_json::to_string(&providers) {
            settings.providers_json = json;
        }
    }
    get_config_manager()
        .save_settings(&settings)
        .map_err(|e| e.to_string())
}

pub async fn validate_api_key(
    provider_id: String,
    api_key: String,
    api_url: String,
    model: String,
    protocol: String,
    max_output_tokens: u32,
) -> Result<String, String> {
    let config = ProviderConfig {
        id: provider_id.clone(),
        name: provider_id.clone(),
        api_key: if api_key.trim().is_empty() {
            None
        } else {
            Some(api_key)
        },
        api_url,
        chat_model: model.clone(),
        thinking_model: None,
        protocol,
        max_output_tokens,
    };
    let settings = AppSettings {
        selected_provider: provider_id.clone(),
        providers_json: serde_json::to_string(&vec![config])
            .map_err(|error| format!("连接测试配置无法序列化: {error}"))?,
        ..AppSettings::default()
    };
    let (provider, _) = ProviderRuntime::from_settings(&settings, &provider_id)?;
    let request = serde_json::json!({
        "model": model,
        "messages": [{"role": "user", "content": "Reply with OK only."}],
        "stream": true,
        "max_tokens": 16
    });

    match tokio::time::timeout(
        std::time::Duration::from_secs(45),
        StreamingHandler::stream_chat(&provider, request, |_| {}),
    )
    .await
    {
        Ok(Ok((content, thinking)))
            if !content.trim().is_empty() || !thinking.trim().is_empty() =>
        {
            Ok(format!("{model} 连接成功"))
        }
        Ok(Ok(_)) => Err(format!("{model} 返回了空响应")),
        Ok(Err(error)) => Err(error.to_string()),
        Err(_) => Err(format!("{model} 连接测试超过 45 秒，请检查网络或稍后重试")),
    }
}

pub fn get_available_models() -> Vec<ModelInfo> {
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
    provider_id: String,
    model: String,
    enable_thinking: bool,
    sink: crate::frb_generated::StreamSink<ChatStreamEvent>,
) {
    let settings = get_config_manager().load_settings();
    let (engine, provider) = match create_engine(&settings, &provider_id) {
        Ok(value) => value,
        Err(err) => {
            let _ = sink.add(ChatStreamEvent::Error(err));
            let _ = sink.add(ChatStreamEvent::Done);
            return;
        }
    };
    let chat_model = resolve_chat_model(&model, &provider);
    let thinking_model = provider
        .thinking_model
        .clone()
        .unwrap_or_else(|| provider.chat_model.clone());
    let use_thinking_pipeline = enable_thinking && provider.thinking_model.is_some();
    let (request_id, mut cancel) = register_generation(&conversation_id);

    let done_sent = std::sync::atomic::AtomicBool::new(false);

    let pipeline_result = tokio::select! {
        result = engine.send_message(
            &conversation_id,
            &content,
            &chat_model,
            &thinking_model,
            use_thinking_pipeline,
            |event| {
                if let ChatStreamEvent::Done = &event {
                    done_sent.store(true, std::sync::atomic::Ordering::Release);
                }
                let _ = sink.add(event);
            },
        ) => Some(result),
        _ = cancel.changed() => None,
    };
    unregister_generation(&conversation_id, &request_id);

    match pipeline_result {
        Some(Ok(())) => {}
        Some(Err(e)) => {
            if !done_sent.load(std::sync::atomic::Ordering::Acquire) {
                let _ = sink.add(ChatStreamEvent::Error(e.to_string()));
            }
        }
        None => {
            let _ = sink.add(ChatStreamEvent::Error(
                "__GENERATION_CANCELLED__".to_string(),
            ));
        }
    }

    if !done_sent.load(std::sync::atomic::Ordering::Acquire) {
        let _ = sink.add(ChatStreamEvent::Done);
    }

    tokio::time::sleep(std::time::Duration::from_millis(300)).await;
}

pub async fn regenerate_response(
    conversation_id: String,
    provider_id: String,
    model: String,
    enable_thinking: bool,
    sink: crate::frb_generated::StreamSink<ChatStreamEvent>,
) {
    let settings = get_config_manager().load_settings();
    let (engine, provider) = match create_engine(&settings, &provider_id) {
        Ok(value) => value,
        Err(err) => {
            let _ = sink.add(ChatStreamEvent::Error(err));
            let _ = sink.add(ChatStreamEvent::Done);
            return;
        }
    };
    let chat_model = resolve_chat_model(&model, &provider);
    let thinking_model = provider
        .thinking_model
        .clone()
        .unwrap_or_else(|| provider.chat_model.clone());
    let use_thinking_pipeline = enable_thinking && provider.thinking_model.is_some();
    let (request_id, mut cancel) = register_generation(&conversation_id);

    let done_sent = std::sync::atomic::AtomicBool::new(false);

    let pipeline_result = tokio::select! {
        result = engine.regenerate_response(
            &conversation_id,
            &chat_model,
            &thinking_model,
            use_thinking_pipeline,
            |event| {
                if let ChatStreamEvent::Done = &event {
                    done_sent.store(true, std::sync::atomic::Ordering::Release);
                }
                let _ = sink.add(event);
            },
        ) => Some(result),
        _ = cancel.changed() => None,
    };
    unregister_generation(&conversation_id, &request_id);

    match pipeline_result {
        Some(Ok(())) => {}
        Some(Err(e)) => {
            if !done_sent.load(std::sync::atomic::Ordering::Acquire) {
                let _ = sink.add(ChatStreamEvent::Error(e.to_string()));
            }
        }
        None => {
            let _ = sink.add(ChatStreamEvent::Error(
                "__GENERATION_CANCELLED__".to_string(),
            ));
        }
    }

    if !done_sent.load(std::sync::atomic::Ordering::Acquire) {
        let _ = sink.add(ChatStreamEvent::Done);
    }

    tokio::time::sleep(std::time::Duration::from_millis(300)).await;
}

pub async fn trigger_memory_summarize(
    conversation_id: String,
    sink: crate::frb_generated::StreamSink<ChatStreamEvent>,
) {
    let settings = get_config_manager().load_settings();
    let engine = match create_engine(&settings, &settings.selected_provider) {
        Ok((engine, _)) => engine,
        Err(_) => return,
    };

    let _ = engine
        .summarize_memory(&conversation_id, |event| {
            let _ = sink.add(event);
        })
        .await;
}
