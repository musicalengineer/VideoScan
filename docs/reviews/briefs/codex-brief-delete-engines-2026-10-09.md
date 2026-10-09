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
