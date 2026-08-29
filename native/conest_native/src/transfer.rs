//! Attachment protocol v2 primitives.
//!
//! This module owns the performance- and crash-sensitive portion of file
//! transfer: stable block framing, application-level authenticated encryption,
//! exact byte accounting and a durable range journal. Network adapters can
//! carry the same frame over LAN, Iroh or a store-forward relay without
//! changing file integrity or resume semantics.

use std::{
    collections::BTreeSet,
    fs::{self, File, OpenOptions},
    io::{Read, Seek, SeekFrom, Write},
    path::{Path, PathBuf},
    time::{Duration, Instant},
};

use anyhow::{Context, Result, anyhow, bail};
use chacha20poly1305::{
    XChaCha20Poly1305, XNonce,
    aead::{Aead, KeyInit, Payload},
};
use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

pub const ATTACHMENT_PROTOCOL_VERSION: u16 = 2;
pub const ATTACHMENT_BLOCK_SIZE: u32 = 128 * 1024;
pub const ATTACHMENT_LAN_BLOCK_SIZE: u32 = 4 * 1024 * 1024;
pub const MAX_ATTACHMENT_BYTES: u64 = 2 * 1024 * 1024 * 1024;
pub const JOURNAL_CHECKPOINT_BYTES: u64 = 8 * 1024 * 1024;
pub const JOURNAL_CHECKPOINT_INTERVAL: Duration = Duration::from_secs(2);

const FRAME_MAGIC: &[u8; 4] = b"CAT2";
const JOURNAL_MAGIC: &[u8; 4] = b"CAJ2";
const FRAME_HEADER_LEN: usize = 4 + 2 + 2 + 8 + 4 + 4 + 32;
const JOURNAL_RECORD_LEN: usize = 4 + 2 + 2 + 4 + 4 + 32 + 32;
const AEAD_TAG_LEN: usize = 16;

