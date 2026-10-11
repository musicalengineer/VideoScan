# Diagnosis: "978 GB in Trash" and the "never under 7" volume total, 2026-10-10 (night)

Diagnose only: no code edits, no catalog writes. Inputs, all read-only:
`catalog.json` (saved 20:05, 13,796 records), `~/Library/Logs/VideoScan/{videoscan,catalog}.log`,
`deletions/*.csv`, `ledger/media-ledger.jsonl`, the `Rick-Breen.VideoScan` prefs plist, and `ls` of
`/Volumes/*/.Trashes/501`. The running app is `v5.1 (debug) · main @ 4e3210e5` (videoscan.log:63483),
which is current main, so the code read here is the code Rick was running. No build was needed.

---

## 1. "The app says there's 978 GB in Trash"

### 1a. Which UI shows it

**No UI anywhere adds up `lifecycleStage == .trashed` bytes.** I grepped every reader of `.trashed`,
`"Trashed"`, `LifecycleStage.allCases` and `lifecycleStage` grouping. The only non-engine reader is
`CatalogAudit.swift:271`, a count. No code reads a real Trash either: `.Trashes`, `~/.Trash` and
`trashDirectory` never appear outside the scan skip-lists. So the manager's 1.43 TB "Trashed"
population is not what Rick saw.

What he saw is almost certainly the **honesty caption under the TOTAL CATALOG footer**:

- Text: `CatalogStorageTotals.swift:573-580` gives `"+ \(X) marked deleted, still on disk"`.
- Rendered by `VolumeTableTotalsFooter.swift:271-283`, directly under the volume table.
- Query: `CatalogStorageTotalsCalculator.manuallyDeletedProbes` (`CatalogStorageTotals.swift:401-414`)
  and `manuallyDeletedOnDisk` (`:422-433`), run off-main by `scheduleManuallyDeletedProbe`
  (`CatalogView+ScanTargetsPane.swift:281-300`).
- Filter: active records (not purged, not set aside, not superseded) with
  **`archiveStage == .manuallyDeleted`**, `sizeBytes > 0`, on a reachable scan-target volume, whose
  file **exists** (`stat`).

Recomputed from catalog.json: **968 such records, 986 GB metadata. 967 are on online volumes and
959 files exist, totalling 976.0 GB** (SanDiskWorkspace 573.8 GB, LaCieWorkspace 360.2,
FamilyArchive 42.0). Rick reported 978. The LaCieWorkspace rescan at 20:05 rewrote records after he
looked, which would account for a 2 GB difference. The metadata hedge (986 GB) and the Trashed totals
(1.43 TB / 1.41 TB gone / 16.4 GB live) are all further from 978.
**Confirm with Rick:** the tooltip on that footer row says
"Not counted above: N records marked Manually Deleted (…) — X still on disk".

**Why it says "deleted" when nothing was deleted.** `.manuallyDeleted` is an ArchiveStage, not a
lifecycle stage. It is written only by Migrate/Reconcile: bucket B at `VideoScanModel+Relocate.swift:366`
("source file not found") and bucket E at `:402` ("safely redundant", catalog-only). The file is never
touched. The notes on these records read `Reconcile 2026-05-31…/2026-08-17…: reason=dup-on-other-volume
witnesses=[/Volumes/InternalRaid/…, /Volumes/MyBook3Terabytes/…]`.

The caption's wording ("marked deleted") reads as "in the Trash". It is not. These are **live,
untouched files on Rick's working drives**.

> **Data-risk observation (not a fix):** the witnesses for those 959 live files are on retired or
> shelf drives. InternalRaid has 0 records in the catalog, and MyBook3Terabytes is not even a scan
> target. So the catalog cannot prove that a second copy exists, yet the footer subtracts these
> 976 GB from TOTAL and UNIQUE. Before any engine ever treats `.manuallyDeleted` as "safe to remove",
> this needs Rick's ruling (the dup-keeper rule: "never elect offline drives").

### 1b. Every way a record reaches `.trashed`

| # | Path | file:line | Disk op? | Notes |
|---|------|-----------|----------|-------|
| 1 | Junk / Catalog ⌘⌫ / Excess Copies / Prune Apply / Archived-what-next (all via `deleteConfirmedJunk(_:mode:)` → `applyJunkOutcomes`) | `VideoScanModel+JunkDelete.swift:327-329` (`.moved`) | **Yes**, `trashItem` at `:479` | The resulting path is returned (`:480`) and written to the receipt CSV only |
| 2 | Same routine, outcome `.missing` | `VideoScanModel+JunkDelete.swift:323-326` | **No** | Stamped `.trashed` although nothing moved. The file was already gone |
| 3 | Workbench Discard | `VideoScanModel+Workbench.swift:91-93` | Best effort | `if (try? trash(url)) != nil { … }` and then **stamps `.trashed` + `purgedAt` even when trashItem threw**. The file can still be on disk and labelled Trashed (a swallowed error, the "no try?" rule) |
| 4 | Delete Duplicates | `VideoScanModel+Duplicates.swift:826-827` | Yes | The row is **removed from `records`** (`:810-815`), so no lingering Trashed record |
| 5 | Catalog Audit "Fix stages" | `CatalogAuditFixer.swift:22-29` (offered by `CatalogAudit.swift:271`, `:399-409`) | **No** | Relabels **any** purged record as `.trashed`. That covers Remove-from-Catalog (`SoftDelete.swift:73-74`), missing-on-disk auto-purge (`CaptionOrchestrator+Activity.swift:141-144`), Archive Angel companions (`ArchiveAngelCompanions.swift:179`) and dangling/dedup purges |
| 6 | Rescan preservation | `VideoScanModel+RescanPreservation.swift:497-505` (snapshot keyed by **fullPath**), `:441`, `:446` (apply) | No | A **returning file at the same path** (Put Back, or a new file with that name) gets the old `purgedAt` and `.trashed` re-stamped on the fresh probe |

Related: `restoreRecord` and `undoLastPurge` (`VideoScanModel+SoftDelete.swift:117-160`) clear
`purgedAt` but **leave `lifecycleStage == .trashed`**, so a restored row still says Trashed.

**Pending relabel:** 283 purged records still carry a live stage (Cataloged 190, In Triage 63,
Archived 30 / 199 GB). The next "Fix stages" click (#5) relabels all of them as Trashed.

### 1c. Is the Trash location recorded? Is anything reconciled against the real Trash?

- **Location:** only in the new per-run receipt CSV (`DeletionAudit.swift:37`, `:44-47`, column
  `trash_path`; the files in `deletions/` start today, 10-10) and in log lines (`moved … → …/.Trashes/501/…`).
  The `VideoRecord` has **no** trash-path field. The Media Ledger `copyTrashed` events carry only
  `{mode, volume}` (585 events, none with a path). Delete Duplicates keeps only the volume name
  (`DeleteDuplicatesPlan.swift:694`, `trashedOnVolume`).
- **Reconcile:** **none.** Nothing checks whether a `.trashed` file is still in a Trash, was emptied,
  or was put back. `RelocateReconcile.swift:358-361` only excludes `.trashed` rows.
- **Live check tonight:** `SanDiskWorkspace/.Trashes/501` is empty (mtime 20:01) although `demo.mov`
  (1.07 GB) was moved there at 20:01:14. Rick emptied it, or put it back, at once. LaCieWorkspace's
  Trash is empty (mtime 17:11). CrucialX9 holds one 803 MB file (Donna_compilation…mp4, trashed 10/9,
  not a catalog record).

### 1d. Classification of all 1,319 "Trashed" records

Script (read-only): `/private/tmp/claude-501/-Users-rickb-dev-VideoScan/8562e4d1-ff42-4e46-b1b8-94e04b855380/scratchpad/classify.py`.

| Class | Files | Bytes | Evidence |
|-------|------:|------:|----------|
| **Gone, a real Trash move, Trash since emptied** | 495 | 1,411.2 GB | Ledger `copyTrashed mode=trash` for every one. File absent at the original path. Mostly 09-22 (30 files, 1.01 TB) and 09-23 (429). Includes 27 sources of archive masters (833 GB, e.g. Franklin_1990_P216_2.mkv 254 GB). The archive copies exist |
| **Gone, never moved by us** | 142 | 3.4 GB | No ledger line. 09-11 (128 iMovie `Cache-*.mov`): catalog-only purge, later gone from disk |
| **Still at the original path (682 / 16.4 GB):** | | | |
| Catalog-only purge of a live file, Photos library internals | 587 | 1.73 GB | 08-06 22:49:41 and 22:50:00 (two batches). Every one is under `…/Photos Library.photoslibrary/resources/media/master/…` on SanDiskWorkspace (541), LaCieWorkspace (26), CrucialX9 (9). Never trashed. **They must never be revived into delete pools** |
| Catalog-only purge, other | 95 | 14.7 GB | 07-20 (12: ffprobe-failed/corrupt, 6.3 GB), 07-22 (39 GuitarSlices `.wavRegion` audio), 07-25 (11, incl. 4 suspected-junk m4v, 5.3 GB), 08-03 (13), 08-18 (10 `.m4p`) and a few more. No ledger line, same size, birthtime before the purge |
| Put Back (proven) | **0** | | No live file has a `copyTrashed` ledger event, and none was born after its purge or changed size. ctime is useless as a Put-Back signal, because the Finder-tag daemon (findtagd) rewrites xattrs |
| New file at the same path | **0** | | No size mismatch and no post-purge birthtime |

Caveat: the ledger starts 2026-09-15 and the logs rotate, so a pre-09-15 Trash move followed by a
Put Back cannot be ruled out for the 95 "other" rows. The 587 are certain.

Example paths:
- Photos library: `/Volumes/SanDiskWorkspace/…/Pictures/Photos Library.photoslibrary/resources/media/master/04/00/…mov`
- Other: `/Volumes/Projects/osx10.8_backup/rickb/Music/GuitarSlices/GuitarIntro12secs.wavRegion 01`, `/Volumes/Projects/osx10.8_backup/rickb/Music/02 Heaven.m4p`
- Gone/ledger: `/Volumes/MediaExpansion/Converted_VHS_Tapes_2026/Misc1990/Franklin_1990_P216_2.mkv`

### 1e. Proposed fix design

Rules it keeps: Trash-only, the app never empties the Trash, and the delete-safety principle.

**F1 (low risk, UI only). Say what the 976 GB is.** Reword the caption at
`CatalogStorageTotals.swift:573-580`, for example "+ 976 GB set aside by Migrate as redundant — files
untouched on disk". Add a **Show in Catalog** affordance (a filter) for it. No Empty button. Do the
same pass on the tooltip at `:627-634`.
→ `qa` plus Rick's eye. No /safety-critical needed.

**F2 (medium, catalog schema, additive). Split the meaning of "Trashed".** Add one field rather than
more enum cases, for example `removal: RemovalState?`:

- `.inTrash(path, volumeUUID, at)` — "Moved to Trash (file is in a Trash)". Written only by paths #1
  and #4, from `resultingItemURL`.
- `.catalogOnly(at, reason)` — "Removed from catalog (file untouched)". Written by SoftDelete, Tidy,
  auto-purge, the Audit fixer (#5) and Workbench when trashItem threw (#3).
- `.gone(at, how: emptied | missing)` — "Gone (Trash emptied / file missing)". Written by path #2 and
  by the reconcile.

Keep `lifecycleStage` for back-compat. Old builds on the M1/M5 fleet decode an unknown enum raw value
badly, so **avoid new `LifecycleStage` cases**: that is an escalation item ("schema changes → ask
Rick"). Backfill from the evidence in 1d (ledger copyTrashed → `.gone(emptied)` or `.inTrash` once
reconciled; the rest → `.catalogOnly`). The backfill writes catalog metadata only.
→ Additive field: Rick sign-off, then `qa`.

**F3 (medium). Cheap reconcile** on catalog load and on volume mount, off-main, one `stat` per
`.inTrash` / `.catalogOnly` record on mounted volumes (about 1.3k today). Same shape as
`scheduleManuallyDeletedProbe`.
- Trash path exists → still in the Trash.
- Trash path gone and the original path is absent → `.gone(emptied)`.
- Original path exists with matching size and partial MD5 → **Put Back candidate** (do not
  auto-revive, see F5).
It writes stage metadata only and never moves a file.
→ `qa`, plus a poisoned-state test (isolation dimension).

**F4 (low). An honest Trash surface.** For example "In the Trash: N files, X GB on SanDiskWorkspace,
LaCieWorkspace — **Open Trash in Finder**". `NSWorkspace.shared.open` on the volume's
`.Trashes/<uid>` or `~/.Trash`, or `activateFileViewerSelecting` the recorded trash paths. **There
is no Empty button, ever.** "Gone (emptied)" is shown as history in File Journey, not as a size.

**F5 (data-risk, needs /safety-critical). Revival of Put-Back files.** When F3 finds a file back at
its original path with the same bytes, offer **Restore to catalog** (one click, a batch with a
preview). Do not auto-restore. Restoring re-admits files into the Delete-Duplicates, Excess and
Prune candidate pools, which is the delete-safety boundary. Exclude `.catalogOnly` rows from the
offer (the 587 Photos-library internals). Restore must also reset `lifecycleStage`, which fixes the
`restoreRecord` gap. The rescan carry-over (#6) should then carry the *verdict* by content key (the
"returning content inherits its verdict" ruling) but must not claim "in Trash" for a file it just
probed on disk.

**Bug fixes to bundle under F2. Separate dispatches, one bug each:**
- B1 `VideoScanModel+Workbench.swift:91-93`: a failed trashItem must not stamp `.trashed`. Hold the
  row and log the error, the way JunkDelete's `.failed` does. **Data-integrity: /safety-critical.**
- B2 `VideoScanModel+JunkDelete.swift:323-326`: `.missing` → `.gone(missing)`, not `.trashed`.
- B3 `CatalogAuditFixer.swift:24-25`: relabel to `.catalogOnly`, not `.trashed`.
- B4 `VideoScanModel+SoftDelete.swift:117-160`: restore resets the stage.

---

## 2. "In the main catalog view, where the totals are shown under volumes, I can never get under 7 GB"

### 2a. What number it is

The row under the volume table is `VolumeTableTotalsFooter` (`CatalogView+ScanTargetsPane.swift:900-903`).
It shows **TOTAL CATALOG** (gross), **ONLINE** (hidden when it equals gross, as it does tonight),
**UNIQUE**, **ARCHIVED**, and the caption from §1.

Nothing on that row is around 7 GB. **TOTAL CATALOG is 7.85 TB (7,495 files)**, recomputed with the
calculator's own population: `partition` at `CatalogStorageTotals.swift:460-469` (not purged, not set
aside, not superseded, not Manually Deleted). Reading "7GB" as **7.x TB** is the only fit; confirm
with Rick. The one ~7 GB figure in the footer is the **Junk** line inside its tooltip: 6.57 GB, of
which 94 Suspected Junk files are 6.56 GB, plus 38 Confirmed Junk records at 4.9 MB that are all
missing on disk. Delete Junk only moves *Confirmed* junk, so that line cannot fall below about
6.6 GB until the suspected ones are confirmed. If Rick meant the junk line, that is the reason.

### 2b. Why TOTAL CATALOG won't go below 7

Hypotheses tested:

| Hypothesis | Verdict |
|---|---|
| Counts purged / "Trashed" records | **No** for the footer: `partition` drops `isPurged` (`:465`). **Yes for the per-volume Media Size COLUMN**, see 2c |
| Counts audio-only / A/V halves | Negligible: audio-only is 2,754 files but **36.5 GB**. Pair-linked exact-dup extras: 1,029 files, 335 GB, held by the Combine rule |
| Stale cache (VolumeStatusCache) | **No.** The footer is not fed by VolumeStatusCache. It recomputes on every `catalogMutationRevision` bump (`CatalogView+ScanTargetsPane.swift:931`) |
| The number is right and the rest is legitimately held | **Yes**, see below |

**Composition of 7.85 TB** (counted population):

| Bucket | Files | Bytes | Removable? |
|---|---:|---:|---|
| FamilyArchive (the Master Archive itself) | 659 | 3.13 TB | **Never.** Archive is read-only |
| Workspace copies of archived content: 29 promoted sources (405 GB) + 365 same-bytes-in-archive (598 GB) | 394 | **1.00 TB** | Yes, Tier 1 (Excess Copies / Archived — what next, byte-verified). By drive: MediaExpansion 334 GB, LaCie 242, CrucialX10 177, Projects 106, SanDisk 75, CrucialX9 55, ~/Movies 13 |
| Exact-dup extras among workspace drives, beyond one keeper | 2,674 | **0.94 TB** | Partly. SanDisk 720 GB, Projects 193, LaCie 21. Of this, 335 GB are A/V pair halves. The last Delete Duplicates runs held most of the rest with "only two copies — not pre-selected" (289 files, 207 GB) and "only the keeper on Projects would remain" (15, 107 GB). Also 3 refused as "content differs" (58 GB) |
| Keepers of those dup groups | | ~0.88 TB | No, these are the keepers |
| One-of-a-kind, not yet archived | 1,178 | **1.91 TB** | No. They need **Promote**, not Delete |

The **floor** is therefore about **3.13 (archive) + 1.91 (unique, not archived) + 0.88 (dup
keepers) ≈ 5.9 TB**, even after every provable copy is gone. Getting under 7 TB means removing more
than 0.85 TB of the roughly 1.94 TB that is removable in principle. That takes the Tier-1 archived-copy
removal (1.0 TB, mostly MediaExpansion, LaCie and CrucialX10), not junk or dup clicks: today's runs
moved GBs against a 7.85 TB total, which barely moves the display. **This is not a bug; the number
is right.**

### 2c. A real bug next to it: the per-volume Media Size column

`recomputeVolumeAggregates` (`CatalogView+ScanTargetsPane.swift:223-238`) sums `sizeBytes` over
**every** record under the prefix: purged, set aside, superseded and Manually Deleted included (the
`fullPath` OR `originalFullPath` match is documented as intentional). So **trashing a file never
lowers its volume's Media Size**:

| Volume | Column shows | Not purged / not set aside |
|---|---:|---:|
| SanDiskWorkspace | 2.02 TB | 1.75 TB |
| LaCieWorkspace | 3.02 TB | 2.55 TB |
| Projects | 1.72 TB | 1.24 TB |

The column sums to about 13.4 TB against a footer of 7.85 TB. If Rick watches a volume row while he
deletes, it really is stuck. The fix is to apply the footer's `partition` (or `pfActiveRecords`) to
`mediaBytes` and `files`, which is a low-risk display change. `CatalogView+VolumeTable.swift` is
under the night refactor agent, but the bug lives in `CatalogView+ScanTargetsPane.swift:238`, so it
can be fixed there. `buildCatalogInfo` (`ContentView.swift:1510`) has the same omission for ⌘I
"Media Size".

---

## Risk summary

| Item | Risk | Gate |
|---|---|---|
| F1 caption wording + Show-in-Catalog | Low | qa |
| 2c volume column excludes tombstones | Low | qa + scale test (100k) |
| F4 Open Trash in Finder (no Empty) | Low | qa |
| F2 removal-state field + backfill | Medium (catalog schema, additive) | **Rick sign-off** (escalation rule) |
| F3 reconcile on load/mount | Medium (catalog writes, no file ops) | qa + isolation test |
| B1 Workbench stamps Trashed on failed trash | Data-integrity | **/safety-critical** |
| F5 Put-Back revival into delete pools | Data-risk | **/safety-critical** + codex candidate |
| `.manuallyDeleted` live files with uncatalogued witnesses (976 GB) | Data-risk (ruling) | **Rick ruling** before any engine acts on it |
