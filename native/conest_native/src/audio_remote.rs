//! Bounded independent receive streams. One missing participant never gates
//! another participant's decoder or playout clock.

use super::{FRAME_SAMPLES, MAX_OPUS_PACKET, OPUS_PACKET_QUEUE, PacketJitterBuffer, VOICE_RATE};
use opus::{Channels, Decoder};
use std::{
    collections::{BTreeMap, VecDeque},
    time::Instant,
};

pub(super) const MAX_REMOTE_STREAMS: u16 = 16;

/// A playout gap this long (3 frames of 20 ms) or longer counts as one
/// audible break (stutter).
const GAP_FRAMES: u32 = 3;

/// The receive side of a call's audio statistics (see CallStats).
#[derive(Default, Clone, Copy)]
pub(super) struct ReceiveStats {
    pub received: u64,
    pub late_or_duplicate: u64,
    pub lost: u64,
    pub concealed_frames: u64,
    pub gaps: u64,
    pub jitter_ms: f64,
}

struct RemoteStream {
    decoder: Decoder,
    jitter: PacketJitterBuffer,
    pcm: VecDeque<f32>,
    level: f32,
    /// A packet came, so silence from now on is a gap, not a quiet start.
    started: bool,
    /// Frames in a row played with too little audio.
    short_run: u32,
    received: u64,
    late_or_duplicate: u64,
    concealed_frames: u64,
    gaps: u64,
}

impl RemoteStream {
    fn new() -> opus::Result<Self> {
        Ok(Self {
            decoder: Decoder::new(VOICE_RATE, Channels::Mono)?,
            jitter: PacketJitterBuffer::new(1),
            pcm: VecDeque::with_capacity(FRAME_SAMPLES * 6),
            level: 0.0,
            started: false,
            short_run: 0,
            received: 0,
            late_or_duplicate: 0,
            concealed_frames: 0,
            gaps: 0,
        })
    }

    fn render(&mut self, now: Instant, output: &mut [f32; FRAME_SAMPLES]) -> bool {
        // Decode only enough for this playout period. Both the jitter queue
        // and decoded PCM are bounded, including 120 ms Opus packets.
        while self.pcm.len() < FRAME_SAMPLES {
            let Some(packet) = self.jitter.pop_ready(now) else {
                break;
            };
            let mut decoded = [0.0; FRAME_SAMPLES * 6];
            if let Ok(count) = self.decoder.decode_float(&packet, &mut decoded, false) {
                for &sample in decoded.iter().take(count) {
                    if self.pcm.len() < FRAME_SAMPLES * 6 {
                        self.pcm.push_back(sample);
                    }
                }
            }
        }
        let ready = !self.pcm.is_empty();
        if self.started {
            if self.pcm.len() < FRAME_SAMPLES {
                self.concealed_frames += 1;
                self.short_run += 1;
                if self.short_run == GAP_FRAMES {
                    self.gaps += 1;
                }
            } else {
                self.short_run = 0;
            }
        }
        let mut energy = 0.0;
        for sample in output {
            *sample = self.pcm.pop_front().unwrap_or(0.0);
            energy += *sample * *sample;
        }
        self.level = (energy / FRAME_SAMPLES as f32).sqrt().min(1.0);
        ready
    }
}

pub(super) struct RemoteMixer {
    streams: BTreeMap<u16, RemoteStream>,
    /// Each participant's volume as set on this device (1 when unset).
    volumes: BTreeMap<u16, f32>,
}

impl RemoteMixer {
    pub fn new() -> opus::Result<Self> {
        let mut mixer = Self {
            streams: BTreeMap::new(),
            volumes: BTreeMap::new(),
        };
        // The unchanged public 1:1 ABI always addresses stream zero.
        mixer.set_active(0, true)?;
        Ok(mixer)
    }

    pub fn set_active(&mut self, participant: u16, active: bool) -> opus::Result<bool> {
        if participant >= MAX_REMOTE_STREAMS {
            return Ok(false);
        }
        if !active {
            self.streams.remove(&participant);
            return Ok(true);
        }
        if !self.streams.contains_key(&participant) {
            self.streams.insert(participant, RemoteStream::new()?);
        }
        Ok(true)
    }

