// flutter_rust_bridge 2.x expands its attributes through the internal
// `frb_expand` cfg. Rust's check-cfg lint cannot see that macro-owned name.
#![allow(unexpected_cfgs)]

mod api;
#[cfg(any(target_os = "android", target_os = "linux", target_os = "windows"))]
mod audio;
pub mod beam;
#[cfg(any(target_os = "linux", target_os = "windows"))]
mod desktop_camera;
mod ffi;
pub mod transfer;
#[cfg(any(target_os = "linux", target_os = "windows"))]
mod voice_recording;

pub use api::*;
