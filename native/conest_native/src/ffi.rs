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
use chacha20poly1305::{
    Tag, XChaCha20Poly1305, XNonce,
    aead::{AeadInPlace, KeyInit},
};
#[cfg(target_os = "android")]
use jni::{
    EnvUnowned,
    errors::ThrowRuntimeExAndDefault,
    objects::{JObject, JShortArray},
    sys::{JNI_FALSE, JNI_TRUE, jboolean, jint, jlong},
};
use serde::Serialize;
use sha2::{Digest, Sha256};
use tokio::runtime::Runtime;

use crate::api::{NativeInboundDatagram, NativeInboundEnvelope, NativeTransport};
#[cfg(any(target_os = "android", target_os = "linux", target_os = "windows"))]
use crate::audio::VoiceAudioSession;
#[cfg(any(target_os = "linux", target_os = "windows"))]
use crate::desktop_camera::DesktopBeamCamera;
#[cfg(any(target_os = "linux", target_os = "windows"))]
use crate::voice_recording::{VoiceMessageRecorder, VoiceMessageRecordingResult};

static RUNTIME: LazyLock<Runtime> =
    LazyLock::new(|| Runtime::new().expect("create Conest native Tokio runtime"));
static TRANSPORTS: LazyLock<Mutex<HashMap<u64, Arc<NativeTransport>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));
#[cfg(any(target_os = "android", target_os = "linux", target_os = "windows"))]
static VOICE_AUDIO_SESSIONS: LazyLock<Mutex<HashMap<u64, VoiceAudioSession>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));
#[cfg(any(target_os = "linux", target_os = "windows"))]
static BEAM_CAMERAS: LazyLock<Mutex<HashMap<u64, DesktopBeamCamera>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));
#[cfg(any(target_os = "linux", target_os = "windows"))]
static VOICE_MESSAGE_RECORDINGS: LazyLock<Mutex<HashMap<u64, VoiceMessageRecorder>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));
static NEXT_HANDLE: LazyLock<Mutex<u64>> = LazyLock::new(|| Mutex::new(1));
static LAST_ERROR: LazyLock<Mutex<String>> = LazyLock::new(|| Mutex::new(String::new()));

