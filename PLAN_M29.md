
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
- 2026-11-06: analyzer back to the base's 28 issues. Full suite: 2315 passed, 24 skipped, 2 failed: the known Iroh test and "relay blobs ... a tampered blob is refused" (a 1:1 file-transfer test that passes alone, a timing flake under the parallel load of other agents' suites). Debug run 42228020317 on b6d1166: green (all 13 jobs).

## Review round 3 (Opus check of f4b63f3, f27317e, 6a6869d; 2026-11-07): fix first

**Confirmed fixed:**
- H3.
- H1 for the reported races. A fork whose heads disagree on the owner still freezes; it is listed as Not done and is no worse than before.
- The merge record is accepted by the frozen old validator.

### HIGH (must fix)

**R3-H1. The H2 rule is defeated.**

How it fails:
- `_answeredByOwner` (gmh ~567–584) counts the owner's own revocation pin as an answer. The owner's writer re-pin loop (gac ~1540–1640) keeps devices that the revoked admin admitted. So the automatic pin releases them, with no one having decided anything.
- The DAG cutoff is the signer's journal head for that author (coord ~413–419). It covers every record the thief made before the pin, and it wins over an earlier cutoff signed by a sibling (gmh ~540–557).
- Sequence numbers alone are compared (gmh ~560), so the thief can backdate a record. `_onChain` / `chainAdmits` (gmh ~1614–1627) exist for exactly this case.
- The merge taint filter checks only the head record's author (gmh ~368–374). An honest record built on top of the thief's record makes the branch look trusted.

Fix:
- When the owner's writer pins a revocation, it drops every device that a revoked author admitted after that author's cutoff.
- Only owner records strictly after the pin count as an answer.
- The cutoff is the minimum of the DAG cutoff and the sibling-signed cutoff, checked with `_onChain` (no sequence-only comparison).
- The taint check covers every record on the branch since the fork point.

Tests, each with a sabotage check:
- a stolen admin phone admits a thief device and is then revoked;
- the owner's automatic pin drops the thief device, and live sends stop;
- a backdated record is refused;
- an honest record on top of a thief record does not make the branch trusted.

**R3-H2. A revoked, stolen device can fork the group without limit.**

How it fails:
- `_isRevokedAuthor` looks only at the incoming record's own ancestry (gmh ~684–689), so a revoked device keeps signing on parents from before the pin.
- Each such record forces an owner merge, which bypasses the per-record rate limit (`_mergeFork` at gac ~1449 runs before the limit at ~1657).
- With 17 or more heads, a merge record cannot be built (the 16-parent cap, gmh ~142), so the group freezes for good.

Fix:
- A head whose author is revoked in the current view or the DAG (as the merged revocations show) does not count as a head: it is not merged, only kept.
- At most 16 heads are merged per record.
- Merges are rate-limited like other owner records, and the first one may run at once.

Test: a revoked device publishes 20 records on old parents. The group keeps one effective head and keeps working, and the owner's merge work stays bounded. Sabotage-check it.

### MEDIUM (fix, small)

- **The merge silently drops the losing branch's changes.**
  - Additions, role changes, title and visibility made on the losing branch are lost. When versions are equal, the base is just the first head in sorted order (gmh ~378–383).
  - `removed` is a union over branches (gmh ~388), so a device re-added on the winning branch after the fork is dropped again.
  - Fix: merge by field, keeping additions and role changes from every trusted branch unless another trusted branch removed that member after the fork. Take title and visibility from the head with the latest lamport.
  - If this can't be done cleanly, the owner's app re-applies the losing branch's own changes in its next record and logs what it did.
- **A leave that arrives during a fork is dropped.** Build the leave at `nextVersion` when a fork is present, or queue it until the merge is done.

### LOW

The designated deputy may be offline for a long time. Note it in the Handoff; a fallback to the next device after N hours is optional.

### Rules for this round

Same as round 2:
- one fix round;
- tests first, and a sabotage check for each fix;
- the full suite, analyze, push and `debug.yml`;
- update the Handoff.

## Handoff, review round 3 (2026-11-07, base b6d1166)

Commit 7f01dd0 (one commit: the pieces share the history changes). Every finding was checked against the code first; all were real.

