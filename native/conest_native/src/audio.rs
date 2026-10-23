//! Native foreground-call audio. Device callbacks only move bounded PCM
//! samples; Opus work runs on worker threads so it never blocks Flutter.

use std::{
    collections::BTreeMap,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

#[cfg(any(target_os = "linux", target_os = "windows"))]
use anyhow::bail;
use anyhow::{Context, Result};
#[cfg(any(target_os = "linux", target_os = "windows"))]
use cpal::{
    Device, SampleFormat, Stream, StreamConfig, SupportedStreamConfig, SupportedStreamConfigRange,
    traits::{DeviceTrait, HostTrait, StreamTrait},
};
use crossbeam_queue::ArrayQueue;
use opus::{Application, Channels, Encoder};

/// A stream format this code takes: the device's own when it is F32, I16
/// or U16, otherwise F32 (then I16) at the device's rate and channels. A
/// sound server converts; its devices often say 24 or 32 bits (a
/// PulseAudio source on S24LE once made every Linux call fail to open).
#[cfg(any(target_os = "linux", target_os = "windows"))]
pub(crate) fn usable_config(
    default: SupportedStreamConfig,
    supported: Vec<SupportedStreamConfigRange>,
) -> SupportedStreamConfig {
    if matches!(
        default.sample_format(),
        SampleFormat::F32 | SampleFormat::I16 | SampleFormat::U16
    ) {
        return default;
    }
    for format in [SampleFormat::F32, SampleFormat::I16] {
        let mut fallback = None;
        for range in &supported {
            if range.sample_format() != format {
                continue;
            }
            let Some(config) = range.clone().try_with_sample_rate(default.sample_rate()) else {
                continue;
            };
            if config.channels() == default.channels() {
                return config;
            }
            fallback.get_or_insert(config);
        }
        if let Some(config) = fallback {
            return config;
        }
    }
    default
}

#[path = "audio_remote.rs"]
mod remote;
use remote::{ReceiveStats, RemoteMixer};

/// What a call's audio did, for the device lab and call diagnostics: the
/// send side and playout here; the receive side lives in the mixer.
#[derive(Default)]
struct CallCounters {
    /// Opus packets made and queued for the network.
    sent: AtomicU64,
    /// Packets dropped because the network side did not take them in time.
    send_dropped: AtomicU64,
    /// 20 ms frames handed to the speaker.
    played_frames: AtomicU64,
    /// Times the playback queue ran too long and was cut back (latency).
    playback_trimmed: AtomicU64,
}

/// A call's audio statistics (see [VoiceAudioSession::stats]).
#[derive(serde::Serialize)]
pub struct CallStats {
    pub sent: u64,
    pub send_dropped: u64,
    pub played_frames: u64,
    pub playback_trimmed: u64,
    pub received: u64,
    pub late_or_duplicate: u64,
    pub lost: u64,
    pub concealed_frames: u64,
    pub gaps: u64,
    pub jitter_ms: f64,
}

const VOICE_RATE: u32 = 48_000;
const FRAME_SAMPLES: usize = 960; // 20 ms, mono, 48 kHz.
const MAX_OPUS_PACKET: usize = 1_100;
const CAPTURE_QUEUE_SAMPLES: usize = FRAME_SAMPLES * 6;
const PLAYBACK_QUEUE_SAMPLES: usize = FRAME_SAMPLES * 8;
const OPUS_PACKET_QUEUE: usize = 12;
const ECHO_REFERENCE_QUEUE_SAMPLES: usize = VOICE_RATE as usize;
const APM_FRAME_SAMPLES: usize = VOICE_RATE as usize / 100; // AEC3 runs on 10 ms.
const FRAME_PERIOD_NANOS: i128 = 20_000_000;
const MIN_JITTER_WAIT: Duration = Duration::from_millis(20);
const MAX_JITTER_WAIT: Duration = Duration::from_millis(100);
/// Packets waiting behind a missing one (60 ms of audio) that make it not
/// worth waiting for: it is skipped at once, so a hole never stalls audio
/// that is already here.
const SKIP_WAIT_BACKLOG: usize = 3;
/// Packets held at most (160 ms): past it the oldest go, so after a stall
/// the delay comes back down instead of growing for good. (Dropping the
/// newest instead left holes ahead, each waited for in turn: playback fell
/// to a quarter of real time.)
const MAX_BUFFERED_PACKETS: usize = 8;
const HIGH_QUEUE_WATERMARK: usize = OPUS_PACKET_QUEUE * 2 / 3;
const LOW_QUEUE_WATERMARK: usize = OPUS_PACKET_QUEUE / 6;
const MIN_BITRATE: u32 = 16_000;
const MAX_BITRATE: u32 = 32_000;

#[cfg(any(target_os = "linux", target_os = "windows"))]
fn output_device_name(device: &Device) -> Option<String> {
    device
        .description()
        .ok()
        .map(|description| description.name().to_owned())
}

#[derive(Default)]
struct AdaptiveBitrate {
    current: u32,
    congested_frames: u8,
    clear_frames: u8,
}

impl AdaptiveBitrate {
    fn observe(&mut self, queued_packets: usize) -> Option<u32> {
        if self.current == 0 {
            self.current = MAX_BITRATE;
        }
        if queued_packets >= HIGH_QUEUE_WATERMARK {
            self.congested_frames = self.congested_frames.saturating_add(1);
            self.clear_frames = 0;
            if self.congested_frames >= 5 && self.current > MIN_BITRATE {
                self.current = (self.current - 8_000).max(MIN_BITRATE);
                self.congested_frames = 0;
                return Some(self.current);
            }
        } else if queued_packets <= LOW_QUEUE_WATERMARK {
            self.congested_frames = 0;
            self.clear_frames = self.clear_frames.saturating_add(1);
            if self.clear_frames >= 50 && self.current < MAX_BITRATE {
                self.current = (self.current + 8_000).min(MAX_BITRATE);
                self.clear_frames = 0;
                return Some(self.current);
            }
        } else {
            self.congested_frames = 0;
            self.clear_frames = 0;
        }
        None
    }
}

/// Desktop echo cancellation with WebRTC AEC3, the canceller used by
/// WebRTC-based voice stacks such as Discord's and Telegram's. AEC3 estimates
/// the speaker-to-microphone delay itself and handles double-talk, so device
/// latency does not need to match a fixed constant.
struct EchoProcessor {
    apm: sonora::AudioProcessing,
    render: Vec<f32>,
    render_out: Vec<f32>,
    capture_out: Vec<f32>,
}

impl EchoProcessor {
    fn new() -> Self {
        let config = sonora::Config {
            echo_canceller: if cfg!(target_os = "android") {
                None
            } else {
                Some(sonora::config::EchoCanceller::default())
            },
            ..Default::default()
        };
        let stream = sonora::StreamConfig::new(VOICE_RATE, 1);
        Self {
            apm: sonora::AudioProcessing::builder()
                .config(config)
                .capture_config(stream)
                .render_config(stream)
                .build(),
            render: Vec::with_capacity(APM_FRAME_SAMPLES),
            render_out: vec![0.0; APM_FRAME_SAMPLES],
            capture_out: vec![0.0; APM_FRAME_SAMPLES],
        }
    }

    fn set_noise_suppression(&mut self, enabled: bool) {
        if self.apm.config().noise_suppression.is_some() == enabled {
            return;
        }
        let mut config = self.apm.config().clone();
        config.noise_suppression = enabled.then(|| sonora::config::NoiseSuppression {
            level: sonora::config::NoiseSuppressionLevel::High,
            ..Default::default()
        });
        // Changing only NS keeps the echo canceller's convergence state.
        self.apm.apply_config(config);
    }

    /// Cancels echo in one capture frame in place. Every rendered sample is
    /// analyzed before the capture that may contain its echo. While muted the
    /// canceller still sees both streams so it stays converged, but the frame
    /// is replaced with silence.
    fn process_frame(
        &mut self,
        frame: &mut [f32],
        render_reference: &ArrayQueue<f32>,
        capture_backlog_samples: usize,
        muted: bool,
    ) {
        while let Some(sample) = render_reference.pop() {
            self.render.push(sample);
            if self.render.len() == APM_FRAME_SAMPLES {
                let _ = self
                    .apm
                    .process_render_f32(&[&self.render], &mut [&mut self.render_out]);
                self.render.clear();
            }
        }
        // Only a hint: AEC3 runs its own delay estimator. Capture samples
        // still queued behind this frame are the delay the app adds itself.
        let backlog_ms = (capture_backlog_samples * 1_000 / VOICE_RATE as usize) as i32;
        let _ = self.apm.set_stream_delay_ms(backlog_ms);
        if muted {
            frame.fill(0.0);
        }
        let (chunks, _) = frame.as_chunks_mut::<APM_FRAME_SAMPLES>();
        for chunk in chunks {
            if self
                .apm
                .process_capture_f32(&[chunk], &mut [&mut self.capture_out])
                .is_ok()
                && !muted
            {
                chunk.copy_from_slice(&self.capture_out);
            }
        }
    }
}

fn push_render_reference(queue: &ArrayQueue<f32>, sample: f32) {
    if queue.push(sample).is_err() {
        let _ = queue.pop();
        let _ = queue.push(sample);
    }
}

pub struct VoiceAudioSession {
    running: Arc<AtomicBool>,
    muted: Arc<AtomicBool>,
    network_congested: Arc<AtomicBool>,
    noise_suppression: Arc<AtomicBool>,
    platform_noise_suppression: Arc<AtomicBool>,
    failed: Arc<AtomicBool>,
    encoded: Arc<ArrayQueue<Vec<u8>>>,
    incoming: Arc<Mutex<RemoteMixer>>,
    capture: Arc<ArrayQueue<f32>>,
    playback: Arc<ArrayQueue<f32>>,
    render_reference: Arc<ArrayQueue<f32>>,
    counters: Arc<CallCounters>,
    #[cfg(any(target_os = "linux", target_os = "windows"))]
    input_stream: Option<Stream>,
    #[cfg(any(target_os = "linux", target_os = "windows"))]
    output_stream: Option<Stream>,
    workers: Vec<JoinHandle<()>>,
}

impl VoiceAudioSession {
    #[cfg(any(target_os = "linux", target_os = "windows"))]
    pub fn open() -> Result<Self> {
        Self::open_with_output(None)
    }

    #[cfg(any(target_os = "linux", target_os = "windows"))]
    pub fn open_with_output(output_name: Option<&str>) -> Result<Self> {
        let host = cpal::default_host();
        let input = host
            .default_input_device()
            .context("No default microphone device is available")?;
        let output = match output_name {
            Some(name) => host
                .output_devices()
                .context("Could not enumerate audio output devices")?
                .find(|device| output_device_name(device).as_deref() == Some(name))
                .with_context(|| format!("Audio output device '{name}' is unavailable"))?,
            None => host
                .default_output_device()
                .context("No default speaker or headphone device is available")?,
        };

        let mut session = Self::create_codec()?;
        let input_stream = open_input_stream(
            &input,
            session.capture.clone(),
            session.muted.clone(),
            session.failed.clone(),
        )?;
        let output_stream = open_output_stream(
            &output,
            session.playback.clone(),
            session.render_reference.clone(),
            session.failed.clone(),
        )?;
        input_stream
            .play()
            .context("Could not start microphone capture")?;
        output_stream
            .play()
            .context("Could not start speaker playback")?;
        session.input_stream = Some(input_stream);
        session.output_stream = Some(output_stream);
        Ok(session)
    }

    #[cfg(any(target_os = "linux", target_os = "windows"))]
    pub fn output_device_names() -> Vec<String> {
        cpal::default_host()
            .output_devices()
            .ok()
            .into_iter()
            .flatten()
            .filter_map(|device| output_device_name(&device))
            .fold(Vec::new(), |mut names, name| {
                if !names.contains(&name) {
                    names.push(name);
                }
                names
            })
    }

    #[cfg(any(target_os = "linux", target_os = "windows"))]
    pub fn set_output_device(&mut self, name: &str) -> Result<()> {
        let output = cpal::default_host()
            .output_devices()
            .context("Could not enumerate audio output devices")?
            .find(|device| output_device_name(device).as_deref() == Some(name))
            .with_context(|| format!("Audio output device '{name}' is unavailable"))?;
        let output_stream = open_output_stream(
            &output,
            self.playback.clone(),
            self.render_reference.clone(),
            self.failed.clone(),
        )?;
        output_stream
            .play()
            .context("Could not start the selected audio output")?;
        self.output_stream = Some(output_stream);
        Ok(())
    }

    /// Android owns its platform microphone/speaker threads through
    /// AudioRecord/AudioTrack. The native codec and bounded queues remain the
    /// same, and the platform threads exchange PCM through the JNI methods.
    #[cfg(target_os = "android")]
    pub fn open() -> Result<Self> {
        Self::create_codec()
    }

    #[cfg(target_os = "android")]
    pub fn output_device_names() -> Vec<String> {
        Vec::new()
    }

    #[cfg(target_os = "android")]
    pub fn set_output_device(&mut self, _name: &str) -> Result<()> {
        anyhow::bail!("Android audio routing is controlled by the system call route.")
    }

    fn create_codec() -> Result<Self> {
        let running = Arc::new(AtomicBool::new(true));
        let muted = Arc::new(AtomicBool::new(false));
        let network_congested = Arc::new(AtomicBool::new(false));
        let noise_suppression = Arc::new(AtomicBool::new(true));
        let platform_noise_suppression = Arc::new(AtomicBool::new(false));
        let failed = Arc::new(AtomicBool::new(false));
        let capture = Arc::new(ArrayQueue::new(CAPTURE_QUEUE_SAMPLES));
        let playback = Arc::new(ArrayQueue::new(PLAYBACK_QUEUE_SAMPLES));
        let render_reference = Arc::new(ArrayQueue::new(ECHO_REFERENCE_QUEUE_SAMPLES));
        let encoded = Arc::new(ArrayQueue::new(OPUS_PACKET_QUEUE));
        let counters = Arc::new(CallCounters::default());
        let incoming = Arc::new(Mutex::new(
            RemoteMixer::new().context("Could not initialize the remote audio mixer")?,
        ));
        let mut encoder = Encoder::new(VOICE_RATE, Channels::Mono, Application::Voip)
            .context("Could not initialize the Opus encoder")?;
        encoder
            .set_bitrate(opus::Bitrate::Bits(32_000))
            .context("Could not configure the Opus voice bitrate")?;

        let encode_worker = thread::Builder::new()
            .name("conest-call-encoder".into())
            .spawn({
                let running = running.clone();
                let capture = capture.clone();
                let encoded = encoded.clone();
                let render_reference = render_reference.clone();
                let muted = muted.clone();
                let network_congested = network_congested.clone();
                let noise_suppression = noise_suppression.clone();
                let platform_noise_suppression = platform_noise_suppression.clone();
                let counters = counters.clone();
                move || {
                    encode_loop(
                        running,
                        capture,
                        encoded,
                        render_reference,
                        muted,
                        encoder,
                        network_congested,
                        noise_suppression,
                        platform_noise_suppression,
                        counters,
                    )
                }
            })
            .context("Could not start the call encoder")?;
        let decode_worker = match thread::Builder::new()
            .name("conest-call-decoder".into())
            .spawn({
                let running = running.clone();
                let incoming = incoming.clone();
                let playback = playback.clone();
                let counters = counters.clone();
                move || decode_loop(running, incoming, playback, counters)
            }) {
            Ok(worker) => worker,
            Err(error) => {
                running.store(false, Ordering::Relaxed);
                let _ = encode_worker.join();
                return Err(error).context("Could not start the call decoder");
            }
        };

        Ok(Self {
            running,
            muted,
            network_congested,
            noise_suppression,
            platform_noise_suppression,
            failed,
            encoded,
            incoming,
            capture,
            playback,
            render_reference,
            counters,
            #[cfg(any(target_os = "linux", target_os = "windows"))]
            input_stream: None,
            #[cfg(any(target_os = "linux", target_os = "windows"))]
            output_stream: None,
            workers: vec![encode_worker, decode_worker],
        })
    }

    pub fn set_muted(&self, muted: bool) {
        self.muted.store(muted, Ordering::Relaxed);
    }

    pub fn set_noise_suppression(&self, enabled: bool) {
        self.noise_suppression.store(enabled, Ordering::Relaxed);
    }

    #[cfg(target_os = "android")]
    pub fn noise_suppression_enabled(&self) -> bool {
        self.noise_suppression.load(Ordering::Relaxed)
    }

    #[cfg(target_os = "android")]
    pub fn set_platform_noise_suppression(&self, enabled: bool) {
        self.platform_noise_suppression
            .store(enabled, Ordering::Relaxed);
    }

    pub fn set_network_congested(&self, congested: bool) {
        self.network_congested.store(congested, Ordering::Relaxed);
    }

    pub fn is_healthy(&self) -> bool {
        !self.failed.load(Ordering::Relaxed)
    }

    /// What this call's audio did so far (counts since it opened).
    pub fn stats(&self) -> CallStats {
        let receive = self
            .incoming
            .lock()
            .map(|mixer| mixer.stats())
            .unwrap_or_default();
        CallStats {
            sent: self.counters.sent.load(Ordering::Relaxed),
            send_dropped: self.counters.send_dropped.load(Ordering::Relaxed),
            played_frames: self.counters.played_frames.load(Ordering::Relaxed),
            playback_trimmed: self.counters.playback_trimmed.load(Ordering::Relaxed),
            received: receive.received,
            late_or_duplicate: receive.late_or_duplicate,
            lost: receive.lost,
            concealed_frames: receive.concealed_frames,
            gaps: receive.gaps,
            jitter_ms: receive.jitter_ms,
        }
    }

    pub fn try_next_packet(&self) -> Option<Vec<u8>> {
        self.encoded.pop()
    }

    pub fn push_packet(&self, sequence: u64, packet: &[u8]) -> bool {
        self.push_participant_packet(0, sequence, packet)
    }

    pub fn set_participant_active(&self, participant: u16, active: bool) -> bool {
        self.incoming
            .lock()
            .ok()
            .and_then(|mut mixer| mixer.set_active(participant, active).ok())
            .unwrap_or(false)
    }

    pub fn push_participant_packet(&self, participant: u16, sequence: u64, packet: &[u8]) -> bool {
        self.incoming
            .lock()
            .ok()
            .map(|mut mixer| mixer.push(participant, sequence, packet, Instant::now()))
            .unwrap_or(false)
    }

    pub fn participant_level(&self, participant: u16) -> f32 {
        self.incoming
            .lock()
            .ok()
            .map_or(0.0, |mixer| mixer.level(participant))
    }

    /// Supplies one bounded mono PCM capture slice from Android's audio thread.
    #[cfg(target_os = "android")]
    pub fn push_capture_pcm16(&self, samples: &[i16]) -> bool {
        if samples.is_empty() || samples.len() > FRAME_SAMPLES * 4 {
            return false;
        }
        let muted = self.muted.load(Ordering::Relaxed);
        for sample in samples {
            let value = if muted { 0.0 } else { *sample as f32 / 32768.0 };
            // Audio callbacks must stay lossy and non-blocking under load.
            // A dropped capture sample is preferable to growing call latency.
            let _ = self.capture.push(value);
        }
        true
    }

    /// Pulls decoded mono PCM for Android AudioTrack without waiting for audio.
    #[cfg(target_os = "android")]
    pub fn read_playback_pcm16(&self, output: &mut [i16]) -> usize {
        if output.is_empty() || output.len() > FRAME_SAMPLES * 4 {
            return 0;
        }
        let mut count = 0;
        while count < output.len() {
            let Some(sample) = self.playback.pop() else {
                break;
            };
            push_render_reference(&self.render_reference, sample);
            output[count] = (sample.clamp(-1.0, 1.0) * 32767.0) as i16;
            count += 1;
        }
        count
    }

    #[cfg(target_os = "android")]
    pub fn mark_failed(&self) {
        self.failed.store(true, Ordering::Relaxed);
    }
}

impl Drop for VoiceAudioSession {
    fn drop(&mut self) {
        self.running.store(false, Ordering::Relaxed);
        #[cfg(any(target_os = "linux", target_os = "windows"))]
        self.input_stream.take();
        #[cfg(any(target_os = "linux", target_os = "windows"))]
        self.output_stream.take();
        for worker in self.workers.drain(..) {
            let _ = worker.join();
        }
    }
}

#[cfg(any(target_os = "linux", target_os = "windows"))]
fn open_input_stream(
    device: &Device,
    samples: Arc<ArrayQueue<f32>>,
    muted: Arc<AtomicBool>,
    failed: Arc<AtomicBool>,
) -> Result<Stream> {
    let supported = usable_config(
        device
            .default_input_config()
            .context("Could not query microphone format")?,
        device
            .supported_input_configs()
            .map(Iterator::collect)
            .unwrap_or_default(),
    );
    let rate = supported.sample_rate();
    let channels = supported.channels() as usize;
    let sample_format = supported.sample_format();
    let config: StreamConfig = supported.into();
    let on_error = move |_| failed.store(true, Ordering::Relaxed);

    let stream = match sample_format {
        SampleFormat::F32 => {
            let mut phase = 0_u64;
            device.build_input_stream::<f32, _, _>(
                config,
                move |data, _| capture_samples(data, channels, rate, &samples, &mut phase, &muted),
                on_error,
                Some(Duration::from_secs(2)),
            )?
        }
        SampleFormat::I16 => {
            let mut phase = 0_u64;
            device.build_input_stream::<i16, _, _>(
                config,
                move |data, _| capture_samples(data, channels, rate, &samples, &mut phase, &muted),
                on_error,
                Some(Duration::from_secs(2)),
            )?
        }
        SampleFormat::U16 => {
            let mut phase = 0_u64;
            device.build_input_stream::<u16, _, _>(
                config,
                move |data, _| capture_samples(data, channels, rate, &samples, &mut phase, &muted),
                on_error,
                Some(Duration::from_secs(2)),
            )?
        }
        format => bail!("Unsupported microphone sample format: {format:?}"),
    };
    Ok(stream)
}

#[cfg(any(target_os = "linux", target_os = "windows"))]
fn open_output_stream(
    device: &Device,
    samples: Arc<ArrayQueue<f32>>,
    render_reference: Arc<ArrayQueue<f32>>,
    failed: Arc<AtomicBool>,
) -> Result<Stream> {
    let supported = usable_config(
        device
            .default_output_config()
            .context("Could not query speaker format")?,
        device
            .supported_output_configs()
            .map(Iterator::collect)
            .unwrap_or_default(),
    );
    let rate = supported.sample_rate();
    let channels = supported.channels() as usize;
    let sample_format = supported.sample_format();
    let config: StreamConfig = supported.into();
    let on_error = move |_| failed.store(true, Ordering::Relaxed);

    let stream = match sample_format {
        SampleFormat::F32 => {
            let mut phase = 0_u64;
            let mut held = 0.0_f32;
            let render_reference = render_reference.clone();
            device.build_output_stream::<f32, _, _>(
                config,
                move |data, _| {
                    play_samples(
                        data,
                        channels,
                        rate,
                        &samples,
                        &render_reference,
                        &mut phase,
                        &mut held,
                    )
                },
                on_error,
                Some(Duration::from_secs(2)),
            )?
        }
        SampleFormat::I16 => {
            let mut phase = 0_u64;
            let mut held = 0.0_f32;
            let render_reference = render_reference.clone();
            device.build_output_stream::<i16, _, _>(
                config,
                move |data, _| {
                    play_samples(
                        data,
                        channels,
                        rate,
                        &samples,
                        &render_reference,
                        &mut phase,
                        &mut held,
                    )
                },
                on_error,
                Some(Duration::from_secs(2)),
            )?
        }
        SampleFormat::U16 => {
            let mut phase = 0_u64;
            let mut held = 0.0_f32;
            let render_reference = render_reference.clone();
            device.build_output_stream::<u16, _, _>(
                config,
                move |data, _| {
                    play_samples(
                        data,
                        channels,
                        rate,
                        &samples,
                        &render_reference,
                        &mut phase,
                        &mut held,
                    )
                },
                on_error,
                Some(Duration::from_secs(2)),
            )?
        }
        format => bail!("Unsupported speaker sample format: {format:?}"),
    };
    Ok(stream)
}

#[cfg(any(target_os = "linux", target_os = "windows"))]
fn capture_samples<T: Copy + IntoPcm>(
    data: &[T],
    channels: usize,
    rate: u32,
    queue: &ArrayQueue<f32>,
    phase: &mut u64,
    muted: &AtomicBool,
) {
    if channels == 0 || rate == 0 {
        return;
    }
    let silent = muted.load(Ordering::Relaxed);
    for frame in data.chunks_exact(channels) {
        let mono = if silent {
            0.0
        } else {
            frame.iter().map(|sample| sample.into_pcm()).sum::<f32>() / channels as f32
        };
        *phase += VOICE_RATE as u64;
        while *phase >= rate as u64 {
            *phase -= rate as u64;
            let _ = queue.push(mono);
        }
    }
}

#[cfg(any(target_os = "linux", target_os = "windows"))]
trait IntoPcm {
    fn into_pcm(self) -> f32;
}
#[cfg(any(target_os = "linux", target_os = "windows"))]
impl IntoPcm for f32 {
    fn into_pcm(self) -> f32 {
        self.clamp(-1.0, 1.0)
    }
}
#[cfg(any(target_os = "linux", target_os = "windows"))]
impl IntoPcm for i16 {
    fn into_pcm(self) -> f32 {
        self as f32 / 32768.0
    }
}
#[cfg(any(target_os = "linux", target_os = "windows"))]
impl IntoPcm for u16 {
    fn into_pcm(self) -> f32 {
        (self as f32 - 32768.0) / 32768.0
    }
}

#[cfg(any(target_os = "linux", target_os = "windows"))]
trait FromPcm: Sized {
    fn from_pcm(sample: f32) -> Self;
}
#[cfg(any(target_os = "linux", target_os = "windows"))]
impl FromPcm for f32 {
    fn from_pcm(sample: f32) -> Self {
        sample
    }
}
#[cfg(any(target_os = "linux", target_os = "windows"))]
impl FromPcm for i16 {
    fn from_pcm(sample: f32) -> Self {
        (sample.clamp(-1.0, 1.0) * 32767.0) as i16
    }
}
#[cfg(any(target_os = "linux", target_os = "windows"))]
impl FromPcm for u16 {
    fn from_pcm(sample: f32) -> Self {
        ((sample.clamp(-1.0, 1.0) * 0.5 + 0.5) * 65535.0) as u16
    }
}

#[cfg(any(target_os = "linux", target_os = "windows"))]
fn play_samples<T: FromPcm>(
    output: &mut [T],
    channels: usize,
    rate: u32,
    queue: &ArrayQueue<f32>,
    render_reference: &ArrayQueue<f32>,
    phase: &mut u64,
    held: &mut f32,
) {
    if channels == 0 || rate == 0 {
        return;
    }
    for frame in output.chunks_exact_mut(channels) {
        for sample in frame.iter_mut() {
            *sample = T::from_pcm(*held);
        }
        *phase += VOICE_RATE as u64;
        while *phase >= rate as u64 {
            *phase -= rate as u64;
            *held = queue.pop().unwrap_or(0.0);
            push_render_reference(render_reference, *held);
        }
    }
}

fn encode_loop(
    running: Arc<AtomicBool>,
    capture: Arc<ArrayQueue<f32>>,
    encoded: Arc<ArrayQueue<Vec<u8>>>,
    render_reference: Arc<ArrayQueue<f32>>,
    muted: Arc<AtomicBool>,
    mut encoder: Encoder,
    network_congested: Arc<AtomicBool>,
    noise_suppression: Arc<AtomicBool>,
    platform_noise_suppression: Arc<AtomicBool>,
    counters: Arc<CallCounters>,
) {
    let mut frame = vec![0.0_f32; FRAME_SAMPLES];
    let mut bitrate = AdaptiveBitrate::default();
    let mut echo = EchoProcessor::new();
    while running.load(Ordering::Relaxed) {
        let mut count = 0;
        while count < FRAME_SAMPLES {
            if let Some(sample) = capture.pop() {
                frame[count] = sample;
                count += 1;
            } else {
                thread::sleep(Duration::from_millis(1));
                if !running.load(Ordering::Relaxed) {
                    return;
                }
            }
        }
        echo.set_noise_suppression(
            noise_suppression.load(Ordering::Relaxed)
                && !platform_noise_suppression.load(Ordering::Relaxed),
        );
        echo.process_frame(
            &mut frame,
            &render_reference,
            capture.len(),
            muted.load(Ordering::Relaxed),
        );
        let queue_depth = if network_congested.load(Ordering::Relaxed) {
            HIGH_QUEUE_WATERMARK
        } else {
            encoded.len()
        };
        if let Some(bits_per_second) = bitrate.observe(queue_depth) {
            let _ = encoder.set_bitrate(opus::Bitrate::Bits(bits_per_second as i32));
        }
        if let Ok(packet) = encoder.encode_vec_float(&frame, MAX_OPUS_PACKET)
            && !packet.is_empty()
        {
            counters.sent.fetch_add(1, Ordering::Relaxed);
            if let Err(packet) = encoded.push(packet) {
                // The oldest goes; this newest one takes its place.
                let _ = encoded.pop();
                let _ = encoded.push(packet);
                counters.send_dropped.fetch_add(1, Ordering::Relaxed);
            }
        }
    }
}

fn decode_loop(
    running: Arc<AtomicBool>,
    incoming: Arc<Mutex<RemoteMixer>>,
    playback: Arc<ArrayQueue<f32>>,
    counters: Arc<CallCounters>,
) {
    let mut next_playout = Instant::now();
    while running.load(Ordering::Relaxed) {
        let now = Instant::now();
        if now < next_playout {
            thread::sleep(Duration::from_millis(2));
            continue;
        }
        // One 20 ms slot, played or silent: a slot with nothing ready is
        // concealed once (calling again every 2 ms counted each retry as a
        // concealed frame and a 6 ms wait as an audible gap).
        let frame = incoming.lock().ok().and_then(|mut mixer| mixer.render(now));
        next_playout = next_playout_after(next_playout, now);
        let Some(frame) = frame else {
            continue;
        };
        counters.played_frames.fetch_add(1, Ordering::Relaxed);
        if playback.len().saturating_add(frame.len()) > PLAYBACK_QUEUE_SAMPLES * 3 / 4 {
            counters.playback_trimmed.fetch_add(1, Ordering::Relaxed);
            while playback.len() > PLAYBACK_QUEUE_SAMPLES / 4 {
                let _ = playback.pop();
            }
        }
        for sample in frame {
            let _ = playback.push(sample);
        }
    }
}

/// The next 20 ms playout slot. A fixed schedule: taking it from the
/// (always a little late) wake time played about 5% slower than the
/// speaker consumed, so playback starved and crackled. Far behind (after a
/// gap with nothing to play), the schedule starts again from now.
fn next_playout_after(scheduled: Instant, now: Instant) -> Instant {
    let next = scheduled + Duration::from_millis(20);
    if now.saturating_duration_since(next) > Duration::from_millis(60) {
        now + Duration::from_millis(20)
    } else {
        next
    }
}

struct PacketJitterBuffer {
    expected: u64,
    pending: BTreeMap<u64, Vec<u8>>,
    gap_started: Option<Instant>,
    previous_arrival: Option<(u64, Instant)>,
    arrival_jitter_nanos: u64,
    gap_wait: Duration,
    /// Packets skipped after waiting for them (never came in time).
    lost: u64,
}

impl PacketJitterBuffer {
    fn new(first_sequence: u64) -> Self {
        Self {
            expected: first_sequence,
            pending: BTreeMap::new(),
            gap_started: None,
            previous_arrival: None,
            arrival_jitter_nanos: 0,
            gap_wait: MIN_JITTER_WAIT,
            lost: 0,
        }
    }

    /// False when [packet] is too late (already played past) or a copy.
    fn insert(&mut self, sequence: u64, packet: Vec<u8>, arrived_at: Instant) -> bool {
        if sequence < self.expected || self.pending.contains_key(&sequence) {
            return false;
        }
        self.observe_arrival(sequence, arrived_at);
        self.pending.insert(sequence, packet);
        // Over the bound, the oldest go (and whatever was missing before
        // them): the newest audio is what is worth playing.
        while self.pending.len() > MAX_BUFFERED_PACKETS.min(OPUS_PACKET_QUEUE) {
            let (oldest, _) = self.pending.pop_first().expect("over the bound");
            self.lost = self
                .lost
                .saturating_add(oldest.saturating_sub(self.expected) + 1);
            self.expected = oldest.saturating_add(1);
            self.gap_started = None;
        }
        true
    }

    fn jitter(&self) -> Duration {
        Duration::from_nanos(self.arrival_jitter_nanos)
    }

    fn observe_arrival(&mut self, sequence: u64, arrived_at: Instant) {
        if let Some((previous_sequence, previous_at)) = self.previous_arrival {
            let arrival_delta = if arrived_at >= previous_at {
                arrived_at.duration_since(previous_at).as_nanos() as i128
            } else {
                -(previous_at.duration_since(arrived_at).as_nanos() as i128)
            };
            let sequence_delta = sequence as i128 - previous_sequence as i128;
            let deviation = arrival_delta
                .abs_diff(sequence_delta * FRAME_PERIOD_NANOS)
                .min(u64::MAX as u128) as u64;
            self.arrival_jitter_nanos = if deviation >= self.arrival_jitter_nanos {
                self.arrival_jitter_nanos
                    .saturating_add((deviation - self.arrival_jitter_nanos) / 16)
            } else {
                self.arrival_jitter_nanos
                    .saturating_sub((self.arrival_jitter_nanos - deviation) / 16)
            };
        }
        self.previous_arrival = Some((sequence, arrived_at));
        let target_nanos = (MIN_JITTER_WAIT.as_nanos() + u128::from(self.arrival_jitter_nanos) * 4)
            .min(MAX_JITTER_WAIT.as_nanos()) as u64;
        self.gap_wait = Duration::from_nanos(target_nanos);
    }

    fn pop_ready(&mut self, now: Instant) -> Option<Vec<u8>> {
        if let Some(packet) = self.pending.remove(&self.expected) {
            self.expected = self.expected.saturating_add(1);
            self.gap_started = None;
            return Some(packet);
        }
        let next_sequence = *self.pending.first_key_value()?.0;
        let gap_started = *self.gap_started.get_or_insert(now);
        if self.pending.len() < SKIP_WAIT_BACKLOG && now.duration_since(gap_started) < self.gap_wait
        {
            return None;
        }
        self.lost = self.lost.saturating_add(next_sequence - self.expected);
        self.expected = next_sequence;
        self.gap_started = None;
        self.pop_ready(now)
    }
}

#[cfg(all(test, any(target_os = "linux", target_os = "windows")))]
mod config_tests {
    use super::usable_config;
    use cpal::{
        SampleFormat, SupportedBufferSize, SupportedStreamConfig, SupportedStreamConfigRange,
    };

    fn range(channels: u16, format: SampleFormat) -> SupportedStreamConfigRange {
        SupportedStreamConfigRange::new(
            channels,
            8_000,
            192_000,
            SupportedBufferSize::Unknown,
            format,
        )
    }

    #[test]
    fn a_24_bit_device_is_opened_as_f32_at_its_own_rate() {
        let default =
            SupportedStreamConfig::new(2, 48_000, SupportedBufferSize::Unknown, SampleFormat::I24);
        let ranges = vec![
            range(2, SampleFormat::I24),
            range(1, SampleFormat::F32),
            range(2, SampleFormat::F32),
            range(2, SampleFormat::I16),
        ];
        let chosen = usable_config(default, ranges);
        assert_eq!(chosen.sample_format(), SampleFormat::F32);
        assert_eq!(chosen.sample_rate(), 48_000);
        assert_eq!(chosen.channels(), 2);
    }

    #[test]
    fn a_device_without_f32_is_opened_as_i16() {
        let default =
            SupportedStreamConfig::new(1, 44_100, SupportedBufferSize::Unknown, SampleFormat::I32);
        let chosen = usable_config(
            default,
            vec![range(1, SampleFormat::I32), range(1, SampleFormat::I16)],
        );
        assert_eq!(chosen.sample_format(), SampleFormat::I16);
        assert_eq!(chosen.sample_rate(), 44_100);
    }

    #[test]
    fn a_format_this_code_takes_is_kept() {
        let default =
            SupportedStreamConfig::new(2, 48_000, SupportedBufferSize::Unknown, SampleFormat::I16);
        let chosen = usable_config(default, vec![range(2, SampleFormat::F32)]);
        assert_eq!(chosen.sample_format(), SampleFormat::I16);
    }
}

#[cfg(test)]
mod tests {
    use super::{
        AdaptiveBitrate, Application, Channels, Encoder, MAX_BUFFERED_PACKETS, MAX_JITTER_WAIT,
        MIN_JITTER_WAIT, PacketJitterBuffer, SKIP_WAIT_BACKLOG, next_playout_after,
    };
    use opus::Decoder;
    use std::time::{Duration, Instant};

    #[test]
    fn late_wakeups_do_not_slow_playout() {
        let start = Instant::now();
        let mut next = start;
        // Every wake comes 1.5 ms after its slot, as a 2 ms poll does.
        for _ in 0..500 {
            let woke = next + Duration::from_micros(1500);
            next = next_playout_after(next, woke);
        }
        // 500 frames take 10 s of playout, not 10.75 s.
        assert_eq!(next - start, Duration::from_millis(500 * 20));
    }

    #[test]
    fn a_long_gap_restarts_the_schedule() {
        let start = Instant::now();
        let woke = start + Duration::from_millis(500);
        let next = next_playout_after(start, woke);
        assert_eq!(next, woke + Duration::from_millis(20));
    }

    #[test]
    fn twenty_millisecond_mono_opus_round_trip() {
        let input: Vec<f32> = (0..960)
            .map(|index| (index as f32 * 440.0 * std::f32::consts::TAU / 48_000.0).sin() * 0.25)
            .collect();
        let mut encoder = Encoder::new(48_000, Channels::Mono, Application::Voip).unwrap();
        let packet = encoder.encode_vec_float(&input, 1_100).unwrap();
        assert!(!packet.is_empty());
        assert!(packet.len() <= 1_100);

        let mut decoder = Decoder::new(48_000, Channels::Mono).unwrap();
        let mut output = vec![0.0_f32; 5_760];
        let decoded_samples = decoder.decode_float(&packet, &mut output, false).unwrap();
        assert_eq!(decoded_samples, 960);
        let signal_energy = output[..decoded_samples]
            .iter()
            .map(|sample| sample * sample)
            .sum::<f32>();
        assert!(signal_energy > 0.01);
    }

    #[test]
    fn noise_suppression_reduces_noise_and_preserves_changing_voiced_signal() {
        use super::{EchoProcessor, FRAME_SAMPLES, VOICE_RATE};
        use crossbeam_queue::ArrayQueue;
        let render = ArrayQueue::new(FRAME_SAMPLES);
        let mut processor = EchoProcessor::new();
        processor.set_noise_suppression(true);
        let mut seed = 0x193a_b723_u32;
        let (mut input_noise, mut output_noise) = (0.0_f64, 0.0_f64);
        let (mut input_voice, mut output_voice) = (0.0_f64, 0.0_f64);
        for frame_number in 0..500 {
            let voiced = frame_number >= 250;
            let mut frame: Vec<f32> = (0..FRAME_SAMPLES)
                .map(|i| {
                    seed = seed.wrapping_mul(1664525).wrapping_add(1013904223);
                    let noise = ((seed >> 8) as f32 / 16777215.0 - 0.5) * 0.04;
                    let t = (frame_number * FRAME_SAMPLES + i) as f32 / VOICE_RATE as f32;
                    let frequency = 140.0 + 30.0 * (t * 2.3).sin();
                    let voice = (std::f32::consts::TAU * frequency * t).sin() * 0.25
                        + (std::f32::consts::TAU * frequency * 2.0 * t).sin() * 0.08;
                    noise
                        + if voiced {
                            voice * (0.7 + 0.3 * (t * 6.0).sin())
                        } else {
                            0.0
                        }
                })
                .collect();
            let input = frame.iter().map(|x| f64::from(x * x)).sum::<f64>();
            processor.process_frame(&mut frame, &render, 0, false);
            let output = frame.iter().map(|x| f64::from(x * x)).sum::<f64>();
            if (150..250).contains(&frame_number) {
                input_noise += input;
                output_noise += output;
            }
            if frame_number >= 350 {
                input_voice += input;
                output_voice += output;
            }
        }
        assert!(
            output_noise < input_noise * 0.1,
            "noise {output_noise}/{input_noise}"
        );
        assert!(
            output_voice > input_voice * 0.5,
            "voice {output_voice}/{input_voice}"
        );
        processor.set_noise_suppression(false);
        assert!(processor.apm.config().noise_suppression.is_none());
    }

    #[test]
    fn bitrate_falls_on_sustained_queue_pressure_and_recovers_slowly() {
        let mut controller = AdaptiveBitrate::default();
        let mut changes = Vec::new();
        for _ in 0..15 {
            changes.extend(controller.observe(9));
        }
        assert_eq!(changes, vec![24_000, 16_000]);

        let mut recovery = Vec::new();
        for _ in 0..100 {
            recovery.extend(controller.observe(0));
        }
        assert_eq!(recovery, vec![24_000, 32_000]);
    }

    /// Runs `seconds` of far-end noise through a simulated room with the
    /// given speaker-to-microphone delay, optionally mixing in near-end
    /// speech for the second half. Returns (echo, residual, near, output)
    /// energies over the final second.
    #[cfg(any(target_os = "linux", target_os = "windows"))]
    fn simulate_echo_path(delay_ms: usize, double_talk: bool) -> (f64, f64, f64, f64) {
        use super::{EchoProcessor, FRAME_SAMPLES, VOICE_RATE};
        use crossbeam_queue::ArrayQueue;

        let seconds = 6;
        let total = VOICE_RATE as usize * seconds;
        let delay = VOICE_RATE as usize * delay_ms / 1_000;
        let mut state = 0x1357_9bdf_u32;
        let mut noise = || {
            state = state.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
            ((state >> 8) as f32 / 16_777_215.0 - 0.5) * 0.4
        };
        let far: Vec<f32> = (0..total).map(|_| noise()).collect();
        let near: Vec<f32> = (0..total)
            .map(|index| {
                if double_talk && index >= total / 2 {
                    (index as f32 * 310.0 * std::f32::consts::TAU / VOICE_RATE as f32).sin() * 0.2
                } else {
                    0.0
                }
            })
            .collect();
        let render = ArrayQueue::new(VOICE_RATE as usize);
        let mut processor = EchoProcessor::new();
        let measure_from = total - VOICE_RATE as usize;
        let (mut echo_energy, mut residual_energy) = (0.0_f64, 0.0_f64);
        let (mut near_energy, mut output_energy) = (0.0_f64, 0.0_f64);
        for start in (0..total).step_by(FRAME_SAMPLES) {
            for sample in &far[start..start + FRAME_SAMPLES] {
                let _ = render.push(*sample);
            }
            let echo: Vec<f32> = (start..start + FRAME_SAMPLES)
                .map(|index| index.checked_sub(delay).map_or(0.0, |at| far[at] * 0.5))
                .collect();
            let mut frame: Vec<f32> = echo
                .iter()
                .zip(&near[start..start + FRAME_SAMPLES])
                .map(|(echo, near)| echo + near)
                .collect();
            processor.process_frame(&mut frame, &render, 0, false);
            if start >= measure_from {
                for (offset, output) in frame.iter().enumerate() {
                    let near = near[start + offset];
                    echo_energy += f64::from(echo[offset] * echo[offset]);
                    residual_energy += f64::from((output - near) * (output - near));
                    near_energy += f64::from(near * near);
                    output_energy += f64::from(output * output);
                }
            }
        }
        (echo_energy, residual_energy, near_energy, output_energy)
    }

    #[cfg(any(target_os = "linux", target_os = "windows"))]
    #[test]
    fn aec3_cancels_echo_across_realistic_device_delays() {
        for delay_ms in [30, 80, 150] {
            let (echo, residual, _, _) = simulate_echo_path(delay_ms, false);
            assert!(
                residual < echo * 0.01,
                "{delay_ms} ms: residual {residual} should be 20 dB below echo {echo}",
            );
        }
    }

    #[cfg(any(target_os = "linux", target_os = "windows"))]
    #[test]
    fn aec3_keeps_near_end_speech_during_double_talk() {
        let (_, _, near, output) = simulate_echo_path(80, true);
        assert!(
            output > near * 0.25,
            "near-end speech energy {near} was suppressed to {output}",
        );
    }

    #[cfg(any(target_os = "linux", target_os = "windows"))]
    #[test]
    fn muted_frames_are_silent_while_the_canceller_keeps_running() {
        use super::{EchoProcessor, FRAME_SAMPLES};
        use crossbeam_queue::ArrayQueue;

        let render = ArrayQueue::new(FRAME_SAMPLES * 2);
        for index in 0..FRAME_SAMPLES {
            let _ = render.push((index as f32 * 0.03).sin() * 0.3);
        }
        let mut processor = EchoProcessor::new();
        let mut frame = vec![0.25_f32; FRAME_SAMPLES];
        processor.process_frame(&mut frame, &render, 0, true);
        assert!(frame.iter().all(|sample| *sample == 0.0));
        assert!(render.is_empty());
    }

    #[test]
    fn jitter_buffer_reorders_nearby_packets_and_skips_expired_gaps() {
        let start = Instant::now();
        let mut jitter = PacketJitterBuffer::new(1);
        jitter.insert(2, vec![2], start + Duration::from_millis(20));
        jitter.insert(1, vec![1], start);
        assert_eq!(jitter.pop_ready(start), Some(vec![1]));
        assert_eq!(jitter.pop_ready(start), Some(vec![2]));

        jitter.insert(4, vec![4], start + Duration::from_millis(60));
        assert_eq!(jitter.pop_ready(start), None);
        assert_eq!(
            jitter.pop_ready(start + MIN_JITTER_WAIT + Duration::from_millis(1)),
            Some(vec![4]),
        );
    }

    #[test]
    fn a_hole_behind_a_backlog_is_skipped_at_once() {
        let start = Instant::now();
        let mut jitter = PacketJitterBuffer::new(1);
        for sequence in [1_u64, 3, 4, 5] {
            jitter.insert(sequence, vec![sequence as u8], start);
        }
        assert_eq!(jitter.pop_ready(start), Some(vec![1]));
        // 2 is missing with three waiting behind it: no wait.
        assert_eq!(jitter.pop_ready(start), Some(vec![3]));
        assert_eq!(jitter.lost, 1);
    }

    #[test]
    fn a_long_backlog_keeps_the_newest_audio() {
        let start = Instant::now();
        let mut jitter = PacketJitterBuffer::new(1);
        for sequence in 1..=20_u64 {
            assert!(jitter.insert(sequence, vec![sequence as u8], start));
        }
        assert_eq!(jitter.pending.len(), MAX_BUFFERED_PACKETS);
        assert_eq!(jitter.pop_ready(start), Some(vec![13]));
        assert_eq!(jitter.lost, 12);
    }

    #[test]
    fn playout_keeps_up_through_losses_and_a_stall() {
        // A minute of 20 ms packets: every 50th lost, and a 200 ms stall
        // that then delivers its packets at once. One slot plays per 20 ms.
        let start = Instant::now();
        let mut jitter = PacketJitterBuffer::new(1);
        let mut played = 0;
        for slot in 0..3000_u64 {
            let now = start + Duration::from_millis(20 * slot);
            let arriving: Vec<u64> = if (500..510).contains(&slot) {
                Vec::new()
            } else if slot == 510 {
                (501..=511).collect()
            } else {
                vec![slot + 1]
            };
            for sequence in arriving {
                if sequence % 50 != 0 {
                    jitter.insert(sequence, vec![0], now);
                }
            }
            if jitter.pop_ready(now).is_some() {
                played += 1;
            }
        }
        // About 3000 less the 60 lost and a few dropped to catch up.
        assert!(played >= 2850, "played {played}");
        assert!(jitter.pending.len() <= SKIP_WAIT_BACKLOG + 1);
    }

    #[test]
    fn jitter_buffer_adapts_gap_wait_to_arrival_variation_with_a_hard_bound() {
        let start = Instant::now();
        let mut jitter = PacketJitterBuffer::new(1);
        jitter.insert(1, vec![1], start);
        assert_eq!(jitter.gap_wait, MIN_JITTER_WAIT);
        jitter.insert(2, vec![2], start + Duration::from_millis(20));
        assert_eq!(jitter.gap_wait, MIN_JITTER_WAIT);
        jitter.insert(3, vec![3], start + Duration::from_millis(90));
        assert!(jitter.gap_wait > MIN_JITTER_WAIT);
        assert!(jitter.gap_wait <= MAX_JITTER_WAIT);
    }
}
