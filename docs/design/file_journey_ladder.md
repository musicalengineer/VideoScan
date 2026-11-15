# File Journey: one sheet, one ladder (Rick 2026-11-14)

**Workflow sentence.** I open one sheet on a file and see at a glance where it stands — Catalogued, Analyzed, Reviewed, Archived — then how it got there, then the finer detail.

## What Rick ruled
- The ladder is Catalogued · Analyzed · Reviewed · Archived, green checks, on top. Offsite appears only once Rick has answered the cloud / off-site question for the file.
- "Signed" and the MD5 line are gone: not something a person cares about.
- Catalogued is the day the file first came into the catalog; a rescan never moves it.
- One sheet: the ladder, the timeline, then progressively less important detail. Archive Details and the File Journey are the same sheet.
- Dates in the timeline stand out (the icon's colour, heavier type). The sheet opens large.

## What each tick is proven by
| Step | Ticked when | Date |
|---|---|---|
| Catalogued | the record exists | the earliest date the catalog holds for the footage, shown "by …" (the true first day was never recorded — see Not built) |
| Analyzed | every content analyzer that applies has its stamp: the same per-file rule Catalog Status counts (`AnalyzeCoverageCalculator.forEachContentAnalyzer`) | newest stamp |
| Reviewed | Rick's own act on the footage: his date, his place, his note, a person he confirmed, a same-footage answer, a confirmed repair, an Update of the archived file, a confirmed provenance | latest dated act |
| Archived | a copy in the archive that is on disk now (one stat at sheet open) and known by a whole-file SHA-256 | the day Promote archived it (never a later check's date); "checked …" when a later full read-back matched |
| Offsite | never ticked green: it is Rick's word (`BackupAttestation`, cloud or off-site), drawn apart and left out of "N of M" | when he said so |

The ladder answers for the footage, not the row: the row, its archived copy and the copy's source are read together. Opening the sheet on the archive copy itself is the case that read "not archived" before.

Not evidence of review: star rating and classification (Promote and the analyzers write them), `archiveStage`, a provenance role (it may be the machine's estimate), machine text left in `userNotes`, a recorded `BackupEntry` (no writer since 09/22).

"Read back and matched" is said only of a copy Promote made (its archive fixity). A file that is merely inside the archive's folder with a fingerprint of its own is said to be "in" the archive with a fingerprint recorded — nothing was compared to anything.

## Timeline
One sentence per real event, oldest first, each from a dated field: the file's own date; catalogued; machine passes (scenes described, speech transcribed, sound check, Check Media, era estimate); Rick's dated acts; archived (from the copy record, not the note string); a later read-back; where it is now (stat). Machine notes (ffprobe text) and undated lines move to Technical notes at the bottom.

## Internals
- `PreservationChecklist.steps(from:)` is pure over `PreservationEvidence`; `FileJourneyBuilder` (pure, main actor, no store) gathers the evidence and the events from records handed to it. `VideoScanModel.buildFileJourney` forwards to it.
- No schema change, no catalog write, no ledger read (the ledger is a whole-file read; not for sheet open).

## Not built (follow-ups)
- The true first-catalogued day: `files.catalogued_at` exists and is always NULL. Recording it once at first insert is a catalog-writer change with its own tests.
- Face-scan coverage: no per-file stamp exists, so it cannot be part of Analyzed.
- iCloud as an archive destination: after a spike on the upload-status keys.
