use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock, Weak};

use tokio::sync::watch;

use super::chat_engine::ChatEngine;
use super::config_manager::ConfigManager;
use super::conversation_store::ConversationStore;
use super::data_models::*;
use super::error_handler::ChatError;
use super::knowledge_store::KnowledgeStore;
use super::memory_engine::MemoryEngine;
use super::network_diagnosis::{diagnose, EndpointDiagnosis};
use super::provider::ProviderRuntime;
use super::streaming_handler::StreamingHandler;

static CONFIG_MANAGER: OnceLock<ConfigManager> = OnceLock::new();
static CONVERSATION_STORE: OnceLock<ConversationStore> = OnceLock::new();
static DATA_PATH: OnceLock<String> = OnceLock::new();
static ACTIVE_GENERATIONS: OnceLock<Mutex<HashMap<String, ActiveGeneration>>> = OnceLock::new();
static GENERATION_GATES: OnceLock<Mutex<HashMap<String, Weak<tokio::sync::Mutex<()>>>>> =
    OnceLock::new();

struct ActiveGeneration {
    request_id: String,
    cancel: watch::Sender<bool>,
}

struct GenerationRegistration {
    conversation_id: String,
    request_id: String,
    gate: Arc<tokio::sync::Mutex<()>>,
}

impl Drop for GenerationRegistration {
    fn drop(&mut self) {
        unregister_generation(&self.conversation_id, &self.request_id);
    }
}

fn active_generations() -> &'static Mutex<HashMap<String, ActiveGeneration>> {
    ACTIVE_GENERATIONS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn register_generation(conversation_id: &str) -> (GenerationRegistration, watch::Receiver<bool>) {
    let request_id = uuid::Uuid::new_v4().to_string();
    let (cancel, receiver) = watch::channel(false);
    let mut active = active_generations()
        .lock()
        .unwrap_or_else(|error| error.into_inner());
    // A cancelled waiter may disappear before its predecessor finishes. Keep
    // gates independently of the latest registration so a third request still
    // waits for the predecessor's interrupted-reply commit.
    let mut gates = GENERATION_GATES
        .get_or_init(|| Mutex::new(HashMap::new()))
        .lock()
        .unwrap_or_else(|error| error.into_inner());
    gates.retain(|_, gate| gate.strong_count() > 0);
    let gate = gates
        .get(conversation_id)
        .and_then(Weak::upgrade)
        .unwrap_or_else(|| Arc::new(tokio::sync::Mutex::new(())));
    gates.insert(conversation_id.to_string(), Arc::downgrade(&gate));
    if let Some(previous) = active.insert(
        conversation_id.to_string(),
        ActiveGeneration {
            request_id: request_id.clone(),
            cancel,
        },
    ) {
        let _ = previous.cancel.send(true);
    }
    (
        GenerationRegistration {
            conversation_id: conversation_id.to_string(),
            request_id,
            gate,
        },
        receiver,
    )
}

async fn run_until_cancelled<T>(
    cancel: &mut watch::Receiver<bool>,
    work: impl std::future::Future<Output = T>,
) -> Option<T> {
    if *cancel.borrow() {
        return None;
    }
    tokio::select! {
        biased;
        _ = cancel.changed() => None,
        result = work => Some(result),
    }
}

/// Persist only against the exact history used by this generation. This also
/// replaces the rejected assistant reply when a regeneration is interrupted.
fn persist_interrupted_reply(
    store: &ConversationStore,
    snapshot: Option<&Conversation>,
    model: &str,
    content: &str,
    thinking: &str,
) -> Result<(), ChatError> {
    if content.trim().is_empty() {
        return Ok(());
    }
    let Some(snapshot) = snapshot else {
        return Ok(());
    };
    let message = Message {
        id: uuid::Uuid::new_v4().to_string(),
        role: MessageRole::Assistant,
        content: content.to_string(),
        thinking_content: (!thinking.trim().is_empty()).then(|| thinking.to_string()),
        model: model.to_string(),
        timestamp: crate::api::clock::now_millis(),
        message_type: MessageType::Say,
    };
    store.commit_reply(snapshot, message).map(|_| ())
}

#[derive(Default, Clone)]
struct PartialReply {
    content: String,
    thinking: String,
}

impl PartialReply {
    fn record(&mut self, event: &ChatStreamEvent) {
        match event {
            ChatStreamEvent::ContentDelta(delta) => self.content.push_str(delta),
            ChatStreamEvent::ThinkingDelta(delta) => self.thinking.push_str(delta),
            ChatStreamEvent::Error(error) if error == "__RETRY_RESET__" => {
                self.content.clear();
                self.thinking.clear();
            }
            _ => {}
        }
    }
}

