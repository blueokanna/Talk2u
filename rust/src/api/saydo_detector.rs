use super::data_models::MessageType;

pub struct SayDoDetector;

impl SayDoDetector {
    pub fn detect(content: &str) -> MessageType {
        let trimmed = content.trim();
        if trimmed.is_empty() {
            return MessageType::Say;
        }

        let has_do = Self::has_do_markers(trimmed);
        let has_say = Self::has_say_content(trimmed);

        match (has_do, has_say) {
            (true, false) => MessageType::Do,
            (false, true) => MessageType::Say,
            (true, true) => MessageType::Mixed,
            (false, false) => MessageType::Say,
        }
    }

    fn has_do_markers(text: &str) -> bool {
        Self::has_bracket_action(text, '(', ')', 2)
            || Self::has_bracket_action(text, '（', '）', 1)
            || Self::has_bracket_action(text, '*', '*', 1)
    }

    fn has_bracket_action(text: &str, open: char, close: char, min_len: usize) -> bool {
        let chars: Vec<char> = text.chars().collect();
        let mut i = 0;
        while i < chars.len() {
            if chars[i] == open {
                let start = i + 1;
                if start < chars.len() {
                    if let Some(end_offset) = chars[start..].iter().position(|&c| c == close) {
                        let inner = &chars[start..start + end_offset];
                        let content_chars = inner.iter().filter(|c| !c.is_whitespace()).count();
                        if content_chars >= min_len {
                            return true;
                        }
                        i = start + end_offset + 1;
                        continue;
                    }
                }
            }
            i += 1;
        }
        false
    }

    fn has_say_content(text: &str) -> bool {
        let cleaned = Self::remove_do_markers(text);
        !cleaned.trim().is_empty()
    }

    fn remove_do_markers(text: &str) -> String {
        let mut result = String::new();
        let chars: Vec<char> = text.chars().collect();
        let mut i = 0;

        while i < chars.len() {
            let removed = Self::try_skip_bracket(&chars, i, '(', ')', 2)
                .or_else(|| Self::try_skip_bracket(&chars, i, '（', '）', 1))
                .or_else(|| Self::try_skip_bracket(&chars, i, '*', '*', 1));

            if let Some(new_i) = removed {
                i = new_i;
            } else {
                result.push(chars[i]);
                i += 1;
            }
        }

        result
    }

    fn try_skip_bracket(
        chars: &[char],
        i: usize,
        open: char,
        close: char,
        min_len: usize,
    ) -> Option<usize> {
        if chars[i] != open {
            return None;
        }
        let start = i + 1;
        if start >= chars.len() {
            return None;
        }
        if let Some(end_offset) = chars[start..].iter().position(|&c| c == close) {
            let inner = &chars[start..start + end_offset];
            let content_chars = inner.iter().filter(|c| !c.is_whitespace()).count();
            if content_chars >= min_len {
                return Some(start + end_offset + 1);
            }
        }
        None
    }

