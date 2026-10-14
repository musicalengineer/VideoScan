# Codex review — Cleanup v1 r1

- Range: `b07f9da43..e5d39127`
- Credits spent: unavailable (billing telemetry not exposed)
- Tokens: 105772
- Finding count: 7
- Verdict: fix — close the ancestry and volume-identity holes before Rick’s real-archive run.
- Run: 2026-10-12T18:56:19Z (cycle #68, tools/codex_review.py)

## Codex answer

Credits spent: unavailable (billing telemetry not exposed) | Finding count: 7

Reviewed `main..e5d39127`. No files changed; tests not rerun. The 173 passing tests are supplied evidence.

1. **P1 — Execution accepts ancestry that became unsafe after planning.**  
   `CleanupProof.swift:53`, `:125`; `VideoScanModel+JunkDelete.swift:170`, `:577`.

   Reproduction: after planning, move the keeper’s parent into Trash and replace its old directory with a symlink. The proof follows that link, reads the reserved inode successfully, and permits trashing the remaining outside-Trash copy.

   The same hole defeats the FamilyArchive waiver: move ticked junk’s parent into the archive tree and leave a symlink at its old location. The lexical tree/name checks miss the new ancestry; the waiver permits removal.

   **Smallest fix:** repeat regular-file and no-symlink-ancestry checks at execution for both files; reject resolved Trash ancestry and enforce archive-tree/Avid exclusions on resolved paths in both lanes. This is reproducible before proof starts, independently of the narrow proof→Trash race.

2. **P1 — Mount presence is mistaken for the original volume’s identity.**  
   `CleanupProof.swift:128`; `CleanupDiskProbe.swift:44`.

   Reproduction: plan junk `/Volumes/X/a.mov` on disk A; disconnect A and mount disk B as X without that file. `mountPresent` returns true, the proof permits “missing,” and the engine stamps A’s still-existing offline file’s row.

   Copies have a related identity weakness at `CleanupProof.swift:59`, `:76`: planned identity comparisons discard volume UUID. A replacement volume reusing device/inode numbers passes if its bytes match the keeper, potentially moving a different disk’s file and stamping the original row.

   **Smallest fix:** require the frozen volume UUID at execution. Treat absence as “missing” only after proving the original volume is mounted; otherwise hold. Preserve UUID in planned-file comparisons.

3. **P2 — The alias index omits noncandidate catalog rows.**  
   `CleanupPlan.swift:270`, `:316`.

   Reproduction: A and B form a full-hash group; an additional active, nonjunk row names B’s physical file but has no full digest. That row never enters the physical index. B remains selectable, and trashing it leaves the alias row active. Singleton stale-hash groups and set-aside aliases have the same omission.

   **Smallest fix:** account for aliases across all active rows before authorizing candidates, with disk work off-main. The current index does not establish the promised catalog-wide ambiguity exclusion.

4. **P2 — “Last run” captures the previous progress message.**  
   `CleanupPane.swift:100`; `CleanupTrashJob.swift:517`, `:521`, `:528`.

   The synchronous `$state` subscriber reads `job.subtitle` when terminal state publishes, but the final subtitle is assigned afterward. A finished run can persist “Preparing…” or an intermediate progress message instead of its outcome; a failed save can lose its warning from the page summary.

   **Smallest fix:** publish final subtitle before terminal state, or pass the completed outcome directly to the store.

5. **P2 — Read progress double-counts bytes and credits unread files.**  
   `CleanupTrashJob.swift:409`, `:484`; `FixityRebind.swift:82`.

   Each rehash resets `control.bytesRead`, so progress regresses between keeper and target reads. Settlement adds two complete files regardless of whether either was read, then progress adds the target’s residual counter again. One successful pair can display three file-lengths read against two planned; early holds also receive full read credit.

   **Smallest fix:** accumulate actual bytes across both reads and transfer/reset the in-flight counter exactly once at settlement.

6. **P2 — Early engine refusal silently disappears from Cleanup outcomes.**  
   `CleanupTrashJob.swift:301`; `VideoScanModel+JunkDelete.swift:302`.

   If viewer protection activates during a run, engine preflight returns held outcomes without invoking `settled`. Cleanup discards that return value, so those files disappear from totals and the receipt.

   **Smallest fix:** consume every returned outcome exactly once, including preflight refusals.

7. **P3 — Per-render reduction remains:** `CleanupPane.swift:277` evaluates `plan.archiveJunkBytes`, an O(archive-junk rows) reduction; cache the listed-byte total when building the plan.

The seven design findings landed as follows:

- **Fresh reads:** landed, `CleanupProof.swift:55`, `:63`; both files are fully hashed for each attempted move.
- **Reserved survivor:** frozen selection and no re-election landed, `CleanupTrashJob.swift:66`; outside-Trash enforcement remains open under finding 1.
- **Aliases/physical accounting:** partial; planning rejects symlink paths and indexed aliases, but findings 1 and 3 remain.
- **Separate junk lane/tick box:** landed, `CleanupTrashJob.swift:415`, `CleanupPane.swift:110`; explicit authorization remains distinct from duplicate proof. Waiver ancestry remains open.
- **Full SHA-256 plus size:** landed, `CleanupPlan.swift:317`.
- **A/V halves/Avid:** planning exclusions landed at `CleanupPlan.swift:414`; live pair checks exist, but execution ancestry exclusions remain incomplete.
- **Ties/report/wording:** ties and “GB selected” landed at `CleanupPlan.swift:383`, `CleanupPane.swift:229`; receipts persist outcomes, but findings 4–6 weaken reporting.

Checkpointing awaits `saveCatalogAcknowledged()` before advancing (`CleanupTrashJob.swift:283`, `:355`). Engine calls now contain one file each, so in-memory stamps settle per file. A process crash can leave the current batch unpersisted: up to 20 copies/40 GiB of planned reads, with oversized singletons, or 100 junk files. Save failure prevents further moves. Pause waits between files; Stop during hashing holds/cancels the file. Stop after proof can still allow a move, but that outcome remains honestly **moved**, not cancelled.

The proof→Trash exposure remains: after descriptor-based hashing, the engine checks protections/existence/size and moves by pathname (`VideoScanModel+JunkDelete.swift:553`). Replacement target bytes can be trashed, or the keeper can disappear after its final check. Scheduling and filesystem calls make this more than a guaranteed “microsecond” interval. **#315 need not independently block a quiescent single-user v1 after these fixes**, but concurrent writers/movers remain unsafe; quarantine addresses the target-replacement exposure.

Tests are meaningfully proof-sensitive: `lyingDigestHeld`, `keeperRewrittenHeld`, the media matrix’s changed copy, and the poisoned-candidate sensor would fail with proof bypassed. Happy-path moves, planner sweeps and batching tests would still pass. Missing cases include post-plan ancestry changes, volume substitution/device reuse, unhashed aliases, mutation during/between reads, post-proof Stop, blocked-save ordering, and crash/reload durability.

Read, no independent findings: `VideoScanModel+Cleanup.swift`, `CleanupTrashJobDetailView.swift`, removal-marker/doorVerb changes, new audit/MFO kinds, Triage sidebar changes, and all five scoped test files. `reportedRecord` preserves original-path reporting; genuinely held/failed/offline/cancelled outcomes receive no marker. No production unlink fallback found.

Verdict: fix — close the ancestry and volume-identity holes before Rick’s real-archive run.

## Brief

# Codex brief: Triage ▸ Cleanup v1, round 1

**Answer contract.** First line: `Credits spent: <amount> | Finding count: <N>`. A line `Verdict: <merge | fix | block> …`. Write no files; answer only. Under ~1,200 words.

**What this is.** The Cleanup page and job you reviewed as a design this morning (`docs/reviews/codex/codex-design-cleanup-kiss-2026-10-12.md`, your 7 findings; design `docs/design/cleanup_kiss_2026_10_12.md`, five v1 rules) is now built on the one-engine branch (#143, your two rounds; merged to main today). An in-house QA pass found no P1 and three P2s, all fixed. Rick runs this on his real archive next: ~867 copies, ~630 GB. A miss costs family media.

**Range:** branch `worktree-agent-aa316ffbf0a4f7b2f`, `main..e5d39127` (`git log main..e5d39127`; read files with `git show e5d39127:<path>`). Paths under `VideoScan/VideoScan/` unless noted.

**Files in scope:**
- `MediaOps/Cleanup/CleanupPlan.swift` — planner: groups by stored full SHA-256 + size; keeper = `DuplicateKeeperPolicy` among connected members; exclusions; frozen selection; physical-file index for aliases
- `MediaOps/Cleanup/CleanupDiskProbe.swift` — realpath / identity / mount-present seams
- `MediaOps/Cleanup/CleanupProof.swift` — the proof inside the engine's `beforeRemoval` hook: both files read in full, identity before/after, SHA-256 + length; junk re-check; `mountPresent`
- `MediaOps/Cleanup/CleanupTrashJob.swift` — the MFO job: batches (20 files or 40 GB), confirmed save per batch, Pause between files, Stop settles the rest as cancelled
- `MediaOps/Cleanup/VideoScanModel+Cleanup.swift`, `MediaOps/Cleanup/CleanupTrashJobDetailView.swift`
- `Catalog/CleanupPane.swift` — the page and `CleanupStore` (tick box for FamilyArchive junk, frozen on run, reset after)
- `MediaOps/VideoScanModel+JunkDelete.swift` — the ONE engine change: `JunkDeletionGuard.archiveVolumeJunkWaiver` (lifts only the "elsewhere on the Master Archive volume" refusal, only for listed junk rows, at all three gates; never for the archive tree, an unprovable drive, or a Read-only mark); plus `reportedRecord(_:turn:)` for your r2 P2
- `MediaOps/VideoScanModel+RemovalMarker.swift` (doorVerb table), `MediaOps/DeletionAudit.swift` (new receipt kind), `MediaOps/MediaFileOperations.swift` (new kind), `Catalog/TriageView.swift` (sidebar row only)
- Tests: `VideoScanTests/CleanupTrashPlanTests.swift`, `CleanupTrashRunTests.swift`, `CleanupTrashMediaMatrixTests.swift`, `CleanupTrashSensorTests.swift`, `CleanupTrashTestSupport.swift`

**Do not explore outside these files**, except to confirm what an engine function they call actually does (`deleteConfirmedJunk`, `MediaTrash.move`, `stampRemoval`, `FixityRebind.rehash`, `DuplicateKeeperPolicy`).

**Invariant to attack:** *No file goes to the Trash unless an identical copy provably stays, on a connected drive, outside the Trash, not itself removed in this run. FamilyArchive is never trimmed as a copy. A held, failed, offline or cancelled file's row is never stamped. Nothing is ever unlinked.*

**Check your own design findings landed (cite file:line or say what is open):**
1. fresh full read of BOTH files at each move, no stat-only shortcut;
2. one reserved survivor per group for the whole run, never in the removal set under any alias, keeper loss holds (never re-elects);
3. aliases skipped: same device+inode, hardlinks, symlink-traversing paths, case variants, two rows for one file; physical accounting;
4. junk is a separate lane with its own re-check; FamilyArchive junk only via the explicit tick box;
5. groups from full SHA-256 + size, not sampled hashes;
6. A/V halves and Avid MediaFiles excluded at execution, both lanes;
7. ties excluded; outcome report persists; "GB selected" wording.

**Then attack:**
- the waiver: any way it lifts protection for a non-listed row, a copy, a tree file (spelling/case/symlink of the archive root), or outlives the run;
- the batch checkpoint: can a crash between `MediaTrash.move` and the confirmed save leave moved files unstamped beyond one batch? Is the save awaited before the next batch starts?
- Pause/Stop/crash mid-proof: half-stamped batches, double-counted bytes, a cancelled file that was actually moved;
- the proof→trash window (file hashed at its path, then trashed without quarantine; Delete Duplicates quarantines first): state the exact exposure on a single-user archive and whether v1 may ship with it (#315 tracks the engine RemovalStep split);
- stale mount cache / device-number reuse after remount;
- the page: O(records) in view bodies? `model.records` read? state mutation during layout?
- tests that would pass with the proof removed; name missing cases.

**Evidence already run (Debug):** 173 tests in 21 suites green on the branch (4 Cleanup suites: plan 25+, run 16+, media matrix 5, sensors 6; plus 17 engine/Triage regression suites); media matrix moves real mp4/mov/mkv/mxf/avi to a test Trash and holds a one-byte-changed copy; a 2,000-catalog random sweep checks the keeper invariant; sensors: Cleanup code has no trashItem/removeItem/unlink/rename/moveItem/marker write/row delete.

**Output:** P1 (could trash the last good copy / wrong stamp / unlink) · P2 (wrong result, count, or UX that misleads) · P3 (≤3, one line each). Each with file:line, scenario, smallest fix. End with `Verdict:`.

## Closure (Manager, 2026-10-12)

All 7 findings fixed red-green on the branch (94e59dad, 5ed941f8, fc83301e, 6d11f06a, 9e61c4e0, 28a4fa1d, bbdbdd4d) plus the dry-run P2 (2aa8e527, hand marks only) and the missing cases (c80cc264). Round 2 → codex-review-2026-10-12-cleanup-v1-r2.md.

## Closed

Closed by `HEAD` at 2026-10-12T19:48:19Z. 7 fixed
