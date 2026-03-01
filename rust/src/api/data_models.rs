use flutter_rust_bridge::frb;
use serde::{Deserialize, Serialize};

#[frb]
#[derive(Debug, Clone)]
pub enum ChatStreamEvent {
    ContentDelta(String),
    ThinkingDelta(String),
    Done,
    Error(String),
}

#[derive(Default)]
#[frb]
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub enum MessageType {
    #[default]
    Say,
    Do,
    Mixed,
}


#[frb]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Message {
    pub id: String,
    pub role: MessageRole,
    pub content: String,
    pub thinking_content: Option<String>,
    pub model: String,
    pub timestamp: i64,
    #[serde(default)]
    pub message_type: MessageType,
}

#[frb]
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub enum MessageRole {
    User,
    Assistant,
    System,
}

#[derive(Default)]
#[frb]
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub enum DialogueStyle {
    Free,
    SayOnly,
    DoOnly,
    #[default]
    Mixed,
}


/// 对话
#[frb]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Conversation {
    pub id: String,
    pub title: String,
    pub messages: Vec<Message>,
    pub model: String,
    pub created_at: i64,
    pub updated_at: i64,
    #[serde(default)]
    pub dialogue_style: DialogueStyle,
    #[serde(default)]
    pub turn_count: u32,
    #[serde(default)]
    pub memory_summaries: Vec<MemorySummary>,
}

#[frb]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MemorySummary {
    pub id: String,
    pub summary: String,
    pub core_facts: Vec<String>,
    pub turn_range_start: u32,
    pub turn_range_end: u32,
    pub created_at: i64,
    pub keywords: Vec<String>,
    #[serde(default)]
    pub compression_generation: u32,
    #[serde(default)]
    pub context_card: Option<MemoryContextCard>,
    #[serde(default)]
    pub fact_tiers: Vec<MemoryTier>,
}

/// 压缩影响等级 — 随压缩代数递增，逐步影响不同维度
/// Gen 0-1: 无损（完整保留所有信息）
/// Gen 2-3: 语气/表达风格可能轻微偏移
/// Gen 4-5: 性格细节可能模糊（如口癖频率降低）
/// Gen 6-7: 次要关系/金钱等数值细节可能丢失
/// Gen 8+:  身份设定的边缘属性可能受影响（核心身份仍保留）
#[frb]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum CompressionImpactLevel {
    Lossless,
    StyleDrift,
    PersonalityFade,
    DetailLoss,
    IdentityErosion,
}

/// 对话摘要（用于列表展示）
#[frb]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ConversationSummary {
    pub id: String,
    pub title: String,
    pub last_message_preview: String,
    pub model: String,
    pub updated_at: i64,
}

#[frb]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AppSettings {
    pub api_key: Option<String>,
    pub default_model: String,
    pub enable_thinking_by_default: bool,
    #[serde(default = "default_chat_model")]
    pub chat_model: String,
    #[serde(default = "default_thinking_model")]
    pub thinking_model: String,
}

fn default_chat_model() -> String {
    "glm-4.7".to_string()
}

fn default_thinking_model() -> String {
    "glm-4-air".to_string()
}

impl Default for AppSettings {
    fn default() -> Self {
        Self {
            api_key: None,
            default_model: "glm-4.7".to_string(),
            enable_thinking_by_default: true,
            chat_model: "glm-4.7".to_string(),
            thinking_model: "glm-4-air".to_string(),
        }
    }
}

#[frb]
#[derive(Debug, Clone)]
pub struct ModelInfo {
    pub id: String,
    pub name: String,
    pub context_tokens: usize,
    pub max_output_tokens: usize,
    pub supports_thinking: bool,
}

#[frb]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MemoryContextCard {
    pub source_range: String,
    pub topic_tags: Vec<String>,
    pub key_entities: Vec<String>,
    pub emotional_tone: String,
    pub causal_links: Vec<String>,
}

#[frb]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum MemoryTier {
    Identity,
    CriticalEvent,
    RelationshipDynamic,
    CurrentState,
    SceneDetail,
}

#[frb]
#[derive(Debug, Clone)]
pub struct MemorySearchResult {
    pub summary: String,
    pub core_facts: Vec<String>,
    pub relevance_score: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DistilledSystemState {
    pub core_prompt: String,
    pub last_memory_count: usize,
    pub last_max_compression_gen: u32,
    pub character_prompt_hash: u64,
    pub last_turn_count: u32,
    pub distilled_at: i64,
    pub core_facts_snapshot: Vec<String>,
}
