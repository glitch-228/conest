# Q4b: file privacy follow-ups

## Progress log

### Phase 0 — setup and inspection
- Read both supplied plans in full. Cloned the repository and created `agent/q4b-file-privacy` at `3929653e2eeb8941ca0939300d68b5330402c46a`.
- Agent instructions and formatting helper remain outside the repository in `../agent-files/`.
- Confirmed the existing sanitizer, original-source consent, group send path, and scheduled outbox behavior. Scheduled sources are currently staged without cleaning, and cleaned size/name decisions are deferred until dispatch.
- Installing Flutter 3.41.9 locally, matching CI. No GitHub CLI, pushes, tags, releases or release-note/version edits will be used.

### Phase 1 — cleaner and scheduling implementation checkpoint
- Added separate bounded Office ZIP/XML, PDF and ISO BMFF cleaners. JPEG thumbnail and PNG C2PA/trailing-byte fixes remain small changes in the existing sanitizer.
- `partial` is appended to the status enum. Direct/group sends and schedule-time callbacks use distinct consent wording. Scheduled copies retain their cleaned size and chosen name through an optional persisted flag; old vaults default to the old privacy path.
- Added crafted-fixture tests for each format and hostile limits, controller tests for direct/group partial consent and scheduled privacy, and widget/serialization tests.
- Added `xml: ^6.6.1` deliberately for bounded, namespace-aware XML handling; the only lock-file change promotes the existing exact version from transitive to direct.
- Flutter 3.41.9 / Dart 3.11.5 downloaded successfully. The VM aborts before running tools because the sandbox lacks process metadata (`Failed to retrieve stack bounds`; `/proc/self/exe` also unavailable). A request for broader execution was rejected because sandbox escalation is disabled. Flutter analyze/test/format and runtime sabotage checks remain blocked, not passed.
- An independent tree-sitter Dart syntax scan passed for the implementation and media fixtures. This is syntax-only, not Dart type analysis or tests.
- Picker platform source inspection and final hardening/review are still in progress.

### Phase 2 — hardening, picker and independent review
- Added Android's `android.provider.extra.SHOW_ADVANCED` hint to the plain SAF document picker via a small MainActivity hook and a separate helper. Added an Android instrumentation regression test without a new package. The pinned file_picker 11.0.2 Linux path is the XDG portal; Windows file picking uses GetOpenFileNameW (IFileDialog only for directories). Neither exposes a hidden-file API. Provider/desktop visibility remains a device check.
- Independent reviewer examined the source diff and the current hardening patches. Fixed: old PDF incremental metadata surviving; indirect stream types/filters and changed revisions; shared Info dictionaries corrupting fonts (including compressed references, comments, NUL separators, aliases and canonical numeric IDs); exponential reference traversal; repeated ISO sample rewrites and linear containment; HEIF duplicate/missing IDs, ambiguous sample tables and overflow; failed scheduled candidates retaining incomplete writes; Saved-message name parity; a JPEG fixture offset.
- Added regression fixtures for every confirmed finding. Compressed metadata remains partial; unknown/shared PDF structures request consent rather than being rewritten unsafely. Embedded ISO images in Office currently fail closed, never report clean.
- Kept cap fixtures independent of implementation constants so lifting a limit can actually break their tests. Added `tool/q4b_sabotage.py`: 29 mutation anchors validated with `--dry-run`; Python compilation passed. An attempted execution stopped at the healthy-suite precheck because Flutter cannot start, before making any mutation. No runtime sabotage outcome is claimed.
- Formatter/helper attempts also abort at Dart VM initialization. Hand-adjusted only new code and our small hooks; checked recommended braces and Dart syntax independently. `git diff --check` passes.
- Reviewer final result: no remaining confirmed blocker by source inspection; no definite Dart type/API error found. Runtime analysis/tests, sabotage proofs and platform builds remain unverified.

### Phase 3 — upstream merge
- Fetched origin and merged `origin/feature/matrix-client` (`f3489bc9020c46186946ef99e09766754c1bb198`). Resolved three overlapping insertion conflicts in the sanitizer and its two existing test files.
- Retained upstream's oversized-Office consent rule and oversized plain-ZIP regression test, implemented using the new bounded ZIP directory reader. Retained upstream route-trace tests alongside Q4b's test registrations. No upstream release notes or version were manually edited.
- Remaining checks: final syntax/whitespace/import verification, repeat analyze/full test attempts, clean bundle import verification and final handoff.

## Handoff

- Branch and final commit: `agent/q4b-file-privacy`; in progress.
- Base commit: `3929653e2eeb8941ca0939300d68b5330402c46a`.
- Debug run id and result: not run (no access).
- CI: not run (no access); please run Rust tests and debug.yml.
- What changed: in progress.
- Draft release-note lines: pending.
- Device checks: Samsung and Pixel media with exiftool; GoPro or DJI GPS videos; Word tracked changes; hidden-folder file picking on Android, Linux and Windows.
- Review summary: pending independent security review.
- Known gaps: pending.
- Hooks added in lib/main.dart and lib/src/messenger_controller.dart: pending.
- Local test and build results: pending Flutter installation.
- Blocked / decisions: Native/platform builds and physical-device checks depend on the available toolchain. For unsupported or ambiguous structures, choose failure/consent rather than silently claiming privacy.
