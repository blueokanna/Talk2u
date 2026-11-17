//! JNI surface for the Android on-device model path.
//!
//! This is a thin, panic-free adapter. It exists because the hot operations
//! happen inside a Kotlin flow that already owns the model transaction:
//!
//! * `inspectGguf` runs while a 2-3 GB file is still in the staging directory,
//!   so a parse failure has to be reported as data, not as an exception that
//!   unwinds through the import;
//! * `buildChatMlPrompt` runs once per generated turn and produces the exact
//!   bytes the accelerator will prefill;
//! * `probeGgmlBackends` answers, after a llama.cpp session is opened, whether
//!   the HTP backend was registered. It is passive and never registers a second
//!   backend.
//!
//! All of them answer with a JSON envelope (`{"ok":true,...}` or
//! `{"ok":false,"error":"..."}`) so Kotlin never has to interpret a JNI
//! exception. `EnvUnowned::with_env` already wraps the closure in
//! `catch_unwind`, so a panic cannot unwind into the JVM either.
//!
//! The JVM class is `com.blue.talk2u.OnDeviceAiNative`. The second argument is
//! `JClass` because the Kotlin entry points are `@JvmStatic`.

use jni::EnvUnowned;
use jni::objects::{JClass, JString};
use jni::sys::jstring;

use crate::api::{chatml, gguf};

/// A JNI-level failure that must surface as a Java exception.
///
/// Application failures never use this type: they travel inside the JSON
/// envelope. This one exists for the case where the Java string itself cannot be
/// allocated, where there is nothing left to read on the Kotlin side.
#[derive(Debug)]
struct BridgeError(String);

impl std::fmt::Display for BridgeError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl std::error::Error for BridgeError {}

impl From<jni::errors::Error> for BridgeError {
    fn from(error: jni::errors::Error) -> Self {
        BridgeError(format!("JNI call failed: {error}"))
    }
}

/// Answers `{"ok":false,"error":...}`.
fn failure(error: &str) -> String {
    serde_json::json!({ "ok": false, "error": error }).to_string()
}

/// Wraps a successful payload in the JSON envelope Kotlin parses.
fn success(fields: serde_json::Map<String, serde_json::Value>) -> String {
    let mut object = serde_json::Map::new();
    object.insert("ok".to_string(), serde_json::Value::Bool(true));
    object.extend(fields);
    serde_json::Value::Object(object).to_string()
}

/// Allocates the Java result string, mapping a failure onto [`BridgeError`].
fn reply(env: &mut jni::Env<'_>, payload: String) -> Result<jstring, BridgeError> {
    Ok(env
        .new_string(payload)
        .map_err(|error| BridgeError(format!("cannot allocate the Java result string: {error}")))?
        .into_raw())
}

/// Reads the GGUF header of `path` and returns its summary as JSON.
#[unsafe(no_mangle)]
pub extern "system" fn Java_com_blue_talk2u_OnDeviceAiNative_inspectGguf<'local>(
    mut unowned: EnvUnowned<'local>,
    _class: JClass<'local>,
    path: JString<'local>,
) -> jstring {
    let outcome = unowned.with_env(|env| -> Result<jstring, BridgeError> {
        let path: String = path.to_string();
        let payload = match gguf::inspect(std::path::Path::new(&path)) {
            Ok(summary) => match summary.to_json() {
                serde_json::Value::Object(fields) => success(fields),
                _ => failure("the GGUF summary could not be encoded"),
            },
            Err(error) => failure(&error),
        };
        reply(env, payload)
    });
    outcome.resolve::<jni::errors::ThrowRuntimeExAndDefault>()
}

