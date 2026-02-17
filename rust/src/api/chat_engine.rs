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

        // 层3: 情感状态追踪
        let non_system: Vec<&Message> = conv
            .messages
            .iter()
            .filter(|m| m.role != MessageRole::System)
            .collect();

        if non_system.len() >= 4 {
            let emotional_context = Self::build_emotional_context(&non_system);
            if !emotional_context.is_empty() {
                system_token_budget += emotional_context.len() / 2;
                enhanced_messages.push(Message {
                    id: String::new(),
                    role: MessageRole::System,
                    content: emotional_context,
                    thinking_content: None,
                    model: "system".to_string(),
                    timestamp: 0,
                    message_type: MessageType::Say,
                });
            }
        }

        // 层3.5: 对话连贯性与上下文指代消歧
        // 分析最近几条消息中的指代关系，防止张冠李戴
        if non_system.len() >= 2 {
            let coherence_context = Self::build_coherence_context(&non_system);
            if !coherence_context.is_empty() {
                system_token_budget += coherence_context.len() / 2;
                enhanced_messages.push(Message {
                    id: String::new(),
                    role: MessageRole::System,
                    content: coherence_context,
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

    /// 构建对话连贯性上下文，防止张冠李戴和上下文断裂
    /// 提取最近对话中的关键话题、指代关系和未完成的话题线索
    fn build_coherence_context(recent_messages: &[&Message]) -> String {
        let last_n: Vec<&&Message> = recent_messages.iter().rev().take(6).collect();
        if last_n.len() < 2 {
            return String::new();
        }

        let mut context = String::new();

        // 1. 提取最近的话题焦点（最后2-3条消息的核心内容）
        let last_user_msgs: Vec<&str> = last_n.iter()
            .filter(|m| m.role == MessageRole::User)
            .take(2)
            .map(|m| m.content.as_str())
            .collect();

        let last_ai_msgs: Vec<&str> = last_n.iter()
            .filter(|m| m.role == MessageRole::Assistant)
            .take(2)
            .map(|m| m.content.as_str())
            .collect();

        // 2. 检测话题转换信号
        if last_user_msgs.len() >= 2 {
            let current = last_user_msgs[0];
            let previous = last_user_msgs[1];

            // 检测是否在延续同一话题（通过共享关键词）
            let current_chars: std::collections::HashSet<String> = current.chars()
                .collect::<Vec<_>>()
                .windows(2)
                .map(|w| w.iter().collect::<String>())
                .filter(|s| s.chars().any(|c| c > '\u{4e00}'))
                .collect();
            let previous_chars: std::collections::HashSet<String> = previous.chars()
                .collect::<Vec<_>>()
                .windows(2)
                .map(|w| w.iter().collect::<String>())
                .filter(|s| s.chars().any(|c| c > '\u{4e00}'))
                .collect();

            let overlap = current_chars.intersection(&previous_chars).count();
            let topic_continuity = if current_chars.is_empty() || previous_chars.is_empty() {
                0.0
            } else {
                overlap as f64 / current_chars.len().min(previous_chars.len()) as f64
            };

            if topic_continuity < 0.1 && !current.trim().is_empty() && !previous.trim().is_empty() {
                context.push_str("【上下文提示】对方刚换了话题，注意不要还在聊之前的内容。\n");
            } else if topic_continuity > 0.3 {
                context.push_str("【上下文提示】对方在延续之前的话题，保持连贯，记住之前聊的内容。\n");
            }
        }

        // 3. 检测问句未回答（防止忽略对方的问题）
        if let Some(last_user) = last_user_msgs.first() {
            let has_question = last_user.contains('？') || last_user.contains('?')
                || last_user.contains("吗") || last_user.contains("呢")
                || last_user.contains("什么") || last_user.contains("怎么")
                || last_user.contains("为什么") || last_user.contains("哪")
                || last_user.contains("谁") || last_user.contains("几");

            if has_question {
                context.push_str("【上下文提示】对方在问你问题，要回应（但可以用角色的方式回应，不一定要正面回答）。\n");
            }
        }

        // 4. 检测情绪转折（防止情绪不连贯）
        if last_ai_msgs.len() >= 1 && last_user_msgs.len() >= 1 {
            let user_text = last_user_msgs[0];
            let ai_text = last_ai_msgs[0];

            // 检测用户是否在表达负面情绪但AI之前回复很积极（情绪错位）
            let user_negative = ["难过", "伤心", "不开心", "烦", "累", "算了", "没意思", "唉"]
                .iter().any(|kw| user_text.contains(kw));
            let ai_was_cheerful = ["哈哈", "嘿嘿", "好开心", "太好了", "耶"]
                .iter().any(|kw| ai_text.contains(kw));

            if user_negative && ai_was_cheerful {
                context.push_str("【上下文提示】对方情绪转低了，你需要感知到这个变化，调整你的语气和态度。\n");
            }
        }

        context
    }

    fn build_emotional_context(recent_messages: &[&Message]) -> String {
        // 基于 Plutchik 情感轮模型的 8 维情感空间 + 扩展维度
        // 每个维度对应一组关键词，使用指数衰减加权
        let emotion_lexicon: &[(&str, &str, &[&str])] = &[
            ("喜悦", "joy", &["开心", "高兴", "快乐", "笑", "哈哈", "嘻嘻", "好的", "太好了", "喜欢", "爱", "幸福", "温暖", "感谢", "谢谢", "棒", "赞", "耶", "嘿嘿", "甜", "嘿嘿嘿", "哈哈哈", "噗", "好耶", "绝了", "爽", "舒服", "满足", "开心死了", "乐", "美", "妙"]),
            ("悲伤", "sadness", &["难过", "伤心", "痛苦", "哭", "呜呜", "失望", "沮丧", "孤独", "寂寞", "心疼", "遗憾", "可惜", "唉", "叹", "泪", "委屈", "心酸", "难受", "不开心", "丧", "emo", "崩溃", "受不了", "好累", "算了", "无所谓了", "没意思"]),
            ("愤怒", "anger", &["生气", "愤怒", "气死", "混蛋", "可恶", "滚", "烦死", "受够", "讨厌", "烦", "恼", "怒", "闭嘴", "够了", "你行", "随便你", "爱咋咋", "呵呵", "哦", "行吧", "切", "啧"]),
            ("恐惧", "fear", &["害怕", "恐惧", "担心", "紧张", "不安", "慌", "怕", "焦虑", "忐忑", "心虚", "发抖", "不敢", "完了", "怎么办", "糟了", "慌了"]),
            ("惊讶", "surprise", &["惊讶", "天哪", "什么", "不会吧", "真的吗", "居然", "竟然", "没想到", "啊", "哇", "诶", "卧槽", "我靠", "天呐", "不是吧", "啊？", "嗯？", "等等"]),
            ("亲密", "intimacy", &["抱", "靠", "牵手", "依偎", "亲", "蹭", "贴", "挽", "搂", "窝", "枕", "偎", "想你", "在吗", "陪我", "别走", "过来", "靠近", "抱抱", "摸摸头", "宝", "亲爱的", "乖"]),
            ("信赖", "trust", &["相信", "信任", "放心", "安心", "依赖", "靠谱", "踏实", "陪", "懂", "理解", "知道", "明白", "你说的对", "听你的", "交给你"]),
            ("期待", "anticipation", &["期待", "想", "盼", "等", "希望", "要是", "如果能", "好想", "什么时候", "快点", "等不及", "明天", "下次", "以后", "一起"]),
        ];

        let total = recent_messages.len();
        if total == 0 {
            return String::new();
        }

        // 指数衰减半衰期 = 3 条消息
        // 权重公式: w(d) = 0.5^(d / τ), τ = 3.0
        let decay_half_life: f64 = 3.0;
        let mut emotion_scores: Vec<(&str, &str, f64)> = emotion_lexicon
            .iter()
            .map(|(cn, en, _)| (*cn, *en, 0.0))
            .collect();

        for (i, msg) in recent_messages.iter().enumerate() {
            let distance = (total - 1 - i) as f64;
            let weight = (0.5_f64).powf(distance / decay_half_life);

            // 区分用户消息和AI消息的权重：用户消息权重 ×1.2（用户情绪更重要）
            let role_factor = if msg.role == MessageRole::User { 1.2 } else { 0.8 };

            for (emo_idx, (_cn, _en, keywords)) in emotion_lexicon.iter().enumerate() {
                let mut hit_count = 0u32;
                for kw in *keywords {
                    if msg.content.contains(kw) {
                        hit_count += 1;
                    }
                }
                if hit_count > 0 {
                    // 对数饱和：避免单条消息中多次命中导致分数爆炸
                    // score += w * role_factor * ln(1 + hits)
                    let contribution = weight * role_factor * (1.0 + hit_count as f64).ln();
                    emotion_scores[emo_idx].2 += contribution;
                }
            }
        }

        // 筛选显著情感（得分 > 0.3 的维度）
        let significant: Vec<(&str, &str, f64)> = emotion_scores
            .into_iter()
            .filter(|(_, _, score)| *score > 0.3)
            .collect();

        if significant.is_empty() {
            return String::new();
        }

        // Softmax 归一化：将原始分数转换为概率分布
        // P(i) = exp(s_i) / Σ exp(s_j)
        let max_score = significant.iter().map(|(_, _, s)| *s).fold(f64::NEG_INFINITY, f64::max);
        let exp_sum: f64 = significant.iter().map(|(_, _, s)| (s - max_score).exp()).sum();

        let mut context = String::from("【情感状态向量（Plutchik 8维模型）】\n");
        context.push_str("当前对话的情绪分布：");
        for (i, (cn, _en, score)) in significant.iter().enumerate() {
            let prob = ((score - max_score).exp() / exp_sum * 100.0).round() as u32;
            if i > 0 {
                context.push(',');
            }
            context.push_str(&format!("{}:{}%", cn, prob));
        }

        // 计算情绪变化趋势（最近 2 条 vs 之前的消息）
        if total >= 4 {
            let mid = total / 2;
            let recent_half = &recent_messages[mid..];
            let earlier_half = &recent_messages[..mid];

            let recent_valence = Self::compute_valence(recent_half, emotion_lexicon);
            let earlier_valence = Self::compute_valence(earlier_half, emotion_lexicon);
            let delta = recent_valence - earlier_valence;

            if delta.abs() > 0.15 {
                let trend = if delta > 0.0 { "↑趋向积极" } else { "↓趋向消极" };
                context.push_str(&format!("\n情绪趋势：{}（Δ={:.2}）", trend, delta));
            }
        }

        // 推断心理状态（基于情绪组合模式）
        let joy_score = significant.iter().find(|(cn, _, _)| *cn == "喜悦").map(|(_, _, s)| *s).unwrap_or(0.0);
        let sad_score = significant.iter().find(|(cn, _, _)| *cn == "悲伤").map(|(_, _, s)| *s).unwrap_or(0.0);
        let anger_score = significant.iter().find(|(cn, _, _)| *cn == "愤怒").map(|(_, _, s)| *s).unwrap_or(0.0);
        let intimacy_score = significant.iter().find(|(cn, _, _)| *cn == "亲密").map(|(_, _, s)| *s).unwrap_or(0.0);
        let fear_score = significant.iter().find(|(cn, _, _)| *cn == "恐惧").map(|(_, _, s)| *s).unwrap_or(0.0);
        let anticipation_score = significant.iter().find(|(cn, _, _)| *cn == "期待").map(|(_, _, s)| *s).unwrap_or(0.0);

        // 复合心理状态推断
        let mut psych_states: Vec<&str> = Vec::new();
        if intimacy_score > 0.5 && fear_score > 0.3 {
            psych_states.push("又想靠近又怕受伤的矛盾心理");
        }
        if anger_score > 0.5 && sad_score > 0.3 {
            psych_states.push("生气背后藏着委屈和受伤");
        }
        if joy_score > 0.5 && intimacy_score > 0.3 {
            psych_states.push("因为对方而感到幸福和安全感");
        }
        if sad_score > 0.5 && anticipation_score > 0.3 {
            psych_states.push("虽然难过但还抱有期待");
        }
        if anger_score > 0.3 && intimacy_score > 0.3 {
            psych_states.push("因为在乎所以才生气（撒娇式愤怒）");
        }
        if fear_score > 0.5 && anticipation_score > 0.3 {
            psych_states.push("对未知既紧张又期待");
        }

        if !psych_states.is_empty() {
            context.push_str(&format!("\n深层心理：{}", psych_states.join("；")));
        }

        // 推断情景氛围
        let last_few: Vec<&&Message> = recent_messages.iter().rev().take(4).collect();
        let combined_text: String = last_few.iter().map(|m| m.content.as_str()).collect::<Vec<_>>().join(" ");

        let mut scene_hints: Vec<&str> = Vec::new();
        // 检测对话节奏（短消息密集 = 即时聊天氛围）
        let avg_len = last_few.iter().map(|m| m.content.chars().count()).sum::<usize>() as f64 / last_few.len().max(1) as f64;
        if avg_len < 10.0 {
            scene_hints.push("对话节奏很快，像在即时聊天");
        } else if avg_len > 50.0 {
            scene_hints.push("对话节奏较慢，在认真交流");
        }

        // 检测亲密度信号
        if combined_text.contains("晚安") || combined_text.contains("睡了") || combined_text.contains("困") || combined_text.contains("深夜") {
            scene_hints.push("深夜/睡前氛围，语气应更柔软私密");
        }
        if combined_text.contains("对不起") || combined_text.contains("抱歉") || combined_text.contains("我错了") {
            scene_hints.push("道歉/和解场景，情绪敏感需要小心回应");
        }
        if combined_text.contains("再见") || combined_text.contains("走了") || combined_text.contains("要走") || combined_text.contains("离开") {
            scene_hints.push("离别/分开场景，可能有不舍或释然");
        }

        if !scene_hints.is_empty() {
            context.push_str(&format!("\n情景感知：{}", scene_hints.join("；")));
        }

        context.push_str("\n请自然体现这种情绪和心理状态，不要刻意点明情绪名称。回复的语气、用词、节奏、长短都应与当前心理状态一致。情绪低落时话要少，兴奋时可以多说。\n");

        context
    }

    /// 计算情感效价（valence）：积极情感为正，消极情感为负
    /// valence = (joy + trust + anticipation + intimacy - sadness - anger - fear) / total
    fn compute_valence(messages: &[&Message], lexicon: &[(&str, &str, &[&str])]) -> f64 {
        let positive_indices = [0usize, 5, 6, 7]; // joy, intimacy, trust, anticipation
        let negative_indices = [1usize, 2, 3];     // sadness, anger, fear

        let mut pos_score = 0.0f64;
        let mut neg_score = 0.0f64;

        for msg in messages {
            for &idx in &positive_indices {
                for kw in lexicon[idx].2 {
                    if msg.content.contains(kw) {
                        pos_score += 1.0;
                    }
                }
            }
            for &idx in &negative_indices {
                for kw in lexicon[idx].2 {
                    if msg.content.contains(kw) {
                        neg_score += 1.0;
                    }
                }
            }
        }

        let total = pos_score + neg_score;
        if total == 0.0 {
            0.0
        } else {
            (pos_score - neg_score) / total
        }
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
