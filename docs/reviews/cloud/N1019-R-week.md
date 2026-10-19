Brief: N1019-R-week | Source: main@8daeb186 | Wall clock: ~40 | Files read: 14
Finding count: 2 (REAL 1 / NEEDS-MAC 1 / NOISE 0)
Verdict: No P1/P2 in the week's data-risk merges I reached; the one post-codex change to a purge door (d1f36066) holds, and the new async volume-rename Undo has two small truth-of-words gaps.

## Scope and method

Theme R over everything merged on main 10-12..10-18 under the data-risk folders
(docs/guides/source_layout.md). About 60 first-parent merges touch those folders;
most went through one to five codex rounds that week. In the 45-minute box I put
**changes that landed after their codex pass closed** first, since no one has
attacked those yet:

1. `d1f36066`: `placeRecord` uncurated-row swap-and-purge (landed after f16ce239 closed the cutover codex cycles).
2. `c558d68c`: adversarial 10/18 #2 #3 #9 #10 (volume-rename Undo rewritten and made async; safety copy commits first; held-catalog Undo Remove; Reconcile Bucket B words).
3. `4ce05b52`: the batched id lookup behind the ledger's Angel attention lines.
4. `d45692d5`: Family Music removal (checked for removed persisted enum cases).
5. Cleanup "copies the archive already holds" lane (`983896fe`, `e006fc80`): only checked that nothing changed it after codex r1 (nothing did) and that it trashes through the Junk engine, which the 10/18 held-catalog tests cover.

Callees followed to settle findings: `CatalogSharedCurated` (Core/Commit),
`CatalogReplacedRecord.inherit/carriesCuration/describe`, `CatalogDDL.KnowledgeField`,
`RecordIDIndex.record(forID:)`, `VideoScanModel.clearRemoval`, `SQLiteCatalogLoader.LoadResult`,
`migrateRenamedVolume` (the forward apply step), `CatalogCommitter.commitBeforeSafetyCopy`,
`ContentView.withDuplicateAlerts` (the rename alert binding),
`CatalogView.volumeRenameNoticeButtons`, `registerPromotedCopy` / `registerOrphanPromotedCopy`,
`MediaRepairJob.catalogCopy`.

## Findings

### N1019-R-week-F1: P3 · REAL · `CatalogView.volumeRenameNoticeButtons` / `ContentView.withDuplicateAlerts`. Every Undo now logs a "Dialog DISMISSED (Not Now / Esc)" line first
`VideoScan/VideoScan/Catalog/CatalogView+VolumeTable.swift:956`, `VideoScan/VideoScan/App/ContentView.swift:1052-1058`, `VideoScan/VideoScan/Volumes/VideoScanModel+VolumeRenameMigration.swift` (`dismissVolumeRenameNotice`).

c558d68c made Undo `async` (it now opens the sealed SQLite copy), so the button became
`Task { await model.undoVolumeRenameMigration(notice) }`. Before this change Undo ran
synchronously and set `pendingVolumeRenameNotice = nil` before the alert's `isPresented`
binding was set to false. Now the Task has not run when SwiftUI dismisses the alert,
so the binding's setter still sees a non-nil notice and calls
`dismissVolumeRenameNotice(n)`. That writes `Dialog DISMISSED (Not Now / Esc)` to the
os log and `Volume rename: user chose Not Now …` to videoscan.log, then clears the notice.
The Undo Task then runs from its captured `notice` and logs UNDONE. Result: every Undo
leaves a log trail that says Rick chose Not Now and then Undo. For `.migrated` the
dismiss inserts no suppression, so the catalog is unaffected; it is the log telling a
story that didn't happen, which the log-format rule cares about.
(The same mechanism already applies to `.ask` → **Update**, which is async too. There the
dismiss also inserts the old path into `volumeRenameAutoSuppressed` just before the
migration it was meant to prevent. That predates this week, so I note it here and don't
count it.)

Guard looked for: a check in the setter for an in-flight Undo/Update, or the button
clearing the notice synchronously. Neither exists.

Smallest pinning test: a model-level test that calls the same sequence the alert does.
Run the Undo button's action body (or a model `beginUndoVolumeRename(notice)` that clears
`pendingVolumeRenameNotice` synchronously and then spawns the await), then the binding
setter `set(false)`, and assert the log sink holds no `chose Not Now` line. Fails today.
Fix shape: the button clears `pendingVolumeRenameNotice` synchronously before the `Task`,
and the same for Update.

### N1019-R-week-F2: P3 · NEEDS-MAC · `VideoScanModel.revertVolumeRenameRewrites`. A migrated record missing from the safety copy stays on the new path, and Undo still says "back to how it was"
`VideoScan/VideoScan/Volumes/VideoScanModel+VolumeRenameUndo.swift` (`revertVolumeRenameRewrites`, the `guard let old = before[rec.id]` line, and the `leftAlone == 0` message in `undoVolumeRenameMigration`).

