//! Ed25519 for Dart, which signs and checks every group-call frame: the
//! pure-Dart implementation took about 3 ms each on a desktop and many times
//! that on phones, so a three-way call kept a phone's main isolate busy and
//! its call signals arrived too late to be taken.

use std::slice;

use ed25519_dalek::{Signature, Signer, SigningKey, VerifyingKey};

/// Larger messages are refused (frames and signals are a few KiB at most).
const MAXIMUM_MESSAGE_BYTES: usize = 1 << 20;

fn sign(seed: &[u8; 32], message: &[u8]) -> [u8; 64] {
    SigningKey::from_bytes(seed).sign(message).to_bytes()
}

fn verify(public_key: &[u8; 32], message: &[u8], signature: &[u8; 64]) -> bool {
    VerifyingKey::from_bytes(public_key)
        .and_then(|key| key.verify_strict(message, &Signature::from_bytes(signature)))
        .is_ok()
}

/// # Safety
/// `pointer` is null or readable for `length` bytes during the call.
unsafe fn bytes<'a>(pointer: *const u8, length: usize) -> Option<&'a [u8]> {
    if length > MAXIMUM_MESSAGE_BYTES || (pointer.is_null() && length != 0) {
        return None;
    }
    if length == 0 {
        return Some(&[]);
    }
    // SAFETY: the caller guarantees `length` readable bytes at `pointer`.
    Some(unsafe { slice::from_raw_parts(pointer, length) })
}

/// Signs `message` with the key whose 32-byte seed is at `seed`, writing 64
/// bytes to `signature`. False (nothing written) for invalid input.
///
/// # Safety
/// `seed` is readable for 32 bytes, `message` for `message_length` bytes and
/// `signature` writable for 64 bytes during the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn conest_ed25519_sign(
    seed: *const u8,
    message: *const u8,
    message_length: usize,
    signature: *mut u8,
) -> bool {
    if seed.is_null() || signature.is_null() {
        return false;
    }
    // SAFETY: see the function's contract.
    let (Some(seed), Some(message)) = (unsafe { bytes(seed, 32) }, unsafe {
        bytes(message, message_length)
    }) else {
        return false;
    };
    let Ok(seed) = <&[u8; 32]>::try_from(seed) else {
        return false;
    };
    let signed = sign(seed, message);
    // SAFETY: `signature` is writable for 64 bytes (the contract).
    unsafe { slice::from_raw_parts_mut(signature, 64) }.copy_from_slice(&signed);
    true
}

/// Whether `signature` (64 bytes) is `public_key`'s (32 bytes) over
/// `message`, by the strict rules (no malleable or small-order forms).
///
/// # Safety
/// `public_key` is readable for 32 bytes, `message` for `message_length`
/// bytes and `signature` for 64 bytes during the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn conest_ed25519_verify(
    public_key: *const u8,
    message: *const u8,
    message_length: usize,
    signature: *const u8,
) -> bool {
    if public_key.is_null() || signature.is_null() {
        return false;
    }
    // SAFETY: see the function's contract.
    let (Some(public_key), Some(message), Some(signature)) = (
        unsafe { bytes(public_key, 32) },
        unsafe { bytes(message, message_length) },
        unsafe { bytes(signature, 64) },
    ) else {
        return false;
    };
    let (Ok(public_key), Ok(signature)) = (
        <&[u8; 32]>::try_from(public_key),
        <&[u8; 64]>::try_from(signature),
    ) else {
        return false;
    };
    verify(public_key, message, signature)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hex(text: &str) -> Vec<u8> {
        (0..text.len())
            .step_by(2)
            .map(|at| u8::from_str_radix(&text[at..at + 2], 16).expect("hex"))
            .collect()
    }

    // RFC 8032, section 7.1, tests 1 and 2.
    const VECTORS: [(&str, &str, &str, &str); 2] = [
        (
            "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
            "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
            "",
            "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b",
        ),
        (
            "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb",
            "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c",
            "72",
            "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00",
        ),
    ];

    #[test]
    fn signs_and_checks_the_rfc_8032_vectors() {
        for (seed, public_key, message, expected) in VECTORS {
            let (seed, public_key, message, expected) =
                (hex(seed), hex(public_key), hex(message), hex(expected));
            let mut signature = [0_u8; 64];
            // SAFETY: every buffer is exactly the size the call reads/writes.
            let signed = unsafe {
                conest_ed25519_sign(
                    seed.as_ptr(),
                    message.as_ptr(),
                    message.len(),
                    signature.as_mut_ptr(),
                )
            };
            assert!(signed);
            assert_eq!(signature.to_vec(), expected);
            // SAFETY: as above.
            let valid = unsafe {
                conest_ed25519_verify(
                    public_key.as_ptr(),
                    message.as_ptr(),
                    message.len(),
                    signature.as_ptr(),
                )
            };
            assert!(valid);
        }
    }

    #[test]
    fn a_changed_message_or_signature_is_refused() {
        let (seed, public_key) = (hex(VECTORS[1].0), hex(VECTORS[1].1));
        let message = b"conest group call frame".to_vec();
        let mut signature = [0_u8; 64];
        // SAFETY: every buffer is exactly the size the call reads/writes.
        assert!(unsafe {
            conest_ed25519_sign(
                seed.as_ptr(),
                message.as_ptr(),
                message.len(),
                signature.as_mut_ptr(),
            )
        });
        let check = |message: &[u8], signature: &[u8; 64]| {
            // SAFETY: as above.
            unsafe {
                conest_ed25519_verify(
                    public_key.as_ptr(),
                    message.as_ptr(),
                    message.len(),
                    signature.as_ptr(),
                )
            }
        };
        assert!(check(&message, &signature));
        assert!(!check(b"conest group call frame!", &signature));
        let mut forged = signature;
        forged[10] ^= 1;
        assert!(!check(&message, &forged));
        // Null buffers are refused rather than read.
        // SAFETY: null pointers are checked before any read.
        assert!(!unsafe {
            conest_ed25519_verify(
                std::ptr::null(),
                message.as_ptr(),
                message.len(),
                signature.as_ptr(),
            )
        });
    }
}
