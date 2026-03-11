use super::data_models::{LogEntry, LogLevel};
use std::collections::VecDeque;
use std::sync::Mutex;

const MAX_LOG_ENTRIES: usize = 500;

static LOG_BUFFER: Mutex<Option<VecDeque<LogEntry>>> = Mutex::new(None);

static LOGGER: ChatLogger = ChatLogger;

struct ChatLogger;

impl log::Log for ChatLogger {
    fn enabled(&self, metadata: &log::Metadata) -> bool {
        metadata.target().starts_with("rust_lib_talk2u")
    }

    fn log(&self, record: &log::Record) {
        if !self.enabled(record.metadata()) {
            return;
        }

        let level = match record.level() {
            log::Level::Error => LogLevel::Error,
            log::Level::Warn => LogLevel::Warning,
            _ => LogLevel::Info,
        };

        let entry = LogEntry {
            timestamp: chrono::Utc::now().timestamp_millis(),
            level,
            module: record.target().to_string(),
            message: record.args().to_string(),
        };

        if let Ok(mut guard) = LOG_BUFFER.lock() {
            let buffer = guard.get_or_insert_with(|| VecDeque::with_capacity(MAX_LOG_ENTRIES));
            if buffer.len() >= MAX_LOG_ENTRIES {
                buffer.pop_front();
            }
            buffer.push_back(entry);
        }
    }

    fn flush(&self) {}
}

/// 初始化日志系统。在 init_app 中调用一次。
pub fn init_logger() {
    let _ = log::set_logger(&LOGGER).map(|()| log::set_max_level(log::LevelFilter::Info));
}

/// 获取日志条目。
/// - `level_filter`: 按级别过滤（None = 全部，Info = 全部，Warning = Warning+Error，Error = 仅Error）
/// - `limit`: 返回条数上限
pub fn get_logs(level_filter: Option<LogLevel>, limit: usize) -> Vec<LogEntry> {
    let guard = match LOG_BUFFER.lock() {
        Ok(g) => g,
        Err(_) => return Vec::new(),
    };
    let buffer = match guard.as_ref() {
        Some(b) => b,
        None => return Vec::new(),
    };

    let filtered: Vec<LogEntry> = buffer
        .iter()
        .filter(|entry| match &level_filter {
            None => true,
            Some(LogLevel::Info) => true,
            Some(LogLevel::Warning) => {
                matches!(entry.level, LogLevel::Warning | LogLevel::Error)
            }
            Some(LogLevel::Error) => entry.level == LogLevel::Error,
        })
        .rev()
        .take(limit)
        .cloned()
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .collect();

    filtered
}

/// 清空日志缓冲区
pub fn clear_logs() {
    if let Ok(mut guard) = LOG_BUFFER.lock() {
        if let Some(buffer) = guard.as_mut() {
            buffer.clear();
        }
    }
}
