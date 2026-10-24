//! The relay's persistent Ed25519 identity.

use std::fs;

use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64_STANDARD;
use ed25519_dalek::{Signer, SigningKey};

use crate::config::RelayConfig;

#[derive(Clone)]
pub(crate) struct RelayIdentity {
    pub(crate) signing_key: SigningKey,
    pub(crate) public_key_b64: String,
}

impl std::fmt::Debug for RelayIdentity {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("RelayIdentity")
            .field("public_key_b64", &self.public_key_b64)
            .finish()
    }
}

impl RelayIdentity {
    pub(crate) fn from_seed_bytes(seed: [u8; 32]) -> Self {
        let signing_key = SigningKey::from_bytes(&seed);
        let public_key_b64 = BASE64_STANDARD.encode(signing_key.verifying_key().to_bytes());
        Self {
            signing_key,
            public_key_b64,
        }
    }

    /// Loads the relay's persistent Ed25519 identity. Resolution order:
    ///   1. `identity_seed_inline` (base64) — for stateless deployments
    ///      where the seed comes from a secrets manager.
    ///   2. `identity_seed_path` — read 32 raw bytes if the file exists.
    ///   3. Generate a fresh seed with `OsRng` and persist it to the path.
    ///
    /// On unix the freshly-written file is chmod'd 0600. Failures during
    /// the read/write are propagated so the operator notices instead of
    /// silently rotating the relay's identity.
    pub(crate) fn load_or_generate(config: &RelayConfig) -> Result<Self, String> {
        if let Some(inline) = &config.identity_seed_inline {
            let trimmed = inline.trim();
            if !trimmed.is_empty() {
                let bytes = BASE64_STANDARD.decode(trimmed).map_err(|error| {
                    format!("CONEST_RELAY_IDENTITY_SEED is not base64: {error}")
                })?;
                if bytes.len() != 32 {
                    return Err(format!(
                        "CONEST_RELAY_IDENTITY_SEED must decode to 32 bytes (got {})",
                        bytes.len()
                    ));
                }
                let mut seed = [0_u8; 32];
                seed.copy_from_slice(&bytes);
                return Ok(Self::from_seed_bytes(seed));
            }
        }
        let path = &config.identity_seed_path;
        if path.exists() {
            let bytes = fs::read(path)
                .map_err(|error| format!("reading identity seed at {}: {error}", path.display()))?;
            if bytes.len() != 32 {
                return Err(format!(
                    "identity seed at {} must be exactly 32 bytes (got {})",
                    path.display(),
                    bytes.len()
                ));
            }
            let mut seed = [0_u8; 32];
            seed.copy_from_slice(&bytes);
            return Ok(Self::from_seed_bytes(seed));
        }
        // Generate + persist a fresh seed.
        use rand::RngCore;
        let mut seed = [0_u8; 32];
        rand::rngs::OsRng.fill_bytes(&mut seed);
        if let Some(parent) = path.parent()
            && !parent.as_os_str().is_empty()
        {
            fs::create_dir_all(parent).map_err(|error| {
                format!(
                    "creating identity seed directory {}: {error}",
                    parent.display()
                )
            })?;
        }
        fs::write(path, seed)
            .map_err(|error| format!("writing identity seed to {}: {error}", path.display()))?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = fs::set_permissions(path, fs::Permissions::from_mode(0o600));
        }
        Ok(Self::from_seed_bytes(seed))
    }

    pub(crate) fn sign(&self, message: &[u8]) -> [u8; 64] {
        self.signing_key.sign(message).to_bytes()
    }
}
