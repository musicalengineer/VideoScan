# Codex review — Delete engines

- Range: `007fc2c2aa30f727f6f38b51bcb473b1bedb7eba..spot/delete-2026-10-09`
- Credits spent: unavailable (billing telemetry not exposed)
- Tokens: 127099
- Finding count: 8
- Verdict: fix — Trash-only enforcement, authorization freshness, and accounting remain incomplete.
- Run: 2026-10-09T23:43:50Z (cycle #54, tools/codex_review.py)

## Codex answer

Credits spent: unavailable (billing telemetry not exposed) | Finding count: 8
Verdict: fix — Trash-only enforcement, authorization freshness, and accounting remain incomplete.

Line numbers refer to branch head `ca71ce1c1`. Reproductions below are source-traced; no files written or tests run.

1. **P1 — Junk permanent deletion remains executable.** `VideoScanModel+JunkDelete.swift:438`  
   State: an eligible file, calling `deleteConfirmedJunk([record], mode: .permanent)` without an injected operation → `FileManager.removeItem` permanently removes it. “Tests only” is a comment, not an execution restriction. The inspected UI callers pass `.toTrash`, but R3 requires the engine’s permanent branch to be unexecutable.

2. **P1 — Copies & Advice bypasses move-time keeper verification.** `Catalog/CopiesAdviceSheet.swift:218`; `VideoScanModel+TrashSelection.swift:145`  
   State: advice returns Safe because keeper K exists; K disappears after advice finishes but before the detached Trash operation → target T still moves. The hand-off uses the junk routine without a keeper guard. Recomputing advice before dispatch does not establish keeper presence at disposal.

3. **P1 — Junk does not refresh all protections during the batch.** `VideoScanModel+JunkDelete.swift:227`; `VideoScanModel+JunkTrashSnapshot.swift:153`  
   State: start a multi-file batch with no designated archive; while its first file runs, designate the later target’s volume as Master Archive → the later target uses the batch’s captured `nil` archive protection and can move. Likewise, making a frozen target an A/V-pair member before its turn adds no hold: the live junk authorization checks membership, purged status, disposition and path, but not pairing. R1/R4 remain open.

4. **P1 — Reviewed duplicates are not bound to the reviewed disk contents.** `DeleteDuplicatesReviewedPlan.swift:175`; `DeleteDuplicatesJob.swift:2066`  
   State: freeze a reviewed target/keeper pair, then rewrite both files with identical new content at unchanged paths → the fresh job verifies the new pair and trashes the target. Only the keeper stamp is retained; fresh execution never compares it with the reviewed stamp, and no target stamp is retained. Successful verification of today’s pair does not authorize changed review facts.

5. **P1 — Duplicate authorization can be revoked during verification without stopping disposal.** `DeleteDuplicatesJob.swift:1507`; `VideoScanModel+Duplicates.swift:379`  
   State: after authorization, change the target from Extra Copy to Keep while its large file is being verified → phase two can still trash it. The post-read check covers the deletion hold rule; the removal boundary covers protections and pairing. Neither repeats the reviewed disposition/group/keeper authorization from `authorizeDuplicateDeletion`.

6. **P2 — Resumed legacy bulk plans bypass the two-copy explicit-pick rule.** `DeleteDuplicatesJob.swift:2017`  
   State: resume an older bulk plan containing a pending extra whose only other copy is its keeper, with no explicit pick → resume returns `.ready` before `holdRowsNotPreselected()`. Verification now permits one survivor, so the extra moves. The new selection hold applies only to fresh bulk plans.

7. **P2 — Duplicate completion reports use catalog sizes instead of moved sizes.** `DeleteDuplicatesOutcome.swift:97`; `DeleteDuplicatesJob.swift:1700`  
   State: an otherwise valid identical pair occupies 20 MB, but the target’s catalog/plan size is 10 MB → verification succeeds and moves 20 MB; `outcomeReport` reports 10 MB. The worker’s measured `bytes` updates the transient tally but never updates the persisted entry used by the completion report and plan counters.

8. **P2 — Catalog’s Trash action skips the required confirmation.** `Catalog/CatalogRowContextMenu.swift:285`  
   State: choose Move to Trash from an enabled row menu → the button immediately starts `trashSelectedRecords`. No confirmation intervenes. This leaves R9’s retained “one confirmation” requirement unimplemented on this scoped path.

Earlier findings: **F1–F5 and F7 remain partially open** through the findings above. **F6:** outcome producers retain per-item reasons, but complete UI rendering is outside the allowed files. **F8:** no new custom Undo appears in scope; Open Trash presentation cannot be certified here. **F9:** selection plumbing exists, but confirmation remains open.

Read, no findings: `JunkDeleteAction.swift`, `JunkDeletionReport.swift`, `DeleteDuplicatesBatchRun.swift`, `DeleteDuplicatesTargetGates.swift`, `DeleteDuplicatesCopyCounts.swift`, and `DeleteDuplicatesForecast.swift`. Other scoped files are covered above.

Duplicate disposal explicitly passes `.trash`, including legacy permanent decisions. Inspected quarantine handling preserves recovery obligations after failed restoration. Verification primitives, recovery UI, and prune/Excess callers remain outside scope, so their full behavior is not certified.

## Brief

# Codex brief: Trash-only junk + duplicate delete engines (branch spot/delete-2026-10-09)

**Answer contract.** First line: `Credits spent: <amount> | Finding count: <N>`. A line:
`Verdict: <merge | fix | block> …`. Number findings P1–P3 with file:line and a concrete
reproduction (state → wrong result). Write nothing; answer only.

**Range:** `main...spot/delete-2026-10-09` (two branches merged onto main:
`fix/junk-delete-streamline` and `fix/dup-delete-trash-keep-one`; plus one Copies & Advice
follow-up). Design and rulings: `docs/design/triage_delete_streamline_2026_10_09.md` §2, §6,
§9 (R1–R9) — read those sections; they override the rest. Your earlier design review:
`docs/reviews/codex/codex-design-triage-delete-2026-10-09.md` (check each of your F1–F9 is
actually closed by the code).

**Do not explore outside these files** (all under `VideoScan/VideoScan/MediaOps/` unless noted):
- `VideoScanModel+JunkDelete.swift` (`deleteConfirmedJunk`), `VideoScanModel+JunkTrashSnapshot.swift`
  (`freezeJunkSnapshot`, `trashFrozenJunk`), `VideoScanModel+TrashSelection.swift`
  (`trashSelectedRecords`), `JunkDeleteAction.swift`, `JunkDeletionReport.swift`
- `DeleteDuplicatesJob.swift`, `DeleteDuplicatesPlan.swift`, `DeleteDuplicatesReviewedPlan.swift`,
  `DeleteDuplicatesBatchRun.swift`, `DeleteDuplicatesTargetGates.swift`,
  `DeleteDuplicatesOutcome.swift`, `DeleteDuplicatesCopyCounts.swift`, `DeleteDuplicatesForecast.swift`,
  `VideoScanModel+Duplicates.swift` (`authorizeDuplicateDeletion`, `reviewedDuplicateBatch`)
- `Catalog/CatalogRowContextMenu.swift` (`removeAndDeleteItems`), `Catalog/CopiesAdviceSheet.swift` (the trash hand-off only)

**Invariants to attack (prove or break):**
1. Trash only: no reachable path in these files calls `removeItem`, `unlink`, `unlinkat`,
   or a quarantine-then-delete, including a RESUMED legacy duplicate plan with a recorded
   `.permanent` disposal. A Trash failure is a hold with the file back at its path, never an
   unlink and never a silent loss (check quarantine: is a quarantined file ever stranded?).
2. Junk: moved ⊆ the frozen confirmed snapshot; a file changed, replaced, un-marked, offline
   or protected after the freeze is held; nothing marked after the freeze moves.
3. Duplicates keep-one: nothing goes unless, AT THE MOVE, one keeper of the same content is
   proven present (digest/fixity + identity) and is not the target under any alias (symlink,
   hard link, case, firmlink). A 2-copy group is never moved without an explicit pick.
4. The reviewed plan never widens: moved ⊆ picks; a pick whose facts changed is held; two
   keepers chosen for one group → held.
5. Never a target: Master Archive tree/volume, read-only and archive-backup drives, network
   mounts, half of an A/V pair, a copy longer than the archive master or of unknown length.
6. Every requested item has exactly one outcome and requested == the sum; held reasons reach
   the UI; bytes reported = moved files' sizes.
7. Existing prune / Excess callers of `deleteConfirmedJunk` behave as before.

**Evidence already run:** junk branch 322 tests / 36 suites green (Release); duplicates branch
650 tests / 97 suites green (Release); red-first per item.
**Known / accepted, do not report:** the `[dupjob]` log line still prints `freed 0` (log
formats need Rick's OK); `leftAloneCopies` capped at 2,000 (never requested); the "Prefer the
Trash" toggle is now inert UI (cleanup later); `SignatureVerification.deleteQuarantined`
default `.permanent` has no app caller (report only if you find a caller).

## Closure

Closed on `spot/delete-2026-10-09` (worktree `.claude/worktrees/spot-delete`), 2026-10-09
night. Each finding: red test shown failing on the head before its fix (Debug), then
green; one commit per finding. Full suite run: see "Evidence" below.

| # | Finding | Pinning test(s) | SHA |
|---|---------|-----------------|-----|
| F1 (P1) | Junk `.permanent` still executable | `JunkPermanentUnreachableTests` (engine has no `removeItem`/`unlink`; no app source spells the seam; the production mode is the Trash). `.permanent` now exists only in the test target as the engine's injected-operation seam. | `33967b312` |
| F2 (P1) | Copies & Advice trash bypassed move-time keeper proof | `CopiesAdviceTrashKeeperProofTests` (sensor) + `CopiesAdviceTrashBehaviourTests` (keeper vanishes after the advice → nothing moves, held with its reason; proven keeper → moves; no pick for the keeper's own card or a sampled match) | `42af62463` |
| F3 (P1) | Junk protections captured once per batch | `JunkProtectionsPerFileTests` (archive designated mid-batch → later file on it held; frozen target paired mid-batch → held; same for ⌘⌫) | `b48a8d5d3` |
| F4 (P1) | Reviewed duplicates not bound to reviewed disk contents | `DeleteDuplicatesReviewedStampTests` (both files rewritten with identical new content → held "changed since you reviewed it"; target-only rewrite → held; pure identity rule) | `670c87c8b` |
| F5 (P1) | Authorization revocable during verification | `DeleteDuplicatesBoundaryAuthorizationTests` (target re-marked Keep after quarantine → held; keeper re-elected during the read → held). Follow-up `9963803be`: three older tests that pinned "catalog row replaced/moved during the read, file removed anyway" now pin HELD (stricter). | `5485dbeec`, `9963803be` |
| F6 (P2) | Resumed legacy bulk plans skip the 2-copy pick rule | **Superseded by Rick's ruling (2026-10-09 evening, design §9 R5 revised):** no per-file ticks, pairs included, fresh AND resumed; the proof at the move is the safety. `DeleteDuplicatesPairsIncludedTests` (fresh pair with proven keeper → moves; unprovable keeper → held with reason; resumed older plan → same rule; forecast has no "not pre-selected" bucket). | `86f20319d` |
| F7 (P2) | Completion bytes used catalog sizes | `DeleteDuplicatesMovedBytesTests` (catalog says half → report, line and plan counters say the measured size) | `6b12fef44` |
| F8 (P2) | Row-menu Move to Trash had no confirmation | `CatalogTrashConfirmationSensorTests` (row menu and ⌘⌫ both go through `confirmThenTrash`, the one `trashSelectedRecords` call; Esc = Cancel) + `CatalogTrashConfirmationTests` (pure words: count, size, every held reason) | `2776b83a9` |

Also in this batch (Rick's additions, approved by him):
- G1 — the result says why copies stayed, in the window (MFO row, status, card):
  `DeleteDuplicatesResultLineTests` — `2d3d62efa`. (The tick half of G1 went with F6/R5.)
- G2 — auditor-grade delete log (START / one line per file / OUTCOME) through the one
  sink + per-run receipt CSV under `~/Library/Logs/VideoScan/deletions/`:
  `DeletionAuditSensorTests`, `DeletionAuditReceiptTests` — `3bd7d411b`. Not yet covered:
  the "Archived — what next?" prune lane (per-copy engine calls; named in the sensor).
- Sensors that were red on the spot head before this batch, fixed sensor-only:
  removal censuses missing Delete Duplicates' Trash step (`fafd83011`); Triage view
  sensor pinned to pre-snapshot Delete Junk code (`4e12b9147`).

Declined: none. Superseded: F6 (by Rick's R5 revision, above).

### Evidence

Release, `ENABLE_TESTABILITY=YES`, by SUITE (every DeleteDuplicates*, Duplicate*, Junk*,
ExcessCopies*, ReadOnlyVolume*, ArchiveVolumeProtection*, PruneApply*, CopiesAdvice*,
CatalogRowMenu*, TriageViewSensor*, RemoteViewer*, AtomicFilePublishSensor suite, plus the
new CatalogTrashConfirmation*, CatalogTrashConsistency, DeletionAudit* suites):
**727 tests in 126 suites passed**, 0 failures; 8 known issues are the deliberate
`withKnownIssue` mutation checks in the Codex #258 round-4 sensor suite (there before
this batch). Log: `…/scratchpad/codexfix/release.log`.

Behaviour changes to note for Rick: a bulk Delete Duplicates run now moves pair extras
(R5 revised); a copy whose catalog row is replaced or moved during its read is held, not
removed (F5); a reviewed plan resumed after its drive was re-plugged under a new device
number is held "changed since you reviewed it" (F4, fail closed).

Pre-existing, not from this batch (gauntlet `inventory.swift --validate`): six test files
unassigned or stale (HallieShellCLITests, HallieSuperlativeScopeTests,
MediaFileOperationsTests, three tests/test_complexity_*.py) and a unit-stage
blocked/assignment mismatch (MediaRepairEngineTests, MediaRepairJobTests). The new test
files of this batch are assigned.
## Closed

Closed by `3bd7d411b` at 2026-10-10T01:31:18Z. F1–F5, F7, F8 fixed red→green; F6 superseded by Rick's R5 revision; G1/G2 added. Release: 727 tests / 126 suites green.
