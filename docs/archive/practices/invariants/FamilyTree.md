---
tier: data-risk
paths:
  - VideoScan/VideoScan/FamilyTree/RecordFinderFiling.swift
  - VideoScan/VideoScan/FamilyTree/RecordFinderFoundSheet.swift
  - VideoScan/VideoScan/FamilyTree/ResearchStore.swift
  - VideoScan/VideoScan/FamilyTree/ResearchPerson.swift
  - VideoScan/VideoScan/FamilyTree/ResearchPersonSheet.swift
  - VideoScan/VideoScan/FamilyTree/ResearchAttestation.swift
  - VideoScan/VideoScan/FamilyTree/FamilyAssetStore*.swift
  - VideoScan/VideoScan/FamilyTree/DocumentIngest.swift
  - VideoScan/VideoScan/FamilyTree/VideoScanModel+Documents.swift
  - VideoScan/VideoScan/FamilyTree/VideoScanModel+FamilyAssets.swift
  - VideoScan/VideoScan/FamilyTree/CouplePortrait.swift
  - VideoScan/VideoScan/FamilyTree/FamilyTreeNotes.swift
  - VideoScan/VideoScan/FamilyTree/FamilyTreeLiveModel.swift
  - VideoScan/VideoScan/FamilyTree/FamilyTreeBookmarks.swift
  - VideoScan/VideoScan/FamilyTree/FamilyTreeLineExport.swift
  - VideoScan/VideoScan/FamilyTree/FamilyTreePronunciation.swift
  - VideoScan/VideoScan/FamilyTree/FamilySearchPull*.swift
  - VideoScan/VideoScan/FamilyTree/FamilySearchPersonRefresh*.swift
  - VideoScan/VideoScan/Hallie/HallieTellingMode*.swift
  - VideoScan/VideoScan/Hallie/HallieAppTurnCoordinator+Telling.swift
  - VideoScan/VideoScan/Hallie/HallieAppTurnCoordinator+Pronunciation.swift
  - VideoScan/VideoScanCore/Sources/VideoScanCore/CyberBrainWriter*.swift
  - VideoScan/VideoScanCore/Sources/VideoScanCore/CyberBrainCorrections.swift
---
# Family Tree: Record Finder filing, research dossiers, documents, CyberBrain writes, FamilySearch pull

FT-1..FT-7 are the #230 Record Finder filing brief's invariants, verbatim in substance.

## Invariants
1. **FT-1** Nothing is written before every refusal check passes; `.refused` means zero bytes written anywhere.
2. **FT-2** No existing file is ever overwritten; a duplicate SHA-256 is detected across every folder the person has.
3. **FT-3** No dossier writer saves a stale copy: a Research-pane edit (verdict / lore / tell / run) and a concurrent filing both survive, in either order. The same holds for two panes on one person and for rollback (it restores only what this filing changed).
4. **FT-4** Undo reverts only this filing's finding from what is on disk now; `dossier.json` is retired (to `research/.trash`, never deleted) only if this filing created it and it is otherwise empty.
5. **FT-5** CyberBrain is written only when the user ticked "read" and there is a real transcription or lore — never the placeholder, never twice for the same passage. Re-attach after an inspector Remove keeps verdict/told state and does not tell Hallie again. Concurrent CyberBrain writers never lose a passage whose receipt was returned.
6. **FT-6** A rollback leaves the document in `Documents/.trash` with its row gone, and the reported outcome (refused / rolledBack / filed) matches what is on disk.
7. **FT-7** Logs (filer and document store) carry no person name, URL or transcription.
8. **FT-8** A FamilySearch pull or person refresh replaces the tree on disk only with a complete, validated download; the previous tree survives a failed, partial or empty pull.
9. **FT-9** Rick's GEDCOM files are never edited by the app; corrections and identity rulings are data beside them.
10. **FT-10** A sidecar/list the app cannot read is never overwritten with an empty or default one; older builds can still read every list a newer build writes.
11. **FT-11** Private by default: DNA documents stay private unless Rick changes them; nothing about living people leaves the machine.

## Known and accepted (do not report)
- The per-key dossier lock is in-process only; two app processes are not coordinated.
- The lock table grows by one entry per researched person per session.
- A downgrade to an older build cannot decode new `ResearchSourceKind` cases (documented; the kind is written as Other + category for legacy readers).
