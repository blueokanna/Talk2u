pub mod api;
pub mod connectors;
mod frb_generated;

/// The Android-only JNI surface for the on-device model path.
///
/// Kept out of `api` on purpose: everything in `api` is reachable from Dart
/// through flutter_rust_bridge, while this module is the opposite direction —
/// Kotlin calls Rust synchronously inside an import or a generation turn.
#[cfg(target_os = "android")]
mod android_bridge;

/// Returns true if the character is a CJK unified ideograph (including Extension A).
#[inline]
pub(crate) fn is_cjk_char(c: char) -> bool {
    matches!(c, '\u{3400}'..='\u{4DBF}' | '\u{4E00}'..='\u{9FFF}' | '\u{F900}'..='\u{FAFF}')
}
