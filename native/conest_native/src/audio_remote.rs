//! Bounded independent receive streams. One missing participant never gates
//! another participant's decoder or playout clock.

use super::{FRAME_SAMPLES, MAX_OPUS_PACKET, OPUS_PACKET_QUEUE, PacketJitterBuffer, VOICE_RATE};
use opus::{Channels, Decoder};
use std::{
    collections::{BTreeMap, VecDeque},
    time::Instant,
};

pub(super) const MAX_REMOTE_STREAMS: u16 = 16;

struct RemoteStream {
    decoder: Decoder,
    jitter: PacketJitterBuffer,
    pcm: VecDeque<f32>,
    level: f32,
}

impl RemoteStream {
    fn new() -> opus::Result<Self> {
        Ok(Self {
            decoder: Decoder::new(VOICE_RATE, Channels::Mono)?,
            jitter: PacketJitterBuffer::new(1),
            pcm: VecDeque::with_capacity(FRAME_SAMPLES * 6),
            level: 0.0,
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
}

impl RemoteMixer {
    pub fn new() -> opus::Result<Self> {
        let mut mixer = Self {
            streams: BTreeMap::new(),
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

    pub fn push(&mut self, participant: u16, sequence: u64, packet: &[u8], now: Instant) -> bool {
        if sequence == 0 || packet.is_empty() || packet.len() > MAX_OPUS_PACKET {
            return false;
        }
        let Some(stream) = self.streams.get_mut(&participant) else {
            return false;
        };
        stream.jitter.insert(sequence, packet.to_vec(), now);
        true
    }

    pub fn level(&self, participant: u16) -> f32 {
        self.streams
            .get(&participant)
            .map_or(0.0, |stream| stream.level)
    }

    pub fn render(&mut self, now: Instant) -> Option<[f32; FRAME_SAMPLES]> {
        let mut mixed = [0.0; FRAME_SAMPLES];
        let mut any_ready = false;
        for stream in self.streams.values_mut() {
            let mut frame = [0.0; FRAME_SAMPLES];
            any_ready |= stream.render(now, &mut frame);
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
        assert_eq!(mixer.level(0), 0.0);
        assert!(mixer.level(1) > 0.0);
        assert!(mixer.render(now + Duration::from_millis(110)).is_some());
    }
}
