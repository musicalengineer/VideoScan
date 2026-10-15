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
