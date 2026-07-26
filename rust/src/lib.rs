pub mod api;
pub mod connectors;
mod frb_generated;

#[cfg(target_os = "android")]
mod android_tls;

pub(crate) fn ensure_platform_tls_ready() -> Result<(), String> {
    #[cfg(target_os = "android")]
    {
        return android_tls::ensure_initialized();
    }

    #[cfg(not(target_os = "android"))]
    Ok(())
}