const ATTACHMENT_KEY_LEN: usize = 32;
const ATTACHMENT_NONCE_LEN: usize = 24;
const ATTACHMENT_HASH_LEN: usize = 32;
const ATTACHMENT_TAG_LEN: usize = 16;
const MAX_FFI_ATTACHMENT_BLOCK_LEN: usize = 4 * 1024 * 1024;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct InboundJson {
    sender_endpoint_id: String,
    bytes_base64: String,
    relayed: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct InboundDatagramJson {
    sender_endpoint_id: String,
    bytes_base64: String,
    relayed: bool,
}

#[cfg(any(target_os = "linux", target_os = "windows"))]
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct VoiceMessageRecordingJson {
    size_bytes: u64,
    waveform: Vec<u8>,
}

#[cfg(any(target_os = "linux", target_os = "windows"))]
impl From<VoiceMessageRecordingResult> for VoiceMessageRecordingJson {
    fn from(value: VoiceMessageRecordingResult) -> Self {
        Self {
            size_bytes: value.size_bytes,
            waveform: value.waveform,
        }
    }
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

/// Opens native microphone capture, Opus encoding/decoding and speaker
/// playback. The returned handle must be closed on every call exit path.
#[cfg(any(target_os = "android", target_os = "linux", target_os = "windows"))]
#[unsafe(no_mangle)]
pub extern "C" fn conest_voice_audio_open() -> u64 {
    let session = match VoiceAudioSession::open() {
        Ok(session) => session,
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
    match VOICE_AUDIO_SESSIONS.lock() {
        Ok(mut sessions) => {
            sessions.insert(handle, session);
            handle
        }
        Err(error) => {
            record_error(error);
            0
        }
    }
}

/// JSON-encoded audio output device names. The returned string is freed with
/// `conest_string_free`; Android returns an empty list because the OS owns its
/// communication route selection.
#[cfg(any(target_os = "android", target_os = "linux", target_os = "windows"))]
#[unsafe(no_mangle)]
pub extern "C" fn conest_voice_audio_output_devices() -> *mut c_char {
    let value = serde_json::to_string(&VoiceAudioSession::output_device_names())
        .unwrap_or_else(|_| "[]".to_owned());
    CString::new(value)
        .map(CString::into_raw)
        .unwrap_or_else(|_| std::ptr::null_mut())
}

/// Switches a live desktop call to a named output. Android routing is selected
/// through AudioManager and therefore rejects this operation.
#[cfg(any(target_os = "android", target_os = "linux", target_os = "windows"))]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn conest_voice_audio_set_output_device(
    handle: u64,
    name: *const c_char,
) -> bool {
    if name.is_null() {
        record_error("missing audio output device name");
        return false;
    }
    let name = match unsafe { CStr::from_ptr(name) }.to_str() {
        Ok(name) => name,
        Err(error) => {
            record_error(error);
            return false;
        }
    };
    let Ok(mut sessions) = VOICE_AUDIO_SESSIONS.lock() else {
        record_error("voice audio session registry lock poisoned");
        return false;
    };
    let Some(session) = sessions.get_mut(&handle) else {
        record_error("unknown voice audio session handle");
        return false;
    };
    match session.set_output_device(name) {
        Ok(()) => true,
        Err(error) => {
            record_error(error);
            false
        }
    }
}

#[cfg(any(target_os = "android", target_os = "linux", target_os = "windows"))]
#[unsafe(no_mangle)]
pub extern "C" fn conest_voice_audio_set_muted(handle: u64, muted: bool) -> bool {
    let Ok(sessions) = VOICE_AUDIO_SESSIONS.lock() else {
        record_error("voice audio session registry lock poisoned");
        return false;
    };
    let Some(session) = sessions.get(&handle) else {
        record_error("unknown voice audio session handle");
        return false;
    };
    session.set_muted(muted);
    true
}

#[cfg(any(target_os = "android", target_os = "linux", target_os = "windows"))]
#[unsafe(no_mangle)]
pub extern "C" fn conest_voice_audio_set_network_congested(handle: u64, congested: bool) -> bool {
    let Ok(sessions) = VOICE_AUDIO_SESSIONS.lock() else {
        record_error("voice audio session registry lock poisoned");
        return false;
    };
    let Some(session) = sessions.get(&handle) else {
        record_error("unknown voice audio session handle");
        return false;
    };
    session.set_network_congested(congested);
    true
}

#[cfg(any(target_os = "android", target_os = "linux", target_os = "windows"))]
#[unsafe(no_mangle)]
pub extern "C" fn conest_voice_audio_is_healthy(handle: u64) -> bool {
    VOICE_AUDIO_SESSIONS
        .lock()
        .ok()
        .and_then(|sessions| sessions.get(&handle).map(VoiceAudioSession::is_healthy))
        .unwrap_or(false)
}

/// Non-blocking poll for one encoded 20 ms Opus packet. Returns false when
/// no complete packet is ready or the caller's buffer is too small.
#[cfg(any(target_os = "android", target_os = "linux", target_os = "windows"))]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn conest_voice_audio_next_packet(
    handle: u64,
    output: *mut u8,
    output_capacity: usize,
    output_length: *mut usize,
) -> bool {
    if output.is_null() || output_length.is_null() || output_capacity == 0 {
        record_error("invalid voice packet output buffer");
        return false;
    }
    let packet = VOICE_AUDIO_SESSIONS.lock().ok().and_then(|sessions| {
        sessions
            .get(&handle)
            .and_then(VoiceAudioSession::try_next_packet)
    });
    let Some(packet) = packet else {
        return false;
    };
    if packet.len() > output_capacity {
        record_error("voice packet output buffer is too small");
        return false;
    }
    // SAFETY: Dart supplies a writable output buffer of `output_capacity` bytes
    // and the packet length was checked to fit before copying.
    unsafe { slice::from_raw_parts_mut(output, packet.len()) }.copy_from_slice(&packet);
    // SAFETY: Dart passes a writable pointer to one usize for this call.
    unsafe {
        *output_length = packet.len();
    }
    true
}

/// Queues a bounded authenticated Opus packet for native decoding/playback.
#[cfg(any(target_os = "android", target_os = "linux", target_os = "windows"))]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn conest_voice_audio_push_packet(
    handle: u64,
    sequence: u64,
    packet: *const u8,
    packet_length: usize,
) -> bool {
    if packet.is_null() || packet_length == 0 || packet_length > 1100 {
        record_error("invalid voice audio packet");
        return false;
    }
    // SAFETY: Dart provides a readable packet buffer for the duration of this
    // synchronous call; the native session copies it into its bounded queue.
    let packet = unsafe { slice::from_raw_parts(packet, packet_length) };
    VOICE_AUDIO_SESSIONS
        .lock()
        .ok()
        .and_then(|sessions| {
            sessions
                .get(&handle)
                .map(|session| session.push_packet(sequence, packet))
        })
        .unwrap_or(false)
}

