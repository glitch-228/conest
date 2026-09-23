//! Desktop voice-message capture and Ogg/Opus muxing.
//!
//! CPAL callbacks only enqueue bounded mono samples. The worker owns Opus
//! encoding and file I/O, so neither operation blocks the audio device thread.

use std::{
    fs::{self, File},
    io::{self, Write},
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicU32, Ordering},
    },
    thread::{self, JoinHandle},
    time::Duration,
};

use anyhow::{Context, Result, bail};
use cpal::{
    Device, SampleFormat, Stream, StreamConfig,
    traits::{DeviceTrait, HostTrait, StreamTrait},
};
use crossbeam_queue::ArrayQueue;
use opus::{Application, Channels, Encoder};

const RATE: u32 = 48_000;
const FRAME_SAMPLES: usize = 960;
const MAX_PACKET_BYTES: usize = 1_275;
const PRE_SKIP: u64 = 312;
const WAVEFORM_BUCKET_SAMPLES: usize = RATE as usize / 10;
const MAX_WAVEFORM_SAMPLES: usize = 256;
const CAPTURE_QUEUE_SAMPLES: usize = RATE as usize * 2;
static NEXT_OGG_SERIAL: AtomicU32 = AtomicU32::new(1);

pub struct VoiceMessageRecordingResult {
    pub size_bytes: u64,
    pub waveform: Vec<u8>,
}

pub struct VoiceMessageRecorder {
    path: PathBuf,
    running: Arc<AtomicBool>,
    failed: Arc<AtomicBool>,
    input_stream: Option<Stream>,
    worker: Option<JoinHandle<Result<Vec<u8>>>>,
    completed: bool,
}

impl VoiceMessageRecorder {
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        let path = path.as_ref().to_path_buf();
        let host = cpal::default_host();
        let input = host
            .default_input_device()
            .context("No default microphone device is available")?;
        let queue = Arc::new(ArrayQueue::new(CAPTURE_QUEUE_SAMPLES));
        let failed = Arc::new(AtomicBool::new(false));
        let input_stream = open_input_stream(&input, queue.clone(), failed.clone())?;

        let file = File::create(&path).context("Could not create voice recording")?;
        let serial = NEXT_OGG_SERIAL.fetch_add(1, Ordering::Relaxed).max(1);
        let mut ogg = OggOpusWriter::new(file, serial);
        if let Err(error) = ogg.write_headers() {
            drop(ogg);
            let _ = fs::remove_file(&path);
            return Err(error).context("Could not write Ogg headers");
        }

        let running = Arc::new(AtomicBool::new(true));
        let worker = match thread::Builder::new()
            .name("conest-voice-message-encoder".into())
            .spawn({
                let running = running.clone();
                let queue = queue.clone();
                move || record_loop(running, queue, ogg)
            }) {
            Ok(worker) => worker,
            Err(error) => {
                let _ = fs::remove_file(&path);
                return Err(error).context("Could not start voice recording encoder");
            }
        };

        if let Err(error) = input_stream.play() {
            running.store(false, Ordering::Relaxed);
            let _ = worker.join();
            let _ = fs::remove_file(&path);
            return Err(error).context("Could not start microphone capture");
        }

        Ok(Self {
            path,
            running,
            failed,
            input_stream: Some(input_stream),
            worker: Some(worker),
            completed: false,
        })
    }

    pub fn stop(mut self) -> Result<VoiceMessageRecordingResult> {
        self.input_stream.take();
        self.running.store(false, Ordering::Relaxed);
        let worker = self
            .worker
            .take()
            .context("Voice recording worker is unavailable")?;
        let waveform = worker
            .join()
            .map_err(|_| anyhow::anyhow!("Voice recording worker stopped unexpectedly"))??;
        if self.failed.load(Ordering::Relaxed) {
            bail!("Microphone capture stopped or could not keep up; recording discarded");
        }
        let size_bytes = fs::metadata(&self.path)
            .context("Could not read completed voice recording")?
            .len();
        if size_bytes <= 64 {
            bail!("Voice recording contains no audio");
        }
        self.completed = true;
        Ok(VoiceMessageRecordingResult {
            size_bytes,
            waveform,
        })
    }
}

impl Drop for VoiceMessageRecorder {
    fn drop(&mut self) {
        self.input_stream.take();
        self.running.store(false, Ordering::Relaxed);
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
        if !self.completed {
            let _ = fs::remove_file(&self.path);
        }
    }
}

