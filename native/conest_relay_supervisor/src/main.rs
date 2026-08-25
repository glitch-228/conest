use std::env;
use std::fs::{self, File};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64_STANDARD;
use ed25519_dalek::{Signature, Verifier, VerifyingKey};
use rand::Rng;
use semver::Version;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

const CHECK_INTERVAL: Duration = Duration::from_secs(6 * 60 * 60);
const MAX_MANIFEST_BYTES: usize = 512 * 1024;
const MAX_SIGNATURE_BYTES: usize = 4096;
const MAX_RELAY_BYTES: usize = 256 * 1024 * 1024;
const HEALTH_DEADLINE: Duration = Duration::from_secs(30);

fn main() {
    if let Err(error) = run() {
        eprintln!("conest_relay_supervisor: {error}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), String> {
    let (command, config) = Config::from_args()?;
    match command.as_str() {
        "install" => install_service(&config),
        "uninstall" => uninstall_service(),
        "start" => start_service(&config),
        "stop" => stop_service(&config),
        "status" => print_status(&config),
        "update-now" => {
            let staged = check_and_stage_update(&config)?;
            println!(
                "{}",
                staged
                    .map(|value| format!("staged relay {value}"))
                    .unwrap_or_else(|| "relay is already current".to_owned())
            );
            Ok(())
        }
        "rollback" => rollback(&config),
        "serve" => serve(&config),
        _ => Err(usage()),
    }
}

#[derive(Clone)]
struct Config {
    data_dir: PathBuf,
    bundle_dir: PathBuf,
    relay_bind: String,
    channel: String,
    manifest_url: Option<String>,
    release_public_key: Option<String>,
    maintenance_start_hour: u8,
}

impl Config {
    fn from_args() -> Result<(String, Self), String> {
        let mut args = env::args().skip(1);
        let command = args.next().ok_or_else(usage)?;
        if command == "--help" || command == "-h" {
            return Err(usage());
        }
        let mut data_dir = env::var("CONEST_RELAY_DATA_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|_| PathBuf::from("conest-relay-data"));
        let mut bundle_dir = env::var("CONEST_RELAY_BUNDLE_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|_| PathBuf::from("conest-relay-bundle"));
        let mut relay_bind =
            env::var("CONEST_RELAY_BIND").unwrap_or_else(|_| "127.0.0.1:7667".to_owned());
        let mut channel = env::var("CONEST_RELAY_CHANNEL").unwrap_or_else(|_| "stable".to_owned());
        let mut manifest_url = env::var("CONEST_RELAY_RELEASE_MANIFEST_URL").ok();
        let mut release_public_key = env::var("CONEST_RELEASE_MANIFEST_PUBLIC_KEY").ok();
        let mut maintenance_start_hour = env::var("CONEST_RELAY_MAINTENANCE_HOUR")
            .ok()
            .and_then(|value| value.parse().ok())
            .unwrap_or(3);
        while let Some(option) = args.next() {
            let value = match option.as_str() {
                "--data-dir"
                | "--bundle-dir"
                | "--bind"
                | "--channel"
                | "--manifest-url"
                | "--release-public-key"
                | "--maintenance-hour" => args
                    .next()
                    .ok_or_else(|| format!("{option} requires a value"))?,
                _ => return Err(format!("unknown option {option}\n\n{}", usage())),
            };
            match option.as_str() {
                "--data-dir" => data_dir = PathBuf::from(value),
                "--bundle-dir" => bundle_dir = PathBuf::from(value),
                "--bind" => relay_bind = value,
                "--channel" => channel = value,
                "--manifest-url" => manifest_url = Some(value),
                "--release-public-key" => release_public_key = Some(value),
                "--maintenance-hour" => {
                    maintenance_start_hour = value
                        .parse()
                        .map_err(|_| "maintenance hour must be 0..23".to_owned())?
                }
                _ => unreachable!(),
            }
        }
        if channel != "stable" && channel != "nightly" {
            return Err("channel must be stable or nightly".to_owned());
        }
        if maintenance_start_hour > 23 {
            return Err("maintenance hour must be 0..23".to_owned());
        }
        Ok((
            command,
            Self {
                data_dir,
                bundle_dir,
                relay_bind,
                channel,
                manifest_url,
                release_public_key,
                maintenance_start_hour,
            },
        ))
    }

    fn relay_binary(&self) -> PathBuf {
        self.bundle_dir.join(if cfg!(windows) {
            "conest_relay.exe"
        } else {
            "conest_relay"
        })
    }

    fn staged_binary(&self) -> PathBuf {
        self.bundle_dir.join(if cfg!(windows) {
            "conest_relay.staged.exe"
        } else {
            "conest_relay.staged"
        })
    }

    fn previous_binary(&self) -> PathBuf {
        self.bundle_dir.join(if cfg!(windows) {
            "conest_relay.previous.exe"
        } else {
            "conest_relay.previous"
        })
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ReleaseManifest {
    version: u32,
    tag_name: String,
    release_version: String,
    channel: String,
    minimum_supervisor_version: String,
    assets: Vec<ReleaseAsset>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ReleaseAsset {
    name: String,
    sha256: String,
    size_bytes: u64,
    role: String,
    platform: String,
    architecture: String,
}

#[derive(Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct SupervisorState {
    channel: String,
    current_version: Option<String>,
    previous_version: Option<String>,
    staged_version: Option<String>,
    relay_identity_key: Option<String>,
    last_update_result: Option<String>,
    started_at_millis: Option<u64>,
    draining: bool,
    supervisor_pid: Option<u32>,
}

#[derive(Debug, Deserialize)]
struct RelayWireResponse {
    ok: bool,
    stats: Option<RelayHealth>,
    messages: Option<Vec<serde_json::Value>>,
}

#[derive(Debug, Deserialize)]
struct RelayHealth {
    version: String,
    identity_public_key: String,
    queued_envelope_count: u64,
    queued_bytes: u64,
    active_leases: u64,
}

fn serve(config: &Config) -> Result<(), String> {
    prepare_directories(config)?;
    let mut state = read_state(config)?;
    state.channel = config.channel.clone();
    state.started_at_millis = Some(now_millis());
    state.supervisor_pid = Some(std::process::id());
    write_state(config, &state)?;
    let mut relay = spawn_relay(config)?;
    let initial_health = wait_for_health(
        config,
        state.current_version.as_deref(),
        state.relay_identity_key.as_deref(),
    )?;
    state.current_version = Some(initial_health.version);
    state.relay_identity_key = Some(initial_health.identity_public_key);
    state.last_update_result = Some("relay startup health passed".to_owned());
    write_state(config, &state)?;
    let mut next_check = SystemTime::now() + jittered_check_interval();
    loop {
        if let Some(status) = relay.try_wait().map_err(|error| error.to_string())? {
            state.last_update_result = Some(format!("relay exited with {status}; restarting"));
            write_state(config, &state)?;
            thread::sleep(Duration::from_secs(2));
            relay = spawn_relay(config)?;
        }
        if SystemTime::now() >= next_check {
            match check_and_stage_update(config) {
                Ok(Some(_)) => state = read_state(config)?,
                Ok(_) => {}
                Err(error) => {
                    state.last_update_result = Some(format!("update check failed: {error}"));
                    write_state(config, &state)?;
                }
            }
            next_check = SystemTime::now() + jittered_check_interval();
        }
        if should_apply_staged(&state, in_maintenance_window(config.maintenance_start_hour)) {
            state.draining = true;
            write_state(config, &state)?;
            stop_child(&mut relay)?;
            match apply_staged_and_verify(config, &mut state) {
                Ok(child) => relay = child,
                Err(error) => {
                    let rollback_result = rollback_binary(config);
                    state.current_version = state.previous_version.take();
                    state.staged_version = None;
                    state.draining = false;
                    state.last_update_result = Some(match &rollback_result {
                        Ok(()) => format!("update failed and rolled back: {error}"),
                        Err(rollback_error) => {
                            format!("update failed: {error}; rollback failed: {rollback_error}")
                        }
                    });
                    write_state(config, &state)?;
                    rollback_result?;
                    relay = spawn_relay(config)?;
                }
            }
        } else if state.staged_version.is_none() {
            // `update-now` may stage from a separate process. Pick up that
            // atomic state file without waiting for the next six-hour check.
            let persisted = read_state(config)?;
            if persisted.staged_version.is_some() {
                state = persisted;
            }
        }
        thread::sleep(Duration::from_secs(2));
    }
}

fn should_apply_staged(state: &SupervisorState, maintenance_window_open: bool) -> bool {
    state.staged_version.is_some() && maintenance_window_open
}

fn apply_staged_and_verify(config: &Config, state: &mut SupervisorState) -> Result<Child, String> {
    let staged = config.staged_binary();
    if !staged.is_file() {
        return Err("no staged relay update".to_owned());
    }
    let current = config.relay_binary();
    let previous = config.previous_binary();
    if previous.exists() {
        fs::remove_file(&previous).map_err(|error| error.to_string())?;
    }
    if current.exists() {
        fs::rename(&current, &previous).map_err(|error| error.to_string())?;
    }
    fs::rename(&staged, &current).map_err(|error| error.to_string())?;
    set_executable(&current)?;
    let mut child = spawn_relay(config)?;
    let expected_version = state.staged_version.clone();
    let expected_identity = state.relay_identity_key.clone();
    match wait_for_health(
        config,
        expected_version.as_deref(),
        expected_identity.as_deref(),
    ) {
        Ok(health) => {
            state.previous_version = state.current_version.take();
            state.current_version = Some(health.version);
            state.relay_identity_key = Some(health.identity_public_key);
            state.staged_version = None;
            state.draining = false;
            state.last_update_result = Some("update applied and loopback health passed".to_owned());
            write_state(config, state)?;
            Ok(child)
        }
        Err(error) => {
            let _ = stop_child(&mut child);
            Err(error)
        }
    }
}

fn check_and_stage_update(config: &Config) -> Result<Option<String>, String> {
    let manifest_url = config
        .manifest_url
        .as_deref()
        .ok_or_else(|| "manifest URL is not configured".to_owned())?;
    let key_text = config
        .release_public_key
        .as_deref()
        .ok_or_else(|| "release public key is not configured".to_owned())?;
    let manifest_bytes = download_bounded(manifest_url, MAX_MANIFEST_BYTES)?;
    let signature_url = sibling_url(manifest_url, "RELEASE-MANIFEST.ed25519.sig")?;
    let signature_text = String::from_utf8(download_bounded(&signature_url, MAX_SIGNATURE_BYTES)?)
        .map_err(|_| "release signature is not UTF-8".to_owned())?;
    verify_manifest_signature(&manifest_bytes, signature_text.trim(), key_text)?;
    let manifest: ReleaseManifest =
        serde_json::from_slice(&manifest_bytes).map_err(|error| error.to_string())?;
    validate_manifest(config, &manifest)?;
    let state = read_state(config)?;
    if !is_newer(&manifest.release_version, state.current_version.as_deref())? {
        return Ok(None);
    }
    let platform = current_platform();
    let architecture = current_architecture();
    let asset = manifest
        .assets
        .iter()
        .find(|asset| {
            asset.role == "relay"
                && asset.platform == platform
                && asset.architecture == architecture
        })
        .ok_or_else(|| format!("manifest has no relay for {platform}/{architecture}"))?;
    if asset.size_bytes == 0 || asset.size_bytes as usize > MAX_RELAY_BYTES {
        return Err("relay asset size is outside the accepted range".to_owned());
    }
    if Path::new(&asset.name)
        .file_name()
        .and_then(|value| value.to_str())
        != Some(&asset.name)
    {
        return Err("relay asset name is unsafe".to_owned());
    }
    let asset_url = sibling_url(manifest_url, &asset.name)?;
    let bytes = download_bounded(&asset_url, asset.size_bytes as usize)?;
    if bytes.len() as u64 != asset.size_bytes {
        return Err("relay asset size did not match signed manifest".to_owned());
    }
    let actual = format!("{:x}", Sha256::digest(&bytes));
    if actual != asset.sha256.to_ascii_lowercase() {
        return Err("relay asset SHA-256 did not match signed manifest".to_owned());
    }
    prepare_directories(config)?;
    atomic_write(&config.staged_binary(), &bytes)?;
    set_executable(&config.staged_binary())?;
    let mut state = state;
    state.channel = config.channel.clone();
    state.staged_version = Some(manifest.release_version.clone());
    state.last_update_result = Some(format!("staged signed {}", manifest.tag_name));
    write_state(config, &state)?;
    Ok(Some(manifest.release_version))
}

fn validate_manifest(config: &Config, manifest: &ReleaseManifest) -> Result<(), String> {
    // Version 1 remains the rollout wire format so supervisors shipped before
    // the additive relay metadata was introduced can still consume the first
    // updated nightly. Version 2 is accepted for a future schema cutover.
    if manifest.version != 1 && manifest.version != 2 {
        return Err(format!(
            "unsupported release manifest version {}",
            manifest.version
        ));
    }
    if manifest.channel != config.channel {
        return Err(format!(
            "release channel {} does not match installed {} channel",
            manifest.channel, config.channel
        ));
    }
    let minimum = Version::parse(&manifest.minimum_supervisor_version)
        .map_err(|error| format!("invalid minimum supervisor version: {error}"))?;
    let running = Version::parse(env!("CARGO_PKG_VERSION")).map_err(|error| error.to_string())?;
    if running < minimum {
        return Err(format!(
            "supervisor {running} is older than required {minimum}"
        ));
    }
    Version::parse(&manifest.release_version)
        .map_err(|error| format!("invalid release version: {error}"))?;
    Ok(())
}

fn verify_manifest_signature(manifest: &[u8], signature: &str, key: &str) -> Result<(), String> {
    let key_bytes = BASE64_STANDARD
        .decode(key.trim())
        .map_err(|error| error.to_string())?;
    let signature_bytes = BASE64_STANDARD
        .decode(signature)
        .map_err(|error| error.to_string())?;
    let key: [u8; 32] = key_bytes
        .try_into()
        .map_err(|_| "release public key must be 32 bytes".to_owned())?;
    let signature: [u8; 64] = signature_bytes
        .try_into()
        .map_err(|_| "release signature must be 64 bytes".to_owned())?;
    VerifyingKey::from_bytes(&key)
        .map_err(|error| error.to_string())?
        .verify(manifest, &Signature::from_bytes(&signature))
        .map_err(|_| "release manifest signature verification failed".to_owned())
}

fn spawn_relay(config: &Config) -> Result<Child, String> {
    prepare_directories(config)?;
    let binary = config.relay_binary();
    if !binary.is_file() {
        return Err(format!("relay binary is missing at {}", binary.display()));
    }
    Command::new(binary)
        .arg(&config.relay_bind)
        .arg("--identity-seed-path")
        .arg(config.data_dir.join("relay-identity.seed"))
        .arg("--database-path")
        .arg(config.data_dir.join("relay.sqlite3"))
        .stdin(Stdio::null())
        .spawn()
        .map_err(|error| format!("starting relay: {error}"))
}

fn wait_for_health(
    config: &Config,
    expected_version: Option<&str>,
    expected_identity: Option<&str>,
) -> Result<RelayHealth, String> {
    let deadline = SystemTime::now() + HEALTH_DEADLINE;
    let mut last_error = "relay health not attempted".to_owned();
    while SystemTime::now() < deadline {
        match relay_health(config) {
            Ok(health) => {
                if expected_version.is_some_and(|value| value != health.version) {
                    last_error = format!("relay reported unexpected version {}", health.version);
                } else if expected_identity.is_some_and(|value| value != health.identity_public_key)
                {
                    return Err("relay identity changed during update".to_owned());
                } else if loopback_store_fetch(config).is_err() {
                    last_error = "loopback store/fetch failed".to_owned();
                } else {
                    return Ok(health);
                }
            }
            Err(error) => last_error = error,
        }
        thread::sleep(Duration::from_millis(500));
    }
    Err(format!(
        "relay failed its 30-second health gate: {last_error}"
    ))
}

fn relay_health(config: &Config) -> Result<RelayHealth, String> {
    let response = relay_request(config, serde_json::json!({"action": "health"}))?;
    if !response.ok {
        return Err("relay health returned not-ok".to_owned());
    }
    let health = response
        .stats
        .ok_or_else(|| "relay omitted health stats".to_owned())?;
    let _ = (
        health.queued_envelope_count,
        health.queued_bytes,
        health.active_leases,
    );
    Ok(health)
}

fn loopback_store_fetch(config: &Config) -> Result<(), String> {
    let mailbox = format!("supervisor-{}", now_millis());
    let message_id = format!("health-{}", now_millis());
    let stored = relay_request(
        config,
        serde_json::json!({
            "action": "store",
            "recipient_device_id": mailbox,
            "envelope": {"kind":"health_probe", "messageId": message_id}
        }),
    )?;
    if !stored.ok {
        return Err("health probe store failed".to_owned());
    }
    let fetched = relay_request(
        config,
        serde_json::json!({
            "action": "fetch",
            "recipient_device_id": mailbox,
            "limit": 1
        }),
    )?;
    if !fetched.ok || fetched.messages.unwrap_or_default().is_empty() {
        return Err("health probe fetch failed".to_owned());
    }
    Ok(())
}

fn relay_request(config: &Config, value: serde_json::Value) -> Result<RelayWireResponse, String> {
    let address = config
        .relay_bind
        .to_socket_addrs()
        .map_err(|error| error.to_string())?
        .next()
        .ok_or_else(|| "relay bind did not resolve".to_owned())?;
    let mut stream = TcpStream::connect_timeout(&address, Duration::from_secs(2))
        .map_err(|error| error.to_string())?;
    stream
        .set_read_timeout(Some(Duration::from_secs(2)))
        .map_err(|error| error.to_string())?;
    serde_json::to_writer(&mut stream, &value).map_err(|error| error.to_string())?;
    stream.write_all(b"\n").map_err(|error| error.to_string())?;
    stream.flush().map_err(|error| error.to_string())?;
    let mut line = String::new();
    BufReader::new(stream)
        .read_line(&mut line)
        .map_err(|error| error.to_string())?;
    serde_json::from_str(&line).map_err(|error| error.to_string())
}

fn install_service(config: &Config) -> Result<(), String> {
    prepare_directories(config)?;
    let executable = env::current_exe().map_err(|error| error.to_string())?;
    #[cfg(target_os = "linux")]
    {
        let exec_start = std::iter::once(executable.to_string_lossy().into_owned())
            .chain(serve_arguments(config))
            .map(|value| shell_escape_value(&value))
            .collect::<Vec<_>>()
            .join(" ");
        let unit = format!(
            "[Unit]\nDescription=Conest Relay Supervisor\nAfter=network-online.target\n\n[Service]\nExecStart={exec_start}\nRestart=always\nRestartSec=3\n\n[Install]\nWantedBy=multi-user.target\n",
        );
        let path = PathBuf::from("/etc/systemd/system/conest-relay.service");
        fs::write(&path, unit).map_err(|error| format!("writing {}: {error}", path.display()))?;
        command_ok("systemctl", &["daemon-reload"])?;
        command_ok("systemctl", &["enable", "--now", "conest-relay.service"])
    }
    #[cfg(target_os = "windows")]
    {
        let bin_path = std::iter::once(executable.to_string_lossy().into_owned())
            .chain(serve_arguments(config))
            .map(|value| windows_service_argument(&value))
            .collect::<Vec<_>>()
            .join(" ");
        command_ok(
            "sc.exe",
            &[
                "create",
                "ConestRelay",
                "start=",
                "auto",
                "binPath=",
                &bin_path,
            ],
        )?;
        command_ok("sc.exe", &["start", "ConestRelay"])
    }
    #[cfg(not(any(target_os = "linux", target_os = "windows")))]
    Err("service installation is supported on Linux and Windows".to_owned())
}

fn serve_arguments(config: &Config) -> Vec<String> {
    let mut arguments = vec![
        "serve".to_owned(),
        "--data-dir".to_owned(),
        config.data_dir.to_string_lossy().into_owned(),
        "--bundle-dir".to_owned(),
        config.bundle_dir.to_string_lossy().into_owned(),
        "--bind".to_owned(),
        config.relay_bind.clone(),
        "--channel".to_owned(),
        config.channel.clone(),
        "--maintenance-hour".to_owned(),
        config.maintenance_start_hour.to_string(),
    ];
    if let Some(manifest_url) = &config.manifest_url {
        arguments.push("--manifest-url".to_owned());
        arguments.push(manifest_url.clone());
    }
    if let Some(release_public_key) = &config.release_public_key {
        arguments.push("--release-public-key".to_owned());
        arguments.push(release_public_key.clone());
    }
    arguments
}

fn uninstall_service() -> Result<(), String> {
    #[cfg(target_os = "linux")]
    {
        let _ = command_ok("systemctl", &["disable", "--now", "conest-relay.service"]);
        fs::remove_file("/etc/systemd/system/conest-relay.service")
            .map_err(|error| error.to_string())?;
        command_ok("systemctl", &["daemon-reload"])
    }
    #[cfg(target_os = "windows")]
    {
        let _ = command_ok("sc.exe", &["stop", "ConestRelay"]);
        command_ok("sc.exe", &["delete", "ConestRelay"])
    }
    #[cfg(not(any(target_os = "linux", target_os = "windows")))]
    Err("service installation is supported on Linux and Windows".to_owned())
}

fn start_service(_config: &Config) -> Result<(), String> {
    #[cfg(target_os = "linux")]
    return command_ok("systemctl", &["start", "conest-relay.service"]);
    #[cfg(target_os = "windows")]
    return command_ok("sc.exe", &["start", "ConestRelay"]);
    #[allow(unreachable_code)]
    {
        let executable = env::current_exe().map_err(|error| error.to_string())?;
        Command::new(executable)
            .arg("serve")
            .arg("--data-dir")
            .arg(&_config.data_dir)
            .arg("--bundle-dir")
            .arg(&_config.bundle_dir)
            .spawn()
            .map_err(|error| error.to_string())?;
        Ok(())
    }
}

fn stop_service(_config: &Config) -> Result<(), String> {
    #[cfg(target_os = "linux")]
    return command_ok("systemctl", &["stop", "conest-relay.service"]);
    #[cfg(target_os = "windows")]
    return command_ok("sc.exe", &["stop", "ConestRelay"]);
    #[allow(unreachable_code)]
    {
        let state = read_state(_config)?;
        let pid = state
            .supervisor_pid
            .ok_or_else(|| "no running supervisor pid".to_owned())?;
        command_ok("kill", &[&pid.to_string()])
    }
}

fn rollback(config: &Config) -> Result<(), String> {
    rollback_binary(config)?;
    let mut state = read_state(config)?;
    state.current_version = state.previous_version.take();
    state.staged_version = None;
    state.draining = false;
    state.last_update_result = Some("operator rollback applied".to_owned());
    write_state(config, &state)
}

fn rollback_binary(config: &Config) -> Result<(), String> {
    let previous = config.previous_binary();
    if !previous.is_file() {
        return Err("no previous relay bundle is available".to_owned());
    }
    let current = config.relay_binary();
    let failed = current.with_extension("failed");
    if failed.exists() {
        fs::remove_file(&failed).map_err(|error| error.to_string())?;
    }
    if current.exists() {
        fs::rename(&current, failed).map_err(|error| error.to_string())?;
    }
    fs::rename(previous, &current).map_err(|error| error.to_string())?;
    set_executable(&current)
}

fn print_status(config: &Config) -> Result<(), String> {
    let state = read_state(config)?;
    let health = relay_health(config).ok();
    println!(
        "{}",
        serde_json::to_string_pretty(&serde_json::json!({
            "supervisorVersion": env!("CARGO_PKG_VERSION"),
            "channel": state.channel,
            "currentVersion": state.current_version,
            "uptimeSeconds": state.started_at_millis.map(|at| now_millis().saturating_sub(at) / 1000),
            "draining": state.draining,
            "lastUpdateResult": state.last_update_result,
            "relay": health.map(|value| serde_json::json!({
                "version": value.version,
                "identityPublicKey": value.identity_public_key,
                "queueDepth": value.queued_envelope_count,
                "queueBytes": value.queued_bytes,
                "activeLeases": value.active_leases,
            })),
        }))
        .map_err(|error| error.to_string())?
    );
    Ok(())
}

fn prepare_directories(config: &Config) -> Result<(), String> {
    fs::create_dir_all(&config.data_dir).map_err(|error| error.to_string())?;
    fs::create_dir_all(&config.bundle_dir).map_err(|error| error.to_string())
}

fn read_state(config: &Config) -> Result<SupervisorState, String> {
    let path = config.data_dir.join("supervisor-state.json");
    if !path.exists() {
        return Ok(SupervisorState {
            channel: config.channel.clone(),
            ..SupervisorState::default()
        });
    }
    let bytes = fs::read(path).map_err(|error| error.to_string())?;
    serde_json::from_slice(&bytes).map_err(|error| error.to_string())
}

fn write_state(config: &Config, state: &SupervisorState) -> Result<(), String> {
    prepare_directories(config)?;
    let bytes = serde_json::to_vec_pretty(state).map_err(|error| error.to_string())?;
    atomic_write(&config.data_dir.join("supervisor-state.json"), &bytes)
}

fn atomic_write(path: &Path, bytes: &[u8]) -> Result<(), String> {
    let temporary = path.with_extension("tmp");
    let mut file = File::create(&temporary).map_err(|error| error.to_string())?;
    file.write_all(bytes).map_err(|error| error.to_string())?;
    file.sync_all().map_err(|error| error.to_string())?;
    if path.exists() {
        fs::remove_file(path).map_err(|error| error.to_string())?;
    }
    fs::rename(temporary, path).map_err(|error| error.to_string())
}

fn download_bounded(url: &str, max_bytes: usize) -> Result<Vec<u8>, String> {
    if !url.starts_with("https://") && !url.starts_with("http://127.0.0.1:") {
        return Err("update URLs must use HTTPS (loopback HTTP is allowed for tests)".to_owned());
    }
    let response = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(30))
        .build()
        .map_err(|error| error.to_string())?
        .get(url)
        .send()
        .map_err(|error| error.to_string())?
        .error_for_status()
        .map_err(|error| error.to_string())?;
    if response
        .content_length()
        .is_some_and(|length| length > max_bytes as u64)
    {
        return Err("update response exceeds its signed size limit".to_owned());
    }
    let mut bytes = Vec::new();
    response
        .take((max_bytes + 1) as u64)
        .read_to_end(&mut bytes)
        .map_err(|error| error.to_string())?;
    if bytes.len() > max_bytes {
        return Err("update response exceeds its size limit".to_owned());
    }
    Ok(bytes)
}

fn sibling_url(url: &str, name: &str) -> Result<String, String> {
    let (base, _) = url
        .rsplit_once('/')
        .ok_or_else(|| "manifest URL has no path".to_owned())?;
    Ok(format!("{base}/{name}"))
}

fn is_newer(candidate: &str, current: Option<&str>) -> Result<bool, String> {
    let candidate = Version::parse(candidate).map_err(|error| error.to_string())?;
    let Some(current) = current else {
        return Ok(true);
    };
    let current = Version::parse(current).map_err(|error| error.to_string())?;
    Ok(candidate > current)
}

fn stop_child(child: &mut Child) -> Result<(), String> {
    child.kill().map_err(|error| error.to_string())?;
    child.wait().map_err(|error| error.to_string())?;
    Ok(())
}

fn jittered_check_interval() -> Duration {
    let jitter = rand::thread_rng().gen_range(0..=30 * 60);
    CHECK_INTERVAL + Duration::from_secs(jitter)
}

fn in_maintenance_window(start_hour: u8) -> bool {
    let seconds = now_millis() / 1000;
    let local_offset_seconds = env::var("CONEST_RELAY_LOCAL_UTC_OFFSET_SECONDS")
        .ok()
        .and_then(|value| value.parse::<i64>().ok())
        .unwrap_or(0);
    let local_seconds = (seconds as i64 + local_offset_seconds).rem_euclid(24 * 60 * 60);
    (local_seconds / 3600) as u8 == start_hour
}

fn current_platform() -> &'static str {
    if cfg!(windows) { "windows" } else { "linux" }
}

fn current_architecture() -> &'static str {
    if cfg!(target_arch = "aarch64") {
        "arm64"
    } else {
        "x86_64"
    }
}

fn command_ok(program: &str, args: &[&str]) -> Result<(), String> {
    let status = Command::new(program)
        .args(args)
        .status()
        .map_err(|error| format!("running {program}: {error}"))?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("{program} exited with {status}"))
    }
}

#[cfg(unix)]
fn set_executable(path: &Path) -> Result<(), String> {
    use std::os::unix::fs::PermissionsExt;
    let mut permissions = fs::metadata(path)
        .map_err(|error| error.to_string())?
        .permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(path, permissions).map_err(|error| error.to_string())
}

#[cfg(not(unix))]
fn set_executable(_path: &Path) -> Result<(), String> {
    Ok(())
}

#[cfg(target_os = "linux")]
fn shell_escape_value(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

#[cfg(target_os = "windows")]
fn windows_service_argument(value: &str) -> String {
    if value.bytes().all(|byte| !byte.is_ascii_whitespace()) && !value.contains('"') {
        return value.to_owned();
    }
    format!("\"{}\"", value.replace('"', "\\\""))
}

fn now_millis() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

fn usage() -> String {
    "usage: conest_relay_supervisor <install|uninstall|start|stop|status|update-now|rollback|serve> [--data-dir PATH] [--bundle-dir PATH] [--bind HOST:PORT] [--channel stable|nightly] [--manifest-url HTTPS_URL] [--release-public-key BASE64] [--maintenance-hour 0..23]".to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_config() -> Config {
        Config {
            data_dir: PathBuf::from("/var/lib/conest relay"),
            bundle_dir: PathBuf::from("/opt/conest relay"),
            relay_bind: "127.0.0.1:7667".to_owned(),
            channel: "nightly".to_owned(),
            manifest_url: Some("https://example.com/nightly/RELEASE-MANIFEST.json".to_owned()),
            release_public_key: Some("cHVibGljLWtleQ==".to_owned()),
            maintenance_start_hour: 4,
        }
    }

    #[test]
    fn monotonic_versions_are_enforced() {
        assert!(is_newer("1.2.0", Some("1.1.9")).unwrap());
        assert!(!is_newer("1.2.0", Some("1.2.0")).unwrap());
        assert!(!is_newer("1.1.9", Some("1.2.0")).unwrap());
    }

    #[test]
    fn unsafe_update_schemes_are_rejected_before_network_io() {
        assert!(download_bounded("http://example.com/release", 10).is_err());
    }

    #[test]
    fn asset_urls_remain_manifest_siblings() {
        assert_eq!(
            sibling_url("https://example.com/r/RELEASE-MANIFEST.json", "relay").unwrap(),
            "https://example.com/r/relay"
        );
    }

    #[test]
    fn installed_service_preserves_update_configuration() {
        let arguments = serve_arguments(&test_config());
        assert!(
            arguments
                .windows(2)
                .any(|pair| pair == ["--channel", "nightly"])
        );
        assert!(arguments.windows(2).any(|pair| pair
            == [
                "--manifest-url",
                "https://example.com/nightly/RELEASE-MANIFEST.json"
            ]));
        assert!(
            arguments
                .windows(2)
                .any(|pair| pair == ["--release-public-key", "cHVibGljLWtleQ=="])
        );
        assert!(
            arguments
                .windows(2)
                .any(|pair| pair == ["--maintenance-hour", "4"])
        );
    }

    #[test]
    fn staged_update_waits_for_and_then_enters_maintenance_window() {
        let mut state = SupervisorState::default();
        assert!(!should_apply_staged(&state, true));
        state.staged_version = Some("0.4.0-nightly.1".to_owned());
        assert!(!should_apply_staged(&state, false));
        assert!(should_apply_staged(&state, true));
    }

    #[test]
    fn operator_rollback_restores_binary_and_persisted_version_state() {
        let root = std::env::temp_dir().join(format!(
            "conest-supervisor-rollback-{}-{}",
            std::process::id(),
            now_millis()
        ));
        let config = Config {
            data_dir: root.join("data"),
            bundle_dir: root.join("bundle"),
            ..test_config()
        };
        prepare_directories(&config).unwrap();
        fs::write(config.relay_binary(), b"new relay").unwrap();
        fs::write(config.previous_binary(), b"old relay").unwrap();
        write_state(
            &config,
            &SupervisorState {
                current_version: Some("0.4.0".to_owned()),
                previous_version: Some("0.3.5".to_owned()),
                staged_version: Some("0.4.1".to_owned()),
                draining: true,
                ..SupervisorState::default()
            },
        )
        .unwrap();

        rollback(&config).unwrap();

        assert_eq!(fs::read(config.relay_binary()).unwrap(), b"old relay");
        let state = read_state(&config).unwrap();
        assert_eq!(state.current_version.as_deref(), Some("0.3.5"));
        assert!(state.previous_version.is_none());
        assert!(state.staged_version.is_none());
        assert!(!state.draining);
        let _ = fs::remove_dir_all(root);
    }
}
