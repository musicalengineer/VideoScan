# C02 — Deep area: Archive promote, 00_Index, journal and ledger under a crash

Inherits `docs/briefs/cloud/README.md`. Report: `docs/reviews/cloud/C02-archive-promote-recovery.md`.

**Kind:** deep area pass. Data-risk folder (Archive/), ~20.9k lines total. Read the
write path only, not the views.

## Scope (`VideoScan/VideoScan/Archive/`)
`ArchivePromoteEngine`, `ArchivePromoteJournal`, `ArchivePromoteDecisions`,
`PromoteToArchiveJob` (+`Guards`, +`Steps`), `ArchiveIndexLock`, `ArchiveIndexText`,
`ArchiveIndexRename`, `ArchiveRefile`, `VideoScanModel+ArchiveUpdate`,
`MediaLedger`, `VideoScanModel+MediaLedger`, `MasterArchive`,
`MasterArchiveReadoption`, `ArchiveFileLock`. Also `AtomicFilePublish` wherever it
is defined (the rename wedge fix; never `replaceItemAt`).

## Invariants to attack
1. **Crash at any step.** For each step of a promote (copy → verify digest →
   index line → journal → ledger → record update), what does the disk look like if
   the process dies right after it, and does resume / re-adoption reach a
   consistent state? Write the step table in the report. Ending up with a record
   marked archived whose archive copy is missing or unverified is P1.
2. **Never clobber.** No path overwrites an existing archive file or index line
   that it didn't create in this run (name collisions, two promotes of the same
   content, case-insensitive name equality on APFS).
3. **Index lock.** Every writer of `00_Index` holds `ArchiveIndexLock`. Look at
   lock stealing after a stale holder, and whether two app instances (or the app
   and a hand edit) can interleave.
4. **Archived is read-only.** Archive update (refile) changes only {name, date}.
   Find any path that rewrites content bytes, or moves a file out of the archive.
5. Ledger: an entry is appended only after the fact it records is durable.

Out of scope: UI, progress wording, date-inference heuristics.