**R3-H1 fixed.**
- The owner's record for a revocation takes out the devices a revoked author admitted after its cutoff (`_runOwnerWriter`, from `devicesAdmittedByRevoked`). A device-only member leaves; an account leaves whole (entry and devices); devices of an account that stays are projected again by the writer's own loop when the account's list says so (then under the owner's record). Decision for review: with no cutoff known at all, the devices count as admitted after it (fail closed), so a legitimately admitted member of that admin goes too and the owner adds them again. The owner's own journal head in its pin is not a cutoff for this purpose, because it covers the thief's records the owner already holds.
- `_answeredByOwner`: only an owner record strictly after a record that pins the revocation (first pin on its branch) counts. The pin itself does not.
- `_signedBeforeCutoff` (now async, so `admittedByRevokedAuthors` returns a Future): the cutoff is the earlier of the DAG checkpoint and the sibling-signed one, and the record must pass `_onChain` (the chain walked from the cutoff event), never a sequence compare. With no chain oracle or no cutoff the device waits.
- Taint covers the branch: a head is untrusted when any record since the fork point (ancestors of the head that are not ancestors of every head) is signed by a revoked or compromised author, by the union of the DAG facts of all heads or the local view.
- Tests (group_accounts_review2_test.dart, H2 group): cutoff releases, cutoff below the record does not, a record off the author's chain (backdated) does not, the earlier cutoff wins over the owner's checkpoint, the owner's own pin is no answer while a later owner record is; controller test "a stolen admin phone admits a thief device and is revoked" (the owner's record for the revocation takes the thief device out; the laptop's cutoff is below the add). Sabotage: taint on the head only, sequence-only compare, the DAG cutoff winning, the pin answering, the drop in the writer disabled; each fails its test.
- "Live sends stop": the H2 rule (no new message to such a device) is unchanged and tested; the new part is that the owner's record removes the device, so sends stop for good.

**R3-H2 fixed.** `GroupMembershipHistory.heads/current/hasConflict` work on effective heads: a head whose branch holds a record of a revoked device (union of the DAG facts, or the local view) is kept but does not count, so one effective head is `current` and the group keeps working. `heads` is capped at 16 (newest first) for a merge record; the members of a merge record are capped at 16 (later additions wait). Merges are rate limited (`_mergeDue`, per group, the owner's record window; the first runs at once; the map is bounded and cleared on dispose). Tests: twenty records of a revoked device on old parents leave one effective head and the owner's next record is taken; an honest record on top of a thief record does not count; a revoked device seen only in the view counts the same and stops counting when the view changes; 17 effective heads merge in two records; the member cap; the rate limit (controller test). Sabotage: taint off, cap raised, member cap removed, rate limit removed. Behaviour change worth knowing: the old test "a thief owner revoked in the ancestry" now sees no fork (the thief's branch is no head); its resolution is still refused (N1).

**MEDIUM merge by field fixed.** `mergedHeads` merges against the common ancestor: members and roles added or changed on any branch are kept unless another branch removed the member; `removedDeviceIds` follows what each branch changed since the base (a member removed before the fork and added on one branch stays); account entries merge role (a changed role from the latest head), newest list, union of approved and excluded; title and the history setting (`mergedVisibility`) come from the latest head by lamport that changed them. A projected device has its account's role. Tests: the combined merge (additions, role change, title, removal) and the re-added member; both with the frozen old-validator pair kept from round 2. Sabotage: re-add rule, role pick, title pick.

**MEDIUM leave during a fork fixed.** `_commitFromHead` (the leave writer) merges a fork first, then builds the leave from the new head. Controller test: carol leaves in the middle of a fork, version base + 3 (merge, leave), no fork left. Sabotage: the merge before the leave removed.

**LOW.** The designated deputy (smallest projected, non-revoked, non-owner device of the account) may be offline for a long time; then the pin waits for the owner's app. A fallback to the next device after N hours is not done: the validator would have to name a time-dependent signer, which it cannot know, so it needs a design note (for example a second signer allowed after a signed delay record).

### Not done (all rounds)
- `_rebuildDeviceListViews` digests and verification marks; the repeating no-op owner record; a sibling of the owner's account cannot leave; a fork whose heads disagree on the owner (not merged); the owner's own account is never folded by the app; the fallback signer above.
- A fork whose effective heads are all tainted stays a fork (all heads kept) and is not merged.

### Pitfalls (round 3)
1 the merge and the drop run in the owner's writer, not on the inbound path; the leave writer runs off it. 3 no new timers beyond the existing debounced writer. 6 `_lastMergeAt` is cleared with the other owner state and bounded to 64 groups; the effective-head cache is per history instance. 9 the owner's drop uses facts and cutoffs, nothing is dropped on a claim. 12 bounded: 16 parents, 16 members, 4 leave tries, merges per window. 14 the merge stays owner-signed multi-parent (old validators accept it, tested with the frozen validator). 17 the leave retry has a cap. 19 the effective-head computation is cached per (heads, view epoch); `admittedByRevokedAuthors` is cached per (head, epoch).

### Performance
`GroupHistoryReplica.membership` still forks the index on each access; `hasConflict`, `mergeCandidate` and `_reduce` use it. The effective-head computation walks the branches of the heads, only when there are two or more heads, and is cached.

### Lab check needed
As in round 2, plus: a stolen admin phone that adds a device, then is revoked from the laptop while the owner's app is online (the thief device must leave in the owner's record); a revoked device that keeps sending membership records while offline devices come back.

### Release-note lines (draft, plain text)
When a device is removed from a person's account, devices that it added to a group in the meantime leave the group too; the group owner can add them again.

## Progress log, round 3
- 2026-11-07: pulled the round 3 findings; verified each in the code; rewrote the fork logic around effective heads and a field merge; made the H2 rule async with the chain check; tests first, sabotage checks as listed (history level: 10 variants, controller level: 3). The full suite and the debug run are recorded below.
