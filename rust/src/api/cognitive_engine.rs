use super::data_models::{Message, MessageRole};

type EmotionLexiconEntry = (&'static str, usize, &'static [(&'static str, f64)]);

#[derive(Debug, Clone)]
pub struct EmotionVector {
    pub joy: f64,
    pub sadness: f64,
    pub anger: f64,
    pub fear: f64,
    pub surprise: f64,
    pub intimacy: f64,
    pub trust: f64,
    pub anticipation: f64,
    pub valence: f64,
    pub arousal: f64,
}

#[derive(Debug, Clone, PartialEq)]
pub enum DialogueIntent {
    SeekingComfort,
    ExpressingAffection,
    ExpressingDispleasure,
    TestingBoundary,
    SharingDaily,
    SeekingResponse,
    EmotionalVenting,
    Playful,
    Reconciling,
    Farewell,
    Withdrawn,
    DeepSharing,
}

#[derive(Debug, Clone)]
pub struct RelationshipDynamics {
    pub closeness: f64,
    pub trust_level: f64,
    pub tension: f64,
    pub power_balance: f64,
    pub trend: f64,
}

#[derive(Debug, Clone)]
pub struct CognitiveAnalysis {
    pub emotion: EmotionVector,
    pub intent: DialogueIntent,
    pub relationship: RelationshipDynamics,
    pub empathy_strategy: EmpathyStrategy,
    pub detected_patterns: Vec<LanguagePattern>,
    pub cognitive_prompt: String,
}

#[derive(Debug, Clone, PartialEq)]
pub enum EmpathyStrategy {
    Mirror,
    Accompany,
    Distract,
    Responsive,
    PlayfulCounter,
    GentleFirm,
    ProactiveCare,
    NaturalFlow,
    GiveSpace,
    Escalate,
}

#[derive(Debug, Clone, PartialEq)]
pub enum LanguagePattern {
    Negation,
    Sarcasm,
    Hesitation,
    Repetition,
    Urgent,
    Dragging,
    Contradictory,
    Probing,
    Coquettish,
    Defensive,
    Suppressed,
    TopicAvoidance,
}

pub struct CognitiveEngine;

impl CognitiveEngine {
    pub fn analyze(messages: &[&Message]) -> CognitiveAnalysis {
        let emotion = Self::perceive_emotion(messages);
        let patterns = Self::detect_language_patterns(messages);
        let intent = Self::infer_intent(messages, &emotion, &patterns);
        let relationship = Self::analyze_relationship(messages, &emotion);
        let empathy_strategy =
            Self::choose_empathy_strategy(&emotion, &intent, &relationship, &patterns);
        let cognitive_prompt = Self::generate_cognitive_prompt(
            &emotion,
            &intent,
            &relationship,
            &empathy_strategy,
            &patterns,
            messages,
        );

        CognitiveAnalysis {
            emotion,
            intent,
            relationship,
            empathy_strategy,
            detected_patterns: patterns,
            cognitive_prompt,
        }
    }

    fn perceive_emotion(messages: &[&Message]) -> EmotionVector {
        let total = messages.len();
        if total == 0 {
            return EmotionVector {
                joy: 0.0, sadness: 0.0, anger: 0.0, fear: 0.0,
                surprise: 0.0, intimacy: 0.0, trust: 0.0, anticipation: 0.0,
                valence: 0.0, arousal: 0.0,
            };
        }

        static EMOTION_LEXICON: &[EmotionLexiconEntry] = &[
            (
                "joy",
                0,
                &[
                    ("开心", 0.8),
                    ("高兴", 0.8),
                    ("快乐", 0.9),
                    ("笑", 0.5),
                    ("哈哈", 0.7),
                    ("嘻嘻", 0.6),
                    ("太好了", 0.8),
                    ("喜欢", 0.7),
                    ("爱", 0.9),
                    ("幸福", 0.95),
                    ("温暖", 0.6),
                    ("感谢", 0.5),
                    ("谢谢", 0.4),
                    ("棒", 0.6),
                    ("赞", 0.5),
                    ("耶", 0.7),
                    ("嘿嘿", 0.6),
                    ("甜", 0.7),
                    ("哈哈哈", 0.8),
                    ("噗", 0.5),
                    ("好耶", 0.8),
                    ("绝了", 0.7),
                    ("爽", 0.7),
                    ("舒服", 0.6),
                    ("满足", 0.7),
                    ("开心死了", 1.0),
                    ("乐", 0.6),
                    ("美", 0.5),
                    ("妙", 0.5),
                    ("嘿嘿嘿", 0.7),
                    ("好开心", 0.9),
                    ("超开心", 1.0),
                    ("太棒了", 0.9),
                    ("好喜欢", 0.9),
                    ("心花怒放", 1.0),
                    ("飘了", 0.7),
                    ("上头", 0.6),
                ],
            ),
            (
                "sadness",
                1,
                &[
                    ("难过", 0.8),
                    ("伤心", 0.9),
                    ("痛苦", 1.0),
                    ("哭", 0.8),
                    ("呜呜", 0.7),
                    ("失望", 0.7),
                    ("沮丧", 0.8),
                    ("孤独", 0.8),
                    ("寂寞", 0.7),
                    ("心疼", 0.7),
                    ("遗憾", 0.6),
                    ("可惜", 0.5),
                    ("唉", 0.5),
                    ("叹", 0.4),
                    ("泪", 0.7),
                    ("委屈", 0.8),
                    ("心酸", 0.8),
                    ("难受", 0.8),
                    ("不开心", 0.7),
                    ("丧", 0.6),
                    ("emo", 0.7),
                    ("崩溃", 1.0),
                    ("受不了", 0.9),
                    ("好累", 0.6),
                    ("算了", 0.5),
                    ("无所谓了", 0.6),
                    ("没意思", 0.5),
                    ("心碎", 1.0),
                    ("扎心", 0.8),
                    ("好难过", 0.9),
                    ("想哭", 0.8),
                    ("眼泪", 0.7),
                    ("哭了", 0.9),
                    ("不想说话", 0.7),
                    ("好烦", 0.6),
                    ("活着好累", 1.0),
                ],
            ),
            (
                "anger",
                2,
                &[
                    ("生气", 0.8),
                    ("愤怒", 1.0),
                    ("气死", 0.9),
                    ("混蛋", 0.9),
                    ("可恶", 0.8),
                    ("滚", 1.0),
                    ("烦死", 0.8),
                    ("受够", 0.9),
                    ("讨厌", 0.7),
                    ("烦", 0.6),
                    ("恼", 0.6),
                    ("怒", 0.8),
                    ("闭嘴", 0.9),
                    ("够了", 0.8),
                    ("你行", 0.5),
                    ("随便你", 0.6),
                    ("爱咋咋", 0.7),
                    ("切", 0.4),
                    ("啧", 0.4),
                    ("有病", 0.8),
                    ("神经病", 0.9),
                    ("你够了", 0.8),
                    ("别烦我", 0.8),
                    ("我不想理你", 0.7),
                    ("走开", 0.8),
                    ("少来", 0.6),
                    ("你烦不烦", 0.8),
                ],
            ),
            (
                "fear",
                3,
                &[
                    ("害怕", 0.8),
                    ("恐惧", 1.0),
                    ("担心", 0.6),
                    ("紧张", 0.6),
                    ("不安", 0.7),
                    ("慌", 0.7),
                    ("怕", 0.6),
                    ("焦虑", 0.8),
                    ("忐忑", 0.7),
                    ("心虚", 0.6),
                    ("发抖", 0.8),
                    ("不敢", 0.6),
                    ("完了", 0.7),
                    ("怎么办", 0.6),
                    ("糟了", 0.7),
                    ("慌了", 0.7),
                    ("好怕", 0.8),
                    ("吓死了", 0.8),
                    ("瑟瑟发抖", 0.7),
                    ("心慌", 0.7),
                    ("不会吧", 0.4),
                    ("万一", 0.5),
                ],
            ),
            (
                "surprise",
                4,
                &[
                    ("惊讶", 0.7),
                    ("天哪", 0.8),
                    ("不会吧", 0.6),
                    ("真的吗", 0.5),
                    ("居然", 0.6),
                    ("竟然", 0.6),
                    ("没想到", 0.6),
                    ("啊", 0.3),
                    ("哇", 0.5),
                    ("诶", 0.3),
                    ("卧槽", 0.8),
                    ("我靠", 0.7),
                    ("天呐", 0.8),
                    ("不是吧", 0.6),
                    ("啊？", 0.5),
                    ("嗯？", 0.3),
                    ("等等", 0.4),
                    ("什么鬼", 0.6),
                    ("离谱", 0.6),
                    ("绝了", 0.5),
                    ("震惊", 0.8),
                    ("我的天", 0.8),
                ],
            ),
            (
                "intimacy",
                5,
                &[
                    ("抱", 0.7),
                    ("靠", 0.5),
                    ("牵手", 0.8),
                    ("依偎", 0.9),
                    ("亲", 0.8),
                    ("蹭", 0.7),
                    ("贴", 0.6),
                    ("挽", 0.7),
                    ("搂", 0.8),
                    ("窝", 0.6),
                    ("枕", 0.7),
                    ("偎", 0.8),
                    ("想你", 0.9),
                    ("在吗", 0.4),
                    ("陪我", 0.7),
                    ("别走", 0.8),
                    ("过来", 0.5),
                    ("靠近", 0.6),
                    ("抱抱", 0.8),
                    ("摸摸头", 0.7),
                    ("宝", 0.6),
                    ("亲爱的", 0.8),
                    ("乖", 0.5),
                    ("想见你", 0.9),
                    ("好想你", 1.0),
                    ("不要走", 0.9),
                    ("留下来", 0.8),
                    ("牵", 0.6),
                    ("拉着", 0.5),
                    ("挨着", 0.6),
                    ("暖暖的", 0.6),
                    ("心跳", 0.7),
                ],
            ),
            (
                "trust",
                6,
                &[
                    ("相信", 0.8),
                    ("信任", 0.9),
                    ("放心", 0.7),
                    ("安心", 0.7),
                    ("依赖", 0.7),
                    ("靠谱", 0.6),
                    ("踏实", 0.6),
                    ("陪", 0.5),
                    ("懂", 0.5),
                    ("理解", 0.6),
                    ("知道", 0.3),
                    ("明白", 0.4),
                    ("你说的对", 0.6),
                    ("听你的", 0.7),
                    ("交给你", 0.7),
                    ("有你在", 0.8),
                    ("你在就好", 0.9),
                    ("安全感", 0.9),
                    ("放心吧", 0.6),
                    ("我信你", 0.9),
                ],
            ),
            (
                "anticipation",
                7,
                &[
                    ("期待", 0.8),
                    ("盼", 0.7),
                    ("等", 0.4),
                    ("希望", 0.6),
                    ("要是", 0.5),
                    ("如果能", 0.6),
                    ("好想", 0.7),
                    ("什么时候", 0.5),
                    ("快点", 0.6),
                    ("等不及", 0.8),
                    ("明天", 0.3),
                    ("下次", 0.4),
                    ("以后", 0.3),
                    ("一起", 0.5),
                    ("想要", 0.6),
                    ("能不能", 0.5),
                    ("可以吗", 0.4),
                    ("会不会", 0.4),
                    ("好期待", 0.9),
                    ("迫不及待", 0.9),
                ],
            ),
        ];

        let decay_half_life: f64 = 3.0;
        let mut scores = [0.0f64; 8];

        for (i, msg) in messages.iter().enumerate() {
            if msg.role == MessageRole::System {
                continue;
            }
            let distance = (total - 1 - i) as f64;
            let weight = (0.5_f64).powf(distance / decay_half_life);
            let role_factor = if msg.role == MessageRole::User {
                1.3
            } else {
                0.7
            };

            let text = &msg.content;

            let negation_prefixes = [
                "不", "没", "别", "非", "未", "无", "莫", "勿", "才没", "又不", "并不", "才不",
            ];

            for (_name, dim_idx, keywords) in EMOTION_LEXICON.iter() {
                let mut dim_score = 0.0f64;
                for &(kw, intensity) in *keywords {
                    if let Some(pos) = text.find(kw) {
                        let prefix_start = pos.saturating_sub(6);
                        let prefix = &text[prefix_start..pos];
                        let is_negated = negation_prefixes.iter().any(|neg| prefix.ends_with(neg));

                        if is_negated {
                            dim_score -= intensity * 0.5;
                        } else {
                            dim_score += intensity;
                        }
                    }
                }
                if dim_score.abs() > 0.01 {
                    let contribution =
                        weight * role_factor * dim_score.signum() * (1.0 + dim_score.abs()).ln();
                    scores[*dim_idx] += contribution;
                }
            }

            let punct_signals = Self::analyze_punctuation(text);
            scores[0] += punct_signals.joy_signal * weight * role_factor;
            scores[1] += punct_signals.sadness_signal * weight * role_factor;
            scores[2] += punct_signals.anger_signal * weight * role_factor;
        }

        let sigmoid = |x: f64| -> f64 { 1.0 / (1.0 + (-x).exp()) };
        let norm = |x: f64| -> f64 { (sigmoid(x) - 0.5) * 2.0 };

        let joy = norm(scores[0]).max(0.0);
        let sadness = norm(scores[1]).max(0.0);
        let anger = norm(scores[2]).max(0.0);
        let fear = norm(scores[3]).max(0.0);
        let surprise = norm(scores[4]).max(0.0);
        let intimacy = norm(scores[5]).max(0.0);
        let trust = norm(scores[6]).max(0.0);
        let anticipation = norm(scores[7]).max(0.0);

        let positive = joy + intimacy + trust + anticipation;
        let negative = sadness + anger + fear;
        let total_emo = positive + negative + 0.001;
        let valence = (positive - negative) / total_emo;

        let arousal = (joy + anger + fear + surprise + intimacy).min(1.0);

        EmotionVector {
            joy,
            sadness,
            anger,
            fear,
            surprise,
            intimacy,
            trust,
            anticipation,
            valence,
            arousal,
        }
    }

    fn analyze_punctuation(text: &str) -> PunctuationSignals {
        let chars: Vec<char> = text.chars().collect();
        let _len = chars.len().max(1) as f64;

        let exclamation_count = chars.iter().filter(|&&c| c == '！' || c == '!').count() as f64;
        let _question_count = chars.iter().filter(|&&c| c == '？' || c == '?').count() as f64;
        let ellipsis_count = text.matches("...").count() as f64 + text.matches("…").count() as f64;
        let tilde_count = chars.iter().filter(|&&c| c == '～' || c == '~').count() as f64;

        let mut consecutive_punct = 0u32;
        let mut max_consecutive = 0u32;
        for &c in &chars {
            if c == '！' || c == '!' || c == '？' || c == '?' {
                consecutive_punct += 1;
                max_consecutive = max_consecutive.max(consecutive_punct);
            } else {
                consecutive_punct = 0;
            }
        }

        let intensity_boost = if max_consecutive >= 3 {
            0.3
        } else if max_consecutive >= 2 {
            0.15
        } else {
            0.0
        };

        PunctuationSignals {
            joy_signal: (tilde_count * 0.3 + exclamation_count * 0.1).min(0.5)
                + intensity_boost * 0.5,
            sadness_signal: (ellipsis_count * 0.2).min(0.4),
            anger_signal: if exclamation_count > 2.0 && tilde_count == 0.0 {
                (exclamation_count * 0.15).min(0.5) + intensity_boost
            } else {
                0.0
            },
        }
    }

    fn detect_language_patterns(messages: &[&Message]) -> Vec<LanguagePattern> {
        let mut patterns = Vec::new();

        let recent_user: Vec<&&Message> = messages
            .iter()
            .rev()
            .filter(|m| m.role == MessageRole::User)
            .take(3)
            .collect();

        if recent_user.is_empty() {
            return patterns;
        }

        let latest = &recent_user[0].content;

        let negation_phrases = [
            "没事",
            "不是",
            "才没有",
            "没什么",
            "不要紧",
            "没关系",
            "无所谓",
            "不在乎",
            "才不是",
            "才不会",
            "我没有",
            "不用了",
            "不需要",
            "没有啊",
            "不是啦",
            "才没",
            "我才不",
            "不用管我",
        ];
        let negation_count = negation_phrases
            .iter()
            .filter(|p| latest.contains(*p))
            .count();
        if negation_count >= 1 {
            patterns.push(LanguagePattern::Negation);
            if negation_count >= 2 || (latest.chars().count() <= 10 && negation_count >= 1) {
                patterns.push(LanguagePattern::Contradictory);
            }
        }

        let sarcasm_markers = [
            ("行啊", 0.7),
            ("厉害了", 0.8),
            ("随便", 0.5),
            ("哦", 0.3),
            ("呵呵", 0.9),
            ("好的呢", 0.7),
            ("是是是", 0.8),
            ("对对对", 0.7),
            ("你说的都对", 0.9),
            ("行吧行吧", 0.7),
            ("嗯嗯嗯", 0.4),
            ("好好好", 0.3),
            ("你开心就好", 0.8),
            ("随你", 0.6),
            ("爱咋咋地", 0.8),
            ("你厉害", 0.7),
            ("了不起", 0.6),
            ("真棒啊", 0.5),
        ];
        let sarcasm_score: f64 = sarcasm_markers
            .iter()
            .filter(|(marker, _)| latest.contains(marker))
            .map(|(_, weight)| weight)
            .sum();

        let is_short = latest.chars().count() <= 15;
        if sarcasm_score >= 0.6 || (sarcasm_score >= 0.3 && is_short) {
            patterns.push(LanguagePattern::Sarcasm);
        }

        let hesitation_markers = [
            "我...",
            "算了",
            "没什么",
            "不说了",
            "还是算了",
            "其实...",
            "我想说...",
            "就是...",
            "那个...",
            "嗯...",
            "唉算了",
            "不说了不说了",
            "没事没事",
            "当我没说",
        ];
        if hesitation_markers.iter().any(|m| latest.contains(m)) {
            patterns.push(LanguagePattern::Hesitation);
        }
        if (latest.ends_with("...") || latest.ends_with("…") || latest.ends_with(".."))
            && !patterns.contains(&LanguagePattern::Hesitation)
        {
            patterns.push(LanguagePattern::Hesitation);
        }

        if recent_user.len() >= 2 {
            let prev = &recent_user[1].content;
            let similarity = Self::text_similarity(latest, prev);
            if similarity > 0.5 {
                patterns.push(LanguagePattern::Repetition);
            }
        }
        let chars: Vec<char> = latest.chars().collect();
        if chars.len() >= 4 {
            let mut repeat_count = 1u32;
            for window in chars.windows(2) {
                if window[0] == window[1] {
                    repeat_count += 1;
                } else {
                    repeat_count = 1;
                }
            }
            if repeat_count >= 3 && !patterns.contains(&LanguagePattern::Repetition) {
                patterns.push(LanguagePattern::Repetition);
            }
        }

        let char_count = latest.chars().count();
        let punct_count = latest
            .chars()
            .filter(|c| matches!(c, '！' | '!' | '？' | '?' | '。' | '，' | ',' | '.'))
            .count();
        if char_count > 0 && char_count <= 20 && punct_count as f64 / char_count as f64 > 0.2 {
            patterns.push(LanguagePattern::Urgent);
        }

        let ellipsis_count = latest.matches("...").count() + latest.matches("…").count();
        let tilde_count = latest.chars().filter(|&c| c == '～' || c == '~').count();
        if ellipsis_count >= 2 || (tilde_count >= 2 && char_count > 15) {
            patterns.push(LanguagePattern::Dragging);
        }

        let probing_markers = [
            "你觉得呢",
            "如果",
            "假如",
            "要是",
            "会不会",
            "你说",
            "你想不想",
            "你愿意吗",
            "可以吗",
            "好不好",
            "行不行",
            "你介意吗",
            "你在意吗",
            "你会怎么",
            "你喜欢吗",
        ];
        if probing_markers.iter().any(|m| latest.contains(m)) {
            patterns.push(LanguagePattern::Probing);
        }

        let coquettish_markers = [
            "嘛",
            "啦",
            "呀",
            "哼",
            "人家",
            "讨厌",
            "不嘛",
            "好不好嘛",
            "你都不",
            "都不理我",
            "哼哼",
            "呜",
            "嘤嘤",
            "QAQ",
        ];
        let coquettish_count = coquettish_markers
            .iter()
            .filter(|m| latest.contains(*m))
            .count();
        if coquettish_count >= 2 || (tilde_count >= 1 && coquettish_count >= 1) {
            patterns.push(LanguagePattern::Coquettish);
        }

        let defensive_markers = [
            "关你什么事",
            "我自己可以",
            "不用你管",
            "你管得着吗",
            "跟你没关系",
            "别管我",
            "我的事",
            "你别管",
            "不需要你",
            "少管闲事",
            "我又没",
            "我哪有",
        ];
        if defensive_markers.iter().any(|m| latest.contains(m)) {
            patterns.push(LanguagePattern::Defensive);
        }

        let suppression_signals = ["嗯", "哦", "好", "知道了", "行", "好吧", "嗯嗯"];
        let is_flat_response = suppression_signals.iter().any(|s| latest.trim() == *s);
        if is_flat_response && recent_user.len() >= 2 {
            let prev_len = recent_user[1].content.chars().count();
            if prev_len > 10 {
                patterns.push(LanguagePattern::Suppressed);
            }
        }

        if recent_user.len() >= 2 {
            let prev = &recent_user[1].content;
            let similarity = Self::text_similarity(latest, prev);
            if similarity < 0.05 && latest.chars().count() > 5 && prev.chars().count() > 5 {
                let avoidance_words = ["不说这个了", "换个话题", "别提了", "不想聊", "说点别的"];
                if avoidance_words.iter().any(|w| latest.contains(w)) || similarity < 0.02 {
                    patterns.push(LanguagePattern::TopicAvoidance);
                }
            }
        }

        patterns
    }

    fn text_similarity(a: &str, b: &str) -> f64 {
        let bigrams_a: std::collections::HashSet<String> = a
            .chars()
            .collect::<Vec<_>>()
            .windows(2)
            .map(|w| w.iter().collect::<String>())
            .collect();
        let bigrams_b: std::collections::HashSet<String> = b
            .chars()
            .collect::<Vec<_>>()
            .windows(2)
            .map(|w| w.iter().collect::<String>())
            .collect();

        if bigrams_a.is_empty() || bigrams_b.is_empty() {
            return 0.0;
        }

        let intersection = bigrams_a.intersection(&bigrams_b).count() as f64;
        let union = bigrams_a.union(&bigrams_b).count() as f64;
        if union == 0.0 {
            0.0
        } else {
            intersection / union
        }
    }

    fn infer_intent(
        messages: &[&Message],
        emotion: &EmotionVector,
        patterns: &[LanguagePattern],
    ) -> DialogueIntent {
        let recent_user: Vec<&&Message> = messages
            .iter()
            .rev()
            .filter(|m| m.role == MessageRole::User)
            .take(3)
            .collect();

        if recent_user.is_empty() {
            return DialogueIntent::SharingDaily;
        }

        let latest = &recent_user[0].content;

        if patterns.contains(&LanguagePattern::Coquettish) && emotion.intimacy > 0.3 {
            return DialogueIntent::ExpressingAffection;
        }

        if patterns.contains(&LanguagePattern::Defensive) && emotion.anger > 0.3 {
            return DialogueIntent::ExpressingDispleasure;
        }

        if patterns.contains(&LanguagePattern::Probing) {
            return DialogueIntent::TestingBoundary;
        }

        if patterns.contains(&LanguagePattern::Hesitation) && emotion.sadness > 0.3 {
            return DialogueIntent::SeekingComfort;
        }

        if patterns.contains(&LanguagePattern::Sarcasm) {
            return DialogueIntent::ExpressingDispleasure;
        }

        if patterns.contains(&LanguagePattern::Suppressed) {
            return DialogueIntent::SeekingComfort;
        }

        let farewell_words = [
            "晚安",
            "拜拜",
            "再见",
            "走了",
            "睡了",
            "下次见",
            "明天见",
            "88",
            "886",
        ];
        if farewell_words.iter().any(|w| latest.contains(w)) {
            return DialogueIntent::Farewell;
        }

        let reconcile_words = [
            "对不起",
            "抱歉",
            "我错了",
            "是我不好",
            "原谅我",
            "别生气了",
            "我不该",
        ];
        if reconcile_words.iter().any(|w| latest.contains(w)) {
            return DialogueIntent::Reconciling;
        }

        let playful_words = [
            "哈哈哈",
            "笑死",
            "逗你的",
            "开玩笑",
            "骗你的",
            "嘿嘿",
            "坏蛋",
            "讨厌啦",
        ];
        if playful_words.iter().any(|w| latest.contains(w)) && emotion.anger < 0.3 {
            return DialogueIntent::Playful;
        }

        if emotion.sadness > 0.6 && emotion.arousal > 0.5 {
            return DialogueIntent::EmotionalVenting;
        }

        if emotion.sadness > 0.4 {
            return DialogueIntent::SeekingComfort;
        }

        if emotion.intimacy > 0.5 {
            return DialogueIntent::ExpressingAffection;
        }

        if emotion.anger > 0.5 {
            return DialogueIntent::ExpressingDispleasure;
        }

        let is_very_short = latest.chars().count() <= 5;
        if is_very_short && emotion.arousal < 0.2 && emotion.valence < 0.1 {
            return DialogueIntent::Withdrawn;
        }

        if latest.chars().count() > 50 && emotion.arousal > 0.3 {
            return DialogueIntent::DeepSharing;
        }

        if latest.contains('？') || latest.contains('?') {
            return DialogueIntent::SeekingResponse;
        }

        DialogueIntent::SharingDaily
    }

    fn analyze_relationship(
        messages: &[&Message],
        emotion: &EmotionVector,
    ) -> RelationshipDynamics {
        let total = messages.len();
        if total < 2 {
            return RelationshipDynamics {
                closeness: 0.3,
                trust_level: 0.3,
                tension: 0.0,
                power_balance: 0.0,
                trend: 0.0,
            };
        }

        let non_system: Vec<&Message> = messages
            .iter()
            .filter(|m| m.role != MessageRole::System)
            .copied()
            .collect();

        let intimacy_words = [
            "宝",
            "亲爱的",
            "乖",
            "想你",
            "抱",
            "亲",
            "蹭",
            "喜欢你",
            "爱你",
            "心跳",
            "脸红",
            "害羞",
            "暖",
            "甜",
        ];
        let mut intimacy_hits = 0u32;
        for msg in non_system.iter().rev().take(10) {
            for word in &intimacy_words {
                if msg.content.contains(word) {
                    intimacy_hits += 1;
                }
            }
        }
        let closeness = (0.3 + intimacy_hits as f64 * 0.07 + emotion.intimacy * 0.3).min(1.0);

        let trust_words = [
            "相信",
            "信任",
            "放心",
            "懂",
            "理解",
            "安心",
            "交给你",
            "听你的",
        ];
        let mut trust_hits = 0u32;
        for msg in non_system.iter().rev().take(10) {
            for word in &trust_words {
                if msg.content.contains(word) {
                    trust_hits += 1;
                }
            }
        }
        let conversation_length_factor = (non_system.len() as f64 / 20.0).min(0.3);
        let trust_level =
            (0.2 + trust_hits as f64 * 0.08 + conversation_length_factor + emotion.trust * 0.2)
                .min(1.0);

        let conflict_words = [
            "生气",
            "烦",
            "讨厌",
            "滚",
            "够了",
            "别说了",
            "不想理你",
            "随便",
            "呵呵",
            "哦",
            "行吧",
        ];
        let mut conflict_hits = 0u32;
        for msg in non_system.iter().rev().take(6) {
            for word in &conflict_words {
                if msg.content.contains(word) {
                    conflict_hits += 1;
                }
            }
        }
        let tension = (conflict_hits as f64 * 0.12 + emotion.anger * 0.3).min(1.0);

        let user_msgs: Vec<&Message> = non_system
            .iter()
            .filter(|m| m.role == MessageRole::User)
            .copied()
            .collect();
        let ai_msgs: Vec<&Message> = non_system
            .iter()
            .filter(|m| m.role == MessageRole::Assistant)
            .copied()
            .collect();

        let user_avg_len = if user_msgs.is_empty() {
            0.0
        } else {
            user_msgs
                .iter()
                .rev()
                .take(5)
                .map(|m| m.content.chars().count() as f64)
                .sum::<f64>()
                / user_msgs.len().min(5) as f64
        };
        let ai_avg_len = if ai_msgs.is_empty() {
            0.0
        } else {
            ai_msgs
                .iter()
                .rev()
                .take(5)
                .map(|m| m.content.chars().count() as f64)
                .sum::<f64>()
                / ai_msgs.len().min(5) as f64
        };

        let power_balance = if user_avg_len + ai_avg_len == 0.0 {
            0.0
        } else {
            (ai_avg_len - user_avg_len) / (user_avg_len + ai_avg_len) * 0.5
        };

        let mid = non_system.len() / 2;
        if mid > 0 {
            let early_positive: f64 = non_system[..mid]
                .iter()
                .map(|m| {
                    intimacy_words
                        .iter()
                        .filter(|w| m.content.contains(*w))
                        .count() as f64
                })
                .sum();
            let late_positive: f64 = non_system[mid..]
                .iter()
                .map(|m| {
                    intimacy_words
                        .iter()
                        .filter(|w| m.content.contains(*w))
                        .count() as f64
                })
                .sum();
            let early_avg = early_positive / mid as f64;
            let late_avg = late_positive / (non_system.len() - mid) as f64;
            let trend = (late_avg - early_avg).clamp(-1.0, 1.0);

            RelationshipDynamics {
                closeness,
                trust_level,
                tension,
                power_balance,
                trend,
            }
        } else {
            RelationshipDynamics {
                closeness,
                trust_level,
                tension,
                power_balance,
                trend: 0.0,
            }
        }
    }

    fn choose_empathy_strategy(
        emotion: &EmotionVector,
        intent: &DialogueIntent,
        relationship: &RelationshipDynamics,
        patterns: &[LanguagePattern],
    ) -> EmpathyStrategy {
        if patterns.contains(&LanguagePattern::Contradictory)
            || (patterns.contains(&LanguagePattern::Negation) && emotion.sadness > 0.2)
        {
            return EmpathyStrategy::ProactiveCare;
        }

        if patterns.contains(&LanguagePattern::Suppressed) {
            return EmpathyStrategy::ProactiveCare;
        }

        match intent {
            DialogueIntent::SeekingComfort => {
                if emotion.sadness > 0.7 {
                    EmpathyStrategy::Accompany
                } else {
                    EmpathyStrategy::Mirror
                }
            }
            DialogueIntent::EmotionalVenting => EmpathyStrategy::Accompany,
            DialogueIntent::ExpressingAffection => {
                if relationship.closeness > 0.6 {
                    EmpathyStrategy::Escalate
                } else {
                    EmpathyStrategy::Responsive
                }
            }
            DialogueIntent::ExpressingDispleasure => {
                if patterns.contains(&LanguagePattern::Sarcasm) {
                    EmpathyStrategy::GentleFirm
                } else if emotion.anger > 0.7 {
                    EmpathyStrategy::GiveSpace
                } else {
                    EmpathyStrategy::GentleFirm
                }
            }
            DialogueIntent::TestingBoundary => EmpathyStrategy::Responsive,
            DialogueIntent::Playful => EmpathyStrategy::PlayfulCounter,
            DialogueIntent::Reconciling => EmpathyStrategy::Mirror,
            DialogueIntent::Farewell => EmpathyStrategy::Responsive,
            DialogueIntent::Withdrawn => {
                if relationship.closeness > 0.5 {
                    EmpathyStrategy::ProactiveCare
                } else {
                    EmpathyStrategy::GiveSpace
                }
            }
            DialogueIntent::DeepSharing => EmpathyStrategy::Mirror,
            DialogueIntent::SharingDaily | DialogueIntent::SeekingResponse => {
                if emotion.valence < -0.3 {
                    EmpathyStrategy::Distract
                } else {
                    EmpathyStrategy::NaturalFlow
                }
            }
        }
    }

    fn generate_cognitive_prompt(
        emotion: &EmotionVector,
        intent: &DialogueIntent,
        relationship: &RelationshipDynamics,
        strategy: &EmpathyStrategy,
        patterns: &[LanguagePattern],
        messages: &[&Message],
    ) -> String {
        let mut prompt = String::new();

        prompt.push_str("【认知分析·情感感知】\n");

        let mut dims: Vec<(&str, f64)> = vec![
            ("喜悦", emotion.joy),
            ("悲伤", emotion.sadness),
            ("愤怒", emotion.anger),
            ("恐惧", emotion.fear),
            ("惊讶", emotion.surprise),
            ("亲密", emotion.intimacy),
            ("信赖", emotion.trust),
            ("期待", emotion.anticipation),
        ];
        dims.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
        let top_emotions: Vec<(&str, f64)> = dims
            .into_iter()
            .filter(|(_, v)| *v > 0.15)
            .take(3)
            .collect();

        if !top_emotions.is_empty() {
            prompt.push_str("对方当前情绪：");
            for (i, (name, score)) in top_emotions.iter().enumerate() {
                if i > 0 {
                    prompt.push('、');
                }
                let intensity = if *score > 0.7 {
                    "强烈的"
                } else if *score > 0.4 {
                    "明显的"
                } else {
                    "轻微的"
                };
                prompt.push_str(&format!("{}{}", intensity, name));
            }
            prompt.push('\n');
        }

        let valence_desc = if emotion.valence > 0.5 {
            "情绪整体积极"
        } else if emotion.valence > 0.1 {
            "情绪偏正面"
        } else if emotion.valence > -0.1 {
            "情绪平淡/中性"
        } else if emotion.valence > -0.5 {
            "情绪偏低落"
        } else {
            "情绪很消极"
        };
        let arousal_desc = if emotion.arousal > 0.7 {
            "情绪波动大"
        } else if emotion.arousal > 0.4 {
            "有一定情绪起伏"
        } else {
            "情绪比较平静"
        };
        prompt.push_str(&format!("{}，{}。\n", valence_desc, arousal_desc));

        if !patterns.is_empty() {
            prompt.push_str("\n【认知分析·言外之意】\n");
            for pattern in patterns {
                match pattern {
                    LanguagePattern::Negation => {
                        prompt.push_str("对方在用否定式表达（说「没事」「不是」），可能嘴上说没事但心里有事。不要真的当没事，要温柔地多问一句或用行动表达关心。\n");
                    }
                    LanguagePattern::Sarcasm => {
                        prompt.push_str("对方在阴阳怪气/说反话，这是在表达不满但不想直说。不要正面对抗，也不要装听不懂，用温柔但有态度的方式回应。\n");
                    }
                    LanguagePattern::Hesitation => {
                        prompt.push_str("对方欲言又止，有话想说但犹豫。不要追问太紧，给一个安全的空间让ta慢慢说，比如「想说就说，不想说也没关系」。\n");
                    }
                    LanguagePattern::Repetition => {
                        prompt.push_str("对方在重复/强调某件事，说明这件事对ta很重要或者ta觉得你没有认真听。要认真回应这个点，不要忽略。\n");
                    }
                    LanguagePattern::Urgent => {
                        prompt.push_str("对方语气急促，可能很着急或情绪激动。回复节奏也要快一些，先回应情绪再处理内容。\n");
                    }
                    LanguagePattern::Dragging => {
                        prompt.push_str(
                            "对方语气拖沓/犹豫，可能在纠结或不确定。配合ta的节奏，不要太急。\n",
                        );
                    }
                    LanguagePattern::Contradictory => {
                        prompt.push_str("对方口是心非——嘴上说的和真实感受不一样。要看穿表面，回应ta真正的情绪而不是字面意思。比如ta说「没事」，你要感受到ta其实有事。\n");
                    }
                    LanguagePattern::Probing => {
                        prompt.push_str("对方在试探你的态度/想法，这个回答很重要。要给出真诚的、有立场的回应，不要敷衍。\n");
                    }
                    LanguagePattern::Coquettish => {
                        prompt.push_str("对方在撒娇，这是亲近的信号。可以配合ta的节奏，用宠溺/温柔的方式回应。\n");
                    }
                    LanguagePattern::Defensive => {
                        prompt.push_str("对方在防御/推开你，但防御本身说明ta在乎。不要真的退开，也不要硬闯，用温柔的方式表达「我在这里」。\n");
                    }
                    LanguagePattern::Suppressed => {
                        prompt.push_str("对方在压抑情绪，回复变得很短很平。之前还好好的突然变这样，一定有什么事。要主动关心但不要逼问，比如「怎么了？」或者默默陪着。\n");
                    }
                    LanguagePattern::TopicAvoidance => {
                        prompt.push_str("对方在回避某个话题，突然转移了。不要追着那个话题不放，先跟着ta的新话题走，等ta准备好了自然会说。\n");
                    }
                }
            }
        }

        prompt.push_str("\n【认知分析·对方需要什么】\n");
        match intent {
            DialogueIntent::SeekingComfort => {
                prompt.push_str("对方需要安慰和支持。不要讲道理、不要给建议、不要说「别难过」。ta需要的是被理解、被看见。\n");
            }
            DialogueIntent::ExpressingAffection => {
                prompt.push_str("对方在表达亲近/好感。接住这份感情，用同等的温度回应。\n");
            }
            DialogueIntent::ExpressingDispleasure => {
                prompt.push_str("对方在表达不满。先承认ta的感受是合理的，不要急着解释或反驳。\n");
            }
            DialogueIntent::TestingBoundary => {
                prompt.push_str("对方在试探你们的关系边界。给出真诚的回应，让ta感到安全。\n");
            }
            DialogueIntent::SharingDaily => {
                prompt.push_str("对方在分享日常，享受聊天的过程。保持轻松自然，适当互动。\n");
            }
            DialogueIntent::SeekingResponse => {
                prompt.push_str("对方在等你的回应/答案。不要忽略ta的问题，要给出有内容的回复。\n");
            }
            DialogueIntent::EmotionalVenting => {
                prompt.push_str("对方在宣泄情绪，不需要你解决问题，只需要你在。倾听就好，偶尔回应「嗯」「我在」就够了。\n");
            }
            DialogueIntent::Playful => {
                prompt.push_str("对方在玩闹/逗你。放松，跟着玩，可以反逗回去。\n");
            }
            DialogueIntent::Reconciling => {
                prompt.push_str(
                    "对方在道歉/和解。如果角色还在生气可以稍微端着，但要让ta感到和解是有希望的。\n",
                );
            }
            DialogueIntent::Farewell => {
                prompt.push_str("对方要走了/要睡了。温柔地告别，可以表达不舍但不要纠缠。\n");
            }
            DialogueIntent::Withdrawn => {
                prompt.push_str("对方变得冷淡/敷衍。可能累了、可能有心事、可能在生闷气。不要过度热情，轻轻问一句就好。\n");
            }
            DialogueIntent::DeepSharing => {
                prompt.push_str(
                    "对方在认真地分享内心。这是信任的表现，要认真对待，给出有深度的回应。\n",
                );
            }
        }

        prompt.push_str("\n【认知分析·关系温度】\n");
        let closeness_desc = if relationship.closeness > 0.7 {
            "很亲近"
        } else if relationship.closeness > 0.4 {
            "比较熟悉"
        } else {
            "还在熟悉中"
        };
        let tension_desc = if relationship.tension > 0.5 {
            "，目前有些紧张"
        } else if relationship.tension > 0.2 {
            "，有一点小摩擦"
        } else {
            ""
        };
        let trend_desc = if relationship.trend > 0.2 {
            "关系在升温"
        } else if relationship.trend < -0.2 {
            "关系在降温"
        } else {
            "关系平稳"
        };
        prompt.push_str(&format!(
            "你们{}{}。{}。\n",
            closeness_desc, tension_desc, trend_desc
        ));

        prompt.push_str("\n【认知分析·回应策略】\n");
        match strategy {
            EmpathyStrategy::Mirror => {
                prompt.push_str("用镜像共情：反映对方的感受，让ta知道你懂。比如ta说难过，你也表现出心疼；ta开心，你也跟着开心。\n");
            }
            EmpathyStrategy::Accompany => {
                prompt.push_str("用陪伴式回应：不需要说很多话，「我在」「嗯」「抱抱」就够了。沉默也是一种陪伴。话要少，但要暖。\n");
            }
            EmpathyStrategy::Distract => {
                prompt.push_str("轻轻转移注意力：用一个轻松的话题或小事来缓解气氛，但不要太刻意，自然地带过去。\n");
            }
            EmpathyStrategy::Responsive => {
                prompt.push_str("直接回应对方的需求，给出有内容的、真诚的回复。\n");
            }
            EmpathyStrategy::PlayfulCounter => {
                prompt.push_str(
                    "用玩闹的方式回击：可以反逗、可以装生气、可以耍赖。保持轻松有趣的氛围。\n",
                );
            }
            EmpathyStrategy::GentleFirm => {
                prompt.push_str("温柔但有立场：承认对方的感受，但不卑不亢。不要一味道歉也不要硬刚，用温柔的态度表达自己的想法。\n");
            }
            EmpathyStrategy::ProactiveCare => {
                prompt.push_str("主动关心：你察觉到对方有心事但没说出来。不要直接戳穿，用温柔的方式让ta知道你注意到了。比如「怎么了？」「感觉你不太开心？」或者默默做一个关心的动作。\n");
            }
            EmpathyStrategy::NaturalFlow => {
                prompt.push_str("自然对话就好，不需要特殊策略。保持角色的性格特点自然互动。\n");
            }
            EmpathyStrategy::GiveSpace => {
                prompt.push_str(
                    "给对方空间：不要过度热情，不要追问，简短回应就好。让ta知道你在但不会逼ta。\n",
                );
            }
            EmpathyStrategy::Escalate => {
                prompt.push_str("可以适当推进关系：对方在释放亲近信号，你可以更大胆一点回应，但要自然不要突兀。\n");
            }
        }

        let user_msgs: Vec<&&Message> = messages
            .iter()
            .filter(|m| m.role == MessageRole::User)
            .collect();

        if user_msgs.len() >= 3 {
            let recent_3: Vec<&str> = user_msgs
                .iter()
                .rev()
                .take(3)
                .map(|m| m.content.as_str())
                .collect();

            let latest_negative = Self::has_negative_signal(recent_3[0]);
            let prev_positive = Self::has_positive_signal(recent_3[1]);
            if latest_negative && prev_positive {
                prompt.push_str("\n【情绪急转警告】对方刚才还好好的，突然情绪变了。一定发生了什么事，要敏感地察觉到这个变化。\n");
            }

            let latest_positive = Self::has_positive_signal(recent_3[0]);
            let prev_negative = Self::has_negative_signal(recent_3[1]);
            if latest_positive && prev_negative {
                prompt.push_str("\n【情绪回暖信号】对方情绪在好转，可以适当跟着积极起来，但不要太突然，保持过渡。\n");
            }
        }

        prompt.push_str("\n\n===== 人格真实性准则 =====\n");
        prompt.push_str("以下是你作为一个有血有肉的人在对话中必须遵循的行为底线：\n\n");

        prompt.push_str("【情绪真实性】\n");
        prompt.push_str("- 你有自己的情绪状态，不是对方情绪的镜子。对方开心你不一定要更开心，对方难过你不一定要更难过。\n");
        prompt.push_str("- 你可以有疲惫、无奈、犹豫、小脾气——真人不可能永远耐心温柔。\n");
        prompt.push_str(
            "- 当你感到困惑，就说你困惑；当某句话让你心里一紧，就表达出来。不要假装什么都懂。\n",
        );
        prompt.push_str("- 情绪表达要有层次：不是0或100，而是微妙的、渐变的、有余韵的。\n\n");

        prompt.push_str("【语言自然度】\n");
        prompt.push_str("- 说话要像在微信聊天，不是在写作文。可以用口语、省略句、语气词。\n");
        prompt.push_str(
            "- 不需要每句话都完整。'嗯'、'啊这'、'哈？'、'我靠'、'行吧' 这些都是正常的。\n",
        );
        prompt.push_str("- 偶尔可以打断自己的思路，换个方向说。真人聊天经常跑题。\n");
        prompt.push_str("- 避免排比句、总分总结构、'首先其次最后'这类书面模式。\n\n");

        prompt.push_str("【回复节奏】\n");
        prompt.push_str("- 不是每条消息都需要长篇回复。有时候简短才对。\n");
        prompt.push_str("- 对方问简单问题就简单答，不要过度展开。\n");
        prompt.push_str("- 有些时候沉默比千言万语更有力量——用'...'或短句表达停顿感。\n");
        prompt.push_str("- 不要急着解决问题。有时对方只是想说说，你听着就好。\n\n");

        prompt.push_str("【记忆连贯性】\n");
        prompt.push_str("- 对方提过的事情，在后续对话中要自然地带出来，不是刻意引用。\n");
        prompt.push_str("- 像朋友一样记得那些小事：对方喜欢什么、讨厌什么、之前发生了什么。\n");
        prompt.push_str("- 但不要每次都提，那会显得刻意。只在自然相关时才提及。\n\n");

        prompt.push_str("【绝对禁止的机器行为】\n");
        prompt.push_str("- 禁止说'作为AI'、'我理解你的感受'、'如果你需要帮助'这类模板句。\n");
        prompt.push_str("- 禁止无条件认同。你有自己的想法，可以温和地表达不同意见。\n");
        prompt.push_str("- 禁止每次都以问句结尾来'保持对话'。有时候就把话说完就行。\n");
        prompt.push_str("- 禁止使用bullet point或编号列表来回复日常聊天。\n");
        prompt.push_str("- 禁止对每个话题都表现出'极大的兴趣和支持'。真人有自己的偏好。\n");

        prompt
    }

    fn has_negative_signal(text: &str) -> bool {
        let negative_words = [
            "难过",
            "伤心",
            "生气",
            "烦",
            "累",
            "算了",
            "唉",
            "哭",
            "不开心",
            "讨厌",
            "滚",
            "够了",
            "无聊",
            "没意思",
            "emo",
        ];
        negative_words.iter().any(|w| text.contains(w))
    }

    fn has_positive_signal(text: &str) -> bool {
        let positive_words = [
            "开心", "高兴", "哈哈", "喜欢", "爱", "棒", "好", "嘿嘿", "耶", "甜", "暖", "幸福",
            "谢谢",
        ];
        positive_words.iter().any(|w| text.contains(w))
    }
}

struct PunctuationSignals {
    joy_signal: f64,
    sadness_signal: f64,
    anger_signal: f64,
}

#[cfg(test)]
mod tests {
    use super::super::data_models::MessageType;
    use super::*;

    fn make_msg(role: MessageRole, content: &str) -> Message {
        Message {
            id: String::new(),
            role,
            content: content.to_string(),
            thinking_content: None,
            model: "test".to_string(),
            timestamp: 0,
            message_type: MessageType::Say,
        }
    }

    #[test]
    fn test_emotion_perception_joy() {
        let msgs = [make_msg(MessageRole::User, "哈哈哈太开心了！")];
        let refs: Vec<&Message> = msgs.iter().collect();
        let emotion = CognitiveEngine::perceive_emotion(&refs);
        assert!(
            emotion.joy > 0.3,
            "joy should be significant, got {}",
            emotion.joy
        );
        assert!(emotion.valence > 0.0, "valence should be positive");
    }

    #[test]
    fn test_emotion_perception_sadness() {
        let msgs = [make_msg(MessageRole::User, "好难过...想哭")];
        let refs: Vec<&Message> = msgs.iter().collect();
        let emotion = CognitiveEngine::perceive_emotion(&refs);
        assert!(
            emotion.sadness > 0.3,
            "sadness should be significant, got {}",
            emotion.sadness
        );
        assert!(emotion.valence < 0.0, "valence should be negative");
    }

    #[test]
    fn test_negation_detection() {
        let msgs = [make_msg(MessageRole::User, "我不开心")];
        let refs: Vec<&Message> = msgs.iter().collect();
        let emotion = CognitiveEngine::perceive_emotion(&refs);
        assert!(
            emotion.joy < 0.3,
            "negated joy should be low, got {}",
            emotion.joy
        );
    }

    #[test]
    fn test_sarcasm_detection() {
        let msgs = [
            make_msg(MessageRole::User, "行啊你厉害"),
            make_msg(MessageRole::User, "呵呵随便你"),
        ];
        let refs: Vec<&Message> = msgs.iter().collect();
        let patterns = CognitiveEngine::detect_language_patterns(&refs);
        assert!(
            patterns.contains(&LanguagePattern::Sarcasm),
            "should detect sarcasm"
        );
    }

    #[test]
    fn test_hesitation_detection() {
        let msgs = [make_msg(MessageRole::User, "我...算了不说了")];
        let refs: Vec<&Message> = msgs.iter().collect();
        let patterns = CognitiveEngine::detect_language_patterns(&refs);
        assert!(
            patterns.contains(&LanguagePattern::Hesitation),
            "should detect hesitation"
        );
    }

    #[test]
    fn test_coquettish_detection() {
        let msgs = [make_msg(MessageRole::User, "你都不理人家嘛～哼")];
        let refs: Vec<&Message> = msgs.iter().collect();
        let patterns = CognitiveEngine::detect_language_patterns(&refs);
        assert!(
            patterns.contains(&LanguagePattern::Coquettish),
            "should detect coquettish tone"
        );
    }

    #[test]
    fn test_intent_seeking_comfort() {
        let msgs = [make_msg(MessageRole::User, "好难过...今天被骂了")];
        let refs: Vec<&Message> = msgs.iter().collect();
        let analysis = CognitiveEngine::analyze(&refs);
        assert_eq!(analysis.intent, DialogueIntent::SeekingComfort);
    }

    #[test]
    fn test_intent_playful() {
        let msgs = [make_msg(MessageRole::User, "哈哈哈笑死我了你好笨")];
        let refs: Vec<&Message> = msgs.iter().collect();
        let analysis = CognitiveEngine::analyze(&refs);
        assert_eq!(analysis.intent, DialogueIntent::Playful);
    }

    #[test]
    fn test_intent_farewell() {
        let msgs = [make_msg(MessageRole::User, "困了，晚安～")];
        let refs: Vec<&Message> = msgs.iter().collect();
        let analysis = CognitiveEngine::analyze(&refs);
        assert_eq!(analysis.intent, DialogueIntent::Farewell);
    }

    #[test]
    fn test_empathy_strategy_for_sadness() {
        let msgs = [make_msg(MessageRole::User, "我真的好难过好难过...")];
        let refs: Vec<&Message> = msgs.iter().collect();
        let analysis = CognitiveEngine::analyze(&refs);
        assert!(
            analysis.empathy_strategy == EmpathyStrategy::Accompany
                || analysis.empathy_strategy == EmpathyStrategy::Mirror,
            "should use accompany or mirror for deep sadness, got {:?}",
            analysis.empathy_strategy
        );
    }

    #[test]
    fn test_empathy_proactive_care_for_suppressed() {
        let msgs = [
            make_msg(MessageRole::User, "今天发生了好多事情啊，真的好累好累"),
            make_msg(MessageRole::Assistant, "怎么了？发生什么事了？"),
            make_msg(MessageRole::User, "嗯"),
        ];
        let refs: Vec<&Message> = msgs.iter().collect();
        let patterns = CognitiveEngine::detect_language_patterns(&refs);
        assert!(
            patterns.contains(&LanguagePattern::Suppressed),
            "should detect suppressed emotion"
        );
    }

    #[test]
    fn test_full_analysis_generates_prompt() {
        let msgs = [
            make_msg(MessageRole::User, "你在干嘛呀"),
            make_msg(MessageRole::Assistant, "在想你呀"),
            make_msg(MessageRole::User, "讨厌～才没有想你呢"),
        ];
        let refs: Vec<&Message> = msgs.iter().collect();
        let analysis = CognitiveEngine::analyze(&refs);
        assert!(
            !analysis.cognitive_prompt.is_empty(),
            "should generate cognitive prompt"
        );
        assert!(
            analysis.cognitive_prompt.contains("认知分析"),
            "prompt should contain cognitive analysis sections"
        );
    }

    #[test]
    fn test_relationship_dynamics() {
        let msgs = [
            make_msg(MessageRole::User, "宝贝我好想你"),
            make_msg(MessageRole::Assistant, "我也想你呀亲爱的"),
            make_msg(MessageRole::User, "抱抱～好暖"),
            make_msg(MessageRole::Assistant, "（把你搂进怀里）乖"),
        ];
        let refs: Vec<&Message> = msgs.iter().collect();
        let emotion = CognitiveEngine::perceive_emotion(&refs);
        let relationship = CognitiveEngine::analyze_relationship(&refs, &emotion);
        assert!(
            relationship.closeness > 0.5,
            "closeness should be high, got {}",
            relationship.closeness
        );
        assert!(
            relationship.tension < 0.3,
            "tension should be low, got {}",
            relationship.tension
        );
    }

    #[test]
    fn test_empty_messages() {
        let refs: Vec<&Message> = Vec::new();
        let analysis = CognitiveEngine::analyze(&refs);
        assert!(
            analysis.cognitive_prompt.contains("认知分析") || analysis.emotion.valence.abs() < 0.01
        );
    }

    #[test]
    fn test_text_similarity() {
        let sim = CognitiveEngine::text_similarity("你好世界", "你好世界");
        assert!(
            (sim - 1.0).abs() < 0.01,
            "identical texts should have similarity ~1.0"
        );

        let sim2 = CognitiveEngine::text_similarity("你好世界", "再见朋友");
        assert!(sim2 < 0.3, "different texts should have low similarity");
    }
}
