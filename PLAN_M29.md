
## Review round 2 (Opus, 2026-11-05, head efb6770): fix before merge

The previous findings are confirmed fixed: H-B, H-C, H-D, MEDIUM 1, 2, 4 and 5, and the leave re-read. H-A and MEDIUM 3 are partial; their remaining parts are listed below.

Abbreviations: gac = `group_accounts_controller.dart`, mc = `messenger_controller.dart`, gmh = `group_membership_history.dart`, coord = `group_history_coordinator.dart`, sync = `group_history_sync.dart`.

### HIGH (must fix)

**H1. The deputy's revocation record has no designated signer, so two devices can fork the group for good.**
- **Where:** `_runDeputy` (gac ~1148–1235). `_selfRevocation` (gmh ~718) accepts any projected, non-revoked device of the account.
- **How it breaks:** two siblings (or the deputies of two accounts, or a deputy and the returning owner) both sign v+1 on parent v. The DAG then has two heads, and nothing ever resolves them:
  - `prepareMembership` throws on `hasConflict` for everyone (coord ~364);
  - `current` is null, so `canReceive` is false;
  - the group freezes.
- **Fix:**
  - **One deterministic signer:** the smallest projected, non-revoked device id of that account. Enforce it in `_runDeputy` and as a validator rule in `_selfRevocation`.
  - **Re-read just before signing:** `currentMembership` is re-read right before the deputy signs.
  - **Owner merge:** the owner's `prepareMembership` signs a multi-parent merge record on a conflict, instead of throwing. Check the old-validator invariant for a multi-parent record. If an old app would refuse it, say so and propose an alternative.
- **Test:** two siblings' deputies racing, and a deputy racing the owner. Both converge to one head.

**H2. The local send rule cuts members off permanently.**
- **Where:** `admittedByRevokedAuthors` (gmh ~259–299), used at mc ~29866. A device first admitted by a device that is revoked much later never again gets live messages, and the sender's state stays pending forever. The test at group_accounts_test.dart ~1127 asserts this behaviour; change it.
- **Fix:**
  - count only records the revoked author signed **after** its cutoff or checkpoint;
  - stop counting a device once an owner-signed record after the revocation pin still lists it.
  - If that can't be made precise, drop the rule.
- **Test:** an admin adds Bob; much later the admin's phone is revoked; Bob still receives live messages.

**H3. A device-only member's leave in a group with accounts is still stored before it is signed.**
- **Where:** mc ~26700–26730. `membershipVersion = max(current+1, payload)` is upserted, and the signing refusal is swallowed (mc ~18744). This brings back the H-A freeze; a crafted version or two leaves arriving out of order trigger it.
- **Fix:**
  - in accounts mode, ignore the payload's version;
  - the owner writes the leave from `signedView` at head+1 through `_commitGroupChange`;
  - non-owners wait for the owner's record, as `_accountLeft` already does.
- **Test:** two leaves arrive out of order, and a crafted high version. The owner keeps signing afterwards.

### MEDIUM (fix; small)

- **M1.** `_claimedDevices` (gac ~1646) compares against other accounts' view lists. A hostile account that lists A's device id blocks every owner re-pin of A, including revocation pins. Compare against the DAG-pinned lists and projections, as R6 does, and skip the later claimant.
- **M2.** The fold loop changes `_pendingUpgrades[groupId]` while iterating it (gac ~1407/1436), which aborts the writer. Iterate over `.entries.toList()`.
- **M3.** `beforeAppend` saves the whole vault before every membership record in every group (sync ~178, mc ~2844). Save only when the record pins a list digest that is not saved yet.
- **M4.** Edit and delete rights use the current head's account ids (coord ~698/1022), so after an account leaves, its earlier deletions come undone. Use the account ids from the record the mutation references, or the union over the ancestry.

### LOW (fix if cheap; otherwise list under Not done)

- `_commitGroupChange` accepts someone else's proof at the same version as success (coord ~370). Check that the proof matches the candidate.
- `_replaySiblingParked` should re-run once if new envelopes became due during a run.
- `_rebuildDeviceListViews` takes the oldest 512 digests, and verification marks are not kept. Prefer the digests the head pins.
- `_accountLeft`:
  - non-projected siblings keep the group active;
  - a sibling of the owner's account cannot leave;
  - it awaits sends on the inbound path (pitfall 1), so use `unawaited`.
- The no-op owner record repeats while `needsPin` stays true for a revocation found only in a lower-version list.
- `_siblingAnnounces`: 64 slots can be filled by one hostile account. Cap the slots per account.

### Rules for this round

- One fix round.
- Each fix gets a test with a sabotage check.
- Then the full suite (`timeout 90m flock ~/conest-lab/flutter-test.lock`, a unique log, then `cp ~/conest-lab/pubspec.lock.mine pubspec.lock`), analyze at no new issues, push, and `debug.yml`.
- Update the Handoff.