/// Renders the ChatML prompt for the JSON message array in `messages`.
#[unsafe(no_mangle)]
pub extern "system" fn Java_com_blue_talk2u_OnDeviceAiNative_buildChatMlPrompt<'local>(
    mut unowned: EnvUnowned<'local>,
    _class: JClass<'local>,
    messages: JString<'local>,
) -> jstring {
    let outcome = unowned.with_env(|env| -> Result<jstring, BridgeError> {
        let messages: String = messages.to_string();
        let payload = match chatml::from_json(&messages) {
            Ok(prompt) => {
                let mut fields = serde_json::Map::new();
                fields.insert(
                    "prompt".to_string(),
                    serde_json::Value::String(prompt.clone()),
                );
                fields.insert(
                    "promptBytes".to_string(),
                    serde_json::Value::from(prompt.len() as u64),
                );
                success(fields)
            }
            Err(error) => failure(&error),
        };
        reply(env, payload)
    });
    outcome.resolve::<jni::errors::ThrowRuntimeExAndDefault>()
}

/// Reports whether a generated reply still carries ChatML control tokens.
///
/// The runtime rejects such a reply instead of rendering it, so the check runs
/// in the same module that defines the tokens.
#[unsafe(no_mangle)]
pub extern "system" fn Java_com_blue_talk2u_OnDeviceAiNative_containsControlToken<'local>(
    mut unowned: EnvUnowned<'local>,
    _class: JClass<'local>,
    text: JString<'local>,
) -> jstring {
    let outcome = unowned.with_env(|env| -> Result<jstring, BridgeError> {
        let text: String = text.to_string();
        let payload = serde_json::json!({
            "ok": true,
            "leaked": chatml::contains_control_token(&text),
        })
        .to_string();
        reply(env, payload)
    });
    outcome.resolve::<jni::errors::ThrowRuntimeExAndDefault>()
}

/// Reports which GGML backends the loaded llama.cpp plugin registered.
///
/// This is a **passive** probe. It never loads a library: it opens the already
/// mapped `libggml.so` with `RTLD_NOLOAD`, resolves the registry accessors and
/// reads the device table. Calling `ggml_backend_load_all_from_path` here would
/// register a second copy of every backend next to the one GenieX loaded, so the
/// probe deliberately cannot do that.
///
/// The answer is what separates "a session was created" from "the HTP backend is
/// present". Without it, a llama.cpp session that quietly fell back to CPU would
/// still be labelled NPU by the settings page.
#[cfg(target_os = "android")]
#[unsafe(no_mangle)]
pub extern "system" fn Java_com_blue_talk2u_OnDeviceAiNative_probeGgmlBackends<'local>(
    mut unowned: EnvUnowned<'local>,
    _class: JClass<'local>,
    directory: JString<'local>,
) -> jstring {
    let outcome = unowned.with_env(|env| -> Result<jstring, BridgeError> {
        let directory: String = directory.to_string();
        reply(env, ggml_probe::snapshot(&directory).to_string())
    });
    outcome.resolve::<jni::errors::ThrowRuntimeExAndDefault>()
}

/// The passive GGML registry probe.
///
/// Kept in this module because it shares the JNI envelope contract, but it has
/// no dependency on the rest of the bridge: it only uses `dlopen`/`dlsym` on the
/// process image GenieX already mapped.
#[cfg(target_os = "android")]
mod ggml_probe {
    use std::ffi::{CStr, CString};
    use std::os::raw::{c_char, c_void};

    type RegByName = unsafe extern "C" fn(*const c_char) -> *mut c_void;
    type RegCount = unsafe extern "C" fn() -> usize;
    type DeviceCount = unsafe extern "C" fn() -> usize;
    type DeviceGet = unsafe extern "C" fn(usize) -> *mut c_void;
    type DeviceName = unsafe extern "C" fn(*mut c_void) -> *const c_char;
    type DeviceDescription = unsafe extern "C" fn(*mut c_void) -> *const c_char;

    /// Resolves one symbol from an already-open handle.
    ///
    /// `transmute_copy` is used instead of `transmute` because the function
    /// pointer types differ per symbol; the size equality is guaranteed by the
    /// pointer-sized `T` selected below.
    fn symbol<T: Copy>(handle: *mut c_void, name: &str) -> Option<T> {
        let name = CString::new(name).ok()?;
        // SAFETY: `handle` comes from dlopen and `name` is NUL-terminated.
        let pointer = unsafe { libc::dlsym(handle, name.as_ptr()) };
        if pointer.is_null() {
            return None;
        }
        // SAFETY: `T` is always a pointer-sized function pointer here.
        Some(unsafe { std::mem::transmute_copy::<*mut c_void, T>(&pointer) })
    }

