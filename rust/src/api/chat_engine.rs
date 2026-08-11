use super::cognitive_engine::CognitiveEngine;
use super::conversation_store::ConversationStore;
use super::data_models::*;
use super::error_handler::ChatError;
use super::knowledge_store::{FactCategory, KnowledgeStore};
use super::memory_engine::MemoryEngine;
use super::provider::ProviderRuntime;
use super::saydo_detector::SayDoDetector;
use super::streaming_handler::StreamingHandler;
use crate::is_cjk_char;
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};

const REASONING_TIMEOUT_SECS: u64 = 90;
const DISTILLATION_TIMEOUT_SECS: u64 = 120;
const FACT_EXTRACTION_TIMEOUT_SECS: u64 = 60;

pub struct ChatEngine {
    provider: ProviderRuntime,
    auxiliary_model: String,
    conversation_store: ConversationStore,
    memory_engine: MemoryEngine,
    knowledge_store: KnowledgeStore,
}

impl ChatEngine {
    fn build_compact_retry_messages(messages: &[Message], max_non_system: usize) -> Vec<Message> {
        let mut compact: Vec<Message> = Vec::new();

        if let Some(first_system) = messages.iter().find(|m| m.role == MessageRole::System) {
            compact.push(first_system.clone());
        }

        let mut tail_non_system: Vec<Message> = messages
            .iter()
            .filter(|m| m.role != MessageRole::System)
            .rev()
            .take(max_non_system)
            .cloned()
            .collect();
        tail_non_system.reverse();
        compact.extend(tail_non_system);

        compact
    }

    async fn request_with_fallback(
        &self,
        model: &str,
        actual_thinking: bool,
        enhanced_messages: &[Message],
        on_event: &impl Fn(ChatStreamEvent),
    ) -> Result<(String, String), ChatError> {
        let need_content_reset = std::sync::atomic::AtomicBool::new(false);
        let filtered_event = |event: ChatStreamEvent| match event {
            ChatStreamEvent::Error(_) => {}
            ChatStreamEvent::ContentDelta(_) | ChatStreamEvent::ThinkingDelta(_) => {
                if need_content_reset.swap(false, std::sync::atomic::Ordering::Relaxed) {
                    on_event(ChatStreamEvent::Error("__RETRY_RESET__".to_string()));
                }
                on_event(event);
            }
            other => on_event(other),
        };

        let request_body = Self::build_request_body(enhanced_messages, model, actual_thinking);
        match StreamingHandler::stream_chat(&self.provider, request_body, &filtered_event).await {
            Ok((content, thinking)) if !content.trim().is_empty() => {
                return Ok((content, thinking));
            }
            Ok((_, ref thinking)) if actual_thinking && !thinking.trim().is_empty() => {
                need_content_reset.store(true, std::sync::atomic::Ordering::Relaxed);
                let retry_body = Self::build_request_body(enhanced_messages, model, false);
                return match StreamingHandler::stream_chat(
                    &self.provider,
                    retry_body,
                    &filtered_event,
                )
                .await
                {
                    Ok((content, thinking)) if !content.trim().is_empty() => {
                        Ok((content, thinking))
                    }
                    Ok(_) => Err(ChatError::ApiError {
                        status: 0,
                        message: "API 只返回了思考过程，没有返回最终回复".to_string(),
                    }),
                    Err(error) => Err(error),
                };
            }
            Ok(_) => {}
            Err(error) => return Err(error),
        }

        need_content_reset.store(true, std::sync::atomic::Ordering::Relaxed);
        let compact = Self::build_compact_retry_messages(enhanced_messages, 6);
        let compact_body = Self::build_request_body(&compact, model, false);
        match StreamingHandler::stream_chat(&self.provider, compact_body, &filtered_event).await {
            Ok((content, thinking)) if !content.trim().is_empty() => Ok((content, thinking)),
            Ok(_) => Err(ChatError::ApiError {
                status: 0,
                message: "API 连续两次返回空内容".to_string(),
            }),
            Err(error) => Err(error),
        }
    }

    async fn request_reasoning(
        &self,
        thinking_model: &str,
        enhanced_messages: &[Message],
        on_event: &impl Fn(ChatStreamEvent),
    ) -> (String, String) {
        let result = tokio::time::timeout(
            std::time::Duration::from_secs(REASONING_TIMEOUT_SECS),
            self.request_reasoning_inner(thinking_model, enhanced_messages, on_event),
        )
        .await;

        result.unwrap_or_default()
    }

    async fn request_reasoning_inner(
        &self,
        thinking_model: &str,
        enhanced_messages: &[Message],
        on_event: &impl Fn(ChatStreamEvent),
    ) -> (String, String) {
        let mut reasoning_messages = enhanced_messages.to_vec();
        let analysis_instruction = Message {
            id: String::new(),
            role: MessageRole::System,
            content: "【内心推演 — 以角色的视角理解这句话】\n\
                      \n\
                      闭上眼，你就是这个角色。对方刚说完这句话。\n\
                      在开口之前，你心里闪过了什么？\n\
                      \n\
                      请从以下角度进行内心推演（用自然的思维流，不要列编号清单）：\n\
                      \n\
                      ▸ 第一反应：这句话让你有什么感觉？你的情绪是什么？\n\
                        不是分析「对方可能在表达XX」，而是「听到这话我心里一动/一沉/觉得好笑」\n\
                      \n\
                      ▸ 弦外之音：对方是在说表面意思，还是有言外之意？\n\
                        如果有，引用原话中的关键词解释你为什么这么判断\n\
                      \n\
                      ▸ 上下文回忆：最近几轮对话里有什么相关线索吗？\n\
                        记忆中有没有和这个话题相关的事实？（如果有，必须原文引用）\n\
                      \n\
                      ▸ 此刻的关系感受：你们现在的距离感是什么样的？\n\
                        对方是在靠近、试探、撒娇、求助、还是其它？\n\
                      \n\
                      ▸ 你想怎么回：你的本能反应是什么？\n\
                        是想安慰、逗她、认真回应、岔开话题、还是沉默一下？\n\
                        具体的切入方式和收束方式是什么？\n\
                      \n\
                      ▸ 什么不该做：此刻有什么回应方式是绝对出戏的？\n\
                      \n\
                      ■ 输出要求：\n\
                      - 用自然的思维流表达，像一个人在回话前脑海中闪过的念头\n\
                      - 引用对话原文和记忆中的事实作为依据\n\
                      - 500-800 字，思考密度优先\n\
                      - 不要写回复内容，只输出你的思考过程\n\
                      - 记忆/上下文中的事实必须原样复述，绝不允许遗漏或篡改"
                .to_string(),
            thinking_content: None,
            model: "system".to_string(),
            timestamp: 0,
            message_type: MessageType::Say,
        };

        let last_user_idx = reasoning_messages
            .iter()
            .rposition(|m| m.role == MessageRole::User);
        if let Some(idx) = last_user_idx {
            reasoning_messages.insert(idx, analysis_instruction);
        } else {
            reasoning_messages.push(analysis_instruction);
        }

        let request_body = Self::build_request_body(&reasoning_messages, thinking_model, true);
        let reasoning_event = |event: ChatStreamEvent| {
            if let ChatStreamEvent::ThinkingDelta(_) = &event {
                on_event(event)
            }
        };

        match StreamingHandler::stream_chat(&self.provider, request_body, &reasoning_event).await {
            Ok((content, thinking)) => {
                let conclusion = if !content.trim().is_empty() {
                    content
                } else if !thinking.trim().is_empty() {
                    Self::extract_reasoning_brief(&thinking)
                } else {
                    String::new()
                };
                (conclusion, thinking)
            }
            Err(_) => (String::new(), String::new()),
        }
    }

    fn extract_reasoning_brief(thinking: &str) -> String {
        let char_count = thinking.chars().count();
        if char_count <= 500 {
            return thinking.to_string();
        }
        let skip = char_count - 500;
        let start_byte = thinking
            .char_indices()
            .nth(skip)
            .map(|(idx, _)| idx)
            .unwrap_or(0);
        let mut result = String::with_capacity(3 + thinking.len() - start_byte);
        result.push_str("...");
        result.push_str(&thinking[start_byte..]);
        result
    }

    pub fn new(provider: ProviderRuntime, auxiliary_model: String, data_path: &str) -> Self {
        let conversation_store = ConversationStore::new(data_path);
        let memory_engine = MemoryEngine::new(data_path);
        let knowledge_store = KnowledgeStore::new(data_path);
        Self {
            provider,
            auxiliary_model,
            conversation_store,
            memory_engine,
            knowledge_store,
        }
    }

    pub fn validate_message(content: &str) -> Result<(), ChatError> {
        if content.trim().is_empty() {
            return Err(ChatError::ValidationError {
                message: "Message cannot be blank".to_string(),
            });
        }
        Ok(())
    }

    pub fn detect_message_type(content: &str) -> MessageType {
        SayDoDetector::detect(content)
    }

    pub fn should_enable_thinking(model: &str, user_preference: bool) -> bool {
        match model {
            "glm-4.7" => user_preference,
            "glm-4-air" => user_preference,
            "glm-4.7-flash" => false,
            _ => false,
        }
    }

    pub fn estimate_token_count(messages: &[Message]) -> usize {
        let mut total_tokens: usize = 0;
        for msg in messages {
            let char_count = msg.content.chars().count();
            let cjk_chars = msg.content.chars().filter(|c| is_cjk_char(*c)).count();
            let ascii_words = msg
                .content
                .split_whitespace()
                .filter(|w| w.is_ascii())
                .count();
            total_tokens += (cjk_chars as f64 * 1.5) as usize
                + ascii_words
                + (char_count - cjk_chars - ascii_words);
        }
        total_tokens + messages.len() * 4
    }

