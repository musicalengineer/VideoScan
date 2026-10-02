---
tier: data-risk
paths:
  - VideoScan/VideoScan/Archive/**
  - VideoScan/VideoScanCore/Sources/VideoScanCore/ArchiveFixity.swift
  - VideoScan/VideoScanCore/Sources/VideoScanCore/ArchiveModels.swift
  - VideoScan/VideoScanCore/Sources/VideoScanCore/ContentFixity.swift
  - VideoScan/VideoScanCore/Sources/VideoScanCore/AtomicFilePublish.swift
  - VideoScan/VideoScanCore/Sources/VideoScanCore/BackupAttestation.swift
  - VideoScan/VideoScanCore/Sources/VideoScanCore/MediaLedgerEvent.swift
  - VideoScan/VideoScanCore/Sources/VideoScanCore/LedgerNarrator.swift
  - VideoScan/VideoScanCore/Sources/VideoScanCore/MachineNote.swift
  - VideoScan/VideoScanCore/Sources/VideoScanCore/VolumeIdentity.swift
---
# Master Archive (FamilyArchive): promote, 00_Index, Update…, lock, fixity, ledger

## Invariants
1. **ARCH-1** An archived file is never lost or duplicated. A move inside the archive is ONE `renameatx_np(RENAME_EXCL)` between dirfds opened through the O_NOFOLLOW chain — no copy, no unlink. Any failure after the move renames back only the identity-checked original (device+inode+size, before and after); otherwise the outcome is mixedState naming both paths, with the backup kept.
2. **ARCH-2** Nothing in the archive is ever overwritten: every create and rename is exclusive (no-clobber). Each new no-clobber site is inventoried in `ArchiveVolumeProtection`'s `reviewedNoClobberRenames`.
3. **ARCH-3** The 00_Index manifest never disagrees with disk. Rewrites are row-targeted and prepared in memory, then backup → recheck (planned AND unchanged files) → move → publish → rollback, all under `ArchiveIndexLock`. Every index writer and appender (manifest, promote journal, decisions, attestations) holds that lock; on the main thread it is tried once, never slept on.
4. **ARCH-4** A backup is retained unless the error proves it safe to discard. In-progress or unparseable backup folders are never pruned or counted; two operations never share a backup folder; retention never deletes the newest N (DST, mixed legacy/UTC names, clock going backwards).
5. **ARCH-5** Archived means read-only. Promote locks every file; only Update… unlocks → changes → relocks. Background work may add metadata to an archived record but never changes its name or date; archived records donate dates, they never receive them.
6. **ARCH-6** The archived record carries exactly the date Rick chose (never the source's leftover); placement folder, filename prefix, manifest `record_date`/`date_confidence` and the record agree. A machine date never moves a file on its own. Update… changes only what its sheet lists. When the Promote date cannot be written as Rick's date on the record (a typed decade; an Angel machine proposal), the source's own `userDate` that registration carries must agree with the placement at the coarser precision, or Promote refuses before the journal intent (GH #219, `ArchiveDateAgreement`). Verify Archive Copies flags — never rewrites — an archived record whose index, placement and catalog dates disagree.
7. **ARCH-7** Refusals happen before any mutation: target exists, archive offline or read-only, source digest ≠ manifest digest, filing-year guard. A refusal writes zero bytes. A source digest taken from a stored fixity is proven against the source's current bytes before the journal intent (codex 2026-10-02 #1/#4). A change only the engine can see — the source modified during the copy — is rolled back completely: the partial and the folders that run created (empty-only) are removed and its intent line is retracted, or closed `abandoned` when another writer appended after it; nothing that existed before the run is touched. Persistent logs carry refusal codes, operation ids and digest prefixes, never media paths or filenames; the UI keeps the detail (codex 2026-10-02 #7).
8. **ARCH-8** Fixity: a digest binding is counted as stored only after an acknowledged catalog save. A non-regular file (FIFO, socket, device, directory, symlink to one) is never opened for a blocking read or digested. A legacy stamp is untrusted until one full re-read; a missing volume UUID is never a wildcard.
9. **ARCH-9** Outcomes and ledger lines tell the truth: rolledBack, incompleteRecovery and mixedState are distinct; durability unconfirmed is never reported as success; the narrator never claims an undo the event does not carry.
10. **ARCH-10** Promote never claims a file it could not journal: a Busy or failed manifest/journal append means "not archived", and the next run converges.
11. **ARCH-11** Every machine line in a `.notes` file is signed through `MachineNote` and appended; Rick's existing text is never altered or lost.
12. **ARCH-12** The whole FamilyArchive volume is near read-only: no code path offers or performs bulk delete or trash there.
13. **ARCH-13** The archive never holds the same bytes twice (GH #190). Before the journal intent Promote obtains the source's sha256 (a stamp-bound `contentFixity` that `describesFileNow`, else one full read) and refuses — naming the archived file — when the run's index (00_Index manifest + in-root archive-copy `archiveFixity`) or the model's process-wide claims already hold it; the lookup is O(1). Look-up-then-claim is one main-actor step, so two identical files in one batch or in two concurrent jobs cannot both pass. Adoption of an existing file is decided against a digest READ from the source in that run, never a stored fixity (codex 2026-10-02 #1). The engine refuses to publish bytes whose digest differs from the one checked (`expectedSourceSHA`). An unreadable index refuses the run; malformed rows are skipped and reported.

## Known and accepted (do not report)
- Update… has no retry journal: if the catalog save or the ledger line fails after the archive and index are updated, it is logged loudly and reported, and the next scan picks up the new path (Rick, 2026-09-27, "KISS").
- Folders are not locked and the system immutable flag (`schg`) is not used (cut 2026-09-27).
- `ArchiveIndexLock` is a per-volume `flock`; it does not coordinate with a second machine writing the same archive over the network.
- The one-time lock catch-up marker lives beside the catalog (App Support), not on the archive.
