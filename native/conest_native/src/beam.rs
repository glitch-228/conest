//! Conest Beam v1 frame validation shared by native camera backends.
//!
//! Fountain solving and attachment import remain in the Flutter layer, but a
//! camera frame does not cross FFI until its protocol header, geometry, and
//! CRC32C have been checked here. This keeps every desktop capture backend on
//! the same wire format and bounds untrusted QR input before Dart sees it.

use anyhow::{Context, Result, anyhow, bail};
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};

const PREFIX: &str = "cb1:";
const MAGIC: &[u8; 4] = b"CBM1";
const HEADER_LENGTH: usize = 50;
const MAX_BLOCK_SIZE: usize = 2048;
const MAX_PACKAGE_BYTES: u64 = 64 * 1024 * 1024 + 64 * 1024 + 4;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BeamFrameHeader {
    pub mode: u8,
    pub systematic: bool,
    pub transfer_id: [u8; 16],
    pub original_length: u64,
    pub block_size: u16,
    pub source_block_count: u32,
    pub seed: u32,
    pub degree: u16,
}

impl BeamFrameHeader {
    pub fn parse_text(value: &str) -> Result<Self> {
        let encoded = value
            .strip_prefix(PREFIX)
            .ok_or_else(|| anyhow!("not a Conest Beam frame"))?;
        let bytes = URL_SAFE_NO_PAD
            .decode(encoded)
            .context("decode Conest Beam base64url")?;
        Self::parse_bytes(&bytes)
    }

    pub fn parse_bytes(bytes: &[u8]) -> Result<Self> {
        if bytes.len() < HEADER_LENGTH || bytes.get(..4) != Some(MAGIC) {
            bail!("invalid Conest Beam frame header");
        }
        if bytes[4] != 1 {
            bail!("unsupported Conest Beam frame version");
        }
        let mode = bytes[5];
        if mode > 2 || bytes[7] != 0 {
            bail!("invalid Conest Beam mode or reserved flags");
        }
        let systematic = bytes[6] & 1 == 1;
        if bytes[6] & !1 != 0 {
            bail!("invalid Conest Beam flags");
        }
        let transfer_id = bytes[8..24]
            .try_into()
            .expect("fixed-size transfer id slice");
        let original_length = u64::from_be_bytes(
            bytes[24..32]
                .try_into()
                .expect("fixed-size original length slice"),
        );
        let block_size = u16::from_be_bytes(
            bytes[32..34]
                .try_into()
                .expect("fixed-size block size slice"),
        );
        let source_block_count = u32::from_be_bytes(
            bytes[34..38]
                .try_into()
                .expect("fixed-size block count slice"),
        );
        let seed = u32::from_be_bytes(bytes[38..42].try_into().expect("fixed-size seed slice"));
        let degree = u16::from_be_bytes(bytes[42..44].try_into().expect("fixed-size degree slice"));
        let payload_length = u16::from_be_bytes(
            bytes[44..46]
                .try_into()
                .expect("fixed-size payload length slice"),
        ) as usize;
        if original_length == 0
            || original_length > MAX_PACKAGE_BYTES
            || block_size == 0
            || block_size as usize > MAX_BLOCK_SIZE
            || payload_length != block_size as usize
            || bytes.len() != HEADER_LENGTH + payload_length
            || source_block_count == 0
            || degree == 0
            || u32::from(degree) > source_block_count
        {
            bail!("invalid Conest Beam frame dimensions");
        }
        let expected_blocks = original_length.div_ceil(u64::from(block_size));
        if expected_blocks != u64::from(source_block_count)
            || (systematic && (degree != 1 || seed >= source_block_count))
        {
            bail!("inconsistent Conest Beam source geometry");
        }

        let expected_crc =
            u32::from_be_bytes(bytes[46..50].try_into().expect("fixed-size CRC32C slice"));
        let mut checked = bytes.to_vec();
        checked[46..50].fill(0);
        if crc32c(&checked) != expected_crc {
            bail!("Conest Beam frame CRC32C mismatch");
        }

        Ok(Self {
            mode,
            systematic,
            transfer_id,
            original_length,
            block_size,
            source_block_count,
            seed,
            degree,
        })
    }
}

fn crc32c(bytes: &[u8]) -> u32 {
    let mut crc = 0xffff_ffff_u32;
    for byte in bytes {
        crc ^= u32::from(*byte);
        for _ in 0..8 {
            crc = if crc & 1 == 1 {
                (crc >> 1) ^ 0x82f6_3b78
            } else {
                crc >> 1
            };
        }
    }
    crc ^ 0xffff_ffff
}

#[cfg(test)]
mod tests {
    use super::*;

    // This exact vector is also asserted in test/beam_protocol_test.dart.
    const DART_GOLDEN_FRAME: &str = "cb1:Q0JNMQEAAQAAESIzRFVmd4iZqrvM3e7_AAAAAAAAASwBAAAAAAIAAAAAAAEBANqb9GIAAQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8wMTIzNDU2Nzg5Ojs8PT4_QEFCQ0RFRkdISUpLTE1OT1BRUlNUVVZXWFlaW1xdXl9gYWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXp7fH1-f4CBgoOEhYaHiImKi4yNjo-QkZKTlJWWl5iZmpucnZ6foKGio6SlpqeoqaqrrK2ur7CxsrO0tba3uLm6u7y9vr_AwcLDxMXGx8jJysvMzc7P0NHS09TV1tfY2drb3N3e3-Dh4uPk5ebn6Onq6-zt7u_w8fLz9PX29_j5-vv8_f7_";

    #[test]
    fn parses_dart_golden_frame() {
        let frame = BeamFrameHeader::parse_text(DART_GOLDEN_FRAME).unwrap();
        assert_eq!(frame.mode, 0);
        assert!(frame.systematic);
        assert_eq!(frame.transfer_id, hex_transfer_id());
        assert_eq!(frame.original_length, 300);
        assert_eq!(frame.block_size, 256);
        assert_eq!(frame.source_block_count, 2);
        assert_eq!(frame.seed, 0);
        assert_eq!(frame.degree, 1);
    }

    #[test]
    fn rejects_corrupted_golden_frame() {
        let mut bytes = URL_SAFE_NO_PAD
            .decode(DART_GOLDEN_FRAME.strip_prefix(PREFIX).unwrap())
            .unwrap();
        *bytes.last_mut().unwrap() ^= 1;
        assert!(BeamFrameHeader::parse_bytes(&bytes).is_err());
    }

    fn hex_transfer_id() -> [u8; 16] {
        [
            0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd,
            0xee, 0xff,
        ]
    }
}