#[cfg(any(target_os = "android", target_os = "linux", target_os = "windows"))]
#[unsafe(no_mangle)]
pub extern "C" fn conest_voice_audio_close(handle: u64) {
    let removed = VOICE_AUDIO_SESSIONS
        .lock()
        .ok()
        .and_then(|mut sessions| sessions.remove(&handle));
    drop(removed);
}

/// Starts a desktop Opus capture session and writes it as an Ogg stream to the
/// app-private path supplied by Flutter. Stop or cancel the handle exactly once.
#[cfg(any(target_os = "linux", target_os = "windows"))]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn conest_voice_message_recording_start(path: *const c_char) -> u64 {
    if path.is_null() {
        record_error("missing voice-message recording path");
        return 0;
    }
    let path = match unsafe { CStr::from_ptr(path) }.to_str() {
        Ok(path) if !path.is_empty() => path,
        Ok(_) => {
            record_error("empty voice-message recording path");
            return 0;
        }
        Err(error) => {
            record_error(error);
            return 0;
        }
    };
    let recorder = match VoiceMessageRecorder::open(path) {
        Ok(recorder) => recorder,
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
    match VOICE_MESSAGE_RECORDINGS.lock() {
        Ok(mut recordings) => {
            recordings.insert(handle, recorder);
            handle
        }
        Err(error) => {
            record_error(error);
            0
        }
    }
}

/// Stops capture, finalizes the Ogg EOS page, and returns size/waveform JSON.
/// The returned string is released with `conest_string_free`.
#[cfg(any(target_os = "linux", target_os = "windows"))]
#[unsafe(no_mangle)]
pub extern "C" fn conest_voice_message_recording_stop(handle: u64) -> *mut c_char {
    let recorder = VOICE_MESSAGE_RECORDINGS
        .lock()
        .ok()
        .and_then(|mut recordings| recordings.remove(&handle));
    let Some(recorder) = recorder else {
        record_error("unknown voice-message recording handle");
        return std::ptr::null_mut();
    };
    match recorder.stop() {
        Ok(result) => json_string(&VoiceMessageRecordingJson::from(result)),
        Err(error) => {
            record_error(error);
            std::ptr::null_mut()
        }
    }
}

/// Stops capture and removes its private partial file.
#[cfg(any(target_os = "linux", target_os = "windows"))]
#[unsafe(no_mangle)]
pub extern "C" fn conest_voice_message_recording_cancel(handle: u64) {
    let recorder = VOICE_MESSAGE_RECORDINGS
        .lock()
        .ok()
        .and_then(|mut recordings| recordings.remove(&handle));
    drop(recorder);
}

// Keep the narrow ABI present on Android, where Dart resolves all audio
// symbols at library load time. Android voice notes continue to use MediaCodec.
#[cfg(target_os = "android")]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn conest_voice_message_recording_start(_path: *const c_char) -> u64 {
    record_error("Desktop voice-message capture is unavailable on Android.");
    0
}

#[cfg(target_os = "android")]
#[unsafe(no_mangle)]
pub extern "C" fn conest_voice_message_recording_stop(_handle: u64) -> *mut c_char {
    record_error("Desktop voice-message capture is unavailable on Android.");
    std::ptr::null_mut()
}

#[cfg(target_os = "android")]
#[unsafe(no_mangle)]
pub extern "C" fn conest_voice_message_recording_cancel(_handle: u64) {}

#[cfg(target_os = "android")]
#[unsafe(no_mangle)]
pub extern "system" fn Java_dev_conest_conest_MainActivity_nativeVoiceAudioPushCapture(
    mut unowned_env: EnvUnowned<'_>,
    _this: JObject<'_>,
    handle: jlong,
    samples: JShortArray<'_>,
    sample_count: jint,
) -> jboolean {
    let outcome = unowned_env.with_env(|env| -> jni::errors::Result<jboolean> {
        if sample_count <= 0 || sample_count as usize > 3_840 {
            return Ok(JNI_FALSE);
        }
        let mut pcm = vec![0_i16; sample_count as usize];
        samples.get_region(env, 0, &mut pcm)?;
        let accepted = VOICE_AUDIO_SESSIONS
            .lock()
            .ok()
            .and_then(|sessions| {
                sessions
                    .get(&(handle as u64))
                    .map(|session| session.push_capture_pcm16(&pcm))
            })
            .unwrap_or(false);
        Ok(if accepted { JNI_TRUE } else { JNI_FALSE })
    });
    outcome.resolve::<ThrowRuntimeExAndDefault>()
}