## Handoff, review round 2 (2026-11-06, base efb6770)

Branch `agent/m29-groups-by-account`. Commits since efb6770 (all end with the Co-Authored-By line):
- f4b63f3 H1 (designated signer, owner merge of a fork, admission fix, same-version proof check)
- f27317e H2 (local send rule), and the merge leaves out branches signed by a revoked device
- 6a6869d H3 (leave in a group with accounts)
- ce52af2 M1 and M2
- c41799c M3
- 6f21113 M4
- cc30236 LOWs (replay second pass, announce slots)
- 9045a1e analyzer: two unused test imports

Every finding was checked against the code first; all of H1, H2, H3, M1-M4 were real. Reproduced before fixing: H1 (the fork), H3 (stored version 92 after a crafted leave), M1 (the phone was never dropped from the projection), M2 (ConcurrentModificationError), M4 (a later reader sees the deleted message again). H2 and M3 were confirmed by reading the code; H2's test was written against the new behaviour and its three sabotage checks fail the right tests.

### Per finding

**H1 fixed.**
- Validator (`group_membership_history.dart`): `_selfRevocation` accepts only the smallest projected device of the account that is neither revoked nor the owner device (`_designatedSigner`). The owner device is left out because it writes as the owner; this keeps the deputy useful when the owner's app is away.
- Deputy (`_runDeputy`): signs only when it is that device, and reads the head again (`currentMembership`) right before signing; a stale version stops it.
- Owner merge: `GroupMembershipHistory.mergedHeads()` builds the merged group (base = head with the highest version; every removal, revoked or dropped device and removed account of any branch stays out; every account at its newest pinned list; projected devices the list or the revocations no longer allow are dropped; branches signed by a device any branch shows revoked are left out; additions that only a losing branch made are not merged, whoever added them can repeat it). `forNextRecord`, `nextAdmission`, `nextVersion` give the admission boundaries a record with all heads as parents must carry. `GroupHistoryCoordinator.prepareMembership` signs that multi-parent record when the owner calls it on a fork (non-owners still get the error). The owner's writer (`_runOwnerWriter` -> `_mergeFork`) merges first and then continues its normal run; the fork is noticed after an import in `_handleGroupMembership` and in `_adoptMembershipHead` (two small hooks, 4 lines in messenger_controller.dart).
- Old-validator invariant: a multi-parent owner-signed record is an existing rule of the pre-accounts validator (owner shortcut and `_resolutionAuthority`), and the admissions follow its rule (kept when all parents agree). Proved by a fork of two old-style admin records that the owner merges, accepted by the frozen validator in `test/support/legacy_group_membership_history.dart`. The deputy's self-revocation record itself is rejected by old validators (an admin removing an admin), which is why it is only ever written when every member knows accounts; nothing changed there.
- Found while testing: `_selfRevocation` and `_ownerHandoff` compared the raw `admission` field, so a deputy or handoff record right after the record that admitted the account (or any other account) was refused. They now compare against the authority's resolved admission (`_sameEntry(authority, ...)`).
- LOW from the list, done here: `prepareMembership` no longer returns another record's proof when it has the candidate's version but different members (accounts mode only; `_sameMembership`).
- Tests: `test/group_accounts_review2_test.dart` (designated signer, admission cases, merge of two accounts' deputies, merge with a removal and the frozen old validator, thief branch not merged); controller test "a sibling and the owner write at once" (alice and the laptop both sign on one parent with the network between them cut, then the owner merges and the group works); controller test for the same-version refusal.
- Sabotage checks (break, see fail, restore): designated rule removed; own-entry admission compare reverted; other-accounts compare reverted; removal drop removed; newest-list choice removed; taint filter removed; merge call in the writer disabled; same-version check disabled.
- Not covered by a test: the deputy's own "am I the designated device" return (the validator rule is tested; a wrong deputy is refused anyway and nothing is stored) and the re-read before signing (the coordinator's version check also catches a stale candidate).

**H2 fixed.** `admittedByRevokedAuthors` counts a device only when the admitting record was signed after its author's cutoff (the earliest checkpoint of a record that pins the revocation or follows it, else the cutoff a sibling signed; no cutoff known yet still counts) and no owner-signed record after the revocation pin still lists the device (`_signedBeforeCutoff`, `_answeredByOwner`). Tests in review2: cutoff past the record releases the device; a cutoff below it does not; the owner's record answers; the old test in group_accounts_test.dart (revoked, no cutoff, still counted) stays valid. Sabotage: each of the three conditions removed.

**H3 fixed.** In a group with account members, `_handleGroupLeave` hands every leave to `_memberLeft` (gac): the owner's app writes it from `signedView` at head + 1 through `_commitGroupChange` (never the leaver's number), non-owners wait for the record. Two leaves in a row: `_commitFromHead` starts again from the new head (up to 4 tries). Tests: crafted version 90 ahead leaves the owner at head + 1 and signing afterwards works; carol and the phone leave together and both are recorded. Sabotage: old condition restored (stored version 92); retries cut to 1.

