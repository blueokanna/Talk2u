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
    fn build_compact_retry_messages(messages: &[Message], max_non_system: usize) -> Vec<Message> {
        let mut compact: Vec<Message> = Vec::new();

        // 保留所有 system 消息（角色设定+记忆上下文，这些是不可丢失的）
        // 但如果 system 消息总量过大，只保留第一条（角色设定）
        let system_msgs: Vec<&Message> = messages
            .iter()
            .filter(|m| m.role == MessageRole::System)
            .collect();

        let total_system_tokens: f64 = system_msgs
            .iter()
            .map(|m| Self::estimate_str_tokens(&m.content))
            .sum();

        if total_system_tokens > 50_000.0 {
            // system 消息过大（超过 50K），只保留第一条角色设定
            if let Some(first_system) = system_msgs.first() {
                compact.push((*first_system).clone());
            }
        } else {
            // system 消息在预算内，全部保留
            for msg in &system_msgs {
                compact.push((*msg).clone());
            }
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

    /// 带自动降级重试的请求方法
    /// 策略链：
    ///   1. 完整上下文 + 用户设置的思考模式
    ///   2. 完整上下文 + 关闭思考（仅当第1步思考耗尽 token 时）
    ///   3. 精简上下文（首条系统提示 + 最近6条对话）+ 关闭思考
    ///
    /// 中间尝试的 Error 事件会被屏蔽，避免前端提前终止流式状态。
    /// ContentDelta / ThinkingDelta 始终实时转发给前端。
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

        // 包装回调：屏蔽 Error 事件（由最终调用方统一报告错误），
        // ContentDelta / ThinkingDelta / Done 照常转发
        let filtered_event = |event: ChatStreamEvent| {
            match event {
                ChatStreamEvent::Error(_) => {} // 屏蔽中间错误
                other => on_event(other),
            }
        };

        // ── 第1次尝试：完整上下文 + 用户请求的思考模式 ──
        let request_body = Self::build_request_body(enhanced_messages, model, actual_thinking);
        match StreamingHandler::stream_chat(BIGMODEL_API_URL, &token, request_body, &filtered_event)
            .await
        {
            Ok((content, thinking)) if !content.trim().is_empty() => {
                return Ok((content, thinking));
            }
            Ok((_, ref thinking)) if actual_thinking && !thinking.trim().is_empty() => {
                // 思考内容耗尽了输出 token 预算，关闭思考重试
                // ── 第2次尝试：完整上下文 + 关闭思考 ──
                let retry_body = Self::build_request_body(
                    enhanced_messages,
                    model,
                    false,
                );
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
                    _ => {} // 继续到精简重试
                }
            }
            Ok(_) => {}  // 内容和思考都为空，继续到精简重试
            Err(_) => {} // API 错误（可能上下文超长），跳到精简重试
        }

        // ── 第3次尝试：精简上下文（首条系统提示 + 最近6条对话），关闭思考 ──
        // 最终重试：不再屏蔽 Error 事件，让前端能看到具体失败原因
        let compact = Self::build_compact_retry_messages(enhanced_messages, 6);
        let compact_body = Self::build_request_body(&compact, model, false);
        StreamingHandler::stream_chat(BIGMODEL_API_URL, &token, compact_body, on_event).await
    }

    /// ══ 推理模型调用（Phase 1）══
    /// 调用推理模型（glm-4-air）进行深度分析，返回 (推理结论, 完整思考链)。
    /// - 推理结论：glm-4-air 的 content 输出（供对话模型参考的结构化分析）
    /// - 完整思考链：glm-4-air 的 reasoning_content（实时流式推送给前端）
    ///
    /// 此方法为"尽力而为"：推理失败不阻断对话，仅返回空串。
    async fn request_reasoning(
        &self,
        thinking_model: &str,
        enhanced_messages: &[Message],
        on_event: &impl Fn(ChatStreamEvent),
    ) -> (String, String) {
        let token = {
            let mut auth = self.jwt_auth.lock().unwrap();
            auth.get_token()
        };

        // 在原始上下文基础上追加推理任务指令
        let mut reasoning_messages = enhanced_messages.to_vec();
        let analysis_instruction = Message {
            id: String::new(),
            role: MessageRole::System,
            content: "【深度推理任务】\n\
                      对以上对话进行多层次分析，输出500-800字：\n\n\
                      1.【文本解码】字面意思(≤30字)→潜台词(引用原文)→表层/深层需求\n\
                      2.【上下文关联】近3-5轮因果链→历史记忆相关事实(原文引用)→已建立的共识/承诺→角色性格特征\n\
                      3.【关系动态】亲密度/信任度/张力(高/中/低+依据)→温度趋势(升/平/降)→权力动态\n\
                      4.【情感策略】最需要的回应类型→禁止的回应方式(2-3条)→语气温度(1-10)\n\
                      5.【回复蓝图】开场策略→核心回应点(引用用户原话)→情感锚点位置→收束方式→字数范围\n\
                      6.【人格一致性】角色典型反应→需避免的出戏行为\n\n\
                      要求：每项有具体结论+原文佐证，不要直接写回复，只输出分析。记忆中的事实必须原样复述。"
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

        // 仅转发 ThinkingDelta 事件；推理模型的 ContentDelta/Done/Error 不暴露给前端
        let reasoning_event = |event: ChatStreamEvent| match &event {
            ChatStreamEvent::ThinkingDelta(_) => on_event(event),
            _ => {}
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
                // 如果推理模型因 token 耗尽导致 content 为空，从思考链尾部提取摘要
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
                // 推理失败是非致命的：对话模型仍可独立工作
                (String::new(), String::new())
            }
        }
    }

    /// 从思考链尾部提取推理摘要（token 耗尽回退方案）
    /// 推理链的末尾通常包含结论性内容
    /// 改进：在句子边界处截断，避免截断到半句话
    fn extract_reasoning_brief(thinking: &str) -> String {
        let chars: Vec<char> = thinking.chars().collect();
        if chars.len() <= 500 {
            return thinking.to_string();
        }
        // 从倒数 600 字符处开始，找到第一个句子边界
        let search_start = if chars.len() > 600 { chars.len() - 600 } else { 0 };
        let tail: String = chars[search_start..].iter().collect();

        // 找到第一个句子结束符后的位置作为起点
        let sentence_ends = ['。', '！', '？', '；', '\n', '.', '!', '?'];
        if let Some(pos) = tail.find(|c: char| sentence_ends.contains(&c)) {
            let clean_start = pos + tail[pos..].chars().next().map_or(1, |c| c.len_utf8());
            let result = tail[clean_start..].trim();
            if !result.is_empty() {
                return format!("...{}", result);
            }
        }
        // 找不到句子边界，退回到字符截断
        let start = chars.len() - 500;
        format!("...{}", chars[start..].iter().collect::<String>())
    }

    /// ══ 渐进式上下文裁剪 ══
    /// 替代原来的一刀切策略，分级逐步减少上下文：
    ///   Level 1: 合并重复/相似的 system 消息内容
    ///   Level 2: 减少对话历史到最近 14 条
    ///   Level 3: 减少对话历史到最近 8 条
    ///   Level 4: 极端模式，核心 system（第一条）+ 最近 6 条
    fn gradual_context_trim(messages: Vec<Message>, budget: usize) -> Vec<Message> {
        let mut result = messages;

        // Level 1: 合并重复的 system 消息内容
        // 检测 system 消息中是否有大量重复的核心事实
        result = Self::merge_duplicate_system_content(result);
        if Self::estimate_token_count(&result) <= budget {
            return result;
        }

        // Level 2: 裁剪对话历史到最近 14 条
        result = Self::trim_history_keep_n(result, 14);
        if Self::estimate_token_count(&result) <= budget {
            return result;
        }

        // Level 3: 裁剪对话历史到最近 8 条
        result = Self::trim_history_keep_n(result, 8);
        if Self::estimate_token_count(&result) <= budget {
            return result;
        }

        // Level 4: 极端模式 — 只保留第一条 system（角色设定）+ 最近 6 条
        let first_system = result.iter().find(|m| m.role == MessageRole::System).cloned();
        let non_system: Vec<Message> = result.into_iter()
            .filter(|m| m.role != MessageRole::System)
            .collect();
        let keep = non_system.len().min(6);
        let mut final_result: Vec<Message> = Vec::new();
        if let Some(sys) = first_system {
            final_result.push(sys);
        }
        final_result.extend(non_system[non_system.len() - keep..].iter().cloned());
        final_result
    }

    /// 合并 system 消息中的重复内容
    /// 检测多条 system 消息中重复出现的核心事实行，去重合并
    fn merge_duplicate_system_content(messages: Vec<Message>) -> Vec<Message> {
        let system_msgs: Vec<&Message> = messages.iter()
            .filter(|m| m.role == MessageRole::System)
            .collect();

        if system_msgs.len() <= 2 {
            return messages;
        }

        // 收集所有 system 消息的内容行
        let mut seen_lines: std::collections::HashSet<String> = std::collections::HashSet::new();
        let mut merged_systems: Vec<Message> = Vec::new();

        for msg in &messages {
            if msg.role != MessageRole::System {
                continue;
            }

            let mut deduped_lines: Vec<String> = Vec::new();
            for line in msg.content.lines() {
                let trimmed = line.trim().to_string();
                // 跳过空行和已见过的事实行（以 → 或 ● 或 · 开头的行）
                if trimmed.is_empty() {
                    deduped_lines.push(line.to_string());
                    continue;
                }
                let is_fact_line = trimmed.starts_with('→') || trimmed.starts_with('●')
                    || trimmed.starts_with('·') || trimmed.starts_with('-')
                    || trimmed.contains('→');

                if is_fact_line {
                    if seen_lines.contains(&trimmed) {
                        continue; // 跳过重复的事实行
                    }
                    seen_lines.insert(trimmed);
                }
                deduped_lines.push(line.to_string());
            }

            let new_content = deduped_lines.join("\n");
            // 只保留有实质内容的 system 消息
            if new_content.trim().len() > 5 {
                merged_systems.push(Message {
                    content: new_content,
                    ..msg.clone()
                });
            }
        }

        // 重建消息列表：用去重后的 system 消息替换原来的
        let mut result: Vec<Message> = Vec::new();
        let mut system_idx = 0;
        for msg in &messages {
            if msg.role == MessageRole::System {
                if system_idx < merged_systems.len() {
                    result.push(merged_systems[system_idx].clone());
                    system_idx += 1;
                }
                // 如果去重后 system 消息变少了，跳过多余的
            } else {
                result.push(msg.clone());
            }
        }
        result
    }

    /// 裁剪对话历史，保留最近 N 条非 system 消息
    fn trim_history_keep_n(messages: Vec<Message>, keep_n: usize) -> Vec<Message> {
        let system_msgs: Vec<Message> = messages.iter()
            .filter(|m| m.role == MessageRole::System)
            .cloned()
            .collect();
        let non_system: Vec<Message> = messages.into_iter()
            .filter(|m| m.role != MessageRole::System)
            .collect();

        let keep = non_system.len().min(keep_n);
        let mut result = system_msgs;
        result.extend(non_system[non_system.len() - keep..].iter().cloned());
        result
    }

    /// ══ GLM-4.7 辅助 thinking ══
    /// 在特定场景下让 GLM-4.7 也参与思考：
    ///   1. 当 GLM-4-AIR 推理失败或返回空结果时
    ///   2. 当对话涉及复杂的多角色互动（需要更大上下文窗口的思考）
    ///   3. 当用户消息特别长或复杂（>200字 + 包含深度意图关键词）
    fn should_use_auxiliary_thinking(
        user_content: &str,
        reasoning_conclusion: &str,
        conv: &Conversation,
    ) -> bool {
        // 条件1：主推理模型失败
        if reasoning_conclusion.trim().is_empty() {
            return true;
        }

        // 条件2：用户消息复杂度高
        let user_len = user_content.chars().count();
        let deep_keywords = ["为什么", "怎么", "分析", "详细", "解释", "计划", "方案", "严谨", "认真"];
        let has_deep_intent = deep_keywords.iter().any(|k| user_content.contains(k));
        if user_len > 200 && has_deep_intent {
            return true;
        }

        // 条件3：对话轮次很多（长对话需要更强的上下文理解）
        if conv.turn_count > 50 && user_len > 100 {
            return true;
        }

        false
    }

    /// GLM-4.7 辅助思考：用 GLM-4.7 的 thinking 模式补充推理
    /// 与主推理不同，这里侧重于利用 GLM-4.7 更大的上下文窗口（200K vs 128K）
    /// 来捕获主推理可能遗漏的长距离上下文关联
    async fn request_auxiliary_thinking(
        &self,
        enhanced_messages: &[Message],
        primary_reasoning: &str,
        on_event: &impl Fn(ChatStreamEvent),
    ) -> String {
        let token = {
            let mut auth = self.jwt_auth.lock().unwrap();
            auth.get_token()
        };

        let mut aux_messages = enhanced_messages.to_vec();

        let aux_instruction = Message {
            id: String::new(),
            role: MessageRole::System,
            content: format!(
                "【辅助推理补充任务】\n\
                 主推理模型已给出以下分析：\n{}\n\n\
                 请补充以下方面（200字以内，只补充主推理遗漏的部分）：\n\
                 1. 长距离上下文关联：主推理可能因上下文窗口限制遗漏的历史关联\n\
                 2. 隐含情感线索：对话中未被明确识别的潜在情感变化\n\
                 3. 角色一致性检查：回复是否可能与角色历史行为矛盾\n\
                 如果主推理已经足够完善，直接输出「无需补充」。",
                if primary_reasoning.is_empty() {
                    "（主推理模型未能生成分析，请独立完成完整分析，500字以内）".to_string()
                } else {
                    primary_reasoning.to_string()
                }
            ),
            thinking_content: None,
            model: "system".to_string(),
            timestamp: 0,
            message_type: MessageType::Say,
        };

        let last_user_idx = aux_messages.iter().rposition(|m| m.role == MessageRole::User);
        if let Some(idx) = last_user_idx {
            aux_messages.insert(idx, aux_instruction);
        } else {
            aux_messages.push(aux_instruction);
        }

        // GLM-4.7 开启 thinking 模式
        let request_body = Self::build_request_body(&aux_messages, "glm-4.7", true);

        // 辅助思考是静默的，不向前端推送事件
        let silent_event = |_event: ChatStreamEvent| {};
        let _ = on_event;

        match StreamingHandler::stream_chat(BIGMODEL_API_URL, &token, request_body, &silent_event).await {
            Ok((content, _thinking)) => {
                let trimmed = content.trim();
                if trimmed == "无需补充" || trimmed.is_empty() {
                    String::new()
                } else {
                    content
                }
            }
            Err(_) => String::new(), // 辅助思考失败是非致命的
        }
    }

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

    /// 根据模型判断是否允许启用思考（用于 build_request_body 的安全守卫）
    /// 在双模型管线中，此函数仅作为请求体构建的验证层：
    /// - glm-4-air：推理专用，可启用思考
    /// - glm-4.7：支持思考（官方确认），双模型管线中由推理模型专责
    /// - glm-4.7-flash：支持思考
    pub fn should_enable_thinking(model: &str, user_preference: bool) -> bool {
        match model {
            // 推理模型：用户可选
            "glm-4-air" => user_preference,
            // 对话模型：支持思考，按用户偏好
            "glm-4.7" => user_preference,
            // 快速对话模型：支持思考，按用户偏好
            "glm-4.7-flash" => user_preference,
            _ => false,
        }
    }

    /// 估算消息列表的 token 数
    /// 智谱 GLM 系列使用 BPE tokenizer（与 OpenAI 类似但针对中英双语优化）：
    ///   - 中文：1 个汉字 ≈ 1.4 token（UTF-8 3字节，BPE 编码后约 1.4 token）
    ///   - 英文：1 个单词 ≈ 1.3 token（平均 4-5 字符 → ~1.3 token）
    ///   - 标点/特殊字符：1 个 ≈ 1 token
    /// 综合中英混合场景，使用逐字符分类估算，比固定比例更准确。
    ///
    /// 各模型上下文窗口（官方文档 2026.02）：
    ///   GLM-4.7:       200K 输入 / 128K 最大输出（推荐 max_tokens ≤ 65536）
    ///   GLM-4.7-Flash: 200K 输入 / 128K 最大输出
    ///   GLM-4-AIR:     128K 输入 / 4K 最大输出
    ///   GLM-4-LONG:    1M 输入 / 4K 最大输出
    pub fn estimate_token_count(messages: &[Message]) -> usize {
        let mut total: f64 = 0.0;
        for msg in messages {
            total += Self::estimate_str_tokens(&msg.content);
            // 每条消息有 role/content 等结构开销 ≈ 4 token
            total += 4.0;
        }
        total.ceil() as usize
    }

    /// 估算单个字符串的 token 数
    fn estimate_str_tokens(text: &str) -> f64 {
        let mut tokens: f64 = 0.0;
        for ch in text.chars() {
            if ch > '\u{4e00}' && ch <= '\u{9fff}' {
                // CJK 统一汉字：1 字 ≈ 1.4 token
                tokens += 1.4;
            } else if ch > '\u{3000}' && ch <= '\u{4dff}' {
                // CJK 标点、假名等：1 字 ≈ 1.2 token
                tokens += 1.2;
            } else if ch.is_ascii_alphanumeric() {
                // ASCII 字母/数字：平均 ~0.25 token（4字符≈1 token）
                tokens += 0.25;
            } else if ch.is_ascii_whitespace() {
                // 空白字符通常与前后 token 合并
                tokens += 0.1;
            } else {
                // 其他字符（标点、emoji 等）
                tokens += 1.0;
            }
        }
        tokens
    }

    /// 根据上下文长度选择总结模型
    /// GLM-4.7 上下文窗口 200K，GLM-4-LONG 上下文窗口 1M
    /// 超过 100K token 使用 glm-4-long，否则使用 glm-4.7-flash（200K 上下文足够）
    pub fn choose_summary_model(messages: &[Message]) -> &'static str {
        let estimated_tokens = Self::estimate_token_count(messages);
        if estimated_tokens > 100_000 {
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
            .map(|s| {
                Self::estimate_str_tokens(&s.summary).ceil() as usize
                    + s.core_facts
                        .iter()
                        .map(|f| Self::estimate_str_tokens(f).ceil() as usize)
                        .sum::<usize>()
            })
            .sum();
        let total_tokens = msg_tokens + memory_tokens;
        // 当总 token 超过 80K 或记忆条目超过 15 条时，使用 GLM-4-LONG
        // （GLM-4-AIR 只有 128K 上下文，80K 是其安全阈值）
        let needs_long = total_tokens > 80_000 || memory_summaries.len() > 15;
        (needs_long, total_tokens)
    }

    /// ══ 长上下文蒸馏（GLM-4-LONG）══
    /// 当对话历史+记忆超过 GLM-4-AIR 的有效处理范围时，
    /// 先用 GLM-4-LONG 进行无损信息蒸馏，提取核心脉络，
    /// 再将蒸馏结果注入后续管线。
    ///
    /// 设计原则：
    /// - 核心事实零丢失：身份、关系、约定、承诺必须原样保留
    /// - 情感脉络完整：情绪变化的时间线不可断裂
    /// - 信息密度最大化：用最少的 token 承载最多的关键信息
    ///
    /// Token 优化：蒸馏 prompt 本身控制在 ~300 token 以内
    async fn request_long_context_distillation(
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

        // 构建精简记忆摘要（只包含核心事实，不重复 enhanced_messages 中已有的内容）
        let mut memory_section = String::new();
        if !memory_summaries.is_empty() {
            memory_section.push_str("【记忆存档】\n");
            for (i, summary) in memory_summaries.iter().enumerate() {
                memory_section.push_str(&format!(
                    "{}. (轮{}-{}) {}｜事实: {}\n",
                    i + 1,
                    summary.turn_range_start,
                    summary.turn_range_end,
                    summary.summary,
                    summary.core_facts.join("；")
                ));
            }
        }

        let distill_instruction = Message {
            id: String::new(),
            role: MessageRole::System,
            content: format!(
                "【长上下文蒸馏任务】\n\
                 {}\n\
                 当前用户消息:「{}」\n\n\
                 将以上所有信息蒸馏为高密度摘要，要求：\n\
                 1. 不可变事实清单：角色身份/关系/设定/已发生事件/承诺约定/当前状态，逐条列出\n\
                 2. 情感脉络：关系温度变化轨迹 + 最近5轮情绪走向 + 当前基调\n\
                 3. 当前焦点：用户最新消息的语义解读 + 与历史的关联点\n\
                 信息零丢失，总字数≤1200字",
                memory_section, user_content
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

    /// Build the BigModel API request body.
    ///
    /// ═══ 核心安全措施：消息格式规范化 + Token 预算控制 ═══
    /// 1. 将所有 system 消息合并为单条放在开头
    /// 2. 防止 system 消息穿插在 user/assistant 之间导致 API 拒绝
    /// 3. 显式设置 max_tokens 确保不超出模型限制
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

        // 根据模型设置合理的 max_tokens
        // GLM-4.7/GLM-4.7-flash: 上下文 200K，最大输出 128K（官方示例用 65536）
        // GLM-4-AIR: 上下文 128K，最大输出 4K（推理模型，输出预算有限）
        // GLM-4-LONG: 上下文 1M，最大输出 4K（蒸馏/总结专用）
        let max_tokens: u32 = match model {
            "glm-4.7" | "glm-4.7-flash" => 8192,
            "glm-4-air" => 4096,
            "glm-4-long" => 4096,
            _ => 4096,
        };

        let mut body = serde_json::json!({
            "model": model,
            "messages": api_messages,
            "stream": true,
            "max_tokens": max_tokens,
        });

        // 智谱 API 思考模式控制
        // GLM-4.7 和 GLM-4-AIR 均支持 thinking（官方文档确认）
        // GLM-4.7-flash 也支持 thinking
        // 对话管线中 GLM-4.7 作为最终对话模型时关闭思考（由推理模型专责）
        // 但单模型模式下可按用户偏好开启
        match model {
            "glm-4-air" => {
                if enable_thinking {
                    body["thinking"] = serde_json::json!({"type": "enabled"});
                } else {
                    body["thinking"] = serde_json::json!({"type": "disabled"});
                }
            }
            "glm-4.7" | "glm-4.7-flash" => {
                if enable_thinking {
                    body["thinking"] = serde_json::json!({"type": "enabled"});
                    // 开启思考时 temperature 必须为 1.0（官方要求）
                    body["temperature"] = serde_json::json!(1.0);
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
    ///   层2: 记忆上下文注入（历史记忆检索结果 + 去重核心事实）
    ///   层3: 情感状态追踪（基于最近对话推断当前情绪基线）
    ///   层4: 对话历史窗口（动态裁剪，token 预算内最大化）
    ///   层5: 风格约束（say/do 模式提示）— 由调用方在外部注入
    ///
    /// Token 预算分配策略（GLM-4.7 上下文 200K，GLM-4-AIR 上下文 128K）：
    ///   - 使用 180K 作为 GLM-4.7 的安全上限（留余量给 max_tokens 8192 + 结构开销）
    ///   - system 层（层1-3+层5）：动态计算实际占用
    ///   - 对话历史（层4）：剩余预算全部分配
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
                let tokens = Self::estimate_str_tokens(&msg.content).ceil() as usize;
                system_token_budget += tokens;
                enhanced_messages.push(msg.clone());
                break;
            }
        }

        // 层2: 记忆上下文注入 — 检索相关记忆 + 去重核心事实
        if !memory_summaries.is_empty() {
            // 检索与当前话题最相关的记忆（top 5）
            let search_results = MemoryEngine::search_memories(user_content, memory_summaries, 5);

            // 收集检索命中的事实（用于去重）
            let mut seen_facts: std::collections::HashSet<String> = std::collections::HashSet::new();

            let mut context = String::from("【历史记忆上下文 — 核心事实不可违背】\n");

            // 注入检索到的相关记忆
            if !search_results.is_empty() {
                context.push_str("▸ 与当前话题相关的记忆：\n");
                for result in &search_results {
                    context.push_str(&format!("  · {}\n", result.summary));
                    for fact in &result.core_facts {
                        context.push_str(&format!("    → {}\n", fact));
                        seen_facts.insert(fact.clone());
                    }
                }
            }

            // 注入上下文增强卡片信息（提升记忆的结构化程度）
            let cards_with_context: Vec<&MemorySummary> = memory_summaries.iter()
                .filter(|s| s.context_card.is_some())
                .collect();
            if !cards_with_context.is_empty() {
                context.push_str("▸ 记忆结构化索引：\n");
                for s in cards_with_context.iter().take(5) {
                    if let Some(card) = &s.context_card {
                        let mut card_line = format!("  📋 [{}]", card.source_range);
                        if !card.topic_tags.is_empty() {
                            card_line.push_str(&format!(" 主题:{}", card.topic_tags.join(",")));
                        }
                        if !card.key_entities.is_empty() {
                            card_line.push_str(&format!(" 实体:{}", card.key_entities.join(",")));
                        }
                        card_line.push_str(&format!(" 情感:{}", card.emotional_tone));
                        context.push_str(&format!("{}\n", card_line));
                    }
                }
            }

            // 注入全局核心事实（去重：只添加检索未命中的事实）
            let mut unseen_facts: Vec<&String> = Vec::new();
            for summary in memory_summaries.iter() {
                for fact in &summary.core_facts {
                    if !seen_facts.contains(fact) {
                        unseen_facts.push(fact);
                        seen_facts.insert(fact.clone());
                    }
                }
            }

            if !unseen_facts.is_empty() {
                context.push_str("▸ 已确认的核心事实（必须严格遵守，不得矛盾）：\n");
                for fact in &unseen_facts {
                    context.push_str(&format!("  ● {}\n", fact));
                }
            }

            // 注入压缩影响警告（如果记忆经过多次压缩）
            let max_gen = memory_summaries
                .iter()
                .map(|s| s.compression_generation)
                .max()
                .unwrap_or(0);
            if max_gen >= 2 {
                let impact = MemoryEngine::compression_impact(max_gen);
                let warning = match impact {
                    CompressionImpactLevel::StyleDrift => {
                        "⚠ 记忆经过轻度压缩，语气细节可能有微小偏差，以核心事实为准。"
                    }
                    CompressionImpactLevel::PersonalityFade => {
                        "⚠ 记忆经过多次压缩，性格细节可能不完全精确。优先遵守核心事实，性格表现以角色设定为主。"
                    }
                    CompressionImpactLevel::DetailLoss => {
                        "⚠ 记忆经过较多次压缩，金钱数值和次要关系可能有偏差。如遇不确定的数值，不要编造具体数字。"
                    }
                    CompressionImpactLevel::IdentityErosion => {
                        "⚠ 记忆经过大量压缩，部分边缘设定可能已模糊。严格以角色设定和核心事实为准，不确定的内容不要编造。"
                    }
                    _ => "",
                };
                if !warning.is_empty() {
                    context.push_str(&format!("\n{}\n", warning));
                }
            }

            context.push_str(
                "\n以上记忆是已确认的事实，回复时必须与之一致。\
                 如果当前对话涉及记忆中的人物/事件，必须准确引用，不得编造或篡改。\n",
            );

            system_token_budget += Self::estimate_str_tokens(&context).ceil() as usize;
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
        let non_system: Vec<&Message> = conv
            .messages
            .iter()
            .filter(|m| m.role != MessageRole::System)
            .collect();

        if non_system.len() >= 2 {
            let cognitive_analysis = CognitiveEngine::analyze(&non_system);
            let cognitive_prompt = cognitive_analysis.cognitive_prompt;
            if !cognitive_prompt.is_empty() {
                system_token_budget += Self::estimate_str_tokens(&cognitive_prompt).ceil() as usize;
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
        // GLM-4.7: 200K 上下文，GLM-4-AIR: 128K 上下文
        // 使用 180K 作为 GLM-4.7 的安全上限（预留 max_tokens 8192 + 结构开销）
        // 对 GLM-4-AIR 管线，推理阶段会单独控制预算
        let max_context_tokens: usize = 180_000;
        // 预留：已用 system token + 输出 max_tokens(8192) + style/quality/diversity hints 估算(~3000) + 安全余量(1000)
        let reserved_tokens = system_token_budget + 8192 + 3000 + 1000;
        let available_for_history = if max_context_tokens > reserved_tokens {
            max_context_tokens - reserved_tokens
        } else {
            // 即使预算紧张，至少保留最近几条消息的空间
            6000
        };

        let mut selected_messages: Vec<Message> = Vec::new();
        let mut accumulated_tokens: usize = 0;
        let max_messages = 20usize; // 最多保留 20 条

        for msg in non_system.iter().rev() {
            let msg_tokens = Self::estimate_str_tokens(&msg.content).ceil() as usize + 4;
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
    /// 防止 AI 陷入固定的回复模板（如每次都用相同句式开头）
    fn build_diversity_hint(recent_messages: &[&Message]) -> String {
        let ai_messages: Vec<&&Message> = recent_messages
            .iter()
            .filter(|m| m.role == MessageRole::Assistant)
            .collect();

        if ai_messages.len() < 3 {
            return String::new();
        }

        let recent_starts: Vec<String> = ai_messages
            .iter()
            .rev()
            .take(5)
            .map(|m| m.content.chars().take(10).collect::<String>())
            .collect();

        let mut start_freq: std::collections::HashMap<String, usize> =
            std::collections::HashMap::new();
        for start in &recent_starts {
            let key = start.chars().take(4).collect::<String>();
            *start_freq.entry(key).or_insert(0) += 1;
        }

        let has_repetitive_starts = start_freq.values().any(|&count| count >= 3);

        let lengths: Vec<f64> = ai_messages
            .iter()
            .rev()
            .take(5)
            .map(|m| m.content.chars().count() as f64)
            .collect();

        let mean_len = lengths.iter().sum::<f64>() / lengths.len() as f64;
        let variance =
            lengths.iter().map(|l| (l - mean_len).powi(2)).sum::<f64>() / lengths.len() as f64;
        let cv = if mean_len > 0.0 {
            variance.sqrt() / mean_len
        } else {
            0.0
        }; // 变异系数

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
            "哈哈", "hh", "233", "笑死", "绝了", "6", "啊啊啊", "冲", "摸鱼", "hhh",
            "好家伙", "离谱", "牛", "xswl", "无语", "awsl", "doge",
        ];
        let has_playful = playful_keywords.iter().any(|k| lower.contains(k));

        let mut latest_user_quote = String::new();
        if !user_content.trim().is_empty() {
            latest_user_quote = user_content.chars().take(30).collect::<String>();
        }

        let history_anchor = recent_messages
            .iter()
            .rev()
            .find(|m| m.role == MessageRole::Assistant || m.role == MessageRole::User)
            .map(|m| m.content.chars().take(24).collect::<String>())
            .unwrap_or_default();

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
            "【人格真实性引擎 — 核心要求】\n\
             你不是在「扮演」一个角色，你「就是」这个人。以下是你的行为准则：\n\
             \n\
             ═══ 1. 情感真实性 ═══\n\
             - 你的情绪不是贴标签（「我很开心」），而是自然流露在语气、用词、节奏中\n\
             - 开心时语速会快、用词跳跃、可能突然蹦出不相干的话\n\
             - 难过时可能话变少、句子变短、省略号变多\n\
             - 生气时可能说反话、语气变冲、或者刻意冷淡\n\
             - 紧张时可能啰嗦、重复、说话不连贯\n\
             - 你可以有矛盾的情绪：嘴上说「讨厌」但行为很在乎；说「没事」但语气不对\n\
             \n\
             ═══ 2. 语言自然度 ═══\n\
             - 绝对禁止：「作为AI」「我理解你的感受」「没关系的」「加油哦」等客服话术\n\
             - 绝对禁止：每次都用相同句式开头、每次都以提问结尾、每次都先肯定再建议\n\
             - 绝对禁止：无意义的重复对方的话（「你说你难过，我知道你难过」）\n\
             - 真人会：突然跑题、用口癖、说到一半改口、发现自己说错话、用不完整的句子\n\
             - 真人会：有自己的联想——对方说了A，你想到了和A相关的B，自然地聊到B\n\
             - 真人会：有记忆——引用之前聊过的事，突然提起对方说过的某句话\n\
             \n\
             ═══ 3. 回复节奏 ═══\n\
             - {}\n\
             - {}\n\
             - 绝对禁止固定模板：不是每次都「情绪确认→内容回应→提问」三段式\n\
             - 变化才是自然：这次很长很认真，下次可能就一个「嗯」加一个动作\n\
             \n\
             ═══ 4. 上下文深度联系 ═══\n\
             - 必须呼应用户当前消息的具体内容：「{}」\n\
             - 延续最近上下文的线索：「{}」\n\
             - 如果历史记忆中有相关事实，必须准确引用，不得编造\n\
             - 对话是连续的故事，不是每轮重新开始\n\
             \n\
             ═══ 5. 人格深度 ═══\n\
             - 你有自己的想法、偏好、小癖好，这些会自然体现在对话中\n\
             - 你会主动分享自己的感受，而不是只回应对方\n\
             - 你有好奇心——对方说了有意思的事，你会追问、会发散\n\
             - 你有脆弱面——不会永远完美地回应，有时候也会不知道说什么好\n\
             - 你有自己的节奏——不是对方说什么你都接，有时候你会主导话题\n\
             \n\
             ═══ 6. 绝对禁止的机器感行为 ═══\n\
             - 不要列清单（1. 2. 3.）来回应情感问题\n\
             - 不要用引号复述对方的话再评价（「你说的'XX'让我...」）\n\
             - 不要每句都用叠词卖萌（除非角色设定如此且场景合适）\n\
             - 不要在情感场景给建议（对方说难过，你不要说「试试做XX」）\n\
             - 不要无来由地道歉（「不好意思让你担心了」——如果没做错事就不要道歉）",
            length_rule, structure_rule, latest_user_quote, history_anchor
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
        thinking_model: &str,
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

        // ══ Token 预算最终守卫 — 渐进式裁剪 ══
        // 不再一刀切，而是分级逐步减少上下文：
        //   Level 1 (>180K): 合并相似的 system 消息，减少重复
        //   Level 2 (>180K after L1): 裁剪对话历史到最近 14 条
        //   Level 3 (>180K after L2): 裁剪对话历史到最近 8 条
        //   Level 4 (>180K after L3): 极端模式，只保留核心 system + 最近 6 条
        let total_tokens = Self::estimate_token_count(&enhanced_messages);
        if total_tokens > 180_000 {
            enhanced_messages = Self::gradual_context_trim(enhanced_messages, 180_000);
        }

        // ══ 三级模型管线：长上下文蒸馏 → 深度推理 → 自然对话 ══
        let (full_content, full_thinking) = if enable_thinking {
            // ── Phase 0: 评估上下文复杂度，决定是否需要 GLM-4-LONG ──
            let memory_summaries_for_assess = self
                .memory_engine
                .load_memory_index(conversation_id)
                .unwrap_or_default();
            let (needs_long_context, _total_tokens) =
                Self::assess_context_needs(&enhanced_messages, &memory_summaries_for_assess);

            // ── Phase 0.5: 长上下文蒸馏（GLM-4-LONG，仅在上下文超长时触发）──
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

            // ── Phase 1: 推理模型（GLM-4-AIR）深度分析 ──
            let (reasoning_conclusion, thinking_text) = self
                .request_reasoning(thinking_model, &enhanced_messages, &on_event)
                .await;

            // ── Phase 1.5: GLM-4.7 辅助 thinking（特定场景下触发）──
            let auxiliary_supplement = if Self::should_use_auxiliary_thinking(
                content, &reasoning_conclusion, &conv
            ) {
                self.request_auxiliary_thinking(
                    &enhanced_messages, &reasoning_conclusion, &on_event
                ).await
            } else {
                String::new()
            };

            // ── Phase 2: 将推理结论注入上下文，供对话模型参考 ──
            let combined_reasoning = if !auxiliary_supplement.is_empty() {
                if reasoning_conclusion.trim().is_empty() {
                    auxiliary_supplement
                } else {
                    format!("{}\n\n【辅助推理补充】\n{}", reasoning_conclusion, auxiliary_supplement)
                }
            } else {
                reasoning_conclusion.clone()
            };

            if !combined_reasoning.trim().is_empty() {
                let reasoning_msg = Message {
                    id: String::new(),
                    role: MessageRole::System,
                    content: format!(
                        "【深度推理分析结果】\n{}\n\n\
                         ■ 执行指令：\n\
                         基于以上分析，以角色身份自然地回复用户。\n\
                         - 分析中提到的关键事实必须准确体现在回复中\n\
                         - 分析建议的情感策略必须执行\n\
                         - 不要在回复中提及分析过程本身\n\
                         - 回复必须完整，不要截断或省略\n\
                         - 像真人一样自然地表达，有情绪、有温度、有个性",
                        combined_reasoning
                    ),
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
                    enhanced_messages.insert(idx, reasoning_msg);
                } else {
                    enhanced_messages.push(reasoning_msg);
                }
            }

            // ── Phase 3: 对话模型（GLM-4.7）生成自然回复 ──
            // 对话模型始终关闭思考，由推理模型专责思考
            let (content, _) = self
                .request_with_fallback(chat_model, false, &enhanced_messages, &on_event)
                .await?;

            (content, thinking_text)
        } else {
            // ── 单模型模式：直接使用对话模型，无推理 ──
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

        // Send Done after message is persisted so Flutter reloads the saved data
        on_event(ChatStreamEvent::Done);

        Ok(())
    }

    /// 重新生成AI回复：不添加用户消息，直接基于现有对话上下文重新请求AI
    /// 同样遵循三级模型管线：GLM-4-LONG蒸馏→GLM-4-AIR推理→GLM-4.7对话
    pub async fn regenerate_response(
        &self,
        conversation_id: &str,
        chat_model: &str,
        thinking_model: &str,
        enable_thinking: bool,
        on_event: impl Fn(ChatStreamEvent),
    ) -> Result<(), ChatError> {
        let conv = self.conversation_store.load_conversation(conversation_id)?;

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

        // ══ Token 预算最终守卫 — 渐进式裁剪（与 send_message 相同逻辑）══
        let total_tokens = Self::estimate_token_count(&enhanced_messages);
        if total_tokens > 180_000 {
            enhanced_messages = Self::gradual_context_trim(enhanced_messages, 180_000);
        }

        // ══ 三级模型管线（与 send_message 相同逻辑）══
        let (full_content, full_thinking) = if enable_thinking {
            // ── Phase 0: 评估上下文复杂度，决定是否需要 GLM-4-LONG ──
            let memory_summaries_for_assess = self
                .memory_engine
                .load_memory_index(conversation_id)
                .unwrap_or_default();
            let (needs_long_context, _total_tokens) =
                Self::assess_context_needs(&enhanced_messages, &memory_summaries_for_assess);

            // ── Phase 0.5: 长上下文蒸馏（GLM-4-LONG，仅在需要时触发）──
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

            // ── Phase 1: 推理模型（GLM-4-AIR）深度分析 ──
            let (reasoning_conclusion, thinking_text) = self
                .request_reasoning(thinking_model, &enhanced_messages, &on_event)
                .await;

            // ── Phase 1.5: GLM-4.7 辅助 thinking（特定场景下触发）──
            let auxiliary_supplement = if Self::should_use_auxiliary_thinking(
                &last_user_content, &reasoning_conclusion, &conv
            ) {
                self.request_auxiliary_thinking(
                    &enhanced_messages, &reasoning_conclusion, &on_event
                ).await
            } else {
                String::new()
            };

            // ── Phase 2: 将推理结论注入上下文 ──
            let combined_reasoning = if !auxiliary_supplement.is_empty() {
                if reasoning_conclusion.trim().is_empty() {
                    auxiliary_supplement
                } else {
                    format!("{}\n\n【辅助推理补充】\n{}", reasoning_conclusion, auxiliary_supplement)
                }
            } else {
                reasoning_conclusion.clone()
            };

            if !combined_reasoning.trim().is_empty() {
                let reasoning_msg = Message {
                    id: String::new(),
                    role: MessageRole::System,
                    content: format!(
                        "【深度推理分析结果】\n{}\n\n\
                         ■ 执行指令：\n\
                         基于以上分析，以角色身份自然地回复用户。\n\
                         - 分析中提到的关键事实必须准确体现在回复中\n\
                         - 分析建议的情感策略必须执行\n\
                         - 不要在回复中提及分析过程本身\n\
                         - 回复必须完整，不要截断或省略\n\
                         - 像真人一样自然地表达，有情绪、有温度、有个性",
                        combined_reasoning
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

            // ── Phase 3: 对话模型（GLM-4.7）生成自然回复 ──
            let (content, _) = self
                .request_with_fallback(chat_model, false, &enhanced_messages, &on_event)
                .await?;

            (content, thinking_text)
        } else {
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

        let request_body = Self::build_request_body(
            &summary_messages,
            summary_model,
            false,
        );

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

            let verify_body = Self::build_request_body(
                &verify_messages,
                "glm-4.7-flash",
                false,
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
            summary: final_summary.clone(),
            core_facts: final_core_facts.clone(),
            turn_range_start: turn_start,
            turn_range_end: turn_end,
            created_at: chrono::Utc::now().timestamp_millis(),
            keywords: all_keywords,
            compression_generation: 0, // 新生成的摘要，压缩代数为 0
            // 生成上下文增强卡片
            context_card: None, // 先占位，下面填充
            // 生成排级分类
            fact_tiers: MemoryEngine::classify_all_facts(&final_core_facts),
        };

        // 为新摘要生成上下文增强卡片
        let memory = MemorySummary {
            context_card: Some(MemoryEngine::build_context_card(&memory)),
            ..memory
        };

        // 保存到记忆索引
        let mut summaries = existing_summaries;
        summaries.push(memory.clone());

        // ── 阶段3: 分级压缩合并（当摘要数量超过阈值时自动触发）──
        // 排级制度：Identity/CriticalEvent 永不丢弃，SceneDetail 优先丢弃
        if MemoryEngine::should_tiered_merge(&summaries) {
            let (merged, llm_prompt) = MemoryEngine::tiered_merge(&summaries);

            if let Some(merge_prompt) = llm_prompt {
                // 需要 LLM 辅助精炼（事实过多）
                let merge_messages = vec![
                    Message {
                        id: String::new(),
                        role: MessageRole::System,
                        content: "你是一个精确的记忆压缩系统。按照排级保护规则合并记忆，🔒标记的事实一字不改。只输出JSON。".to_string(),
                        thinking_content: None,
                        model: "system".to_string(),
                        timestamp: 0,
                        message_type: MessageType::Say,
                    },
                    Message {
                        id: String::new(),
                        role: MessageRole::User,
                        content: merge_prompt,
                        thinking_content: None,
                        model: "glm-4.7-flash".to_string(),
                        timestamp: 0,
                        message_type: MessageType::Say,
                    },
                ];

                let merge_body = Self::build_request_body(&merge_messages, "glm-4.7-flash", false);
                let merge_token = {
                    let mut auth = self.jwt_auth.lock().unwrap();
                    auth.get_token()
                };

                if let Ok((merge_text, _)) = StreamingHandler::stream_chat(
                    BIGMODEL_API_URL, &merge_token, merge_body, |_| {},
                ).await {
                    if let Ok((merged_summary, merged_facts)) = Self::parse_summary_json(&merge_text) {
                        // 解析 fact_tiers
                        let merged_tiers = MemoryEngine::classify_all_facts(&merged_facts);

                        let turn_start = merged.iter().map(|s| s.turn_range_start).min().unwrap_or(0);
                        let turn_end = merged.iter().map(|s| s.turn_range_end).max().unwrap_or(0);

                        let mut merged_keywords: Vec<String> = merged.iter()
                            .flat_map(|s| s.keywords.clone())
                            .collect();
                        merged_keywords.sort();
                        merged_keywords.dedup();

                        let llm_merged = MemorySummary {
                            id: uuid::Uuid::new_v4().to_string(),
                            summary: merged_summary,
                            core_facts: merged_facts.clone(),
                            turn_range_start: turn_start,
                            turn_range_end: turn_end,
                            created_at: chrono::Utc::now().timestamp_millis(),
                            keywords: merged_keywords,
                            compression_generation: merged.iter().map(|s| s.compression_generation).max().unwrap_or(0) + 1,
                            context_card: None,
                            fact_tiers: merged_tiers,
                        };
                        let llm_merged = MemorySummary {
                            context_card: Some(MemoryEngine::build_context_card(&llm_merged)),
                            ..llm_merged
                        };

                        summaries = vec![llm_merged];
                    } else {
                        summaries = merged;
                    }
                } else {
                    summaries = merged;
                }
            } else {
                summaries = merged;
            }

            // 为合并后的所有摘要补充上下文卡片（如果缺失）
            for s in summaries.iter_mut() {
                if s.context_card.is_none() {
                    s.context_card = Some(MemoryEngine::build_context_card(s));
                }
                if s.fact_tiers.len() != s.core_facts.len() {
                    s.fact_tiers = MemoryEngine::classify_all_facts(&s.core_facts);
                }
            }
        }

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
    pub fn restart_story(&self, conversation_id: &str) -> Result<(), ChatError> {
        let mut conv = self.conversation_store.load_conversation(conversation_id)?;

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
    fn test_build_request_body_thinking_for_glm4_7_enabled_when_requested() {
        let messages = vec![make_message(MessageRole::User, "think hard")];
        let body = ChatEngine::build_request_body(&messages, "glm-4.7", true);
        // GLM-4.7 现在支持 thinking（官方确认），用于辅助推理场景
        assert_eq!(body["thinking"], serde_json::json!({"type": "enabled"}));
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
        assert!(ChatEngine::should_enable_thinking("glm-4-air", true));
        assert!(!ChatEngine::should_enable_thinking("glm-4-air", false));
        // GLM-4.7 现在支持 thinking，用于辅助推理
        assert!(ChatEngine::should_enable_thinking("glm-4.7", true));
        assert!(!ChatEngine::should_enable_thinking("glm-4.7", false));
        assert!(ChatEngine::should_enable_thinking("glm-4.7-flash", true));
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
