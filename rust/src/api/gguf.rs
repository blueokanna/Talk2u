//! Bounded GGUF metadata reader.
//!
//! The on-device model manager accepts a llama.cpp GGUF as the GPU/CPU artifact
//! (OpenCL via `libggml-opencl.so`), so the import has to answer three questions
//! before copying three gigabytes into private storage:
//!
//! 1. is this really a GGUF container (and a version we can execute)?
//! 2. which architecture is inside — a `qwen3` checkpoint or something that will
//!    load and then answer garbage?
//! 3. how big is the metadata block, so a hostile or corrupt file cannot make the
//!    importer allocate its way to an OOM kill?
//!
//! Every read is bounded by [`MAX_HEADER_BYTES`] and every count by an explicit
//! cap. Strings are length-checked *before* allocating, and skipped values are
//! consumed through a fixed 8 KiB scratch buffer instead of a `Vec` whose size
//! the file controls. The parser therefore runs in constant memory regardless of
//! what the file claims.

use std::fs::File;
use std::io::{BufReader, Read};
use std::path::Path;

/// Container magic, little endian on disk as the bytes `GGUF`.
const MAGIC: [u8; 4] = *b"GGUF";

/// Upper bound on the metadata block we are willing to walk. Qwen3-4B declares
/// roughly 40 keys; 64 MiB is three orders of magnitude of headroom.
const MAX_HEADER_BYTES: u64 = 64 * 1024 * 1024;

/// Upper bound on `metadata_kv_count`.
const MAX_KV_PAIRS: u64 = 65_536;

/// Upper bound on a single metadata string (a 128k tokenizer merge list fits).
const MAX_STRING_BYTES: u64 = 8 * 1024 * 1024;

/// Upper bound on a metadata array length.
const MAX_ARRAY_ITEMS: u64 = 4 * 1024 * 1024;

/// Upper bound on declared tensors. Qwen3-4B has ~400.
const MAX_TENSORS: u64 = 1_048_576;

/// GGUF metadata value types.
mod ty {
    pub(super) const UINT8: u32 = 0;
    pub(super) const INT8: u32 = 1;
    pub(super) const UINT16: u32 = 2;
    pub(super) const INT16: u32 = 3;
    pub(super) const UINT32: u32 = 4;
    pub(super) const INT32: u32 = 5;
    pub(super) const FLOAT32: u32 = 6;
    pub(super) const BOOL: u32 = 7;
    pub(super) const STRING: u32 = 8;
    pub(super) const ARRAY: u32 = 9;
    pub(super) const UINT64: u32 = 10;
    pub(super) const INT64: u32 = 11;
    pub(super) const FLOAT64: u32 = 12;
}

/// What the importer needs to know about a GGUF container.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Summary {
    pub(crate) version: u32,
    pub(crate) tensor_count: u64,
    pub(crate) file_bytes: u64,
    pub(crate) architecture: Option<String>,
    pub(crate) name: Option<String>,
    pub(crate) file_type: Option<u32>,
    pub(crate) block_count: Option<u32>,
    pub(crate) embedding_length: Option<u32>,
}

impl Summary {
    /// `true` when the container declares the Qwen3 transformer.
    pub(crate) fn is_qwen3(&self) -> bool {
        self.architecture
            .as_deref()
            .is_some_and(|arch| arch.eq_ignore_ascii_case("qwen3"))
    }

    /// JSON projection handed to Kotlin through the JNI bridge.
    pub(crate) fn to_json(&self) -> serde_json::Value {
        serde_json::json!({
            "version": self.version,
            "tensorCount": self.tensor_count,
            "fileBytes": self.file_bytes,
            "architecture": self.architecture,
            "name": self.name,
            "fileType": self.file_type,
            "blockCount": self.block_count,
            "embeddingLength": self.embedding_length,
            "qwen3": self.is_qwen3(),
        })
    }
}