    fn open_already_loaded(directory: &str) -> Option<*mut c_void> {
        let flags = libc::RTLD_NOW | libc::RTLD_NOLOAD;
        let by_name = CString::new("libggml.so").ok()?;
        // SAFETY: NUL-terminated names, valid flags.
        let handle = unsafe { libc::dlopen(by_name.as_ptr(), flags) };
        if !handle.is_null() {
            return Some(handle);
        }
        let path = std::path::Path::new(directory).join("libggml.so");
        let path = CString::new(path.to_string_lossy().into_owned()).ok()?;
        // SAFETY: same as above, now with an absolute path.
        let handle = unsafe { libc::dlopen(path.as_ptr(), flags) };
        (!handle.is_null()).then_some(handle)
    }

    fn device_label(name_pointer: *const c_char) -> String {
        if name_pointer.is_null() {
            return String::new();
        }
        // SAFETY: GGML returns a NUL-terminated static string.
        unsafe { CStr::from_ptr(name_pointer) }
            .to_string_lossy()
            .into_owned()
    }

    /// Returns `{"ok":true, "loaded":bool, "htpRegistered":bool, ...}`.
    pub(super) fn snapshot(directory: &str) -> serde_json::Value {
        let Some(handle) = open_already_loaded(directory) else {
            return serde_json::json!({
                "ok": true,
                "loaded": false,
                "htpRegistered": false,
                "htpDevice": false,
                "registryCount": 0,
                "deviceCount": 0,
                "devices": [],
            });
        };

        let reg_by_name: Option<RegByName> = symbol(handle, "ggml_backend_reg_by_name");
        let reg_count: Option<RegCount> = symbol(handle, "ggml_backend_reg_count");
        let device_count: Option<DeviceCount> = symbol(handle, "ggml_backend_dev_count");
        let device_get: Option<DeviceGet> = symbol(handle, "ggml_backend_dev_get");
        let device_name: Option<DeviceName> = symbol(handle, "ggml_backend_dev_name");
        let device_description: Option<DeviceDescription> =
            symbol(handle, "ggml_backend_dev_description");

        let htp_name = CString::new("HTP").unwrap_or_default();
        // SAFETY: the function pointer was resolved from libggml itself.
        let htp_registered =
            reg_by_name.is_some_and(|resolve| unsafe { !resolve(htp_name.as_ptr()).is_null() });

        let mut devices = Vec::new();
        if let (Some(count), Some(get), Some(name)) = (device_count, device_get, device_name) {
            // SAFETY: the table and each device handle belong to libggml.
            let total = unsafe { count() };
            for index in 0..total.min(64) {
                // SAFETY: index is below the reported count.
                let device = unsafe { get(index) };
                if device.is_null() {
                    continue;
                }
                // SAFETY: `device` came from the registry.
                let label = device_label(unsafe { name(device) });
                let description = device_description
                    .map(|describe| {
                        // SAFETY: same handle contract as `name`.
                        device_label(unsafe { describe(device) })
                    })
                    .unwrap_or_default();
                devices.push(serde_json::json!({
                    "name": label,
                    "description": description,
                }));
            }
        }

        let htp_device = devices.iter().any(|device| {
            device
                .get("name")
                .and_then(|value| value.as_str())
                .is_some_and(|name| name.to_ascii_uppercase().starts_with("HTP"))
        });
        let registry_count = reg_count.map(|count| {
            // SAFETY: exported accessor, no arguments.
            unsafe { count() }
        });

        // SAFETY: drops this probe's dlopen reference only; GenieX keeps its own.
        unsafe { libc::dlclose(handle) };

        serde_json::json!({
            "ok": true,
            "loaded": true,
            "htpRegistered": htp_registered,
            "htpDevice": htp_device,
            "registryCount": registry_count.unwrap_or(0),
            "deviceCount": devices.len(),
            "devices": devices,
        })
    }
}
