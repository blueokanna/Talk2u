//! Incremental `text/event-stream` line splitting.
//!
//! The decoder owns the only piece of state a stream needs — bytes that arrived
//! without a terminating newline — so the request loop can stay a plain `for`
//! over complete lines. It also bounds that state: a peer that never sends a
//! newline would otherwise grow the buffer until the process dies.

use super::error_handler::ChatError;

/// One SSE line carries a single JSON delta. A line larger than this is not a
/// delta; buffering it is how a "long reply" becomes an out-of-memory kill.
const MAX_LINE_BYTES: usize = 256 * 1024;

#[derive(Default)]
pub(crate) struct SseDecoder {
    pending: Vec<u8>,
}

impl SseDecoder {
    /// Feeds raw bytes and returns every line that is now complete.
    ///
    /// Lines come back without their `\n` and without a trailing `\r`, so a
    /// CRLF sender and an LF sender produce identical input for the parser.
    pub(crate) fn push(&mut self, chunk: &[u8]) -> Result<Vec<String>, ChatError> {
        self.pending.extend_from_slice(chunk);
        let mut lines = Vec::new();
        while let Some(position) = self.pending.iter().position(|byte| *byte == b'\n') {
            let mut line: Vec<u8> = self.pending.drain(..=position).collect();
            line.pop();
            if line.last() == Some(&b'\r') {
                line.pop();
            }
            lines.push(decode_line(line)?);
        }
        if self.pending.len() > MAX_LINE_BYTES {
            self.pending.clear();
            return Err(ChatError::StreamError {
                message: format!(
                    "服务端返回了超过 {} KiB 且没有换行的单行数据，已中断以避免内存耗尽",
                    MAX_LINE_BYTES / 1024
                ),
            });
        }
        Ok(lines)
    }

    /// Whatever is left when the peer closes. A final line without a newline is
    /// valid SSE and must not be dropped.
    pub(crate) fn finish(&mut self) -> Result<Option<String>, ChatError> {
        if self.pending.is_empty() {
            return Ok(None);
        }
        let mut line = std::mem::take(&mut self.pending);
        if line.last() == Some(&b'\r') {
            line.pop();
        }
        let line = decode_line(line)?;
        let trimmed = line.trim();
        if trimmed.is_empty() {
            return Ok(None);
        }
        Ok(Some(trimmed.to_string()))
    }
}

fn decode_line(line: Vec<u8>) -> Result<String, ChatError> {
    String::from_utf8(line).map_err(|error| ChatError::StreamError {
        message: format!(
            "SSE 返回了无效的 UTF-8（第 {} 字节出错），已中断以免把乱码写入对话",
            error.utf8_error().valid_up_to()
        ),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn push(decoder: &mut SseDecoder, chunk: &str) -> Vec<String> {
        decoder.push(chunk.as_bytes()).expect("decodes")
    }

    #[test]
    fn joins_frames_split_across_chunks() {
        let mut decoder = SseDecoder::default();
        assert!(push(&mut decoder, "data: {\"a\":1}").is_empty());
        assert_eq!(push(&mut decoder, "\n\ndata: [DO"), vec!["data: {\"a\":1}", ""]);
        assert_eq!(push(&mut decoder, "NE]\n\n"), vec!["data: [DONE]", ""]);
    }

    #[test]
    fn strips_carriage_returns() {
        let mut decoder = SseDecoder::default();
        assert_eq!(
            push(&mut decoder, "data: a\r\ndata: b\r\n"),
            vec!["data: a", "data: b"]
        );
    }

    #[test]
    fn keeps_a_final_line_without_a_newline() {
        let mut decoder = SseDecoder::default();
        assert!(push(&mut decoder, "data: tail").is_empty());
        assert_eq!(decoder.finish().unwrap().as_deref(), Some("data: tail"));
        assert!(decoder.finish().unwrap().is_none(), "finish is idempotent");
    }

    #[test]
    fn a_blank_tail_is_not_a_line() {
        let mut decoder = SseDecoder::default();
        assert_eq!(push(&mut decoder, "data: a\n\n").len(), 2);
        assert!(decoder.finish().unwrap().is_none());
    }

    #[test]
    fn a_line_that_never_ends_is_rejected_instead_of_buffered() {
        let mut decoder = SseDecoder::default();
        let error = decoder
            .push(&vec![b'x'; MAX_LINE_BYTES + 1])
            .expect_err("oversized line must fail");
        match error {
            ChatError::StreamError { message } => assert!(message.contains("KiB")),
            other => panic!("expected StreamError, got {other:?}"),
        }
        // The decoder stays usable after refusing one peer.
        assert_eq!(push(&mut decoder, "data: ok\n"), vec!["data: ok"]);
    }

    #[test]
    fn invalid_utf8_is_named_not_silently_replaced() {
        let mut decoder = SseDecoder::default();
        let error = decoder
            .push(b"data: \xff\xfe\n")
            .expect_err("invalid utf-8 must fail");
        match error {
            ChatError::StreamError { message } => {
                assert!(message.contains("UTF-8"), "{message}");
                assert!(message.contains("第 6 字节"), "{message}");
            }
            other => panic!("expected StreamError, got {other:?}"),
        }
    }
}
