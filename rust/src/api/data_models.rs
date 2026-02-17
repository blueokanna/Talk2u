use flutter_rust_bridge::frb;
use serde::{Deserialize, Serialize};

/// 聊天流事件 - 通过 flutter_rust_bridge Stream 传递给 Flutter
#[frb]
#[derive(Debug, Clone)]
pub enum ChatStreamEvent {
    /// 正常内容增量
    ContentDelta(String),
    /// 思考内容增量
    ThinkingDelta(String),
    /// 流结束
    Done,
    /// 错误
    Error(String),
}

/// 消息类型标记：say（对话）或 do（动作/旁白）
#[frb]
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub enum MessageType {
    Say,
    Do,
    Mixed, // 同时包含 say 和 do
}

impl Default for MessageType {
    fn default() -> Self {
        MessageType::Say
    }
}

/// 单条消息
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

/// 消息角色
#[frb]
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub enum MessageRole {
    User,
    Assistant,
    System,
}

/// 对话风格
#[frb]
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub enum DialogueStyle {
    /// 默认自由对话
    Free,
    /// 纯对话模式（say only）
    SayOnly,
    /// 纯动作/旁白模式（do only）
    DoOnly,
    /// 混合模式（say + do 自动识别）
    Mixed,
}

impl Default for DialogueStyle {
    fn default() -> Self {
        DialogueStyle::Mixed
    }
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

/// 记忆摘要条目
#[frb]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MemorySummary {
    pub id: String,
    pub summary: String,
    /// 核心身份/事件等不可变信息
    pub core_facts: Vec<String>,
    /// 涵盖的消息范围 [start_turn, end_turn]
    pub turn_range_start: u32,
    pub turn_range_end: u32,
    pub created_at: i64,
    /// BM25 关键词索引
    pub keywords: Vec<String>,
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

/// 应用设置
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

/// 模型信息
#[frb]
#[derive(Debug, Clone)]
pub struct ModelInfo {
    pub id: String,
    pub name: String,
    pub context_tokens: usize,
    pub supports_thinking: bool,
}

/// 记忆检索结果
#[frb]
#[derive(Debug, Clone)]
pub struct MemorySearchResult {
    pub summary: String,
    pub core_facts: Vec<String>,
    pub relevance_score: f64,
}
