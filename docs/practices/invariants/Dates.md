---
tier: truth
paths:
  - VideoScan/VideoScanCore/Sources/VideoScanCore/RecordDateResolver.swift
  - VideoScan/VideoScanCore/Sources/VideoScanCore/RecordDateClaim.swift
  - VideoScan/VideoScanCore/Sources/VideoScanCore/InferredDateRange.swift
  - VideoScan/VideoScanCore/Sources/VideoScanCore/VideoRecordUserDate.swift
  - VideoScan/VideoScanCore/Sources/VideoScanCore/EmbeddedCreationDate.swift
  - VideoScan/VideoScan/Catalog/DateTriangulat*.swift
  - VideoScan/VideoScan/Catalog/DateValidation.swift
  - VideoScan/VideoScan/Catalog/VideoScanModel+DateInference.swift
  - VideoScan/VideoScan/Catalog/CatalogWideMetadataCandidates.swift
---
# Dates: resolving, inferring and sharing a record's date

The resolved date decides where Promote files a video and what the Date column shows. A wrong date misfiles family media.

## Invariants
1. **DATE-1** A user date always wins, at its precision, in every path: resolver, Date column, Promote's date hint, footage-group sharing.
2. **DATE-2** A device stamp (make AND model, or a named action-cam maker) is never demoted as a "software" stamp.
3. **DATE-3** The date catch-up is idempotent and never destroys evidence: a second run changes nothing; clearing an mtime-tier inferred date never clears a user date, an embedded stamp or a date with evidence; a record on an unreachable volume is left untouched.
4. **DATE-4** Footage-group sharing only at `likely` or better; it never propagates a filename year or an export stamp, never overwrites a member's own stronger claim, and a human "not the same" blocks it.
5. **DATE-5** A range resolves to YEAR precision, deterministically, and never to a day; a reversed or empty range never crashes.
6. **DATE-6** Archived records donate dates and never receive them; background inference never writes a date onto an archived record.
7. **DATE-7** Era floors hold: no inferred video date before the era the media type can exist in; a spoken or written year is evidence of a reference, not proof of the recording date.
8. **DATE-8** Every inferred date can say why (its evidence), and the UI shows inferred dates as inferred.

## Known and accepted (do not report)
- Inferred dates for files with no evidence beyond mtime stay empty by design (rules v13).
