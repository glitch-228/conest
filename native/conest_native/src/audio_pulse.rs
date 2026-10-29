//! The sound server's own outputs and microphones on Linux, by their
//! descriptions ("Built-in Audio Analog Stereo"), for Settings → Voice.
//!
//! ALSA offers a running sound server only as a few plugin devices
//! ("pulse", "pipewire", "jack"), which is what a call used to list. The
//! server itself (PulseAudio, or PipeWire through pipewire-pulse) knows the
//! real sinks and sources: `pactl -f json list sinks|sources` names them.
//! A chosen one is opened through the same ALSA "pulse" device as before,
//! with `PULSE_SINK` / `PULSE_SOURCE` set while the stream opens, so the
//! capture and playback path stays the one that is known to work (opening
//! a card directly would take it from every other app).

use std::{
    io::Read,
    process::{Command, Stdio},
    sync::Mutex,
    time::{Duration, Instant},
};

/// Most devices taken from one listing.
const MAX_DEVICES: usize = 64;
/// Most bytes read from `pactl` (a listing is a few kilobytes).
const MAX_OUTPUT_BYTES: u64 = 1 << 20;
/// How long `pactl` may take (a hung sound server must not hang Settings).
const PACTL_TIMEOUT: Duration = Duration::from_secs(3);
/// Longest name or description kept.
const MAX_TEXT: usize = 256;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Kind {
    /// An output (a sink).
    Sink,
    /// A microphone (a source).
    Source,
}

impl Kind {
    fn list_argument(self) -> &'static str {
        match self {
            Kind::Sink => "sinks",
            Kind::Source => "sources",
        }
    }

    fn env_variable(self) -> &'static str {
        match self {
            Kind::Sink => "PULSE_SINK",
            Kind::Source => "PULSE_SOURCE",
        }
    }
}

/// One output or microphone of the sound server.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct PulseDevice {
    /// The server's name for it, what `PULSE_SINK` / `PULSE_SOURCE` take.
    pub name: String,
    /// What the user sees.
    pub description: String,
}

/// The devices in the JSON of `pactl -f json list sinks|sources`. A source
/// that only monitors an output (what that output plays) is left out: it is
/// not a microphone. Anything that does not parse gives no devices.
pub(crate) fn parse_pactl_devices(json: &str, kind: Kind) -> Vec<PulseDevice> {
    let Ok(serde_json::Value::Array(entries)) = serde_json::from_str::<serde_json::Value>(json)
    else {
        return Vec::new();
    };
    let mut devices: Vec<PulseDevice> = Vec::new();
    for entry in entries {
        let Some(name) = entry.get("name").and_then(|value| value.as_str()) else {
            continue;
        };
        if name.is_empty() || name.len() > MAX_TEXT || name.chars().any(char::is_control) {
            continue;
        }
        if kind == Kind::Source {
            let monitors_a_sink = entry
                .get("monitor_of_sink")
                .is_some_and(|value| !value.is_null());
            if monitors_a_sink || name.ends_with(".monitor") {
                continue;
            }
        }
        let description = entry
            .get("description")
            .and_then(|value| value.as_str())
            .map(str::trim)
            .filter(|text| !text.is_empty() && text.len() <= MAX_TEXT)
            .filter(|text| !text.chars().any(char::is_control))
            .unwrap_or(name);
        // Two with one description would be one choice: the first wins.
        if devices.iter().any(|known| known.description == description) {
            continue;
        }
        devices.push(PulseDevice {
            name: name.to_owned(),
            description: description.to_owned(),
        });
        if devices.len() >= MAX_DEVICES {
            break;
        }
    }
    devices
}

/// The server's name for the device the user picked by [description].
pub(crate) fn resolve<'a>(devices: &'a [PulseDevice], description: &str) -> Option<&'a str> {
    devices
        .iter()
        .find(|device| device.description == description)
        .map(|device| device.name.as_str())
}

/// Runs `pactl -f json list <kind>`; None without `pactl`, without a
/// running sound server, on an error or after [PACTL_TIMEOUT].
fn run_pactl(kind: Kind) -> Option<String> {
    let mut child = Command::new("pactl")
        .args(["-f", "json", "list", kind.list_argument()])
        .env("LC_ALL", "C")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let stdout = child.stdout.take()?;
    // Read on a thread so the timeout holds even if pactl blocks.
    let (sender, receiver) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let mut text = String::new();
        let ok = stdout
            .take(MAX_OUTPUT_BYTES)
            .read_to_string(&mut text)
            .is_ok();
        let _ = sender.send(ok.then_some(text));
    });
    let deadline = Instant::now() + PACTL_TIMEOUT;
    let text = loop {
        match receiver.recv_timeout(Duration::from_millis(50)) {
            Ok(text) => break text,
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) if Instant::now() < deadline => {}
            Err(_) => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
        }
    };
    let status = child.wait().ok()?;
    if status.success() { text } else { None }
}

/// The sound server's outputs or microphones; empty without one (the
/// caller then keeps its ALSA list).
pub(crate) fn list(kind: Kind) -> Vec<PulseDevice> {
    run_pactl(kind)
        .map(|json| parse_pactl_devices(&json, kind))
        .unwrap_or_default()
}

/// Serializes changes to the process environment made here.
static ENV_LOCK: Mutex<()> = Mutex::new(());

/// Runs [open] with the server told to use [device] for the next stream of
/// [kind] (the sound server's context reads it when ALSA opens "pulse"),
/// then restores the environment.
pub(crate) fn with_device<T>(kind: Kind, device: &str, open: impl FnOnce() -> T) -> T {
    with_variable(kind.env_variable(), device, open)
}

