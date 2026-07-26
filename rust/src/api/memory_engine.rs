use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;

use flutter_rust_bridge::frb;

use serde::{Deserialize, Serialize};

use super::data_models::*;
use super::error_handler::ChatError;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ShortTermContext {
    pub active_topics: Vec<String>,
    pub emotional_arc: Vec<EmotionalSnapshot>,
    pub pending_threads: Vec<String>,
    pub response_fingerprints: Vec<ResponseFingerprint>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EmotionalSnapshot {
    pub turn: u32,
    pub valence: f64,
    pub arousal: f64,
    pub dominant_emotion: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ResponseFingerprint {
    pub opening_chars: String,
    pub paragraph_count: usize,
    pub avg_sentence_len: f64,
    pub ending_chars: String,
    pub ends_with_question: bool,
    pub total_length: usize,
    pub has_action_marker: bool,
    pub has_list_format: bool,
    pub emotional_tone: String,
}

const SUMMARIZE_INTERVAL: u32 = 10;

const TIERED_MERGE_THRESHOLD: usize = 8;

const BM25_K1: f64 = 1.2;
const BM25_B: f64 = 0.75;

#[frb(opaque)]
pub struct MemoryEngine {
    base_path: String,
}

impl MemoryEngine {
    pub fn new(base_path: &str) -> Self {
        Self {
            base_path: base_path.to_string(),
        }
    }

    fn memory_dir(&self) -> Result<PathBuf, ChatError> {
        let dir = PathBuf::from(&self.base_path).join("memory_index");
        if !dir.exists() {
            fs::create_dir_all(&dir).map_err(|e| ChatError::StorageError {
                message: format!("Failed to create memory directory: {}", e),
            })?;
        }
        Ok(dir)
    }

    pub fn should_summarize(turn_count: u32) -> bool {
        turn_count > 0 && turn_count.is_multiple_of(SUMMARIZE_INTERVAL)
    }

    pub fn compression_impact(generation: u32) -> CompressionImpactLevel {
        match generation {
            0..=1 => CompressionImpactLevel::Lossless,
            2..=3 => CompressionImpactLevel::StyleDrift,
            4..=5 => CompressionImpactLevel::PersonalityFade,
            6..=7 => CompressionImpactLevel::DetailLoss,
            _ => CompressionImpactLevel::IdentityErosion,
        }
    }

    fn compression_protection_instructions(generation: u32) -> String {
        let impact = Self::compression_impact(generation);
        match impact {
            CompressionImpactLevel::Lossless => {
                "【压缩等级：无损】所有信息必须完整保留，不可省略任何细节。".to_string()
            }
            CompressionImpactLevel::StyleDrift => "【压缩等级：轻微风格偏移】\n\
                 优先保留：身份、关系、事件、金钱数值、承诺\n\
                 允许简化：语气描述、氛围词、重复的情绪表达\n\
                 警告：角色的口癖和表达习惯可能因压缩而轻微变化"
                .to_string(),
            CompressionImpactLevel::PersonalityFade => "【压缩等级：性格细节模糊风险】\n\
                 必须保留（绝对不可丢失）：\n\
                 - [身份] 所有身份属性\n\
                 - [关系] 所有人物关系\n\
                 - [事件] 所有关键事件\n\
                 - [金钱] 所有金额/交易记录\n\
                 允许压缩：性格描述可合并为关键词，口癖可省略频率细节\n\
                 警告：此代数的压缩可能导致角色性格表现不如早期精确"
                .to_string(),
            CompressionImpactLevel::DetailLoss => "【压缩等级：细节丢失风险】\n\
                 绝对保留（核心锚点）：\n\
                 - [身份] 姓名、年龄、职业、核心设定\n\
                 - [关系] 主要人物关系方向\n\
                 - [事件] 不可逆转折点\n\
                 尽力保留：金钱数值、次要关系、时间线\n\
                 允许丢失：氛围、场景细节、重复事件的具体过程\n\
                 警告：金钱数值和次要关系可能因多次压缩而不精确"
                .to_string(),
            CompressionImpactLevel::IdentityErosion => "【压缩等级：深度退化风险】\n\
                 这是高代数压缩，信息损耗不可避免。\n\
                 绝对保留（最后防线）：\n\
                 - 角色姓名和核心身份\n\
                 - 与用户的关系定义\n\
                 - 最重要的 3-5 个转折事件\n\
                 尽力保留：其他身份属性、金钱、次要关系\n\
                 警告：身份的边缘属性（爱好、习惯、次要设定）可能已经模糊"
                .to_string(),
        }
    }

    pub fn extract_keywords(text: &str) -> Vec<String> {
        let mut keywords = Vec::new();
        for word in text.split(|c: char| !c.is_alphanumeric() && c != '-' && c != '_') {
            let w = word.trim().to_lowercase();
            if w.len() >= 2 && !is_stop_word(&w) {
                keywords.push(w);
            }
        }
        let chars: Vec<char> = text
            .chars()
            .filter(|c| c.is_alphabetic() || *c > '\u{4e00}')
            .collect();
        for window in chars.windows(2) {
            let bigram: String = window.iter().collect();
            if bigram.chars().any(|c| c > '\u{4e00}') {
                keywords.push(bigram);
            }
        }
        keywords.sort();
        keywords.dedup();
        keywords
    }

    pub fn build_summarize_prompt(
        messages: &[Message],
        existing_summaries: &[MemorySummary],
        turn_start: u32,
        turn_end: u32,
    ) -> String {
        let mut prompt = String::new();

        let max_gen = existing_summaries
            .iter()
            .map(|s| s.compression_generation)
            .max()
            .unwrap_or(0);
        let current_gen = if existing_summaries.is_empty() {
            0
        } else {
            max_gen
        };

        prompt.push_str(&Self::compression_protection_instructions(current_gen));
        prompt.push('\n');
        prompt.push('\n');

        if !existing_summaries.is_empty() {
            prompt.push_str("【已确认的核心事实（不可修改）】\n");
            for summary in existing_summaries {
                for fact in &summary.core_facts {
                    prompt.push_str(&format!("- {}\n", fact));
                }
            }
            prompt.push('\n');
        }

        prompt.push_str("【需要总结的对话内容】\n");
        for msg in messages {
            let role = match msg.role {
                MessageRole::User => "用户",
                MessageRole::Assistant => "AI",
                MessageRole::System => continue,
            };
            let type_tag = match msg.message_type {
                MessageType::Say => "[说]",
                MessageType::Do => "[做]",
                MessageType::Mixed => "[混合]",
            };
            prompt.push_str(&format!("{}{}: {}\n", role, type_tag, msg.content));
        }

        prompt.push_str(&format!(
            "\n请严格按照以下JSON格式输出第{}轮到第{}轮的总结：\n",
            turn_start, turn_end
        ));
        prompt.push_str(
            r#"{
  "summary": "用一段话概括关键情节走向（50字以内）",
  "core_facts": [
    "身份/关系类事实",
    "已发生的关键转折",
    "当前状态/情感基调"
  ]
}

要求：
1. core_facts 采用三元组编码：「主体→关系/动作→客体」，如"A→青梅竹马→B"
2. 分类记录：
   - [身份] 角色身份、职业、年龄等不可变属性
   - [关系] 人物间的关系变化（用→标记方向）
   - [事件] 已发生的不可逆事件（时间+动作+结果）
   - [状态] 当前情感基调、物理状态
3. summary 用最少的字传达最多信息，像写电报一样精炼
4. 每条 core_fact 控制在25字以内
5. 与已有核心事实不矛盾，有更新则替换旧版本（标注[更新]）
6. 不记录情绪描写和氛围词，只记录可验证的事实
7. 只输出JSON"#,
        );

        prompt
    }

    pub fn build_long_summary_prompt(
        all_summaries: &[MemorySummary],
        recent_messages: &[Message],
    ) -> String {
        let mut prompt = String::new();

        let max_gen = all_summaries
            .iter()
            .map(|s| s.compression_generation)
            .max()
            .unwrap_or(0);
        let merge_gen = max_gen + 1;

        prompt.push_str(&Self::compression_protection_instructions(merge_gen));
        prompt.push('\n');
        prompt.push_str(&format!(
            "（当前压缩代数：{}，每次合并代数+1，代数越高信息损耗风险越大）\n\n",
            merge_gen
        ));

        prompt.push_str("整合以下所有记忆摘要为一份精炼总结。\n\n");

        prompt.push_str("【历史记忆】\n");
        for (i, s) in all_summaries.iter().enumerate() {
            let gen_tag = if s.compression_generation > 0 {
                format!(" [压缩G{}]", s.compression_generation)
            } else {
                String::new()
            };
            prompt.push_str(&format!(
                "{}. [轮次{}-{}]{} {}\n  事实：{}\n",
                i + 1,
                s.turn_range_start,
                s.turn_range_end,
                gen_tag,
                s.summary,
                s.core_facts.join("；")
            ));
        }

        if !recent_messages.is_empty() {
            prompt.push_str("\n【最近对话】\n");
            for msg in recent_messages.iter().take(20) {
                let role = match msg.role {
                    MessageRole::User => "用户",
                    MessageRole::Assistant => "AI",
                    MessageRole::System => continue,
                };
                prompt.push_str(&format!("{}: {}\n", role, msg.content));
            }
        }

        prompt.push_str(
            r#"
输出JSON：
{
  "summary": "完整故事线概括（100字以内，按时间线串联关键转折）",
  "core_facts": ["所有不可变事实，三元组编码，去重合并"]
}

要求：
1. 合并重复事实，保留最新版本，标注[合并]
2. summary 按时间线组织，只保留影响剧情走向的节点
3. core_facts 分类编码：
   - [身份] 不可变属性
   - [关系] 人物关系（用→标记）
   - [事件] 关键转折（时间+结果）
   - [状态] 当前状态
4. 每条 fact ≤25字，用"主体→关系→客体"结构
5. 信息零丢失：原始事实中的每一条都必须在新列表中有对应项
6. 只输出JSON"#,
        );

        prompt
    }

    pub fn build_verify_summary_prompt(
        original_core_facts: &[String],
        new_summary: &str,
        new_core_facts: &[String],
    ) -> String {
        let mut prompt = String::new();
        prompt.push_str("检查新总结是否遗漏了原始核心事实。\n\n");

        prompt.push_str("【原始事实】\n");
        for fact in original_core_facts {
            prompt.push_str(&format!("- {}\n", fact));
        }

        prompt.push_str(&format!("\n【新总结】{}\n", new_summary));
        prompt.push_str("【新事实】\n");
        for fact in new_core_facts {
            prompt.push_str(&format!("- {}\n", fact));
        }

        prompt.push_str(
            r#"
输出JSON：
{
  "is_valid": true/false,
  "missing_facts": ["遗漏的事实"],
  "corrected_core_facts": ["补全后的完整事实列表（每条≤20字）"]
}
只输出JSON"#,
        );

        prompt
    }

    pub fn bm25_score(
        query_keywords: &[String],
        doc_keywords: &[String],
        avg_doc_len: f64,
        total_docs: usize,
        doc_freq: &HashMap<String, usize>,
    ) -> f64 {
        let doc_len = doc_keywords.len() as f64;
        let mut score = 0.0;

        let mut tf_map: HashMap<&str, usize> = HashMap::new();
        for kw in doc_keywords {
            *tf_map.entry(kw.as_str()).or_insert(0) += 1;
        }

        for query_term in query_keywords {
            let tf = *tf_map.get(query_term.as_str()).unwrap_or(&0) as f64;
            let df = *doc_freq.get(query_term.as_str()).unwrap_or(&0) as f64;

            if tf == 0.0 || df == 0.0 {
                continue;
            }

            let idf = ((total_docs as f64 - df + 0.5) / (df + 0.5) + 1.0).ln();
            let tf_norm = (tf * (BM25_K1 + 1.0))
                / (tf + BM25_K1 * (1.0 - BM25_B + BM25_B * doc_len / avg_doc_len));

            score += idf * tf_norm;
        }

        score
    }

    pub fn weighted_rrf_fusion(
        bm25_ranks: &[(usize, f64)],
        semantic_ranks: &[(usize, f64)],
        bm25_weight: f64,
        semantic_weight: f64,
        k: f64,
    ) -> Vec<(usize, f64)> {
        let mut fusion_scores: HashMap<usize, f64> = HashMap::new();

        for (rank, (doc_idx, _score)) in bm25_ranks.iter().enumerate() {
            let rrf = bm25_weight / (k + rank as f64 + 1.0);
            *fusion_scores.entry(*doc_idx).or_insert(0.0) += rrf;
        }

        for (rank, (doc_idx, _score)) in semantic_ranks.iter().enumerate() {
            let rrf = semantic_weight / (k + rank as f64 + 1.0);
            *fusion_scores.entry(*doc_idx).or_insert(0.0) += rrf;
        }

        let mut results: Vec<(usize, f64)> = fusion_scores.into_iter().collect();
        results.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
        results
    }

    pub fn keyword_cosine_similarity(keywords_a: &[String], keywords_b: &[String]) -> f64 {
        if keywords_a.is_empty() || keywords_b.is_empty() {
            return 0.0;
        }

        let set_a: std::collections::HashSet<&str> =
            keywords_a.iter().map(|s| s.as_str()).collect();
        let set_b: std::collections::HashSet<&str> =
            keywords_b.iter().map(|s| s.as_str()).collect();

        let intersection = set_a.intersection(&set_b).count() as f64;
        let magnitude = (set_a.len() as f64).sqrt() * (set_b.len() as f64).sqrt();

        if magnitude == 0.0 {
            0.0
        } else {
            intersection / magnitude
        }
    }

    pub fn tfidf_cosine_similarity(text_a: &str, text_b: &str) -> f64 {
        if text_a.is_empty() || text_b.is_empty() {
            return 0.0;
        }

        let norm_a = text_a.to_lowercase();
        let norm_b = text_b.to_lowercase();

        let features_a = Self::text_to_hybrid_features(&norm_a);
        let features_b = Self::text_to_hybrid_features(&norm_b);

        if features_a.is_empty() || features_b.is_empty() {
            return 0.0;
        }

        let tf_a = Self::compute_tf(&features_a);
        let tf_b = Self::compute_tf(&features_b);

        let mut vocabulary: std::collections::HashSet<&str> = std::collections::HashSet::new();
        for key in tf_a.keys() {
            vocabulary.insert(key.as_str());
        }
        for key in tf_b.keys() {
            vocabulary.insert(key.as_str());
        }

        let total_docs = 2.0f64;
        let mut dot_product = 0.0f64;
        let mut norm_sq_a = 0.0f64;
        let mut norm_sq_b = 0.0f64;

        for term in &vocabulary {
            let tf_val_a = tf_a.get(*term).copied().unwrap_or(0.0);
            let tf_val_b = tf_b.get(*term).copied().unwrap_or(0.0);

            let df =
                (if tf_val_a > 0.0 { 1.0 } else { 0.0 }) + (if tf_val_b > 0.0 { 1.0 } else { 0.0 });
            let idf = (total_docs / (1.0 + df)).ln() + 1.0;

            let tfidf_a = tf_val_a * idf;
            let tfidf_b = tf_val_b * idf;

            dot_product += tfidf_a * tfidf_b;
            norm_sq_a += tfidf_a * tfidf_a;
            norm_sq_b += tfidf_b * tfidf_b;
        }

        let magnitude = norm_sq_a.sqrt() * norm_sq_b.sqrt();
        if magnitude == 0.0 {
            0.0
        } else {
            (dot_product / magnitude).clamp(0.0, 1.0)
        }
    }

    fn text_to_hybrid_features(text: &str) -> Vec<String> {
        let chars: Vec<char> = text
            .chars()
            .filter(|c| c.is_alphanumeric() || (*c > '\u{4e00}' && *c < '\u{9fff}'))
            .collect();

        let mut features = Vec::new();

        for c in &chars {
            if *c > '\u{4e00}' && *c < '\u{9fff}' {
                features.push(c.to_string());
            }
        }

        if chars.len() >= 2 {
            for window in chars.windows(2) {
                features.push(window.iter().collect::<String>());
            }
        }

        if chars.len() >= 3 {
            for window in chars.windows(3) {
                features.push(window.iter().collect::<String>());
            }
        }

        let keywords = Self::extract_keywords(text);
        features.extend(keywords);

        features
    }

    fn compute_tf(features: &[String]) -> HashMap<String, f64> {
        let mut counts: HashMap<String, f64> = HashMap::new();
        let total = features.len() as f64;
        if total == 0.0 {
            return counts;
        }
        for f in features {
            *counts.entry(f.clone()).or_insert(0.0) += 1.0;
        }
        for val in counts.values_mut() {
            *val /= total;
        }
        counts
    }

    pub fn extract_active_topics_from_text(text: &str) -> Vec<String> {
        let mut topics = Vec::new();

        let keywords = Self::extract_keywords(text);
        topics.extend(keywords);

        let chars: Vec<char> = text.chars().collect();
        for window_size in 2..=4 {
            if chars.len() >= window_size {
                for window in chars.windows(window_size) {
                    let phrase: String = window.iter().collect();
                    if phrase.chars().any(|c| c > '\u{4e00}' && c < '\u{9fff}')
                        && !is_stop_word(&phrase)
                    {
                        topics.push(phrase);
                    }
                }
            }
        }

        topics.sort();
        topics.dedup();
        topics
    }

    pub fn extract_active_topics_from_messages(messages: &[&Message]) -> Vec<String> {
        let mut topic_scores: HashMap<String, f64> = HashMap::new();
        let total = messages.len();

        for (i, msg) in messages.iter().enumerate() {
            if msg.role == MessageRole::System {
                continue;
            }

            let recency_weight = ((i + 1) as f64 / total.max(1) as f64).powf(0.5);
            let role_weight = if msg.role == MessageRole::User {
                1.5
            } else {
                0.8
            };
            let weight = recency_weight * role_weight;

            let topics = Self::extract_active_topics_from_text(&msg.content);
            for topic in topics {
                *topic_scores.entry(topic).or_insert(0.0) += weight;
            }
        }

        let mut scored: Vec<(String, f64)> = topic_scores.into_iter().collect();
        scored.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));

        scored.into_iter().take(30).map(|(t, _)| t).collect()
    }

    pub fn compute_relevance_score(
        fact: &str,
        active_topics: &[String],
        user_content: &str,
    ) -> f64 {
        if fact.is_empty() || (active_topics.is_empty() && user_content.is_empty()) {
            return 0.0;
        }

        let tfidf_score = Self::tfidf_cosine_similarity(fact, user_content);

        let fact_keywords = Self::extract_keywords(fact);
        let keyword_overlap = if active_topics.is_empty() || fact_keywords.is_empty() {
            0.0
        } else {
            let overlap_count = fact_keywords
                .iter()
                .filter(|fk| {
                    active_topics
                        .iter()
                        .any(|t| t.contains(fk.as_str()) || fk.contains(t.as_str()))
                })
                .count();
            overlap_count as f64 / fact_keywords.len().max(1) as f64
        };

        let containment_score = if fact_keywords
            .iter()
            .any(|fk| user_content.contains(fk.as_str()))
        {
            0.3
        } else {
            0.0
        };

        let final_score = tfidf_score * 0.4 + keyword_overlap * 0.4 + containment_score * 0.2;

        final_score.clamp(0.0, 1.0)
    }

    pub fn fingerprint_response(content: &str) -> ResponseFingerprint {
        let chars: Vec<char> = content.chars().collect();
        let total_length = chars.len();

        let opening_chars: String = chars.iter().take(10).collect();

        let ending_chars: String = if chars.len() > 10 {
            chars[chars.len() - 10..].iter().collect()
        } else {
            opening_chars.clone()
        };

        let paragraphs: Vec<&str> = content
            .split('\n')
            .filter(|p| !p.trim().is_empty())
            .collect();
        let paragraph_count = paragraphs.len();

        let sentences: Vec<&str> = content
            .split(|c: char| c == '。' || c == '！' || c == '？' || c == '\n')
            .filter(|s| !s.trim().is_empty())
            .collect();
        let avg_sentence_len = if sentences.is_empty() {
            total_length as f64
        } else {
            sentences
                .iter()
                .map(|s| s.chars().count() as f64)
                .sum::<f64>()
                / sentences.len() as f64
        };

        let ends_with_question =
            content.trim_end().ends_with('？') || content.trim_end().ends_with('?');

        let has_action_marker =
            content.contains('*') || content.contains('（') || content.contains('「');

        let has_list_format = content.contains("1.")
            || content.contains("1、")
            || content.contains("- ")
            || content.contains("① ");

        let emotional_tone = Self::classify_response_tone(content);

        ResponseFingerprint {
            opening_chars,
            paragraph_count,
            avg_sentence_len,
            ending_chars,
            ends_with_question,
            total_length,
            has_action_marker,
            has_list_format,
            emotional_tone,
        }
    }

    fn classify_response_tone(content: &str) -> String {
        let warm_words = [
            "暖", "心疼", "抱", "乖", "宝", "温柔", "安慰", "懂", "陪", "在的", "没事", "放心",
        ];
        let playful_words = [
            "哈", "嘿", "笨", "坏", "才不", "哼", "讨厌", "逗", "噗", "哇",
        ];
        let concerned_words = ["怎么了", "还好吗", "担心", "小心", "注意", "别", "当心"];
        let cold_words = ["哦", "嗯", "行", "好吧", "随便", "知道了"];

        let warm_count = warm_words.iter().filter(|w| content.contains(*w)).count();
        let playful_count = playful_words
            .iter()
            .filter(|w| content.contains(*w))
            .count();
        let concerned_count = concerned_words
            .iter()
            .filter(|w| content.contains(*w))
            .count();
        let cold_count = cold_words.iter().filter(|w| content.contains(*w)).count();

        let max_count = warm_count
            .max(playful_count)
            .max(concerned_count)
            .max(cold_count);
        if max_count == 0 {
            return "neutral".to_string();
        }
        if warm_count == max_count {
            "warm".to_string()
        } else if playful_count == max_count {
            "playful".to_string()
        } else if concerned_count == max_count {
            "concerned".to_string()
        } else if cold_count == max_count {
            "cold".to_string()
        } else {
            "neutral".to_string()
        }
    }

    pub fn analyze_response_patterns(fingerprints: &[ResponseFingerprint]) -> Vec<String> {
        let mut suggestions = Vec::new();

        if fingerprints.len() < 3 {
            return suggestions;
        }

        let recent = &fingerprints[fingerprints.len().saturating_sub(5)..];

        let opening_4chars: Vec<String> = recent
            .iter()
            .map(|f| f.opening_chars.chars().take(4).collect::<String>())
            .collect();
        let mut opening_freq: HashMap<&str, usize> = HashMap::new();
        for o in &opening_4chars {
            *opening_freq.entry(o.as_str()).or_insert(0) += 1;
        }
        if opening_freq.values().any(|&c| c >= 3) {
            suggestions.push(
                "开头千篇一律了！试试：用动作开头、反问、感叹、引用对方的话、\
                 沉默后开口、一个表情先行、直接接着上句话说"
                    .to_string(),
            );
        }

        let question_end_ratio =
            recent.iter().filter(|f| f.ends_with_question).count() as f64 / recent.len() as f64;
        if question_end_ratio > 0.7 {
            suggestions.push(
                "不要每次都用问句结尾！有时候把话说完就行。\
                 试试：用动作收束、一句感慨、自然停下、留个悬念、\
                 用省略号表示还在想"
                    .to_string(),
            );
        }

        let lengths: Vec<f64> = recent.iter().map(|f| f.total_length as f64).collect();
        let mean_len = lengths.iter().sum::<f64>() / lengths.len() as f64;
        let variance =
            lengths.iter().map(|l| (l - mean_len).powi(2)).sum::<f64>() / lengths.len() as f64;
        let cv = if mean_len > 0.0 {
            variance.sqrt() / mean_len
        } else {
            0.0
        };
        if cv < 0.12 && lengths.len() >= 4 {
            suggestions.push(format!(
                "回复长度每次都差不多（约{}字），太机械！真人聊天忽长忽短：\n\
                 有时回一个「嗯」，有时来一大段。让长度跟着情绪和场景走",
                mean_len.round() as u32
            ));
        }

        let para_counts: Vec<usize> = recent.iter().map(|f| f.paragraph_count).collect();
        let para_set: std::collections::HashSet<&usize> = para_counts.iter().collect();
        if para_set.len() <= 1 && recent.len() >= 3 {
            suggestions.push(
                "段落结构太固定！不是每次都分几段。\
                 有时全部连着说，有时空行表示停顿/犹豫"
                    .to_string(),
            );
        }

        let tone_set: std::collections::HashSet<&str> =
            recent.iter().map(|f| f.emotional_tone.as_str()).collect();
        if tone_set.len() <= 1 && recent.len() >= 4 {
            let stuck_tone = recent
                .last()
                .map(|f| f.emotional_tone.as_str())
                .unwrap_or("neutral");
            suggestions.push(format!(
                "情感基调卡在「{}」模式了！真人的情绪是流动的：\n\
                 即使整体温柔，也会有小脾气、小无奈、小调皮的瞬间",
                match stuck_tone {
                    "warm" => "温柔关心",
                    "playful" => "活泼俏皮",
                    "concerned" => "担忧关切",
                    "cold" => "冷淡",
                    _ => "中性平淡",
                }
            ));
        }

        let action_ratio =
            recent.iter().filter(|f| f.has_action_marker).count() as f64 / recent.len() as f64;
        if action_ratio > 0.9 {
            suggestions.push(
                "不是每次都需要动作描写。有时纯对话更有力量。\
                 动作应该在情绪到位时自然出现，而不是每次强行加"
                    .to_string(),
            );
        } else if action_ratio < 0.1 && recent.len() >= 4 {
            suggestions.push(
                "试试加一些细微的动作/表情描写，让场景更有画面感。\
                 比如'（低下头）'、'（轻轻蹭了蹭你的手）'"
                    .to_string(),
            );
        }

        if recent.iter().any(|f| f.has_list_format) {
            suggestions.push(
                "绝对不要使用编号列表（1. 2. 3.）来回复！\
                 这是最明显的机器行为。真人用自然的句子表达"
                    .to_string(),
            );
        }

        suggestions
    }

    pub fn build_short_term_context(messages: &[Message]) -> ShortTermContext {
        let non_system: Vec<&Message> = messages
            .iter()
            .filter(|m| m.role != MessageRole::System)
            .collect();

        let recent_refs: Vec<&Message> = non_system.iter().rev().take(6).copied().collect();
        let active_topics = Self::extract_active_topics_from_messages(&recent_refs);

        let mut emotional_arc = Vec::new();
        let user_messages: Vec<&Message> = non_system
            .iter()
            .filter(|m| m.role == MessageRole::User)
            .rev()
            .take(5)
            .copied()
            .collect();

        for (i, msg) in user_messages.iter().enumerate() {
            let (valence, arousal, emotion) = Self::quick_emotion_scan(&msg.content);
            emotional_arc.push(EmotionalSnapshot {
                turn: (non_system.len().saturating_sub(i)) as u32,
                valence,
                arousal,
                dominant_emotion: emotion,
            });
        }
        emotional_arc.reverse();

        let pending_threads = Self::detect_pending_threads(&non_system);

        let response_fingerprints: Vec<ResponseFingerprint> = non_system
            .iter()
            .filter(|m| m.role == MessageRole::Assistant)
            .rev()
            .take(5)
            .map(|m| Self::fingerprint_response(&m.content))
            .collect::<Vec<_>>()
            .into_iter()
            .rev()
            .collect();

        ShortTermContext {
            active_topics,
            emotional_arc,
            pending_threads,
            response_fingerprints,
        }
    }

    fn quick_emotion_scan(text: &str) -> (f64, f64, String) {
        let positive_words = [
            ("开心", 0.8),
            ("高兴", 0.8),
            ("笑", 0.5),
            ("哈哈", 0.7),
            ("喜欢", 0.7),
            ("爱", 0.9),
            ("甜", 0.7),
            ("暖", 0.6),
            ("嘿嘿", 0.6),
            ("耶", 0.7),
            ("棒", 0.6),
        ];
        let negative_words = [
            ("难过", 0.8),
            ("伤心", 0.9),
            ("生气", 0.8),
            ("烦", 0.6),
            ("哭", 0.8),
            ("累", 0.5),
            ("emo", 0.7),
            ("崩溃", 1.0),
            ("委屈", 0.8),
            ("焦虑", 0.7),
            ("害怕", 0.8),
        ];

        let mut pos_score = 0.0f64;
        let mut neg_score = 0.0f64;

        for &(word, weight) in &positive_words {
            if text.contains(word) {
                pos_score += weight;
            }
        }
        for &(word, weight) in &negative_words {
            if text.contains(word) {
                neg_score += weight;
            }
        }

        let valence = if pos_score + neg_score > 0.0 {
            (pos_score - neg_score) / (pos_score + neg_score)
        } else {
            0.0
        };

        let arousal = (pos_score + neg_score).min(1.0);

        let dominant = if pos_score > neg_score {
            if pos_score > 0.7 {
                "喜悦"
            } else {
                "轻松"
            }
        } else if neg_score > pos_score {
            if neg_score > 0.7 {
                "悲伤"
            } else {
                "低落"
            }
        } else {
            "平静"
        };

        (valence, arousal, dominant.to_string())
    }

    fn detect_pending_threads(messages: &[&Message]) -> Vec<String> {
        let mut threads = Vec::new();
        if messages.len() < 4 {
            return threads;
        }

        let recent: Vec<&&Message> = messages.iter().rev().take(6).collect();
        let mut i = 0;
        while i + 1 < recent.len() {
            let current = recent[i];
            let next = recent[i + 1];

            if current.role == MessageRole::User && next.role == MessageRole::Assistant {
                let user_kw = Self::extract_keywords(&current.content);
                let ai_kw = Self::extract_keywords(&next.content);

                for kw in &user_kw {
                    if kw.chars().count() >= 2 && !ai_kw.contains(kw) && !is_stop_word(kw) {
                        threads.push(kw.clone());
                    }
                }
            }
            i += 1;
        }

        threads.sort();
        threads.dedup();
        threads.truncate(5);
        threads
    }

    pub fn describe_emotional_arc(arc: &[EmotionalSnapshot]) -> String {
        if arc.is_empty() {
            return String::new();
        }
        if arc.len() == 1 {
            return format!("对方当前情绪：{}", arc[0].dominant_emotion);
        }

        let mut description = String::from("对方最近的情绪变化：");
        let emotions: Vec<&str> = arc.iter().map(|s| s.dominant_emotion.as_str()).collect();

        let first_valence = arc.first().map(|s| s.valence).unwrap_or(0.0);
        let last_valence = arc.last().map(|s| s.valence).unwrap_or(0.0);
        let trend = last_valence - first_valence;

        description.push_str(&emotions.join(" → "));

        if trend > 0.3 {
            description.push_str("（情绪在好转↑）");
        } else if trend < -0.3 {
            description.push_str("（情绪在下滑↓）");
        } else if arc.iter().all(|s| s.arousal < 0.2) {
            description.push_str("（一直很平淡，可能需要注意）");
        }

        for window in arc.windows(2) {
            let delta = (window[1].valence - window[0].valence).abs();
            if delta > 0.5 {
                description.push_str(&format!(
                    "\n⚠ 情绪急转：{} → {}，一定有什么事",
                    window[0].dominant_emotion, window[1].dominant_emotion
                ));
                break;
            }
        }

        description
    }

    pub fn search_memories(
        query: &str,
        summaries: &[MemorySummary],
        top_k: usize,
    ) -> Vec<MemorySearchResult> {
        if summaries.is_empty() {
            return Vec::new();
        }

        let query_keywords = Self::extract_keywords(query);
        if query_keywords.is_empty() {
            return Vec::new();
        }

        let total_docs = summaries.len();
        let mut doc_freq: HashMap<String, usize> = HashMap::new();
        let mut all_doc_keywords: Vec<Vec<String>> = Vec::new();
        let mut total_len = 0usize;

        for summary in summaries {
            let mut doc_kw = summary.keywords.clone();
            let enhanced_text = Self::build_enhanced_search_text(summary);
            doc_kw.extend(Self::extract_keywords(&enhanced_text));
            for fact in &summary.core_facts {
                doc_kw.extend(Self::extract_keywords(fact));
            }
            if let Some(card) = &summary.context_card {
                for entity in &card.key_entities {
                    doc_kw.extend(Self::extract_keywords(entity));
                }
                for tag in &card.topic_tags {
                    doc_kw.push(tag.clone());
                }
            }
            doc_kw.sort();
            doc_kw.dedup();

            for kw in &doc_kw {
                *doc_freq.entry(kw.clone()).or_insert(0) += 1;
            }
            total_len += doc_kw.len();
            all_doc_keywords.push(doc_kw);
        }

        let avg_doc_len = total_len as f64 / total_docs as f64;

        let mut bm25_scores: Vec<(usize, f64)> = all_doc_keywords
            .iter()
            .enumerate()
            .map(|(i, doc_kw)| {
                let score =
                    Self::bm25_score(&query_keywords, doc_kw, avg_doc_len, total_docs, &doc_freq);
                (i, score)
            })
            .collect();
        bm25_scores.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));

        let mut semantic_scores: Vec<(usize, f64)> = all_doc_keywords
            .iter()
            .enumerate()
            .map(|(i, doc_kw)| {
                let score = Self::keyword_cosine_similarity(&query_keywords, doc_kw);
                (i, score)
            })
            .collect();
        semantic_scores.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));

        let fused = Self::weighted_rrf_fusion(&bm25_scores, &semantic_scores, 0.6, 0.4, 60.0);

        fused
            .into_iter()
            .take(top_k)
            .filter(|(_, score)| *score > 0.0)
            .map(|(idx, score)| {
                let s = &summaries[idx];
                MemorySearchResult {
                    summary: s.summary.clone(),
                    core_facts: s.core_facts.clone(),
                    relevance_score: score,
                }
            })
            .collect()
    }

    pub fn should_tiered_merge(summaries: &[MemorySummary]) -> bool {
        summaries.len() >= TIERED_MERGE_THRESHOLD
    }

    pub fn classify_fact_tier(fact: &str) -> MemoryTier {
        let f = fact.to_lowercase();

        if f.contains("[身份]")
            || f.contains("姓名")
            || f.contains("名字")
            || f.contains("年龄")
            || f.contains("职业")
            || f.contains("设定")
            || f.contains("identity")
            || f.contains("→是→")
            || f.contains("→叫→")
        {
            return MemoryTier::Identity;
        }

        if f.contains("[事件]")
            || f.contains("承诺")
            || f.contains("约定")
            || f.contains("金钱")
            || f.contains("金额")
            || f.contains("转折")
            || f.contains("不可逆")
            || f.contains("死")
            || f.contains("离开")
            || f.contains("告白")
            || f.contains("分手")
            || f.contains("结婚")
        {
            return MemoryTier::CriticalEvent;
        }

        if f.contains("[关系]")
            || f.contains("关系")
            || f.contains("亲密")
            || f.contains("信任")
            || f.contains("→喜欢→")
            || f.contains("→讨厌→")
            || f.contains("→暗恋→")
            || f.contains("→青梅竹马→")
        {
            return MemoryTier::RelationshipDynamic;
        }

        if f.contains("[状态]")
            || f.contains("当前")
            || f.contains("现在")
            || f.contains("情绪")
            || f.contains("心情")
            || f.contains("基调")
        {
            return MemoryTier::CurrentState;
        }

        MemoryTier::SceneDetail
    }

    pub fn classify_all_facts(core_facts: &[String]) -> Vec<MemoryTier> {
        core_facts
            .iter()
            .map(|f| Self::classify_fact_tier(f))
            .collect()
    }

    pub fn tiered_merge(summaries: &[MemorySummary]) -> (Vec<MemorySummary>, Option<String>) {
        if summaries.len() < TIERED_MERGE_THRESHOLD {
            return (summaries.to_vec(), None);
        }

        let mut identity_facts: Vec<String> = Vec::new();
        let mut critical_facts: Vec<String> = Vec::new();
        let mut relationship_facts: Vec<String> = Vec::new();
        let mut state_facts: Vec<String> = Vec::new();
        let mut scene_facts: Vec<String> = Vec::new();

        for summary in summaries {
            for (i, fact) in summary.core_facts.iter().enumerate() {
                let tier = if i < summary.fact_tiers.len() {
                    summary.fact_tiers[i].clone()
                } else {
                    Self::classify_fact_tier(fact)
                };
                match tier {
                    MemoryTier::Identity => identity_facts.push(fact.clone()),
                    MemoryTier::CriticalEvent => critical_facts.push(fact.clone()),
                    MemoryTier::RelationshipDynamic => relationship_facts.push(fact.clone()),
                    MemoryTier::CurrentState => state_facts.push(fact.clone()),
                    MemoryTier::SceneDetail => scene_facts.push(fact.clone()),
                }
            }
        }

        identity_facts.sort();
        identity_facts.dedup();
        critical_facts.sort();
        critical_facts.dedup();
        relationship_facts.sort();
        relationship_facts.dedup();
        state_facts.sort();
        state_facts.dedup();

        let state_facts = Self::deduplicate_state_facts(&state_facts);

        let max_gen = summaries
            .iter()
            .map(|s| s.compression_generation)
            .max()
            .unwrap_or(0);
        let merge_gen = max_gen + 1;

        let latest = summaries.last().cloned();

        let older: Vec<&MemorySummary> = summaries
            .iter()
            .take(summaries.len().saturating_sub(1))
            .collect();

        if older.is_empty() {
            return (summaries.to_vec(), None);
        }

        let merged_summary: String = older
            .iter()
            .map(|s| s.summary.as_str())
            .collect::<Vec<&str>>()
            .join("→");

        let merged_summary = if merged_summary.chars().count() > 150 {
            format!(
                "{}...",
                merged_summary.chars().take(147).collect::<String>()
            )
        } else {
            merged_summary
        };

        let mut merged_facts: Vec<String> = Vec::new();
        let mut merged_tiers: Vec<MemoryTier> = Vec::new();

        for f in &identity_facts {
            merged_facts.push(f.clone());
            merged_tiers.push(MemoryTier::Identity);
        }
        for f in &critical_facts {
            merged_facts.push(f.clone());
            merged_tiers.push(MemoryTier::CriticalEvent);
        }
        for f in &relationship_facts {
            merged_facts.push(f.clone());
            merged_tiers.push(MemoryTier::RelationshipDynamic);
        }
        for f in &state_facts {
            merged_facts.push(f.clone());
            merged_tiers.push(MemoryTier::CurrentState);
        }

        let turn_start = older.iter().map(|s| s.turn_range_start).min().unwrap_or(0);
        let turn_end = older.iter().map(|s| s.turn_range_end).max().unwrap_or(0);

        let mut merged_keywords: Vec<String> =
            older.iter().flat_map(|s| s.keywords.clone()).collect();
        merged_keywords.sort();
        merged_keywords.dedup();

        let merged_card = Self::build_context_card_from_facts(&merged_facts, turn_start, turn_end);

        let merged_entry = MemorySummary {
            id: uuid::Uuid::new_v4().to_string(),
            summary: merged_summary,
            core_facts: merged_facts,
            turn_range_start: turn_start,
            turn_range_end: turn_end,
            created_at: chrono::Utc::now().timestamp_millis(),
            keywords: merged_keywords,
            compression_generation: merge_gen,
            context_card: Some(merged_card),
            fact_tiers: merged_tiers,
        };

        let mut result = vec![merged_entry];
        if let Some(latest) = latest {
            result.push(latest);
        }

        let needs_llm = result.iter().map(|s| s.core_facts.len()).sum::<usize>() > 40;

        let llm_prompt = if needs_llm {
            Some(Self::build_tiered_merge_prompt(&result, merge_gen))
        } else {
            None
        };

        (result, llm_prompt)
    }

    fn deduplicate_state_facts(facts: &[String]) -> Vec<String> {
        if facts.len() <= 2 {
            return facts.to_vec();
        }
        facts
            .iter()
            .rev()
            .take(2)
            .cloned()
            .collect::<Vec<_>>()
            .into_iter()
            .rev()
            .collect()
    }

    fn build_tiered_merge_prompt(summaries: &[MemorySummary], merge_gen: u32) -> String {
        let mut prompt = String::new();

        prompt.push_str(&Self::compression_protection_instructions(merge_gen));
        prompt.push_str("\n\n");
        prompt.push_str("【分级压缩合并任务】\n");
        prompt.push_str("以下记忆需要进一步精炼，但必须遵守排级保护规则：\n\n");

        prompt.push_str("■ 绝对保护（不可修改、不可合并、不可省略）：\n");
        prompt.push_str("  - 所有 [身份] 类事实\n");
        prompt.push_str("  - 所有 [事件] 类不可逆转折\n");
        prompt.push_str("  - 所有承诺/约定/金额\n\n");

        prompt.push_str("■ 允许合并（语义相近的可合并为一条）：\n");
        prompt.push_str("  - [关系] 类事实（保留最新关系状态）\n");
        prompt.push_str("  - [状态] 类事实（只保留当前状态）\n\n");

        for (i, s) in summaries.iter().enumerate() {
            prompt.push_str(&format!(
                "记忆{}. [轮{}-{}] {}\n",
                i + 1,
                s.turn_range_start,
                s.turn_range_end,
                s.summary
            ));
            for (j, fact) in s.core_facts.iter().enumerate() {
                let tier_tag = if j < s.fact_tiers.len() {
                    match &s.fact_tiers[j] {
                        MemoryTier::Identity => " 🔒身份",
                        MemoryTier::CriticalEvent => " 🔒事件",
                        MemoryTier::RelationshipDynamic => " 🔄关系",
                        MemoryTier::CurrentState => " ⏳状态",
                        MemoryTier::SceneDetail => " 💨场景",
                    }
                } else {
                    ""
                };
                prompt.push_str(&format!("  - {}{}\n", fact, tier_tag));
            }
        }

        prompt.push_str(
            r#"
输出JSON：
{
  "summary": "合并后的完整时间线概括（100字以内）",
  "core_facts": ["精炼后的事实列表，三元组编码"],
  "fact_tiers": ["Identity/CriticalEvent/RelationshipDynamic/CurrentState 对应每条事实"]
}

要求：
1. 🔒标记的事实必须原样保留，一字不改
2. 🔄标记的事实可以合并同类项，但不可丢弃
3. ⏳标记的事实只保留最新状态
4. 💨标记的事实可以省略
5. 合并后的事实总数不超过25条
6. 只输出JSON"#,
        );

        prompt
    }

    pub fn build_context_card(summary: &MemorySummary) -> MemoryContextCard {
        Self::build_context_card_from_facts(
            &summary.core_facts,
            summary.turn_range_start,
            summary.turn_range_end,
        )
    }

    fn build_context_card_from_facts(
        core_facts: &[String],
        turn_start: u32,
        turn_end: u32,
    ) -> MemoryContextCard {
        let source_range = format!("对话轮次 {}-{}", turn_start, turn_end);

        let mut topic_tags: Vec<String> = Vec::new();
        let mut key_entities: Vec<String> = Vec::new();
        let mut emotional_indicators: Vec<&str> = Vec::new();
        let mut causal_links: Vec<String> = Vec::new();

        for fact in core_facts {
            if fact.contains("[身份]") {
                topic_tags.push("身份".to_string());
            }
            if fact.contains("[关系]") {
                topic_tags.push("关系".to_string());
            }
            if fact.contains("[事件]") {
                topic_tags.push("事件".to_string());
            }
            if fact.contains("[状态]") {
                topic_tags.push("状态".to_string());
            }

            let parts: Vec<&str> = fact.split('→').collect();
            if parts.len() >= 2 {
                let entity = parts[0]
                    .trim()
                    .trim_start_matches("[身份]")
                    .trim_start_matches("[关系]")
                    .trim_start_matches("[事件]")
                    .trim_start_matches("[状态]")
                    .trim();
                if !entity.is_empty() && entity.chars().count() <= 10 {
                    key_entities.push(entity.to_string());
                }
                if parts.len() >= 3 {
                    let object = parts.last().unwrap().trim();
                    if !object.is_empty() && object.chars().count() <= 10 {
                        key_entities.push(object.to_string());
                    }
                }
            }

            let positive = ["开心", "幸福", "甜蜜", "温暖", "信任", "亲密", "喜欢"];
            let negative = ["难过", "生气", "冷战", "疏远", "不信任", "伤心", "愤怒"];
            for kw in &positive {
                if fact.contains(kw) {
                    emotional_indicators.push("正面");
                }
            }
            for kw in &negative {
                if fact.contains(kw) {
                    emotional_indicators.push("负面");
                }
            }

            if fact.contains("因为")
                || fact.contains("导致")
                || fact.contains("所以")
                || fact.contains("因此")
            {
                causal_links.push(fact.clone());
            }
        }

        topic_tags.sort();
        topic_tags.dedup();
        key_entities.sort();
        key_entities.dedup();

        let pos_count = emotional_indicators
            .iter()
            .filter(|&&e| e == "正面")
            .count();
        let neg_count = emotional_indicators
            .iter()
            .filter(|&&e| e == "负面")
            .count();
        let emotional_tone = if pos_count > neg_count {
            format!("正面(强度:{}/{})", pos_count, pos_count + neg_count)
        } else if neg_count > pos_count {
            format!("负面(强度:{}/{})", neg_count, pos_count + neg_count)
        } else if pos_count > 0 {
            "混合".to_string()
        } else {
            "中性".to_string()
        };

        MemoryContextCard {
            source_range,
            topic_tags,
            key_entities,
            emotional_tone,
            causal_links,
        }
    }

    pub fn build_enhanced_search_text(summary: &MemorySummary) -> String {
        let mut text = summary.summary.clone();

        if let Some(card) = &summary.context_card {
            if !card.topic_tags.is_empty() {
                text.push_str(&format!(" [主题:{}]", card.topic_tags.join(",")));
            }
            if !card.key_entities.is_empty() {
                text.push_str(&format!(" [实体:{}]", card.key_entities.join(",")));
            }
            text.push_str(&format!(" [情感:{}]", card.emotional_tone));
            text.push_str(&format!(" [范围:{}]", card.source_range));
        }

        text
    }

    pub fn save_memory_index(
        &self,
        conversation_id: &str,
        summaries: &[MemorySummary],
    ) -> Result<(), ChatError> {
        let dir = self.memory_dir()?;
        let path = dir.join(format!("{}.json", conversation_id));
        let json =
            serde_json::to_string_pretty(summaries).map_err(|e| ChatError::StorageError {
                message: format!("Failed to serialize memory index: {}", e),
            })?;
        fs::write(&path, json).map_err(|e| ChatError::StorageError {
            message: format!("Failed to write memory index: {}", e),
        })
    }

    pub fn load_memory_index(
        &self,
        conversation_id: &str,
    ) -> Result<Vec<MemorySummary>, ChatError> {
        let dir = self.memory_dir()?;
        let path = dir.join(format!("{}.json", conversation_id));
        if !path.exists() {
            return Ok(Vec::new());
        }
        let json = fs::read_to_string(&path).map_err(|e| ChatError::StorageError {
            message: format!("Failed to read memory index: {}", e),
        })?;
        serde_json::from_str(&json).map_err(|e| ChatError::StorageError {
            message: format!("Failed to parse memory index: {}", e),
        })
    }

    pub fn delete_memory_index(&self, conversation_id: &str) -> Result<(), ChatError> {
        let dir = self.memory_dir()?;
        let path = dir.join(format!("{}.json", conversation_id));
        if path.exists() {
            fs::remove_file(&path).map_err(|e| ChatError::StorageError {
                message: format!("Failed to delete memory index: {}", e),
            })?;
        }
        let _ = self.delete_distilled_state(conversation_id);
        Ok(())
    }

    pub fn load_distilled_state(
        &self,
        conversation_id: &str,
    ) -> Result<Option<DistilledSystemState>, ChatError> {
        let dir = self.memory_dir()?;
        let path = dir.join(format!("{}_distilled.json", conversation_id));
        if !path.exists() {
            return Ok(None);
        }
        let json = fs::read_to_string(&path).map_err(|e| ChatError::StorageError {
            message: format!("Failed to read distilled state: {}", e),
        })?;
        let state: DistilledSystemState =
            serde_json::from_str(&json).map_err(|e| ChatError::StorageError {
                message: format!("Failed to parse distilled state: {}", e),
            })?;
        Ok(Some(state))
    }

    pub fn save_distilled_state(
        &self,
        conversation_id: &str,
        state: &DistilledSystemState,
    ) -> Result<(), ChatError> {
        let dir = self.memory_dir()?;
        let path = dir.join(format!("{}_distilled.json", conversation_id));
        let json = serde_json::to_string_pretty(state).map_err(|e| ChatError::StorageError {
            message: format!("Failed to serialize distilled state: {}", e),
        })?;
        fs::write(&path, json).map_err(|e| ChatError::StorageError {
            message: format!("Failed to write distilled state: {}", e),
        })
    }

    pub fn delete_distilled_state(&self, conversation_id: &str) -> Result<(), ChatError> {
        let dir = self.memory_dir()?;
        let path = dir.join(format!("{}_distilled.json", conversation_id));
        if path.exists() {
            fs::remove_file(&path).map_err(|e| ChatError::StorageError {
                message: format!("Failed to delete distilled state: {}", e),
            })?;
        }
        Ok(())
    }
}

fn is_stop_word(word: &str) -> bool {
    matches!(
        word,
        "the"
            | "a"
            | "an"
            | "is"
            | "are"
            | "was"
            | "were"
            | "be"
            | "been"
            | "being"
            | "have"
            | "has"
            | "had"
            | "do"
            | "does"
            | "did"
            | "will"
            | "would"
            | "could"
            | "should"
            | "may"
            | "might"
            | "shall"
            | "can"
            | "to"
            | "of"
            | "in"
            | "for"
            | "on"
            | "with"
            | "at"
            | "by"
            | "from"
            | "as"
            | "into"
            | "through"
            | "during"
            | "before"
            | "after"
            | "above"
            | "below"
            | "between"
            | "and"
            | "but"
            | "or"
            | "not"
            | "no"
            | "nor"
            | "so"
            | "yet"
            | "both"
            | "it"
            | "its"
            | "this"
            | "that"
            | "these"
            | "those"
            | "he"
            | "she"
            | "we"
            | "they"
            | "me"
            | "him"
            | "her"
            | "us"
            | "them"
            | "my"
            | "your"
            | "his"
            | "our"
            | "their"
            | "if"
            | "then"
            | "的"
            | "了"
            | "在"
            | "是"
            | "我"
            | "有"
            | "和"
            | "就"
            | "不"
            | "人"
            | "都"
            | "一"
            | "一个"
            | "上"
            | "也"
            | "很"
            | "到"
            | "说"
            | "要"
            | "去"
            | "你"
            | "会"
            | "着"
            | "没有"
            | "看"
            | "好"
            | "自己"
            | "这"
            | "他"
            | "她"
            | "它"
            | "吗"
            | "呢"
            | "吧"
            | "啊"
            | "哦"
            | "嗯"
            | "呀"
            | "哈"
            | "嘛"
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_should_summarize() {
        assert!(!MemoryEngine::should_summarize(0));
        assert!(!MemoryEngine::should_summarize(5));
        assert!(!MemoryEngine::should_summarize(8));
        assert!(!MemoryEngine::should_summarize(15));
        assert!(MemoryEngine::should_summarize(10));
        assert!(MemoryEngine::should_summarize(20));
        assert!(MemoryEngine::should_summarize(30));
    }

    #[test]
    fn test_extract_keywords() {
        let kw = MemoryEngine::extract_keywords("Hello world, this is a test");
        assert!(kw.contains(&"hello".to_string()));
        assert!(kw.contains(&"world".to_string()));
        assert!(kw.contains(&"test".to_string()));
        assert!(!kw.contains(&"this".to_string()));
        assert!(!kw.contains(&"is".to_string()));
    }

    #[test]
    fn test_extract_keywords_chinese() {
        let kw = MemoryEngine::extract_keywords("你好世界");
        assert!(!kw.is_empty());
    }

    #[test]
    fn test_bm25_score_basic() {
        let query = vec!["hello".to_string(), "world".to_string()];
        let doc = vec!["hello".to_string(), "world".to_string(), "test".to_string()];
        let mut doc_freq = HashMap::new();
        doc_freq.insert("hello".to_string(), 1);
        doc_freq.insert("world".to_string(), 1);
        doc_freq.insert("test".to_string(), 1);

        let score = MemoryEngine::bm25_score(&query, &doc, 3.0, 1, &doc_freq);
        assert!(score > 0.0);
    }

    #[test]
    fn test_keyword_cosine_similarity() {
        let a = vec!["hello".to_string(), "world".to_string()];
        let b = vec!["hello".to_string(), "world".to_string()];
        let sim = MemoryEngine::keyword_cosine_similarity(&a, &b);
        assert!((sim - 1.0).abs() < 0.001);

        let c = vec!["foo".to_string(), "bar".to_string()];
        let sim2 = MemoryEngine::keyword_cosine_similarity(&a, &c);
        assert!((sim2 - 0.0).abs() < 0.001);
    }

    #[test]
    fn test_weighted_rrf_fusion() {
        let bm25 = vec![(0, 1.0), (1, 0.5), (2, 0.3)];
        let semantic = vec![(1, 1.0), (0, 0.5), (2, 0.3)];
        let result = MemoryEngine::weighted_rrf_fusion(&bm25, &semantic, 0.6, 0.4, 60.0);
        assert!(!result.is_empty());
        let top_ids: Vec<usize> = result.iter().map(|(idx, _)| *idx).collect();
        assert!(top_ids.contains(&0));
        assert!(top_ids.contains(&1));
    }

    #[test]
    fn test_search_memories_empty() {
        let results = MemoryEngine::search_memories("hello", &[], 5);
        assert!(results.is_empty());
    }

    #[test]
    fn test_search_memories_basic() {
        let summaries = vec![
            MemorySummary {
                id: "1".to_string(),
                summary: "用户和AI讨论了编程话题".to_string(),
                core_facts: vec!["用户是程序员".to_string()],
                turn_range_start: 1,
                turn_range_end: 10,
                created_at: 0,
                keywords: vec!["编程".to_string(), "程序员".to_string()],
                compression_generation: 0,
                context_card: None,
                fact_tiers: vec![MemoryTier::Identity],
            },
            MemorySummary {
                id: "2".to_string(),
                summary: "用户询问了天气情况".to_string(),
                core_facts: vec!["用户在北京".to_string()],
                turn_range_start: 11,
                turn_range_end: 20,
                created_at: 0,
                keywords: vec!["天气".to_string(), "北京".to_string()],
                compression_generation: 0,
                context_card: None,
                fact_tiers: vec![MemoryTier::CurrentState],
            },
        ];

        let results = MemoryEngine::search_memories("编程", &summaries, 5);
        assert!(!results.is_empty());
        assert!(results[0].summary.contains("编程"));
    }
}
