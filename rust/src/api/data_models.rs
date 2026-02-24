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
    /// 压缩代数：每次被合并/压缩时 +1，代数越高信息损耗风险越大
    #[serde(default)]
    pub compression_generation: u32,
    /// 上下文增强卡片 — 结构化元信息，提升检索精度
    #[serde(default)]
    pub context_card: Option<MemoryContextCard>,
    /// 每条核心事实的排级分类，与 core_facts 一一对应
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
    /// 无损：所有信息完整保留
    Lossless,
    /// 风格微调：语气、表达习惯可能轻微变化
    StyleDrift,
    /// 性格模糊：性格细节开始模糊
    PersonalityFade,
    /// 细节丢失：金钱数值、次要关系等可能不精确
    DetailLoss,
    /// 深度退化：身份边缘属性可能受影响
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
    /// 最大输入上下文 token 数
    pub context_tokens: usize,
    /// 最大输出 token 数
    pub max_output_tokens: usize,
    pub supports_thinking: bool,
}

/// 记忆上下文增强卡片 — 为每条记忆附加结构化元信息
/// 参考智谱上下文增强技术：为知识切片"恢复记忆"
/// 包含来源信息、主题概括、关键实体、歧义消除
#[frb]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MemoryContextCard {
    /// 来源：涵盖的轮次范围描述
    pub source_range: String,
    /// 主题标签（1-3个关键词）
    pub topic_tags: Vec<String>,
    /// 关键实体（人物、地点、物品等）
    pub key_entities: Vec<String>,
    /// 情感基调（正/负/中性 + 强度）
    pub emotional_tone: String,
    /// 因果关联：与其他记忆的关联描述
    pub causal_links: Vec<String>,
}

/// 分级压缩排级 — 类似军队排级的信息优先级
/// 当记忆条目过多需要二次压缩时，按排级决定保留优先级
#[frb]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum MemoryTier {
    /// 最高级：身份锚点（姓名、核心设定、与用户关系）— 永不丢弃
    Identity,
    /// 高级：不可逆事件（关键转折、承诺、约定）— 极少丢弃
    CriticalEvent,
    /// 中级：关系动态（亲密度变化、信任变化）— 可合并但不丢弃
    RelationshipDynamic,
    /// 普通：状态信息（当前情绪、物理状态）— 可被最新状态覆盖
    CurrentState,
    /// 低级：场景细节（氛围、环境描写）— 可安全丢弃
    SceneDetail,
}

/// 记忆检索结果
#[frb]
#[derive(Debug, Clone)]
pub struct MemorySearchResult {
    pub summary: String,
    pub core_facts: Vec<String>,
    pub relevance_score: f64,
}
