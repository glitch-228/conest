//! Native foreground-call audio. Device callbacks only move bounded PCM
//! samples; Opus work runs on worker threads so it never blocks Flutter.

use std::{
    collections::BTreeMap,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

#[cfg(any(target_os = "linux", target_os = "windows"))]
use anyhow::bail;
use anyhow::{Context, Result};
#[cfg(any(target_os = "linux", target_os = "windows"))]
use cpal::{
    Device, SampleFormat, Stream, StreamConfig,
    traits::{DeviceTrait, HostTrait, StreamTrait},
};
use crossbeam_queue::ArrayQueue;
use opus::{Application, Channels, Decoder, Encoder};

const VOICE_RATE: u32 = 48_000;
const FRAME_SAMPLES: usize = 960; // 20 ms, mono, 48 kHz.
const MAX_OPUS_PACKET: usize = 1_100;
const CAPTURE_QUEUE_SAMPLES: usize = FRAME_SAMPLES * 6;
const PLAYBACK_QUEUE_SAMPLES: usize = FRAME_SAMPLES * 8;
const OPUS_PACKET_QUEUE: usize = 12;
const ECHO_REFERENCE_QUEUE_SAMPLES: usize = VOICE_RATE as usize;
const ECHO_DELAY_SAMPLES: usize = FRAME_SAMPLES * 4;
const ECHO_FILTER_TAPS: usize = 128;
const FRAME_PERIOD_NANOS: i128 = 20_000_000;
const MIN_JITTER_WAIT: Duration = Duration::from_millis(20);
const MAX_JITTER_WAIT: Duration = Duration::from_millis(100);
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

/// Bounded normalized-LMS echo reduction using the rendered speaker signal as
/// its reference. Processing stays on the audio worker, outside device callbacks.
struct EchoCanceller {
    history: [f32; ECHO_FILTER_TAPS],
    weights: [f32; ECHO_FILTER_TAPS],
    cursor: usize,
}

impl EchoCanceller {
    fn new() -> Self {
        Self {
            history: [0.0; ECHO_FILTER_TAPS],
            weights: [0.0; ECHO_FILTER_TAPS],
            cursor: 0,
        }
    }

    fn process_sample(&mut self, captured: f32, rendered: f32) -> f32 {
        self.history[self.cursor] = rendered;
        self.cursor = (self.cursor + 1) % ECHO_FILTER_TAPS;
        let mut estimate = 0.0;
        let mut energy = 1.0e-4;
        for tap in 0..ECHO_FILTER_TAPS {
            let index = (self.cursor + ECHO_FILTER_TAPS - 1 - tap) % ECHO_FILTER_TAPS;
            let reference = self.history[index];
            estimate += self.weights[tap] * reference;
            energy += reference * reference;
        }
        let error = captured - estimate;
        if energy > 1.0e-3 {
            let adaptation = 0.15 * error / energy;
            for tap in 0..ECHO_FILTER_TAPS {
                let index = (self.cursor + ECHO_FILTER_TAPS - 1 - tap) % ECHO_FILTER_TAPS;
                self.weights[tap] =
                    (self.weights[tap] + adaptation * self.history[index]).clamp(-2.0, 2.0);
            }
        }
        error.clamp(-1.0, 1.0)
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
    failed: Arc<AtomicBool>,
    encoded: Arc<ArrayQueue<Vec<u8>>>,
    incoming: Arc<ArrayQueue<(u64, Vec<u8>, Instant)>>,
    capture: Arc<ArrayQueue<f32>>,
    playback: Arc<ArrayQueue<f32>>,
    render_reference: Arc<ArrayQueue<f32>>,
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
        let failed = Arc::new(AtomicBool::new(false));
        let capture = Arc::new(ArrayQueue::new(CAPTURE_QUEUE_SAMPLES));
        let playback = Arc::new(ArrayQueue::new(PLAYBACK_QUEUE_SAMPLES));
        let render_reference = Arc::new(ArrayQueue::new(ECHO_REFERENCE_QUEUE_SAMPLES));
        let encoded = Arc::new(ArrayQueue::new(OPUS_PACKET_QUEUE));
        let incoming = Arc::new(ArrayQueue::new(OPUS_PACKET_QUEUE));
        let mut encoder = Encoder::new(VOICE_RATE, Channels::Mono, Application::Voip)
            .context("Could not initialize the Opus encoder")?;
        encoder
            .set_bitrate(opus::Bitrate::Bits(32_000))
            .context("Could not configure the Opus voice bitrate")?;
        let decoder = Decoder::new(VOICE_RATE, Channels::Mono)
            .context("Could not initialize the Opus decoder")?;

        let encode_worker = thread::Builder::new()
            .name("conest-call-encoder".into())
            .spawn({
                let running = running.clone();
                let capture = capture.clone();
                let encoded = encoded.clone();
                let render_reference = render_reference.clone();
                let network_congested = network_congested.clone();
                move || {
                    encode_loop(
                        running,
                        capture,
                        encoded,
                        render_reference,
                        encoder,
                        network_congested,
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
                move || decode_loop(running, incoming, playback, decoder)
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
            failed,
            encoded,
            incoming,
            capture,
            playback,
            render_reference,
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

    pub fn set_network_congested(&self, congested: bool) {
        self.network_congested.store(congested, Ordering::Relaxed);
    }

    pub fn is_healthy(&self) -> bool {
        !self.failed.load(Ordering::Relaxed)
    }

    pub fn try_next_packet(&self) -> Option<Vec<u8>> {
        self.encoded.pop()
    }

    pub fn push_packet(&self, sequence: u64, packet: &[u8]) -> bool {
        if sequence == 0 || packet.is_empty() || packet.len() > MAX_OPUS_PACKET {
            return false;
        }
        let incoming = (sequence, packet.to_vec(), Instant::now());
        if self.incoming.push(incoming).is_err() {
            // The audio path is lossy by design. Replace stale queued audio
            // with the freshest packet instead of building latency.
            let _ = self.incoming.pop();
            self.incoming
                .push((sequence, packet.to_vec(), Instant::now()))
                .is_ok()
        } else {
            true
        }
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
    let supported = device
        .default_input_config()
        .context("Could not query microphone format")?;
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
    let supported = device
        .default_output_config()
        .context("Could not query speaker format")?;
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
    mut encoder: Encoder,
    network_congested: Arc<AtomicBool>,
) {
    let mut frame = vec![0.0_f32; FRAME_SAMPLES];
    let mut bitrate = AdaptiveBitrate::default();
    let mut echo_canceller = EchoCanceller::new();
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
        while render_reference.len() > ECHO_DELAY_SAMPLES + FRAME_SAMPLES {
            let _ = render_reference.pop();
        }
        for sample in &mut frame {
            let rendered = if render_reference.len() > ECHO_DELAY_SAMPLES {
                render_reference.pop().unwrap_or(0.0)
            } else {
                0.0
            };
            *sample = echo_canceller.process_sample(*sample, rendered);
        }
        let queue_depth = if network_congested.load(Ordering::Relaxed) {
            HIGH_QUEUE_WATERMARK
        } else {
            encoded.len()
        };
        if let Some(bits_per_second) = bitrate.observe(queue_depth) {
            let _ = encoder.set_bitrate(opus::Bitrate::Bits(bits_per_second as i32));
        }
        if let Ok(packet) = encoder.encode_vec_float(&frame, MAX_OPUS_PACKET) {
            if !packet.is_empty() && encoded.push(packet).is_err() {
                let _ = encoded.pop();
            }
        }
    }
}

fn decode_loop(
    running: Arc<AtomicBool>,
    incoming: Arc<ArrayQueue<(u64, Vec<u8>, Instant)>>,
    playback: Arc<ArrayQueue<f32>>,
    mut decoder: Decoder,
) {
    let mut pcm = vec![0.0_f32; FRAME_SAMPLES * 6];
    let mut jitter = PacketJitterBuffer::new(1);
    while running.load(Ordering::Relaxed) {
        while let Some((sequence, packet, arrived_at)) = incoming.pop() {
            jitter.insert(sequence, packet, arrived_at);
        }
        let Some(packet) = jitter.pop_ready(Instant::now()) else {
            thread::sleep(Duration::from_millis(2));
            continue;
        };
        let Ok(samples) = decoder.decode_float(&packet, &mut pcm, false) else {
            continue;
        };
        if playback.len().saturating_add(samples) > PLAYBACK_QUEUE_SAMPLES * 3 / 4 {
            while playback.len() > PLAYBACK_QUEUE_SAMPLES / 4 {
                let _ = playback.pop();
            }
        }
        for sample in pcm.iter().take(samples) {
            let _ = playback.push(*sample);
        }
    }
}

struct PacketJitterBuffer {
    expected: u64,
    pending: BTreeMap<u64, Vec<u8>>,
    gap_started: Option<Instant>,
    previous_arrival: Option<(u64, Instant)>,
    arrival_jitter_nanos: u64,
    gap_wait: Duration,
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
        }
    }

    fn insert(&mut self, sequence: u64, packet: Vec<u8>, arrived_at: Instant) {
        if sequence < self.expected || self.pending.contains_key(&sequence) {
            return;
        }
        if self.pending.len() >= OPUS_PACKET_QUEUE {
            // Keep the closest packets to the expected point; a distant
            // future packet must not displace audio that can play sooner.
            let furthest = *self.pending.last_key_value().expect("queue is full").0;
            if sequence >= furthest {
                return;
            }
            self.pending.pop_last();
        }
        self.observe_arrival(sequence, arrived_at);
        self.pending.insert(sequence, packet);
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
        if now.duration_since(gap_started) < self.gap_wait {
            return None;
        }
        self.expected = next_sequence;
        self.gap_started = None;
        self.pop_ready(now)
    }
}

#[cfg(test)]
mod tests {
    use super::{
        AdaptiveBitrate, Application, Channels, Decoder, EchoCanceller, Encoder, MAX_JITTER_WAIT,
        MIN_JITTER_WAIT, PacketJitterBuffer,
    };
    use std::time::{Duration, Instant};

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

    #[test]
    fn echo_canceller_reduces_a_correlated_render_signal() {
        let mut canceller = EchoCanceller::new();
        let mut state = 0x1357_9bdf_u32;
        let mut uncancelled_energy = 0.0_f64;
        let mut cancelled_energy = 0.0_f64;
        for index in 0..24_000 {
            state = state.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
            let rendered = ((state >> 8) as f32 / 16_777_215.0 - 0.5) * 0.4;
            let echo = rendered * 0.65;
            let output = canceller.process_sample(echo, rendered);
            if index >= 12_000 {
                uncancelled_energy += f64::from(echo * echo);
                cancelled_energy += f64::from(output * output);
            }
        }
        assert!(
            cancelled_energy < uncancelled_energy * 0.15,
            "cancelled energy {cancelled_energy} should be below uncancelled energy {uncancelled_energy}",
        );
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
