# Archived-aware duplicate scrub — design note (2026-09-11)

Status: PROPOSED. Needs Rick's ruling on the three decisions at the bottom before any deletion code is written. The dry-run count ("Copies of archived media") ships first so the number is visible in Tidy Catalog.

## The problem, measured

- Catalog 2026-09-11: 11,431 active records, 10.69 TB. Rick's read: "9.x TB because it is counting the Archive and various cleaned/transcoded versions."
- 2,030 active records match a purged/set-aside record by filename+size, 0 at the same path, 2,008 on LaCieWorkspace: junk returns as another copy. (Solved separately by the content-keyed ignore list.)
- Rick's goal, in his words: archive the good stuff, delete the bad stuff, do not re-ingest junk, help the user move files to the archive, then delete all the crazy copies lying around. "Once the master has been archived, transcoded, etc., there's no reason to keep 10 copies, maybe 1."

## What "archived" means (one predicate, already in code)

`VideoScanModel.isArchived(rec)` = promoted copy | inside the Master Archive root | content has a master copy. `isArchivedOrVersionOfArchived` adds derivedFrom versions (balance-audio, trim, transcode), repairs exempt. Archive Angel and the to-do view already share this (codex #1345 fix).

## Rule

A record is a **scrubbable copy** when ALL hold:

1. It is not itself inside the Master Archive root.
2. Its content group (duplicateGroupID → contentHash → partialMD5+size) contains a member inside the Master Archive root **with a verified fixity** (`archiveFixity != nil`, i.e. Promote read it back or Verify Archive Copies re-read every byte). No fixity → not scrubbable; the row says "archive copy unverified".
3. It carries no human mark that says keep: no star, no human userNotes (MachineNote classifier), disposition not Important.
4. It is reachable (on a connected volume). Offline copies are never elected; see the 2026-08-14 blocker on dispositions stranding data offline.
5. It is not a member of a recovered A/V pair (the Tidy hard invariant).

Versions (a `_balanced` export of an archived tape) are NOT scrubbable by this rule; they are hidden from the to-do view but kept. Deleting versions is a later decision.

## Action

Tidy Catalog category "Copies of archived media (N, X GB)" → confirm sheet → files go to the **macOS Trash** (never `unlink`), records get `purgedAt` + `ArchiveStage.trashed` exactly like Delete Confirmed Junk. Undo = the existing one-tap undo shape plus Finder's Trash. The per-run cap is a number Rick sets (default 500 files) so a first run is reviewable.

## 3-2-1 check

"Keep 1" is only safe if the Master Archive has its own backup. Today: FamilyArchive is a RAID with UPS; retired drives (MyBook, RicksBackups, LACIE500) are insurance. The rule above keeps every retired-drive copy (offline → never elected), so a scrub on LaCieWorkspace / ~/Movies / MediaExpansion leaves: the archive copy + the retired-drive copy. That is 2 copies on 2 devices, 0 off-site. Off-site is the Publish/CDN work for the fall.

## Decisions for Rick

1. Fixity-verified archive copy required before any scrub (recommended: yes; the Verify Archive Copies pass makes it true for the whole archive in one night).
2. Keep exactly one non-archive copy on a connected volume as a warm spare, or zero? (Recommended: zero on scratch volumes, the retired drives are the spare.)
3. Per-run cap and whether the first run is LaCieWorkspace only.
