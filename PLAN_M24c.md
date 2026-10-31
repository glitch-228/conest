# M24c: Delta Chat review leftovers (downloads, speed, saves)

First read `/home/glitch/Documents/conest/PLAN_AGENTS.md` in full (the shared rules); everything there applies here.

- Worktree: `/home/glitch/Documents/conest/.worktrees/agent-m24c`
- Branch: `agent/m24c-delta-leftovers`
- Base: `617b826` on `feature/matrix-client`.
- Size: small to medium. Dart only. Code: the Delta Chat client: `lib/src/email/delta_*.dart`, `lib/src/ui/delta_chats_screen.dart`, `lib/src/ui/delta_*`, and its hooks in `messenger_controller.dart`.
- Other agents work in parallel elsewhere. Keep your hooks in `messenger_controller.dart` and `main.dart` small.

## Items (from the M24b independent review, 2026-10-16)

1. **(M2) Downloads follow the user's rules.** Delta Chat files are downloaded whatever the network. They should follow metered networks and the auto-download preset (Settings → Storage), as Conest's own files do:
   - files over the preset's size, or on a metered network, are deferred per message (per IMAP UID);
   - the bubble shows a Download action;
   - a deferred mail is not deleted from the server until it is downloaded.
2. **(M1) Off the UI thread.** MIME parsing and OpenPGP encryption and decryption of large mails run in an isolate (`compute`/`Isolate.run`), so the UI never stalls on a big mail.
3. **(M3) No quadratic saves; a real cache limit.** Saving Delta chats must not rewrite everything per message, and the attachment cache gets an LRU with a size cap.
4. **(M4) One vault write per fetch batch,** not one per mail.
5. **(M5) Cheap avatar checks at start:** no decoding or hashing of every avatar on each start; check by size and modification time, and decode lazily.
6. **The review's Low items** are not recorded. Re-read the Delta Chat input handling against the Security section of PLAN_AGENTS.md (bounds on sizes and counts, header parsing limits, authorship checks for edits and deletes) and fix what you find, each with a test.

## Tests

Each with a sabotage check:
- metered network: a large Delta file waits behind a Download action, and the mail stays on the server until fetched;
- a fetch batch of 20 mails writes the vault once;
- the cache stays under its cap and evicts the least recently used first;
- parsing a 20 MB mail does not run on the UI isolate (test the entry point used);
- avatar checks at start do not decode unchanged avatars.

The tests use the existing fake mail server (`test/support/fake_mail_server.dart`).

## Performance

These items are about stalls and battery. Name any remaining hot path in the handoff.

## Handoff

(Fill in: what is done, tests, sabotage checks, CI run id, release-note lines, device checks.)

## Progress log

- 2026-10-31: Read PLAN_AGENTS.md and the Delta mail/controller/cache paths. Starting from the named clean worktree at 617b826. Design: bounded IMAP batches with durable acknowledgement before deletion, UID-based deferred downloads, isolate mail jobs, incremental serialization/cache bookkeeping, and lazy avatar restoration.

- Implemented bounded 20-message/48 MiB fetch batches with one Delta vault save before server deletion; deferred UIDs survive restart and have a translated Download action. Existing cache/vault failure controller tests passed. New twenty-message save-count test passed.
- MIME/PGP build/read paths now use isolates, including receipts/Securejoin, and attachment SHA-256 uses an isolate. The 20 MiB encrypted file test passed (actual parser isolate identity differs from UI).
- Added a 256 MiB / 4,096-file metadata-based LRU, incremental cache references, descriptor lookup indexing, and reused immutable JSON rows.
- Avatar storage in this base is inline encrypted-vault data, not avatar files: there are no file modification times to check. Preserved the storage format, using encoded lengths and object identity without hashing/decoding, and validating only when an avatar is displayed. Existing avatar bounds tests passed. File-cache startup uses size/mtime only.
- Input review: reject duplicate identity/control headers, repeated Autocrypt attributes, oversized Autocrypt values, invalid MIME field names/boundaries, oversized invites and restored token collections. Keep the existing password-authenticated Securejoin-v3 format (which legitimately omits protected identity headers); ordinary signed chat mail must carry protected identity headers.