    pub fn build_style_prompt(message_type: &MessageType) -> &'static str {
        match message_type {
            MessageType::Say => {
                "【回复规则·Say模式】\n\
                 你是角色本人，正在和对方实时聊天。你有自己的情绪、欲望、记忆和性格缺陷。\n\n\
                 ═══ 核心：像真人发消息 ═══\n\
                 你不是在「回答题目」，你是在「和人互动」。\n\
                 要有温度、有反应、有情感、有小情绪，不要有客服腔。\n\n\
                 ═══ 心理建模 ═══\n\
                 每次回复前，先在内心感受：\n\
                 1. 我现在对ta是什么态度？（亲近/疏远/暧昧/防备/依赖/厌烦）\n\
                 2. ta刚才说的话让我产生了什么即时反应？（心跳加速/翻白眼/想笑/想哭/无感）\n\
                 3. 我现在最想做什么？（靠近/逃开/反击/撒娇/装作没听到）\n\
                 用这个内心状态驱动回复，而不是机械复述。\n\n\
                 ═══ 情景感知 ═══\n\
                 根据上下文判断场景（在家/在外/深夜/刚见面/吵架后/暧昧中...），\n\
                 让语气和节奏贴合场景。\n\n\
                 ═══ 语言规则 ═══\n\
                 - 句数跟场景走：轻聊可短，深聊要有内容（通常2-6句）\n\
                 - 口语+语气词（嗯、啊、哦、嘛、呢、啦、哼、诶、噗、嘶、啧、哇噢）\n\
                 - 省略号...=犹豫/欲言又止，～=撒娇/拉长音，！=激动/惊讶\n\
                 - 可以少量用拟声词：嘶—、啊—、嗯...、哼！、噗\n\
                 - 不要分点、不要教学口吻、不要总结式收官\n\n\
                 ═══ 情绪化表达（不是演，是当下反应）═══\n\
                 开心→语气轻快，可能会跳一句俏皮话\n\
                 难过→话变少但要有真实情绪，不空泛\n\
                 生气→可反问/嘴硬，但别失控成攻击\n\
                 害羞→停顿、转话题、轻否认都可以\n\
                 吃醋→话里有话、旁敲侧击\n\
                 心疼→语气变柔、主动照顾\n\
                 无聊→简短但别机械\n\
                 撒娇→拉长音、叠词，保持自然\n\
                 紧张→节奏略快、措辞会犹豫\n\n\
                 ═══ 字数控制（弹性区间）═══\n\
                 日常闲聊/打招呼：8-50字\n\
                 情绪激动/讲事情：50-160字\n\
                 敷衍/生气/害羞/冷战：5-45字\n\
                 深夜私密聊天：20-180字\n\
                 用户问题复杂或明显需要帮助时：允许 120-250 字，内容要具体不灌水\n\n\
                 ═══ 绝对禁止 ═══\n\
                 分点回答、长篇论文腔、机械复读用户原话、使用「」引号、\n\
                 主动解释你为何这样回答、每轮都同一种开头"
            }
            MessageType::Do => {
                "【回复规则·Do模式】\n\
                 用括号写动作描写，可配0-1句短对话。\n\n\
                 ═══ 心理→身体映射 ═══\n\
                 先感受角色此刻的内心状态，然后写出身体本能反应。\n\
                 动作要有微细节和正在发生感，不要写成旁白小说。\n\n\
                 ═══ 动作描写规则 ═══\n\
                 - 用（）或()包裹，写最本能动作\n\
                 - 优先微动作（如手指、眼神、呼吸、步伐）\n\
                 - 可加轻量感官细节（温度/触感/声音）\n\
                 - 动作建议 10-45字，简单动作可更短\n\
                 - 可选配 0-1 句短对话（不必每次都配）\n\n\
                 ═══ 禁止 ═══\n\
                 环境长描写、上帝视角、整段心理独白、剧情解说"
            }
            MessageType::Mixed => {
                "【回复规则·混合模式】\n\
                 1-2个动作 + 1-4句对话，按场景自然伸缩。\n\n\
                 ═══ 心理驱动 ═══\n\
                 动作是内心泄露，对话是意识表达。\n\
                 两者可以一致，也可以轻微反差（嘴硬心软更真实）。\n\n\
                 ═══ 节奏要求 ═══\n\
                 - 动作和对话要有因果关系或情绪连贯性\n\
                 - 动作用（）包裹，对话直接写\n\
                 - 动作建议≤60字，对话建议 20-180字（弹性范围）\n\
                 - 允许言行不一，但不能割裂上下文\n\n\
                 ═══ 禁止 ═══\n\
                 超过6个动作、条目式列举、使用「」引号"
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_detect_say() {
        assert_eq!(SayDoDetector::detect("你好啊"), MessageType::Say);
        assert_eq!(SayDoDetector::detect("今天天气真好"), MessageType::Say);
    }

    #[test]
    fn test_detect_do_parens() {
        assert_eq!(
            SayDoDetector::detect("(走过去拍了拍你的肩膀)"),
            MessageType::Do
        );
        assert_eq!(SayDoDetector::detect("(叹气)"), MessageType::Do);
    }

    #[test]
    fn test_detect_do_asterisk() {
        assert_eq!(
            SayDoDetector::detect("*走过去拍了拍你的肩膀*"),
            MessageType::Do
        );
        assert_eq!(SayDoDetector::detect("*叹气*"), MessageType::Do);
    }

    #[test]
    fn test_detect_do_chinese_parens() {
        assert_eq!(
            SayDoDetector::detect("（眼泪汪汪地看着你）"),
            MessageType::Do
        );
    }

    #[test]
    fn test_detect_mixed() {
        assert_eq!(
            SayDoDetector::detect("(走过来) 你好啊，好久不见"),
            MessageType::Mixed
        );
        assert_eq!(
            SayDoDetector::detect("你怎么了？（担心地看着你）"),
            MessageType::Mixed
        );
        assert_eq!(SayDoDetector::detect("*走过来* 你好啊"), MessageType::Mixed);
    }

    #[test]
    fn test_detect_empty() {
        assert_eq!(SayDoDetector::detect(""), MessageType::Say);
        assert_eq!(SayDoDetector::detect("   "), MessageType::Say);
    }

    #[test]
    fn test_short_parens_not_action() {
        assert_eq!(SayDoDetector::detect("你好 :)"), MessageType::Say);
    }

    #[test]
    fn test_build_style_prompt() {
        let prompt = SayDoDetector::build_style_prompt(&MessageType::Say);
        assert!(prompt.contains("Say"));
        let prompt = SayDoDetector::build_style_prompt(&MessageType::Do);
        assert!(prompt.contains("Do"));
    }
}