Undo now reverts per record and only where the safety copy holds that id. A record that
is live in memory, under the old root and inside the UUID gate at migration time, but
absent from the copy, is rewritten by the migration and then skipped silently by Undo.
It isn't counted in `leftAlone`, because `leftAlone` only counts records the copy knows.
The scan target goes back to the old path, that record keeps the new path, and the
console says "the catalog is back to how it was before …".

When does memory hold a record the copy lacks? `commitBeforeSafetyCopy` returns nil (the
copy may be sealed) even when rows sit in `baseline.waiting`. Its own doc says such a
row "carries that row's last stored values". A **new** row the store refused at its first
commit has no stored values, so it isn't in the copy at all. Under catalog.json the
snapshot is written from memory, so this is SQLite-only.
NEEDS-MAC: whether a never-stored row can sit in `baseline.waiting` (as opposed to
`pending_rows`, which the loader does return as `heldIDs`) in practice. If it can't,
this is NOISE.

Smallest pinning test (`AdvVolumeRenameUndoSQLiteTests` style): migrate with one record
that the committer is made to refuse at its first commit. Undo. Assert that either the
record is back on the old path, or `revert.leftAlone == 1` and the message says one
record was left. Fix shape: count `before[rec.id] == nil` records under
`notice.newTargetPath` with an accepted volume UUID into `leftAlone` (or a separate
"not in the safety copy" count), so the words stay true.

## Checked and found sound (no finding)

- **`placeRecord` → `retire` uncurated branch (d1f36066).** `carriesCuration` looks only at the shared curated groups plus `setAsideReason`. It ignores the knowledge fields `archivedAt`, `archiveFixity`, `lineage`, `supersededByID`, `footageDecisions`, `repairConfirmedDate` and `mediaReportCard`, so I tried to find an archived or derived row that gets purged without being kept as history. Promote and orphan registration always set `starRating >= 3` and `.important` on the archive copy, so an archive row always "carries curation" and takes the history branch. Repair copies the user date and place, so a stale earlier Repair output is curated too. Output publishers never clobber, so a live row at a landing path is a stale row whose file has already gone. The purge is a tombstone (recoverable), and `commitBeforeReplacing` has already run, so an edit inside the debounce is durable. Worth noting for the Mac: the archive rows are safe only because of the star rule. A test that pins "an archived row with stars 0 at a landing path is kept as history" would make that explicit and not accidental. Not filed: no real caller produces that row today.
- **`RecordIDIndex.records(forIDs:in:)` (4ce05b52)** matches the single-id lookup: rebuild on count change, then hits from the map, then one scan for misses with first-match-wins on duplicates, then a rebuild if stale. The ledger loop still walks `recordIDs` in order and skips unknown ids exactly as before.
- **`undoLastPurge` (c558d68c #10)** moved from `returnToLive` to `clearRemoval`, which is the same call without the per-row log line. Refused rows stay in the batch, restored rows get the save, pair revalidation and ledger line, and the banner shows the first refusal. A row whose file is still in the Trash refuses on every press, but the words say why, and Dismiss exists.
- **Reconcile Bucket B (c558d68c #9).** `relocateManuallyDeleted` now counts only rows actually marked, the progress bar still advances, and refusals are said once on the console and in relocate.log.
- **Safety copy commits first (c558d68c #3).** `sqliteSnapshot` refuses the copy (and so the door) when the commit can't run, so it fails closed.
- **Family Music removal (d45692d5).** The only removed `String`-raw enum case is `ArchiveCategory.music`, held in `@State` and never persisted. The `familyMusic` field and the `.music` curated group stay, so catalogs still decode and the field is still committed.

## Not covered (time box)

In priority order for a later R night or the 10-26 row:
- `e72ec67e` rescan merge (live curated fields win at swap; codex #109 closed it)
- B2–B2.7 cutover write side (`f4fe64c1`, `31a5006a`, `f3900b36`, `49cb7794`, `4a91fdb7`, `87c84b89`, `b9625577`): five codex passes. A fresh-eyes read of `CatalogCommitter.commit` would still be worth it.
- Import to SQLite job and its quit path (`f883f3dc`, `aaff7a61`, `2f0312e2`, `069d5958`)
- Audit Catalog tier 0, the Missing marker (`b03c3ce6`…`4bf224de`, codex r1–r5)
- Show Again legacy marker (`1d41cdf0`, `8fe7f753`)
- Verify Catalog slice 1 (`e53468e2`)
- P0 archive doors (`53c71c59`, `9a5228dd`)
- Fingerprint Sound backfill (`5c31ad9c`)
- Event Analyzer removal rules (`c6625b21`, `5d827f74`)
- FamilyTree: no merges under FamilyTree/ in the window.
- Merges dated 10-12 and 10-13 (24 first-parent commits). I didn't read them separately: the path-filtered log for the window shows its first data-risk merge on 10-14.

## Blockers & environment

- The clone was shallow (one day of history). `git fetch --shallow-since=2026-10-09 origin main` fixed it, with no network problems.
- No other tools failed. Nothing was built or run: Linux cloud, read-only by brief.
