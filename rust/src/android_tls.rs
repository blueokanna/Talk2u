use std::sync::atomic::{AtomicBool, Ordering};

use jni::errors::LogErrorAndDefault;
use jni::objects::JObject;
use jni::sys::{jboolean, JNI_TRUE};
use jni::EnvUnowned;

static TLS_READY: AtomicBool = AtomicBool::new(false);

pub(crate) fn ensure_initialized() -> Result<(), String> {
    if TLS_READY.load(Ordering::Acquire) {
        Ok(())
    } else {
        Err(
            "Android TLS 验证器尚未初始化。请完全退出并重新启动应用；如果问题持续，请重新安装当前版本。"
                .to_string(),
        )
    }
}

#[no_mangle]
pub extern "system" fn Java_com_blue_talk2u_MainActivity_initializeRustTls<'local>(
    mut unowned_env: EnvUnowned<'local>,
    _activity: JObject<'local>,
    context: JObject<'local>,
) -> jboolean {
    unowned_env
        .with_env(|env| -> jni::errors::Result<jboolean> {
            rustls_platform_verifier::android::init_with_env(env, context)?;
            TLS_READY.store(true, Ordering::Release);
            Ok(JNI_TRUE)
        })
        .resolve::<LogErrorAndDefault>()
}