fn record_loop(
    running: Arc<AtomicBool>,
    queue: Arc<ArrayQueue<f32>>,
    mut ogg: OggOpusWriter<File>,
) -> Result<Vec<u8>> {
    let mut encoder = Encoder::new(RATE, Channels::Mono, Application::Voip)
        .context("Could not initialize the Opus encoder")?;
    encoder
        .set_bitrate(opus::Bitrate::Bits(24_000))
        .context("Could not configure the voice-message bitrate")?;
    let mut frame = [0.0_f32; FRAME_SAMPLES];
    let mut frame_len = 0;
    let mut valid_samples = 0_u64;
    let mut encoded_samples = 0_u64;
    let mut pending_packet: Option<Vec<u8>> = None;
    let mut packet_buffer = vec![0_u8; MAX_PACKET_BYTES];
    let mut waveform = Vec::with_capacity(MAX_WAVEFORM_SAMPLES);
    let mut waveform_samples = 0_usize;
    let mut waveform_energy = 0.0_f64;

    loop {
        while frame_len < FRAME_SAMPLES {
            if let Some(sample) = queue.pop() {
                frame[frame_len] = sample;
                frame_len += 1;
                valid_samples += 1;
                waveform_samples += 1;
                waveform_energy += f64::from(sample) * f64::from(sample);
                if waveform_samples == WAVEFORM_BUCKET_SAMPLES {
                    push_waveform(&mut waveform, waveform_energy, waveform_samples);
                    waveform_samples = 0;
                    waveform_energy = 0.0;
                }
            } else if running.load(Ordering::Relaxed) {
                thread::sleep(Duration::from_millis(1));
            } else {
                break;
            }
        }
        if frame_len == 0 && !running.load(Ordering::Relaxed) {
            break;
        }
        frame[frame_len..].fill(0.0);
        let packet_len = encoder
            .encode_float(&frame, &mut packet_buffer)
            .context("Could not encode voice-message audio")?;
        if let Some(packet) = pending_packet.replace(packet_buffer[..packet_len].to_vec()) {
            ogg.write_packet(&packet, encoded_samples, false)
                .context("Could not write Ogg audio page")?;
        }
        encoded_samples += FRAME_SAMPLES as u64;
        frame_len = 0;
    }

    if waveform_samples > 0 {
        push_waveform(&mut waveform, waveform_energy, waveform_samples);
    }
    if valid_samples == 0 {
        bail!("Microphone produced no audio samples");
    }
    if let Some(packet) = pending_packet {
        ogg.write_packet(&packet, PRE_SKIP + valid_samples, true)
            .context("Could not finish Ogg audio stream")?;
    }
    ogg.finish()
        .context("Could not flush voice recording")?
        .sync_all()
        .context("Could not sync voice recording")?;
    Ok(waveform)
}

fn push_waveform(waveform: &mut Vec<u8>, energy: f64, samples: usize) {
    if waveform.len() >= MAX_WAVEFORM_SAMPLES || samples == 0 {
        return;
    }
    let mean_square = (energy / samples as f64).max(1.0e-12);
    let decibels = 10.0 * mean_square.log10();
    let value = ((decibels + 60.0).clamp(0.0, 60.0) * 255.0 / 60.0).round();
    waveform.push(value as u8);
}

fn open_input_stream(
    device: &Device,
    queue: Arc<ArrayQueue<f32>>,
    failed: Arc<AtomicBool>,
) -> Result<Stream> {
    let supported = device
        .default_input_config()
        .context("Could not query microphone format")?;
    let rate = supported.sample_rate();
    let channels = supported.channels() as usize;
    let sample_format = supported.sample_format();
    let config: StreamConfig = supported.into();
    let stream_failed = failed.clone();
    let on_error = move |_| stream_failed.store(true, Ordering::Relaxed);

    let stream = match sample_format {
        SampleFormat::F32 => {
            let (queue, failed) = (queue.clone(), failed.clone());
            let mut phase = 0_u64;
            device.build_input_stream::<f32, _, _>(
                config,
                move |data, _| capture_samples(data, channels, rate, &queue, &failed, &mut phase),
                on_error,
                Some(Duration::from_secs(2)),
            )?
        }
        SampleFormat::I16 => {
            let (queue, failed) = (queue.clone(), failed.clone());
            let mut phase = 0_u64;
            device.build_input_stream::<i16, _, _>(
                config,
                move |data, _| capture_samples(data, channels, rate, &queue, &failed, &mut phase),
                on_error,
                Some(Duration::from_secs(2)),
            )?
        }
        SampleFormat::U16 => {
            let (queue, failed) = (queue.clone(), failed.clone());
            let mut phase = 0_u64;
            device.build_input_stream::<u16, _, _>(
                config,
                move |data, _| capture_samples(data, channels, rate, &queue, &failed, &mut phase),
                on_error,
                Some(Duration::from_secs(2)),
            )?
        }
        format => bail!("Unsupported microphone sample format: {format:?}"),
    };
    Ok(stream)
}

fn capture_samples<T: IntoPcm>(
    data: &[T],
    channels: usize,
    rate: u32,
    queue: &ArrayQueue<f32>,
    failed: &AtomicBool,
    phase: &mut u64,
) {
    if channels == 0 || rate == 0 || failed.load(Ordering::Relaxed) {
        return;
    }
    for frame in data.chunks_exact(channels) {
        let mono = frame.iter().map(|sample| sample.into_pcm()).sum::<f32>() / channels as f32;
        *phase += RATE as u64;
        while *phase >= rate as u64 {
            *phase -= rate as u64;
            if queue.push(mono).is_err() {
                // Losing samples would make a voice note sound broken; report
                // the overrun and discard the recording instead of succeeding.
                failed.store(true, Ordering::Relaxed);
                return;
            }
        }
    }
}

trait IntoPcm {
    fn into_pcm(&self) -> f32;
}

impl IntoPcm for f32 {
    fn into_pcm(&self) -> f32 {
        (*self).clamp(-1.0, 1.0)
    }
}

impl IntoPcm for i16 {
    fn into_pcm(&self) -> f32 {
        *self as f32 / 32768.0
    }
}

impl IntoPcm for u16 {
    fn into_pcm(&self) -> f32 {
        (*self as f32 - 32768.0) / 32768.0
    }
}

struct OggOpusWriter<W: Write> {
    inner: W,
    serial: u32,
    sequence: u32,
}

impl<W: Write> OggOpusWriter<W> {
    fn new(inner: W, serial: u32) -> Self {
        Self {
            inner,
            serial,
            sequence: 0,
        }
    }

    fn write_headers(&mut self) -> io::Result<()> {
        let mut opus_head = Vec::with_capacity(19);
        opus_head.extend_from_slice(b"OpusHead");
        opus_head.push(1); // Mapping version.
        opus_head.push(1); // Mono.
        opus_head.extend_from_slice(&(PRE_SKIP as u16).to_le_bytes());
        opus_head.extend_from_slice(&RATE.to_le_bytes());
        opus_head.extend_from_slice(&0_i16.to_le_bytes()); // Output gain.
        opus_head.push(0); // Mapping family 0.
        write_ogg_page(
            &mut self.inner,
            self.serial,
            &mut self.sequence,
            &opus_head,
            0,
            0x02,
        )?;

        let vendor = b"Conest";
        let mut opus_tags = Vec::with_capacity(20);
        opus_tags.extend_from_slice(b"OpusTags");
        opus_tags.extend_from_slice(&(vendor.len() as u32).to_le_bytes());
        opus_tags.extend_from_slice(vendor);
        opus_tags.extend_from_slice(&0_u32.to_le_bytes()); // No comments.
        write_ogg_page(
            &mut self.inner,
            self.serial,
            &mut self.sequence,
            &opus_tags,
            0,
            0,
        )
    }

    fn write_packet(&mut self, packet: &[u8], granule: u64, eos: bool) -> io::Result<()> {
        write_ogg_page(
            &mut self.inner,
            self.serial,
            &mut self.sequence,
            packet,
            granule,
            if eos { 0x04 } else { 0 },
        )
    }

    fn finish(mut self) -> io::Result<W> {
        self.inner.flush()?;
        Ok(self.inner)
    }
}

fn write_ogg_page<W: Write>(
    output: &mut W,
    serial: u32,
    sequence: &mut u32,
    packet: &[u8],
    granule: u64,
    flags: u8,
) -> io::Result<()> {
    let mut lacing = Vec::with_capacity(packet.len() / 255 + 1);
    let mut remaining = packet.len();
    while remaining >= 255 {
        lacing.push(255_u8);
        remaining -= 255;
    }
    lacing.push(remaining as u8);

    let mut page = Vec::with_capacity(27 + lacing.len() + packet.len());
    page.extend_from_slice(b"OggS");
    page.push(0); // Ogg bitstream version.
    page.push(flags);
    page.extend_from_slice(&granule.to_le_bytes());
    page.extend_from_slice(&serial.to_le_bytes());
    page.extend_from_slice(&sequence.to_le_bytes());
    page.extend_from_slice(&0_u32.to_le_bytes()); // CRC filled below.
    page.push(lacing.len() as u8);
    page.extend_from_slice(&lacing);
    page.extend_from_slice(packet);
    let checksum = ogg_crc(&page);
    page[22..26].copy_from_slice(&checksum.to_le_bytes());
    output.write_all(&page)?;
    *sequence = (*sequence).saturating_add(1);
    Ok(())
}

fn ogg_crc(page: &[u8]) -> u32 {
    let mut checksum = 0_u32;
    for byte in page {
        checksum ^= u32::from(*byte) << 24;
        for _ in 0..8 {
            checksum = if checksum & 0x8000_0000 != 0 {
                (checksum << 1) ^ 0x04c1_1db7
            } else {
                checksum << 1
            };
        }
    }
    checksum
}

#[cfg(test)]
mod tests {
    use super::{
        Application, Channels, Encoder, OggOpusWriter, PRE_SKIP, RATE, capture_samples, ogg_crc,
    };
    use crossbeam_queue::ArrayQueue;
    use std::io::Cursor;
    use std::sync::atomic::AtomicBool;

    #[test]
    fn capture_converts_supported_sample_formats_without_losing_samples() {
        let failed = AtomicBool::new(false);
        let queue = ArrayQueue::new(8);
        let mut phase = 0;
        capture_samples(&[0.5_f32, -0.5], 1, RATE, &queue, &failed, &mut phase);
        assert_eq!(queue.pop(), Some(0.5));
        assert_eq!(queue.pop(), Some(-0.5));

        let queue = ArrayQueue::new(8);
        phase = 0;
        capture_samples(&[16_384_i16, -16_384], 1, RATE, &queue, &failed, &mut phase);
        assert_eq!(queue.pop(), Some(0.5));
        assert_eq!(queue.pop(), Some(-0.5));

        let queue = ArrayQueue::new(8);
        phase = 0;
        capture_samples(&[49_152_u16, 16_384], 1, RATE, &queue, &failed, &mut phase);
        assert_eq!(queue.pop(), Some(0.5));
        assert_eq!(queue.pop(), Some(-0.5));
        assert!(!failed.load(std::sync::atomic::Ordering::Relaxed));
    }

    #[test]
    fn muxer_writes_valid_ogg_opus_headers_and_final_granule() {
        let mut output = Cursor::new(Vec::new());
        {
            let mut muxer = OggOpusWriter::new(&mut output, 7);
            muxer.write_headers().unwrap();
            let mut encoder = Encoder::new(RATE, Channels::Mono, Application::Voip).unwrap();
            let input: Vec<f32> = (0..960)
                .map(|sample| {
                    (sample as f32 * 440.0 * std::f32::consts::TAU / RATE as f32).sin() * 0.2
                })
                .collect();
            let packet = encoder.encode_vec_float(&input, 1_275).unwrap();
            muxer
                .write_packet(&packet, PRE_SKIP + input.len() as u64, true)
                .unwrap();
        }

        let bytes = output.into_inner();
        let mut offset = 0;
        let mut page_index = 0;
        while offset < bytes.len() {
            assert_eq!(&bytes[offset..offset + 4], b"OggS");
            let segment_count = bytes[offset + 26] as usize;
            let body_len: usize = bytes[offset + 27..offset + 27 + segment_count]
                .iter()
                .map(|length| *length as usize)
                .sum();
            let page_len = 27 + segment_count + body_len;
            let mut page = bytes[offset..offset + page_len].to_vec();
            let stored_crc = u32::from_le_bytes(page[22..26].try_into().unwrap());
            page[22..26].fill(0);
            assert_eq!(ogg_crc(&page), stored_crc);
            if page_index == 0 {
                assert_eq!(page[5], 0x02);
                let body_start = 27 + segment_count;
                assert_eq!(&page[body_start..body_start + 8], b"OpusHead");
            }
            if page_index == 1 {
                let body_start = 27 + segment_count;
                assert_eq!(&page[body_start..body_start + 8], b"OpusTags");
            }
            if page[5] & 0x04 != 0 {
                assert_eq!(u64::from_le_bytes(page[6..14].try_into().unwrap()), 1_272);
            }
            offset += page_len;
            page_index += 1;
        }
        assert_eq!(page_index, 3);
    }
}
