# Codex review — Cutover B2.3 veto + explicit purge

- Range: `282d539e6..49cb7794a`
- Credits spent: unavailable (metering not exposed)
- Tokens: 60133
- Finding count: 2
- Verdict: block** — at `ffa50845b`, F2 remains partially open and replacement records can lose saved curation.
- Run: 2026-10-18T04:26:16Z (cycle #103, tools/codex_review.py)

## Codex answer

Credits spent: unavailable (metering not exposed) | Finding count: 2

Verdict: **block** — at `ffa50845b`, F2 remains partially open and replacement records can lose saved curation.

- **B2.2 P1, marker veto — CLOSED.** [CatalogCommitter.swift:206](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/Catalog/CatalogCommitter.swift:206) refuses requested changes while held/blocked and requires an earlier dirty marker to commit before permitting another change. [VideoScanModel+RemovalMarker.swift:136](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/MediaOps/VideoScanModel+RemovalMarker.swift:136) honors that refusal before Undo changes anything. The original held Trash→Undo revision-gap reproduction is closed.

- **(e), rescan purge by inferred absence — CLOSED.** [CatalogCommitBaseline.swift:101](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/Catalog/CatalogCommitBaseline.swift:101) purges only explicitly requested, absent IDs. Unrequested absences are retained. The listed scan replacement and pruning paths now identify their purges explicitly.

- **F1, committed Trash Undo — CLOSED.** [GRDBCatalogRepository+Live.swift:72](/Users/rickb/dev/VideoScan/VideoScan/VideoScanCore/Sources/VideoScanCore/Store/GRDBCatalogRepository+Live.swift:72) updates lifecycle and removal-marker columns together. The subsequent audit-stamp UPDATE cannot produce the original intermediate CHECK violation.

- **F2, conflicting copy edits — OPEN, P1 for sets; scalar reproduction closed.** [CatalogCommitConflicts.swift:39](/Users/rickb/dev/VideoScan/VideoScan/VideoScanCore/Sources/VideoScanCore/Commit/CatalogCommitConflicts.swift:39) excludes tags and backup attestations. [GRDBCatalogRepository+Live.swift:238](/Users/rickb/dev/VideoScan/VideoScan/VideoScanCore/Sources/VideoScanCore/Store/GRDBCatalogRepository+Live.swift:238) deletes and replaces each shared set for each copy.

  **Failure scenario:** same-content copies A/B start with tags `{base}`; edit A to `{base,a}` and B to `{base,b}`, then save once: whichever copy occurs last wins, removing the other accepted addition from both the working catalog and reload. Both assertions survive in `row_knowledge`, but there is no conflict indication. Backup-attestation edits have the same defect: one copy’s removal can silently be reversed by another copy’s addition.

- **F3, snapshot-gated purges under SQLite — CLOSED for the reported dead doors.** [VideoScanModel+ScanMerge.swift:836](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/Volumes/VideoScanModel+ScanMerge.swift:836) selects the SQLite safety-copy path instead of the frozen JSON writer.

**New P1 — `placeRecord` purges destination curation without transferring it.** [VideoScanModel+CatalogPurge.swift:53](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/Catalog/VideoScanModel+CatalogPurge.swift:53) replaces the instance and purges its old ID without inheriting any curated fields. Balance Audio’s [landing code:753](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/MediaOps/BalanceAudioJob.swift:753) supplies only selected source fields, omitting the replaced destination’s notes, stars and tags.

**Failure scenario:** curate and save `clip_balanced.mov`, remove its file externally, then rerun Balance Audio on `clip.mov`; the available filename is reused, the curated ID is purged, and the freshly probed replacement reloads without those values.

The scoped mutation-shape search found **no additional missed purge door**. The `.diskFact` exception still requires an earlier dirty marker to commit; no new revision-gap reproduction was established.

[sealedCopyBlocking:498](/Users/rickb/dev/VideoScan/VideoScan/VideoScanCore/Sources/VideoScanCore/Store/GRDBCatalogRepository.swift:498) has no evident main-thread/writer wait cycle, but VACUUM blocks the UI throughout execution, including through `snapshotCatalogAsync`. There is no operation deadline or cancellation. A 200 MB run was not measured, so acceptable responsiveness is **unverified**.

**The accepted-edit durability guarantee is refuted:** both findings can hide accepted edits after successful saves without a crash or “Quit and lose N.”

Remaining scoped files/tests: **read, no additional confirmed P1 findings**. An in-memory replay of the extracted production tag SQL confirmed order dependence. App tests were inspected, not executed under the no-files constraint. No files written.

## Brief

# Codex brief: cutover B2.3 — marker veto, explicit purge doors, one-UPDATE Undo, copy conflicts, SQLite safety copies (2026-10-18 night; data-risk)

**Answer contract.** First line: `Credits spent: <amount> | Finding count: <N>`. A line `Verdict: <merge | fix | block> …`. Write no files; answer only. Under ~800 words.

**Your B2.2 pass:** `docs/reviews/codex/codex-review-cutover-b2-2-synchronous-commit-2026-10-17.md` (open: rescan purge by inferred absence; new P1: a failed marker pre-commit didn't veto). Plus three findings from the independent regression suite (`VideoScanTests/CatalogCutoverRegressionTests.swift`): F1 Undo of a committed Trash refused by a CHECK between two UPDATEs; F2 copies edited differently in one window → records order wins; F3 snapshot-gated purges dead under SQLite. **The fix:** merge of `8998e24bc` (range `282d539e6..HEAD`). Files under `VideoScan/`: app `VideoScan/Catalog/CatalogCommitter.swift` (`markerWillChange(_:kind:)`, `purge(ids:reason:)`), `Catalog/CatalogMarkerRelay.swift`, `Catalog/CatalogCommitBaseline.swift` (inference removed), `Catalog/VideoScanModel+CatalogPurge.swift` (`purgeCatalogRows`, `placeRecord`), `MediaOps/VideoScanModel+RemovalMarker.swift` (veto at every marker door), `Volumes/VideoScanModel+ScanMerge.swift` (purge calls; `snapshotCatalog` under SQLite), the purge doors listed in the agent's table (DeleteScanTarget, NonVideoMediaPurge, CoverArtMusicPurge, UnrelatedAudioPurge, MissingAudio, VideoScanModel.swift Delete All/Clear Results, VolumeRenameMigration undo, MasterArchive/BalanceAudio/MediaRepair/FootageFoldersSnapshot via placeRecord); Core `VideoScanCore/Sources/VideoScanCore/Store/GRDBCatalogRepository+Live.swift` (one UPDATE), `Store/GRDBCatalogRepository.swift` (`sealedCopyBlocking` VACUUM INTO), `Commit/CatalogCommitConflicts.swift`, `Commit/CatalogCommitBody.swift`; tests `VideoScanTests/CatalogCutoverB23Tests.swift`, `CatalogCutoverRegressionTests.swift`, `CatalogCutoverB22Tests.swift`, `OneEngineSensorTests.swift`.

**Do only this:** (1) CLOSED/OPEN with file:line for: the B2.2 P1 (veto), (e) rescan purge, F1, F2, F3. (2) at most THREE new P1 findings with a one-line failure scenario — focus: a door that removes records from memory but is NOT in the purge-door table (grep every `records.remove`, `records = `, `records.removeAll`, `records[i] =`, filter-reassign; the sensor only matches some shapes) → is the row resurrected at relaunch, or worse, lost?; `placeRecord` — does the new record inherit every curated value of the replaced id before the old id is purged?; the veto's "disk fact" exception (Trash of a file already moved while held) — can it write a revision the store then refuses?; `sealedCopyBlocking` on the main thread during a long VACUUM (a 200 MB db) — UI freeze acceptable vs a hang? Confirm or refute: after the flip, an edit accepted by the app is never lost except by a crash inside the 2 s debounce or an explicit 'Quit and lose N'.
**Do not explore outside the files listed above and their tests.**