fn unregister_generation(conversation_id: &str, request_id: &str) {
    let mut active = active_generations()
        .lock()
        .unwrap_or_else(|error| error.into_inner());
    if active
        .get(conversation_id)
        .is_some_and(|generation| generation.request_id == request_id)
    {
        active.remove(conversation_id);
    }
}

pub fn cancel_generation(conversation_id: String) -> bool {
    let active = active_generations()
        .lock()
        .unwrap_or_else(|error| error.into_inner());
    // Keep registration until cleanup has committed any partial answer.
    active
        .get(&conversation_id)
        .is_some_and(|generation| generation.cancel.send(true).is_ok())
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
        timestamp: crate::api::clock::now_millis(),
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
        timestamp: crate::api::clock::now_millis(),
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
        timestamp: crate::api::clock::now_millis(),
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
        timestamp: crate::api::clock::now_millis(),
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

    let api_url = provider.api_url.clone();
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
        Ok(Err(error)) => {
            let message = error.to_string();
            if matches!(error, ChatError::NetworkError { .. }) {
                if let Some(hint) = diagnose(&api_url)
                    .await
                    .and_then(EndpointDiagnosis::into_hint)
                {
                    return Err(format!("{message}；{hint}"));
                }
            }
            Err(message)
        }
        Err(_) => Err(format!("{model} 连接测试超过 45 秒，请检查网络或稍后重试")),
    }
}

