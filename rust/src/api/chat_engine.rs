use super::cognitive_engine::CognitiveEngine;
use super::conversation_store::ConversationStore;
use super::data_models::*;
use super::error_handler::ChatError;
use super::jwt_auth::JwtAuth;
use super::knowledge_store::{FactCategory, KnowledgeStore};
use super::memory_engine::MemoryEngine;
use super::saydo_detector::SayDoDetector;
use super::streaming_handler::StreamingHandler;
use log;
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};

const BIGMODEL_API_URL: &str = "https://open.bigmodel.cn/api/paas/v4/chat/completions";

const REASONING_TIMEOUT_SECS: u64 = 90;
const DISTILLATION_TIMEOUT_SECS: u64 = 120;
const FACT_EXTRACTION_TIMEOUT_SECS: u64 = 60;

// ═══ 模型上下文窗口限制 ═══
#[allow(dead_code)]
const GLM_47_MAX_CONTEXT: usize = 128_000;
const GLM_47_FLASH_MAX_CONTEXT: usize = 128_000;
#[allow(dead_code)]
const GLM_4_AIR_MAX_CONTEXT: usize = 128_000;
#[allow(dead_code)]
const GLM_4_LONG_MAX_CONTEXT: usize = 1_000_000;
#[allow(dead_code)]
const GLM_4_LONG_MAX_OUTPUT: usize = 4_095;
const GLM_4_LONG_SAFE_INPUT: usize = 900_000; // 留出输出 + 系统开销空间

// 双层思考超时
const DUAL_THINKING_TIMEOUT_SECS: u64 = 180;
const SYNTHESIS_TIMEOUT_SECS: u64 = 90;
const SUMMARIZE_VERIFY_TIMEOUT_SECS: u64 = 120;

// 验证流程最大重试次数
const MAX_VERIFY_ATTEMPTS: usize = 3;

pub struct ChatEngine {
    jwt_auth: std::sync::Mutex<JwtAuth>,
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
        let token = {
            let mut auth = self.jwt_auth.lock().unwrap();
            auth.get_token()
        };

        let attempt_count = std::sync::atomic::AtomicU32::new(0);
        let need_content_reset = std::sync::atomic::AtomicBool::new(false);
        let intermediate_errors = std::sync::Mutex::new(Vec::<String>::new());
        let filtered_event = |event: ChatStreamEvent| match event {
            ChatStreamEvent::Error(ref msg) => {
                if let Ok(mut errs) = intermediate_errors.lock() {
                    errs.push(msg.clone());
                }
            }
            ChatStreamEvent::ContentDelta(_) | ChatStreamEvent::ThinkingDelta(_) => {
                if need_content_reset.swap(false, std::sync::atomic::Ordering::Relaxed) {
                    on_event(ChatStreamEvent::Error("__RETRY_RESET__".to_string()));
                }
                on_event(event);
            }
            other => on_event(other),
        };

        let request_body = Self::build_request_body(enhanced_messages, model, actual_thinking);
        log::info!(
            "[request_with_fallback] 第1次尝试 | model={} | thinking={} | messages={}",
            model, actual_thinking, enhanced_messages.len()
        );
        match StreamingHandler::stream_chat(BIGMODEL_API_URL, &token, request_body, &filtered_event)
            .await
        {
            Ok((content, thinking)) if !content.trim().is_empty() => {
                return Ok((content, thinking));
            }
            Ok((_, ref thinking)) if actual_thinking && !thinking.trim().is_empty() => {
                attempt_count.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                need_content_reset.store(true, std::sync::atomic::Ordering::Relaxed);
                let retry_body = Self::build_request_body(enhanced_messages, model, false);
                match StreamingHandler::stream_chat(
                    BIGMODEL_API_URL,
                    &token,
                    retry_body,
                    &filtered_event,
                )
                .await
                {
                    Ok((content, thinking)) if !content.trim().is_empty() => {
                        return Ok((content, thinking));
                    }
                    _ => {}
                }
            }
            Ok(_) => {}
            Err(_) => {}
        }

        attempt_count.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        need_content_reset.store(true, std::sync::atomic::Ordering::Relaxed);
        log::warn!("[request_with_fallback] 降级为6条紧凑消息 | model={}", model);
        let compact = Self::build_compact_retry_messages(enhanced_messages, 6);
        let compact_body = Self::build_request_body(&compact, model, false);
        match StreamingHandler::stream_chat(BIGMODEL_API_URL, &token, compact_body, &filtered_event)
            .await
        {
            Ok((content, thinking)) if !content.trim().is_empty() => {
                return Ok((content, thinking));
            }
            _ => {}
        }