type HmacSha256 = Hmac<Sha256>;

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum TransferPhase {
    Preparing,
    Queued,
    AwaitingApproval,
    WaitingForPeer,
    Transferring,
    Reconnecting,
    Paused,
    Verifying,
    Completed,
    Failed,
    Canceled,
    Unavailable,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum AttachmentPresentation {
    Media,
    File,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct TransferMediaMetadata {
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub duration_millis: Option<u64>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct TransferManifest {
    pub protocol_version: u16,
    pub transfer_id: String,
    pub message_id: String,
    pub album_id: Option<String>,
    pub presentation: AttachmentPresentation,
    pub file_name: String,
    pub mime_type: String,
    pub media_metadata: Option<TransferMediaMetadata>,
    pub thumbnail: Vec<u8>,
    pub size_bytes: u64,
    pub block_size: u32,
    pub block_count: u32,
    pub whole_sha256: [u8; 32],
    pub nonce_prefix: [u8; 16],
}

impl TransferManifest {
    pub fn validate(&self) -> Result<()> {
        if self.protocol_version != ATTACHMENT_PROTOCOL_VERSION {
            bail!("unsupported attachment protocol version");
        }
        if self.transfer_id.is_empty() || self.transfer_id.len() > 160 {
            bail!("transfer id is outside the allowed range");
        }
        if self.message_id.is_empty() || self.message_id.len() > 160 {
            bail!("message id is outside the allowed range");
        }
        if self
            .album_id
            .as_ref()
            .is_some_and(|value| value.len() > 160)
        {
            bail!("album id is outside the allowed range");
        }
        if self.file_name.is_empty() || self.file_name.len() > 255 {
            bail!("file name is outside the allowed range");
        }
        if self.mime_type.is_empty() || self.mime_type.len() > 255 {
            bail!("MIME type is outside the allowed range");
        }
        if self.thumbnail.len() > 64 * 1024 {
            bail!("attachment thumbnail exceeds 64 KiB");
        }
        if let Some(metadata) = &self.media_metadata
            && (metadata.width == Some(0)
                || metadata.height == Some(0)
                || metadata.duration_millis == Some(0))
        {
            bail!("media metadata values must be positive");
        }
        if self.size_bytes == 0 || self.size_bytes > MAX_ATTACHMENT_BYTES {
            bail!("attachment size is outside the allowed range");
        }
        if self.block_size != ATTACHMENT_BLOCK_SIZE && self.block_size != ATTACHMENT_LAN_BLOCK_SIZE
        {
            bail!("attachment v2 requires 128 KiB or 4 MiB blocks");
        }
        let expected = self.size_bytes.div_ceil(self.block_size as u64);
        if self.block_count == 0 || self.block_count as u64 != expected {
            bail!("attachment block geometry is inconsistent");
        }
        Ok(())
    }

    pub fn expected_plaintext_len(&self, block_index: u32) -> Result<u32> {
        self.validate()?;
        if block_index >= self.block_count {
            bail!("attachment block index is outside the manifest");
        }
        let offset = block_index as u64 * self.block_size as u64;
        Ok((self.size_bytes - offset).min(self.block_size as u64) as u32)
    }

    pub fn digest(&self) -> [u8; 32] {
        let mut digest = Sha256::new();
        digest.update(self.protocol_version.to_be_bytes());
        digest.update((self.transfer_id.len() as u32).to_be_bytes());
        digest.update(self.transfer_id.as_bytes());
        digest.update((self.message_id.len() as u32).to_be_bytes());
        digest.update(self.message_id.as_bytes());
        let album_id = self.album_id.as_deref().unwrap_or_default();
        digest.update((album_id.len() as u32).to_be_bytes());
        digest.update(album_id.as_bytes());
        digest.update([match self.presentation {
            AttachmentPresentation::Media => 0,
            AttachmentPresentation::File => 1,
        }]);
        digest.update((self.file_name.len() as u32).to_be_bytes());
        digest.update(self.file_name.as_bytes());
        digest.update((self.mime_type.len() as u32).to_be_bytes());
        digest.update(self.mime_type.as_bytes());
        if let Some(metadata) = &self.media_metadata {
            digest.update([1]);
            digest.update(metadata.width.unwrap_or_default().to_be_bytes());
            digest.update(metadata.height.unwrap_or_default().to_be_bytes());
            digest.update(metadata.duration_millis.unwrap_or_default().to_be_bytes());
        } else {
            digest.update([0]);
        }
        digest.update((self.thumbnail.len() as u32).to_be_bytes());
        digest.update(&self.thumbnail);
        digest.update(self.size_bytes.to_be_bytes());
        digest.update(self.block_size.to_be_bytes());
        digest.update(self.block_count.to_be_bytes());
        digest.update(self.whole_sha256);
        digest.update(self.nonce_prefix);
        digest.finalize().into()
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AttachmentBlockFrame {
    pub manifest_digest_prefix: u64,
    pub block_index: u32,
    pub plaintext_len: u32,
    pub plaintext_sha256: [u8; 32],
    pub ciphertext: Vec<u8>,
}

impl AttachmentBlockFrame {
    pub fn encrypt(
        manifest: &TransferManifest,
        attachment_key: &[u8; 32],
        block_index: u32,
        plaintext: &[u8],
    ) -> Result<Self> {
        let expected = manifest.expected_plaintext_len(block_index)? as usize;
        if plaintext.len() != expected {
            bail!("attachment block plaintext has the wrong length");
        }
        let manifest_digest = manifest.digest();
        let plaintext_sha256: [u8; 32] = Sha256::digest(plaintext).into();
        let nonce = block_nonce(manifest.nonce_prefix, block_index);
        let aad = block_aad(&manifest_digest, block_index, expected as u32);
        let cipher = XChaCha20Poly1305::new_from_slice(attachment_key)
            .map_err(|_| anyhow!("attachment key must be 32 bytes"))?;
        let ciphertext = cipher
            .encrypt(
                XNonce::from_slice(&nonce),
                Payload {
                    msg: plaintext,
                    aad: &aad,
                },
            )
            .map_err(|_| anyhow!("attachment block encryption failed"))?;
        Ok(Self {
            manifest_digest_prefix: u64::from_be_bytes(
                manifest_digest[..8]
                    .try_into()
                    .expect("fixed digest prefix"),
            ),
            block_index,
            plaintext_len: expected as u32,
            plaintext_sha256,
            ciphertext,
        })
    }

    pub fn decrypt(
        &self,
        manifest: &TransferManifest,
        attachment_key: &[u8; 32],
    ) -> Result<Vec<u8>> {
        let manifest_digest = manifest.digest();
        if self.manifest_digest_prefix
            != u64::from_be_bytes(
                manifest_digest[..8]
                    .try_into()
                    .expect("fixed digest prefix"),
            )
        {
            bail!("attachment block belongs to another manifest");
        }
        let expected = manifest.expected_plaintext_len(self.block_index)?;
        if self.plaintext_len != expected
            || self.ciphertext.len() != expected as usize + AEAD_TAG_LEN
        {
            bail!("attachment block geometry is invalid");
        }
        let nonce = block_nonce(manifest.nonce_prefix, self.block_index);
        let aad = block_aad(&manifest_digest, self.block_index, expected);
        let cipher = XChaCha20Poly1305::new_from_slice(attachment_key)
            .map_err(|_| anyhow!("attachment key must be 32 bytes"))?;
        let plaintext = cipher
            .decrypt(
                XNonce::from_slice(&nonce),
                Payload {
                    msg: &self.ciphertext,
                    aad: &aad,
                },
            )
            .map_err(|_| anyhow!("attachment block authentication failed"))?;
        let actual: [u8; 32] = Sha256::digest(&plaintext).into();
        if actual != self.plaintext_sha256 {
            bail!("attachment block digest mismatch");
        }
        Ok(plaintext)
    }

    pub fn encode(&self) -> Result<Vec<u8>> {
        if self.plaintext_len == 0
            || self.ciphertext.len() != self.plaintext_len as usize + AEAD_TAG_LEN
        {
            bail!("attachment frame has invalid lengths");
        }
        let mut encoded = Vec::with_capacity(FRAME_HEADER_LEN + self.ciphertext.len());
        encoded.extend_from_slice(FRAME_MAGIC);
        encoded.extend_from_slice(&ATTACHMENT_PROTOCOL_VERSION.to_be_bytes());
        encoded.extend_from_slice(&0_u16.to_be_bytes());
        encoded.extend_from_slice(&self.manifest_digest_prefix.to_be_bytes());
        encoded.extend_from_slice(&self.block_index.to_be_bytes());
        encoded.extend_from_slice(&self.plaintext_len.to_be_bytes());
        encoded.extend_from_slice(&self.plaintext_sha256);
        encoded.extend_from_slice(&self.ciphertext);
        Ok(encoded)
    }

    pub fn decode(encoded: &[u8]) -> Result<Self> {
        if encoded.len() < FRAME_HEADER_LEN + AEAD_TAG_LEN || &encoded[..4] != FRAME_MAGIC {
            bail!("attachment frame header is invalid");
        }
        let version = u16::from_be_bytes(encoded[4..6].try_into()?);
        if version != ATTACHMENT_PROTOCOL_VERSION {
            bail!("unsupported attachment frame version");
        }
        let manifest_digest_prefix = u64::from_be_bytes(encoded[8..16].try_into()?);
        let block_index = u32::from_be_bytes(encoded[16..20].try_into()?);
        let plaintext_len = u32::from_be_bytes(encoded[20..24].try_into()?);
        let plaintext_sha256 = encoded[24..56].try_into()?;
        let ciphertext = encoded[56..].to_vec();
        if plaintext_len == 0 || ciphertext.len() != plaintext_len as usize + AEAD_TAG_LEN {
            bail!("attachment frame payload length is invalid");
        }
        Ok(Self {
            manifest_digest_prefix,
            block_index,
            plaintext_len,
            plaintext_sha256,
            ciphertext,
        })
    }
}

fn block_nonce(prefix: [u8; 16], block_index: u32) -> [u8; 24] {
    let mut nonce = [0_u8; 24];
    nonce[..16].copy_from_slice(&prefix);
    nonce[20..].copy_from_slice(&block_index.to_be_bytes());
    nonce
}

fn block_aad(manifest_digest: &[u8; 32], block_index: u32, length: u32) -> [u8; 40] {
    let mut aad = [0_u8; 40];
    aad[..32].copy_from_slice(manifest_digest);
    aad[32..36].copy_from_slice(&block_index.to_be_bytes());
    aad[36..].copy_from_slice(&length.to_be_bytes());
    aad
}

#[derive(Debug)]
pub struct TransferJournal {
    path: PathBuf,
    key: [u8; 32],
    durable: BTreeSet<u32>,
}

impl TransferJournal {
    pub fn open(path: impl Into<PathBuf>, key: [u8; 32]) -> Result<Self> {
        let path = path.into();
        let durable = load_journal_records(&path, &key)?;
        Ok(Self { path, key, durable })
    }

    pub fn durable_blocks(&self) -> &BTreeSet<u32> {
        &self.durable
    }

    pub fn append(&mut self, block_index: u32, plaintext_len: u32, digest: [u8; 32]) -> Result<()> {
        if self.durable.contains(&block_index) {
            return Ok(());
        }
        if let Some(parent) = self.path.parent() {
            fs::create_dir_all(parent).with_context(|| {
                format!("create transfer journal directory {}", parent.display())
            })?;
        }
        let mut prefix = Vec::with_capacity(JOURNAL_RECORD_LEN - 32);
        prefix.extend_from_slice(JOURNAL_MAGIC);
        prefix.extend_from_slice(&ATTACHMENT_PROTOCOL_VERSION.to_be_bytes());
        prefix.extend_from_slice(&0_u16.to_be_bytes());
        prefix.extend_from_slice(&block_index.to_be_bytes());
        prefix.extend_from_slice(&plaintext_len.to_be_bytes());
        prefix.extend_from_slice(&digest);
        let tag = journal_tag(&self.key, &prefix)?;
        let mut file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.path)
            .with_context(|| format!("open transfer journal {}", self.path.display()))?;
        file.write_all(&prefix)?;
        file.write_all(&tag)?;
        file.sync_data()?;
        self.durable.insert(block_index);
        Ok(())
    }
}

fn load_journal_records(path: &Path, key: &[u8; 32]) -> Result<BTreeSet<u32>> {
    if !path.exists() {
        return Ok(BTreeSet::new());
    }
    let mut bytes =
        fs::read(path).with_context(|| format!("read transfer journal {}", path.display()))?;
    let complete_len = bytes.len() / JOURNAL_RECORD_LEN * JOURNAL_RECORD_LEN;
    if complete_len != bytes.len() {
        bytes.truncate(complete_len);
        fs::write(path, &bytes)
            .with_context(|| format!("truncate incomplete journal {}", path.display()))?;
    }
    let mut durable = BTreeSet::new();
    for record in bytes.as_chunks::<JOURNAL_RECORD_LEN>().0 {
        let prefix = &record[..JOURNAL_RECORD_LEN - 32];
        let tag = &record[JOURNAL_RECORD_LEN - 32..];
        if &prefix[..4] != JOURNAL_MAGIC
            || u16::from_be_bytes(prefix[4..6].try_into()?) != ATTACHMENT_PROTOCOL_VERSION
        {
            bail!("transfer journal has an unsupported record");
        }
        let expected = journal_tag(key, prefix)?;
        if expected.as_slice() != tag {
            bail!("transfer journal authentication failed");
        }
        durable.insert(u32::from_be_bytes(prefix[8..12].try_into()?));
    }
    Ok(durable)
}

fn journal_tag(key: &[u8; 32], record: &[u8]) -> Result<[u8; 32]> {
    let mut mac = <HmacSha256 as Mac>::new_from_slice(key)
        .map_err(|_| anyhow!("journal key must be 32 bytes"))?;
    mac.update(record);
    Ok(mac.finalize().into_bytes().into())
}

/// Long-lived partial-file writer. Blocks become resume-safe only after a
/// data flush followed by an authenticated journal append.
pub struct PartialTransfer {
    manifest: TransferManifest,
    key: [u8; 32],
    file: File,
    partial_path: PathBuf,
    journal: TransferJournal,
    pending: Vec<(u32, u32, [u8; 32])>,
    pending_bytes: u64,
    last_checkpoint: Instant,
}

impl PartialTransfer {
    pub fn open(
        manifest: TransferManifest,
        key: [u8; 32],
        partial_path: impl Into<PathBuf>,
        journal_path: impl Into<PathBuf>,
    ) -> Result<Self> {
        manifest.validate()?;
        let partial_path = partial_path.into();
        if let Some(parent) = partial_path.parent() {
            fs::create_dir_all(parent)?;
        }
        let file = OpenOptions::new()
            .create(true)
            .read(true)
            .write(true)
            .truncate(false)
            .open(&partial_path)
            .with_context(|| format!("open partial attachment {}", partial_path.display()))?;
        file.set_len(manifest.size_bytes)?;
        Ok(Self {
            manifest,
            key,
            file,
            partial_path,
            journal: TransferJournal::open(journal_path, key)?,
            pending: Vec::new(),
            pending_bytes: 0,
            last_checkpoint: Instant::now(),
        })
    }

    pub fn receive_encoded_block(&mut self, encoded: &[u8]) -> Result<u64> {
        let frame = AttachmentBlockFrame::decode(encoded)?;
        if self.journal.durable_blocks().contains(&frame.block_index) {
            return Ok(self.durable_bytes());
        }
        let plaintext = frame.decrypt(&self.manifest, &self.key)?;
        let offset = frame.block_index as u64 * self.manifest.block_size as u64;
        self.file.seek(SeekFrom::Start(offset))?;
        self.file.write_all(&plaintext)?;
        self.pending.push((
            frame.block_index,
            frame.plaintext_len,
            frame.plaintext_sha256,
        ));
        self.pending_bytes += plaintext.len() as u64;
        if self.pending_bytes >= JOURNAL_CHECKPOINT_BYTES
            || self.last_checkpoint.elapsed() >= JOURNAL_CHECKPOINT_INTERVAL
        {
            self.checkpoint()?;
        }
        Ok(self.received_bytes())
    }

    pub fn checkpoint(&mut self) -> Result<()> {
        if self.pending.is_empty() {
            return Ok(());
        }
        self.file.sync_data()?;
        for (index, length, digest) in self.pending.drain(..) {
            self.journal.append(index, length, digest)?;
        }
        self.pending_bytes = 0;
        self.last_checkpoint = Instant::now();
        Ok(())
    }

    pub fn durable_blocks(&self) -> &BTreeSet<u32> {
        self.journal.durable_blocks()
    }

    pub fn durable_bytes(&self) -> u64 {
        self.journal
            .durable_blocks()
            .iter()
            .map(|index| self.manifest.expected_plaintext_len(*index).unwrap_or(0) as u64)
            .sum()
    }

    pub fn received_bytes(&self) -> u64 {
        self.durable_bytes()
            + self
                .pending
                .iter()
                .map(|(_, length, _)| *length as u64)
                .sum::<u64>()
    }

    pub fn is_complete(&self) -> bool {
        self.journal.durable_blocks().len() == self.manifest.block_count as usize
            && self.pending.is_empty()
    }

    pub fn finalize(mut self, destination: impl AsRef<Path>) -> Result<PathBuf> {
        self.checkpoint()?;
        if !self.is_complete() {
            bail!("attachment is incomplete");
        }
        self.file.seek(SeekFrom::Start(0))?;
        let mut digest = Sha256::new();
        let mut buffer = vec![0_u8; 1024 * 1024];
        loop {
            let read = self.file.read(&mut buffer)?;
            if read == 0 {
                break;
            }
            digest.update(&buffer[..read]);
        }
        let actual: [u8; 32] = digest.finalize().into();
        if actual != self.manifest.whole_sha256 {
            bail!("whole-file integrity verification failed");
        }
        self.file.sync_all()?;
        drop(self.file);
        let destination = destination.as_ref();
        if let Some(parent) = destination.parent() {
            fs::create_dir_all(parent)?;
        }
        if destination.exists() {
            fs::remove_file(destination)?;
        }
        fs::rename(&self.partial_path, destination).with_context(|| {
            format!(
                "promote partial attachment {} to {}",
                self.partial_path.display(),
                destination.display()
            )
        })?;
        Ok(destination.to_path_buf())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn manifest(bytes: &[u8]) -> TransferManifest {
        TransferManifest {
            protocol_version: ATTACHMENT_PROTOCOL_VERSION,
            transfer_id: "att-v2-test".to_owned(),
            message_id: "msg-v2-test".to_owned(),
            album_id: None,
            presentation: AttachmentPresentation::File,
            file_name: "payload.bin".to_owned(),
            mime_type: "application/octet-stream".to_owned(),
            media_metadata: None,
            thumbnail: Vec::new(),
            size_bytes: bytes.len() as u64,
            block_size: ATTACHMENT_BLOCK_SIZE,
            block_count: (bytes.len() as u64).div_ceil(ATTACHMENT_BLOCK_SIZE as u64) as u32,
            whole_sha256: Sha256::digest(bytes).into(),
            nonce_prefix: [7; 16],
        }
    }

    fn temp_path(label: &str) -> PathBuf {
        std::env::temp_dir().join(format!(
            "conest_transfer_{label}_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ))
    }

    #[test]
    fn encrypted_frame_round_trips_and_rejects_tampering() {
        let bytes = vec![0x5a; ATTACHMENT_BLOCK_SIZE as usize];
        let manifest = manifest(&bytes);
        let key = [9_u8; 32];
        let frame = AttachmentBlockFrame::encrypt(&manifest, &key, 0, &bytes).unwrap();
        let encoded = frame.encode().unwrap();
        let decoded = AttachmentBlockFrame::decode(&encoded).unwrap();
        assert_eq!(decoded.decrypt(&manifest, &key).unwrap(), bytes);

        let mut tampered = encoded;
        *tampered.last_mut().unwrap() ^= 1;
        let decoded = AttachmentBlockFrame::decode(&tampered).unwrap();
        assert!(decoded.decrypt(&manifest, &key).is_err());
    }

    #[test]
    fn four_mib_direct_block_geometry_is_supported() {
        let bytes = vec![0x3c; ATTACHMENT_LAN_BLOCK_SIZE as usize + 17];
        let mut manifest = manifest(&bytes);
        manifest.block_size = ATTACHMENT_LAN_BLOCK_SIZE;
        manifest.block_count = bytes.len().div_ceil(ATTACHMENT_LAN_BLOCK_SIZE as usize) as u32;
        manifest.validate().unwrap();
        assert_eq!(
            manifest.expected_plaintext_len(0).unwrap(),
            ATTACHMENT_LAN_BLOCK_SIZE
        );
        assert_eq!(manifest.expected_plaintext_len(1).unwrap(), 17);
    }

    #[test]
    fn journal_discards_partial_tail_and_authenticates_records() {
        let path = temp_path("journal");
        let key = [3_u8; 32];
        let digest = [4_u8; 32];
        let mut journal = TransferJournal::open(&path, key).unwrap();
        journal.append(2, 128, digest).unwrap();
        OpenOptions::new()
            .append(true)
            .open(&path)
            .unwrap()
            .write_all(b"partial")
            .unwrap();
        let restored = TransferJournal::open(&path, key).unwrap();
        assert_eq!(restored.durable_blocks(), &BTreeSet::from([2]));
        assert_eq!(
            fs::metadata(&path).unwrap().len() as usize,
            JOURNAL_RECORD_LEN
        );
        let _ = fs::remove_file(path);
    }

    #[test]
    fn partial_transfer_resumes_and_promotes_only_after_hash_verification() {
        let bytes = (0..ATTACHMENT_BLOCK_SIZE as usize + 23)
            .map(|index| (index % 251) as u8)
            .collect::<Vec<_>>();
        let manifest = manifest(&bytes);
        let key = [11_u8; 32];
        let partial = temp_path("partial");
        let journal = temp_path("journal2");
        let destination = temp_path("complete");
        {
            let mut transfer =
                PartialTransfer::open(manifest.clone(), key, &partial, &journal).unwrap();
            let first = AttachmentBlockFrame::encrypt(
                &manifest,
                &key,
                0,
                &bytes[..ATTACHMENT_BLOCK_SIZE as usize],
            )
            .unwrap()
            .encode()
            .unwrap();
            transfer.receive_encoded_block(&first).unwrap();
            transfer.checkpoint().unwrap();
        }
        let mut transfer =
            PartialTransfer::open(manifest.clone(), key, &partial, &journal).unwrap();
        assert_eq!(transfer.durable_blocks(), &BTreeSet::from([0]));
        let second = AttachmentBlockFrame::encrypt(
            &manifest,
            &key,
            1,
            &bytes[ATTACHMENT_BLOCK_SIZE as usize..],
        )
        .unwrap()
        .encode()
        .unwrap();
        transfer.receive_encoded_block(&second).unwrap();
        let complete = transfer.finalize(&destination).unwrap();
        assert_eq!(fs::read(complete).unwrap(), bytes);
        let _ = fs::remove_file(journal);
        let _ = fs::remove_file(destination);
    }

    #[test]
    fn manifest_enforces_two_gibibyte_boundary() {
        let mut value = manifest(&[1]);
        value.size_bytes = MAX_ATTACHMENT_BYTES;
        value.block_count = (MAX_ATTACHMENT_BYTES / ATTACHMENT_BLOCK_SIZE as u64) as u32;
        assert!(value.validate().is_ok());
        value.size_bytes += 1;
        assert!(value.validate().is_err());
    }
}