pub fn get_available_models() -> Vec<ModelInfo> {
    // `supports_thinking` is "this model reasons", taken from the vendor
    // capability registry instead of being asserted here. GLM-4.7-Flash always
    // reasons, so the old hard-coded `false` advertised the opposite of what the
    // model does.
    let model = |id: &str, name: &str, context_tokens: usize, max_output_tokens: usize| ModelInfo {
        id: id.to_string(),
        name: name.to_string(),
        context_tokens,
        max_output_tokens,
        supports_thinking: crate::api::model_policy::can_reason(id),
    };
    vec![
        model("glm-4.7", "GLM-4.7（对话+思考）", 128_000, 131_072),
        model("glm-4-air", "GLM-4-Air（深度推理）", 128_000, 4_095),
        model("glm-4.7-flash", "GLM-4.7-Flash（快速）", 128_000, 131_072),
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
    let (registration, mut cancel) = register_generation(&conversation_id);
    let gate = registration.gate.clone();
    let Some(permit) = run_until_cancelled(&mut cancel, gate.lock_owned()).await else {
        let _ = sink.add(ChatStreamEvent::Error(
            "__GENERATION_CANCELLED__".to_string(),
        ));
        let _ = sink.add(ChatStreamEvent::Done);
        return;
    };
    let snapshot = Mutex::new(None::<Conversation>);

    let done_sent = std::sync::atomic::AtomicBool::new(false);
    let partial = Mutex::new(PartialReply::default());

    let pipeline_result = run_until_cancelled(
        &mut cancel,
        engine.send_message_with_snapshot(
            &conversation_id,
            &content,
            &chat_model,
            &thinking_model,
            use_thinking_pipeline,
            |conversation| {
                *snapshot.lock().unwrap_or_else(|error| error.into_inner()) =
                    Some(conversation.clone());
            },
            |event| {
                partial
                    .lock()
                    .unwrap_or_else(|error| error.into_inner())
                    .record(&event);
                if matches!(&event, ChatStreamEvent::Done) {
                    done_sent.store(true, std::sync::atomic::Ordering::Release);
                }
                let _ = sink.add(event);
            },
        ),
    )
    .await;

    match pipeline_result {
        Some(Ok(())) => {}
        Some(Err(e)) => {
            if !done_sent.load(std::sync::atomic::Ordering::Acquire) {
                let _ = sink.add(ChatStreamEvent::Error(e.to_string()));
            }
        }
        None => {
            let interrupted = partial
                .lock()
                .unwrap_or_else(|error| error.into_inner())
                .clone();
            // Done means the engine already committed the complete reply and
            // is only extracting facts. Do not replace it with a partial buffer.
            if !done_sent.load(std::sync::atomic::Ordering::Acquire) {
                let snapshot = snapshot.lock().unwrap_or_else(|error| error.into_inner());
                if let Err(error) = persist_interrupted_reply(
                    get_conversation_store(),
                    snapshot.as_ref(),
                    &chat_model,
                    &interrupted.content,
                    &interrupted.thinking,
                ) {
                    let _ = sink.add(ChatStreamEvent::Error(error.to_string()));
                }
                let _ = sink.add(ChatStreamEvent::Error(
                    "__GENERATION_CANCELLED__".to_string(),
                ));
            }
        }
    }

    if !done_sent.load(std::sync::atomic::Ordering::Acquire) {
        let _ = sink.add(ChatStreamEvent::Done);
    }

    // Release only after partial persistence and terminal events. The next
    // request must build its context from the final history of this request.
    drop(permit);
    drop(registration);
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
    let (registration, mut cancel) = register_generation(&conversation_id);
    let gate = registration.gate.clone();
    let Some(permit) = run_until_cancelled(&mut cancel, gate.lock_owned()).await else {
        let _ = sink.add(ChatStreamEvent::Error(
            "__GENERATION_CANCELLED__".to_string(),
        ));
        let _ = sink.add(ChatStreamEvent::Done);
        return;
    };
    let snapshot = Mutex::new(None::<Conversation>);

    let done_sent = std::sync::atomic::AtomicBool::new(false);
    let partial = Mutex::new(PartialReply::default());

    let pipeline_result = run_until_cancelled(
        &mut cancel,
        engine.regenerate_response_with_snapshot(
            &conversation_id,
            &chat_model,
            &thinking_model,
            use_thinking_pipeline,
            |conversation| {
                *snapshot.lock().unwrap_or_else(|error| error.into_inner()) =
                    Some(conversation.clone());
            },
            |event| {
                partial
                    .lock()
                    .unwrap_or_else(|error| error.into_inner())
                    .record(&event);
                if matches!(&event, ChatStreamEvent::Done) {
                    done_sent.store(true, std::sync::atomic::Ordering::Release);
                }
                let _ = sink.add(event);
            },
        ),
    )
    .await;

    match pipeline_result {
        Some(Ok(())) => {}
        Some(Err(e)) => {
            if !done_sent.load(std::sync::atomic::Ordering::Acquire) {
                let _ = sink.add(ChatStreamEvent::Error(e.to_string()));
            }
        }
        None => {
            let interrupted = partial
                .lock()
                .unwrap_or_else(|error| error.into_inner())
                .clone();
            // Done means the engine already committed the complete reply and
            // is only extracting facts. Do not replace it with a partial buffer.
            if !done_sent.load(std::sync::atomic::Ordering::Acquire) {
                let snapshot = snapshot.lock().unwrap_or_else(|error| error.into_inner());
                if let Err(error) = persist_interrupted_reply(
                    get_conversation_store(),
                    snapshot.as_ref(),
                    &chat_model,
                    &interrupted.content,
                    &interrupted.thinking,
                ) {
                    let _ = sink.add(ChatStreamEvent::Error(error.to_string()));
                }
                let _ = sink.add(ChatStreamEvent::Error(
                    "__GENERATION_CANCELLED__".to_string(),
                ));
            }
        }
    }

    if !done_sent.load(std::sync::atomic::Ordering::Acquire) {
        let _ = sink.add(ChatStreamEvent::Done);
    }

    // Release only after partial persistence and terminal events. The next
    // request must build its context from the final history of this request.
    drop(permit);
    drop(registration);
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

#[cfg(test)]
mod tests {
    use super::*;

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

    #[tokio::test]
    async fn cancellation_wins_before_ready_work_is_polled() {
        let (sender, mut receiver) = watch::channel(false);
        sender.send(true).unwrap();
        let polled = std::cell::Cell::new(false);
        let result = run_until_cancelled(&mut receiver, async {
            polled.set(true);
            42
        })
        .await;
        assert_eq!(result, None);
        assert!(!polled.get(), "cancelled work must not append a user turn");
    }

    #[tokio::test]
    async fn replacement_and_cancel_keep_predecessor_gate_alive() {
        let id = uuid::Uuid::new_v4().to_string();
        let (first, first_cancel) = register_generation(&id);
        let permit = first.gate.clone().lock_owned().await;
        let (second, second_cancel) = register_generation(&id);
        assert!(*first_cancel.borrow());
        assert!(Arc::ptr_eq(&first.gate, &second.gate));
        assert!(cancel_generation(id.clone()));
        assert!(*second_cancel.borrow());
        drop(second);
        // The latest waiter can exit before the cancelled predecessor has
        // committed its partial reply. A third request must still wait.
        let (third, third_cancel) = register_generation(&id);
        assert!(Arc::ptr_eq(&first.gate, &third.gate));
        assert!(third.gate.try_lock().is_err());
        drop(first);
        assert!(!*third_cancel.borrow());
        assert!(
            cancel_generation(id.clone()),
            "old cleanup must not unregister the replacement"
        );
        drop(permit);
        assert!(third.gate.try_lock().is_ok());
        drop(third);
        assert!(!cancel_generation(id));
    }

    #[test]
    fn unrelated_conversations_have_independent_gates() {
        let (first, _) = register_generation(&uuid::Uuid::new_v4().to_string());
        let (second, _) = register_generation(&uuid::Uuid::new_v4().to_string());
        assert!(!Arc::ptr_eq(&first.gate, &second.gate));
    }

    #[test]
    fn interrupted_regeneration_saves_visible_text_and_thinking_exactly() {
        let dir = tempfile::tempdir().unwrap();
        let store = ConversationStore::new(dir.path().to_str().unwrap());
        let conversation = store.create_conversation();
        store.save_conversation(&conversation).unwrap();
        store
            .add_user_turn(&conversation.id, message(MessageRole::User, "question"))
            .unwrap();
        let rejected = message(MessageRole::Assistant, "rejected");
        store
            .add_message(&conversation.id, rejected.clone())
            .unwrap();
        let snapshot = store.load_conversation(&conversation.id).unwrap();
        persist_interrupted_reply(
            &store,
            Some(&snapshot),
            "new-model",
            "  partial\n",
            "reasoning",
        )
        .unwrap();
        let loaded = store.load_conversation(&conversation.id).unwrap();
        assert_eq!(loaded.messages.len(), 2);
        assert_eq!(loaded.messages[1].id, rejected.id);
        assert_eq!(loaded.messages[1].content, "  partial\n");
        assert_eq!(
            loaded.messages[1].thinking_content.as_deref(),
            Some("reasoning")
        );
        assert_eq!(loaded.messages[1].model, "new-model");
        // A second cleanup against the old snapshot cannot overwrite it.
        persist_interrupted_reply(&store, Some(&snapshot), "new-model", "stale", "").unwrap();
        assert_eq!(
            store.load_conversation(&conversation.id).unwrap().messages[1].content,
            "  partial\n"
        );
    }

    #[test]
    fn retry_reset_excludes_discarded_text_from_interrupted_reply() {
        let mut partial = PartialReply::default();
        partial.record(&ChatStreamEvent::ContentDelta(
            "discarded answer".to_string(),
        ));
        partial.record(&ChatStreamEvent::ThinkingDelta(
            "discarded thinking".to_string(),
        ));
        partial.record(&ChatStreamEvent::Error("__RETRY_RESET__".to_string()));
        partial.record(&ChatStreamEvent::ContentDelta("visible answer".to_string()));
        partial.record(&ChatStreamEvent::ThinkingDelta(
            "visible thinking".to_string(),
        ));
        assert_eq!(partial.content, "visible answer");
        assert_eq!(partial.thinking, "visible thinking");
    }

    #[tokio::test]
    async fn next_generation_reads_committed_interrupted_history() {
        let dir = tempfile::tempdir().unwrap();
        let store = ConversationStore::new(dir.path().to_str().unwrap());
        let conversation = store.create_conversation();
        store.save_conversation(&conversation).unwrap();
        let (first, _first_cancel) = register_generation(&conversation.id);
        let first_permit = first.gate.clone().lock_owned().await;
        let snapshot = store
            .add_user_turn(&conversation.id, message(MessageRole::User, "first"))
            .unwrap();
        assert!(cancel_generation(conversation.id.clone()));
        let (second, mut second_cancel) = register_generation(&conversation.id);
        assert!(second.gate.try_lock().is_err());
        persist_interrupted_reply(
            &store,
            Some(&snapshot),
            "test-model",
            "interrupted first reply",
            "",
        )
        .unwrap();
        drop(first_permit);
        drop(first);
        let _second_permit =
            run_until_cancelled(&mut second_cancel, second.gate.clone().lock_owned())
                .await
                .unwrap();
        let context = store
            .add_user_turn(&conversation.id, message(MessageRole::User, "second"))
            .unwrap();
        assert_eq!(
            context
                .messages
                .iter()
                .map(|m| m.content.as_str())
                .collect::<Vec<_>>(),
            vec!["first", "interrupted first reply", "second"]
        );
        assert_eq!(context.turn_count, 2);
    }
}
