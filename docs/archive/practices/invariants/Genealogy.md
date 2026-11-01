---
tier: truth
paths:
  - VideoScan/VideoScanCore/Sources/VideoScanCore/Gedcom*.swift
  - VideoScan/VideoScanCore/Sources/VideoScanCore/*Kinship*.swift
  - VideoScan/VideoScanCore/Sources/VideoScanCore/LineageTrail.swift
  - VideoScan/VideoScanCore/Sources/VideoScanCore/LifeAndTimes/**
  - VideoScan/VideoScanCore/Sources/VideoScanCore/FamilyMap/**
  - VideoScan/VideoScanCore/Sources/VideoScanCore/TreeStatistics.swift
  - VideoScan/VideoScanCore/Sources/VideoScanCore/TreeLineStatistics.swift
  - VideoScan/VideoScanCore/Sources/VideoScanCore/TreeIntegrityCheck.swift
  - VideoScan/VideoScanCore/Sources/VideoScanCore/FamilyTreeDuplicates.swift
  - VideoScan/VideoScanCore/Sources/VideoScanCore/FamilyIdentityDecisions.swift
  - VideoScan/VideoScanCore/Sources/VideoScanCore/USPlaceNames.swift
  - VideoScan/VideoScanCore/Sources/VideoScanCore/USStateCodes.swift
  - VideoScan/VideoScanCore/Sources/VideoScanCore/BirthplaceClassifier*.swift
  - VideoScan/VideoScanCore/Sources/VideoScanCore/RollCall.swift
  - VideoScan/VideoScanCore/Sources/VideoScanCore/TreeWalkDate.swift
  - VideoScan/VideoScan/FamilyTree/FamilyKinship*.swift
  - VideoScan/VideoScan/FamilyTree/FamilyMapModel.swift
  - VideoScan/VideoScan/FamilyTree/LifeStatus.swift
  - VideoScan/VideoScan/FamilyTree/FamilyTreeRollCall.swift
---
# Genealogy: GEDCOM, kinship, lineage, places, life and times

## Invariants
1. **GEN-1** A relationship name is computed from a real path in the graph — never guessed. Half, step, in-law and "removed" are distinguished; no path or an ambiguous one → abstain.
2. **GEN-2** GEDCOM is read as written: notes verbatim, ids keep their at-signs, nothing invented while parsing; the app never edits the GEDCOM file.
3. **GEN-3** Places: an explicit country wins; old state abbreviations and historic names resolve correctly (New South Wales = Australia; Down → Northern Ireland); an ambiguous place is left unplaced, never misplaced.
4. **GEN-4** The family map places a person from a note only when the note opens with a run of names that are all that person's own (canonical or alias, at least one given name) followed by "was born" / ", born" (#235).
5. **GEN-5** Identity rulings and multiple parent families are honoured as recorded; the code never silently picks one family when a ruling is open.
6. **GEN-6** Date arithmetic: no negative ages, dual years kept, about/before/after qualifiers preserved; a census query never treats a given name as a surname.
7. **GEN-7** Roll Call and other family-facing lists never show a living person; "living" is decided conservatively (no death record and plausibly alive → living).
8. **GEN-8** Statistics and ancestor counts abstain on a family-line scope or a relative clause they cannot evaluate.

## Known and accepted (do not report)
- Notes that do not open with the person's own name ("Born in Cork.", "She was born in Cork.") are accepted false negatives for the map (#235).
- The GEDCOM 200k-person performance ceiling can flake under machine load; it passes alone.
