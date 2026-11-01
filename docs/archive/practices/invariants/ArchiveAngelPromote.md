---
tier: data-risk
paths:
  - VideoScan/VideoScan/ArchiveAngel/Promote/**
  - VideoScan/VideoScan/ArchiveAngel/Review/ArchiveAngelReviewDates.swift
  - VideoScan/VideoScan/ArchiveAngel/Prepare/ArchiveAngelPlan.swift
---
# Archive Angel → Promote hand-off

## Invariants
1. **AAP-1** The Angel proposes; it never promotes, moves, trashes or deletes media on its own. Nothing reaches the archive without Rick's approval in Review, and the hand-off goes through the same Promote engine as the Promote sheet (no parallel copy path).
2. **AAP-2** The date on an approved plan row is exactly the date Promote files under: a typed date survives pre-selection, reload and sibling selection; "Promote undated" stays undated; a copies'-date question must be answered before Promote is enabled.
3. **AAP-3** The fixity check at hand-off reads the source now; a digest that disagrees with the catalog refuses that item and says why.
4. **AAP-4** Family stamps and fact lenders never write a person, place or date onto a record that already holds a stronger (Rick's own) claim, and never onto an archived record.
5. **AAP-5** A refused or failed item is reported per item; the rest of the batch is not silently dropped and nothing is claimed archived that Promote did not journal.

## Known and accepted (do not report)
- Short clips are low-signal and ranked low; that is a ranking choice, not data loss.
- The plan row's `proposedDate`, `inheritedDate` and `dateFromCopiesAnswered` are additive fields; old plans decode with them absent.
