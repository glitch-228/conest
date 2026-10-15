# M24b: Delta Chat, second half (files, voice, reactions, edits, deletions, member timestamps, avatars)

First read `/home/glitch/Documents/conest/PLAN_AGENTS.md` in full (the shared rules); everything there applies here.

- Worktree: `/home/glitch/Documents/conest/.worktrees/agent-m24b`
- Branch: `agent/m24b-delta-chat`
- Size: medium. Security-relevant (parsing hostile mail, authorship checks), so a reviewer pass is required.

## Background: what exists (the first half, shipped in the October 13 nightly)

Conest chats with Delta Chat users through the user's email account (for example a chatmail server):
- one to one and in groups;
- OpenPGP end-to-end encryption;
- Autocrypt and gossip;
- Securejoin, both classic and v3;
- read receipts.

Code:
- **`lib/src/email/`:**
  - `pgp.dart`, `pgp_aead.dart`, `openpgp.dart`: OpenPGP, Ed25519 + Cv25519, SEIPD v1/v2. Strictly bounded parsing with `PgpCheckBudget`. Keep those bounds.
  - `mime.dart`: MIME building and parsing.
  - `delta_mail.dart`: `DeltaMail` builds and reads Delta's mails (`DeltaIncoming`, `AutocryptHeader`); `maxBytes` = 2 MiB.
  - `imap.dart`, `smtp.dart`, `carrier_mail.dart` (`maxCarrierMailBytes` 2 MiB).
- **`lib/src/delta_protocol.dart`:**
  - `DeltaProtocol` handles incoming mail (`DeltaStep`), Securejoin and groups.
  - Groups use one `membersAt` timestamp for the whole member list: see around lines 511 and 613, and `copyWith(membersAt:)`.
  - Reactions are currently consumed and ignored: `if (read.reaction) return DeltaStep(next, consumed: true);`.
- **`lib/src/delta_chats.dart`:** the store, holding `DeltaPeer`, `DeltaChatMessage`, `DeltaChat`, `DeltaJoin` and `DeltaChats`, with per-chat caps.
- **`lib/src/ui/delta_chats_screen.dart`:** the chat list and chat UI. `lib/src/ui/network_chat_sources.dart` has `DeltaChatSource`.
- **`lib/src/messenger_controller.dart`:** the "Delta Chat chats over the email carrier's account" section, around line 4337 (`_deltaProtocol`, `_startDeltaChat`).
- **Tests:**
  - `test/delta_mail_test.dart` and `test/delta_protocol_test.dart`;
  - `test/support/fake_mail_server.dart` (IMAP and SMTP, multiple recipients, the chatmail filtermail Securejoin rule);
  - the controller test group 'Delta Chat'.

Today, files, voice messages and reactions from Delta Chat show as a short note, and such mail is left on the server.

## The reference: match Delta Chat exactly

Delta Chat's behaviour is defined by its core, chatmail/core on GitHub (formerly deltachat-core-rust): `src/headerdef.rs`, `src/mimefactory.rs`, `src/mimeparser.rs`, `src/receive_imf.rs`, `src/reaction.rs`, `src/chat.rs`, `src/message.rs`.

Before implementing each feature, read the relevant core code at its current main branch, and record the commit hash and the exact header names and semantics in your progress log. Where this plan and the core disagree, the core wins; note the difference.

Things to confirm there:
- **Pre/post messages** (`Chat-Post-Message-ID`, `Chat-Post-Message-Metadata`, `Chat-Is-Post-Message`): which headers are protected and which unprotected; the size threshold (believed to be about 140 kB); whether they apply to both directions.
- `Chat-Edit` and `Chat-Delete`.
- `Content-Disposition: reaction`.
- `Chat-Group-Member-Timestamps` and `Chat-Group-Past-Members`.
- `Chat-User-Avatar` and `Chat-Group-Avatar`.
- `Chat-Voice-Message` and `Chat-Duration`.
- `Chat-Content` (sticker, call and so on).

## Scope

**1. Files from Delta Chat**
- Attachments (images, files, audio, video, stickers) are saved into Conest's attachment storage and shown like Conest attachments, with open, save and forward.
- Find how Conest stores received attachments in the controller (the attachment cache; for example `_prepareOutboundAttachmentSource`, the inbound attachment state, the managed cache directory) and reuse it. Do not invent a second store.
- **Pre/post messages:** a pre-message makes a placeholder message ("Photo, 3.2 MB, downloading…"). When the post-message arrives, the file fills the placeholder in place.
  - A pre-message whose post never arrives expires: it shows "not received" after a bound, such as 7 days.
  - Post-messages without a pre-message also work.
