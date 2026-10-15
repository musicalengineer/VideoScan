# Codex review — Show Again legacy marker

- Range: `7dd2de28..62b90bbf`
- Credits spent: unavailable
- Tokens: 134122
- Finding count: 3
- Verdict: fix — receipt fidelity fails for two admitted cases; the scoped rescan helper also violates the stated one-writer invariant. No P1 found.
- Run: 2026-10-14T23:58:48Z (cycle #71, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 3

Verdict: fix — receipt fidelity fails for two admitted cases; the scoped rescan helper also violates the stated one-writer invariant. No P1 found.

- **P2 — Invariants 3–4: receipt records a post-state the engine never sets.** [ShowAgain+Apply.swift:203](/Users/rickb/dev/VideoScan/VideoScan/Catalog/ShowAgain+Apply.swift:203) always writes `to: "None"`; reproduce with a valid legacy marker and `.backedUp`: candidacy accepts it, `clearRemoval` preserves `.backedUp`, then [reverse:309](/Users/rickb/dev/VideoScan/VideoScan/Catalog/ShowAgain+Apply.swift:309) refuses the unchanged row, leaving its cleared marker unrestored.
- **P2 — Invariant 5: a second removal writer exists, predating this range.** [VideoScanModel+RescanPreservation.swift:450](/Users/rickb/dev/VideoScan/VideoScan/Catalog/VideoScanModel+RescanPreservation.swift:450) directly assigns `rec.removal`; reproduce by capturing preservation fields before Show Again and applying them afterward—the captured legacy marker is reinstated outside the engine.
- **P3 — Invariant 4: receipt serialization loses fractional seconds.** [ShowAgain.swift:388](/Users/rickb/dev/VideoScan/VideoScan/Catalog/ShowAgain.swift:388) uses `.iso8601`; reproduce with `since = Date(timeIntervalSince1970: 1_760_300_000.25)`: encode/decode drops `.25`, and reverse stamps a different `since`; the new equality test uses an integral timestamp at [ShowAgainTests.swift:310](/Users/rickb/dev/VideoScan/VideoScanTests/ShowAgainTests.swift:310).

Remaining invariant checks:

- **1 holds:** candidacy requires the exact legacy state/reason when purged; commit repeats that check, and reverse holds purged rows. See [ShowAgain.swift:173](/Users/rickb/dev/VideoScan/VideoScan/Catalog/ShowAgain.swift:173) and [ShowAgain+Apply.swift:310](/Users/rickb/dev/VideoScan/VideoScan/Catalog/ShowAgain+Apply.swift:310).
- **2 holds for indexed receipts:** ID or path matches veto restoration, including files returned to their original paths; the run rereads the ledger. See [ShowAgain.swift:213](/Users/rickb/dev/VideoScan/VideoScan/Catalog/ShowAgain.swift:213).
- **3 otherwise holds:** snapshot and receipt precede mutation; forward save refusal yields `saveUnconfirmed`. See [ShowAgain+Apply.swift:104](/Users/rickb/dev/VideoScan/VideoScan/Catalog/ShowAgain+Apply.swift:104).
- **4 compatibility holds:** optional `removalSince` permits old-shape receipts; reverse retains path, label and removal-state guards.
- **6 holds:** hidden candidates are counted and excluded in the same `cleanupInputs()` pass; rebuilding inputs admits restored rows. The view reads the cached tally. See [VideoScanModel+Cleanup.swift:82](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/Cleanup/VideoScanModel+Cleanup.swift:82).
- **7 holds for replacement rows:** matching requires the reviewed UUID, path, size and marker timestamp, checked again immediately before commit; there is no path-only fallback. See [ShowAgain+Apply.swift:179](/Users/rickb/dev/VideoScan/VideoScan/Catalog/ShowAgain+Apply.swift:179).

`VideoScanModel+Cleanup.swift`, `CleanupPlan.swift`, `CleanupPane.swift`, `ShowAgainReview.swift`, `CatalogStorageTotals.swift`, and both removal-engine reference files: read, no findings within scope.

Reviewed at `62b90bbf`. Tests inspected, not executed because they write fixtures and catalog files. No files written.

## Brief

# Codex brief: Show Again sees the GH #143 legacy marker (data-risk)

**Answer contract.** First line: `Credits spent: <amount> | Finding count: <N>`. A line `Verdict: <merge | fix | block> …`. Write no files; answer only. Under ~900 words.

**One sentence (Rick, 2026-10-14):** files that sit on disk untouched but are hidden behind an old "deleted" label become live rows again, so Triage ▸ Cleanup can see them and remove the copies with proof.

**Why it matters:** on Rick's catalog 993 rows (987 GB on his working drives) carry `archiveStage == .manuallyDeleted` from Migrate's old bucket E (sampled-hash "safely redundant", 2026-05/08; the files were never moved). The 10/11 repair "Show files hidden by a 'deleted' label" (`fc87cc87`) cleared the label only. GH #143 (`5208a5de`, 10/12) then made the load migration stamp those rows `removal = .removedFromCatalog(reason: .legacyDeletedLabel)` (persisted), so `isPurged` became true, the repair's candidate list went empty and its footer link disappeared. After this change the repair re-admits those rows into Cleanup's delete pool.

**Range:** main, `7dd2de28..62b90bbf` (merged as `1d41cdf0`). Read files with `git show 62b90bbf:<path>`. Paths under `VideoScan/VideoScan/` unless noted.
- `Catalog/ShowAgain.swift` — `ShowAgainRules.isCandidate` (label in either encoding; if purged, the marker must be exactly `removedFromCatalog` + `.legacyDeletedLabel`), `ShowAgainCandidate.removalSince`, `ShowAgainReceiptFile.Change.removalSince` (optional, old receipts decode), `ShowAgainStayReason.restoreRefused`.
- `Catalog/ShowAgain+Apply.swift` — commit through the engine's `clearRemoval(rec)`; receipt records the row's real `from` stage; reverse re-stamps with `VideoScanModel.stampRemoval(rec, .removedFromCatalog(at: since, reason: .legacyDeletedLabel))` and puts the label back only when `from == "Manually Deleted"`.
- `MediaOps/Cleanup/VideoScanModel+Cleanup.swift`, `MediaOps/Cleanup/CleanupPlan.swift`, `Catalog/CleanupPane.swift`, `Catalog/ShowAgainReview.swift` — the hidden-by-label tally rides `cleanupInputs()`'s one pass; one line + "Show them again…" link on the Cleanup page.
- `Catalog/CatalogStorageTotals.swift` — legacy-marker rows routed to the manuallyDeleted bucket (excluded from counted/gross/unique).
- Engine reference (read-only context): `MediaOps/VideoScanModel+RemovalMarker.swift` (`clearRemoval`, `stampRemoval`), `VideoScanCore/Sources/VideoScanCore/RemovalMarker.swift` (`migrated`).
- Tests: `VideoScan/VideoScanTests/ShowAgainTests.swift`, `CleanupTrashPlanTests.swift`, `CatalogStorageTotalsTests.swift`. In-house QA round 1 closed two P3s (exact reverse on a marker-only row; lifecycleStage `.trashed` → `.cataloged` documented).

**Invariants to attack (prove with file:line or say it holds):**
1. No row whose marker is anything but `removedFromCatalog/.legacyDeletedLabel` (inTrash, missing, userRemoved, legacyTrashed, legacyPurged, legacyDeleted, unspecified) can become a candidate, be shown again, or be touched by the reverse.
2. A file that the app DID move (a Trash receipt in the Media Ledger) stays hidden, whatever the marker says.
3. After a run the row is live (`removal == nil`, label `.none`) and nothing else on the record changed except the engine's `.trashed → .cataloged` mirror; the receipt and the catalog snapshot are written before the first mutation; a refused save is reported as `saveUnconfirmed`, never success.
4. Reverse from the receipt puts back exactly what was cleared (same `since`), holds on rows that changed, and old-shape receipts still decode.
5. The one-writer rule: nothing outside `VideoScanModel+RemovalMarker.swift` assigns `.removal` / `.purgedAt` / `lifecycleStage = .trashed`.
6. Re-admitted rows reach Cleanup only through `cleanupInputs()` after the run; while hidden they are never in Cleanup's `rows`; the tally never does O(records) work in a view body.
7. A rescan between review and run (rows replaced / markers carried by `VideoScanModel+RescanPreservation.swift`) cannot make the run restore a different row than the one reviewed.

**Do only this:** findings against 1–7 (P1 first), each with file:line and a one-line failure scenario; then at most three P2/P3 one-liners. Known and out of scope (not findings): rows with `inTrash/.legacyTrashed` still present at their path (682 rows, 16 GB; Restore via Show Removed handles them); the load migration itself; Migrate/Relocate.

**Do not explore outside the files listed above and their tests.**

## Closure

Branch `fix/show-again-codex-r1` off main (8789eb98). Red tests first in
`12a66e33` (ShowAgainTests.swift); fixes in `3663b24f`. Verified in an
isolated worktree: 61 tests in 5 suites green (ShowAgainRulesTests 5,
ShowAgainApplyTests 17, ShowAgainSensorTests 3, OneEngineSensorTests 7,
CleanupTrashPlanTests 29), Debug.

| Finding | Closure | Pinning test |
|---|---|---|
| P2-1 receipt records a post-state the engine never sets | fixed in `3663b24f`: `writeShowAgainReceipt` writes `to` = the stage `clearRemoval` actually leaves (`.manuallyDeleted` → `.none`; any other label stays, so `from == to`); the reverse hold compares against that real `to` and puts a label back only where `from` was Manually Deleted | `ShowAgainApplyTests.otherLabelRowReceiptIsExact` ("codex r1 P2-1: … Backed Up …") — red in `12a66e33`, green in `3663b24f` |
| P2-2 a second removal writer (RescanPreservation carry-over) | (a) fixed in `3663b24f`: `showAgainPreflightRefusal` and `reverseShowAgain` refuse on `model.isScanning` — "a scan is running — let it finish, then show the files again" (the flag the Analyze cyclers refuse on); (b) otherwise **declined**: the rescan carry-over is the allowlisted, documented behaviour of the one-marker design (docs/design/one_removal_marker_and_trash_engine.md §3; `OneEngineSensorTests.markerWriterAllowlist`), and a re-hidden row is the conservative outcome | `ShowAgainApplyTests.refusesWhileScanning` ("codex r1 P2-2 …") — red in `12a66e33`, green in `3663b24f` |
| P3 receipt serialization loses fractional seconds | fixed in `3663b24f`: `ShowAgainReceiptFile.encode/decode` use ISO 8601 with fractional seconds (millisecond precision — the formatter's limit; a sub-millisecond `since` still differs by < 1 ms after a reverse) and decode both shapes, so receipts written before 2026-10-14 still load | `ShowAgainApplyTests.reversePutsTheMarkerBack`, `reverseOnMarkerOnlyRowIsExact`, `legacyTrashedStageBecomesCataloged`, `otherLabelRowReceiptIsExact` — every marker-equality `since` is now `1_760_300_000.25`; red in `12a66e33`, green in `3663b24f`; `oldReceiptShapeReversesLabelOnly` keeps the whole-second shape loading |


## Closed

Closed by `8fe7f753` at 2026-10-15T00:17:31Z. Closure merged to main 8fe7f753: P2-1 fixed (receipt records the real post-state), P2-2(a) fixed (refuses while a scan runs) / (b) declined (allowlisted rescan carry-over), P3 fixed (fractional seconds); 61 tests.
