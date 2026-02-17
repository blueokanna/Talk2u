use super::cognitive_engine::CognitiveEngine;
use super::conversation_store::ConversationStore;
use super::data_models::*;
use super::error_handler::ChatError;
use super::jwt_auth::JwtAuth;
use super::memory_engine::MemoryEngine;
use super::saydo_detector::SayDoDetector;
use super::streaming_handler::StreamingHandler;

const BIGMODEL_API_URL: &str = "https://open.bigmodel.cn/api/paas/v4/chat/completions";

pub struct ChatEngine {
    jwt_auth: std::sync::Mutex<JwtAuth>,
    conversation_store: ConversationStore,
    memory_engine: MemoryEngine,
}

impl ChatEngine {
    pub fn new(api_key: &str, data_path: &str) -> Result<Self, String> {
        let jwt_auth = JwtAuth::new(api_key)?;
        let conversation_store = ConversationStore::new(data_path);
        let memory_engine = MemoryEngine::new(data_path);
        Ok(Self {
            jwt_auth: std::sync::Mutex::new(jwt_auth),
            conversation_store,
            memory_engine,
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

    /// 根据模型自动决定是否启用思考
    /// glm-4-air → 自动开启思考
    /// glm-4.7 / glm-4.7-flash → 不支持思考
    pub fn should_enable_thinking(model: &str, user_preference: bool) -> bool {
        match model {
            // glm-4-air: 用户可选
            "glm-4-air" => user_preference,
            // glm-4.7: 用户可选（API 默认开启，需要显式控制）
            "glm-4.7" => user_preference,
            // flash 模型默认不开启思考，节省 token
            "glm-4.7-flash" => false,
            _ => false,
        }
    }

    /// 估算消息列表的 token 数（粗略：中文1字≈1.5token，英文1词≈1token）
    pub fn estimate_token_count(messages: &[Message]) -> usize {
        let mut total_chars: usize = 0;
        for msg in messages {
            total_chars += msg.content.len();
        }
        // 粗略估算：UTF-8 字节数 / 2 ≈ token 数（中英混合场景的合理近似）
        total_chars / 2
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

    /// Build the BigModel API request body.
    pub fn build_request_body(
        messages: &[Message],
        model: &str,
        enable_thinking: bool,
    ) -> serde_json::Value {
        Self::build_request_body_with_options(messages, model, enable_thinking, None)
    }

    /// Build the BigModel API request body with optional max_tokens override.
    pub fn build_request_body_with_options(
        messages: &[Message],
        model: &str,
        enable_thinking: bool,
        max_tokens_override: Option<u32>,
    ) -> serde_json::Value {
        let api_messages: Vec<serde_json::Value> = messages
            .iter()
            .map(|m| {
                let role = match m.role {
                    MessageRole::User => "user",
                    MessageRole::Assistant => "assistant",
                    MessageRole::System => "system",
                };
                serde_json::json!({
                    "role": role,
                    "content": m.content,
                })
            })
            .collect();

        let mut body = serde_json::json!({
            "model": model,
            "messages": api_messages,
            "stream": true,
        });

        // 设置 max_tokens
        if let Some(max_tokens) = max_tokens_override {
            body["max_tokens"] = serde_json::json!(max_tokens);
        } else {
            match model {
                "glm-4.7" | "glm-4.7-flash" => {
                    if enable_thinking {
                        // 思考模式下 max_tokens 包含 reasoning + content，需要足够大
                        body["max_tokens"] = serde_json::json!(4096);
                    } else {
                        // 非思考模式，角色扮演对话通常不需要太长
                        body["max_tokens"] = serde_json::json!(1024);
                    }
                }
                "glm-4-air" => {
                    body["max_tokens"] = serde_json::json!(4096);
                }
                _ => {} // glm-4-long 等总结模型不限制
            }
        }

        // 智谱 API 默认开启 thinking，必须显式控制
        // GLM-4.7/GLM-4.7-flash/GLM-4-air 等模型都支持 thinking 参数
        match model {
            "glm-4.7" | "glm-4.7-flash" | "glm-4-air" => {
                if enable_thinking {
                    body["thinking"] = serde_json::json!({"type": "enabled"});
                } else {
                    body["thinking"] = serde_json::json!({"type": "disabled"});
                }
            }
            _ => {}
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

        // 层2: 检索相关记忆并注入上下文
        if !memory_summaries.is_empty() {
            let search_results =
                MemoryEngine::search_memories(user_content, memory_summaries, 3);

            if !search_results.is_empty() {
                let mut context = String::from("【历史记忆上下文】\n");
                for result in &search_results {
                    context.push_str(&format!("- {}\n", result.summary));
                    for fact in &result.core_facts {
                        context.push_str(&format!("  核心事实：{}\n", fact));
                    }
                }
                context.push_str("基于以上记忆保持角色一致性。\n");

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
            let cognitive_prompt = cognitive_analysis.cognitive_prompt;
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
        // 预留 system 消息 + style hint + 输出 token 的空间
        // 保守估计：输出预留 4096 token，style hint 约 200 token
        let max_context_tokens: usize = 120_000;
        let reserved_tokens = system_token_budget + 4096 + 200;
        let available_for_history = if max_context_tokens > reserved_tokens {
            max_context_tokens - reserved_tokens
        } else {
            8000 // 最少保留 8000 token 给历史消息
        };

        // 从最新消息开始向前累积，直到达到 token 预算
        let mut selected_messages: Vec<Message> = Vec::new();
        let mut accumulated_tokens: usize = 0;
        let max_messages = 20usize; // 最多保留 20 条

        for msg in non_system.iter().rev() {
            let msg_tokens = msg.content.len() / 2;
            if selected_messages.len() >= max_messages {
                break;
            }
            if accumulated_tokens + msg_tokens > available_for_history && !selected_messages.is_empty() {
                // 已经有消息了，超出预算就停止
                break;
            }
            accumulated_tokens += msg_tokens;
            selected_messages.push((*msg).clone());
        }

        // 反转回时间顺序
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
    /// 防止 AI 陷入固定的回复模板（如每次都用相同句式开头）
    fn build_diversity_hint(recent_messages: &[&Message]) -> String {
        let ai_messages: Vec<&&Message> = recent_messages
            .iter()
            .filter(|m| m.role == MessageRole::Assistant)
            .collect();

        if ai_messages.len() < 3 {
            return String::new();
        }

        // 检测最近 AI 回复的开头模式
        let recent_starts: Vec<String> = ai_messages
            .iter()
            .rev()
            .take(5)
            .map(|m| {
                m.content
                    .chars()
                    .take(10)
                    .collect::<String>()
            })
            .collect();

        // 检测重复开头
        let mut start_freq: std::collections::HashMap<String, usize> = std::collections::HashMap::new();
        for start in &recent_starts {
            let key = start.chars().take(4).collect::<String>();
            *start_freq.entry(key).or_insert(0) += 1;
        }

        let has_repetitive_starts = start_freq.values().any(|&count| count >= 3);

        // 检测回复长度的方差（如果方差太小说明长度太固定）
        let lengths: Vec<f64> = ai_messages
            .iter()
            .rev()
            .take(5)
            .map(|m| m.content.chars().count() as f64)
            .collect();

        let mean_len = lengths.iter().sum::<f64>() / lengths.len() as f64;
        let variance = lengths.iter().map(|l| (l - mean_len).powi(2)).sum::<f64>() / lengths.len() as f64;
        let cv = if mean_len > 0.0 { variance.sqrt() / mean_len } else { 0.0 }; // 变异系数

        let has_fixed_length = cv < 0.15 && lengths.len() >= 4; // 变异系数 < 15% 说明长度太固定

        if !has_repetitive_starts && !has_fixed_length {
            return String::new();
        }

        let mut hint = String::from("【回复多样性要求】\n");
        if has_repetitive_starts {
            hint.push_str("你最近的回复开头太相似了，换一种完全不同的方式开始。\n");
            hint.push_str("试试：用动作开头、反问、感叹、直接回应对方某个词、沉默后突然说一句、发个表情再说话\n");
        }
        if has_fixed_length {
            hint.push_str(&format!(
                "你最近的回复长度都在{}字左右，太机械了。真人聊天长短不一：\n\
                 有时只回一个「嗯」，有时突然说一大段。根据情绪和情景自然变化。\n",
                mean_len.round() as u32
            ));
        }
        hint
    }

    /// Send a message: validate → detect type → persist user msg → build request → get JWT → stream SSE → persist assistant msg → check memory.
    pub async fn send_message(
        &self,
        conversation_id: &str,
        content: &str,
        model: &str,
        enable_thinking: bool,
        on_event: impl Fn(ChatStreamEvent),
    ) -> Result<(), ChatError> {
        Self::validate_message(content)?;

        // 自动检测 say/do 类型
        let message_type = Self::detect_message_type(content);

        let user_msg = Message {
            id: uuid::Uuid::new_v4().to_string(),
            role: MessageRole::User,
            content: content.to_string(),
            thinking_content: None,
            model: model.to_string(),
            timestamp: chrono::Utc::now().timestamp_millis(),
            message_type: message_type.clone(),
        };
        self.conversation_store
            .add_message(conversation_id, user_msg)?;

        // 增加轮次计数
        self.conversation_store
            .increment_turn_count(conversation_id)?;

        let conv = self
            .conversation_store
            .load_conversation(conversation_id)?;

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

        // 自动决定是否启用思考
        let actual_thinking = Self::should_enable_thinking(model, enable_thinking);

        let request_body = Self::build_request_body(&enhanced_messages, model, actual_thinking);

        let token = {
            let mut auth = self.jwt_auth.lock().unwrap();
            auth.get_token()
        };

        let (full_content, full_thinking) = StreamingHandler::stream_chat(
            BIGMODEL_API_URL,
            &token,
            request_body,
            &on_event,
        )
        .await?;

        // 如果 AI 返回了空内容，发送 Done 事件让前端正确结束流式状态
        if full_content.trim().is_empty() {
            if !full_thinking.is_empty() {
                on_event(ChatStreamEvent::Error(
                    "AI 思考过程消耗了全部 token 预算，未能生成回复内容。请重试或关闭思考模式。".to_string(),
                ));
            }
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
            model: model.to_string(),
            timestamp: chrono::Utc::now().timestamp_millis(),
            message_type: MessageType::Say,
        };
        self.conversation_store
            .add_message(conversation_id, assistant_msg)?;

        // Send Done after message is persisted so Flutter reloads the saved data
        on_event(ChatStreamEvent::Done);

        Ok(())
    }

    /// 重新生成AI回复：不添加用户消息，直接基于现有对话上下文重新请求AI
    pub async fn regenerate_response(
        &self,
        conversation_id: &str,
        model: &str,
        enable_thinking: bool,
        on_event: impl Fn(ChatStreamEvent),
    ) -> Result<(), ChatError> {
        let conv = self
            .conversation_store
            .load_conversation(conversation_id)?;

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
        let last_user_idx = enhanced_messages
            .iter()
            .rposition(|m| m.role == MessageRole::User);
        if let Some(idx) = last_user_idx {
            enhanced_messages.insert(idx, style_msg);
        } else {
            enhanced_messages.push(style_msg);
        }

        let actual_thinking = Self::should_enable_thinking(model, enable_thinking);
        let request_body = Self::build_request_body(&enhanced_messages, model, actual_thinking);

        let token = {
            let mut auth = self.jwt_auth.lock().unwrap();
            auth.get_token()
        };

        let (full_content, full_thinking) = StreamingHandler::stream_chat(
            BIGMODEL_API_URL,
            &token,
            request_body,
            &on_event,
        )
        .await?;

        // 如果 AI 返回了空内容，发送 Done 事件让前端正确结束流式状态
        if full_content.trim().is_empty() {
            if !full_thinking.is_empty() {
                on_event(ChatStreamEvent::Error(
                    "AI 思考过程消耗了全部 token 预算，未能生成回复内容。请重试或关闭思考模式。".to_string(),
                ));
            }
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
            model: model.to_string(),
            timestamp: chrono::Utc::now().timestamp_millis(),
            message_type: MessageType::Say,
        };
        self.conversation_store
            .add_message(conversation_id, assistant_msg)?;

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
        let conv = self
            .conversation_store
            .load_conversation(conversation_id)?;

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
                content: "你是一个精确的记忆管理系统，负责总结对话内容。请严格按照要求的JSON格式输出。".to_string(),
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

        // 总结不限制 max_tokens（传 4096 以确保完整输出）
        let request_body = Self::build_request_body_with_options(&summary_messages, summary_model, false, Some(4096));

        let token = {
            let mut auth = self.jwt_auth.lock().unwrap();
            auth.get_token()
        };

        let (summary_text, _) = StreamingHandler::stream_chat(
            BIGMODEL_API_URL,
            &token,
            request_body,
            &on_event,
        )
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

            // 验证使用 glm-4.7-flash（快速且足够）
            let verify_body = Self::build_request_body_with_options(
                &verify_messages,
                "glm-4.7-flash",
                false,
                Some(2048),
            );

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

        let memory = MemorySummary {
            id: uuid::Uuid::new_v4().to_string(),
            summary: final_summary,
            core_facts: final_core_facts,
            turn_range_start: turn_start,
            turn_range_end: turn_end,
            created_at: chrono::Utc::now().timestamp_millis(),
            keywords: all_keywords,
        };

        // 保存到记忆索引
        let mut summaries = existing_summaries;
        summaries.push(memory.clone());
        self.memory_engine
            .save_memory_index(conversation_id, &summaries)?;

        // 同时更新对话中的记忆摘要
        self.conversation_store
            .update_memory_summaries(conversation_id, &summaries)?;

        Ok(Some(memory))
    }

    /// 解析总结 JSON
    fn parse_summary_json(text: &str) -> Result<(String, Vec<String>), String> {
        // 尝试提取 JSON 部分
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

    /// 重启剧情：清除对话消息但保留 system prompt 和角色开场白
    pub fn restart_story(
        &self,
        conversation_id: &str,
    ) -> Result<(), ChatError> {
        let mut conv = self
            .conversation_store
            .load_conversation(conversation_id)?;

        // 保留 system 消息和第一条 assistant 消息（开场白）
        let mut kept_messages: Vec<Message> = Vec::new();
        let mut found_greeting = false;

        for msg in &conv.messages {
            if msg.role == MessageRole::System {
                kept_messages.push(msg.clone());
            } else if msg.role == MessageRole::Assistant && !found_greeting {
                // 保留第一条 AI 消息作为开场白
                kept_messages.push(msg.clone());
                found_greeting = true;
            }
        }

        conv.messages = kept_messages;
        conv.turn_count = 0;
        conv.memory_summaries.clear();
        conv.updated_at = chrono::Utc::now().timestamp_millis();

        self.conversation_store.save_conversation(&conv)?;

        // 清除记忆索引
        self.memory_engine.delete_memory_index(conversation_id)?;

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
        assert_eq!(body["thinking"], serde_json::json!({"type": "enabled"}));
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
    fn test_build_request_body_thinking_enabled_for_glm4_7() {
        let messages = vec![make_message(MessageRole::User, "think hard")];
        let body = ChatEngine::build_request_body(&messages, "glm-4.7", true);
        assert_eq!(body["thinking"], serde_json::json!({"type": "enabled"}));
    }

    #[test]
    fn test_build_request_body_no_thinking_for_unknown_model() {
        let messages = vec![make_message(MessageRole::User, "hi")];
        for model in &["glm-4-flash", "glm-4-long"] {
            let body = ChatEngine::build_request_body(&messages, model, true);
            assert!(body.get("thinking").is_none(), "Model {} should not have thinking param", model);
        }
    }

    #[test]
    fn test_build_request_body_stream_true_with_all_models() {
        let messages = vec![make_message(MessageRole::User, "test")];
        for model in &["glm-4.7", "glm-4-flash", "glm-4-air", "glm-4-long"] {
            let body = ChatEngine::build_request_body(&messages, model, false);
            assert_eq!(body["stream"], serde_json::json!(true), "stream should be true for model {}", model);
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
        assert!(ChatEngine::should_enable_thinking("glm-4-air", true));
        assert!(!ChatEngine::should_enable_thinking("glm-4-air", false));
        assert!(ChatEngine::should_enable_thinking("glm-4.7", true));
        assert!(!ChatEngine::should_enable_thinking("glm-4.7", false));
        assert!(!ChatEngine::should_enable_thinking("glm-4.7-flash", true));
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
