pub mod api;
pub mod connectors;
mod frb_generated;

#[cfg(target_os = "android")]
mod android_tls;

/// Returns true if the character is a CJK unified ideograph (including Extension A).
#[inline]
pub(crate) fn is_cjk_char(c: char) -> bool {
    matches!(c, '\u{3400}'..='\u{4DBF}' | '\u{4E00}'..='\u{9FFF}' | '\u{F900}'..='\u{FAFF}')
}

pub(crate) fn ensure_platform_tls_ready() -> Result<(), String> {
    #[cfg(target_os = "android")]
    {
        return android_tls::ensure_initialized();
    }

    #[cfg(not(target_os = "android"))]
    Ok(())
}
