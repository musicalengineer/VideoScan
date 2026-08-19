# Promote-Helper — implementation plan (2026-08-19)

Source spec: `docs/promote-helper-workflow.md` (Rick + codex). Goal: a right-click
**Assess Copies for Archive…** that looks at one copy family, collapses physical
duplicates into distinct *representations*, names the original source master,
and offers Promote / companion / access-copy actions — with the existing
Promote job as the unchanged safe executor.

## Design decisions (from the code map)

* **Decision is lexicographic, not a score** (spec §"decision"):
  1. same complete recording incl. audio → 2. known original generation over
  derivatives → 3. reject damaged/truncated → 4. preserve native geometry /
  cadence / interlace / color / audio structure → 5. format sustainability →
  6. drive reliability + human metadata only among byte-identical instances.
  Size / resolution / bitrate never win alone (fixes `keeperScore`'s size+pixel bias).
* **Representation** = encoding signature (video codec · audio codec · container
  · geometry · fps · scan · channels · rate · depth). Instances inside one
  representation are *byte-identical* when they share a non-empty
  `contentHash` (candidates; Pair Compare's full SHA-256 is the proof) or else
  *unconfirmed equivalents*.
* **Generation evidence**, strongest first: explicit lineage (`derivedFrom`
  → a family member; `derivationKind`), then codec class (native acquisition
  codecs DV/DVCPRO/HDV-MPEG2/MJPEG/AVCHD-from-camera vs mezzanine ProRes/DNx,
  preservation FFV1+lossless, access HEVC/H.264+AAC). A family with no native
  acquisition codec gets a *presumed* original, flagged unconfirmed.
* `ArchiveReadiness.formatRisk` stays longevity advice; it is **not** a fidelity
  signal and never demotes DV below HEVC in this assessor.
* Pure core (`CopyFamilyAssessor`) → Sendable inputs, O(family), table-tested.
  Main-actor projection builds inputs from records + `DuplicateKeeperPolicy`
  (volume rank, human-metadata score) so slice 1 needs **no schema change**.

## Slices

| # | What | Schema | Status |
|---|------|--------|--------|
| 1 | `CopyFamilyAssessor` pure core + tests (collapse → classify → recommend → actions + cautions) | none | **this session** |
| 2 | MFO job kind `.assessCopies` + expanded result panel ("12 locations → 4 representations") + catalog row verb **Assess Copies for Archive…** (extension file, like `CatalogContent+Promote.swift`) | none | next |
| 3 | Actions wired: Promote Recommended Original (→ `requestPromote`), Choose Another Equivalent…, Create Access Copy (→ `startTranscode .archival`), Create + Promote Lossless Companion (→ `.preservation` then promote), Verify Audio gate | `derivationKind = "transcode:<preset>"` on transcode outputs (additive; today missing) — **Rick OK needed** | after 2 |
| 4 | Asset-role / manifest fields (`assetRole`, companion links in archive manifest) | new catalog + manifest fields — **Rick approval** | later |
| 5 | Color correctness: carry primaries/transfer/range on `VideoRecord`; SD derivatives tag BT.601/SMPTE-170M (spec caution) | additive probe fields — **Rick approval** | before auto SD derivatives |
| – | Separate fixes surfaced: `duplicateGroupCount` staleness (audit Fix-it now recounts), `duplicateDisposition` relative-to-keeper bug, cross-container high-confidence without hash | — | tracked |

## Slice 1 contract

```
CopyFamilyAssessor.assess(_ inputs: [CopyFamilyInput], options:) -> CopyFamilyAssessment
  .representations: [CopyRepresentation]   // role, signature, instances, recommended instance, notes
  .recommendedOriginal: (representation id, instance id)?
  .summary: String                          // the one-paragraph verdict
  .actions: [CopyFamilyAction]              // promoteRecommended, chooseAnotherEquivalent, createCompanion, promoteOriginalAndCompanion, createAccessCopy
  .cautions: [String]                       // provenance gaps, unverified audio, damaged variants
```