/// Reads a GGUF header and returns its summary.
///
/// The file is never mapped or read whole: the header is consumed through a
/// buffered reader capped by [`MAX_HEADER_BYTES`].
pub(crate) fn inspect(path: &Path) -> Result<Summary, String> {
    let file = File::open(path).map_err(|error| format!("cannot open the GGUF file: {error}"))?;
    let file_bytes = file
        .metadata()
        .map_err(|error| format!("cannot stat the GGUF file: {error}"))?
        .len();
    if file_bytes < 16 {
        return Err("the GGUF file is too small to be a model".to_string());
    }

    let mut reader = Reader::new(BufReader::with_capacity(1 << 20, file).take(MAX_HEADER_BYTES));

    let mut magic = [0u8; 4];
    reader.exact(&mut magic)?;
    if magic != MAGIC {
        return Err("the file is not a GGUF container".to_string());
    }

    let version = reader.u32()?;
    if version != 2 && version != 3 {
        return Err(format!(
            "unsupported GGUF version {version}; only versions 2 and 3 are executable"
        ));
    }

    let tensor_count = reader.u64()?;
    if tensor_count == 0 {
        return Err("the GGUF container declares no tensors".to_string());
    }
    if tensor_count > MAX_TENSORS {
        return Err(format!(
            "the GGUF container declares {tensor_count} tensors, above the {MAX_TENSORS} limit"
        ));
    }

    let kv_count = reader.u64()?;
    if kv_count > MAX_KV_PAIRS {
        return Err(format!(
            "the GGUF container declares {kv_count} metadata entries, above the {MAX_KV_PAIRS} limit"
        ));
    }

    let mut summary = Summary {
        version,
        tensor_count,
        file_bytes,
        architecture: None,
        name: None,
        file_type: None,
        block_count: None,
        embedding_length: None,
    };

    for _ in 0..kv_count {
        let key = reader.string()?;
        let value_type = reader.u32()?;
        match key.as_str() {
            "general.architecture" => {
                summary.architecture = reader.string_value(value_type)?;
            }
            "general.name" => {
                summary.name = reader.string_value(value_type)?;
            }
            "general.file_type" => {
                summary.file_type = reader.u32_value(value_type)?;
            }
            "qwen3.block_count" => {
                summary.block_count = reader.u32_value(value_type)?;
            }
            "qwen3.embedding_length" => {
                summary.embedding_length = reader.u32_value(value_type)?;
            }
            _ => reader.skip_value(value_type)?,
        }
    }

    Ok(summary)
}

/// A reader with the bounds documented on the module.
struct Reader<R: Read> {
    inner: R,
    scratch: [u8; 8 * 1024],
}

impl<R: Read> Reader<R> {
    fn new(inner: R) -> Self {
        Self {
            inner,
            scratch: [0u8; 8 * 1024],
        }
    }

    fn exact(&mut self, buffer: &mut [u8]) -> Result<(), String> {
        self.inner
            .read_exact(buffer)
            .map_err(|error| format!("the GGUF header is truncated: {error}"))
    }

    fn u32(&mut self) -> Result<u32, String> {
        let mut bytes = [0u8; 4];
        self.exact(&mut bytes)?;
        Ok(u32::from_le_bytes(bytes))
    }

    fn u64(&mut self) -> Result<u64, String> {
        let mut bytes = [0u8; 8];
        self.exact(&mut bytes)?;
        Ok(u64::from_le_bytes(bytes))
    }

    /// Reads a GGUF string: a `u64` byte length followed by UTF-8 bytes.
    ///
    /// The length is validated against [`MAX_STRING_BYTES`] *before*
    /// `with_capacity`, so a file claiming a 4 GiB key fails instead of
    /// allocating.
    fn string(&mut self) -> Result<String, String> {
        let length = self.u64()?;
        if length > MAX_STRING_BYTES {
            return Err(format!(
                "a GGUF metadata string declares {length} bytes, above the {MAX_STRING_BYTES} limit"
            ));
        }
        let mut bytes = vec![0u8; length as usize];
        self.exact(&mut bytes)?;
        String::from_utf8(bytes)
            .map_err(|_| "a GGUF metadata string is not valid UTF-8".to_string())
    }

    /// Consumes `bytes` through the scratch buffer; never allocates.
    fn skip(&mut self, mut bytes: u64) -> Result<(), String> {
        while bytes > 0 {
            let chunk = bytes.min(self.scratch.len() as u64) as usize;
            self.inner
                .read_exact(&mut self.scratch[..chunk])
                .map_err(|error| format!("the GGUF header is truncated: {error}"))?;
            bytes -= chunk as u64;
        }
        Ok(())
    }