fn with_variable<T>(variable: &str, value: &str, run: impl FnOnce() -> T) -> T {
    let _guard = ENV_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let before = std::env::var_os(variable);
    // SAFETY: changes made here are serialized by ENV_LOCK, and last only
    // as long as the stream takes to open.
    unsafe { std::env::set_var(variable, value) };
    let result = run();
    // SAFETY: as above.
    unsafe {
        match before {
            Some(old) => std::env::set_var(variable, old),
            None => std::env::remove_var(variable),
        }
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    const SINKS: &str = r#"[
      {"index": 1, "name": "alsa_output.pci-0000_00_1f.3.analog-stereo",
       "description": "Built-in Audio Analog Stereo", "state": "RUNNING",
       "monitor_source": "alsa_output.pci-0000_00_1f.3.analog-stereo.monitor"},
      {"index": 2, "name": "bluez_output.AA_BB.1",
       "description": "WH-1000XM4", "state": "SUSPENDED"}
    ]"#;

    const SOURCES: &str = r#"[
      {"index": 1, "name": "alsa_output.pci-0000_00_1f.3.analog-stereo.monitor",
       "description": "Monitor of Built-in Audio Analog Stereo",
       "monitor_of_sink": 1, "monitor_of_sink_name": "alsa_output.pci"},
      {"index": 2, "name": "alsa_input.pci-0000_00_1f.3.analog-stereo",
       "description": "Built-in Audio Analog Stereo", "monitor_of_sink": null},
      {"index": 3, "name": "bluez_input.AA_BB.0",
       "description": "WH-1000XM4"}
    ]"#;

    #[test]
    fn sinks_are_listed_by_description() {
        let devices = parse_pactl_devices(SINKS, Kind::Sink);
        let descriptions: Vec<_> = devices.iter().map(|d| d.description.as_str()).collect();
        assert_eq!(descriptions, ["Built-in Audio Analog Stereo", "WH-1000XM4"]);
        assert_eq!(devices[1].name, "bluez_output.AA_BB.1");
    }

    #[test]
    fn monitor_sources_are_not_microphones() {
        let devices = parse_pactl_devices(SOURCES, Kind::Source);
        let names: Vec<_> = devices.iter().map(|d| d.name.as_str()).collect();
        assert_eq!(
            names,
            [
                "alsa_input.pci-0000_00_1f.3.analog-stereo",
                "bluez_input.AA_BB.0"
            ]
        );
    }

    #[test]
    fn a_monitor_is_found_by_its_name_even_without_the_sink_field() {
        let json = r#"[{"name": "x.monitor", "description": "Monitor"}]"#;
        assert!(parse_pactl_devices(json, Kind::Source).is_empty());
        // But an output with that name is an output.
        assert_eq!(parse_pactl_devices(json, Kind::Sink).len(), 1);
    }

    #[test]
    fn the_chosen_description_gives_the_servers_name() {
        let devices = parse_pactl_devices(SINKS, Kind::Sink);
        assert_eq!(
            resolve(&devices, "WH-1000XM4"),
            Some("bluez_output.AA_BB.1")
        );
        assert_eq!(resolve(&devices, "PipeWire Sound Server"), None);
    }

    #[test]
    fn a_missing_description_shows_the_name_and_duplicates_collapse() {
        let json = r#"[
          {"name": "a", "description": "Same"},
          {"name": "b", "description": "Same"},
          {"name": "c"}
        ]"#;
        let devices = parse_pactl_devices(json, Kind::Sink);
        assert_eq!(devices.len(), 2);
        assert_eq!(devices[0].name, "a");
        assert_eq!(devices[1].description, "c");
    }

    #[test]
    fn hostile_listings_give_nothing_or_stay_bounded() {
        assert!(parse_pactl_devices("", Kind::Sink).is_empty());
        assert!(parse_pactl_devices("not json", Kind::Sink).is_empty());
        assert!(parse_pactl_devices("{\"name\": \"a\"}", Kind::Sink).is_empty());
        assert!(parse_pactl_devices("[1, null, \"x\", []]", Kind::Sink).is_empty());
        let long = "x".repeat(MAX_TEXT + 1);
        let json = format!(r#"[{{"name": "{long}"}}, {{"name": "a\u0007b"}}]"#);
        assert!(parse_pactl_devices(&json, Kind::Sink).is_empty());
        let many: Vec<String> = (0..500)
            .map(|i| format!(r#"{{"name": "n{i}", "description": "d{i}"}}"#))
            .collect();
        let json = format!("[{}]", many.join(","));
        assert_eq!(parse_pactl_devices(&json, Kind::Sink).len(), MAX_DEVICES);
    }

    #[test]
    fn the_server_is_told_the_device_only_while_the_stream_opens() {
        let variable = "CONEST_TEST_PULSE_SINK_G5";
        // SAFETY: a variable only this test uses.
        unsafe { std::env::remove_var(variable) };
        let seen = with_variable(variable, "sink-a", || std::env::var(variable).ok());
        assert_eq!(seen.as_deref(), Some("sink-a"));
        assert!(std::env::var_os(variable).is_none());
        // A value that was set before comes back.
        // SAFETY: as above.
        unsafe { std::env::set_var(variable, "old") };
        with_variable(variable, "sink-b", || ());
        assert_eq!(std::env::var(variable).as_deref(), Ok("old"));
        // SAFETY: as above.
        unsafe { std::env::remove_var(variable) };
    }
}
