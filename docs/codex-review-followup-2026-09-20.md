# Follow-up review: duplicate recovery, documents, archive pruning

Reviewed immutable commit `90a54fb0`, including `23d5206a`, `4e01d35f`, `5ad5d0b4`, and `90a54fb0`. Machine: none. Verdict: **changes required**. This follows the review of message #1593; it does not replace that historical report.

## Findings

1. **P1 — an archive audit makes a changed original appear safe to remove.** `VideoScanModel+PruneApply.swift:364` passes the archive's `archiveFixity.verifiedAt` as the source's `trustedUntil`; lines 256–263 accept source timestamps preceding it. `VerifyArchiveCopiesJob.swift:952–963` advances this date when verifying only the archive. Promote A, edit A to different same-sized bytes, then audit the archive: the changed source passes without being read. Source authority must be tied to the source identity established during promotion, not the latest archive audit.

2. **P1 — same-sized archive corruption still authorizes pruning an original.** `VideoScanModel+PruneApply.swift:209–211` checks archive existence and size; the original shortcut at 256–263 never checks its current identity or digest. Rewrite the archive after promotion without changing its size, select the unchanged original, and both gates succeed despite different contents. Versions also receive only the size check. Require current archive evidence before allowing removal.

3. **P1 — prune verification expires before the file operation.** `VideoScanModel+PruneApply.swift:370–372` verifies the whole batch, discards verified target/keeper identities in `PruneByteVerdict` (244–249, 271–274), then passes mutable records to `deleteConfirmedJunk` (390, 433). `VideoScanModel+JunkDelete.swift:244–276` only checks existence before Trash/permanent removal. Rewrite or replace target A, or remove its archive, while target B hashes: A's stale verdict still authorizes its current pathname. Carry proof through a guarded per-file mutation and recheck live catalog authorization.

4. **P1 — Stop/Quit can miss the second deletion phase.** `DeleteDuplicatesJob.swift:400–416` awaits quarantine-ticket persistence while `currentWorker` is nil. Stop/Quit cancels the outer task, but after persistence it unconditionally starts phase two through a new `Task.detached` (587–590). That task does not inherit cancellation. Check the stop/suspend latch after persistence and propagate cancellation to any new worker; restoration or retention is allowed, deletion is not.

5. **P1 — changed eligibility prevents recovery of an interrupted quarantine.** `DeleteDuplicatesJob.swift:636–641` settles and skips rows whose deletion authorization changed, before restoration at 655–669. After a crash with a valid saved ticket, marking the target Keep, changing its keeper, or disabling cleanup can leave the original quarantined while the settled plan moves to `done/`. Separate recovery authorization from deletion authorization; refusing deletion must preserve a recovery path.

6. **P2 — prune rereads an initially uncached archive for every duplicate.** All checks capture the same initial fixity at `VideoScanModel+PruneApply.swift:358–364`; fresh evidence is published only after the entire map finishes (382–383). N duplicates therefore cause N full archive reads. Reuse newly verified keeper evidence within the batch, subject to its identity checks.

## Evidence and validation limits

The prune reviewer extracted the exact production disk/byte-check functions plus ContentFixity/SignatureVerification into a standalone Swift CLI. On real filesystem stamps and 256-byte synthetic files, both unsafe authorizations reproduced:

```text
archive rewritten same-size after promote: equal=false diskProblem=nil byteProblem=nil readInFull=false
source edited, then archive audited: equal=false diskProblem=nil byteProblem=nil readInFull=false
```

Harness directory: `/var/folders/d8/4gw97srj1gq4bwk2cnlklzwh0000gn/T/prune-review-90a-ap6nap6e`. The reproduction did not delete files.

A separate standalone Swift scheduling reproduction of the two-phase worker structure reported:

```text
current worker absent during save: true
outer cancelled after save: true
phase 2 sees cancellation: false
```

Source: `/private/tmp/dup1593-phase-gap.swift`. This demonstrates the cancellation mechanism; it is not an app-level integration test. No app builds or launches, and no independent full-suite pass is claimed.

## Prior findings addressed by source and regression-test inspection

- Post-quarantine target rewrite: full post-move identity plus a second target hash now guard deletion. `DeleteDuplicatesCodex1593Tests.swift:82–161` covers the prior descriptor-write scenario and ticket-to-delete changes.
- Arbitrary quarantine selection and recursive cleanup: recovery uses recorded/derived locations and empty-only directory removal. The separate recovery-ordering issue above remains.
- Authorization between duplicate pairs, moved-row settlement, final-save failure, and discovery of the next unfinished plan have direct fixes and regression cases.
- Archive corruption invalidates both archive and content fixity (`VerifyArchiveCopiesJob.swift:1000–1002`); regression coverage includes content-only authority.
- Document rows bind their owner and folder; selection clears stale rows; removal validates ownership; per-person revisions reject stale asynchronous results. `FamilyDocumentModelTests.swift` exercises selection/removal and import/removal read races. No additional concrete defect found in that correction.
- Quit suspension exists, but cannot be approved until finding 4 is covered.

## Required regression coverage

- Each prune timeline in findings 1–3, with deterministic synchronization at the verification-to-mutation boundary and assertions that changed data survives.
- Stop and Quit while the saved quarantine ticket is pending; release persistence and assert no deletion occurs.
- Resume a valid ticket after Keep/keeper/policy changes; assert restoration or explicit retained recovery state.
- Multiple duplicates sharing an initially uncached keeper, counting actual file opens/bytes rather than callback labels.

Prune tests already cover sampled-hash collisions, sources edited after promotion, missing archives, notes, versions, and changed attestation. Scale tests cover 120,000 Core snapshots and 100,000 model records with explicit budgets. Those do not cover the apply-time mutation boundary. The existing source-text sensor pins delegation to the unguarded Trash routine rather than safe behavior; replace or supplement it with behavioral assertions. Sandbox fixtures exist, but these reviewed suites do not establish poisoned-global-state coverage or the real-codec media matrix required by AGENTS.md. For byte-only operations, document which media-matrix dimensions are applicable and exercise them through the production path.

Findings sent to Claude in team-channel messages #1603 and #1604. Production files were not modified by this review.
