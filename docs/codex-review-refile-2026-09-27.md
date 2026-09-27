# Codex review — Refile

- Range: `db083e71..765c0351`
- Credits spent: unavailable
- Tokens: 97983
- Finding count: 5
- Verdict: merge-after-fixes
- Run: 2026-09-27T17:39:06Z (cycle #1, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 5
Verdict: merge-after-fixes

1. **P1 — Concurrent writes can disappear.** `ArchiveIndexRename.swift:299` checks identity separately from publication; rollback at `:333` overwrites originals without checking intervening writes. `VideoScanModel+ArchiveRefile.swift:356` checks Promote activity only before the asynchronous engine call. Counterexample: append another promotion’s manifest row after the final identity check; Refile publishes its older snapshot, silently dropping that row while the promoted file remains. **Pin:** inject the append inside `indexPublisher` before publishing; require preservation or refusal. Archive writers need shared transaction exclusion through rollback.

2. **P1 — A publisher that writes then throws escapes restoration.** `ArchiveIndexRename.swift:305` adds the file to `published` only after the publisher returns. Counterexample using the supported seam: publish the updated manifest, then throw. Rollback receives an empty `published` list, moves the media back, deletes the backup, and reports rollback success—manifest and disk disagree. **Pin:** publish-then-throw on both the first and second index files; require byte-identical restoration. This establishes a seam-contract defect; the out-of-scope `AtomicFilePublish` implementation’s failure guarantees were not inspected.

3. **P1 — Failed move-back can leave the catalog identifying another file.** `VideoScanModel+ArchiveRefile.swift:414` updates the record only when the old path is absent. Counterexample: after the forward move, another writer creates a different file at the old path; verification fails and exclusive move-back returns `EEXIST`. Both paths exist, so the catalog still points to the replacement, while the archived original remains at the destination. **Pin:** create that blocker during destination hashing, then return a mismatch; require identity-based catalog reconciliation and preservation of both files.

4. **P1 — Rollback durability failures are discarded.** `ArchiveRefile.swift:810` ignores both directory `fsync` results after moving back. Counterexample: forward directory flushing fails; rollback rename succeeds, but its directory flushes also fail. The engine reports `.rolledBack` and the backup is removed despite unconfirmed durability. A subsequent crash can leave disk inconsistent with the restored index. **Pin:** inject rollback-directory flush failures; require an explicit incomplete-recovery outcome and retained backup.

5. **P2 — Step (e) failure still returns success.** `VideoScanModel+ArchiveRefile.swift:478` logs a failed catalog save and schedules a retry; `:485` queues the ledger append without awaiting persistence, then `:399` reports success. Counterexample: catalog storage stays unwritable and the app exits before retry; the persisted catalog retains the old path. This violates the approved “any failure → rollback” contract. **Pin:** fail catalog persistence and ledger persistence independently; require recovery or an explicit incomplete outcome, never unconditional success.

Read, no findings in the scoped changes to: `ArchiveVolumeProtection.swift`, `MasterArchive.swift`, `PromoteToArchiveJob+Steps.swift`, `ArchiveRefileSheet.swift`, `ArchiveView.swift`, `ArchiveView+Table.swift`, `ArchiveView+Categories.swift`, `InspectorPanel.swift`, `CatalogHelpers.swift`, `VideoScanModel.swift`, `VideoScanModel+MediaLedger.swift`, `MediaLedgerEvent.swift`, and `LedgerNarrator.swift`.

Specified tests read for coverage gaps. Findings are static counterexamples; no builds or tests run, and no files changed.

## Brief

Adversarial review, SCOPED to the Refile feature: commits db083e71..765c0351 on branch feat/archive-refile (4 commits: 7debb3e6 feature, 56580713 narrator split, 7b9441c7 tests, 765c0351 lint). Use `git diff db083e71..765c0351` and `git show <sha>`. Do not explore outside these files; read-only; do not build or run.

WHY: Refile MOVES an already-archived file inside the Master Archive (FamilyArchive — the family's near-read-only master copy) to the folder its corrected date says, and rewrites the archive's 00_Index manifest and journals. A lost file, a duplicated file, or a manifest that disagrees with disk is the failure that matters. Rick's approved order: (a) refuse before any mutation — target exists, archive read-only/offline, source digest ≠ manifest digest; (b) same-volume rename, never copy + delete; (c) verify the file at the new path against the manifest digest; (d) update the manifest row under a backup taken with the GH #204 marker machinery; (e) ledger event + catalog record; (f) any failure → move back, restore the manifest from the backup, log it, say so.

PRODUCTION FILES IN SCOPE (exactly these):
- VideoScan/VideoScan/ArchiveRefile.swift (new) — `ArchiveRefile` (placement via ArchivePathResolver.baseRelativePath, Misfiled rule, Why line, `rewriteManifestRows`) and `ArchiveRefileEngine.execute` / `moveAndVerify` / `moveBack`.
- VideoScan/VideoScan/ArchiveVolumeProtection.swift — appended `ArchiveRefileAuthorization` (private init, `grant`, `covers`).
- VideoScan/VideoScan/VideoScanModel+ArchiveRefile.swift (new) — Misfiled refresh (sliced main-actor capture + `@concurrent` manifest read), `makeRefilePreview`, `refileArchiveCopy` (main-actor refusals, grant, engine hop, `applyRefiled`, rollback ledger), `archiveRelPath` fast path.
- VideoScan/VideoScan/ArchiveIndexRename.swift — `csvCells` / `csvDecode` / `splice` made internal (no behaviour change); Refile reuses `readIndexFile`, `prepare`, `apply` (backup → recheck → move → publish → rollback), `livePublish`.
- VideoScan/VideoScan/MasterArchive.swift — `ArchivePathResolver.filingYearRefusal` / `latestFilingYear`; README text.
- VideoScan/VideoScan/PromoteToArchiveJob+Steps.swift — the guard call in `copyOrAdopt`.
- VideoScan/VideoScan/ArchiveRefileSheet.swift (new), ArchiveView.swift, ArchiveView+Table.swift, ArchiveView+Categories.swift, InspectorPanel.swift, CatalogHelpers.swift, VideoScanModel.swift (two stored properties), VideoScanModel+MediaLedger.swift (refresh on date edit) — UI wiring.
- VideoScan/VideoScanCore/Sources/VideoScanCore/MediaLedgerEvent.swift (+refiled, +refileRolledBack, +from/to/provenance keys), LedgerNarrator.swift (sentences; two sentence groups moved to helpers, same text).
Tests (read for coverage gaps, not style): VideoScanTests/ArchiveRefileTests.swift, ArchiveRefileScaleTests.swift, ArchiveRefileSensorTests.swift, the `reviewedNoClobberRenames` addition in ArchiveVolumeProtectionTests.swift.

INVARIANTS TO ATTACK:
1. The file is never lost or duplicated. The move is ONE `renameatx_np(..., RENAME_EXCL)` between dirfds opened through the O_NOFOLLOW chain; there is no copy, no unlink; every failure after the move renames back (in `moveAndVerify` for (b)/(c) failures, via `undoMoveMedia` for (d) failures). Look for: a path where the rename succeeded but `moved` is not set before a throw; a failure between rename and fsync; the move-back itself failing (is that reported as mixedState with every path, and does the model point the catalog record at where the file IS?); a symlink or a case-insensitive twin at the target; EXDEV; a concurrent Promote/rename/refile creating the target between the existence check and the rename; the target folder created by mkdirat and left behind.
2. The manifest never disagrees with disk. Row-targeted rewrite (relpath, record_date, date_confidence) + journals' exact old-path values, all prepared in memory, backed up with the #204 marker, identity-rechecked before and during publish, restored byte-for-byte on any publish failure. Look for: a publish that lands after the file moved back; `changedLines != mine.count`; several manifest rows for one relpath with one digest; a manifest append (Promote) between `readIndexFile` and publish (the recheck window); the journal rewrite touching a value that is not this file (exact-value collisions, the `filename` sibling rule); the rolled-back case leaving a non-complete backup folder or pruning a complete one.
3. Nothing outside the Refile path can write to FamilyArchive. `ArchiveRefileAuthorization` has a private init; `grant` is called once (the model) and refuses anything not between two media buckets of this root; `execute` re-checks `covers`. Look for: another caller able to construct or reuse a grant (Equatable/Sendable copies, a stale grant replayed for a different move), a grant for 00_Index or 40_Family_Tree via `..`, `//`, or a non-standard root spelling, and whether the no-clobber rename inventory in the sensor could miss a new mover.
4. The target always comes from Promote's placement function. `ArchiveRefile.targetRelPath` → `ArchivePathResolver.baseRelativePath(facts:title:)`; the filing-year guard is the one `filingYearRefusal` for both Promote and Refile. Look for: a place where the sheet's shown "To" and the executed target can differ (name trimming, empty name, the date-prefix strip in `currentName`), the Misfiled rule reading the archive filename's typo'd year (it must use the ORIGINAL's filename), and whether a sheet edit can produce a target outside the media buckets.
5. Refusals happen before any mutation. Order in `execute`: grant → root open → read-only → containment → manifest read/parse → target on disk and in manifest → source present → source digest → index plan; only then `apply` (backup) and the rename. Look for: any write (mkdirat, backup folder, ledger line, catalog record) before a refusal returns; model-side refusals (read-only viewer, identity mismatch, Promote writing, catalog moved, guard, same place) after the grant's audit line (that line is a log line, not a mutation — confirm nothing else happens).

EVIDENCE (M4, Debug, derivedData /private/tmp/dd-refile):
- `xcodebuild test -only-testing` by SUITE at 765c0351: 260 tests in 46 suites passed — the 7 Refile suites (logic 11: happy path; target exists → refused, nothing moved; source digest mismatch → refused; read-only → refused; failure injected at (c) and at (d), and at (d) on the SECOND index file → file back at source, manifest + journal byte-identical, ledger `refileRolledBack`; user edits year + name; Refile guard 1884 / next year + 1; grant coverage; grant refusals — pure 5 incl. the exact Why line "You dated this 1984 (known) on 25 Sep 2026; it was filed on 1 Sep as 1884."; Promote guard end-to-end; mov/mp4/mkv names ×3; isolation 3: poisoned / absent manifest → Misfiled empty + logged, Refile refuses; scale 2; sensor 5) plus every Master Archive, archive-volume-protection (incl. the new no-clobber rename inventory), rename-backup, catalog-rename-index, Family Music and media-ledger suite.
- Scale (Debug): Misfiled rule over 100k candidates 2.6 s off-main; one main-actor capture slice (2,000 copies) 50 ms; whole refresh over 100k archived records 8.7 s (off-main except the yielding slices); 200k badge reads O(1).
- `swift test` VideoScanCore MediaLedgerEventTests + LedgerNarratorTests: 16 passed.
- Not run: the full ~5k battery; no UI click-through (no app launch on the M4).

OUTPUT (stdout, Markdown, under 600 words):
first line exactly `Credits spent: <n or unavailable> | Finding count: <n>`
then a line `Verdict: merge / merge-after-fixes / hold`
then findings, each with file:line, a concrete counterexample, and the test that would pin it.
