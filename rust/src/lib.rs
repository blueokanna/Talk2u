pub mod api;
pub mod connectors;
mod frb_generated;

/// Returns true if the character is a CJK unified ideograph (including Extension A).
#[inline]
pub(crate) fn is_cjk_char(c: char) -> bool {
    matches!(c, '\u{3400}'..='\u{4DBF}' | '\u{4E00}'..='\u{9FFF}' | '\u{F900}'..='\u{FAFF}')
}

