# Archive promotion — workflow design stab

**Status:** first sketch, 2026-08-14 end-of-day, per Rick's dinner brief.
Not final — this is the strawman to argue with tomorrow.

## The idea in one line

Media that is **clear, dated, identified, cleaned, approved, rated** gets
*promoted* — copied, checksummed, and green-checked into a Safe Archive —
and the app pushes the user along the pipeline because humans don't do
tedious repetitive work without a carrot and a stick.

## The pipeline (most machinery already exists)

| Stage | Meaning | Backed by |
|---|---|---|
| 1. Identified | people tagged, confirmed | `confirmedByUserPeople`, POI |
| 2. Dated | verified or high-confidence date | `inferredRecordDate` + confidence, OCR/dossier |
| 3. Cleaned | not junk, not a duplicate loser | `junkScore`, dup group Keep |
| 4. Rated | ★★★ = gold | `starRating == 3` (canonical axis) |
| 5. **Promoted** | copied + verified into the archive | `archiveStage` ladder: Master → Backed Up → Archived |
| 6. Offsite | cloud copy verified | `backupDestinations` (already a field!) |

**Promotion of one file =** copy to archive layout → **full-file checksum
verify** (read back, compare — the delete-safety standard) → new catalog
record at the archive path with `derivedFrom`/`originalFullPath` provenance
→ `archiveStage = .masterAssigned` → green check. Cloud sync + verify later
flips `.backedUp`; tertiary flips `.archived`. **Green checkmarks per stage
in the inspector** — that row of checks IS the carrot.

The stick: the backup-time nag pattern (shipped tonight for retired
volumes) generalizes — "N gold-rated files are not yet archived" at backup
time, with the prompt performing the first step.

## Folder layout (strawman)

```
FamilyArchive/
└── VideoScan_MediaArchive/
    ├── 1980s/
    │   └── 1985/
    │       └── 1985-06-21_Timmy-Birthday.mov
    ├── 2000s/
    │   └── 2005/
    │       └── 2005-11-19_Rick-and-Matt-Podcast.m4v
    └── undated/
        └── needs-dating before promotion — or a deliberate "undated" home
```

Rules:
- `decade/year/` — Rick's sketch; year folder only when the year is known
- Filename: `YYYY-MM-DD_Slug.ext` — date prefix sorts naturally in Finder,
  slug from the curated title, original extension preserved (no transcode
  at promotion time; archive stores the verified original)
- **Finder-legible is a feature**: the archive must make sense to an
  80-year-old cousin with no app — that's the north-star constraint
- Undated media either blocks promotion (stick: "date me first") or lands
  in `undated/` by explicit choice — proposal: block by default, because
  the archive is precisely where dating discipline pays off forever

## Worked example (Rick's file, ready today)

```
source:  /Volumes/LaCieWorkspace/CheesegraterArchive/osx10.8_backup/rickb/
         Music/iTunes/iTunes Music/Movies/Rick-and-Matt-Podcast-11-19-2005.m4v
dated:   2005-11-19 (from filename — verify + stamp)
becomes: FamilyArchive/VideoScan_MediaArchive/2000s/2005/
         2005-11-19_Rick-and-Matt-Podcast.m4v
catalog: new record at archive path, derivedFrom → source record,
         archiveStage=Master, sha256 stored, ★★★
```

## Terminology to keep clean (ties to volume_taxonomy_proposal.md)

- **Safe Archive** = derived chip (redundant + trusted + reachable), never
  hand-set — FamilyArchive earns it today
- Local archive master / cloud offsite master / tertiary offsite = the
  three `backupDestinations` kinds; 3-2-1 in the user's own words
- One verb: **Promote**. Not archive/move/export/copy — one verb, one
  meaning (nag-button rule)

## Open questions for tomorrow

1. Promote-in-place UI: inspector button? context menu? drag to a volume
   role chip?
2. Does promotion *retire* the source record or keep both live? (Proposal:
   both live, source gains "archived elsewhere" badge — deletion stays a
   separate human decision, per the catalog-delete doctrine.)
3. Batch promotion — the 3★ queue as a review-then-promote list?
4. Cloud leg mechanics: rclone to B2 per the storage strategy; verify =
   remote hash compare; who runs it and when?
