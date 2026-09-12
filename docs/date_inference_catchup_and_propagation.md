# Inferred dates: catch-up, propagation, folder-year prior

*Rick 2026-09-12 · code: `VideoScan/VideoScan/VideoScanModel+DateInference.swift` ·
tests: `VideoScanTests/InferredDatePropagationTests.swift`*

## The bug this closes

`/Converted_VHS_Tapes_2026/1991/NV12.mkv` existed twice — on MediaExpansion and as
the Projects `_staging` copy — same `partialMD5`, same size, same OCR burn-in
`JUN.21 1991 PM11:29` at t = 193 s on both. Only the Projects copy carried
`inferredRecordDate 1991-06-21` (0.75). The MediaExpansion copy had the OCR
candidate and no date, so its Date column fell through to the 2026 conversion
date. Same bytes, same evidence, different answer.

## Root cause

Dossier results reach a copy by three roads; only one carried the conclusion:

| road | writes the channels | writes `inferredRecordDate` |
|---|---|---|
| `applyDossier` (the record's own VLM/Whisper pass) | yes | yes |
| `propagateBestDossier` (per-writeback + load-time backfill across `partialMD5` siblings) | yes — transcript, captions, OCR text, **OCR date candidates** | **no** |
| `applyEnrichmentInheritance` (duplicate-delete keeper fold) | yes | yes — but only when a copy is removed |

NV12's MediaExpansion row took road 2 (its channel stamps are the Projects copy's
model/date; no `dossierProcessedAt`). Nothing ever re-derived a date from the
evidence that propagation delivered.

## The three rules

All run off the view path, in `catchUpInferredDates(scope:limit:trigger:)`,
in this order, and each is idempotent.

1. **Catch-up from stored evidence.** Any active record with date evidence
   (`ocrDateCandidates`, transcript or caption year mentions) and no inferred
   date gets one from `pfInferRecordDate` run on *content tiers only* — no path
   hint, no mtime, no container time (those are facts about one copy, not the
   footage). Same confidences as the dossier pass: 0.95/0.85/0.75 OCR, 0.90
   OCR + agreeing mention, 0.58/0.55 mention-only (year precision, below the
   resolver's 0.6 floor by design). Provenance `inferredDateSource = "catch-up"`.

2. **Propagation across a content group.** Group key precedence is
   `CatalogSizeTotals.groupKey`: `duplicateGroupID` → `contentHash` →
   (`partialMD5`, `sizeBytes`). The highest-confidence *content-backed* date
   (≥ 0.50 — the mtime tier 0.30 never travels) is copied, with its confidence,
   to every other member that is active, readable, has **no `userDate`**, **no
   settled inferred date**, and whose own evidence does not name a different
   year. Provenance `"propagated from <donor record id>"`. Mirrors
   `applyHumanMetadataInheritance`'s fill-the-hole rule for Rick's date/place,
   but for machine dates.

3. **Folder-year prior (weak).** A *directory* component that is exactly a
   four-digit year in 1900–2030 (`/1991/`; not `Christmas2010`, never the
   filename) dates an otherwise evidence-less record at Jan 1 noon-UTC,
   confidence **0.30**, provenance `"folder-year"`. "Otherwise evidence-less"
   means: no `userDate`, no `embeddedCreationDate`, no OCR/transcript/captions
   at all. It sits below `RecordDateResolver.inferredConfidenceFloor` (0.6), so
   it never files the archive; it flips the readiness copy from "undated" to
   "low-confidence guess" (`hadRejectedSignal`) and makes `year:1991` find the
   record. It is a **placeholder**: rules 1 and 2 and any real dossier pass
   replace it (`hasSettledInferredDate` treats it as absent). `applyDossier`'s
   own path-year tier stays at 0.50 — there a VLM pass ran and found nothing
   better, which is itself evidence.

### Never

- overwrite a `userDate` (not read for writing at all);
- overwrite a settled inferred date — own pass (`inferredDateSource == nil`),
  catch-up, or propagated — even when evidence disagrees (that heals on the
  next dossier pass, as before, GH #166);
- propagate a copy-local date (confidence < 0.50) or a folder-year placeholder;
- read from or write to purged / set-aside / superseded rows, or to
  ffprobe-failed / `isLikelyUnanalyzable` rows (the 2026-06-30 smear guard,
  both as donor and recipient).

## When it runs

| trigger | scope | log line |
|---|---|---|
| catalog load, right after `backfillDossierAcrossDuplicates()` | whole catalog | `date inference: N records caught up (a from own evidence, b propagated, c folder-year prior; e examined, t ms, load)` |
| live-reload sweep (30 s) after `mergeDossierFields` | rows the external merger touched + their groups | `… live reload)` |
| every `applyDossier` writeback | that record's group | `… dossier)` |
| every `applyAudioTranscript` / `applyCaptions` writeback (single-channel roads that also deliver evidence without a conclusion) | that record's group | `… transcript)` / `… captions)` |

`limit` (default 50,000) bounds rule 1's evidence scans per pass; a truncated
pass says so in the log and the rest catch up next time. Nothing logs when a
pass changes nothing.

## Notifications

Each touched record gets `searchIndex.update` and a record-scoped
`.videoScanCatalogMutated` post (the `InspectorPlaceView` shape — the model's
listener schedules the debounced save and refreshes chrome). A bulk pass
(> 50 rows) refreshes the index itself and posts one unscoped notice.

## Schema

`VideoRecord.inferredDateSource: String?` — additive optional, `encodeIfPresent`;
records dated by their own dossier pass round-trip byte-identical. Threaded
through CodingKeys, decode, DTO, `snapshotClone`, `RescanPreservedFields`
(which now also treats any `inferredRecordDate` as worth restoring), live
reload, the enrichment fold and the Master Archive copy. The Python merger's
delta whitelist is untouched (this field is written by the app only; the
merger's atomic rewrite preserves keys it does not know).

## Numbers on Rick's catalog, 2026-09-12 (read-only copy)

`InferredDatePropagationRealCatalogReport` (the shipped code on a temp copy of
catalog.json, 13,824 records / 9,271 eligible): **448** active records carried
`ocrDateCandidates` and no `inferredRecordDate`; one pass dates **1,473** —
147 from their own stored evidence, **1,305 by propagation**, 21 folder-year
priors — 2,226 records examined in 160 ms. (An independent Python pre-check
on the same copy agreed within its cruder eligibility model: 448 / 1,314 / 29.)