- Mail with a file is consumed (deleted or moved, as text mail already is) only after the file is safely saved.
- Bound everything:
  - mail size (raise `DeltaMail.maxBytes` only as far as needed, with a separate, explicit cap for file mail, for example 25 MiB, enforced before download through the IMAP size);
  - attachment count per mail;
  - decoded size;
  - file names: strip paths and control characters, and limit the length;
  - never trust the declared MIME type for anything security-relevant.

**2. Files to Delta Chat**
- In a Delta chat (1:1 and group), the composer can attach files, photos and voice messages, through the same pickers as Conest chats.
- **Mail format:** multipart/mixed with a base64 file part, inside the encrypted payload, as Delta builds it. Use the pre/post split above the core's threshold.
- **Size:** about 21 MB at most, or the core's recommended limit if different. Above it, refuse with a clear message.
- **Metadata removal** applies (`removesFileMetadata`, `MediaSanitizer`), with the same consent flow as Conest files:
  - in the controller: `_withoutFileMetadata` and `FileMetadataException`;
  - in the UI: `confirmSendingMetadata` and `publishGroupFileAsking` in `lib/main.dart`.
- **Random file names** (`randomizesFileNames`, `_outgoingFileName`) apply. The sender's own copy shows the real name locally.

**3. Voice messages**
- Incoming `Chat-Voice-Message: 1` audio shows as a voice note with its duration, playable with Conest's voice note player. Find it in main.dart and `voice_message_service.dart`.
- Outgoing voice notes are sent as Delta expects, with the right MIME type and headers.

**4. Reactions**
- Shown on the target message (`In-Reply-To` plus `Content-Disposition: reaction`), with one reaction per sender, replaced or removed per the core's rules.
- Sent from the message menu: reuse Conest's reaction picker, if there is one in main.dart; otherwise a small emoji row.
- Accept a reaction only from a member of that chat, in groups as well.

**5. Edits and deletions**
- Apply `Chat-Edit` (new text) and `Chat-Delete` (remove for everyone) only when the request is signed by the same key as the original message's author. A different key, or an unsigned or unverified mail, is ignored.
- Send both from the message menu for your own messages.
- An edited message shows "edited".

**6. Group member timestamps**
- Replace the single `membersAt` with per-member timestamps, read and written as `Chat-Group-Member-Timestamps` and `Chat-Group-Past-Members`, merged per member by the senders' dates, as the core does.
- This fixes the earlier review item: a stale member list from one member could undo a newer change by another.
- Migrate stored chats: an existing `membersAt` becomes each current member's timestamp. New fields are optional, so old stores load.

**7. Avatars**
- `Chat-User-Avatar` and `Chat-Group-Avatar`: small images, bounded (for example 256 KiB encoded and 512×512 decoded), shown in the chat list and the chat header.
- Sending your own avatar is optional. Use the Conest profile picture if there is one.

**8. Group parity**
- Every item above works in Delta groups as well as 1:1: files, voice, reactions, edits, deletions and avatars.

## Tests

Each test needs a sabotage check.
- **Exact mails:** build each mail kind exactly as Delta's core would (headers copied from the core source) and check it is read correctly. Check that the mails Conest builds have the headers the core expects. Put the core commit hash in a comment.
- **Through `fake_mail_server.dart`:**
  - a photo round trip between two Conest instances acting as Delta peers, 1:1 and in a group;
  - a large file split into pre- and post-message, with the placeholder replaced in place;
  - a post-message that never arrives expires;
  - a post-message arriving first.
- **Reactions:** add, replace and remove; a reaction from a non-member is ignored.
- **Edit and delete:** by the author, applied; by another member, or by a forged From with a different key, ignored.
- **Member timestamps:**
  - Alice adds Carol at t2, and Bob's older list from t1 (without Carol) arrives later: Carol stays.
  - Past members are not re-added.
- **Avatars:** an oversized avatar is refused.
- **Files to Delta:**
  - metadata is removed;
  - a file whose metadata cannot be removed asks first;
  - random names are used when on.
- **Bounds:** too many attachments, an oversized decoded size, and a path in the file name are all handled safely.

## Out of scope

- Delta's webxdc apps: show "app (not supported)".
- Calls.
- Location streaming.
- Multi-device Delta accounts.

## Device checks to list

With the Delta Chat apps (Android, iOS, desktop), both ways, 1:1 and group:
- photos;
- a large video (pre/post);
- voice notes;
- reactions;
- edit and delete;
- adding and removing members while one side is offline;
- avatars.