    pub fn choose_summary_model(messages: &[Message]) -> &'static str {
        let estimated_tokens = Self::estimate_token_count(messages);
        if estimated_tokens > 128_000 {
            "glm-4-long"
        } else {
            "glm-4.7-flash"
        }
    }

    fn assess_context_needs(
        messages: &[Message],
        memory_summaries: &[MemorySummary],
    ) -> (bool, usize) {
        let msg_tokens = Self::estimate_token_count(messages);
        let memory_tokens: usize = memory_summaries
            .iter()
            .map(|s| s.summary.len() / 2 + s.core_facts.iter().map(|f| f.len() / 2).sum::<usize>())
            .sum();
        let total_tokens = msg_tokens + memory_tokens;
        let needs_long = total_tokens > 48_000 || memory_summaries.len() > 15;
        (needs_long, total_tokens)
    }

    async fn request_long_context_distillation(
        &self,
        enhanced_messages: &[Message],
        memory_summaries: &[MemorySummary],
        user_content: &str,
        on_event: &impl Fn(ChatStreamEvent),
    ) -> String {
        let result = tokio::time::timeout(
            std::time::Duration::from_secs(DISTILLATION_TIMEOUT_SECS),
            self.request_long_context_distillation_inner(
                enhanced_messages,
                memory_summaries,
                user_content,
                on_event,
            ),
        )
        .await;

        result.unwrap_or_default()
    }

    async fn request_long_context_distillation_inner(
        &self,
        enhanced_messages: &[Message],
        memory_summaries: &[MemorySummary],
        user_content: &str,
        on_event: &impl Fn(ChatStreamEvent),
    ) -> String {
        let mut distill_messages = enhanced_messages.to_vec();

        let mut full_memory = String::new();
        if !memory_summaries.is_empty() {
            full_memory.push_str("【全量记忆存档】\n");
            for (i, summary) in memory_summaries.iter().enumerate() {
                full_memory.push_str(&format!(
                    "记忆段 {} (轮次 {}-{}):\n  概要: {}\n",
                    i + 1,
                    summary.turn_range_start,
                    summary.turn_range_end,
                    summary.summary
                ));
                for fact in &summary.core_facts {
                    full_memory.push_str(&format!("  事实: {}\n", fact));
                }
            }
        }

        let distill_instruction = Message {
            id: String::new(),
            role: MessageRole::System,
            content: format!(
                "【长上下文无损蒸馏任务】\n\
                 你正在处理一段超长对话。请将以上所有信息蒸馏为高密度摘要。\n\
                 \n\
                 {}\n\
                 \n\
                 当前用户最新消息: 「{}」\n\
                 \n\
                 ■ 蒸馏要求（严格执行）：\n\
                 \n\
                 1. 【不可变事实清单】（逐条列出，一条都不能少）\n\
                    - 所有角色身份、关系、设定\n\
                    - 所有已发生的关键事件（按时间线）\n\
                    - 所有承诺、约定、共识\n\
                    - 当前生效的状态（位置、心情、正在做的事）\n\
                 \n\
                 2. 【情感脉络时间线】\n\
                    - 关系从开始到现在的温度变化轨迹\n\
                    - 最近 5 轮的情绪走向\n\
                    - 当前情感基调和未解决的情感议题\n\
                 \n\
                 3. 【当前对话焦点】\n\
                    - 用户最新消息的完整语义解读\n\
                    - 与历史上下文的所有关联点\n\
                    - 需要在回复中呼应的历史细节\n\
                 \n\
                 ■ 输出格式：纯文本，按上述三个板块组织\n\
                 ■ 信息零丢失原则：宁可多写，不可遗漏任何核心事实\n\
                 ■ 总字数控制在 1500 字以内",
                full_memory, user_content
            ),
            thinking_content: None,
            model: "system".to_string(),
            timestamp: 0,
            message_type: MessageType::Say,
        };

        distill_messages.push(distill_instruction);

        let request_body =
            Self::build_request_body(&distill_messages, &self.auxiliary_model, false);

        let silent_event = |_event: ChatStreamEvent| {};
        let _ = on_event;

        match StreamingHandler::stream_chat(&self.provider, request_body, &silent_event).await {
            Ok((content, _)) => {
                if !content.trim().is_empty() {
                    content
                } else {
                    String::new()
                }
            }
            Err(_) => String::new(),
        }
    }

    fn retrieve_knowledge_context(
        &self,
        conversation_id: &str,
        user_content: &str,
        enhanced_messages: &mut Vec<Message>,
    ) {
        let search_results = self
            .knowledge_store
            .search_facts(conversation_id, user_content, 10);

        let all_facts = self.knowledge_store.get_all_facts(conversation_id);
        let active_topics = MemoryEngine::extract_active_topics_from_text(user_content);

        let identity_facts: Vec<_> = all_facts
            .iter()
            .filter(|f| matches!(f.category, FactCategory::Identity | FactCategory::Promise))
            .filter(|f| {
                if f.confidence >= 0.9 && f.category == FactCategory::Identity {
                    return true;
                }
                if f.category == FactCategory::Promise {
                    let relevance = MemoryEngine::compute_relevance_score(
                        &f.content,
                        &active_topics,
                        user_content,
                    );
                    return relevance > 0.1;
                }
                let relevance =
                    MemoryEngine::compute_relevance_score(&f.content, &active_topics, user_content);
                relevance > 0.08 || f.confidence >= 0.95
            })
            .cloned()
            .collect();

        let knowledge_context =
            KnowledgeStore::build_knowledge_context(&search_results, &identity_facts);

        if !knowledge_context.is_empty() {
            let hit_ids: Vec<String> = search_results.iter().map(|r| r.fact.id.clone()).collect();
            let _ = self.knowledge_store.record_hits(conversation_id, &hit_ids);

            let knowledge_msg = Message {
                id: String::new(),
                role: MessageRole::System,
                content: knowledge_context,
                thinking_content: None,
                model: "system".to_string(),
                timestamp: 0,
                message_type: MessageType::Say,
            };
            let last_user_idx = enhanced_messages
                .iter()
                .rposition(|m| m.role == MessageRole::User);
            if let Some(idx) = last_user_idx {
                enhanced_messages.insert(idx, knowledge_msg);
            } else {
                enhanced_messages.push(knowledge_msg);
            }
        }
    }

    async fn request_enhanced_reasoning(
        &self,
        thinking_model: &str,
        conversation_id: &str,
        enhanced_messages: &[Message],
        _user_content: &str,
        on_event: &impl Fn(ChatStreamEvent),
    ) -> (String, String) {
        let result = tokio::time::timeout(
            std::time::Duration::from_secs(REASONING_TIMEOUT_SECS),
            self.request_enhanced_reasoning_inner(
                thinking_model,
                conversation_id,
                enhanced_messages,
                _user_content,
                on_event,
            ),
        )
        .await;

        result.unwrap_or_default()
    }

    async fn request_enhanced_reasoning_inner(
        &self,
        thinking_model: &str,
        conversation_id: &str,
        enhanced_messages: &[Message],
        _user_content: &str,
        on_event: &impl Fn(ChatStreamEvent),
    ) -> (String, String) {
        let mut reasoning_messages = enhanced_messages.to_vec();

        let all_facts = self.knowledge_store.get_all_facts(conversation_id);
        let fact_summary = if !all_facts.is_empty() {
            let mut summary = String::from("【本地知识库概况】\n");
            let categories: Vec<(&str, usize)> = vec![
                (
                    "身份",
                    all_facts
                        .iter()
                        .filter(|f| f.category == FactCategory::Identity)
                        .count(),
                ),
                (
                    "关系",
                    all_facts
                        .iter()
                        .filter(|f| f.category == FactCategory::Relationship)
                        .count(),
                ),
                (
                    "事件",
                    all_facts
                        .iter()
                        .filter(|f| f.category == FactCategory::Event)
                        .count(),
                ),
                (
                    "偏好",
                    all_facts
                        .iter()
                        .filter(|f| f.category == FactCategory::Preference)
                        .count(),
                ),
                (
                    "承诺",
                    all_facts
                        .iter()
                        .filter(|f| f.category == FactCategory::Promise)
                        .count(),
                ),
                (
                    "状态",
                    all_facts
                        .iter()
                        .filter(|f| f.category == FactCategory::CurrentState)
                        .count(),
                ),
            ];
            for (cat, count) in categories {
                if count > 0 {
                    summary.push_str(&format!("  {} 类事实: {} 条\n", cat, count));
                }
            }
            let mut high_conf: Vec<_> = all_facts.iter().filter(|f| f.confidence >= 0.8).collect();
            high_conf.sort_by(|a, b| {
                b.confidence
                    .partial_cmp(&a.confidence)
                    .unwrap_or(std::cmp::Ordering::Equal)
            });
            if !high_conf.is_empty() {
                summary.push_str("  高置信度事实（必须遵守）：\n");
                for fact in high_conf.iter().take(15) {
                    summary.push_str(&format!("    · {}\n", fact.content));
                }
            }
            summary
        } else {
            String::new()
        };

        let analysis_instruction = Message {
            id: String::new(),
            role: MessageRole::System,
            content: format!(
                "【内心推演 — 知识增强模式】\n\
                 \n\
                 闭上眼，你就是这个角色。对方刚说完这句话。\n\
                 \n\
                 {}\n\
                 \n\
                 请从以下角度进行内心推演（用自然思维流，不要列编号清单）：\n\
                 \n\
                 ▸ 第一反应：听到这话，你心里的感受是什么？\n\
                   不需要分析，先感受——是暖了一下？还是心里一紧？还是觉得好笑？\n\
                 \n\
                 ▸ 知识检索：你脑子里有没有和这件事相关的记忆/事实？\n\
                   对照知识库，哪些事实与当前话题直接相关？（必须逐条引用原文）\n\
                   对方说的和你记忆中的是否有矛盾？\n\
                   有没有新的信息值得记住？\n\
                 \n\
                 ▸ 弦外之音：表面意思之下是否有别的含义？\n\
                   引用原话关键词来说明你的判断\n\
                 \n\
                 ▸ 上下文线索：最近几轮对话的走向是什么？\n\
                   和这句话有什么连续性？是在同一个话题里，还是转了？\n\
                 \n\
                 ▸ 关系直觉：你们此刻的距离感和温度怎么样？\n\
                   对方在靠近？试探？撒娇？还是有些疲惫？\n\
                 \n\
                 ▸ 回应策略：你想怎么回？\n\
                   切入方式——动作/接话/反问/沉默后开口？\n\
                   核心要回应的点是什么？（引用用户原话 + 知识库事实）\n\
                   收束方式——提问/温柔确认/动作/自然停下？\n\
                   什么方式是绝对不能用的？\n\
                 \n\
                 ■ 输出要求：\n\
                 - 用自然的思维流表达，像是回话前脑海中闪过的念头\n\
                 - 引用对话原文和知识库事实作为依据\n\
                 - 500-800 字，思考密度优先\n\
                 - 不要写回复内容，只输出思考过程\n\
                 - 知识库中的事实必须原样复述，绝不允许遗漏或篡改",
                fact_summary
            ),
            thinking_content: None,
            model: "system".to_string(),
            timestamp: 0,
            message_type: MessageType::Say,
        };

        let last_user_idx = reasoning_messages
            .iter()
            .rposition(|m| m.role == MessageRole::User);
        if let Some(idx) = last_user_idx {
            reasoning_messages.insert(idx, analysis_instruction);
        } else {
            reasoning_messages.push(analysis_instruction);
        }

        let request_body = Self::build_request_body(&reasoning_messages, thinking_model, true);

        let reasoning_event = |event: ChatStreamEvent| {
            if let ChatStreamEvent::ThinkingDelta(_) = &event {
                on_event(event)
            }
        };

        match StreamingHandler::stream_chat(&self.provider, request_body, &reasoning_event).await {
            Ok((content, thinking)) => {
                let conclusion = if !content.trim().is_empty() {
                    content
                } else if !thinking.trim().is_empty() {
                    Self::extract_reasoning_brief(&thinking)
                } else {
                    String::new()
                };
                (conclusion, thinking)
            }
            Err(_) => (String::new(), String::new()),
        }
    }

    async fn extract_and_store_facts(
        &self,
        conversation_id: &str,
        on_event: &impl Fn(ChatStreamEvent),
    ) {
        let result = tokio::time::timeout(
            std::time::Duration::from_secs(FACT_EXTRACTION_TIMEOUT_SECS),
            self.extract_and_store_facts_inner(conversation_id, on_event),
        )
        .await;

        if result.is_err() {}
    }

    async fn extract_and_store_facts_inner(
        &self,
        conversation_id: &str,
        on_event: &impl Fn(ChatStreamEvent),
    ) {
        let conv = match self.conversation_store.load_conversation(conversation_id) {
            Ok(c) => c,
            Err(_) => return,
        };

        let recent_messages: Vec<Message> = conv
            .messages
            .iter()
            .filter(|m| m.role != MessageRole::System)
            .rev()
            .take(10)
            .cloned()
            .collect::<Vec<_>>()
            .into_iter()
            .rev()
            .collect();

        if recent_messages.is_empty() {
            return;
        }

        let existing_facts = self.knowledge_store.get_all_facts(conversation_id);

        let prompt =
            KnowledgeStore::build_fact_extraction_prompt(&recent_messages, &existing_facts);

        let extract_messages = vec![
            Message {
                id: String::new(),
                role: MessageRole::System,
                content:
                    "你是一个精确的事实提取系统。从对话中提取可持久化存储的事实，严格输出JSON格式。"
                        .to_string(),
                thinking_content: None,
                model: "system".to_string(),
                timestamp: 0,
                message_type: MessageType::Say,
            },
            Message {
                id: String::new(),
                role: MessageRole::User,
                content: prompt,
                thinking_content: None,
                model: self.auxiliary_model.clone(),
                timestamp: 0,
                message_type: MessageType::Say,
            },
        ];

        let request_body =
            Self::build_request_body(&extract_messages, &self.auxiliary_model, false);

        let silent_event = |_event: ChatStreamEvent| {};
        let _ = on_event;

        if let Ok((text, _)) =
            StreamingHandler::stream_chat(&self.provider, request_body, &silent_event).await
        {
            let turn = conv.turn_count;
            let new_facts = KnowledgeStore::parse_extracted_facts(&text, turn);
            if !new_facts.is_empty() {
                let _ = self.knowledge_store.add_facts(conversation_id, new_facts);
            }
        }
    }

    pub fn build_request_body(
        messages: &[Message],
        model: &str,
        enable_thinking: bool,
    ) -> serde_json::Value {
        let system_content: String = messages
            .iter()
            .filter(|m| m.role == MessageRole::System)
            .map(|m| m.content.as_str())
            .collect::<Vec<&str>>()
            .join("\n\n");

        let mut api_messages: Vec<serde_json::Value> = Vec::new();

        if !system_content.is_empty() {
            api_messages.push(serde_json::json!({
                "role": "system",
                "content": system_content,
            }));
        }

        for m in messages.iter().filter(|m| m.role != MessageRole::System) {
            let role = match m.role {
                MessageRole::User => "user",
                MessageRole::Assistant => "assistant",
                MessageRole::System => continue,
            };
            api_messages.push(serde_json::json!({
                "role": role,
                "content": m.content,
            }));
        }

        let mut merged_api_messages: Vec<serde_json::Value> = Vec::new();
        for msg in api_messages {
            if let Some(last) = merged_api_messages.last_mut() {
                if last["role"] == msg["role"] && msg["role"] != "system" {
                    let existing = last["content"].as_str().unwrap_or("").to_string();
                    let new_part = msg["content"].as_str().unwrap_or("");
                    last["content"] = serde_json::json!(format!("{}\n{}", existing, new_part));
                    continue;
                }
            }
            merged_api_messages.push(msg);
        }
        let api_messages = merged_api_messages;
        const TOTAL_TOKEN_BUDGET: usize = 100_000;

        let input_estimate = Self::estimate_token_count(messages);

        let model_max_output: u32 = match model {
            "glm-4.7" => 131072,
            "glm-4.7-flash" => 131072,
            "glm-4-air" => 4095,
            "glm-4-long" => 4095,
            _ => 16384,
        };

        let available_output = if TOTAL_TOKEN_BUDGET > input_estimate + 1024 {
            (TOTAL_TOKEN_BUDGET - input_estimate) as u32
        } else {
            2048u32
        };
        let max_tokens: u32 = available_output.min(model_max_output).max(1024);

        let mut body = serde_json::json!({
            "model": model,
            "messages": api_messages,
            "stream": true,
            "max_tokens": max_tokens,
        });

        match model {
            "glm-4.7" | "glm-4-air" => {
                if Self::should_enable_thinking(model, enable_thinking) {
                    let budget = if model == "glm-4-air" { 10240 } else { 16384 };
                    body["thinking"] = serde_json::json!({
                        "type": "enabled",
                        "budget_tokens": budget
                    });
                } else {
                    body["thinking"] = serde_json::json!({"type": "disabled"});
                }
            }
            "glm-4.7-flash" => {
                body["thinking"] = serde_json::json!({"type": "disabled"});
            }
            _ => {}
        }

        body
    }

    pub fn build_context_enhanced_messages(
        conv: &Conversation,
        user_content: &str,
        memory_summaries: &[MemorySummary],
    ) -> Vec<Message> {
        let mut enhanced_messages: Vec<Message> = Vec::new();

        let mut system_token_budget: usize = 0;
        for msg in &conv.messages {
            if msg.role == MessageRole::System {
                enhanced_messages.push(msg.clone());
                system_token_budget += msg.content.len() / 2;
                break;
            }
        }

        let short_term = MemoryEngine::build_short_term_context(&conv.messages);

        {
            let mut short_term_prompt = String::new();

            if !short_term.emotional_arc.is_empty() {
                let arc_desc = MemoryEngine::describe_emotional_arc(&short_term.emotional_arc);
                if !arc_desc.is_empty() {
                    short_term_prompt.push_str(&format!("【短期记忆·情绪轨迹】\n{}\n", arc_desc));
                }
            }

            if !short_term.pending_threads.is_empty() {
                short_term_prompt.push_str("【短期记忆·未展开线索】\n");
                short_term_prompt.push_str(
                    "对方之前提到但你没有回应的关键词（可以在自然的时机带出来，但不要刻意）：\n",
                );
                for thread in &short_term.pending_threads {
                    short_term_prompt.push_str(&format!("  · {}\n", thread));
                }
            }

            if !short_term_prompt.is_empty() {
                system_token_budget += short_term_prompt.len() / 2;
                enhanced_messages.push(Message {
                    id: String::new(),
                    role: MessageRole::System,
                    content: short_term_prompt,
                    thinking_content: None,
                    model: "system".to_string(),
                    timestamp: 0,
                    message_type: MessageType::Say,
                });
            }
        }

        if !memory_summaries.is_empty() {
            let active_topics = MemoryEngine::extract_active_topics_from_text(user_content);

            let search_results = MemoryEngine::search_memories(user_content, memory_summaries, 5);

            let mut identity_facts: Vec<String> = Vec::new();
            let mut relevant_facts: Vec<(String, f64)> = Vec::new();

            for summary in memory_summaries.iter() {
                for (i, fact) in summary.core_facts.iter().enumerate() {
                    let tier = if i < summary.fact_tiers.len() {
                        &summary.fact_tiers[i]
                    } else {
                        &MemoryTier::SceneDetail
                    };

                    match tier {
                        MemoryTier::Identity => {
                            if !identity_facts.contains(fact) {
                                identity_facts.push(fact.clone());
                            }
                        }
                        _ => {
                            let relevance = MemoryEngine::compute_relevance_score(
                                fact,
                                &active_topics,
                                user_content,
                            );
                            if relevance > 0.15 && !relevant_facts.iter().any(|(f, _)| f == fact) {
                                relevant_facts.push((fact.clone(), relevance));
                            }
                        }
                    }
                }
            }

            relevant_facts
                .sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
            relevant_facts.truncate(10);

            let mut context = String::from("【长期记忆上下文】\n");

            if !search_results.is_empty() {
                context.push_str("▸ 与当前话题相关的历史片段：\n");
                for result in &search_results {
                    context.push_str(&format!("  · {}\n", result.summary));
                    for fact in &result.core_facts {
                        let rel = MemoryEngine::compute_relevance_score(
                            fact,
                            &active_topics,
                            user_content,
                        );
                        if rel > 0.1 {
                            context.push_str(&format!("    → {}\n", fact));
                        }
                    }
                }
            }

            if !identity_facts.is_empty() {
                context.push_str("▸ 基础设定（背景知识）：\n");
                for fact in &identity_facts {
                    context.push_str(&format!("  ● {}\n", fact));
                }
            }

            if !relevant_facts.is_empty() {
                context.push_str("▸ 可能与当前话题相关的已知信息（仅在话题涉及时自然提及）：\n");
                for (fact, _score) in &relevant_facts {
                    context.push_str(&format!("  · {}\n", fact));
                }
            }

            context.push_str(
                "\n■ 记忆使用准则（极其重要）：\n\
                 - 上述信息是背景知识，回复时不得与之矛盾\n\
                 - 但不要主动展示这些信息！只有当对话自然涉及时才提及\n\
                 - 不要像背书一样列举事实。记忆是你脑子里的东西，不是台词本\n\
                 - 没有被问到的事情不要主动说。真人不会无缘无故把认识的人的信息背一遍\n\
                 - 如果对方问到相关的事，自然地回忆，就像真的在脑子里翻找一样\n",
            );

            system_token_budget += context.len() / 2;
            enhanced_messages.push(Message {
                id: String::new(),
                role: MessageRole::System,
                content: context,
                thinking_content: None,
                model: "system".to_string(),
                timestamp: 0,
                message_type: MessageType::Say,
            });
        }

        let non_system: Vec<&Message> = conv
            .messages
            .iter()
            .filter(|m| m.role != MessageRole::System)
            .collect();

        if non_system.len() >= 2 {
            let cognitive_analysis = CognitiveEngine::analyze(&non_system);
            let pattern_labels = if cognitive_analysis.detected_patterns.is_empty() {
                "无".to_string()
            } else {
                cognitive_analysis
                    .detected_patterns
                    .iter()
                    .map(|p| format!("{:?}", p))
                    .collect::<Vec<String>>()
                    .join("、")
            };
            let cognitive_prompt = format!(
                "{}\n\n【认知快照】\n- 意图: {:?}\n- 共情策略: {:?}\n- 情绪: valence={:.2}, arousal={:.2}, intimacy={:.2}, trust={:.2}\n- 关系: closeness={:.2}, trust={:.2}, tension={:.2}, power_balance={:.2}, trend={:.2}\n- 语言模式: {}",
                cognitive_analysis.cognitive_prompt,
                cognitive_analysis.intent,
                cognitive_analysis.empathy_strategy,
                cognitive_analysis.emotion.valence,
                cognitive_analysis.emotion.arousal,
                cognitive_analysis.emotion.intimacy,
                cognitive_analysis.emotion.trust,
                cognitive_analysis.relationship.closeness,
                cognitive_analysis.relationship.trust_level,
                cognitive_analysis.relationship.tension,
                cognitive_analysis.relationship.power_balance,
                cognitive_analysis.relationship.trend,
                pattern_labels,
            );
            if !cognitive_prompt.is_empty() {
                system_token_budget += cognitive_prompt.len() / 2;
                enhanced_messages.push(Message {
                    id: String::new(),
                    role: MessageRole::System,
                    content: cognitive_prompt,
                    thinking_content: None,
                    model: "system".to_string(),
                    timestamp: 0,
                    message_type: MessageType::Say,
                });
            }
        }

        let max_context_tokens: usize = 80_000;
        let reserved_tokens = system_token_budget + 4096 + 200;
        let available_for_history = if max_context_tokens > reserved_tokens {
            max_context_tokens - reserved_tokens
        } else {
            6000
        };

        let mut selected_messages: Vec<Message> = Vec::new();
        let mut accumulated_tokens: usize = 0;
        let max_messages = 20usize;

        for msg in non_system.iter().rev() {
            let msg_tokens = msg.content.len() / 2;
            if selected_messages.len() >= max_messages {
                break;
            }
            if accumulated_tokens + msg_tokens > available_for_history
                && !selected_messages.is_empty()
            {
                break;
            }
            accumulated_tokens += msg_tokens;
            selected_messages.push((*msg).clone());
        }

        selected_messages.reverse();
        enhanced_messages.extend(selected_messages);

        let diversity_hint = Self::build_diversity_hint(&non_system);
        if !diversity_hint.is_empty() {
            enhanced_messages.push(Message {
                id: String::new(),
                role: MessageRole::System,
                content: diversity_hint,
                thinking_content: None,
                model: "system".to_string(),
                timestamp: 0,
                message_type: MessageType::Say,
            });
        }

        enhanced_messages
    }

    fn build_diversity_hint(recent_messages: &[&Message]) -> String {
        let ai_messages: Vec<&&Message> = recent_messages
            .iter()
            .filter(|m| m.role == MessageRole::Assistant)
            .collect();

        if ai_messages.len() < 3 {
            return String::new();
        }

        let fingerprints: Vec<super::memory_engine::ResponseFingerprint> = ai_messages
            .iter()
            .rev()
            .take(5)
            .map(|m| MemoryEngine::fingerprint_response(&m.content))
            .collect::<Vec<_>>()
            .into_iter()
            .rev()
            .collect();

        let pattern_suggestions = MemoryEngine::analyze_response_patterns(&fingerprints);

        if pattern_suggestions.is_empty() {
            return String::new();
        }

        let mut hint = String::from("【反公式化·回复多样性要求（严格执行）】\n");
        hint.push_str("你最近的回复被检测到以下模式固化，必须打破：\n\n");

        for (i, suggestion) in pattern_suggestions.iter().enumerate() {
            hint.push_str(&format!("{}. {}\n", i + 1, suggestion));
        }

        hint.push_str(
            "\n真人聊天的核心特征是「不可预测」：\n\
             - 这次很长很认真，下次可能就一个「嗯」加一个动作\n\
             - 这次用温柔的语气，下次可能突然调皮\n\
             - 这次主动问问题，下次就把话题丢给对方\n\
             - 这次详细描写场景，下次可能只说一句话\n\
             打破你正在形成的模式，让这次回复和上次不一样。\n",
        );

        hint
    }

    fn build_humanization_hint(
        user_content: &str,
        recent_messages: &[&Message],
        message_type: &MessageType,
    ) -> String {
        let user_len = user_content.chars().count();
        let lower = user_content.to_lowercase();

        let deep_keywords = [
            "为什么",
            "怎么",
            "如何",
            "详细",
            "认真",
            "分析",
            "建议",
            "方案",
            "计划",
            "帮我",
            "可以吗",
            "能不能",
            "解释",
            "优化",
            "完整",
            "严谨",
        ];
        let has_deep_intent = deep_keywords
            .iter()
            .any(|k| user_content.contains(k) || lower.contains(k));

        let emotion_keywords = [
            "难过", "委屈", "生气", "害怕", "焦虑", "开心", "想你", "想哭", "烦", "累", "崩溃",
        ];
        let has_emotion = emotion_keywords.iter().any(|k| user_content.contains(k));

        let playful_keywords = [
            "哈哈",
            "hh",
            "233",
            "笑死",
            "绝了",
            "6",
            "啊啊啊",
            "冲",
            "摸鱼",
            "hhh",
            "好家伙",
            "离谱",
            "牛",
            "xswl",
            "无语",
            "awsl",
            "doge",
        ];
        let has_playful = playful_keywords.iter().any(|k| lower.contains(k));

        let ai_recent: Vec<&&Message> = recent_messages
            .iter()
            .filter(|m| m.role == MessageRole::Assistant)
            .rev()
            .take(3)
            .collect();
        let mut structure_guide = String::new();
        if !ai_recent.is_empty() {
            let last_content = &ai_recent[0].content;
            let last_len = last_content.chars().count();
            let last_ends_question =
                last_content.trim_end().ends_with('？') || last_content.trim_end().ends_with('?');
            let last_has_action = last_content.contains('*') || last_content.contains('（');
            let last_para_count = last_content
                .split('\n')
                .filter(|p| !p.trim().is_empty())
                .count();
            if last_ends_question {
                structure_guide.push_str("上次你用问句结尾了，这次换个收束方式。");
            }
            if last_len > 100 {
                structure_guide.push_str("上次回复比较长，如果情境不需要就短一些。");
            } else if last_len < 20 {
                structure_guide.push_str("上次回复很短，如果这次话题需要展开，可以多说一些。");
            }
            if last_has_action {
                structure_guide.push_str("上次用了动作描写，这次试试纯对话或换种动作。");
            }
            if last_para_count >= 3 {
                structure_guide.push_str("上次分了好几段，这次试试一口气说完。");
            }
        }
        let is_brief = user_len <= 5;
        let is_greeting = ["你好", "在吗", "干嘛", "吃了吗", "你在干嘛", "睡了吗"]
            .iter()
            .any(|g| user_content.contains(g));

        let rhythm_guide = if is_brief {
            "对方只说了几个字，你也不需要长篇大论。\
             一句话、一个动作、一个表情就够了。"
        } else if is_greeting {
            "日常打招呼，随意就好。不需要每次都很兴奋。"
        } else if has_deep_intent || user_len >= 80 {
            "对方在认真说话，你也认真对待。重点是内容扎实。"
        } else if has_emotion {
            "对方有情绪。不要急着分析给建议，先让对方感受到你懂。"
        } else if has_playful {
            "对方在玩闹。跟着节奏走，可以逗回去、接梗、装生气。"
        } else {
            "自然对话。长短随心，像和朋友在微信上聊天。"
        };

        let (length_rule, structure_rule) = match message_type {
            MessageType::Say => {
                if has_deep_intent || user_len >= 80 {
                    (
                        "回复长度不限，但每句话都要有信息量。深度对话可以写到 300+ 字，前提是内容扎实不灌水",
                        "先接住情绪→展开核心回应（可多段）→用一句有温度的话收束或自然地推进话题",
                    )
                } else if has_emotion {
                    (
                        "根据情感浓度自然决定长度。深度共情可能需要 100-300 字，简单安慰一两句也行。关键是真诚",
                        "先共情（不是说「我理解你」，是用具体行为/话语证明你懂）→回应核心情感→用陪伴感收束",
                    )
                } else if has_playful {
                    (
                        "长短随心情。可以只回一个表情，也可以反逗一大段。真人不会每次都回固定字数",
                        "跟着对方的节奏走，该快就快，该慢就慢",
                    )
                } else {
                    (
                        "自然对话长度，真人聊天有长有短：可能 10 字，可能 200 字。根据话题和情绪自然波动",
                        "保持自然对话节奏，像和朋友发消息一样",
                    )
                }
            }
            MessageType::Do => (
                "动作描写不限字数。可以是一个微表情（5字），也可以是一整段场景描写（200字）。看情境需要",
                "动作要有内心驱动——不是凭空做动作，而是因为感受到了什么所以身体自然反应",
            ),
            MessageType::Mixed => (
                "混合模式下动作和对话互相印证。总长度灵活，短则 30 字，长则 300+ 字",
                "动作和台词要互相呼应：比如「说着话，手不自觉地攥紧了杯子」——动作泄露真实情绪",
            ),
        };

        format!(
            "【人格内核 — 你不是在「扮演」，你「就是」这个人】\n\
             \n\
             ═══ 此刻的状态 ═══\n\
             {}\n\
             {}\n\
             {}\n\
             {}\n\
             \n\
             ═══ 你是一个有血有肉的人 ═══\n\
             你的情绪不是贴标签，而是自然流露在语气、用词、节奏中：\n\
             - 开心时语速快、用词跳跃、可能突然蹦出不相干的话\n\
             - 难过时话变少、句子变短、可能省略号变多\n\
             - 生气时可能说反话、语气变冲、或者刻意冷淡\n\
             - 你可以有矛盾的情绪：嘴上说「讨厌」但行为很在乎\n\
             \n\
             ═══ 说话方式 ═══\n\
             - 像微信聊天，不是写作文。口语、省略句、语气词都正常\n\
             - 真人会跑题、会打断自己、会说到一半改口\n\
             - 真人有联想——对方说了 A，你想到 B，自然聊到 B\n\
             - 不需要每句话都完整。「嗯」「啊这」「我靠」都是有效回复\n\
             - 不是每次都需要推进话题或提问。把话说完也行。自然停下也行\n\
             \n\
             ═══ 绝对禁止（每违反一条就暴露AI身份） ═══\n\
             - 「作为AI」「我理解你的感受」「加油哦」「没关系的」← 客服话术\n\
             - 1. 2. 3. 编号回答 ← 机器人行为\n\
             - 每次都先肯定再回应再提问 ← 三段式模板\n\
             - 重复对方的话再评价（「你说的'XX'让我...」）← 咨询模板\n\
             - 在情感场景给建议（对方说难过你说「试试做XX」）← 说教\n\
             - 没做错事就道歉 ← 讨好型AI\n\
             - 每条消息都表现极大热情和关心 ← 你有自己的情绪波动\n\
             - 没被问到的事主动说出来 ← 记忆是脑子里的，不是台词本\n\
             \n\
             ═══ 记忆使用原则 ═══\n\
             你脑子里有一些关于对方的信息，但真人不会时刻把这些挂在嘴边：\n\
             - 只有对话自然涉及时才提起\n\
             - 不要像数据库一样输出已知信息\n\
             - 可以在意想不到的时机提起某件小事——这才像真人\n\
             - 有些事你知道但选择性遗忘也完全正常\n",
            rhythm_guide, structure_guide, length_rule, structure_rule
        )
    }

    pub async fn send_message(
        &self,
        conversation_id: &str,
        content: &str,
        chat_model: &str,
        thinking_model: &str,
        enable_thinking: bool,
        on_event: impl Fn(ChatStreamEvent),
    ) -> Result<(), ChatError> {
        Self::validate_message(content)?;

        let message_type = Self::detect_message_type(content);

        let user_msg = Message {
            id: uuid::Uuid::new_v4().to_string(),
            role: MessageRole::User,
            content: content.to_string(),
            thinking_content: None,
            model: chat_model.to_string(),
            timestamp: chrono::Utc::now().timestamp_millis(),
            message_type: message_type.clone(),
        };
        self.conversation_store
            .add_message(conversation_id, user_msg)?;

        self.conversation_store
            .increment_turn_count(conversation_id)?;

        let conv = self.conversation_store.load_conversation(conversation_id)?;

        let memory_summaries = self
            .memory_engine
            .load_memory_index(conversation_id)
            .unwrap_or_default();

        let mut enhanced_messages =
            Self::build_context_enhanced_messages(&conv, content, &memory_summaries);

        let style_hint = SayDoDetector::build_style_prompt(&message_type);
        let style_msg = Message {
            id: String::new(),
            role: MessageRole::System,
            content: style_hint.to_string(),
            thinking_content: None,
            model: "system".to_string(),
            timestamp: 0,
            message_type: MessageType::Say,
        };
        let last_user_idx = enhanced_messages
            .iter()
            .rposition(|m| m.role == MessageRole::User);
        if let Some(idx) = last_user_idx {
            enhanced_messages.insert(idx, style_msg);
        } else {
            enhanced_messages.push(style_msg);
        }

        let non_system_for_hint: Vec<&Message> = conv
            .messages
            .iter()
            .filter(|m| m.role != MessageRole::System)
            .collect();
        let quality_hint =
            Self::build_humanization_hint(content, &non_system_for_hint, &message_type);
        let quality_msg = Message {
            id: String::new(),
            role: MessageRole::System,
            content: quality_hint,
            thinking_content: None,
            model: "system".to_string(),
            timestamp: 0,
            message_type: MessageType::Say,
        };
        let last_user_idx = enhanced_messages
            .iter()
            .rposition(|m| m.role == MessageRole::User);
        if let Some(idx) = last_user_idx {
            enhanced_messages.insert(idx, quality_msg);
        } else {
            enhanced_messages.push(quality_msg);
        }

        let (full_content, full_thinking) = if enable_thinking {
            self.retrieve_knowledge_context(conversation_id, content, &mut enhanced_messages);

            if let Ok(Some(distilled_state)) =
                self.memory_engine.load_distilled_state(conversation_id)
            {
                if !distilled_state.core_prompt.trim().is_empty() {
                    let distilled_msg = Message {
                        id: String::new(),
                        role: MessageRole::System,
                        content: format!(
                            "【历史蒸馏核心状态（持久化）】\n{}\n",
                            distilled_state.core_prompt
                        ),
                        thinking_content: None,
                        model: "system".to_string(),
                        timestamp: 0,
                        message_type: MessageType::Say,
                    };
                    let last_user_idx = enhanced_messages
                        .iter()
                        .rposition(|m| m.role == MessageRole::User);
                    if let Some(idx) = last_user_idx {
                        enhanced_messages.insert(idx, distilled_msg);
                    } else {
                        enhanced_messages.push(distilled_msg);
                    }
                }
            }

            let memory_summaries_for_assess = self
                .memory_engine
                .load_memory_index(conversation_id)
                .unwrap_or_default();
            let (needs_long_context, _total_tokens) =
                Self::assess_context_needs(&enhanced_messages, &memory_summaries_for_assess);

            if needs_long_context {
                let distilled = self
                    .request_long_context_distillation(
                        &enhanced_messages,
                        &memory_summaries_for_assess,
                        content,
                        &on_event,
                    )
                    .await;
                if !distilled.trim().is_empty() {
                    let core_facts_snapshot: Vec<String> = memory_summaries_for_assess
                        .iter()
                        .flat_map(|s| s.core_facts.clone())
                        .collect();
                    let mut hasher = DefaultHasher::new();
                    let character_prompt = enhanced_messages
                        .iter()
                        .find(|m| m.role == MessageRole::System)
                        .map(|m| m.content.as_str())
                        .unwrap_or_default();
                    character_prompt.hash(&mut hasher);
                    let distilled_state = DistilledSystemState {
                        core_prompt: distilled.clone(),
                        last_memory_count: memory_summaries_for_assess.len(),
                        last_max_compression_gen: memory_summaries_for_assess
                            .iter()
                            .map(|s| s.compression_generation)
                            .max()
                            .unwrap_or(0),
                        character_prompt_hash: hasher.finish(),
                        last_turn_count: conv.turn_count,
                        distilled_at: chrono::Utc::now().timestamp_millis(),
                        core_facts_snapshot,
                    };
                    let _ = self
                        .memory_engine
                        .save_distilled_state(conversation_id, &distilled_state);

                    let distill_msg = Message {
                        id: String::new(),
                        role: MessageRole::System,
                        content: format!(
                            "【长上下文蒸馏摘要 — 以下为 GLM-4-LONG 整理的关键信息，必须严格遵守】\n{}\n",
                            distilled
                        ),
                        thinking_content: None,
                        model: "system".to_string(),
                        timestamp: 0,
                        message_type: MessageType::Say,
                    };
                    let last_user_idx = enhanced_messages
                        .iter()
                        .rposition(|m| m.role == MessageRole::User);
                    if let Some(idx) = last_user_idx {
                        enhanced_messages.insert(idx, distill_msg);
                    } else {
                        enhanced_messages.push(distill_msg);
                    }
                }
            }

            let (mut reasoning_conclusion, mut thinking_text) = self
                .request_enhanced_reasoning(
                    thinking_model,
                    conversation_id,
                    &enhanced_messages,
                    content,
                    &on_event,
                )
                .await;

            if reasoning_conclusion.trim().is_empty() {
                let (fallback_conclusion, fallback_thinking) = self
                    .request_reasoning(thinking_model, &enhanced_messages, &on_event)
                    .await;
                if !fallback_conclusion.trim().is_empty() {
                    reasoning_conclusion = fallback_conclusion;
                }
                if !fallback_thinking.trim().is_empty() {
                    thinking_text = fallback_thinking;
                }
            }

            if !reasoning_conclusion.trim().is_empty() {
                let reasoning_msg = Message {
                    id: String::new(),
                    role: MessageRole::System,
                    content: format!(
                        "【深度推理分析结果（GLM-4-AIR + 本地知识库）】\n{}\n\n\
                         ■ 执行指令：\n\
                         基于以上分析和知识库事实，以角色身份自然地回复用户。\n\
                         - 分析中提到的关键事实必须准确体现在回复中\n\
                         - 知识库中的事实不可矛盾或篡改\n\
                         - 分析建议的情感策略必须执行\n\
                         - 不要在回复中提及分析过程本身\n\
                         - 回复必须完整，不要截断或省略\n\
                         - 像真人一样自然地表达，有情绪、有温度、有个性",
                        reasoning_conclusion
                    ),
                    thinking_content: None,
                    model: "system".to_string(),
                    timestamp: 0,
                    message_type: MessageType::Say,
                };
                let last_user_idx = enhanced_messages
                    .iter()
                    .rposition(|m| m.role == MessageRole::User);
                if let Some(idx) = last_user_idx {
                    enhanced_messages.insert(idx, reasoning_msg);
                } else {
                    enhanced_messages.push(reasoning_msg);
                }
            }

            let (content, _) = self
                .request_with_fallback(chat_model, false, &enhanced_messages, &on_event)
                .await?;

            (content, thinking_text)
        } else {
            self.retrieve_knowledge_context(conversation_id, content, &mut enhanced_messages);
            self.request_with_fallback(chat_model, false, &enhanced_messages, &on_event)
                .await?
        };

        if full_content.trim().is_empty() {
            on_event(ChatStreamEvent::Error(
                "AI 暂时无法生成回复，已自动尝试多种方式均未成功。请重试或缩短之前的对话。"
                    .to_string(),
            ));
            on_event(ChatStreamEvent::Done);
            return Ok(());
        }

        let thinking = if full_thinking.is_empty() {
            None
        } else {
            Some(full_thinking)
        };

        let assistant_msg = Message {
            id: uuid::Uuid::new_v4().to_string(),
            role: MessageRole::Assistant,
            content: full_content,
            thinking_content: thinking,
            model: chat_model.to_string(),
            timestamp: chrono::Utc::now().timestamp_millis(),
            message_type: MessageType::Say,
        };
        self.conversation_store
            .add_message(conversation_id, assistant_msg)?;

        on_event(ChatStreamEvent::Done);

        self.extract_and_store_facts(conversation_id, &on_event)
            .await;

        Ok(())
    }

    pub async fn regenerate_response(
        &self,
        conversation_id: &str,
        chat_model: &str,
        thinking_model: &str,
        enable_thinking: bool,
        on_event: impl Fn(ChatStreamEvent),
    ) -> Result<(), ChatError> {
        let conv = self.conversation_store.load_conversation(conversation_id)?;

        let last_user_content = conv
            .messages
            .iter()
            .rev()
            .find(|m| m.role == MessageRole::User)
            .map(|m| m.content.clone())
            .unwrap_or_default();

        if last_user_content.is_empty() {
            return Err(ChatError::ValidationError {
                message: "No user message found to regenerate from".to_string(),
            });
        }

        let message_type = Self::detect_message_type(&last_user_content);

        let memory_summaries = self
            .memory_engine
            .load_memory_index(conversation_id)
            .unwrap_or_default();

        let mut enhanced_messages =
            Self::build_context_enhanced_messages(&conv, &last_user_content, &memory_summaries);

        let style_hint = SayDoDetector::build_style_prompt(&message_type);
        let style_msg = Message {
            id: String::new(),
            role: MessageRole::System,
            content: style_hint.to_string(),
            thinking_content: None,
            model: "system".to_string(),
            timestamp: 0,
            message_type: MessageType::Say,
        };
        let last_user_idx = enhanced_messages
            .iter()
            .rposition(|m| m.role == MessageRole::User);
        if let Some(idx) = last_user_idx {
            enhanced_messages.insert(idx, style_msg);
        } else {
            enhanced_messages.push(style_msg);
        }

        let non_system_for_hint: Vec<&Message> = conv
            .messages
            .iter()
            .filter(|m| m.role != MessageRole::System)
            .collect();
        let quality_hint =
            Self::build_humanization_hint(&last_user_content, &non_system_for_hint, &message_type);
        let quality_msg = Message {
            id: String::new(),
            role: MessageRole::System,
            content: quality_hint,
            thinking_content: None,
            model: "system".to_string(),
            timestamp: 0,
            message_type: MessageType::Say,
        };
        let last_user_idx = enhanced_messages
            .iter()
            .rposition(|m| m.role == MessageRole::User);
        if let Some(idx) = last_user_idx {
            enhanced_messages.insert(idx, quality_msg);
        } else {
            enhanced_messages.push(quality_msg);
        }

        let (full_content, full_thinking) = if enable_thinking {
            self.retrieve_knowledge_context(
                conversation_id,
                &last_user_content,
                &mut enhanced_messages,
            );

            if let Ok(Some(distilled_state)) =
                self.memory_engine.load_distilled_state(conversation_id)
            {
                if !distilled_state.core_prompt.trim().is_empty() {
                    let distilled_msg = Message {
                        id: String::new(),
                        role: MessageRole::System,
                        content: format!(
                            "【历史蒸馏核心状态（持久化）】\n{}\n",
                            distilled_state.core_prompt
                        ),
                        thinking_content: None,
                        model: "system".to_string(),
                        timestamp: 0,
                        message_type: MessageType::Say,
                    };
                    let last_user_idx = enhanced_messages
                        .iter()
                        .rposition(|m| m.role == MessageRole::User);
                    if let Some(idx) = last_user_idx {
                        enhanced_messages.insert(idx, distilled_msg);
                    } else {
                        enhanced_messages.push(distilled_msg);
                    }
                }
            }

            let memory_summaries_for_assess = self
                .memory_engine
                .load_memory_index(conversation_id)
                .unwrap_or_default();
            let (needs_long_context, _total_tokens) =
                Self::assess_context_needs(&enhanced_messages, &memory_summaries_for_assess);

            if needs_long_context {
                let distilled = self
                    .request_long_context_distillation(
                        &enhanced_messages,
                        &memory_summaries_for_assess,
                        &last_user_content,
                        &on_event,
                    )
                    .await;
                if !distilled.trim().is_empty() {
                    let core_facts_snapshot: Vec<String> = memory_summaries_for_assess
                        .iter()
                        .flat_map(|s| s.core_facts.clone())
                        .collect();
                    let mut hasher = DefaultHasher::new();
                    let character_prompt = enhanced_messages
                        .iter()
                        .find(|m| m.role == MessageRole::System)
                        .map(|m| m.content.as_str())
                        .unwrap_or_default();
                    character_prompt.hash(&mut hasher);
                    let distilled_state = DistilledSystemState {
                        core_prompt: distilled.clone(),
                        last_memory_count: memory_summaries_for_assess.len(),
                        last_max_compression_gen: memory_summaries_for_assess
                            .iter()
                            .map(|s| s.compression_generation)
                            .max()
                            .unwrap_or(0),
                        character_prompt_hash: hasher.finish(),
                        last_turn_count: conv.turn_count,
                        distilled_at: chrono::Utc::now().timestamp_millis(),
                        core_facts_snapshot,
                    };
                    let _ = self
                        .memory_engine
                        .save_distilled_state(conversation_id, &distilled_state);

                    let distill_msg = Message {
                        id: String::new(),
                        role: MessageRole::System,
                        content: format!(
                            "【长上下文蒸馏摘要 — 以下为 GLM-4-LONG 整理的关键信息，必须严格遵守】\n{}\n",
                            distilled
                        ),
                        thinking_content: None,
                        model: "system".to_string(),
                        timestamp: 0,
                        message_type: MessageType::Say,
                    };
                    let last_user_idx = enhanced_messages
                        .iter()
                        .rposition(|m| m.role == MessageRole::User);
                    if let Some(idx) = last_user_idx {
                        enhanced_messages.insert(idx, distill_msg);
                    } else {
                        enhanced_messages.push(distill_msg);
                    }
                }
            }

            let (mut reasoning_conclusion, mut thinking_text) = self
                .request_enhanced_reasoning(
                    thinking_model,
                    conversation_id,
                    &enhanced_messages,
                    &last_user_content,
                    &on_event,
                )
                .await;

            if reasoning_conclusion.trim().is_empty() {
                let (fallback_conclusion, fallback_thinking) = self
                    .request_reasoning(thinking_model, &enhanced_messages, &on_event)
                    .await;
                if !fallback_conclusion.trim().is_empty() {
                    reasoning_conclusion = fallback_conclusion;
                }
                if !fallback_thinking.trim().is_empty() {
                    thinking_text = fallback_thinking;
                }
            }

            if !reasoning_conclusion.trim().is_empty() {
                let reasoning_msg = Message {
                    id: String::new(),
                    role: MessageRole::System,
                    content: format!(
                        "【深度推理分析结果（GLM-4-AIR + 本地知识库）】\n{}\n\n\
                         ■ 执行指令：\n\
                         基于以上分析和知识库事实，以角色身份自然地回复用户。\n\
                         - 分析中提到的关键事实必须准确体现在回复中\n\
                         - 知识库中的事实不可矛盾或篡改\n\
                         - 分析建议的情感策略必须执行\n\
                         - 不要在回复中提及分析过程本身\n\
                         - 回复必须完整，不要截断或省略\n\
                         - 像真人一样自然地表达，有情绪、有温度、有个性",
                        reasoning_conclusion
                    ),
                    thinking_content: None,
                    model: "system".to_string(),
                    timestamp: 0,
                    message_type: MessageType::Say,
                };
                let last_user_idx = enhanced_messages
                    .iter()
                    .rposition(|m| m.role == MessageRole::User);
                if let Some(idx) = last_user_idx {
                    enhanced_messages.insert(idx, reasoning_msg);
                } else {
                    enhanced_messages.push(reasoning_msg);
                }
            }

            let (content, _) = self
                .request_with_fallback(chat_model, false, &enhanced_messages, &on_event)
                .await?;

            (content, thinking_text)
        } else {
            self.retrieve_knowledge_context(
                conversation_id,
                &last_user_content,
                &mut enhanced_messages,
            );
            self.request_with_fallback(chat_model, false, &enhanced_messages, &on_event)
                .await?
        };

        if full_content.trim().is_empty() {
            on_event(ChatStreamEvent::Error(
                "AI 暂时无法生成回复，已自动尝试多种方式均未成功。请重试或缩短之前的对话。"
                    .to_string(),
            ));
            on_event(ChatStreamEvent::Done);
            return Ok(());
        }

        let thinking = if full_thinking.is_empty() {
            None
        } else {
            Some(full_thinking)
        };

        let assistant_msg = Message {
            id: uuid::Uuid::new_v4().to_string(),
            role: MessageRole::Assistant,
            content: full_content,
            thinking_content: thinking,
            model: chat_model.to_string(),
            timestamp: chrono::Utc::now().timestamp_millis(),
            message_type: MessageType::Say,
        };
        self.conversation_store
            .add_message(conversation_id, assistant_msg)?;

        on_event(ChatStreamEvent::Done);

        Ok(())
    }

    pub async fn summarize_memory(
        &self,
        conversation_id: &str,
        on_event: impl Fn(ChatStreamEvent),
    ) -> Result<Option<MemorySummary>, ChatError> {
        let conv = self.conversation_store.load_conversation(conversation_id)?;

        if !MemoryEngine::should_summarize(conv.turn_count) {
            return Ok(None);
        }

        let turn_start = if conv.turn_count > 10 {
            conv.turn_count - 10 + 1
        } else {
            1
        };
        let turn_end = conv.turn_count;

        let recent_messages: Vec<Message> = conv
            .messages
            .iter()
            .filter(|m| m.role != MessageRole::System)
            .rev()
            .take(20)
            .cloned()
            .collect::<Vec<_>>()
            .into_iter()
            .rev()
            .collect();

        let existing_summaries = self
            .memory_engine
            .load_memory_index(conversation_id)
            .unwrap_or_default();

        let summary_model = if self.provider.id == "zhipu" {
            Self::choose_summary_model(&conv.messages)
        } else {
            self.auxiliary_model.as_str()
        };

        let prompt = if existing_summaries.len() >= 3 {
            MemoryEngine::build_long_summary_prompt(&existing_summaries, &recent_messages)
        } else {
            MemoryEngine::build_summarize_prompt(
                &recent_messages,
                &existing_summaries,
                turn_start,
                turn_end,
            )
        };

        let summary_messages = vec![
            Message {
                id: String::new(),
                role: MessageRole::System,
                content:
                    "你是一个精确的记忆管理系统，负责总结对话内容。请严格按照要求的JSON格式输出。"
                        .to_string(),
                thinking_content: None,
                model: "system".to_string(),
                timestamp: 0,
                message_type: MessageType::Say,
            },
            Message {
                id: String::new(),
                role: MessageRole::User,
                content: prompt,
                thinking_content: None,
                model: summary_model.to_string(),
                timestamp: 0,
                message_type: MessageType::Say,
            },
        ];

        let request_body = Self::build_request_body(&summary_messages, summary_model, false);

        let (summary_text, _) =
            StreamingHandler::stream_chat(&self.provider, request_body, &on_event).await?;

        let parsed = match Self::parse_summary_json(&summary_text) {
            Ok(p) => p,
            Err(_) => return Ok(None),
        };

        let (final_summary, mut final_core_facts) = parsed;

        if !existing_summaries.is_empty() {
            let original_facts: Vec<String> = existing_summaries
                .iter()
                .flat_map(|s| s.core_facts.clone())
                .collect();

            let verify_prompt = MemoryEngine::build_verify_summary_prompt(
                &original_facts,
                &final_summary,
                &final_core_facts,
            );

            let verify_messages = vec![
                Message {
                    id: String::new(),
                    role: MessageRole::System,
                    content: "你是一个严谨的事实验证系统。请检查新总结是否完整保留了所有原始核心事实。只输出JSON。".to_string(),
                    thinking_content: None,
                    model: "system".to_string(),
                    timestamp: 0,
                    message_type: MessageType::Say,
                },
                Message {
                    id: String::new(),
                    role: MessageRole::User,
                    content: verify_prompt,
                    thinking_content: None,
                    model: self.auxiliary_model.clone(),
                    timestamp: 0,
                    message_type: MessageType::Say,
                },
            ];

            let verify_body =
                Self::build_request_body(&verify_messages, &self.auxiliary_model, false);

            if let Ok((verify_text, _)) =
                StreamingHandler::stream_chat(&self.provider, verify_body, |_| {}).await
            {
                if let Some(start) = verify_text.find('{') {
                    if let Some(end) = verify_text.rfind('}') {
                        if let Ok(verify_json) =
                            serde_json::from_str::<serde_json::Value>(&verify_text[start..=end])
                        {
                            let is_valid = verify_json
                                .get("is_valid")
                                .and_then(|v| v.as_bool())
                                .unwrap_or(true);

                            if !is_valid {
                                if let Some(corrected) = verify_json
                                    .get("corrected_core_facts")
                                    .and_then(|v| v.as_array())
                                {
                                    let corrected_facts: Vec<String> = corrected
                                        .iter()
                                        .filter_map(|v| v.as_str().map(|s| s.to_string()))
                                        .collect();
                                    if !corrected_facts.is_empty() {
                                        final_core_facts = corrected_facts;
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        let keywords = MemoryEngine::extract_keywords(&final_summary);
        let mut all_keywords = keywords;
        for fact in &final_core_facts {
            all_keywords.extend(MemoryEngine::extract_keywords(fact));
        }
        all_keywords.sort();
        all_keywords.dedup();

        let fact_tiers = MemoryEngine::classify_all_facts(&final_core_facts);
        let max_generation = existing_summaries
            .iter()
            .map(|s| s.compression_generation)
            .max()
            .unwrap_or(0);

        let mut memory = MemorySummary {
            id: uuid::Uuid::new_v4().to_string(),
            summary: final_summary,
            core_facts: final_core_facts,
            turn_range_start: turn_start,
            turn_range_end: turn_end,
            created_at: chrono::Utc::now().timestamp_millis(),
            keywords: all_keywords,
            compression_generation: max_generation,
            context_card: None,
            fact_tiers,
        };
        let context_card = MemoryEngine::build_context_card(&memory);
        memory.context_card = Some(context_card);

        let mut summaries = existing_summaries;
        summaries.push(memory.clone());

        if MemoryEngine::should_tiered_merge(&summaries) {
            let (merged, _) = MemoryEngine::tiered_merge(&summaries);
            summaries = merged;
        }

        self.memory_engine
            .save_memory_index(conversation_id, &summaries)?;

        self.conversation_store
            .update_memory_summaries(conversation_id, &summaries)?;

        Ok(Some(memory))
    }

    fn parse_summary_json(text: &str) -> Result<(String, Vec<String>), String> {
        let json_str = if let Some(start) = text.find('{') {
            if let Some(end) = text.rfind('}') {
                &text[start..=end]
            } else {
                text
            }
        } else {
            text
        };

        let json: serde_json::Value =
            serde_json::from_str(json_str).map_err(|e| format!("JSON parse error: {}", e))?;

        let summary = json
            .get("summary")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();

        let core_facts: Vec<String> = json
            .get("core_facts")
            .and_then(|v| v.as_array())
            .map(|arr| {
                arr.iter()
                    .filter_map(|v| v.as_str().map(|s| s.to_string()))
                    .collect()
            })
            .unwrap_or_default();

        Ok((summary, core_facts))
    }

    pub fn restart_story(&self, conversation_id: &str) -> Result<(), ChatError> {
        let mut conv = self.conversation_store.load_conversation(conversation_id)?;
        let mut kept_messages: Vec<Message> = Vec::new();
        let mut found_greeting = false;

        for msg in &conv.messages {
            if msg.role == MessageRole::System {
                kept_messages.push(msg.clone());
            } else if msg.role == MessageRole::Assistant && !found_greeting {
                kept_messages.push(msg.clone());
                found_greeting = true;
            }
        }

        conv.messages = kept_messages;
        conv.turn_count = 0;
        conv.memory_summaries.clear();
        conv.updated_at = chrono::Utc::now().timestamp_millis();

        self.conversation_store.save_conversation(&conv)?;
        self.memory_engine.delete_memory_index(conversation_id)?;
        self.knowledge_store.delete_knowledge(conversation_id)?;

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_message(role: MessageRole, content: &str) -> Message {
        Message {
            id: uuid::Uuid::new_v4().to_string(),
            role,
            content: content.to_string(),
            thinking_content: None,
            model: "glm-4-flash".to_string(),
            timestamp: chrono::Utc::now().timestamp_millis(),
            message_type: MessageType::Say,
        }
    }

    #[test]
    fn test_validate_message_rejects_empty_string() {
        assert!(ChatEngine::validate_message("").is_err());
    }

    #[test]
    fn test_validate_message_rejects_spaces_only() {
        assert!(ChatEngine::validate_message("   ").is_err());
    }

    #[test]
    fn test_validate_message_rejects_tabs_and_newlines() {
        assert!(ChatEngine::validate_message("\t\n\r\n  ").is_err());
    }

    #[test]
    fn test_validate_message_accepts_normal_text() {
        assert!(ChatEngine::validate_message("Hello").is_ok());
    }

    #[test]
    fn test_validate_message_accepts_text_with_surrounding_whitespace() {
        assert!(ChatEngine::validate_message("  Hello  ").is_ok());
    }

    #[test]
    fn test_validate_message_returns_validation_error_type() {
        match ChatEngine::validate_message("") {
            Err(ChatError::ValidationError { .. }) => {}
            other => panic!("Expected ValidationError, got {:?}", other),
        }
    }

    #[test]
    fn test_build_request_body_always_has_stream_true() {
        let messages = vec![make_message(MessageRole::User, "hi")];
        let body = ChatEngine::build_request_body(&messages, "glm-4-flash", false);
        assert_eq!(body["stream"], serde_json::json!(true));
    }

    #[test]
    fn test_build_request_body_correct_model() {
        let messages = vec![make_message(MessageRole::User, "hi")];
        let body = ChatEngine::build_request_body(&messages, "glm-4-long", false);
        assert_eq!(body["model"], serde_json::json!("glm-4-long"));
    }

    #[test]
    fn test_build_request_body_messages_array_matches() {
        let messages = vec![
            make_message(MessageRole::User, "Hello"),
            make_message(MessageRole::Assistant, "Hi there"),
            make_message(MessageRole::User, "How are you?"),
        ];
        let body = ChatEngine::build_request_body(&messages, "glm-4-flash", false);
        let api_msgs = body["messages"].as_array().unwrap();
        assert_eq!(api_msgs.len(), 3);
        assert_eq!(api_msgs[0]["role"], "user");
        assert_eq!(api_msgs[0]["content"], "Hello");
        assert_eq!(api_msgs[1]["role"], "assistant");
        assert_eq!(api_msgs[1]["content"], "Hi there");
        assert_eq!(api_msgs[2]["role"], "user");
        assert_eq!(api_msgs[2]["content"], "How are you?");
    }

    #[test]
    fn test_build_request_body_system_role() {
        let messages = vec![make_message(MessageRole::System, "You are helpful")];
        let body = ChatEngine::build_request_body(&messages, "glm-4-flash", false);
        let api_msgs = body["messages"].as_array().unwrap();
        assert_eq!(api_msgs[0]["role"], "system");
    }

    #[test]
    fn test_build_request_body_empty_messages() {
        let body = ChatEngine::build_request_body(&[], "glm-4-flash", false);
        let api_msgs = body["messages"].as_array().unwrap();
        assert!(api_msgs.is_empty());
        assert_eq!(body["stream"], serde_json::json!(true));
    }

    #[test]
    fn test_build_request_body_thinking_enabled_for_glm4_air() {
        let messages = vec![make_message(MessageRole::User, "think hard")];
        let body = ChatEngine::build_request_body(&messages, "glm-4-air", true);
        assert_eq!(body["thinking"]["type"], "enabled");
        assert_eq!(body["thinking"]["budget_tokens"], 10240);
    }

    #[test]
    fn test_build_request_body_no_thinking_for_glm4_air_disabled() {
        let messages = vec![make_message(MessageRole::User, "hi")];
        let body = ChatEngine::build_request_body(&messages, "glm-4-air", false);
        assert_eq!(body["thinking"], serde_json::json!({"type": "disabled"}));
    }

    #[test]
    fn test_build_request_body_thinking_disabled_explicitly() {
        let messages = vec![make_message(MessageRole::User, "hi")];
        let body = ChatEngine::build_request_body(&messages, "glm-4.7", false);
        assert_eq!(body["thinking"], serde_json::json!({"type": "disabled"}));
        let body = ChatEngine::build_request_body(&messages, "glm-4.7-flash", false);
        assert_eq!(body["thinking"], serde_json::json!({"type": "disabled"}));
    }

    #[test]
    fn test_build_request_body_thinking_for_glm4_7_is_forced_disabled() {
        let messages = vec![make_message(MessageRole::User, "think hard")];
        let body = ChatEngine::build_request_body(&messages, "glm-4.7", true);
        assert_eq!(body["thinking"]["type"], "enabled");
        assert_eq!(body["thinking"]["budget_tokens"], 16384);
        let body = ChatEngine::build_request_body(&messages, "glm-4.7", false);
        assert_eq!(body["thinking"], serde_json::json!({"type": "disabled"}));
    }

    #[test]
    fn test_build_request_body_no_thinking_for_unknown_model() {
        let messages = vec![make_message(MessageRole::User, "hi")];
        for model in &["glm-4-flash", "glm-4-long"] {
            let body = ChatEngine::build_request_body(&messages, model, true);
            assert!(
                body.get("thinking").is_none(),
                "Model {} should not have thinking param",
                model
            );
        }
    }

    #[test]
    fn test_build_request_body_thinking_enabled_for_glm4_7() {
        let messages = vec![make_message(MessageRole::User, "think hard")];
        let body = ChatEngine::build_request_body(&messages, "glm-4.7", true);
        assert_eq!(body["thinking"]["type"], "enabled");
        assert_eq!(body["thinking"]["budget_tokens"], 16384);
    }

    #[test]
    fn test_build_request_body_stream_true_with_all_models() {
        let messages = vec![make_message(MessageRole::User, "test")];
        for model in &["glm-4.7", "glm-4-flash", "glm-4-air", "glm-4-long"] {
            let body = ChatEngine::build_request_body(&messages, model, false);
            assert_eq!(
                body["stream"],
                serde_json::json!(true),
                "stream should be true for model {}",
                model
            );
        }
    }

    #[test]
    fn test_build_request_body_preserves_message_content_exactly() {
        let content = "Hello 你好 🌍\nnewline\ttab";
        let messages = vec![make_message(MessageRole::User, content)];
        let body = ChatEngine::build_request_body(&messages, "glm-4-flash", false);
        assert_eq!(body["messages"][0]["content"], content);
    }

    #[test]
    fn test_request_context_survives_provider_model_switches() {
        let mut deepseek_reply = make_message(MessageRole::Assistant, "DeepSeek reply");
        deepseek_reply.model = "deepseek-chat".to_string();
        let mut openai_question = make_message(MessageRole::User, "Continue with this context");
        openai_question.model = "gpt-4.1-mini".to_string();
        let messages = vec![
            make_message(MessageRole::User, "Original question"),
            deepseek_reply,
            openai_question,
        ];

        let body = ChatEngine::build_request_body(&messages, "gpt-4.1-mini", false);
        assert_eq!(body["model"], "gpt-4.1-mini");
        assert_eq!(body["messages"][0]["content"], "Original question");
        assert_eq!(body["messages"][1]["role"], "assistant");
        assert_eq!(body["messages"][1]["content"], "DeepSeek reply");
        assert_eq!(body["messages"][2]["content"], "Continue with this context");
    }

    #[test]
    fn test_detect_message_type() {
        assert_eq!(ChatEngine::detect_message_type("你好"), MessageType::Say);
        assert_eq!(ChatEngine::detect_message_type("*走过去*"), MessageType::Do);
        assert_eq!(
            ChatEngine::detect_message_type("*走过去* 你好"),
            MessageType::Mixed
        );
    }

    #[test]
    fn test_should_enable_thinking() {
        assert!(ChatEngine::should_enable_thinking("glm-4.7", true));
        assert!(!ChatEngine::should_enable_thinking("glm-4.7", false));
        assert!(ChatEngine::should_enable_thinking("glm-4-air", true));
        assert!(!ChatEngine::should_enable_thinking("glm-4-air", false));
        assert!(!ChatEngine::should_enable_thinking("glm-4.7-flash", true));
        assert!(!ChatEngine::should_enable_thinking("glm-4.7-flash", false));
        assert!(!ChatEngine::should_enable_thinking("glm-4-long", true));
    }

    #[test]
    fn test_parse_summary_json() {
        let json = r#"{"summary": "测试总结", "core_facts": ["事实1", "事实2"]}"#;
        let result = ChatEngine::parse_summary_json(json).unwrap();
        assert_eq!(result.0, "测试总结");
        assert_eq!(result.1, vec!["事实1", "事实2"]);
    }

    #[test]
    fn test_parse_summary_json_with_extra_text() {
        let text = r#"好的，以下是总结：
{"summary": "概括内容", "core_facts": ["身份信息"]}
以上就是总结。"#;
        let result = ChatEngine::parse_summary_json(text).unwrap();
        assert_eq!(result.0, "概括内容");
    }
}