#[cfg(target_os = "android")]
#[unsafe(no_mangle)]
pub extern "system" fn Java_dev_conest_conest_MainActivity_nativeVoiceAudioReadPlayback(
    mut unowned_env: EnvUnowned<'_>,
    _this: JObject<'_>,
    handle: jlong,
    output: JShortArray<'_>,
    requested_count: jint,
) -> jint {
    let outcome = unowned_env.with_env(|env| -> jni::errors::Result<jint> {
        if requested_count <= 0 || requested_count as usize > 3_840 {
            return Ok(0);
        }
        let mut pcm = vec![0_i16; requested_count as usize];
        let count = VOICE_AUDIO_SESSIONS
            .lock()
            .ok()
            .and_then(|sessions| {
                sessions
                    .get(&(handle as u64))
                    .map(|session| session.read_playback_pcm16(&mut pcm))
            })
            .unwrap_or(0);
        output.set_region(env, 0, &pcm[..count])?;
        Ok(count as jint)
    });
    outcome.resolve::<ThrowRuntimeExAndDefault>()
}

#[cfg(target_os = "android")]
#[unsafe(no_mangle)]
pub extern "system" fn Java_dev_conest_conest_MainActivity_nativeVoiceAudioMarkFailed(
    _unowned_env: EnvUnowned<'_>,
    _this: JObject<'_>,
    handle: jlong,
) {
    if let Ok(sessions) = VOICE_AUDIO_SESSIONS.lock() {
        if let Some(session) = sessions.get(&(handle as u64)) {
            session.mark_failed();
        }
    }
}

/// Hashes a file with bounded memory. Called from a Dart worker isolate.
/// The path must be a valid NUL-terminated UTF-8 string; free the returned
/// JSON string with `conest_string_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn conest_attachment_hash_file(path: *const c_char) -> *mut c_char {
    let result = (|| -> anyhow::Result<serde_json::Value> {
        use std::io::Read;
        anyhow::ensure!(!path.is_null(), "Missing attachment path");
        let path = unsafe { CStr::from_ptr(path) }.to_str()?;
        let mut file = std::fs::File::open(path)?;
        let mut hash = Sha256::new();
        let mut buffer = vec![0u8; 1024 * 1024];
        let mut size = 0u64;
        loop {
            let count = file.read(&mut buffer)?;
            if count == 0 {
                break;
            }
            hash.update(&buffer[..count]);
            size += count as u64;
        }
        Ok(serde_json::json!({"sizeBytes": size, "sha256Base64": BASE64.encode(hash.finalize())}))
    })();
    match result {
        Ok(value) => json_string(&value),
        Err(error) => {
            record_error(error);
            std::ptr::null_mut()
        }
    }
}

/// Encrypts one already-bounded attachment block without JSON or base64.
///
/// The caller owns every buffer. `ciphertext_out` must be exactly
/// `plaintext_len + 16` bytes and `hash_out` exactly 32 bytes. This narrow ABI
/// deliberately matches attachment protocol v2's Dart wire format so peers
/// can upgrade independently while block crypto moves off the Flutter isolate.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn conest_attachment_encrypt_block(
    key: *const u8,
    nonce: *const u8,
    aad: *const u8,
    aad_len: usize,
    plaintext: *const u8,
    plaintext_len: usize,
    ciphertext_out: *mut u8,
    ciphertext_out_len: usize,
    hash_out: *mut u8,
) -> bool {
    if key.is_null()
        || nonce.is_null()
        || aad.is_null()
        || plaintext.is_null()
        || ciphertext_out.is_null()
        || hash_out.is_null()
        || aad_len == 0
        || plaintext_len == 0
        || plaintext_len > MAX_FFI_ATTACHMENT_BLOCK_LEN
        || ciphertext_out_len != plaintext_len + ATTACHMENT_TAG_LEN
    {
        record_error("invalid native attachment encryption buffers");
        return false;
    }
    // SAFETY: all pointers and exact lengths are supplied by the FFI caller
    // for this call only and were checked for null/valid protocol bounds.
    let key = unsafe { slice::from_raw_parts(key, ATTACHMENT_KEY_LEN) };
    let nonce = unsafe { slice::from_raw_parts(nonce, ATTACHMENT_NONCE_LEN) };
    let aad = unsafe { slice::from_raw_parts(aad, aad_len) };
    let plaintext = unsafe { slice::from_raw_parts(plaintext, plaintext_len) };
    let output = unsafe { slice::from_raw_parts_mut(ciphertext_out, ciphertext_out_len) };
    output[..plaintext_len].copy_from_slice(plaintext);

    let cipher = match XChaCha20Poly1305::new_from_slice(key) {
        Ok(cipher) => cipher,
        Err(error) => {
            record_error(error);
            return false;
        }
    };
    let tag = match cipher.encrypt_in_place_detached(
        XNonce::from_slice(nonce),
        aad,
        &mut output[..plaintext_len],
    ) {
        Ok(tag) => tag,
        Err(error) => {
            record_error(error);
            return false;
        }
    };
    output[plaintext_len..].copy_from_slice(&tag);
    let hash: [u8; ATTACHMENT_HASH_LEN] = Sha256::digest(plaintext).into();
    // SAFETY: `hash_out` is documented as a writable 32-byte caller buffer.
    unsafe { slice::from_raw_parts_mut(hash_out, ATTACHMENT_HASH_LEN) }.copy_from_slice(&hash);
    true
}

