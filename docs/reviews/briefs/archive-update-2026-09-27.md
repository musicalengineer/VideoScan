Adversarial review of the WHOLE feature "Update… an archived file" on branch feat/archive-update: `git diff main...449b232f -- VideoScan` (it is a rewrite of the earlier Refile branch, simplified by Rick's ruling 2026-09-27 — review it fresh; the Refile review history is in docs/reviews/codex/codex-review-refile-2026-09-27.md for context only). Do not explore outside these files; read-only; do not build or run.

WHAT IT IS: right-click ▸ Update… on an archived file in the Archive window. Exactly two editable things: Name, and Date (year / month / day + known / estimated). The folder follows the date through Promote's own placement function (`ArchivePathResolver.baseRelativePath`); the user never picks a folder. Name-only keeps the folder; date changes move folders; both at once are ONE move; known/estimated alone updates the manifest row without moving the file. The date is written onto THIS archived record only (its userDate / confidence) plus the manifest row's record_date / date_confidence. If the catalog save or the ledger line fails AFTER the archive + index are updated, it is logged loudly and reported ("the archive is updated; the catalog will pick up the new path on the next scan") — no retry journal, no replay, by design.

PRODUCTION FILES IN SCOPE:
- VideoScan/VideoScan/ArchiveRefile.swift — pure layer (placement, labels, manifest reads, row-targeted manifest rewrite) and `ArchiveRefileEngine` (preflight / commit / failureOutcome, moveAndVerify, moveBack with identity checks, locateOriginal, seams). Internal names keep "Refile".
- VideoScan/VideoScan/VideoScanModel+ArchiveUpdate.swift — preview from the manifest row, main-actor refusals, grant, engine hop, `applyUpdated`, audit sink.
- VideoScan/VideoScan/ArchiveUpdateSheet.swift, ArchiveView.swift, ArchiveView+Table.swift — the sheet and the context-menu item.
- VideoScan/VideoScan/ArchiveVolumeProtection.swift — `ArchiveRefileAuthorization` (private init, `grant`, `covers`; from == to allowed for the index-only case).
- VideoScan/VideoScan/ArchiveIndexLock.swift (new) + its takers: ArchiveIndexRename.swift (`apply` holds it through backup → recheck → move → publish → rollback; touched-before-publish restore; `BackupDisposition` = retain the backup unless proven safe), MasterArchive.swift (manifest append; `filingYearRefusal`; README text), ArchivePromoteEngine.swift (journal append), ArchivePromoteDecisions.swift, VideoScanModel+BackupAttestations.swift, PromoteToArchiveJob.swift / +Steps.swift (filing-year guard; `finalizeBatch` async with off-main `done` appends; on main the lock is tried once, never slept on).
- VideoScan/VideoScan/VideoScanModel+Rename.swift (`RenameError: BackupDisposition`), MediaLedger.swift (`appendConfirmed`).
- VideoScanCore: MediaLedgerEvent.swift (+archiveUpdated, +archiveUpdateRolledBack, +from / to keys), LedgerNarrator.swift.
Tests (for coverage gaps): VideoScanTests/ArchiveUpdateTests.swift, ArchiveUpdateSafetyTests.swift, ArchiveUpdateSensorTests.swift, and the `reviewedNoClobberRenames` inventory in ArchiveVolumeProtectionTests.swift.

INVARIANTS TO ATTACK:
1. The file is never lost or duplicated: ONE `renameatx_np(RENAME_EXCL)` between O_NOFOLLOW dirfds, no copy, no unlink; every failure after the move renames back ONLY the archived original (identity-checked before and after) — otherwise mixedState naming both paths with the backup kept.
2. The manifest never disagrees with disk: row-targeted rewrite + journals' exact old paths, prepared in memory, #204 marker backup, identity rechecks, touched-before-publish byte-for-byte restore, all under the one 00_Index lock; unproven recovery keeps the backup (incompleteRecovery / mixedState).
3. Nothing outside Update can write to FamilyArchive: one `grant` call site, private init, `covers` re-checked; every 00_Index appender takes the lock; the no-clobber rename inventory.
4. The target always comes from Promote's placement function, and the filing-year guard (< 1900 / > next year, video only) is the one function for Promote and Update; the sheet's shown changes equal what executes (name trimming, empty name, the date-prefix strip in `currentName`, the known/estimated-only path).
5. Refusals happen before any mutation: nothing changed, read-only viewer, identity mismatch, Promote writing, catalog moved, guard, offline / read-only volume, target exists (disk or manifest), source missing, digest mismatch, index unreadable.
Also: THIS record only (no writes to the original), and the post-archive warning path is honest (never reports success when the catalog or ledger write failed).

EVIDENCE (M4, Debug, derivedData /private/tmp/dd-refile): at 449b232f, run by suite with `-only-testing`, 357 tests in 56 suites ran. 356 passed. 1 failed: `VerifyArchiveCopiesIsolationTests`'s real-App-Support snapshot. That test snapshots the real App Support tree, and the two files that changed during the run were written outside the tests: `manifest.sha256`, by Rick's own VideoScan app (running from his Xcode build during the run), and the team-channel SQLite `-shm` file. It fails the same way when run alone. The Update suites (Logic 12 incl. 3 container cases, Pure 4, Safety 7 incl. parameterized, Sensor 6) all pass; VideoScanCore MediaLedgerEventTests + LedgerNarratorTests 16 passed.

OUTPUT (stdout, Markdown, under 600 words):
first line exactly `Credits spent: <n or unavailable> | Finding count: <n>`
then a line `Verdict: merge / merge-after-fixes / hold`
then findings, each with file:line, a concrete counterexample, and the test that would pin it.
