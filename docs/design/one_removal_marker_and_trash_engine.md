# One removal marker, one Trash engine (VideoScan 5.2 step 1, GH #143)

Rick's rulings 2026-10-11. Source: tab-charter audit §2a/§2b, T4/T5. Data-risk path: branch only,
codex pass at Rick's call. Paths are relative to `VideoScan/`.

## 1. The marker

`VideoScanCore/RemovalMarker.swift`, a value type stored on `VideoRecord.removal: RemovalMarker?`.
`nil` means live. Three states, built only through factories, so a bad combination can't be built:

| State | Fields | Meaning |
|---|---|---|
| `inTrash` | `since` (moved), `trashPath` (what macOS returned), `trashEmptiedSeenAt` | The engine moved the file to the Finder Trash. A later stat that finds `trashPath` gone records "Trash emptied" (`noteTrashEmptied`). |
| `removedFromCatalog` | `since` | The file is untouched on disk. The catalog hides the row. Restore is one click. |
| `missing` | `since` (noticed), `lastSeen` | The file vanished outside the app. |

Every marker carries a `reason: RemovalReason`, an open string key (≈ `Notification.Name`) with these
values: `junk`, `catalogTrash`, `duplicate`, `prune`, `workbench`, `copiesAdvice`, `angelCompanion`,
`userRemoved`, `missingOnDisk`, `volumeForgotten`, `legacy*`.

**Relation to the old fields:**
- `purgedAt` becomes **derived**: `get` returns `removal?.since`. It is still encoded, so an older
  build reading the file still hides the row. Its setter stays for the 91 test writers. `nil`
  clears the marker. A date with no marker becomes `removedFromCatalog(.unspecified)`. A sensor
  forbids production writers outside the engine.
- `lifecycleStage .trashed / .deletedPermanently`: a **legacy mirror**. The engine writes `.trashed`
  for `inTrash` so the ~40 readers keep working. `missing` and `removedFromCatalog` leave the stage
  alone. Restore puts `.trashed` back to `.cataloged` only when the file is back at its path (the B4
  rule, kept).
- `archiveStage .manuallyDeleted`: **legacy, read-only, never written again.** Load maps it to
  `removedFromCatalog(.legacyDeletedLabel)`. Clearing the 959 labels needs Rick's sign-off (959
  classification, §Prerequisite), so the label stays put and Retire keeps reading it unchanged.
  Restore clears it on the rows the user restores.
- `disposition`: unrelated. It is a verdict, not a "gone" state. It is untouched.

## 2. Load-time migration (pure, `RemovalMarker.migrated(...)`, run in `VideoRecord.init(from:)`)

| Stored on disk | → marker |
|---|---|
| `removal` present | kept as is |
| `purgedAt` + `.trashed` | `inTrash(since: purgedAt, trashPath: nil, reason: .legacyTrashed)` |
| `purgedAt` + `.deletedPermanently` | `missing(since: purgedAt, lastSeen: purgedAt, reason: .legacyDeleted)` (gone; no Trash URL) |
| `purgedAt`, any other stage | `removedFromCatalog(since: purgedAt, reason: .legacyPurged)` |
| no `purgedAt`, `.trashed` / `.deletedPermanently` (CatalogAuditFixer residue) | **no marker** (the row stays visible, so a stage with no purge is never newly hidden) |
| no `purgedAt`, `archiveStage .manuallyDeleted` | `removedFromCatalog(since: load time, reason: .legacyDeletedLabel)` |
| anything else | `nil` |

The ordering is safe for deletion: a newly hidden row leaves every delete pool and can't be counted
as a survivor, so the only-copy warnings get stricter, not looser. Retire counts every record in its
scope regardless of purge, and it keys on `archiveStage`, so it is unchanged.

## 3. The engine

**Catalog half: `VideoScanModel+RemovalMarker.swift`.** This is the only writer of `removal` and its
mirrors:
- `stampRemoval(_:_:)` writes the marker and the legacy mirror.
- `clearRemoval(_:)` is the Restore primitive. `returnToLive` calls it.

The UI's "Restore" and "Show Removed" are unchanged: they read `isPurged`. The Show Removed row
gains a state word ("In the Trash", "Removed from catalog", "Missing").

**Disk half: E1 `deleteConfirmedJunk(_:mode:guard:)`**, plus a new `reason:` parameter. I confirm
the audit's pick. E1 already has, per file and at the file's turn:
- the viewer refusal;
- the archive tree and volume gates, and the read-only drive gate, asked twice (batch, then at
  removal, by UUID);
- offline as distinct from missing;
- the `JunkDeletionGuard` (`authorize` on main, `beforeRemoval` off-main, immediately before the move);
- the outcome set moved/held/failed/missing/offline/cancelled, with exactly one outcome per file;
- `copyTrashed` ledger lines;
- the DeletionAudit receipt, through the lanes that build one.

Outcome → marker: `moved` gives `inTrash(trashPath)`. `missing` gives `missing(lastSeen: nil)`.
`held`, `failed`, `offline` and `cancelled` leave the row untouched. Logging stays in E1's one sink.

**Delete Duplicates' proof, argued.** The audit says "plug the byte proof into `beforeRemoval`".
That is right for the gates and the settle, but too weak for the move. DD's quarantine works like
this: rename into an owner-only directory, re-hash the full SHA-256 there, check ctime and identity,
put the file back, then call `trashItem`. That sequence closes the swap window between the hash and
the move. A `beforeRemoval(path) → String?` hook that hashes at the public path and then lets E1
trash it re-opens that window. So the engine's seam is a **removal step**:
`JunkDiskTurn.perform` today, which becomes `RemovalStep` with two implementations:
- `.trash`: `beforeRemoval`, then `trashItem`.
- `.quarantinedTrash(proof)`: `SignatureVerification.quarantine` + `deleteQuarantined(.trash)`.

DD keeps its resumable MFO job, its plan store and its copy-count facts. Its settle goes through
`stampRemoval` (T4: the row is kept). Its move goes through the step. This shift lands the
settle (T4). The step split is the next shift.

**MFO:** Delete Duplicates is already an MFO job. Delete Junk, ⌘⌫ and Discard stay sheet-driven,
but they write the same START/row/OUTCOME DeletionAudit lines. An MFO wrapper for E1 batches over
about 1 minute is listed as a follow-up.

## 4. Doors

| Door | file:function | Onto the engine |
|---|---|---|
| Triage Delete Junk | `MediaOps/VideoScanModel+JunkTrashSnapshot.swift` `trashConfirmedJunkSnapshot` → E1 | reason `.junk` |
| ⌘⌫ / Catalog Move to Trash | `MediaOps/VideoScanModel+TrashSelection.swift` → E1 | reason `.catalogTrash` |
| Prune / Archived what-next / Excess copies | `MediaOps/VideoScanModel+PruneApply.swift:739` → E1 | reason `.prune` |
| Delete Duplicates (Storage card, Steward, Copies & Advice) | `MediaOps/VideoScanModel+Duplicates.swift` `settleDeletedDuplicate` | `stampRemoval(.inTrash)`; **the row is no longer removed** (T4) |
| Workbench discard | `Catalog/VideoScanModel+Workbench.swift` `discardWorkbench` | `stampRemoval` now. Its private `discardTurn` duplicates E1's disk turn; it moves onto E1 once the call site becomes async |
| Archive Angel companion discard | `ArchiveAngel/Prepare/VideoScanModel+ArchiveAngelCompanions.swift:179` | `stampRemoval(.removedFromCatalog(.angelCompanion))` |
| Caption orchestrator missing purge | `Media/CaptionOrchestrator+Activity.swift:143` | `stampRemoval(.missing(.missingOnDisk))` |
| Remove from Catalog (row, Music Triage, extensionless, what-next missing rows) | `MediaOps/VideoScanModel+SoftDelete.swift` `purgeRecords` | `stampRemoval(.removedFromCatalog(.userRemoved))` |
| Migrate skip / Bucket B | `MediaOps/VideoScanModel+Relocate.swift:390` | skip already writes nothing. Bucket B's `.manuallyDeleted` → `stampRemoval(.missing(.missingAtMigrate))` |
| Retire's catalog cleanup (Forget volume records) | `Volumes/VideoScanModel+DeleteScanTarget.swift:317` | stays a row removal: catalog repair, with an explicit confirm (allowlist) |
| Transcode/Reformat replace | `MediaOps/DerivativeOutputPublish.swift:79` | app-owned output. Allowlisted; noted for the step split |

Row-removal allowlist (catalog repair, never "gone"): forget volume, Purge Non-Video Media, Cover-art
and Unrelated-audio purges, the MissingAudio probe-row rollback, scan-merge re-seen replacement,
clear-all. Scan merge's prune of *genuinely gone* rows keeps any row that carries a marker (#143 b).
Turning the active-gone prune into `missing` is a follow-up, because the tripwire semantics need a
design talk.

## 5. Tests and sensors

- Characterization of today's doors.
- Migration table, poisoned catalog, 100k load under a time budget, and round trip.
- T4 green.
- T5: `quarantineAndDelete` removed, and `deleteQuarantined` defaults to `.trash`.
- Sensors, by source scan with a reviewed allowlist:
  - `trashItem`/`removeItem` on media only in the engine files;
  - `records.remove*` only in the allowlist;
  - `purgedAt =` and `lifecycleStage = .trashed` writers only in the engine;
  - every `RemovalMarker.State` reachable from a door.

## 6. Risks

1. Migrating `.manuallyDeleted` hides 968 rows that were "active but labelled". They were already
   hidden from the catalog view and the Angel. They now also leave the footer caption, dup pools
   and witness sets. That is the safe direction, but the footer's "+X hidden" line disappears.
   Restore brings them back one at a time, with the label cleared.
2. Catalog JSON grows by one small object per removed row. An older build ignores the key (it reads
   `purgedAt`).
3. Rescan preservation now carries `removal`, not `purgedAt`. The path-reuse edge (#143 a) is
   unchanged.
4. The byte-identity golden (`CatalogStoreAsyncSaveTests`) changes for purged rows.
5. DD's move is still its own Trash call until the step split. The sensor allowlists it, by name,
   for one shift.