    /// A participant's volume (0 to 2), kept across their stream restarting.
    pub fn set_volume(&mut self, participant: u16, gain: f32) -> bool {
        if participant >= MAX_REMOTE_STREAMS || !gain.is_finite() {
            return false;
        }
        let gain = gain.clamp(0.0, 2.0);
        if (gain - 1.0).abs() < f32::EPSILON {
            self.volumes.remove(&participant);
        } else {
            self.volumes.insert(participant, gain);
        }
        true
    }

    pub fn push(&mut self, participant: u16, sequence: u64, packet: &[u8], now: Instant) -> bool {
        if sequence == 0 || packet.is_empty() || packet.len() > MAX_OPUS_PACKET {
            return false;
        }
        let Some(stream) = self.streams.get_mut(&participant) else {
            return false;
        };
        if stream.jitter.insert(sequence, packet.to_vec(), now) {
            stream.received += 1;
            stream.started = true;
        } else {
            stream.late_or_duplicate += 1;
        }
        true
    }

    /// Summed over the streams now playing; the jitter is the worst one.
    pub fn stats(&self) -> ReceiveStats {
        let mut stats = ReceiveStats::default();
        for stream in self.streams.values() {
            stats.received += stream.received;
            stats.late_or_duplicate += stream.late_or_duplicate;
            stats.lost += stream.jitter.lost;
            stats.concealed_frames += stream.concealed_frames;
            stats.gaps += stream.gaps;
            stats.jitter_ms = stats
                .jitter_ms
                .max(stream.jitter.jitter().as_secs_f64() * 1000.0);
        }
        stats
    }

    pub fn level(&self, participant: u16) -> f32 {
        self.streams
            .get(&participant)
            .map_or(0.0, |stream| stream.level)
    }

    pub fn render(&mut self, now: Instant) -> Option<[f32; FRAME_SAMPLES]> {
        let mut mixed = [0.0; FRAME_SAMPLES];
        let mut any_ready = false;
        for (participant, stream) in self.streams.iter_mut() {
            let mut frame = [0.0; FRAME_SAMPLES];
            any_ready |= stream.render(now, &mut frame);
            if let Some(gain) = self.volumes.get(participant) {
                for sample in &mut frame {
                    *sample *= gain;
                }
            }
            add_frame(&mut mixed, &frame);
        }
        if !any_ready {
            return None;
        }
        for sample in &mut mixed {
            *sample = sample.clamp(-1.0, 1.0);
        }
        Some(mixed)
    }
}