    fn skip_value(&mut self, value_type: u32) -> Result<(), String> {
        match value_type {
            ty::UINT8 | ty::INT8 | ty::BOOL => self.skip(1),
            ty::UINT16 | ty::INT16 => self.skip(2),
            ty::UINT32 | ty::INT32 | ty::FLOAT32 => self.skip(4),
            ty::UINT64 | ty::INT64 | ty::FLOAT64 => self.skip(8),
            ty::STRING => {
                let length = self.u64()?;
                if length > MAX_STRING_BYTES {
                    return Err(format!(
                        "a GGUF metadata string declares {length} bytes, above the {MAX_STRING_BYTES} limit"
                    ));
                }
                self.skip(length)
            }
            ty::ARRAY => {
                let element_type = self.u32()?;
                let count = self.u64()?;
                if count > MAX_ARRAY_ITEMS {
                    return Err(format!(
                        "a GGUF metadata array declares {count} items, above the {MAX_ARRAY_ITEMS} limit"
                    ));
                }
                match element_type {
                    ty::UINT8 | ty::INT8 | ty::BOOL => self.skip(count),
                    ty::UINT16 | ty::INT16 => self.skip(count.saturating_mul(2)),
                    ty::UINT32 | ty::INT32 | ty::FLOAT32 => self.skip(count.saturating_mul(4)),
                    ty::UINT64 | ty::INT64 | ty::FLOAT64 => self.skip(count.saturating_mul(8)),
                    ty::STRING => {
                        for _ in 0..count {
                            let length = self.u64()?;
                            if length > MAX_STRING_BYTES {
                                return Err(format!(
                                    "a GGUF metadata string declares {length} bytes, above the {MAX_STRING_BYTES} limit"
                                ));
                            }
                            self.skip(length)?;
                        }
                        Ok(())
                    }
                    ty::ARRAY => Err("nested GGUF metadata arrays are not supported".to_string()),
                    other => Err(format!("unknown GGUF metadata element type {other}")),
                }
            }
            other => Err(format!("unknown GGUF metadata value type {other}")),
        }
    }

    /// Reads a `STRING` value, or skips it when the file typed it differently.
    fn string_value(&mut self, value_type: u32) -> Result<Option<String>, String> {
        if value_type == ty::STRING {
            self.string().map(Some)
        } else {
            self.skip_value(value_type)?;
            Ok(None)
        }
    }

