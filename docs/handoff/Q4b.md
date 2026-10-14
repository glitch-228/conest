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
- Post-merge syntax-only validation passed for all 16 changed Dart files and whitespace checks passed. Repeated analyze/full test attempts still fail at VM startup. Final bundle will be verified and test-imported from the original base before delivery.

## Handoff

- Branch and final commit: `agent/q4b-file-privacy`; final export ref is `refs/heads/agent/q4b-file-privacy` in `agent-q4b.bundle` (resolve with `git bundle list-heads agent-q4b.bundle`). Reviewed implementation/upstream-merge commit: `a4281c043385ea824a07709bdb08d4ad3b76cff0`; the following final commit records this handoff.
- Base commit: `3929653e2eeb8941ca0939300d68b5330402c46a`. Latest merged base: `f3489bc9020c46186946ef99e09766754c1bb198`.
- Debug run id and result: not run (no access).
- CI: not run (no access); please run Rust tests and debug.yml.
- What changed: In-place UUID/Samsung/timed-track removal with validated audio/video preservation; bounded Office author/date/comment XML and embedded JPEG/PNG/GIF/WebP cleanup; structural PDF Info/XMP/embedded-APP1 blanking and partial status for compressed/shared metadata; JFIF/JFXX thumbnails and PNG C2PA/trailing bytes removed; all sanitizeFile work runs in a worker isolate and never throws. Scheduling cleans and asks before confirmation, persists cleaned size/name choices, restores intact sources after failed I/O rewrites, and retains Saved-message behavior. Android plain file picking requests advanced storage roots.
- Draft release-note lines: Files you send remove more location, author and date details from videos and documents. If some details may remain, Conest asks before sending. Scheduled files are prepared when you schedule them, so sending later does not need another confirmation. Android's file picker asks to show more storage locations.
- Device checks: Samsung and Pixel photos/videos before/after with exiftool; GoPro/DJI GPS tracks; Word tracked changes and comments; Excel/PowerPoint comments; Office and ODF documents still opening normally; PDF text/fonts and embedded images; large-file UI responsiveness. Plain file picker: dot-folders and .nomedia folders on Android (including OEM DocumentsUI), Linux GTK/KDE portals and Windows. Android instrumentation picker tests and Android/Windows builds are unrun.
- Review summary: A separate reviewer examined `3929653...HEAD` and subsequent hardening patches. Confirmed privacy, corruption and complexity findings were fixed and regression fixtures added; final source review reported no remaining confirmed blocker or definite Dart type/API error. This is source inspection, not runtime validation or maintainer approval.
- Known gaps: Embedded HEIC/AVIF inside Office/ODF requests consent (`failed`) rather than being silently marked clean; it is not currently rewritten inside an archive. Fragmented/unindexed timed video metadata, unusual HEIF locations, encrypted/ambiguous PDFs, changed indirect stream parameters, unsupported object-stream filters, shared/aliased Info dictionaries, and over-cap/malformed files also ask conservatively. PDF object streams containing comments can request extra consent because shared references cannot be proved safe. ZIP64/multi-volume/encrypted archives and non-UTF-8 document XML are rejected conservatively. MKV/WebM remain unsupported as planned. Desktop hidden-file visibility cannot be forced through the pinned package's public API. Android's hint cannot force a document provider to expose dot-folders.
- Hooks added in lib/main.dart and lib/src/messenger_controller.dart: Shared partial consent dialog; partial exception flags and exhaustive status cases; schedule-time consent callback; optional scheduled privacy flag in feature_models; cleaned size/stored outgoing name; dispatch skips repeated cleaning/renaming for prepared entries. Group cleaning/scheduling does not depend on group members being direct contacts. No new wire format or ApplicationCapability is needed; ordinary attachment payloads, hashes and signatures use the existing protocol.
- Local test and build results: Flutter 3.41.9 / Dart 3.11.5 installed. Both initial and post-merge `flutter analyze` and full `flutter test` abort before execution (exit 255; empty resolved_executable_name/missing process metadata); direct Dart formatting also aborts with failed stack bounds. Thus analyzer, full/focused tests, Dart format/fmt_mine and runtime sabotage proofs have NOT passed or run successfully. No test failure is being attributed to the known native-Iroh exception. Independent tree-sitter syntax parsing passed for all 16 changed Dart files; `git diff --check` passed against the latest base. Python sabotage runner compilation and 29-anchor dry-run passed; its attempted runtime run was blocked at the healthy baseline and changed no source. No Rust crate was modified, so Rust local test/clippy runs are not applicable. Android, Linux and Windows application builds are unbuilt; Android test instrumentation requires a device.
- Blocked / decisions: Runtime/tool execution is the main blocker. Automatic approval review rejected broader Flutter execution because sandbox escalation is disabled; no bypass was attempted. Maintainer should run analyze, the full suite (ignoring only the documented native-Iroh test when applicable), formatting of our code and `python3 tool/q4b_sabotage.py --flutter /path/to/flutter` before approval. Larger format-specific rewrite limits and ambiguous structures intentionally require consent. User privacy/name choices are frozen at scheduling; old entries lacking the optional flag still use the normal privacy path. Added only the intentional direct XML dependency and its existing lock classification. No pushes, GitHub CLI, tags, releases or manual release/version edits occurred.

## Verification commands for the maintainer

```bash
git bundle verify /path/to/agent-q4b.bundle
git fetch /path/to/agent-q4b.bundle refs/heads/agent/q4b-file-privacy:refs/heads/agent/q4b-file-privacy
git switch agent/q4b-file-privacy
flutter analyze
flutter test
python3 tool/q4b_sabotage.py --flutter /path/to/flutter
```

Use Flutter 3.41.9. Each sabotage case first requires a passing focused baseline, deliberately disables a behavior, requires an assertion/timeout regression failure (compiler/startup errors do not count), restores every file byte-for-byte, and rechecks the baseline. The 29 primary mutations cover format cleanup, caps, shared resources, consent and scheduled dispatch; additional hostile-format and compatibility fixtures run in the baseline. Runtime proofs remain pending in this environment.

## Picker source references

- Pinned source: https://pub.dev/api/archives/file_picker-11.0.2.tar.gz (`FileUtils.kt`, `file_picker_linux.dart`, `file_picker_windows.dart`). Android FileType.any uses ACTION_OPEN_DOCUMENT. The gallery's filtering remains untouched.
- Portal API: https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.FileChooser.html — no standardized show-hidden option in the published OpenFile options.
- Windows native flag: https://learn.microsoft.com/en-us/windows/win32/api/commdlg/ns-commdlg-openfilenamew — OFN_FORCESHOWHIDDEN exists, but the package neither exposes nor sets it. A replacement picker or package fork was not introduced.
- Samsung trailer layout checked against https://github.com/exiftool/exiftool/blob/master/lib/Image/ExifTool/Samsung.pm (`ProcessSamsungTrailer`). Offsets, counts and referenced ranges are independently bounded.