**M1 fixed.** `_claimedDevices` reads only the lists the signed record pins for other accounts (plus device-only members, the owner, removed ids); the unused `view` parameter is gone. Test: carol's account publishes a list naming Bob's laptop id, Bob revokes the phone, the owner's record still lands. Sabotage: view lists restored.

**M2 fixed.** The fold loop iterates `.entries.toList()`. Test: a pending upgrade whose list names the owner's device id is dropped and the writer completes. Sabotage: the copy removed (ConcurrentModificationError).

**M3 fixed.** `PinnedListStore` notes which lists the last vault save held (`markSaved`, all of them after a load); `GroupHistoryReplica.importMembership` calls `beforeAppend` only when the record pins a list not saved yet; `_savePinnedListsNow` marks the lists saved after the save. Test (restore file): saves counted over five records (0, 1, 1, 1, then 2 after a new list). Sabotage: always save.

**M4 fixed.** `GroupMessageProjection.reduce` takes `accountIdsAt` (judge each mutation by the accounts of the record it names, `GroupMembershipHistory.accountIdsAt`); the coordinator's three reduce sites use it through `_reduce`, and `_mutationsFor` also fetches all authors' mutations when the original's author was an account at the original's record. A device-only newcomer that merely names itself by that account id gets nothing (its mutation names a record without the account). Tests: unit (review2) and a controller test where Dave joins after Bob's account left and must not see the sibling-deleted message. Sabotage: reduce on the head's accounts; `_mutationsFor` on the head only.

### LOWs
Done: same-version proof (see H1); `_replaySiblingParked` runs once more at its end (test, sabotage); `_accountLeft` now also tells the siblings the record does not project and runs off the inbound path (`unawaited`, in `_memberLeft`); announced profiles must carry the sender's own account id and one account takes at most 16 announce slots (test with two sabotage checks).

### Not done
- `_rebuildDeviceListViews` still takes the oldest 512 digests and verification marks are not kept across restarts (needs a hook with 500+ lists to test; the cost is bounded).
- The no-op owner record that repeats while `needsPin` stays true for a revocation found only in a lower-version list (rate limited to one per window; the semantics of such a list need a decision).
- A sibling of the owner's account cannot leave.
- A fork whose heads disagree on the owner (an ownership handoff concurrent with another record) is not merged (`mergedHeads` returns null; the group stays frozen until someone resolves it by hand). Needs a design note if it matters.
- The owner's own account is never folded by the app (no controller path for the owner's upgrade; the validator allows it). Found while writing a test for the owner linking a phone; unrelated to this round, noted so it is not forgotten.

### Pitfalls checked for this round
1 leaves and the merge run off the inbound path (`unawaited` in `_memberLeft`, the writer timer for the merge). 3 no new timers (the merge uses the owner's debounced writer; the leave retry waits at most 20+40+60 ms). 6 no new state outside the list store's `_saved` set (cleared and evicted with the lists). 9 ownership/authorization first: only the owner merges and writes leaves; the deputy checks the designated signer before signing. 12 bounded: announce slots per account, leave retries 4, merge reads only the heads. 14 deputy and merge stay gated by every member knowing accounts; old members see an ordinary owner-signed multi-parent record. 17 the leave retry has an attempt cap. 18 nothing migrated; the new `_saved` set is not persisted. 20 new fixtures use `fixtureEpoch`. The others do not apply.

### Performance risk
`GroupHistoryReplica.membership` returns `_membership.fork()` on every access (copies the record, facts and group maps). Existing, but `hasConflict`, `mergeCandidate`, `membersOfHeads` and `_reduce` each add one access; `_reduce` is once per projected message. A cheap read-only accessor would remove the copies; not changed in this round.

### Lab check needed
Two phones as one account plus the owner: revoke a device on one phone while the owner's app is online and the other phone is the deputy (a fork is possible when the two cannot reach each other); watch that the group freezes for at most the owner's writer delay and then works. A device-only member leaving a group with accounts over relay-only Wi-Fi.

### Release-note lines (draft, plain text)
Groups with several-device members recover by themselves when two devices change the group at the same moment: the owner's app settles it. A device-only member leaving such a group is now recorded the same way as everyone else, and a message deleted from any of a member's devices stays deleted after that member leaves.

## Progress log, round 2
- 2026-11-06: read the rules and the review. Tests first, one finding at a time, each with a sabotage check (listed above). Found on the way: raw admission compare in the validator (fixed with H1); `parents.first` on an empty list in the first draft of `prepareMembership` (caught by the existing controller tests).
- 2026-11-06: analyzer back to the base's 28 issues. Full suite and debug run: see below.
