use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;

use flutter_rust_bridge::frb;
use serde::{Deserialize, Serialize};

use super::data_models::*;
use super::error_handler::ChatError;
use super::memory_engine::MemoryEngine;

const FACT_SIMILARITY_THRESHOLD: f64 = 0.62;
const CONTEXT_DEDUP_SIMILARITY_THRESHOLD: f64 = 0.88;
const NON_CRITICAL_UPDATE_FLOOR: f64 = 0.55;
const MAX_RELATED_FACTS_IN_CONTEXT: usize = 12;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum FactCategory {
    Identity,
    Relationship,
    Preference,
    Event,
    CurrentState,
    Promise,
    Consensus,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Fact {
    pub id: String,
    pub content: String,
    pub category: FactCategory,
    pub source_turn: u32,
    pub created_at: i64,
    pub last_confirmed_at: i64,
    pub keywords: Vec<String>,
    pub entities: Vec<String>,
    pub confidence: f64,
    pub hit_count: u32,
    pub context_snippet: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct KnowledgeIndex {
    pub keyword_index: HashMap<String, Vec<String>>,
    pub entity_index: HashMap<String, Vec<String>>,
    pub category_index: HashMap<String, Vec<String>>,
}

#[derive(Debug, Clone)]
pub struct FactSearchResult {
    pub fact: Fact,
    pub relevance_score: f64,
}

#[frb(opaque)]
pub struct KnowledgeStore {
    base_path: String,
}

impl KnowledgeStore {
    pub fn new(base_path: &str) -> Self {
        Self {
            base_path: base_path.to_string(),
        }
    }

    fn knowledge_dir(&self) -> Result<PathBuf, ChatError> {
        let dir = PathBuf::from(&self.base_path).join("knowledge_base");
        if !dir.exists() {
            fs::create_dir_all(&dir).map_err(|e| ChatError::StorageError {
                message: format!("Failed to create knowledge directory: {}", e),
            })?;
        }
        Ok(dir)
    }

    fn facts_path(&self, conversation_id: &str) -> Result<PathBuf, ChatError> {
        Ok(self
            .knowledge_dir()?
            .join(format!("{}_facts.json", conversation_id)))
    }

    fn index_path(&self, conversation_id: &str) -> Result<PathBuf, ChatError> {
        Ok(self
            .knowledge_dir()?
            .join(format!("{}_index.json", conversation_id)))
    }

    pub fn save_facts(&self, conversation_id: &str, facts: &[Fact]) -> Result<(), ChatError> {
        let path = self.facts_path(conversation_id)?;
        let json = serde_json::to_string_pretty(facts).map_err(|e| ChatError::StorageError {
            message: format!("Failed to serialize facts: {}", e),
        })?;
        fs::write(&path, json).map_err(|e| ChatError::StorageError {
            message: format!("Failed to write facts: {}", e),
        })
    }

    pub fn load_facts(&self, conversation_id: &str) -> Result<Vec<Fact>, ChatError> {
        let path = self.facts_path(conversation_id)?;
        if !path.exists() {
            return Ok(Vec::new());
        }
        let json = fs::read_to_string(&path).map_err(|e| ChatError::StorageError {
            message: format!("Failed to read facts: {}", e),
        })?;
        serde_json::from_str(&json).map_err(|e| ChatError::StorageError {
            message: format!("Failed to parse facts: {}", e),
        })
    }

    pub fn add_facts(&self, conversation_id: &str, new_facts: Vec<Fact>) -> Result<(), ChatError> {
        let mut existing = self.load_facts(conversation_id)?;

        for new_fact in new_facts {
            let existing_idx = existing.iter().position(|f| {
                Self::facts_are_similar(&f.content, &new_fact.content)
                    || (f.category == new_fact.category
                        && f.category == FactCategory::CurrentState
                        && Self::entities_overlap(&f.entities, &new_fact.entities))
            });

            if let Some(idx) = existing_idx {
                let similarity =
                    Self::semantic_similarity_score(&existing[idx].content, &new_fact.content);

                let should_replace_content = Self::is_critical_category(&existing[idx].category)
                    || similarity >= NON_CRITICAL_UPDATE_FLOOR;

                if should_replace_content {
                    existing[idx].content = new_fact.content;
                    existing[idx].keywords = new_fact.keywords;
                    existing[idx].entities = new_fact.entities;
                    existing[idx].context_snippet = new_fact.context_snippet;
                }

                existing[idx].last_confirmed_at = new_fact.last_confirmed_at;
                existing[idx].confidence = (existing[idx].confidence + 0.1).min(1.0);
            } else {
                existing.push(new_fact);
            }
        }

        self.save_facts(conversation_id, &existing)?;
        self.rebuild_index(conversation_id, &existing)?;
        Ok(())
    }

    fn facts_are_similar(a: &str, b: &str) -> bool {
        Self::semantic_similarity_score(a, b) >= FACT_SIMILARITY_THRESHOLD
    }

    fn semantic_similarity_score(a: &str, b: &str) -> f64 {
        let norm_a = Self::normalize_fact_text(a);
        let norm_b = Self::normalize_fact_text(b);

        if norm_a.is_empty() || norm_b.is_empty() {
            return 0.0;
        }

        if norm_a == norm_b {
            return 1.0;
        }

        let kw_a = MemoryEngine::extract_keywords(&norm_a);
        let kw_b = MemoryEngine::extract_keywords(&norm_b);
        let kw_cos = MemoryEngine::keyword_cosine_similarity(&kw_a, &kw_b);

        let ngram_a = Self::char_ngrams(&norm_a, 2);
        let ngram_b = Self::char_ngrams(&norm_b, 2);
        let ngram_cos = MemoryEngine::keyword_cosine_similarity(&ngram_a, &ngram_b);

        let overlap = {
            let mut common = 0usize;
            for token in &kw_a {
                if kw_b.contains(token) {
                    common += 1;
                }
            }
            let denom = kw_a.len() + kw_b.len() - common;
            if denom == 0 {
                0.0
            } else {
                common as f64 / denom as f64
            }
        };

        let containment_boost = if norm_a.contains(&norm_b) || norm_b.contains(&norm_a) {
            0.08
        } else {
            0.0
        };

        (kw_cos * 0.55 + ngram_cos * 0.35 + overlap * 0.10 + containment_boost).min(1.0)
    }

    fn normalize_fact_text(text: &str) -> String {
        let mut normalized = text.to_lowercase();
        let noise_words = [
            "一名", "一个", "一种", "这个", "那个", "这位", "那位", "非常", "比较", "有点", "真的",
        ];
        for word in noise_words {
            normalized = normalized.replace(word, "");
        }

        normalized
            .chars()
            .filter(|c| {
                !c.is_whitespace()
                    && !matches!(
                        c,
                        '，' | '。'
                            | '；'
                            | '：'
                            | '！'
                            | '？'
                            | ','
                            | '.'
                            | ';'
                            | ':'
                            | '!'
                            | '?'
                            | '"'
                            | '\''
                            | '（'
                            | '）'
                            | '('
                            | ')'
                            | '【'
                            | '】'
                            | '['
                            | ']'
                    )
            })
            .collect()
    }

    fn char_ngrams(text: &str, n: usize) -> Vec<String> {
        let chars: Vec<char> = text.chars().collect();
        if chars.is_empty() {
            return Vec::new();
        }
        if chars.len() < n {
            return vec![text.to_string()];
        }

        chars
            .windows(n)
            .map(|w| w.iter().collect::<String>())
            .collect()
    }

    fn is_critical_category(category: &FactCategory) -> bool {
        matches!(
            category,
            FactCategory::Identity
                | FactCategory::Promise
                | FactCategory::Relationship
                | FactCategory::Event
        )
    }

    fn entities_overlap(a: &[String], b: &[String]) -> bool {
        a.iter().any(|ea| b.iter().any(|eb| ea == eb))
    }

    fn rebuild_index(&self, conversation_id: &str, facts: &[Fact]) -> Result<(), ChatError> {
        let mut keyword_index: HashMap<String, Vec<String>> = HashMap::new();
        let mut entity_index: HashMap<String, Vec<String>> = HashMap::new();
        let mut category_index: HashMap<String, Vec<String>> = HashMap::new();

        for fact in facts {
            for kw in &fact.keywords {
                keyword_index
                    .entry(kw.clone())
                    .or_default()
                    .push(fact.id.clone());
            }
            for entity in &fact.entities {
                entity_index
                    .entry(entity.clone())
                    .or_default()
                    .push(fact.id.clone());
            }
            let cat_key = format!("{:?}", fact.category);
            category_index
                .entry(cat_key)
                .or_default()
                .push(fact.id.clone());
        }

        let index = KnowledgeIndex {
            keyword_index,
            entity_index,
            category_index,
        };

        let path = self.index_path(conversation_id)?;
        let json = serde_json::to_string_pretty(&index).map_err(|e| ChatError::StorageError {
            message: format!("Failed to serialize index: {}", e),
        })?;
        fs::write(&path, json).map_err(|e| ChatError::StorageError {
            message: format!("Failed to write index: {}", e),
        })
    }

    pub fn search_facts(
        &self,
        conversation_id: &str,
        query: &str,
        top_k: usize,
    ) -> Vec<FactSearchResult> {
        let facts = match self.load_facts(conversation_id) {
            Ok(f) => f,
            Err(_) => return Vec::new(),
        };

        if facts.is_empty() {
            return Vec::new();
        }

        let query_keywords = MemoryEngine::extract_keywords(query);
        if query_keywords.is_empty() {
            return Self::get_priority_facts(&facts, top_k);
        }

        let total_docs = facts.len();
        let mut doc_freq: HashMap<String, usize> = HashMap::new();
        let mut all_doc_keywords: Vec<Vec<String>> = Vec::new();
        let mut total_len = 0usize;

        for fact in &facts {
            let mut doc_kw = fact.keywords.clone();
            doc_kw.extend(MemoryEngine::extract_keywords(&fact.content));
            doc_kw.extend(MemoryEngine::extract_keywords(&fact.context_snippet));
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
                let score = MemoryEngine::bm25_score(
                    &query_keywords,
                    doc_kw,
                    avg_doc_len,
                    total_docs,
                    &doc_freq,
                );
                let category_boost = Self::category_weight(&facts[i].category);
                let confidence_boost = 0.5 + facts[i].confidence * 0.5;
                (i, score * category_boost * confidence_boost)
            })
            .collect();
        bm25_scores.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));

        let mut semantic_scores: Vec<(usize, f64)> = all_doc_keywords
            .iter()
            .enumerate()
            .map(|(i, doc_kw)| {
                let score = MemoryEngine::keyword_cosine_similarity(&query_keywords, doc_kw);
                let category_boost = Self::category_weight(&facts[i].category);
                (i, score * category_boost)
            })
            .collect();
        semantic_scores.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));

        let fused =
            MemoryEngine::weighted_rrf_fusion(&bm25_scores, &semantic_scores, 0.55, 0.45, 60.0);

        fused
            .into_iter()
            .take(top_k)
            .filter(|(_, score)| *score > 0.0)
            .map(|(idx, score)| FactSearchResult {
                fact: facts[idx].clone(),
                relevance_score: score,
            })
            .collect()
    }

    fn get_priority_facts(facts: &[Fact], top_k: usize) -> Vec<FactSearchResult> {
        let mut priority: Vec<&Fact> = facts
            .iter()
            .filter(|f| {
                matches!(
                    f.category,
                    FactCategory::Identity | FactCategory::Promise | FactCategory::Relationship
                )
            })
            .collect();
        priority.sort_by(|a, b| {
            b.confidence
                .partial_cmp(&a.confidence)
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        priority
            .into_iter()
            .take(top_k)
            .map(|f| FactSearchResult {
                fact: f.clone(),
                relevance_score: 1.0,
            })
            .collect()
    }

    pub fn get_all_facts(&self, conversation_id: &str) -> Vec<Fact> {
        self.load_facts(conversation_id).unwrap_or_default()
    }

    fn category_weight(category: &FactCategory) -> f64 {
        match category {
            FactCategory::Identity => 2.0,
            FactCategory::Promise => 1.8,
            FactCategory::Relationship => 1.6,
            FactCategory::Event => 1.4,
            FactCategory::Preference => 1.2,
            FactCategory::Consensus => 1.1,
            FactCategory::CurrentState => 1.0,
        }
    }

    pub fn parse_extracted_facts(json_text: &str, turn: u32) -> Vec<Fact> {
        let json_str = if let Some(start) = json_text.find('[') {
            if let Some(end) = json_text.rfind(']') {
                &json_text[start..=end]
            } else {
                json_text
            }
        } else if let Some(start) = json_text.find('{') {
            if let Some(end) = json_text.rfind('}') {
                let obj_str = &json_text[start..=end];
                if let Ok(obj) = serde_json::from_str::<serde_json::Value>(obj_str) {
                    if let Some(arr) = obj.get("facts").and_then(|v| v.as_array()) {
                        return Self::parse_fact_array(arr, turn);
                    }
                }
                obj_str
            } else {
                json_text
            }
        } else {
            return Vec::new();
        };

        if let Ok(arr) = serde_json::from_str::<Vec<serde_json::Value>>(json_str) {
            Self::parse_fact_array(&arr, turn)
        } else {
            Vec::new()
        }
    }

    fn parse_fact_array(arr: &[serde_json::Value], turn: u32) -> Vec<Fact> {
        let now = chrono::Utc::now().timestamp_millis();
        arr.iter()
            .filter_map(|item| {
                let content = item
                    .get("content")
                    .or_else(|| item.get("fact"))
                    .and_then(|v| v.as_str())?
                    .to_string();

                let category_str = item
                    .get("category")
                    .or_else(|| item.get("type"))
                    .and_then(|v| v.as_str())
                    .unwrap_or("event");

                let category = match category_str.to_lowercase().as_str() {
                    "identity" | "身份" => FactCategory::Identity,
                    "relationship" | "关系" => FactCategory::Relationship,
                    "preference" | "偏好" | "习惯" => FactCategory::Preference,
                    "event" | "事件" => FactCategory::Event,
                    "state" | "状态" | "current_state" => FactCategory::CurrentState,
                    "promise" | "承诺" | "约定" => FactCategory::Promise,
                    "consensus" | "共识" => FactCategory::Consensus,
                    _ => FactCategory::Event,
                };

                let entities: Vec<String> = item
                    .get("entities")
                    .and_then(|v| v.as_array())
                    .map(|a| {
                        a.iter()
                            .filter_map(|v| v.as_str().map(|s| s.to_string()))
                            .collect()
                    })
                    .unwrap_or_default();

                let context = item
                    .get("context")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();

                let keywords = MemoryEngine::extract_keywords(&content);

                Some(Fact {
                    id: uuid::Uuid::new_v4().to_string(),
                    content,
                    category,
                    source_turn: turn,
                    created_at: now,
                    last_confirmed_at: now,
                    keywords,
                    entities,
                    confidence: 0.8,
                    hit_count: 0,
                    context_snippet: context,
                })
            })
            .collect()
    }

    pub fn build_fact_extraction_prompt(
        recent_messages: &[Message],
        existing_facts: &[Fact],
    ) -> String {
        let mut prompt = String::new();

        prompt.push_str("【事实提取任务】\n");
        prompt.push_str("从以下对话中提取所有可以作为持久化知识存储的事实。\n\n");

        if !existing_facts.is_empty() {
            prompt.push_str("【已存储的事实（不要重复）】\n");
            for (i, fact) in existing_facts.iter().take(20).enumerate() {
                prompt.push_str(&format!(
                    "{}. [{}] {}\n",
                    i + 1,
                    Self::category_label(&fact.category),
                    fact.content
                ));
            }
            prompt.push('\n');
        }

        prompt.push_str("【最近对话】\n");
        for msg in recent_messages {
            let role = match msg.role {
                MessageRole::User => "用户",
                MessageRole::Assistant => "AI角色",
                MessageRole::System => continue,
            };
            prompt.push_str(&format!("{}: {}\n", role, msg.content));
        }

        prompt.push_str(
            r#"
请提取新的事实（已存储的不要重复），输出JSON数组：
[
  {
    "content": "事实内容（三元组编码：主体→关系→客体）",
    "category": "identity/relationship/preference/event/state/promise/consensus",
    "entities": ["涉及的实体名"],
    "context": "该事实出现时的对话上下文（简短引用原文）"
  }
]

提取规则：
1. 只提取确定性事实，不提取推测、氛围描写
2. 身份信息(identity)：姓名、年龄、职业等不可变属性
3. 关系(relationship)：人物间的关系定义或变化
4. 偏好(preference)：喜好、习惯、口癖等
5. 事件(event)：已确认发生的关键事件
6. 状态(state)：当前情绪、位置等（会被新状态覆盖）
7. 承诺(promise)：双方做出的承诺、约定
8. 共识(consensus)：双方达成的一致看法
9. 每条事实≤30字，信息密度优先
10. 如果没有新事实可提取，输出空数组 []
只输出JSON"#,
        );

        prompt
    }

    fn category_label(category: &FactCategory) -> &'static str {
        match category {
            FactCategory::Identity => "身份",
            FactCategory::Relationship => "关系",
            FactCategory::Preference => "偏好",
            FactCategory::Event => "事件",
            FactCategory::CurrentState => "状态",
            FactCategory::Promise => "承诺",
            FactCategory::Consensus => "共识",
        }
    }

    pub fn build_knowledge_context(
        search_results: &[FactSearchResult],
        all_identity_facts: &[Fact],
    ) -> String {
        if search_results.is_empty() && all_identity_facts.is_empty() {
            return String::new();
        }

        let mut context = String::from("【本地知识库 — 已确认事实，必须严格遵守】\n");

        if !all_identity_facts.is_empty() {
            context.push_str("▸ 不可变事实：\n");
            for fact in all_identity_facts {
                context.push_str(&format!(
                    "  ● [{}] {}\n",
                    Self::category_label(&fact.category),
                    fact.content
                ));
            }
        }

        if !search_results.is_empty() {
            context.push_str("▸ 与当前话题相关的事实：\n");

            let mut selected: Vec<&FactSearchResult> = Vec::new();
            for candidate in search_results {
                if Self::is_critical_category(&candidate.fact.category) {
                    selected.push(candidate);
                    continue;
                }

                let duplicated = selected.iter().any(|existing| {
                    !Self::is_critical_category(&existing.fact.category)
                        && Self::semantic_similarity_score(
                            &existing.fact.content,
                            &candidate.fact.content,
                        ) >= CONTEXT_DEDUP_SIMILARITY_THRESHOLD
                });

                if !duplicated {
                    selected.push(candidate);
                }

                if selected.len() >= MAX_RELATED_FACTS_IN_CONTEXT {
                    break;
                }
            }

            for result in selected {
                context.push_str(&format!(
                    "  · [{}] {} (相关:{:.2}, 置信:{:.0}%)\n",
                    Self::category_label(&result.fact.category),
                    result.fact.content,
                    result.relevance_score,
                    result.fact.confidence * 100.0
                ));
                if !result.fact.context_snippet.is_empty() {
                    context.push_str(&format!("    ↳ 来源: {}\n", result.fact.context_snippet));
                }
            }
        }

        context
            .push_str("\n以上知识库事实是已经确认的信息，回复时必须与之一致，不得矛盾或编造。\n");

        context
    }

    pub fn delete_knowledge(&self, conversation_id: &str) -> Result<(), ChatError> {
        let facts_path = self.facts_path(conversation_id)?;
        let index_path = self.index_path(conversation_id)?;
        if facts_path.exists() {
            fs::remove_file(&facts_path).map_err(|e| ChatError::StorageError {
                message: format!("Failed to delete facts: {}", e),
            })?;
        }
        if index_path.exists() {
            fs::remove_file(&index_path).map_err(|e| ChatError::StorageError {
                message: format!("Failed to delete index: {}", e),
            })?;
        }
        Ok(())
    }

    pub fn record_hits(&self, conversation_id: &str, fact_ids: &[String]) -> Result<(), ChatError> {
        let mut facts = self.load_facts(conversation_id)?;
        for fact in &mut facts {
            if fact_ids.contains(&fact.id) {
                fact.hit_count += 1;
                fact.last_confirmed_at = chrono::Utc::now().timestamp_millis();
            }
        }
        self.save_facts(conversation_id, &facts)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_category_weight() {
        assert!(
            KnowledgeStore::category_weight(&FactCategory::Identity)
                > KnowledgeStore::category_weight(&FactCategory::CurrentState)
        );
    }

    #[test]
    fn test_facts_are_similar() {
        assert!(KnowledgeStore::facts_are_similar(
            "用户→是→程序员",
            "用户→是→一名程序员"
        ));
        assert!(!KnowledgeStore::facts_are_similar(
            "用户→喜欢→猫",
            "用户→讨厌→下雨"
        ));
    }

    #[test]
    fn test_parse_extracted_facts() {
        let json = r#"[
            {"content": "用户→是→程序员", "category": "identity", "entities": ["用户"], "context": "用户说我是程序员"},
            {"content": "用户→喜欢→Rust", "category": "preference", "entities": ["用户", "Rust"], "context": "用户提到喜欢Rust"}
        ]"#;
        let facts = KnowledgeStore::parse_extracted_facts(json, 5);
        assert_eq!(facts.len(), 2);
        assert_eq!(facts[0].category, FactCategory::Identity);
        assert_eq!(facts[1].category, FactCategory::Preference);
    }

    #[test]
    fn test_parse_facts_wrapped_object() {
        let json = r#"{"facts": [{"content": "测试事实", "category": "event"}]}"#;
        let facts = KnowledgeStore::parse_extracted_facts(json, 1);
        assert_eq!(facts.len(), 1);
    }

    #[test]
    fn test_parse_facts_empty() {
        let facts = KnowledgeStore::parse_extracted_facts("[]", 1);
        assert!(facts.is_empty());
    }

    #[test]
    fn test_build_knowledge_context_empty() {
        let ctx = KnowledgeStore::build_knowledge_context(&[], &[]);
        assert!(ctx.is_empty());
    }

    #[test]
    fn test_build_knowledge_context_with_facts() {
        let fact = Fact {
            id: "1".to_string(),
            content: "用户→是→程序员".to_string(),
            category: FactCategory::Identity,
            source_turn: 1,
            created_at: 0,
            last_confirmed_at: 0,
            keywords: vec!["用户".to_string(), "程序员".to_string()],
            entities: vec!["用户".to_string()],
            confidence: 0.9,
            hit_count: 0,
            context_snippet: "用户自我介绍".to_string(),
        };
        let ctx = KnowledgeStore::build_knowledge_context(&[], &[fact]);
        assert!(ctx.contains("不可变事实"));
        assert!(ctx.contains("程序员"));
    }
}