/// Authenticates, decrypts, and SHA-256-checks one attachment block.
/// `plaintext_out` must be exactly `ciphertext_len - 16` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn conest_attachment_decrypt_block(
    key: *const u8,
    nonce: *const u8,
    aad: *const u8,
    aad_len: usize,
    ciphertext: *const u8,
    ciphertext_len: usize,
    expected_hash: *const u8,
    plaintext_out: *mut u8,
    plaintext_out_len: usize,
) -> bool {
    if key.is_null()
        || nonce.is_null()
        || aad.is_null()
        || ciphertext.is_null()
        || expected_hash.is_null()
        || plaintext_out.is_null()
        || aad_len == 0
        || ciphertext_len <= ATTACHMENT_TAG_LEN
        || ciphertext_len > MAX_FFI_ATTACHMENT_BLOCK_LEN + ATTACHMENT_TAG_LEN
        || plaintext_out_len != ciphertext_len - ATTACHMENT_TAG_LEN
    {
        record_error("invalid native attachment decryption buffers");
        return false;
    }
    // SAFETY: all pointers and exact lengths are supplied by the FFI caller
    // for this call only and were checked for null/valid protocol bounds.
    let key = unsafe { slice::from_raw_parts(key, ATTACHMENT_KEY_LEN) };
    let nonce = unsafe { slice::from_raw_parts(nonce, ATTACHMENT_NONCE_LEN) };
    let aad = unsafe { slice::from_raw_parts(aad, aad_len) };
    let ciphertext = unsafe { slice::from_raw_parts(ciphertext, ciphertext_len) };
    let expected_hash = unsafe { slice::from_raw_parts(expected_hash, ATTACHMENT_HASH_LEN) };
    let plaintext = unsafe { slice::from_raw_parts_mut(plaintext_out, plaintext_out_len) };
    plaintext.copy_from_slice(&ciphertext[..plaintext_out_len]);

    let cipher = match XChaCha20Poly1305::new_from_slice(key) {
        Ok(cipher) => cipher,
        Err(error) => {
            record_error(error);
            return false;
        }
    };
    let tag = Tag::from_slice(&ciphertext[plaintext_out_len..]);
    if let Err(error) =
        cipher.decrypt_in_place_detached(XNonce::from_slice(nonce), aad, plaintext, tag)
    {
        plaintext.fill(0);
        record_error(error);
        return false;
    }
    let actual: [u8; ATTACHMENT_HASH_LEN] = Sha256::digest(&*plaintext).into();
    if actual.as_slice() != expected_hash {
        plaintext.fill(0);
        record_error("native attachment block digest mismatch");
        return false;
    }
    true
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
pub unsafe extern "C" fn conest_iroh_send_v3(
    handle: u64,
    remote_endpoint_id: *const c_char,
    direct_addresses_json: *const c_char,
    bytes: *const u8,
    bytes_len: usize,
    allow_relay: bool,
) -> *mut c_char {
    let Some(transport) = transport(handle) else {
        record_error("unknown native transport handle");
        return std::ptr::null_mut();
    };
    if remote_endpoint_id.is_null() || direct_addresses_json.is_null() || bytes.is_null() {
        record_error("null Iroh send argument");
        return std::ptr::null_mut();
    }
    // SAFETY: strings are NUL-terminated and buffers remain live for this
    // synchronous call, as guaranteed by the Dart bridge.
    let endpoint = match unsafe { CStr::from_ptr(remote_endpoint_id) }.to_str() {
        Ok(value) => value.to_owned(),
        Err(error) => {
            record_error(error);
            return std::ptr::null_mut();
        }
    };
    let direct_addresses_json = match unsafe { CStr::from_ptr(direct_addresses_json) }.to_str() {
        Ok(value) => value,
        Err(error) => {
            record_error(error);
            return std::ptr::null_mut();
        }
    };
    let direct_addresses = match serde_json::from_str::<Vec<String>>(direct_addresses_json) {
        Ok(value) => value,
        Err(error) => {
            record_error(error);
            return std::ptr::null_mut();
        }
    };
    // SAFETY: Dart provides a readable buffer of exactly `bytes_len` bytes.
    let payload = unsafe { slice::from_raw_parts(bytes, bytes_len) }.to_vec();
    match RUNTIME.block_on(transport.send_envelope_with_hints(
        endpoint,
        direct_addresses,
        payload,
        allow_relay,
    )) {
        Ok(receipt) => json_string(&receipt),
        Err(error) => {
            record_error(error);
            std::ptr::null_mut()
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn conest_iroh_send_datagram(
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
        record_error("null Iroh datagram argument");
        return std::ptr::null_mut();
    }
    let endpoint = match unsafe { CStr::from_ptr(remote_endpoint_id) }.to_str() {
        Ok(value) => value.to_owned(),
        Err(error) => {
            record_error(error);
            return std::ptr::null_mut();
        }
    };
    let payload = unsafe { slice::from_raw_parts(bytes, bytes_len) }.to_vec();
    match RUNTIME.block_on(transport.send_datagram(endpoint, payload, allow_relay)) {
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
pub extern "C" fn conest_iroh_next_datagram(handle: u64) -> *mut c_char {
    let Some(transport) = transport(handle) else {
        record_error("unknown native transport handle");
        return std::ptr::null_mut();
    };
    let Some(NativeInboundDatagram {
        sender_endpoint_id,
        bytes,
        path,
    }) = RUNTIME.block_on(transport.try_next_datagram())
    else {
        return std::ptr::null_mut();
    };
    json_string(&InboundDatagramJson {
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

#[cfg(test)]
mod attachment_crypto_tests {
    use super::{conest_attachment_decrypt_block, conest_attachment_encrypt_block};

    #[test]
    fn binary_ffi_round_trip_and_tamper_rejection() {
        let key = [0x11_u8; 32];
        let nonce = [0x22_u8; 24];
        let aad = b"manifest-bound attachment block";
        let plaintext: Vec<u8> = (0..128 * 1024).map(|index| index as u8).collect();
        let mut ciphertext = vec![0_u8; plaintext.len() + 16];
        let mut hash = [0_u8; 32];
        // SAFETY: every pointer references the exact live buffer length passed.
        assert!(unsafe {
            conest_attachment_encrypt_block(
                key.as_ptr(),
                nonce.as_ptr(),
                aad.as_ptr(),
                aad.len(),
                plaintext.as_ptr(),
                plaintext.len(),
                ciphertext.as_mut_ptr(),
                ciphertext.len(),
                hash.as_mut_ptr(),
            )
        });
        let mut decrypted = vec![0_u8; plaintext.len()];
        // SAFETY: every pointer references the exact live buffer length passed.
        assert!(unsafe {
            conest_attachment_decrypt_block(
                key.as_ptr(),
                nonce.as_ptr(),
                aad.as_ptr(),
                aad.len(),
                ciphertext.as_ptr(),
                ciphertext.len(),
                hash.as_ptr(),
                decrypted.as_mut_ptr(),
                decrypted.len(),
            )
        });
        assert_eq!(decrypted, plaintext);

        ciphertext[123] ^= 0x80;
        decrypted.fill(0x55);
        // SAFETY: every pointer references the exact live buffer length passed.
        assert!(!unsafe {
            conest_attachment_decrypt_block(
                key.as_ptr(),
                nonce.as_ptr(),
                aad.as_ptr(),
                aad.len(),
                ciphertext.as_ptr(),
                ciphertext.len(),
                hash.as_ptr(),
                decrypted.as_mut_ptr(),
                decrypted.len(),
            )
        });
        assert!(decrypted.iter().all(|byte| *byte == 0));
    }
}
