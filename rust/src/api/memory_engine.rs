use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;

use flutter_rust_bridge::frb;

use super::data_models::*;
use super::error_handler::ChatError;

/// 每 N 轮对话触发一次自动总结
const SUMMARIZE_INTERVAL: u32 = 10;

/// BM25 参数
const BM25_K1: f64 = 1.2;
const BM25_B: f64 = 0.75;

/// 记忆引擎：负责自动总结、BM25 检索、RRF 融合
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

    /// 检查是否需要触发自动总结
    pub fn should_summarize(turn_count: u32) -> bool {
        turn_count > 0 && turn_count % SUMMARIZE_INTERVAL == 0
    }

    /// 从消息中提取关键词（简易中文分词 + 英文分词）
    pub fn extract_keywords(text: &str) -> Vec<String> {
        let mut keywords = Vec::new();
        // 英文单词提取
        for word in text.split(|c: char| !c.is_alphanumeric() && c != '-' && c != '_') {
            let w = word.trim().to_lowercase();
            if w.len() >= 2 && !is_stop_word(&w) {
                keywords.push(w);
            }
        }
        // 中文 bigram 提取（简易方案，不依赖外部分词库）
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

    /// 构建总结请求的 prompt
    pub fn build_summarize_prompt(
        messages: &[Message],
        existing_summaries: &[MemorySummary],
        turn_start: u32,
        turn_end: u32,
    ) -> String {
        let mut prompt = String::new();

        // 注入已有的核心事实作为前置上下文
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

    /// 构建长对话双模型检查的 prompt（用 glm-4-long 做第一轮完整概括）
    pub fn build_long_summary_prompt(
        all_summaries: &[MemorySummary],
        recent_messages: &[Message],
    ) -> String {
        let mut prompt = String::new();
        prompt.push_str("整合以下所有记忆摘要为一份精炼总结。\n\n");

        prompt.push_str("【历史记忆】\n");
        for (i, s) in all_summaries.iter().enumerate() {
            prompt.push_str(&format!(
                "{}. [轮次{}-{}] {}\n  事实：{}\n",
                i + 1,
                s.turn_range_start,
                s.turn_range_end,
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

    /// 构建第二轮验证 prompt（用 GLM-4.7-Flash 检查）
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

        // 构建文档词频
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

            // IDF
            let idf = ((total_docs as f64 - df + 0.5) / (df + 0.5) + 1.0).ln();
            // TF normalization
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

        // 语义排名贡献
        for (rank, (doc_idx, _score)) in semantic_ranks.iter().enumerate() {
            let rrf = semantic_weight / (k + rank as f64 + 1.0);
            *fusion_scores.entry(*doc_idx).or_insert(0.0) += rrf;
        }

        let mut results: Vec<(usize, f64)> = fusion_scores.into_iter().collect();
        results.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
        results
    }

    /// 简易余弦相似度（基于关键词重叠，作为轻量级语义近似）
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
            doc_kw.extend(Self::extract_keywords(&summary.summary));
            for fact in &summary.core_facts {
                doc_kw.extend(Self::extract_keywords(fact));
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

        // RRF 融合（BM25 权重 0.6，语义权重 0.4）
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

    /// 加载记忆索引
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

    /// 删除对话的记忆索引
    pub fn delete_memory_index(&self, conversation_id: &str) -> Result<(), ChatError> {
        let dir = self.memory_dir()?;
        let path = dir.join(format!("{}.json", conversation_id));
        if path.exists() {
            fs::remove_file(&path).map_err(|e| ChatError::StorageError {
                message: format!("Failed to delete memory index: {}", e),
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
        assert!(MemoryEngine::should_summarize(10));
        assert!(MemoryEngine::should_summarize(20));
        assert!(!MemoryEngine::should_summarize(15));
    }

    #[test]
    fn test_extract_keywords() {
        let kw = MemoryEngine::extract_keywords("Hello world, this is a test");
        assert!(kw.contains(&"hello".to_string()));
        assert!(kw.contains(&"world".to_string()));
        assert!(kw.contains(&"test".to_string()));
        // stop words should be filtered
        assert!(!kw.contains(&"this".to_string()));
        assert!(!kw.contains(&"is".to_string()));
    }

    #[test]
    fn test_extract_keywords_chinese() {
        let kw = MemoryEngine::extract_keywords("你好世界");
        // Should have bigrams
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
        // Both doc 0 and doc 1 should be in top results
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
            },
            MemorySummary {
                id: "2".to_string(),
                summary: "用户询问了天气情况".to_string(),
                core_facts: vec!["用户在北京".to_string()],
                turn_range_start: 11,
                turn_range_end: 20,
                created_at: 0,
                keywords: vec!["天气".to_string(), "北京".to_string()],
            },
        ];

        let results = MemoryEngine::search_memories("编程", &summaries, 5);
        assert!(!results.is_empty());
        // 编程相关的应该排在前面
        assert!(results[0].summary.contains("编程"));
    }
}