## Progress log

- Started in assigned clean worktree at 3929653; main source checkout remains untouched. Read PLAN_AGENTS.md and RTK.md.
- Reference: chatmail/core main d766641ce27eb5ff52baa72bd5f87d0baf378a18. Read relevant portions of headerdef.rs, mimefactory.rs, mimeparser.rs, receive_imf.rs, reaction.rs, chat.rs, message.rs, constants.rs, download.rs and download/post_msg_metadata.rs before implementing. Public reference source saved in /tmp/conest-m24b-core.
- Exact formats: encrypted attachments use multipart/mixed and base64 parts. Encrypted files >140,000 bytes split in both directions. Protected Chat-Post-Message-ID references the post ID; protected Chat-Post-Message-Metadata is JSON {size,viewtype,filename,wh?,duration?}, with enum strings Image/File/Voice/etc. Chat-Is-Post-Message is an unprotected presence hint, never authority to replace content. Displayed identity is the post ID.
- Chat-Voice-Message: 1; Chat-Duration is milliseconds. Reactions use In-Reply-To and Content-Disposition: reaction on the text part. First ASCII-whitespace-delimited token under 30 UTF-8 bytes; one per sender, replaces, empty retracts.
- Protected Chat-Edit names the original ID; core prefixes edited text with ✏️ (strip on receive). Chat-Delete names whitespace-separated IDs. Conest enforces the exact original author fingerprint and a verified encrypted signature, stricter than core sender-ID checks where required by plan.
- Group headers: Chat-Group-Past-Members is an address list; Chat-Group-Member-Timestamps is epoch seconds for To followed by past addresses; Chat-Group-Member-Fpr uses the same order. Per-member max addition/removal clocks; addition >= removal permits rejoin. Omission is not removal. Explicit legacy removal bumps removal to >=addition+1 second.
- Protected Chat-User-Avatar and Chat-Group-Avatar use base64:<image> or 0. Core targets 512 pixels/60,000 bytes (256/20,000 on restrictive servers). Conest accepts <=256 KiB encoded and <=512x512 static images, checking actual dimensions before pixel allocation. Chat-Content: sticker marks stickers; call and webxdc are unsupported.
- Decisions: ordinary/carrier cap remains 2 MiB. Delta enabled only: 21 MiB decoded aggregate file cap, 30 MiB plaintext and 42 MiB wire cap (MIME base64 plus PGP armor requires about 1.88x), at most 20 files. Preserve key/signature/S2K budgets. Seven-day placeholder lifetime from local receipt, independent of sender Date. Reuse AttachmentDescriptor and content-addressed managed cache; flush private files before consuming mail.

- Implemented bounded Delta MIME file bodies, actual-content MIME detection, pre/post placeholders with post-ID identity, voice metadata, reactions, signed-author edits/deletions, per-member clocks, avatars and unsupported app/call notes. New controller part shares the managed cache, descriptor lookup, startup janitor, privacy sanitizer and voice service. Main.dart changes are small attachment-viewer and list-avatar hooks.
- Local focused validation: 66 Delta mail/protocol tests passed; five controller Delta tests through fake_mail_server passed (direct/group photo round trips, pre/post/expiry/post-first, >2 MiB mail download, restart cache retention, privacy consent/randomization); 11 email carrier tests passed, including IMAP size rejection before body fetch. Full suite, sabotage checks and reviewer pass pending.
- Fixed pre-existing Delta test clock dependence: keys and exact fixture signatures now use the fixed test clock instead of today's date. Old no-storage file regression now verifies mail is left and no unsaved file message is inserted.

- First implementation commit: 8af9268. Merged latest origin/feature/matrix-client (f3489bc) without conflicts. Independent read-only security reviewer is reviewing the frozen implementation. Full analysis and full Flutter suite started; CI verification now explicitly includes all Delta fixtures and fake-server tests.

- Security reviewer found and accepted fixes for: avatar IDAT inflation / nested WebP frames / cyclic JPEG-WebP EXIF; raw OpenPGP packet-count allocation; quadratic edit quote stripping; subsecond removal clocks; unsaved-mail cursor skipping; legacy member-history insertion bounds and explicit re-add; reordered authored deletion and pending reactions; voice startup disposal; delayed-pre caption rollback. Also addressing avatar timestamp replay and inherited empty group request/peer caps amplified by avatars. Regression additions are in progress.
- Storage retry now uses a typed recognized-mail signal and a retained durable UID, with 2-second to 5-minute backoff. Cache and vault failure recovery tests pass; tests pin actual file Message-IDs so pending handshake mail cannot skew UID assertions. Flush pending snapshot writes before applying Delta changes to keep the durable boundary isolated.
- First merged full Flutter run: 1014 passed, 18 skipped, one known local native-Iroh failure only. Final full rerun after review fixes and sabotage checks is still required. Analyze has zero errors and only the two inherited warnings (main.dart null-aware operator; voice_message_service.dart unnecessary !).