fn add_frame(output: &mut [f32; FRAME_SAMPLES], frame: &[f32; FRAME_SAMPLES]) {
    for (out, sample) in output.iter_mut().zip(frame) {
        *out += sample;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use opus::{Application, Encoder};
    use std::time::Duration;

    fn packet() -> Vec<u8> {
        let input: Vec<f32> = (0..FRAME_SAMPLES)
            .map(|i| (i as f32 * 0.04).sin() * 0.3)
            .collect();
        Encoder::new(VOICE_RATE, Channels::Mono, Application::Voip)
            .unwrap()
            .encode_vec_float(&input, MAX_OPUS_PACKET)
            .unwrap()
    }

    #[test]
    fn mixes_all_streams_and_clamps_only_the_final_sum() {
        let now = Instant::now();
        let mut mixer = RemoteMixer::new().unwrap();
        for id in 0..MAX_REMOTE_STREAMS {
            mixer.set_active(id, true).unwrap();
            // Predecoded PCM makes this a precise mixing/clipping test,
            // independent of the codec's initial delay.
            mixer
                .streams
                .get_mut(&id)
                .unwrap()
                .pcm
                .extend([0.75; FRAME_SAMPLES]);
        }
        let mixed = mixer.render(now).unwrap();
        assert!(mixed.iter().all(|&s| s == 1.0));
        assert_eq!(mixer.level(1), 0.75);
        assert!(!mixer.set_active(MAX_REMOTE_STREAMS, true).unwrap());
        assert_eq!(mixer.streams.len(), 16);
    }

    #[test]
    fn a_participant_volume_scales_only_that_stream() {
        let now = Instant::now();
        let mut mixer = RemoteMixer::new().unwrap();
        mixer.set_active(1, true).unwrap();
        assert!(mixer.set_volume(1, 0.5));
        assert!(!mixer.set_volume(MAX_REMOTE_STREAMS, 0.5));
        assert!(!mixer.set_volume(1, f32::NAN) || mixer.volumes[&1] == 0.5);
        for id in [0, 1] {
            mixer
                .streams
                .get_mut(&id)
                .unwrap()
                .pcm
                .extend([0.2; FRAME_SAMPLES]);
        }
        let mixed = mixer.render(now).unwrap();
        // 0.2 (stream 0) + 0.2 * 0.5 (stream 1).
        assert!(mixed.iter().all(|&s| (s - 0.3).abs() < 1e-6));
        // The level shows who speaks, whatever the volume.
        assert_eq!(mixer.level(1), 0.2);
        assert!(mixer.set_volume(1, 1.0));
        assert!(mixer.volumes.is_empty());
    }

    #[test]
    fn leaving_discards_decoder_jitter_pcm_and_level() {
        let mut mixer = RemoteMixer::new().unwrap();
        let now = Instant::now();
        let bytes = packet();
        mixer.set_active(2, true).unwrap();
        assert!(mixer.push(2, 1, &bytes, now));
        assert!(mixer.render(now).is_some());
        assert!(mixer.level(2) > 0.0);
        mixer.set_active(2, false).unwrap();
        assert!(!mixer.push(2, 2, &bytes, now));
        assert_eq!(mixer.level(2), 0.0);
        mixer.set_active(2, true).unwrap();
        assert!(mixer.render(now).is_none());
        assert!(mixer.push(2, 1, &bytes, now));
        assert!(mixer.render(now).is_some());
    }

    #[test]
    fn counts_received_late_lost_and_audible_gaps() {
        let mut mixer = RemoteMixer::new().unwrap();
        let start = Instant::now();
        let bytes = packet();
        // 1 and 2 arrive, 3 never does, 4 arrives; 2 comes again (a copy).
        assert!(mixer.push(0, 1, &bytes, start));
        assert!(mixer.push(0, 2, &bytes, start + Duration::from_millis(20)));
        assert!(mixer.push(0, 4, &bytes, start + Duration::from_millis(60)));
        let mut now = start;
        for _ in 0..10 {
            mixer.render(now);
            now += Duration::from_millis(20);
        }
        assert!(mixer.push(0, 2, &bytes, now));
        let stats = mixer.stats();
        assert_eq!(stats.received, 3);
        assert_eq!(stats.late_or_duplicate, 1);
        assert_eq!(stats.lost, 1);
        // After the last packet, the silence that follows is one gap.
        assert!(stats.concealed_frames >= GAP_FRAMES as u64);
        assert_eq!(stats.gaps, 1);
    }

    #[test]
    fn silence_before_the_first_packet_is_not_a_gap() {
        let mut mixer = RemoteMixer::new().unwrap();
        let mut now = Instant::now();
        for _ in 0..20 {
            mixer.render(now);
            now += Duration::from_millis(20);
        }
        let stats = mixer.stats();
        assert_eq!(stats.concealed_frames, 0);
        assert_eq!(stats.gaps, 0);
    }

    #[test]
    fn one_stream_gap_or_flood_does_not_stall_other_streams() {
        let mut mixer = RemoteMixer::new().unwrap();
        mixer.set_active(1, true).unwrap();
        let now = Instant::now();
        let bytes = packet();
        for sequence in 2..100 {
            mixer.push(0, sequence, &bytes, now);
        }
        assert!(mixer.streams[&0].jitter.pending.len() <= OPUS_PACKET_QUEUE);
        mixer.push(1, 1, &bytes, now);
        assert!(mixer.render(now).is_some());
        // Stream 0's missing first packet, with audio waiting behind it, is
        // skipped rather than waited for; stream 1 plays regardless.
        assert!(mixer.level(0) > 0.0);
        assert!(mixer.level(1) > 0.0);
        assert!(mixer.render(now + Duration::from_millis(110)).is_some());
    }
}
