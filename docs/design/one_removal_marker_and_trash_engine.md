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
- `archiveStage .manuallyDeleted`: **legacy.** Load maps it to
  `removedFromCatalog(.legacyDeletedLabel)`. Only Migrate's Bucket B still writes it, beside its
  `missing(.missingAtMigrate)` marker. Clearing the 959 labels needs Rick's sign-off (959
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

The UI's "Restore" and "Show Removed" are unchanged: they read `isPurged`. The Show Removed row's
tooltip now names the state from the marker ("in the Trash since …", "removed from the catalog on
… — the file was not touched", "missing since …", "hidden by an old “deleted” label — the file was
never moved"). Turning Show Removed on runs `refreshTrashEmptied`, which does its stats off the main
actor.

**The move: `MediaTrash.move`.** This is the one call to `FileManager.trashItem`. A test host
routes it to a scratch Trash. Every Trash door reaches it:
- E1's disk turn;
- Delete Duplicates' `moveToTrash`;
- the verifier's default;
- `DerivativeOutputPublish`'s Replace.

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

DD keeps its resumable MFO job, its plan store and its copy-count facts. **Landed this shift:**
- the settle goes through `stampRemoval` (T4: the row is kept);
- the move goes through `MediaTrash.move`.

**Not landed (the next shift, a choice for Rick):** DD's per-file turn running inside E1's loop as
a `RemovalStep`. That moves the quarantine, the plan record between steps (crash recovery) and the
copy-count final verdict into the engine. Each of those is codex-hardened. So it should be its own
reviewed batch, not bolted on tonight.

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
| Workbench discard | `Catalog/VideoScanModel+Workbench.swift` `discardWorkbench` | **E1** (`reason: .workbench`, async). Its private disk turn is deleted; it keeps its viewer refusal and DeletionAudit |
| Archive Angel companion discard | `ArchiveAngel/Prepare/VideoScanModel+ArchiveAngelCompanions.swift` `.absent` | `stampRemoval(.missing(.angelCompanion))`, because the file is gone (ENOENT) |
| Caption orchestrator missing purge | `Media/CaptionOrchestrator+Activity.swift:143` | `stampRemoval(.missing(.missingOnDisk))` |
| Remove from Catalog (row, Music Triage, extensionless, what-next missing rows) | `MediaOps/VideoScanModel+SoftDelete.swift` `purgeRecords` | `stampRemoval(.removedFromCatalog(.userRemoved))` |
| Migrate skip / Bucket B | `MediaOps/VideoScanModel+Relocate.swift` `markSourceNotFound` | skip writes nothing. Bucket B → `stampRemoval(.missing(.missingAtMigrate))`, and it keeps the label for Retire |
| Retire's catalog cleanup (Forget volume records) | `Volumes/VideoScanModel+DeleteScanTarget.swift` `removeCatalogRecords` | **open question for Rick.** It stays a row removal: catalog repair with a confirm and a snapshot. Marking those rows instead would keep a rescanned volume hidden, because a rescan carries the marker |
| Transcode/Reformat replace | `MediaOps/DerivativeOutputPublish.swift` | an app-made output. The move is `MediaTrash.move` |
| Catalog audit fixer | `Catalog/CatalogAuditFixer.swift` | re-stamps an inTrash row's own marker. A removed or missing row is never "fixed" to Trashed |

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