- Completed 34 sabotage checks: each intentional implementation break produced an assertion failure, then its source was restored. Covered cache saving/restart, attachment/decoded/wire bounds, safe names, placeholder completion/expiry, member-only reactions and exact-author controls, same-second removals, avatar dimensions/inflation/animation/cyclic EXIF/replay, PGP packet/chunk budgets, linear edits, early deletion/reaction, empty group caps, microphone startup disposal, metadata consent/random names, storage retry, removed-author controls, pending posts across membership changes, outgoing voice headers/M4A detection, omission/past-member clocks, legacy rejoin/history bounds, and delayed-pre preservation of edited-empty captions. Detailed local results: /tmp/conest-m24b-sabotage-results.json and /tmp/conest-m24b-sabotage-final-results.json.
- Final ordering refinements: exact original authors can edit/delete known messages after leaving; reactions and unknown pending controls still require current membership. An already authorized group file post can finish after author removal or local departure without changing membership/name/avatar. Direct/group outgoing voice fixtures verify protected millisecond headers and split Voice JSON. M4A voice uses actual MP4 brand detection. All 50 final content tests passed; full merged validation and debug CI follow.

- Final security follow-up also fixed pre-receive vault failures (typed UID retry), deletion before a chat exists (128 globally bounded author/chat/target-bound tombstones), fractional legacy membership removal, stale departure notices, and voice permission-error retry. Kept and request chats now share a 500-chat ceiling without evicting existing history; file/pre mail at the ceiling remains unconsumed and retryable. Unsupported mixed control/receipt/Securejoin/member-change mail containing a file remains intact on the server and does not stall the inbox.
- Closed inherited allocation paths amplified by larger file mail: one IMAP command shares its literal-byte budget, 16-literal and 1 MiB response-text caps; socket input is capped at 64 MiB and 4096 queued chunks, ignores empty chunks, and checks complete line length. Armor uses a bounded linear scanner and 64 KiB decoding batches (32 MiB decoded, 1,000,000 lines, 1024-byte lines, 64 armor headers). MIME caps fields/lines per entity and 1 MiB/4096 aggregate header bytes/fields. PGP packet cap is 4096 to retain the existing 3000-signature compatibility test; partial chunk and key/signature budgets remain bounded.
- Avatar decoder audit: PNG streaming preflight, JPEG metadata stripping, and static lossy WebP are supported. GIF, animated/alpha/lossless WebP avatars are refused before unsafe decoder entry. Ordinary file attachments retain these formats through the shared native viewer.
- Actual attachment widget coverage caught transport-metadata assumptions in the shared viewer. Delta now explicitly renders only a matching stored descriptor with managed cached bytes, bypassing transport chunk/key requirements. Added file actions that use the existing image/video/voice viewer and save/forward handlers. Widget regression opens a real cached photo, checks file and voice affordances and rejects unmanaged/mismatched descriptors. No native dialogs or system apps were opened by tests.
- All 61 sabotage checks caught behavior failures, with sources restored after each case (25 initial, 9 ordering, 27 final review). Final review set additionally covers every new parser budget, detached controls, capacity/mail preservation, mixed files, the real viewer mode and exact managed-descriptor binding. A first mutation that removed Dart type promotion was corrected before counting; an empty-chunk fixture was made explicitly undrained before counting. Results: /tmp/conest-m24b-sabotage-review-results.json.
- Focused tests before the last UI integration: 132 passed plus eight Delta fake-server/controller tests. Final mixed-file/parser set: 72 passed. Real cached attachment-viewer widget passed. Analyze: zero errors and only the inherited main.dart and voice_message_service.dart warnings; final merged full rerun and CI still pending. The previous full run reached 1040 passed/18 skipped, with only the known native-Iroh failure plus the now-fixed 3000-signature packet-cap compatibility failure.

## Handoff


- Branch and final commit:
- Debug run id and result:
- Delta core commit used as the reference:
- What changed:
- Draft release-note lines:
- Device checks:
- Review summary:
- Known gaps:
- Hooks added in lib/main.dart and lib/src/messenger_controller.dart:
