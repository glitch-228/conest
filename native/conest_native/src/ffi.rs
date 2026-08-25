//! Small stable C ABI used by Flutter's `dart:ffi` loader.
//!
//! The primary Rust API remains annotated for flutter_rust_bridge codegen.
//! This ABI is intentionally narrow so development builds can load the same
//! library before generated bridge churn is committed. Every returned string
//! is owned by Rust and must be released with `conest_string_free`.

use std::{
    collections::HashMap,
    ffi::{CStr, CString, c_char},
    slice,
    sync::{Arc, LazyLock, Mutex},
};

use base64::{Engine as _, engine::general_purpose::STANDARD as BASE64};
use serde::Serialize;
use tokio::runtime::Runtime;

use crate::api::{NativeInboundEnvelope, NativeTransport};
#[cfg(any(target_os = "linux", target_os = "windows"))]
use crate::desktop_camera::DesktopBeamCamera;

static RUNTIME: LazyLock<Runtime> =
    LazyLock::new(|| Runtime::new().expect("create Conest native Tokio runtime"));
static TRANSPORTS: LazyLock<Mutex<HashMap<u64, Arc<NativeTransport>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));
#[cfg(any(target_os = "linux", target_os = "windows"))]
static BEAM_CAMERAS: LazyLock<Mutex<HashMap<u64, DesktopBeamCamera>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));
static NEXT_HANDLE: LazyLock<Mutex<u64>> = LazyLock::new(|| Mutex::new(1));
static LAST_ERROR: LazyLock<Mutex<String>> = LazyLock::new(|| Mutex::new(String::new()));

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct InboundJson {
    sender_endpoint_id: String,
    bytes_base64: String,
    relayed: bool,
}

fn record_error(error: impl std::fmt::Display) {
    if let Ok(mut slot) = LAST_ERROR.lock() {
        *slot = error.to_string();
    }
}

fn json_string(value: &impl Serialize) -> *mut c_char {
    match serde_json::to_string(value)
        .map_err(anyhow::Error::from)
        .and_then(|value| CString::new(value).map_err(anyhow::Error::from))
    {
        Ok(value) => value.into_raw(),
        Err(error) => {
            record_error(error);
            std::ptr::null_mut()
        }
    }
}

fn transport(handle: u64) -> Option<Arc<NativeTransport>> {
    TRANSPORTS.lock().ok()?.get(&handle).cloned()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn conest_iroh_start(
    seed: *const u8,
    seed_len: usize,
    relay_enabled: bool,
) -> u64 {
    unsafe { start_transport(seed, seed_len, relay_enabled, Vec::new()) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn conest_iroh_start_v2(
    seed: *const u8,
    seed_len: usize,
    relay_enabled: bool,
    relay_urls_json: *const c_char,
) -> u64 {
    if relay_urls_json.is_null() {
        record_error("custom Iroh relay URL list is null");
        return 0;
    }
    // SAFETY: The Dart caller supplies a NUL-terminated UTF-8 JSON string for
    // the duration of this call.
    let relay_urls_json = match unsafe { CStr::from_ptr(relay_urls_json) }.to_str() {
        Ok(value) => value,
        Err(error) => {
            record_error(error);
            return 0;
        }
    };
    let relay_urls = match serde_json::from_str::<Vec<String>>(relay_urls_json) {
        Ok(value) => value,
        Err(error) => {
            record_error(error);
            return 0;
        }
    };
    unsafe { start_transport(seed, seed_len, relay_enabled, relay_urls) }
}

unsafe fn start_transport(
    seed: *const u8,
    seed_len: usize,
    relay_enabled: bool,
    relay_urls: Vec<String>,
) -> u64 {
    if seed.is_null() || seed_len != 32 {
        record_error("Iroh secret key seed must be exactly 32 bytes");
        return 0;
    }
    // SAFETY: The caller guarantees `seed` points to `seed_len` readable bytes
    // for the duration of this call; null and exact length were checked above.
    let seed = unsafe { slice::from_raw_parts(seed, seed_len) }.to_vec();
    let created = RUNTIME.block_on(NativeTransport::start(seed, relay_enabled, relay_urls));
    let created = match created {
        Ok(value) => Arc::new(value),
        Err(error) => {
            record_error(error);
            return 0;
        }
    };
    let handle = match NEXT_HANDLE.lock() {
        Ok(mut next) => {
            let value = *next;
            *next = next.saturating_add(1).max(1);
            value
        }
        Err(error) => {
            record_error(error);
            return 0;
        }
    };
    match TRANSPORTS.lock() {
        Ok(mut transports) => {
            transports.insert(handle, created);
            handle
        }
        Err(error) => {
            record_error(error);
            0
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn conest_iroh_status(handle: u64) -> *mut c_char {
    let Some(transport) = transport(handle) else {
        record_error("unknown native transport handle");
        return std::ptr::null_mut();
    };
    json_string(&transport.status())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn conest_iroh_send(
    handle: u64,
    remote_endpoint_id: *const c_char,
    bytes: *const u8,
    bytes_len: usize,
) -> *mut c_char {
    let Some(transport) = transport(handle) else {
        record_error("unknown native transport handle");
        return std::ptr::null_mut();
    };
    if remote_endpoint_id.is_null() || bytes.is_null() {
        record_error("null Iroh send argument");
        return std::ptr::null_mut();
    }
    // SAFETY: Both pointers are borrowed only for this call. The Dart bridge
    // owns the allocations and supplies a terminating NUL for the endpoint.
    let endpoint = match unsafe { CStr::from_ptr(remote_endpoint_id) }.to_str() {
        Ok(value) => value.to_owned(),
        Err(error) => {
            record_error(error);
            return std::ptr::null_mut();
        }
    };
    // SAFETY: The caller provides a readable buffer of exactly `bytes_len`.
    let payload = unsafe { slice::from_raw_parts(bytes, bytes_len) }.to_vec();
    match RUNTIME.block_on(transport.send_envelope(endpoint, payload)) {
        Ok(receipt) => json_string(&receipt),
        Err(error) => {
            record_error(error);
            std::ptr::null_mut()
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn conest_iroh_send_v2(
    handle: u64,
    remote_endpoint_id: *const c_char,
    bytes: *const u8,
    bytes_len: usize,
    allow_relay: bool,
) -> *mut c_char {
    let Some(transport) = transport(handle) else {
        record_error("unknown native transport handle");
        return std::ptr::null_mut();
    };
    if remote_endpoint_id.is_null() || bytes.is_null() {
        record_error("null Iroh send argument");
        return std::ptr::null_mut();
    }
    // SAFETY: pointers are borrowed only for this call and validated above.
    let endpoint = match unsafe { CStr::from_ptr(remote_endpoint_id) }.to_str() {
        Ok(value) => value.to_owned(),
        Err(error) => {
            record_error(error);
            return std::ptr::null_mut();
        }
    };
    // SAFETY: Dart provides a readable buffer of exactly `bytes_len` bytes.
    let payload = unsafe { slice::from_raw_parts(bytes, bytes_len) }.to_vec();
    match RUNTIME.block_on(transport.send_envelope_with_policy(endpoint, payload, allow_relay)) {
        Ok(receipt) => json_string(&receipt),
        Err(error) => {
            record_error(error);
            std::ptr::null_mut()
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn conest_iroh_next(handle: u64) -> *mut c_char {
    let Some(transport) = transport(handle) else {
        record_error("unknown native transport handle");
        return std::ptr::null_mut();
    };
    let Some(NativeInboundEnvelope {
        sender_endpoint_id,
        bytes,
        path,
    }) = RUNTIME.block_on(transport.try_next_envelope())
    else {
        return std::ptr::null_mut();
    };
    json_string(&InboundJson {
        sender_endpoint_id,
        bytes_base64: BASE64.encode(bytes),
        relayed: matches!(path, crate::api::NativePathKind::Relayed),
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn conest_iroh_close(handle: u64) {
    let removed = TRANSPORTS
        .lock()
        .ok()
        .and_then(|mut transports| transports.remove(&handle));
    if let Some(transport) = removed {
        RUNTIME.block_on(transport.close());
    }
}

/// Starts a Nokhwa camera and RXing QR decoder on Linux/Windows. Frames are
/// returned as decoded UTF-8 by [conest_beam_camera_next], never as raw image
/// buffers across FFI.
#[cfg(any(target_os = "linux", target_os = "windows"))]
#[unsafe(no_mangle)]
pub extern "C" fn conest_beam_camera_start(camera_index: u32) -> u64 {
    let camera = match DesktopBeamCamera::start(camera_index) {
        Ok(camera) => camera,
        Err(error) => {
            record_error(error);
            return 0;
        }
    };
    let handle = match NEXT_HANDLE.lock() {
        Ok(mut next) => {
            let value = *next;
            *next = next.saturating_add(1).max(1);
            value
        }
        Err(error) => {
            record_error(error);
            return 0;
        }
    };
    match BEAM_CAMERAS.lock() {
        Ok(mut cameras) => {
            cameras.insert(handle, camera);
            handle
        }
        Err(error) => {
            record_error(error);
            0
        }
    }
}

#[cfg(any(target_os = "linux", target_os = "windows"))]
#[unsafe(no_mangle)]
pub extern "C" fn conest_beam_camera_next(handle: u64) -> *mut c_char {
    let Ok(cameras) = BEAM_CAMERAS.lock() else {
        record_error("desktop Beam camera lock poisoned");
        return std::ptr::null_mut();
    };
    let Some(camera) = cameras.get(&handle) else {
        record_error("unknown desktop Beam camera handle");
        return std::ptr::null_mut();
    };
    let Some(value) = camera.try_next() else {
        return std::ptr::null_mut();
    };
    CString::new(value)
        .map(CString::into_raw)
        .unwrap_or_else(|error| {
            record_error(error);
            std::ptr::null_mut()
        })
}

#[cfg(any(target_os = "linux", target_os = "windows"))]
#[unsafe(no_mangle)]
pub extern "C" fn conest_beam_camera_stop(handle: u64) {
    let removed = BEAM_CAMERAS
        .lock()
        .ok()
        .and_then(|mut cameras| cameras.remove(&handle));
    if let Some(camera) = removed {
        camera.stop();
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn conest_last_error() -> *mut c_char {
    let message = LAST_ERROR
        .lock()
        .map(|value| value.clone())
        .unwrap_or_else(|_| "native error lock poisoned".to_owned());
    CString::new(message)
        .map(CString::into_raw)
        .unwrap_or(std::ptr::null_mut())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn conest_string_free(value: *mut c_char) {
    if !value.is_null() {
        // SAFETY: This function is only for pointers produced by
        // `CString::into_raw` in this module, and Dart calls it exactly once.
        drop(unsafe { CString::from_raw(value) });
    }
}