    /// Reads an unsigned scalar value widened to `u32`, or skips it.
    fn u32_value(&mut self, value_type: u32) -> Result<Option<u32>, String> {
        let value = match value_type {
            ty::UINT8 | ty::INT8 | ty::BOOL => {
                let mut byte = [0u8; 1];
                self.exact(&mut byte)?;
                Some(u32::from(byte[0]))
            }
            ty::UINT16 | ty::INT16 => {
                let mut bytes = [0u8; 2];
                self.exact(&mut bytes)?;
                Some(u32::from(u16::from_le_bytes(bytes)))
            }
            ty::UINT32 | ty::INT32 => Some(self.u32()?),
            ty::UINT64 | ty::INT64 => {
                let value = self.u64()?;
                Some(u32::try_from(value.min(u64::from(u32::MAX))).unwrap_or(u32::MAX))
            }
            _ => {
                self.skip_value(value_type)?;
                return Ok(None);
            }
        };
        Ok(value)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    enum Kv {
        Str(&'static str),
        U32(u32),
        U64(u64),
        Ints(Vec<u32>),
        Strings(Vec<&'static str>),
    }

    fn push_u32(out: &mut Vec<u8>, value: u32) {
        out.extend_from_slice(&value.to_le_bytes());
    }

    fn push_u64(out: &mut Vec<u8>, value: u64) {
        out.extend_from_slice(&value.to_le_bytes());
    }

    fn push_str(out: &mut Vec<u8>, value: &str) {
        push_u64(out, value.len() as u64);
        out.extend_from_slice(value.as_bytes());
    }

    fn build(version: u32, tensors: u64, kvs: &[(&str, Kv)]) -> Vec<u8> {
        let mut out = Vec::new();
        out.extend_from_slice(&MAGIC);
        push_u32(&mut out, version);
        push_u64(&mut out, tensors);
        push_u64(&mut out, kvs.len() as u64);
        for (key, value) in kvs {
            push_str(&mut out, key);
            match value {
                Kv::Str(text) => {
                    push_u32(&mut out, ty::STRING);
                    push_str(&mut out, text);
                }
                Kv::U32(number) => {
                    push_u32(&mut out, ty::UINT32);
                    push_u32(&mut out, *number);
                }
                Kv::U64(number) => {
                    push_u32(&mut out, ty::UINT64);
                    push_u64(&mut out, *number);
                }
                Kv::Ints(items) => {
                    push_u32(&mut out, ty::ARRAY);
                    push_u32(&mut out, ty::UINT32);
                    push_u64(&mut out, items.len() as u64);
                    for item in items {
                        push_u32(&mut out, *item);
                    }
                }
                Kv::Strings(items) => {
                    push_u32(&mut out, ty::ARRAY);
                    push_u32(&mut out, ty::STRING);
                    push_u64(&mut out, items.len() as u64);
                    for item in items {
                        push_str(&mut out, item);
                    }
                }
            }
        }
        out
    }

    fn inspect_bytes(bytes: &[u8]) -> Result<Summary, String> {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("model.gguf");
        let mut file = File::create(&path).unwrap();
        file.write_all(bytes).unwrap();
        file.sync_all().unwrap();
        inspect(&path)
    }

    fn qwen3_header() -> Vec<u8> {
        build(
            3,
            398,
            &[
                ("general.architecture", Kv::Str("qwen3")),
                (
                    "general.name",
                    Kv::Str("Huihui-Qwen3-4B-Instruct-2507-abliterated"),
                ),
                ("general.file_type", Kv::U32(15)),
                ("qwen3.block_count", Kv::U32(36)),
                ("qwen3.embedding_length", Kv::U32(2560)),
                ("qwen3.attention.head_count", Kv::Ints(vec![32, 8])),
                (
                    "tokenizer.ggml.tokens",
                    Kv::Strings(vec!["<|im_start|>", "<|im_end|>", "你"]),
                ),
                ("qwen3.rope.freq_base", Kv::U64(1_000_000)),
            ],
        )
    }

    #[test]
    fn reads_a_qwen3_container() {
        let summary = inspect_bytes(&qwen3_header()).unwrap();
        assert_eq!(summary.version, 3);
        assert_eq!(summary.tensor_count, 398);
        assert_eq!(summary.architecture.as_deref(), Some("qwen3"));
        assert_eq!(
            summary.name.as_deref(),
            Some("Huihui-Qwen3-4B-Instruct-2507-abliterated")
        );
        assert_eq!(summary.file_type, Some(15));
        assert_eq!(summary.block_count, Some(36));
        assert_eq!(summary.embedding_length, Some(2560));
        assert!(summary.is_qwen3());
        assert!(summary.file_bytes > 0);
    }

    #[test]
    fn rejects_foreign_containers() {
        let mut bytes = qwen3_header();
        bytes[0] = b'X';
        assert!(inspect_bytes(&bytes).is_err());

        let mut short = qwen3_header();
        short.truncate(8);
        assert!(inspect_bytes(&short).is_err());

        assert!(inspect_bytes(b"").is_err());
    }

    #[test]
    fn rejects_unsupported_versions() {
        for version in [1u32, 4, 0] {
            let bytes = build(version, 1, &[("general.architecture", Kv::Str("qwen3"))]);
            assert!(
                inspect_bytes(&bytes).is_err(),
                "version {version} was accepted"
            );
        }
    }

    #[test]
    fn rejects_a_hostile_kv_count_without_allocating() {
        let mut bytes = Vec::new();
        bytes.extend_from_slice(&MAGIC);
        push_u32(&mut bytes, 3);
        push_u64(&mut bytes, 1);
        push_u64(&mut bytes, MAX_KV_PAIRS + 1);
        let error = inspect_bytes(&bytes).unwrap_err();
        assert!(error.contains("metadata entries"), "{error}");
    }

    #[test]
    fn rejects_a_hostile_string_length_without_allocating() {
        let mut bytes = Vec::new();
        bytes.extend_from_slice(&MAGIC);
        push_u32(&mut bytes, 3);
        push_u64(&mut bytes, 1);
        push_u64(&mut bytes, 1);
        push_u64(&mut bytes, u64::MAX);
        let error = inspect_bytes(&bytes).unwrap_err();
        assert!(error.contains("string declares"), "{error}");
    }

    #[test]
    fn rejects_a_truncated_header() {
        let bytes = qwen3_header();
        for cut in [20, 40, 64, bytes.len() - 1] {
            let error = inspect_bytes(&bytes[..cut]).unwrap_err();
            assert!(
                error.contains("truncated") || error.contains("string"),
                "cut {cut}: {error}"
            );
        }
    }

    #[test]
    fn jsons_projection_is_stable() {
        let summary = inspect_bytes(&qwen3_header()).unwrap();
        let json = summary.to_json();
        assert_eq!(json["architecture"], "qwen3");
        assert_eq!(json["qwen3"], true);
        assert_eq!(json["blockCount"], 36);
    }
}
