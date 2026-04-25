# Conest v0.1.0

First v0.1 release candidate notes for the LAN-first secure text prototype.

## Highlights
- One-device identity with encrypted local vault storage.
- QR, payload, and codephrase contact pairing.
- 1:1 encrypted text messaging with LAN-first delivery, relay fallback, pending retry, acknowledgements, edits, deletes, and read receipts.
- LAN lobby chat for untrusted local-network conversation without adding contacts.
- Standalone TCP/UDP/HTTP relay package with queue caps, TTL cleanup, pairing announcement reuse, and basic rate limits.
- Cross-platform update flow gated by signed release manifests.

## Security Boundary
- Conest v0.1.0 encrypts local storage and message envelopes, but it is still a prototype security model.
- This is not an audited production messenger and does not yet implement X3DH plus Double Ratchet.
- Relays store encrypted envelopes only, but relay abuse controls, signed default relay lists, federation, key rotation, and broader cryptographic hardening remain future v0.1.x/v0.3 work.

## Release Gate
- Stable assets must be release-mode only.
- Android stable APKs must be signed with a real release certificate, not the Android debug certificate.
- Update assets must include `RELEASE-MANIFEST.json`, `RELEASE-MANIFEST.ed25519.sig`, and `SHA256SUMS.txt`.
- Windows stable artifacts must be produced on a Windows runner before publishing the non-prerelease GitHub release.