        need_content_reset.store(true, std::sync::atomic::Ordering::Relaxed);
        let ultra_compact = Self::build_compact_retry_messages(enhanced_messages, 4);
        let fallback_model = if model != "glm-4.7-flash" {
            "glm-4.7-flash"
        } else {
            model
        };
        log::warn!(
            "[request_with_fallback] 最终降级 | model={} | messages=4",
            fallback_model
        );
        let fallback_body = Self::build_request_body(&ultra_compact, fallback_model, false);
        match StreamingHandler::stream_chat(
            BIGMODEL_API_URL,
            &token,
            fallback_body,
            &filtered_event,
        )
        .await
        {
            Ok((content, thinking)) if !content.trim().is_empty() => Ok((content, thinking)),
            Ok(_) => {
                let diag = if let Ok(errs) = intermediate_errors.lock() {
                    if errs.is_empty() {
                        "AI 暂时无法生成回复，请稍后重试".to_string()
                    } else {
                        format!(
                            "AI 多次未能生成回复: {}",
                            errs.last().unwrap_or(&String::new())
                        )
                    }
                } else {
                    "AI 暂时无法生成回复，请稍后重试".to_string()
                };
                Err(ChatError::ApiError {
                    status: 0,
                    message: diag,
                })
            }
            Err(e) => Err(e),
        }
    }

    /// ══ 推理模型调用（Phase 1）══
    /// 调用推理模型（glm-4-air）进行深度分析，返回 (推理结论, 完整思考链)。
    /// - 推理结论：glm-4-air 的 content 输出（供对话模型参考的结构化分析）
    /// - 完整思考链：glm-4-air 的 reasoning_content（实时流式推送给前端）
    ///
    /// 此方法为"尽力而为"：推理失败不阻断对话，仅返回空串。
    /// 增加超时保护：最多等待 REASONING_TIMEOUT_SECS 秒。
    ///
    /// 注：当前管线使用 request_enhanced_reasoning 替代，
    /// 保留此方法作为轻量级备选方案。
    #[allow(dead_code)]
    async fn request_reasoning(
        &self,
        thinking_model: &str,
        enhanced_messages: &[Message],
        on_event: &impl Fn(ChatStreamEvent),
    ) -> (String, String) {
        // 使用 tokio::time::timeout 保护推理调用，防止无限等待
        let result = tokio::time::timeout(
            std::time::Duration::from_secs(REASONING_TIMEOUT_SECS),
            self.request_reasoning_inner(thinking_model, enhanced_messages, on_event),
        )
        .await;

        result.unwrap_or_default()
    }

    /// request_reasoning 的内部实现（无超时保护）
    #[allow(dead_code)]
    async fn request_reasoning_inner(
        &self,
        thinking_model: &str,
        enhanced_messages: &[Message],
        on_event: &impl Fn(ChatStreamEvent),
    ) -> (String, String) {
        let token = {
            let mut auth = self.jwt_auth.lock().unwrap();
            auth.get_token()
        };

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

        // 将分析指令插入到最后一条用户消息之前
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

        match StreamingHandler::stream_chat(
            BIGMODEL_API_URL,
            &token,
            request_body,
            &reasoning_event,
        )
        .await
        {
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
        let chars: Vec<char> = thinking.chars().collect();
        if chars.len() <= 500 {
            thinking.to_string()
        } else {
            let start = chars.len() - 500;
            format!("...{}", chars[start..].iter().collect::<String>())
        }
    }

    pub fn new(api_key: &str, data_path: &str) -> Result<Self, String> {
        let jwt_auth = JwtAuth::new(api_key)?;
        let conversation_store = ConversationStore::new(data_path);
        let memory_engine = MemoryEngine::new(data_path);
        let knowledge_store = KnowledgeStore::new(data_path);
        Ok(Self {
            jwt_auth: std::sync::Mutex::new(jwt_auth),
            conversation_store,
            memory_engine,
            knowledge_store,
        })
    }

    /// Validate message content — reject blank messages (whitespace-only).
    pub fn validate_message(content: &str) -> Result<(), ChatError> {
        if content.trim().is_empty() {
            return Err(ChatError::ValidationError {
                message: "Message cannot be blank".to_string(),
            });
        }
        Ok(())
    }

    /// 自动检测消息的 say/do 类型
    pub fn detect_message_type(content: &str) -> MessageType {
        SayDoDetector::detect(content)
    }

    /// 根据模型判断是否允许启用思考（用于 build_request_body 的安全守卫）
    ///
    /// 参考 GLM 思考模式文档: https://docs.bigmodel.cn/cn/guide/capabilities/thinking-mode
    /// - GLM-4.7: 默认开启 Thinking，支持轮级思考、交错式思考、保留式思考
    /// - GLM-4-AIR: 推理专用模型，支持思考
    /// - GLM-4.7-FLASH: 快速模型，支持思考模式
    pub fn should_enable_thinking(model: &str, user_preference: bool) -> bool {
        match model {
            // GLM-4.7: 文档明确支持思考模式（默认开启）
            "glm-4.7" => user_preference,
            // GLM-4-AIR: 推理模型，支持思考
            "glm-4-air" => user_preference,
            // GLM-4.7-FLASH: 快速模型，支持思考模式
            "glm-4.7-flash" => user_preference,
            _ => false,
        }
    }

    /// 估算消息列表的 token 数
    /// 改进版：基于字符数而非 UTF-8 字节数，对中文更准确
    /// 中文 1 字 ≈ 1.5 token，英文 1 词 ≈ 1 token
    pub fn estimate_token_count(messages: &[Message]) -> usize {
        let mut total_tokens: usize = 0;
        for msg in messages {
            let char_count = msg.content.chars().count();
            // 统计中文字符占比，动态调整 token 估算系数
            let cjk_chars = msg
                .content
                .chars()
                .filter(|c| *c > '\u{4e00}' && *c < '\u{9fff}')
                .count();
            let ascii_words = msg
                .content
                .split_whitespace()
                .filter(|w| w.is_ascii())
                .count();
            // 中文按 1.5 token/字，英文按 1 token/词，其他按 1
            total_tokens += (cjk_chars as f64 * 1.5) as usize
                + ascii_words
                + (char_count - cjk_chars - ascii_words);
        }
        // 加上消息格式开销（每条消息约 4 token 的格式开销）
        total_tokens + messages.len() * 4
    }

    /// 根据上下文长度选择总结模型
    /// 超过 128K token 使用 glm-4-long，否则使用 glm-4.7-flash
    pub fn choose_summary_model(messages: &[Message]) -> &'static str {
        let estimated_tokens = Self::estimate_token_count(messages);
        if estimated_tokens > 128_000 {
            "glm-4-long"
        } else {
            "glm-4.7-flash"
        }
    }

    /// 评估上下文复杂度，决定是否需要 GLM-4-LONG 辅助处理
    /// 返回: (是否需要长上下文蒸馏, 估算总 token 数)
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
        // 当总 token 超过 GLM-4.7/Flash 上下文窗口的 70%（约90K）或记忆条目超过 20 条时触发
        let needs_long = total_tokens > 90_000 || memory_summaries.len() > 20;
        (needs_long, total_tokens)
    }

    /// ══ 长上下文蒸馏（GLM-4-LONG）══
    /// 当对话历史+记忆超过 GLM-4-AIR 的有效处理范围时，
    /// 先用 GLM-4-LONG 进行无损信息蒸馏，提取核心脉络，
    /// 再将蒸馏结果注入后续管线。
    ///
    /// 增加超时保护：最多等待 DISTILLATION_TIMEOUT_SECS 秒。
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

    /// request_long_context_distillation 的内部实现
    async fn request_long_context_distillation_inner(
        &self,
        enhanced_messages: &[Message],
        memory_summaries: &[MemorySummary],
        user_content: &str,
        on_event: &impl Fn(ChatStreamEvent),
    ) -> String {
        let token = {
            let mut auth = self.jwt_auth.lock().unwrap();
            auth.get_token()
        };

        // 构建蒸馏请求上下文
        let mut distill_messages = enhanced_messages.to_vec();

        // 构建完整记忆摘要（不依赖搜索，全量注入）
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

        let request_body = Self::build_request_body(&distill_messages, "glm-4-long", false);

        // GLM-4-LONG 蒸馏是静默执行的，不向前端推送事件
        let silent_event = |_event: ChatStreamEvent| {};
        let _ = on_event; // 保留参数以维持接口一致性

        match StreamingHandler::stream_chat(BIGMODEL_API_URL, &token, request_body, &silent_event)
            .await
        {
            Ok((content, _)) => {
                if !content.trim().is_empty() {
                    content
                } else {
                    String::new()
                }
            }
            Err(_) => {
                // GLM-4-LONG 蒸馏失败是非致命的，继续用原始上下文
                String::new()
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    //  知识库增强管线 — 本地事实检索 + GLM-4-AIR 深度检索 + GLM-4.7 二次整合
    // ═══════════════════════════════════════════════════════════════════

    /// ══ 知识检索增强（Phase 0.3）══
    /// 从本地知识库中检索与当前对话相关的事实，注入上下文
    /// ═══ 核心改进 ═══
    /// 不再无差别注入所有身份/承诺事实，而是：
    ///   1. BM25+语义检索相关事实（已有的 top 10）
    ///   2. 身份事实仅在与当前话题有一定关联时作为背景注入
    ///   3. 完全无关的事实不注入，避免 AI 在不相关的回复中提及
    fn retrieve_knowledge_context(
        &self,
        conversation_id: &str,
        user_content: &str,
        enhanced_messages: &mut Vec<Message>,
    ) {
        // 检索相关事实（top 10，已通过 BM25 + 语义排序）
        let search_results = self
            .knowledge_store
            .search_facts(conversation_id, user_content, 10);

        // 获取身份/承诺类永久事实
        let all_facts = self.knowledge_store.get_all_facts(conversation_id);
        let active_topics = MemoryEngine::extract_active_topics_from_text(user_content);

        // 对身份事实进行相关性门控
        // 核心身份（名字等）始终注入，其他身份事实需要有一定相关性
        let identity_facts: Vec<_> = all_facts
            .iter()
            .filter(|f| matches!(f.category, FactCategory::Identity | FactCategory::Promise))
            .filter(|f| {
                // 核心身份事实（高置信度）始终注入
                if f.confidence >= 0.9 && f.category == FactCategory::Identity {
                    return true;
                }
                // 承诺类事实需要有一定相关性
                if f.category == FactCategory::Promise {
                    let relevance = MemoryEngine::compute_relevance_score(
                        &f.content,
                        &active_topics,
                        user_content,
                    );
                    return relevance > 0.1;
                }
                // 其他身份事实需要有一定相关性或高置信度
                let relevance =
                    MemoryEngine::compute_relevance_score(&f.content, &active_topics, user_content);
                relevance > 0.08 || f.confidence >= 0.95
            })
            .cloned()
            .collect();

        // 构建知识上下文
        let knowledge_context =
            KnowledgeStore::build_knowledge_context(&search_results, &identity_facts);

        if !knowledge_context.is_empty() {
            // 记录命中的事实ID（用于更新热度）
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
            // 插入到最后一条用户消息之前
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

    /// ══ GLM-4-AIR 深度检索分析（Phase 1 增强）══
    /// 在原有推理分析的基础上，增加对本地知识库的深度检索指令
    /// GLM-4-AIR 负责：
    ///   1. 分析用户意图，判断需要哪些知识
    ///   2. 基于注入的知识库事实进行深度推理
    ///   3. 输出结构化分析结论，供 GLM-4.7 参考
    ///
    /// 增加超时保护：最多等待 REASONING_TIMEOUT_SECS 秒。
    /// 注：新管线使用 request_dual_thinking 替代，此方法保留作为降级路径。
    #[allow(dead_code)]
    async fn request_enhanced_reasoning(
        &self,
        thinking_model: &str,
        conversation_id: &str,
        enhanced_messages: &[Message],
        _user_content: &str,
        on_event: &impl Fn(ChatStreamEvent),
    ) -> (String, String) {
        // 使用 tokio::time::timeout 保护增强推理调用
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

    /// request_enhanced_reasoning 的内部实现（无超时保护）
    #[allow(dead_code)]
    async fn request_enhanced_reasoning_inner(
        &self,
        thinking_model: &str,
        conversation_id: &str,
        enhanced_messages: &[Message],
        _user_content: &str,
        on_event: &impl Fn(ChatStreamEvent),
    ) -> (String, String) {
        let token = {
            let mut auth = self.jwt_auth.lock().unwrap();
            auth.get_token()
        };

        // 在原始上下文基础上追加增强推理指令
        let mut reasoning_messages = enhanced_messages.to_vec();

        // 获取知识库概况（辅助推理）
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
            // 列出高置信度事实
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

        // 将分析指令插入到最后一条用户消息之前
        let last_user_idx = reasoning_messages
            .iter()
            .rposition(|m| m.role == MessageRole::User);
        if let Some(idx) = last_user_idx {
            reasoning_messages.insert(idx, analysis_instruction);
        } else {
            reasoning_messages.push(analysis_instruction);
        }

        let request_body = Self::build_request_body(&reasoning_messages, thinking_model, true);

        // 仅转发 ThinkingDelta 事件
        let reasoning_event = |event: ChatStreamEvent| {
            if let ChatStreamEvent::ThinkingDelta(_) = &event {
                on_event(event)
            }
        };

        match StreamingHandler::stream_chat(
            BIGMODEL_API_URL,
            &token,
            request_body,
            &reasoning_event,
        )
        .await
        {
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
            Err(_) => {
                // 推理失败是非致命的
                (String::new(), String::new())
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    //  双层思考管线 — Flash + Air 并行思考 → Air 综合
    //  参考用户需求：用户输入 → 同时 Flash + Air 思考 → Air 综合 → 4.7/Flash 回复
    // ═══════════════════════════════════════════════════════════════════

    /// 双层思考：并行执行 GLM-4.7-Flash 和 GLM-4-Air 的思考，
    /// 然后由 GLM-4-Air 综合两者的分析结果。
    ///
    /// 管线流程：
    ///   1a. GLM-4.7-Flash 思考（并行）→ flash_analysis
    ///   1b. GLM-4-Air 思考（并行）→ air_analysis
    ///   2.  GLM-4-Air 综合两者 → synthesis
    ///
    /// 所有思考过程通过 ThinkingDelta 推送前端。
    /// 返回: (综合分析结论, 完整思考链)
    async fn request_dual_thinking(
        &self,
        conversation_id: &str,
        enhanced_messages: &[Message],
        user_content: &str,
        on_event: &impl Fn(ChatStreamEvent),
    ) -> (String, String) {
        let result = tokio::time::timeout(
            std::time::Duration::from_secs(DUAL_THINKING_TIMEOUT_SECS),
            self.request_dual_thinking_inner(
                conversation_id,
                enhanced_messages,
                user_content,
                on_event,
            ),
        )
        .await;

        result.unwrap_or_default()
    }

    async fn request_dual_thinking_inner(
        &self,
        conversation_id: &str,
        enhanced_messages: &[Message],
        _user_content: &str,
        on_event: &impl Fn(ChatStreamEvent),
    ) -> (String, String) {
        let token = {
            let mut auth = self.jwt_auth.lock().unwrap();
            auth.get_token()
        };

        // 构建 Flash 思考消息（快速洞察 + 情绪感知）
        let flash_messages =
            self.build_flash_thinking_messages(enhanced_messages, conversation_id);
        let flash_body = Self::build_request_body(&flash_messages, "glm-4.7-flash", true);

        // 构建 Air 思考消息（深度推理 + 知识检索）
        let air_messages =
            self.build_air_thinking_messages(enhanced_messages, conversation_id);
        let air_body = Self::build_request_body(&air_messages, "glm-4-air", true);

        // 并行执行两个思考（静默收集，完成后统一推送前端）
        let silent = |_: ChatStreamEvent| {};
        log::info!("[dual_thinking] 并行启动 Flash + Air 思考");

        let (flash_result, air_result) = futures::join!(
            StreamingHandler::stream_chat(BIGMODEL_API_URL, &token, flash_body, &silent),
            StreamingHandler::stream_chat(BIGMODEL_API_URL, &token, air_body, &silent),
        );

        let (flash_content, flash_thinking) = flash_result.unwrap_or_default();
        let (air_content, air_thinking) = air_result.unwrap_or_default();

        log::info!(
            "[dual_thinking] 并行完成 | flash_content={} flash_thinking={} | air_content={} air_thinking={}",
            flash_content.len(), flash_thinking.len(),
            air_content.len(), air_thinking.len()
        );

        // 向前端推送两个思考过程
        if !flash_thinking.is_empty() {
            on_event(ChatStreamEvent::ThinkingDelta(
                "═══ 〔Flash 快速洞察〕 ═══\n".to_string(),
            ));
            on_event(ChatStreamEvent::ThinkingDelta(flash_thinking.clone()));
        }
        if !air_thinking.is_empty() {
            on_event(ChatStreamEvent::ThinkingDelta(
                "\n\n═══ 〔Air 深度推理〕 ═══\n".to_string(),
            ));
            on_event(ChatStreamEvent::ThinkingDelta(air_thinking.clone()));
        }

        // 提取分析结论
        let flash_analysis = if !flash_content.trim().is_empty() {
            flash_content
        } else if !flash_thinking.trim().is_empty() {
            Self::extract_reasoning_brief(&flash_thinking)
        } else {
            String::new()
        };

        let air_analysis = if !air_content.trim().is_empty() {
            air_content
        } else if !air_thinking.trim().is_empty() {
            Self::extract_reasoning_brief(&air_thinking)
        } else {
            String::new()
        };

        // 如果两个都失败，返回空
        if flash_analysis.is_empty() && air_analysis.is_empty() {
            return (
                String::new(),
                format!("{}\n{}", flash_thinking, air_thinking),
            );
        }

        // Phase 2: GLM-4-Air 综合两者分析结果
        on_event(ChatStreamEvent::ThinkingDelta(
            "\n\n═══ 〔综合深度分析〕 ═══\n".to_string(),
        ));

        let (synthesis, synthesis_thinking) = self
            .request_air_synthesis(
                &flash_analysis,
                &air_analysis,
                enhanced_messages,
                on_event,
            )
            .await;

        let all_thinking = format!(
            "═══ Flash 快速洞察 ═══\n{}\n\n═══ Air 深度推理 ═══\n{}\n\n═══ 综合分析 ═══\n{}",
            flash_thinking, air_thinking, synthesis_thinking
        );

        (synthesis, all_thinking)
    }

    /// 构建 Flash 思考消息（快速直觉 + 情绪感知）
    fn build_flash_thinking_messages(
        &self,
        enhanced_messages: &[Message],
        conversation_id: &str,
    ) -> Vec<Message> {
        let mut messages = enhanced_messages.to_vec();

        let all_facts = self.knowledge_store.get_all_facts(conversation_id);
        let fact_brief = if !all_facts.is_empty() {
            let high_conf: Vec<_> = all_facts
                .iter()
                .filter(|f| f.confidence >= 0.8)
                .take(10)
                .collect();
            if !high_conf.is_empty() {
                let mut s = String::from("【已知关键事实】\n");
                for f in &high_conf {
                    s.push_str(&format!("· {}\n", f.content));
                }
                s
            } else {
                String::new()
            }
        } else {
            String::new()
        };

        let flash_instruction = Message {
            id: String::new(),
            role: MessageRole::System,
            content: format!(
                "【快速思考任务 — 第一直觉与情绪感知】\n\
                 \n\
                 {}\n\
                 \n\
                 你是角色本身。用最快的速度完成以下思考（不要写回复内容）：\n\
                 \n\
                 ▸ 本能反应：听到这话，心里第一个感受是什么？\n\
                 ▸ 情绪判断：对方此刻的情绪状态（具体到哪种情绪，不是笼统的好/不好）\n\
                 ▸ 关系温度：你们现在的距离感——在靠近、稳定、试探、还是有些微妙？\n\
                 ▸ 弦外之音：对方有没有言外之意？有的话是什么？\n\
                 ▸ 回应直觉：你的第一反应是想怎么回？切入点是什么？\n\
                 ▸ 什么不该做：此刻有什么回应方式是绝对出戏的？\n\
                 \n\
                 ■ 输出要求：\n\
                 - 用自然的思维流，快速精准，300-500字\n\
                 - 引用对话原文和事实作为依据\n\
                 - 不要写回复内容，只输出思考过程",
                fact_brief
            ),
            thinking_content: None,
            model: "system".to_string(),
            timestamp: 0,
            message_type: MessageType::Say,
        };

        let last_user_idx = messages
            .iter()
            .rposition(|m| m.role == MessageRole::User);
        if let Some(idx) = last_user_idx {
            messages.insert(idx, flash_instruction);
        } else {
            messages.push(flash_instruction);
        }

        messages
    }

    /// 构建 Air 思考消息（深度推理 + 知识检索）
    fn build_air_thinking_messages(
        &self,
        enhanced_messages: &[Message],
        conversation_id: &str,
    ) -> Vec<Message> {
        let mut messages = enhanced_messages.to_vec();

        let all_facts = self.knowledge_store.get_all_facts(conversation_id);
        let fact_summary = if !all_facts.is_empty() {
            let mut summary = String::from("【本地知识库概况】\n");
            let categories: Vec<(&str, usize)> = vec![
                ("身份", all_facts.iter().filter(|f| f.category == FactCategory::Identity).count()),
                ("关系", all_facts.iter().filter(|f| f.category == FactCategory::Relationship).count()),
                ("事件", all_facts.iter().filter(|f| f.category == FactCategory::Event).count()),
                ("偏好", all_facts.iter().filter(|f| f.category == FactCategory::Preference).count()),
                ("承诺", all_facts.iter().filter(|f| f.category == FactCategory::Promise).count()),
                ("状态", all_facts.iter().filter(|f| f.category == FactCategory::CurrentState).count()),
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

        let air_instruction = Message {
            id: String::new(),
            role: MessageRole::System,
            content: format!(
                "【深度推理任务 — 知识增强分析】\n\
                 \n\
                 闭上眼，你就是这个角色。对方刚说完这句话。\n\
                 \n\
                 {}\n\
                 \n\
                 请从以下角度进行深度推演（用自然思维流，不要列编号清单）：\n\
                 \n\
                 ▸ 第一反应：听到这话，你心里的感受是什么？\n\
                 ▸ 知识检索：你脑子里有没有和这件事相关的记忆/事实？\n\
                   对照知识库，哪些事实与当前话题直接相关？（必须逐条引用原文）\n\
                   有没有新的信息值得记住？\n\
                 ▸ 弦外之音：表面意思之下是否有别的含义？\n\
                 ▸ 上下文线索：最近几轮对话的走向是什么？和这句话有什么连续性？\n\
                 ▸ 关系直觉：你们此刻的距离感和温度怎么样？\n\
                 ▸ 回应策略：你想怎么回？\n\
                   切入方式——动作/接话/反问/沉默后开口？\n\
                   核心要回应的点是什么？\n\
                   收束方式——提问/温柔确认/动作/自然停下？\n\
                   什么方式是绝对不能用的？\n\
                 \n\
                 ■ 输出要求：\n\
                 - 用自然的思维流表达，像是回话前脑海中闪过的念头\n\
                 - 引用对话原文和知识库事实作为依据\n\
                 - 500-800字，思考密度优先\n\
                 - 不要写回复内容，只输出思考过程\n\
                 - 知识库中的事实必须原样复述，绝不允许遗漏或篡改",
                fact_summary
            ),
            thinking_content: None,
            model: "system".to_string(),
            timestamp: 0,
            message_type: MessageType::Say,
        };

        let last_user_idx = messages
            .iter()
            .rposition(|m| m.role == MessageRole::User);
        if let Some(idx) = last_user_idx {
            messages.insert(idx, air_instruction);
        } else {
            messages.push(air_instruction);
        }

        messages
    }

    /// GLM-4-Air 综合两路思考结果，输出最终分析结论
    async fn request_air_synthesis(
        &self,
        flash_analysis: &str,
        air_analysis: &str,
        enhanced_messages: &[Message],
        on_event: &impl Fn(ChatStreamEvent),
    ) -> (String, String) {
        let result = tokio::time::timeout(
            std::time::Duration::from_secs(SYNTHESIS_TIMEOUT_SECS),
            self.request_air_synthesis_inner(
                flash_analysis,
                air_analysis,
                enhanced_messages,
                on_event,
            ),
        )
        .await;

        result.unwrap_or_default()
    }

    async fn request_air_synthesis_inner(
        &self,
        flash_analysis: &str,
        air_analysis: &str,
        enhanced_messages: &[Message],
        on_event: &impl Fn(ChatStreamEvent),
    ) -> (String, String) {
        let token = {
            let mut auth = self.jwt_auth.lock().unwrap();
            auth.get_token()
        };

        let mut synthesis_messages = enhanced_messages.to_vec();

        let synthesis_instruction = Message {
            id: String::new(),
            role: MessageRole::System,
            content: format!(
                "【综合分析任务 — 结合两路思考的最终研判】\n\
                 \n\
                 你已经从两个不同角度完成了思考，现在需要综合两者得出最终结论：\n\
                 \n\
                 ═══ Flash 快速洞察 ═══\n\
                 {}\n\
                 \n\
                 ═══ Air 深度分析 ═══\n\
                 {}\n\
                 \n\
                 请综合以上两路分析，输出最终的回应策略：\n\
                 \n\
                 1. 两路分析的共识点（高置信度判断）\n\
                 2. 分歧点分析（如果有，选择更合理的判断并说明理由）\n\
                 3. 最终回应策略：\n\
                    - 情绪定位（此刻你的情绪应该是什么）\n\
                    - 切入方式（具体的第一句话/动作的方向）\n\
                    - 核心要表达的内容（不超过3个要点）\n\
                    - 收束方式（怎么结束这段回复）\n\
                    - 必须遵守的约束（不能做的事）\n\
                 \n\
                 ■ 输出要求：\n\
                 - 500-800字，结论明确\n\
                 - 不写回复内容，只输出分析结论\n\
                 - 引用原始事实和对话内容作为依据",
                flash_analysis, air_analysis
            ),
            thinking_content: None,
            model: "system".to_string(),
            timestamp: 0,
            message_type: MessageType::Say,
        };

        let last_user_idx = synthesis_messages
            .iter()
            .rposition(|m| m.role == MessageRole::User);
        if let Some(idx) = last_user_idx {
            synthesis_messages.insert(idx, synthesis_instruction);
        } else {
            synthesis_messages.push(synthesis_instruction);
        }

        let request_body = Self::build_request_body(&synthesis_messages, "glm-4-air", true);

        let reasoning_event = |event: ChatStreamEvent| {
            if let ChatStreamEvent::ThinkingDelta(_) = &event {
                on_event(event)
            }
        };

        match StreamingHandler::stream_chat(
            BIGMODEL_API_URL,
            &token,
            request_body,
            &reasoning_event,
        )
        .await
        {
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
            Err(e) => {
                log::warn!("[air_synthesis] 综合分析失败: {}", e);
                (String::new(), String::new())
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    //  验证式上下文总结管线
    //  GLM-4-Long 总结 → GLM-4.7-Flash 校验 → GLM-4-Air 校验 → 循环
    //  参考: https://docs.bigmodel.cn/cn/guide/tools/knowledge/contextual
    // ═══════════════════════════════════════════════════════════════════

    /// 验证式上下文总结：GLM-4-Long 总结后由 Flash 和 Air 依次校验
    /// 如果校验不通过，循环重试直到合格或达到最大次数
    async fn verified_summarize_context(
        &self,
        messages: &[Message],
        existing_summaries: &[MemorySummary],
        on_event: &impl Fn(ChatStreamEvent),
    ) -> Result<String, ChatError> {
        let total_tokens = Self::estimate_token_count(messages);

        // 如果上下文超过 GLM-4-Long 的安全处理限制（900K token），先分批处理
        if total_tokens > GLM_4_LONG_SAFE_INPUT {
            log::info!(
                "[verified_summarize] 上下文超过 GLM-4-Long 安全限制 ({} > {}), 启动分批处理",
                total_tokens, GLM_4_LONG_SAFE_INPUT
            );
            return self
                .batch_process_long_context(messages, existing_summaries, on_event)
                .await;
        }

        // 单批处理 + 验证循环
        for attempt in 0..MAX_VERIFY_ATTEMPTS {
            log::info!(
                "[verified_summarize] 尝试 {}/{} | tokens={}",
                attempt + 1, MAX_VERIFY_ATTEMPTS, total_tokens
            );

            // Step 1: GLM-4-Long 三级总结（关键无损 + 核心小概括 + 一般大概括）
            let summary = self
                .glm4_long_tiered_summarize(messages, existing_summaries)
                .await;

            if summary.trim().is_empty() {
                log::warn!("[verified_summarize] GLM-4-Long 总结为空, 重试");
                continue;
            }

            // Step 2: GLM-4.7-Flash 校验（启用思考模式）— 检查关键信息和上下文逻辑
            let flash_ok = self
                .verify_summary_with_flash(&summary, messages)
                .await;

            if !flash_ok {
                log::warn!(
                    "[verified_summarize] Flash 校验未通过 (attempt {})",
                    attempt + 1
                );
                continue;
            }

            // Step 3: GLM-4-Air 校验核心内容（启用思考模式）— 第三次检查主要核心内容
            let air_ok = self
                .verify_summary_with_air(&summary, messages)
                .await;

            if !air_ok {
                log::warn!(
                    "[verified_summarize] Air 校验未通过 (attempt {})",
                    attempt + 1
                );
                continue;
            }

            // 两项校验都通过
            log::info!("[verified_summarize] 双重校验通过 (attempt {})", attempt + 1);
            return Ok(summary);
        }

        // 最大重试次数后，使用最后一次的总结（降级）
        log::warn!("[verified_summarize] 达到最大重试次数，使用降级总结");
        let fallback = self
            .glm4_long_tiered_summarize(messages, existing_summaries)
            .await;
        Ok(fallback)
    }

    /// GLM-4-Long 三级总结：
    /// - 第一级：关键信息无损保留（身份/关系/事件/承诺）
    /// - 第二级：核心内容精炼概括（情感变化/重要观点）
    /// - 第三级：一般对话高度压缩
    async fn glm4_long_tiered_summarize(
        &self,
        messages: &[Message],
        existing_summaries: &[MemorySummary],
    ) -> String {
        let token = {
            let mut auth = self.jwt_auth.lock().unwrap();
            auth.get_token()
        };

        // 构建上下文
        let mut context = String::new();
        if !existing_summaries.is_empty() {
            context.push_str("【已有记忆摘要】\n");
            for (i, s) in existing_summaries.iter().enumerate() {
                context.push_str(&format!(
                    "{}. [轮次{}-{}] {}\n  事实：{}\n",
                    i + 1,
                    s.turn_range_start,
                    s.turn_range_end,
                    s.summary,
                    s.core_facts.join("；")
                ));
            }
            context.push('\n');
        }

        context.push_str("【需要总结的对话内容】\n");
        for msg in messages {
            let role = match msg.role {
                MessageRole::User => "用户",
                MessageRole::Assistant => "AI",
                MessageRole::System => continue,
            };
            context.push_str(&format!("{}: {}\n", role, msg.content));
        }

        let summarize_prompt = format!(
            "【三级上下文总结任务】\n\
             你需要对以下对话内容进行三级精度的无损总结，确保记忆体完整。\n\
             \n\
             {}\n\
             \n\
             请按照以下三个级别进行总结：\n\
             \n\
             ## 第一级：关键信息（绝对无损保留）\n\
             以下信息必须逐条原样保留，不允许任何省略或改写：\n\
             - 所有角色身份、姓名、年龄、职业\n\
             - 所有人物关系及变化\n\
             - 所有承诺、约定、共识\n\
             - 所有已发生的不可逆事件\n\
             - 所有金额、数值、时间等精确信息\n\
             - 当前生效的状态（位置、心情、正在做的事）\n\
             \n\
             ## 第二级：核心内容（精炼概括）\n\
             以下信息进行精炼但保留核心语义：\n\
             - 情感变化轨迹（关键转折点）\n\
             - 重要对话的核心观点\n\
             - 关系温度和互动模式的变化\n\
             - 未解决的问题或冲突\n\
             \n\
             ## 第三级：一般对话（高度压缩）\n\
             以下信息可以高度压缩为一两句话：\n\
             - 日常闲聊、寒暄\n\
             - 重复出现的类似对话\n\
             - 场景氛围描述\n\
             \n\
             ■ 输出格式：\n\
             【关键信息·无损】\n\
             - 逐条列出\n\
             \n\
             【核心内容·概括】\n\
             概括段落\n\
             \n\
             【一般对话·压缩】\n\
             压缩描述\n\
             \n\
             ■ 总输出控制在3000字以内\n\
             ■ 信息零丢失原则：第一级信息不允许任何遗漏",
            context
        );

        let summarize_messages = vec![
            Message {
                id: String::new(),
                role: MessageRole::System,
                content: "你是一个高精度的长上下文总结系统。你的任务是在严格保留关键信息的前提下，\
                         将超长对话压缩为结构化的记忆摘要。"
                    .to_string(),
                thinking_content: None,
                model: "system".to_string(),
                timestamp: 0,
                message_type: MessageType::Say,
            },
            Message {
                id: String::new(),
                role: MessageRole::User,
                content: summarize_prompt,
                thinking_content: None,
                model: "glm-4-long".to_string(),
                timestamp: 0,
                message_type: MessageType::Say,
            },
        ];

        let request_body = Self::build_request_body(&summarize_messages, "glm-4-long", false);
        let silent = |_: ChatStreamEvent| {};

        match StreamingHandler::stream_chat(BIGMODEL_API_URL, &token, request_body, &silent).await
        {
            Ok((content, _)) => content,
            Err(e) => {
                log::error!("[glm4_long_summarize] 总结失败: {}", e);
                String::new()
            }
        }
    }

    /// GLM-4.7-Flash 校验总结内容（启用思考模式）
    /// 检查关键信息完整性和上下文逻辑一致性
    async fn verify_summary_with_flash(
        &self,
        summary: &str,
        original_messages: &[Message],
    ) -> bool {
        let result = tokio::time::timeout(
            std::time::Duration::from_secs(SUMMARIZE_VERIFY_TIMEOUT_SECS),
            self.verify_summary_with_flash_inner(summary, original_messages),
        )
        .await;

        result.unwrap_or(true) // 超时默认通过，不阻断主流程
    }

    async fn verify_summary_with_flash_inner(
        &self,
        summary: &str,
        original_messages: &[Message],
    ) -> bool {
        let token = {
            let mut auth = self.jwt_auth.lock().unwrap();
            auth.get_token()
        };

        // 提取最近对话用于比对
        let mut key_info = String::new();
        let mut msg_count = 0;
        for msg in original_messages.iter().rev().take(30) {
            if msg.role == MessageRole::System {
                continue;
            }
            let role = match msg.role {
                MessageRole::User => "用户",
                MessageRole::Assistant => "AI",
                MessageRole::System => continue,
            };
            key_info = format!("{}: {}\n{}", role, msg.content, key_info);
            msg_count += 1;
        }

        let verify_prompt = format!(
            "【总结质量校验任务】\n\
             \n\
             请对比以下总结与原始对话，检查关键信息是否完整准确。\n\
             \n\
             【总结内容】\n\
             {}\n\
             \n\
             【最近 {} 条原始对话】\n\
             {}\n\
             \n\
             请检查：\n\
             1. 所有身份信息是否完整保留？\n\
             2. 所有关系信息是否准确？\n\
             3. 所有关键事件是否无遗漏？\n\
             4. 所有承诺/约定是否记录？\n\
             5. 上下文逻辑是否自洽？\n\
             6. 是否有信息被错误篡改？\n\
             \n\
             输出JSON：\n\
             {{\"passed\": true/false, \"issues\": [\"问题描述\"]}}",
            summary, msg_count, key_info
        );

        let verify_messages = vec![
            Message {
                id: String::new(),
                role: MessageRole::System,
                content: "你是一个严谨的信息完整性校验系统。请仔细对比总结与原始对话，\
                         确保关键信息无遗漏无篡改。只输出JSON。"
                    .to_string(),
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
                model: "glm-4.7-flash".to_string(),
                timestamp: 0,
                message_type: MessageType::Say,
            },
        ];

        // 启用思考模式进行校验
        let request_body = Self::build_request_body(&verify_messages, "glm-4.7-flash", true);
        let silent = |_: ChatStreamEvent| {};

        match StreamingHandler::stream_chat(BIGMODEL_API_URL, &token, request_body, &silent).await
        {
            Ok((content, _)) => Self::parse_verification_result(&content),
            Err(_) => true, // 校验请求失败默认通过
        }
    }

    /// GLM-4-Air 校验核心内容（启用思考模式）
    /// 第三次检查：主要核心内容的准确性和完整性
    async fn verify_summary_with_air(
        &self,
        summary: &str,
        _original_messages: &[Message],
    ) -> bool {
        let result = tokio::time::timeout(
            std::time::Duration::from_secs(SUMMARIZE_VERIFY_TIMEOUT_SECS),
            self.verify_summary_with_air_inner(summary),
        )
        .await;

        result.unwrap_or(true)
    }

    async fn verify_summary_with_air_inner(
        &self,
        summary: &str,
    ) -> bool {
        let token = {
            let mut auth = self.jwt_auth.lock().unwrap();
            auth.get_token()
        };

        let verify_prompt = format!(
            "【核心内容深度校验】\n\
             \n\
             请深度检查以下总结的核心内容是否准确、完整、逻辑自洽。\n\
             \n\
             【总结内容】\n\
             {}\n\
             \n\
             请重点检查：\n\
             1. 角色身份的核心设定是否被正确保留？\n\
             2. 人物关系的方向和性质是否准确？\n\
             3. 事件时间线是否合乎逻辑？\n\
             4. 情感走向是否与对话内容一致？\n\
             5. 是否存在矛盾或不一致？\n\
             \n\
             输出JSON：\n\
             {{\"passed\": true/false, \"critical_issues\": [\"严重问题描述\"]}}",
            summary
        );

        let verify_messages = vec![
            Message {
                id: String::new(),
                role: MessageRole::System,
                content: "你是一个深度内容校验系统，专门检查总结中的核心内容是否准确完整。\
                         启用深度思考来进行检查。只输出JSON。"
                    .to_string(),
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
                model: "glm-4-air".to_string(),
                timestamp: 0,
                message_type: MessageType::Say,
            },
        ];

        let request_body = Self::build_request_body(&verify_messages, "glm-4-air", true);
        let silent = |_: ChatStreamEvent| {};

        match StreamingHandler::stream_chat(BIGMODEL_API_URL, &token, request_body, &silent).await
        {
            Ok((content, _)) => Self::parse_verification_result(&content),
            Err(_) => true,
        }
    }

    /// 解析校验结果 JSON（支持 passed 和 is_valid 两种格式）
    fn parse_verification_result(text: &str) -> bool {
        if let Some(start) = text.find('{') {
            if let Some(end) = text.rfind('}') {
                if let Ok(json) = serde_json::from_str::<serde_json::Value>(&text[start..=end]) {
                    // 支持 "passed" 或 "is_valid" 字段
                    return json
                        .get("passed")
                        .or_else(|| json.get("is_valid"))
                        .and_then(|v| v.as_bool())
                        .unwrap_or(true);
                }
            }
        }
        true // 解析失败默认通过
    }

    // ═══════════════════════════════════════════════════════════════════
    //  超长上下文分批处理
    //  当上下文超过 GLM-4-Long 1M token 限制时，分批处理
    //  每批双重 GLM-4-Long 处理 + 验证，确保语义不漂移
    // ═══════════════════════════════════════════════════════════════════

    /// 分批处理超长上下文（> GLM-4-Long 安全限制）
    /// 在完整的 user-assistant 对话边界处切分，避免句子截断
    async fn batch_process_long_context(
        &self,
        messages: &[Message],
        existing_summaries: &[MemorySummary],
        on_event: &impl Fn(ChatStreamEvent),
    ) -> Result<String, ChatError> {
        let batches =
            Self::split_at_conversation_boundaries(messages, GLM_4_LONG_SAFE_INPUT);
        log::info!(
            "[batch_process] 分批处理 | 总批次={} | 总消息={}",
            batches.len(),
            messages.len()
        );

        let mut batch_summaries: Vec<String> = Vec::new();

        for (i, batch) in batches.iter().enumerate() {
            let batch_tokens = Self::estimate_token_count(batch);
            log::info!(
                "[batch_process] 处理第 {}/{} 批 | 消息数={} | tokens={}",
                i + 1, batches.len(), batch.len(), batch_tokens
            );

            // 如果剩余批次小于 GLM-4.7/Flash 上下文窗口，直接用 Flash 处理
            if batch_tokens < GLM_47_FLASH_MAX_CONTEXT {
                log::info!(
                    "[batch_process] 批次 {} tokens < Flash窗口, 使用 Flash 处理",
                    i + 1
                );
                let summary = self
                    .summarize_with_flash(batch, existing_summaries)
                    .await;
                // Flash 处理后由 Air 校验
                let air_ok = self.verify_summary_with_air(&summary, batch).await;
                if air_ok {
                    batch_summaries.push(summary);
                } else {
                    // Air 校验未通过，回退到双重 GLM-4-Long
                    let summary = self
                        .double_pass_glm4_long(batch, existing_summaries)
                        .await;
                    batch_summaries.push(summary);
                }
            } else {
                // 使用双重 GLM-4-Long 处理
                let summary = self
                    .double_pass_glm4_long(batch, existing_summaries)
                    .await;

                // Flash 校验
                let flash_ok = self.verify_summary_with_flash(&summary, batch).await;
                if !flash_ok {
                    log::warn!("[batch_process] 批次 {} Flash校验未通过, 重新处理", i + 1);
                    let retry_summary = self
                        .double_pass_glm4_long(batch, existing_summaries)
                        .await;
                    batch_summaries.push(retry_summary);
                } else {
                    // Air 校验
                    let air_ok = self.verify_summary_with_air(&summary, batch).await;
                    if !air_ok {
                        log::warn!("[batch_process] 批次 {} Air校验未通过, 重新处理", i + 1);
                        let retry_summary = self
                            .double_pass_glm4_long(batch, existing_summaries)
                            .await;
                        batch_summaries.push(retry_summary);
                    } else {
                        batch_summaries.push(summary);
                    }
                }
            }
        }

        // 合并所有批次的总结
        let combined = batch_summaries.join("\n\n---\n\n");
        let _ = on_event; // 保留参数以维持接口一致性
        Ok(combined)
    }

    /// 双重 GLM-4-Long 处理：两次调用确保语义不漂移
    /// 第一遍正常总结，第二遍对照原文校验补全
    async fn double_pass_glm4_long(
        &self,
        messages: &[Message],
        existing_summaries: &[MemorySummary],
    ) -> String {
        // 第一遍：正常三级总结
        let first_pass = self
            .glm4_long_tiered_summarize(messages, existing_summaries)
            .await;

        if first_pass.trim().is_empty() {
            return String::new();
        }

        // 第二遍：基于第一遍结果进行语义一致性校验补全
        let token = {
            let mut auth = self.jwt_auth.lock().unwrap();
            auth.get_token()
        };

        // 收集原始对话（截取尾部保证不超限）
        let mut dialogue_context = String::new();
        for msg in messages.iter().rev().take(80) {
            if msg.role == MessageRole::System {
                continue;
            }
            let role = match msg.role {
                MessageRole::User => "用户",
                MessageRole::Assistant => "AI",
                MessageRole::System => continue,
            };
            dialogue_context = format!("{}: {}\n{}", role, msg.content, dialogue_context);
        }

        let second_pass_prompt = format!(
            "【语义一致性校验 — 第二遍处理】\n\
             \n\
             以下是第一遍总结的结果：\n\
             {}\n\
             \n\
             请重新审视原始对话内容，检查上述总结是否：\n\
             1. 遗漏了任何关键信息（身份、关系、事件、承诺）\n\
             2. 存在语义偏移或不准确的描述\n\
             3. 缺少重要的情感变化节点\n\
             \n\
             如果发现问题，请输出修正后的完整总结。\n\
             如果没有问题，请原样输出第一遍的结果。\n\
             \n\
             ■ 不要添加额外的解释，只输出最终的总结内容。",
            first_pass
        );

        let verify_messages = vec![
            Message {
                id: String::new(),
                role: MessageRole::System,
                content: "你是一个语义一致性校验系统。请对照原始对话验证总结的准确性和完整性。"
                    .to_string(),
                thinking_content: None,
                model: "system".to_string(),
                timestamp: 0,
                message_type: MessageType::Say,
            },
            Message {
                id: String::new(),
                role: MessageRole::User,
                content: format!(
                    "【原始对话参考】\n{}\n\n{}", dialogue_context, second_pass_prompt
                ),
                thinking_content: None,
                model: "glm-4-long".to_string(),
                timestamp: 0,
                message_type: MessageType::Say,
            },
        ];

        let request_body = Self::build_request_body(&verify_messages, "glm-4-long", false);
        let silent = |_: ChatStreamEvent| {};

        match StreamingHandler::stream_chat(BIGMODEL_API_URL, &token, request_body, &silent).await
        {
            Ok((content, _)) if !content.trim().is_empty() => content,
            _ => first_pass, // 第二遍失败，使用第一遍结果
        }
    }

    /// 使用 GLM-4.7-Flash 直接总结较短的上下文（启用思考模式提高质量）
    async fn summarize_with_flash(
        &self,
        messages: &[Message],
        existing_summaries: &[MemorySummary],
    ) -> String {
        let token = {
            let mut auth = self.jwt_auth.lock().unwrap();
            auth.get_token()
        };

        let mut context = String::new();
        if !existing_summaries.is_empty() {
            context.push_str("【已有记忆摘要】\n");
            for (i, s) in existing_summaries.iter().enumerate() {
                context.push_str(&format!(
                    "{}. {}\n  事实：{}\n",
                    i + 1,
                    s.summary,
                    s.core_facts.join("；")
                ));
            }
            context.push('\n');
        }

        context.push_str("【对话内容】\n");
        for msg in messages {
            let role = match msg.role {
                MessageRole::User => "用户",
                MessageRole::Assistant => "AI",
                MessageRole::System => continue,
            };
            context.push_str(&format!("{}: {}\n", role, msg.content));
        }

        let prompt = format!(
            "请总结以下对话内容，保证关键信息（身份、关系、事件、承诺）的绝对完整。\n\
             \n\
             {}\n\
             \n\
             输出格式：\n\
             【关键信息·无损】逐条列出所有不可变事实\n\
             【核心内容·概括】精炼概括核心情节\n\
             【一般对话·压缩】高度压缩日常闲聊",
            context
        );

        let summary_messages = vec![
            Message {
                id: String::new(),
                role: MessageRole::System,
                content: "你是一个精确的对话总结系统。".to_string(),
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
                model: "glm-4.7-flash".to_string(),
                timestamp: 0,
                message_type: MessageType::Say,
            },
        ];

        let request_body = Self::build_request_body(&summary_messages, "glm-4.7-flash", true);
        let silent = |_: ChatStreamEvent| {};

        match StreamingHandler::stream_chat(BIGMODEL_API_URL, &token, request_body, &silent).await
        {
            Ok((content, _)) => content,
            Err(_) => String::new(),
        }
    }

    /// 在完整的对话边界处切分消息列表
    /// 确保每个批次都以完整的 user-assistant 对结束，不会截断句子
    fn split_at_conversation_boundaries(
        messages: &[Message],
        max_tokens_per_batch: usize,
    ) -> Vec<Vec<Message>> {
        let mut batches: Vec<Vec<Message>> = Vec::new();
        let mut current_batch: Vec<Message> = Vec::new();
        let mut current_tokens: usize = 0;

        // 收集 system 消息（始终包含在每个批次中）
        let system_messages: Vec<Message> = messages
            .iter()
            .filter(|m| m.role == MessageRole::System)
            .cloned()
            .collect();
        let system_tokens = Self::estimate_token_count(&system_messages);

        let non_system: Vec<&Message> = messages
            .iter()
            .filter(|m| m.role != MessageRole::System)
            .collect();

        let mut i = 0;
        while i < non_system.len() {
            let msg = non_system[i];
            let msg_tokens = Self::estimate_token_count(&[msg.clone()]);

            // 检查添加这条消息后是否会超过限制
            if current_tokens + msg_tokens + system_tokens > max_tokens_per_batch
                && !current_batch.is_empty()
            {
                // 回退到上一个完整的 user-assistant 对结尾
                while !current_batch.is_empty() {
                    if current_batch.last().map(|m| &m.role) == Some(&MessageRole::Assistant) {
                        break;
                    }
                    let removed = current_batch.pop().unwrap();
                    current_tokens -= Self::estimate_token_count(&[removed]);
                    if i > 0 {
                        i -= 1;
                    }
                }

                if !current_batch.is_empty() {
                    let mut full_batch = system_messages.clone();
                    full_batch.extend(current_batch);
                    batches.push(full_batch);
                }

                current_batch = Vec::new();
                current_tokens = 0;
            }

            current_batch.push(msg.clone());
            current_tokens += msg_tokens;
            i += 1;
        }

        // 处理最后一个批次
        if !current_batch.is_empty() {
            let mut full_batch = system_messages;
            full_batch.extend(current_batch);
            batches.push(full_batch);
        }

        if batches.is_empty() {
            batches.push(messages.to_vec());
        }

        batches
    }

    /// ══ 异步事实提取（后台任务）══
    /// 在对话完成后，使用 GLM-4.7-flash 从最近对话中提取新事实
    /// 存入本地知识库，供后续对话检索
    ///
    /// 增加超时保护：最多等待 FACT_EXTRACTION_TIMEOUT_SECS 秒。
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

        if result.is_err() {
            // 超时不影响主流程
        }
    }

    /// extract_and_store_facts 的内部实现
    async fn extract_and_store_facts_inner(
        &self,
        conversation_id: &str,
        on_event: &impl Fn(ChatStreamEvent),
    ) {
        let conv = match self.conversation_store.load_conversation(conversation_id) {
            Ok(c) => c,
            Err(_) => return,
        };

        // 获取最近 10 条非 system 消息
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

        // 构建事实提取 prompt
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
                model: "glm-4.7-flash".to_string(),
                timestamp: 0,
                message_type: MessageType::Say,
            },
        ];

        let request_body = Self::build_request_body(&extract_messages, "glm-4.7-flash", false);

        let token = {
            let mut auth = self.jwt_auth.lock().unwrap();
            auth.get_token()
        };

        // 静默执行，不向前端发送事件
        let silent_event = |_event: ChatStreamEvent| {};
        let _ = on_event;

        if let Ok((text, _)) =
            StreamingHandler::stream_chat(BIGMODEL_API_URL, &token, request_body, &silent_event)
                .await
        {
            let turn = conv.turn_count;
            let new_facts = KnowledgeStore::parse_extracted_facts(&text, turn);
            if !new_facts.is_empty() {
                let _ = self.knowledge_store.add_facts(conversation_id, new_facts);
            }
        }
    }

    /// Build the BigModel API request body.
    ///
    /// ═══ 核心安全措施：消息格式规范化 ═══
    /// 将所有 system 消息合并为单条放在开头，
    /// 防止 system 消息穿插在 user/assistant 之间导致 API 拒绝或返回空内容。
    /// 智谱 API（OpenAI 兼容格式）要求：[system] → [user/assistant 交替]
    pub fn build_request_body(
        messages: &[Message],
        model: &str,
        enable_thinking: bool,
    ) -> serde_json::Value {
        // ── 合并所有 system 消息为单条 ──
        let system_content: String = messages
            .iter()
            .filter(|m| m.role == MessageRole::System)
            .map(|m| m.content.as_str())
            .collect::<Vec<&str>>()
            .join("\n\n");

        let mut api_messages: Vec<serde_json::Value> = Vec::new();

        // 单条合并的 system 消息放在最前面
        if !system_content.is_empty() {
            api_messages.push(serde_json::json!({
                "role": "system",
                "content": system_content,
            }));
        }

        // user/assistant 消息保持原始顺序
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

        // ═══ 消息交替校验 ═══
        // 智谱 API（OpenAI 兼容）要求 user/assistant 消息严格交替。
        // 若因 system 消息被合并等原因产生连续同角色消息，在此合并。
        let mut merged_api_messages: Vec<serde_json::Value> = Vec::new();
        for msg in api_messages {
            if let Some(last) = merged_api_messages.last_mut() {
                if last["role"] == msg["role"] && msg["role"] != "system" {
                    // 合并连续同角色消息
                    let existing = last["content"].as_str().unwrap_or("").to_string();
                    let new_part = msg["content"].as_str().unwrap_or("");
                    last["content"] = serde_json::json!(format!("{}\n{}", existing, new_part));
                    continue;
                }
            }
            merged_api_messages.push(msg);
        }
        let api_messages = merged_api_messages;
        // ═══ 动态 max_tokens 计算 ═══
        // 参考: https://docs.bigmodel.cn/cn/guide/start/concept-param
        // 原则: input + output ≤ 100K（用户要求每次调用最多 100K token）
        //
        // 各模型最大 output token（官方文档）：
        //   glm-4.7:       默认 65536, 最大 131072
        //   glm-4.7-flash: 默认 65536, 最大 131072（同系列）
        //   glm-4-air:     动态计算,  最大 4095
        //   glm-4-long:    旧模型,    最大 4095
        const TOTAL_TOKEN_BUDGET: usize = 100_000;

        let input_estimate = Self::estimate_token_count(messages);

        let model_max_output: u32 = match model {
            "glm-4.7" => 131072,
            "glm-4.7-flash" => 131072,
            "glm-4-air" => 4095,
            "glm-4-long" => 4095,
            _ => 16384,
        };

        // 可用输出 = 总预算 − 输入估算，下限 1024，上限为模型最大输出
        let available_output = if TOTAL_TOKEN_BUDGET > input_estimate + 1024 {
            (TOTAL_TOKEN_BUDGET - input_estimate) as u32
        } else {
            2048u32 // 最低保障：即使上下文超预算，也保留 2K 输出空间
        };
        let max_tokens: u32 = available_output.min(model_max_output).max(1024);

        let mut body = serde_json::json!({
            "model": model,
            "messages": api_messages,
            "stream": true,
            "max_tokens": max_tokens,
        });

        // ═══ Thinking 模式控制 ═══
        // 参考: https://docs.bigmodel.cn/cn/guide/capabilities/thinking-mode
        //
        // GLM-4.7: 默认开启 Thinking，必须显式 disabled 才能关闭
        // GLM-4-AIR: 推理模型，按用户偏好开关
        // GLM-4.7-FLASH: 快速模型，支持思考模式
        // 其他模型: 不发送 thinking 字段（旧模型不支持）
        //
        // budget_tokens: 思考预算（官方文档推荐），防止思考无限消耗 token
        match model {
            "glm-4.7" | "glm-4-air" | "glm-4.7-flash" => {
                if Self::should_enable_thinking(model, enable_thinking) {
                    let budget = match model {
                        "glm-4-air" => 10240,
                        "glm-4.7-flash" => 10240,
                        _ => 16384, // glm-4.7
                    };
                    body["thinking"] = serde_json::json!({
                        "type": "enabled",
                        "budget_tokens": budget
                    });
                } else {
                    body["thinking"] = serde_json::json!({"type": "disabled"});
                }
            }
            _ => {}
        }

        // ═══ 采样参数：按模型用途优化 ═══
        // GLM-4.7 / GLM-4.7-FLASH: 默认 temperature=0.95（自然对话变化丰富）
        // GLM-4-AIR: 降低 temperature 保证推理分析的一致性和聚焦度
        // GLM-4-LONG: 低 temperature 保证蒸馏/总结的事实准确性
        match model {
            "glm-4-air" => {
                body["temperature"] = serde_json::json!(0.75);
            }
            "glm-4-long" => {
                body["temperature"] = serde_json::json!(0.4);
            }
            _ => {
                // GLM-4.7 / GLM-4.7-FLASH 使用 API 默认值 0.95
            }
        }

        body
    }

    /// 构建带记忆上下文增强的消息列表
    /// 实现自我认知架构：
    ///   层1: 角色身份锚定（system prompt）
    ///   层2: 记忆上下文注入（历史记忆检索结果）
    ///   层3: 情感状态追踪（基于最近对话推断当前情绪基线）
    ///   层4: 对话历史窗口（最近 20 条消息）
    ///   层5: 风格约束（say/do 模式提示）
    pub fn build_context_enhanced_messages(
        conv: &Conversation,
        user_content: &str,
        memory_summaries: &[MemorySummary],
    ) -> Vec<Message> {
        let mut enhanced_messages: Vec<Message> = Vec::new();

        // 层1: 保留角色 system 消息（身份锚定）
        let mut system_token_budget: usize = 0;
        for msg in &conv.messages {
            if msg.role == MessageRole::System {
                enhanced_messages.push(msg.clone());
                system_token_budget += msg.content.len() / 2;
                break;
            }
        }

        // 层2: 记忆上下文注入 — 分层检索 + 相关性门控
        // ═══ 核心改进 ═══
        // 不再无差别注入所有核心事实，而是：
        //   (a) 构建短期记忆上下文（情感弧线、活跃话题、回复指纹）
        //   (b) 通过 TF-IDF 相关性评分，仅注入与当前话题相关的长期记忆
        //   (c) 身份事实始终保留作为锚点，但以背景方式注入（不强调）
        //   (d) 未被话题命中的事实不注入，避免 AI 在不相关时主动提及
        //
        // 参考：智谱增强型上下文技术 — 上下文感知检索 + 相关性门控

        // 步骤 2.1：构建短期记忆上下文
        let short_term = MemoryEngine::build_short_term_context(&conv.messages);

        // 步骤 2.2：注入短期记忆（情感弧线 + 未展开线索）
        {
            let mut short_term_prompt = String::new();

            // 情感弧线描述
            if !short_term.emotional_arc.is_empty() {
                let arc_desc = MemoryEngine::describe_emotional_arc(&short_term.emotional_arc);
                if !arc_desc.is_empty() {
                    short_term_prompt.push_str(&format!("【短期记忆·情绪轨迹】\n{}\n", arc_desc));
                }
            }

            // 未展开的对话线索
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

        // 步骤 2.3：注入相关性门控的长期记忆
        if !memory_summaries.is_empty() {
            // 提取当前活跃话题
            let active_topics = MemoryEngine::extract_active_topics_from_text(user_content);

            // 检索与当前话题最相关的记忆摘要（BM25 + 语义融合）
            let search_results = MemoryEngine::search_memories(user_content, memory_summaries, 5);

            // 收集所有核心事实并按层级+相关性分类
            let mut identity_facts: Vec<String> = Vec::new(); // 身份事实（始终注入）
            let mut relevant_facts: Vec<(String, f64)> = Vec::new(); // 其他事实（相关性门控）

            for summary in memory_summaries.iter() {
                for (i, fact) in summary.core_facts.iter().enumerate() {
                    let tier = if i < summary.fact_tiers.len() {
                        &summary.fact_tiers[i]
                    } else {
                        &MemoryTier::SceneDetail
                    };

                    match tier {
                        MemoryTier::Identity => {
                            // 身份事实始终保留（核心锚点）
                            if !identity_facts.contains(fact) {
                                identity_facts.push(fact.clone());
                            }
                        }
                        _ => {
                            // 其他事实通过相关性评分门控
                            let relevance = MemoryEngine::compute_relevance_score(
                                fact,
                                &active_topics,
                                user_content,
                            );
                            // 相关性阈值 0.15：足够宽松以捕捉间接关联，
                            // 又足够严格以过滤完全无关的事实
                            if relevance > 0.15 && !relevant_facts.iter().any(|(f, _)| f == fact) {
                                relevant_facts.push((fact.clone(), relevance));
                            }
                        }
                    }
                }
            }

            // 按相关性降序排列，取 top 10
            relevant_facts
                .sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
            relevant_facts.truncate(10);

            let mut context = String::from("【长期记忆上下文】\n");

            // 注入检索到的相关记忆摘要
            if !search_results.is_empty() {
                context.push_str("▸ 与当前话题相关的历史片段：\n");
                for result in &search_results {
                    context.push_str(&format!("  · {}\n", result.summary));
                    // 只注入摘要中与当前话题有一定相关性的核心事实
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

            // 注入身份锚点（始终存在，但以背景方式提供）
            if !identity_facts.is_empty() {
                context.push_str("▸ 基础设定（背景知识）：\n");
                for fact in &identity_facts {
                    context.push_str(&format!("  ● {}\n", fact));
                }
            }

            // 注入相关性达标的其他事实
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

        // 层3: 认知思维引擎（替代简单的情感关键词匹配和连贯性检测）
        // 整合了：情感感知、语言模式检测、意图推断、关系分析、共情策略
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

        // 层4: 添加最近的对话消息，动态调整数量以适应上下文窗口
        // 用户要求每次调用最多 100K token（input + output），
        // 这里预留 ~20K 给 output（max_tokens），input 上限 80K
        let max_context_tokens: usize = 80_000;
        let reserved_tokens = system_token_budget + 4096 + 200;
        let available_for_history = if max_context_tokens > reserved_tokens {
            max_context_tokens - reserved_tokens
        } else {
            6000
        };

        let mut selected_messages: Vec<Message> = Vec::new();
        let mut accumulated_tokens: usize = 0;
        let max_messages = 20usize; // 最多保留 20 条

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

        // 层5: 风格约束（say/do 模式提示）— 由调用方在外部注入
        // 层5.5: 回复多样性约束（防止 AI 回复模式固化）
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

    /// 分析最近的 AI 回复模式，生成多样性约束提示
    /// 使用回复指纹系统检测模式固化，生成具体的反公式化建议
    /// 检测维度：开头模式、结尾模式、长度、段落结构、情感基调、动作描写、列表格式
    fn build_diversity_hint(recent_messages: &[&Message]) -> String {
        let ai_messages: Vec<&&Message> = recent_messages
            .iter()
            .filter(|m| m.role == MessageRole::Assistant)
            .collect();

        if ai_messages.len() < 3 {
            return String::new();
        }

        // 使用回复指纹系统进行结构化分析
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

    /// 构建“真人感 + 内容密度 + 强上下文联系”的系统提示
    /// 目标：
    /// 1) 避免模板化、客服化回复
    /// 2) 根据用户输入复杂度动态控制回复长度
    /// 3) 保证至少锚定一个当前消息细节 + 一个历史上下文线索
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

        // 分析最近AI回复的结构模式，生成针对性的变化指导
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
            // 生成与上次结构不同的建议
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

        // 根据场景动态构建回复节奏指导
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

        // 根据场景动态构建长度和结构建议
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

    /// Send a message: validate → detect type → persist user msg → build context →
    /// 三级模型管线（长上下文蒸馏+推理+对话）→ persist assistant msg → check memory.
    ///
    /// 三级模型管线（enable_thinking=true 时）：
    ///   Phase 0: GLM-4-LONG 长上下文蒸馏（仅在上下文超长时触发）
    ///   Phase 1: GLM-4-AIR 深度推理 → 输出思考链（ThinkingDelta）+ 分析结论
    ///   Phase 2: 将分析结论注入上下文 → GLM-4.7 生成自然对话回复（ContentDelta）
    ///
    /// 单模型模式（enable_thinking=false 时）：
    ///   直接使用 chat_model 生成对话回复
    pub async fn send_message(
        &self,
        conversation_id: &str,
        content: &str,
        chat_model: &str,
        _thinking_model: &str,
        enable_thinking: bool,
        on_event: impl Fn(ChatStreamEvent),
    ) -> Result<(), ChatError> {
        Self::validate_message(content)?;
        log::info!(
            "[send_message] conv={} | chat_model={} | thinking={} | content_len={}",
            &conversation_id[..8.min(conversation_id.len())],
            chat_model, enable_thinking, content.len()
        );

        // 自动检测 say/do 类型
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

        // 增加轮次计数
        self.conversation_store
            .increment_turn_count(conversation_id)?;

        let conv = self.conversation_store.load_conversation(conversation_id)?;

        // 加载记忆索引
        let memory_summaries = self
            .memory_engine
            .load_memory_index(conversation_id)
            .unwrap_or_default();

        // 构建上下文增强的消息列表
        let mut enhanced_messages =
            Self::build_context_enhanced_messages(&conv, content, &memory_summaries);

        // 注入 say/do 模式提示（插入到最后一条用户消息之前，确保用户消息是最后一条）
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
        // 找到最后一条用户消息的位置，将 style hint 插入到它之前
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

        // ══ 五级模型管线：知识检索 → 验证式上下文管理 → 双层思考 → 综合分析 → 自然对话 ══
        let (full_content, full_thinking) = if enable_thinking {
            // ── Phase 0.3: 本地知识库检索（纯本地，零延迟）──
            log::info!("[pipeline] Phase 0.3: 本地知识库检索");
            self.retrieve_knowledge_context(conversation_id, content, &mut enhanced_messages);

            // ── Phase 0.4: 读取已蒸馏的核心状态（若存在）──
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

            // ── Phase 0.5: 评估上下文，决定是否需要上下文管理 ──
            let memory_summaries_for_assess = self
                .memory_engine
                .load_memory_index(conversation_id)
                .unwrap_or_default();
            let (needs_long_context, total_tokens) =
                Self::assess_context_needs(&enhanced_messages, &memory_summaries_for_assess);

            // ── Phase 0.7: 验证式上下文管理（GLM-4-Long 总结 → Flash 校验 → Air 校验 → 循环）──
            if needs_long_context {
                log::info!(
                    "[pipeline] Phase 0.7: 验证式上下文管理 | tokens={}",
                    total_tokens
                );
                match self
                    .verified_summarize_context(
                        &enhanced_messages,
                        &memory_summaries_for_assess,
                        &on_event,
                    )
                    .await
                {
                    Ok(verified_summary) if !verified_summary.trim().is_empty() => {
                        // 持久化蒸馏状态
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
                            core_prompt: verified_summary.clone(),
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
                                "【经验证的上下文总结 — 必须严格遵守】\n{}\n",
                                verified_summary
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
                    _ => {
                        log::warn!("[pipeline] 验证式总结失败，使用降级蒸馏");
                        let distilled = self
                            .request_long_context_distillation(
                                &enhanced_messages,
                                &memory_summaries_for_assess,
                                content,
                                &on_event,
                            )
                            .await;
                        if !distilled.trim().is_empty() {
                            let distill_msg = Message {
                                id: String::new(),
                                role: MessageRole::System,
                                content: format!(
                                    "【长上下文蒸馏摘要（降级）】\n{}\n",
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
                }
            }

            // ── Phase 1: 双层思考（Flash + Air 并行 → Air 综合）──
            log::info!("[pipeline] Phase 1: 双层思考管线 (Flash 并行 Air → Air 综合)");
            let (synthesis_conclusion, thinking_text) = self
                .request_dual_thinking(
                    conversation_id,
                    &enhanced_messages,
                    content,
                    &on_event,
                )
                .await;

            // 双层思考失败不阻断管线 — 对话模型可独立生成回复

            // ── Phase 2: 将综合分析结论注入上下文 ──
            if !synthesis_conclusion.trim().is_empty() {
                let reasoning_msg = Message {
                    id: String::new(),
                    role: MessageRole::System,
                    content: format!(
                        "【双层深度分析结论（Flash快速洞察 + Air深度推理 + Air综合分析）】\n{}\n\n\
                         ■ 执行指令：\n\
                         基于以上综合分析结论，以角色身份自然地回复用户。\n\
                         - 分析中提到的关键事实必须准确体现在回复中\n\
                         - 知识库中的事实不可矛盾或篡改\n\
                         - 分析建议的情感策略必须执行\n\
                         - 不要在回复中提及分析过程本身\n\
                         - 回复必须完整，不要截断或省略\n\
                         - 像真人一样自然地表达，有情绪、有温度、有个性",
                        synthesis_conclusion
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

            // ── Phase 3: 对话模型（GLM-4.7/Flash）生成自然回复 ──
            log::info!(
                "[pipeline] Phase 3: {} 生成回复 | synthesis_len={} | messages={}",
                chat_model, synthesis_conclusion.len(), enhanced_messages.len()
            );
            let (content, _) = self
                .request_with_fallback(chat_model, false, &enhanced_messages, &on_event)
                .await?;

            (content, thinking_text)
        } else {
            // ── 单模型模式也注入知识库 ──
            self.retrieve_knowledge_context(conversation_id, content, &mut enhanced_messages);
            self.request_with_fallback(chat_model, false, &enhanced_messages, &on_event)
                .await?
        };

        // 如果 AI 返回了空内容（已经过多级降级重试），报告最终错误
        if full_content.trim().is_empty() {
            log::error!("[send_message] 所有降级尝试均未生成内容");
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

        log::info!("[send_message] AI回复已持久化 → 发送 Done");
        // Send Done after message is persisted so Flutter reloads the saved data
        on_event(ChatStreamEvent::Done);

        // ── 后台任务：异步提取事实存入知识库 ──
        // 首轮立即提取（捕获关键身份/设定事实），之后每3轮一次（平衡 API 开销和准确性）
        // 10 条消息的滑动窗口保证相邻提取之间有充分重叠，不会遗漏事实
        if conv.turn_count <= 1 || conv.turn_count % 3 == 0 {
            log::info!("[send_message] 触发事实提取 | turn={}", conv.turn_count);
            self.extract_and_store_facts(conversation_id, &on_event)
                .await;
        }

        Ok(())
    }

    /// 重新生成AI回复：不添加用户消息，直接基于现有对话上下文重新请求AI
    /// 同样遵循三级模型管线：GLM-4-LONG蒸馏→GLM-4-AIR推理→GLM-4.7对话
    pub async fn regenerate_response(
        &self,
        conversation_id: &str,
        chat_model: &str,
        _thinking_model: &str,
        enable_thinking: bool,
        on_event: impl Fn(ChatStreamEvent),
    ) -> Result<(), ChatError> {
        let conv = self.conversation_store.load_conversation(conversation_id)?;
        log::info!(
            "[regenerate] conv={} | chat_model={} | thinking={}",
            &conversation_id[..8.min(conversation_id.len())],
            chat_model, enable_thinking
        );

        // 找到最后一条用户消息的内容（用于构建上下文）
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

        // 加载记忆索引
        let memory_summaries = self
            .memory_engine
            .load_memory_index(conversation_id)
            .unwrap_or_default();

        // 构建上下文增强的消息列表
        let mut enhanced_messages =
            Self::build_context_enhanced_messages(&conv, &last_user_content, &memory_summaries);

        // 注入 say/do 模式提示
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

        // ══ 五级模型管线（与 send_message 相同逻辑）══
        let (full_content, full_thinking) = if enable_thinking {
            // ── Phase 0.3: 本地知识库检索 ──
            self.retrieve_knowledge_context(
                conversation_id,
                &last_user_content,
                &mut enhanced_messages,
            );

            // ── Phase 0.4: 读取已蒸馏的核心状态（若存在）──
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

            // ── Phase 0.5: 评估上下文，决定是否需要上下文管理 ──
            let memory_summaries_for_assess = self
                .memory_engine
                .load_memory_index(conversation_id)
                .unwrap_or_default();
            let (needs_long_context, total_tokens) =
                Self::assess_context_needs(&enhanced_messages, &memory_summaries_for_assess);

            // ── Phase 0.7: 验证式上下文管理（GLM-4-Long → Flash 校验 → Air 校验 → 循环）──
            if needs_long_context {
                log::info!(
                    "[regen pipeline] Phase 0.7: 验证式上下文管理 | tokens={}",
                    total_tokens
                );
                match self
                    .verified_summarize_context(
                        &enhanced_messages,
                        &memory_summaries_for_assess,
                        &on_event,
                    )
                    .await
                {
                    Ok(verified_summary) if !verified_summary.trim().is_empty() => {
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
                            core_prompt: verified_summary.clone(),
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
                                "【经验证的上下文总结 — 必须严格遵守】\n{}\n",
                                verified_summary
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
                    _ => {
                        log::warn!("[regen pipeline] 验证式总结失败，使用降级蒸馏");
                        let distilled = self
                            .request_long_context_distillation(
                                &enhanced_messages,
                                &memory_summaries_for_assess,
                                &last_user_content,
                                &on_event,
                            )
                            .await;
                        if !distilled.trim().is_empty() {
                            let distill_msg = Message {
                                id: String::new(),
                                role: MessageRole::System,
                                content: format!(
                                    "【长上下文蒸馏摘要（降级）】\n{}\n",
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
                }
            }

            // ── Phase 1: 双层思考（Flash + Air 并行 → Air 综合）──
            log::info!("[regen pipeline] Phase 1: 双层思考管线");
            let (synthesis_conclusion, thinking_text) = self
                .request_dual_thinking(
                    conversation_id,
                    &enhanced_messages,
                    &last_user_content,
                    &on_event,
                )
                .await;

            // ── Phase 2: 将综合分析结论注入上下文 ──
            if !synthesis_conclusion.trim().is_empty() {
                let reasoning_msg = Message {
                    id: String::new(),
                    role: MessageRole::System,
                    content: format!(
                        "【双层深度分析结论（Flash快速洞察 + Air深度推理 + Air综合分析）】\n{}\n\n\
                         ■ 执行指令：\n\
                         基于以上综合分析结论，以角色身份自然地回复用户。\n\
                         - 分析中提到的关键事实必须准确体现在回复中\n\
                         - 知识库中的事实不可矛盾或篡改\n\
                         - 分析建议的情感策略必须执行\n\
                         - 不要在回复中提及分析过程本身\n\
                         - 回复必须完整，不要截断或省略\n\
                         - 像真人一样自然地表达，有情绪、有温度、有个性",
                        synthesis_conclusion
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

            // ── Phase 3: 对话模型（GLM-4.7/Flash）生成自然回复 ──
            log::info!(
                "[regen pipeline] Phase 3: {} 生成回复 | synthesis_len={} | messages={}",
                chat_model, synthesis_conclusion.len(), enhanced_messages.len()
            );
            let (content, _) = self
                .request_with_fallback(chat_model, false, &enhanced_messages, &on_event)
                .await?;

            (content, thinking_text)
        } else {
            // ── 单模型模式也注入知识库 ──
            self.retrieve_knowledge_context(
                conversation_id,
                &last_user_content,
                &mut enhanced_messages,
            );
            self.request_with_fallback(chat_model, false, &enhanced_messages, &on_event)
                .await?
        };

        // 如果 AI 返回了空内容（已经过多级降级重试），报告最终错误
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

        log::info!("[regenerate] AI回复已持久化 → 发送 Done");
        // Send Done after message is persisted so Flutter reloads the saved data
        on_event(ChatStreamEvent::Done);

        Ok(())
    }

    /// 执行记忆总结（由外部调用，在 send_message 完成后异步触发）
    /// 采用双阶段验证：
    ///   阶段1: 使用总结模型生成摘要
    ///   阶段2: 使用验证 prompt 检查核心事实完整性（当已有摘要时）
    pub async fn summarize_memory(
        &self,
        conversation_id: &str,
        on_event: impl Fn(ChatStreamEvent),
    ) -> Result<Option<MemorySummary>, ChatError> {
        let conv = self.conversation_store.load_conversation(conversation_id)?;

        if !MemoryEngine::should_summarize(conv.turn_count) {
            return Ok(None);
        }

        // 获取需要总结的消息范围
        let turn_start = if conv.turn_count > 10 {
            conv.turn_count - 10 + 1
        } else {
            1
        };
        let turn_end = conv.turn_count;

        // 获取最近 20 条消息用于总结
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

        // 动态选择总结模型
        let summary_model = Self::choose_summary_model(&conv.messages);

        // ── 阶段1: 生成摘要 ──
        // 当已有多段摘要时，使用长摘要整合 prompt；否则使用标准 prompt
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

        let token = {
            let mut auth = self.jwt_auth.lock().unwrap();
            auth.get_token()
        };

        let (summary_text, _) =
            StreamingHandler::stream_chat(BIGMODEL_API_URL, &token, request_body, &on_event)
                .await?;

        // 解析总结结果
        let parsed = match Self::parse_summary_json(&summary_text) {
            Ok(p) => p,
            Err(_) => return Ok(None),
        };

        let (final_summary, mut final_core_facts) = parsed;

        // ── 阶段2: 核心事实完整性验证（当已有摘要时） ──
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
                    model: "glm-4.7-flash".to_string(),
                    timestamp: 0,
                    message_type: MessageType::Say,
                },
            ];

            let verify_body = Self::build_request_body(&verify_messages, "glm-4.7-flash", false);

            let verify_token = {
                let mut auth = self.jwt_auth.lock().unwrap();
                auth.get_token()
            };

            // 验证阶段的事件不传递给前端（静默执行）
            if let Ok((verify_text, _)) = StreamingHandler::stream_chat(
                BIGMODEL_API_URL,
                &verify_token,
                verify_body,
                |_| {}, // 静默，不向前端发送验证阶段的流事件
            )
            .await
            {
                // 尝试解析验证结果
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
                                // 使用修正后的核心事实
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

        // 构建最终记忆摘要
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
        // glm-4.7 with thinking disabled should explicitly send disabled
        let body = ChatEngine::build_request_body(&messages, "glm-4.7", false);
        assert_eq!(body["thinking"], serde_json::json!({"type": "disabled"}));
        // glm-4.7-flash with thinking disabled
        let body = ChatEngine::build_request_body(&messages, "glm-4.7-flash", false);
        assert_eq!(body["thinking"], serde_json::json!({"type": "disabled"}));
    }

    #[test]
    fn test_build_request_body_thinking_for_glm4_7_is_forced_disabled() {
        let messages = vec![make_message(MessageRole::User, "think hard")];
        // GLM-4.7 with enable_thinking=true should now work (per docs)
        let body = ChatEngine::build_request_body(&messages, "glm-4.7", true);
        assert_eq!(body["thinking"]["type"], "enabled");
        assert_eq!(body["thinking"]["budget_tokens"], 16384);
        // GLM-4.7 with enable_thinking=false should be disabled
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
        // GLM-4.7 now supports thinking (per docs)
        assert!(ChatEngine::should_enable_thinking("glm-4.7", true));
        assert!(!ChatEngine::should_enable_thinking("glm-4.7", false));
        // GLM-4-AIR: reasoning model
        assert!(ChatEngine::should_enable_thinking("glm-4-air", true));
        assert!(!ChatEngine::should_enable_thinking("glm-4-air", false));
        // Flash: now supports thinking
        assert!(ChatEngine::should_enable_thinking("glm-4.7-flash", true));
        assert!(!ChatEngine::should_enable_thinking("glm-4.7-flash", false));
        // Others: no thinking
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
