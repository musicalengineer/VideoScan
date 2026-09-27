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

## Hardening after codex review, 2026-09-12 evening (#1413, #1415, #1433, #1434)

**Identity.** A date travels only between rows VERIFIED to hold the same
bytes: equal `contentHash` when both have one (a conflict rejects the pair
outright), else equal `partialMD5` AND equal non-zero `sizeBytes`.
`duplicateGroupID` is never a key — `DuplicateDetector` hands those to
heuristic groups that score High while the full hashes conflict. Audit of
the live catalog after the 20:18 load pass: **558 of 1,305** persisted
"propagated from" dates rested on unverified identity, 531 with conflicting
content hashes.

**Unwind (one-shot, at load, before the pass).** `unwindUnverifiedPropagatedDates`
clears every "propagated from <id>" date whose donor is not verified same
content (or is gone). Reversible: the prior state is written FIRST to
`App Support/VideoScan/date-inference/unwound-<yyyyMMdd-HHmmss>-<8 hex>.json`
(`{recordID, fullPath, inferredRecordDate, inferredDateConfidence,
inferredDateSource}` per row), opened create-exclusive so an undo file is
never replaced (#1439); no sidecar, no repair. Idempotent: a second load
finds nothing, writes nothing, logs nothing. Validation follows the
provenance chain ("propagated from <id>") to the row that EARNED the date
and checks verified-same-content against that ORIGIN, so a dependent
subtree (A → B → C with A/C conflicting) is cleared whole; a missing link,
an unparseable id, an undated origin or a cycle is unverified by definition
and cleared (#1439). Audit line in catalog.log
and the app log. `reapplyUnwoundDates(from:to:)` restores a sidecar onto rows
that still have no settled date and no userDate. userDate, own-evidence,
folder-year and verified propagated rows are never touched.

**Budget.** Rows the `limit` leaves unexamined are deferred — never a rule-2
recipient or donor that pass. Evidence classified "names no date" is memoised
on the model (`inferredDateNoDateEvidence`, fingerprint-validated) so later
bounded passes skip it for free and advance. Recipient conflict detection
compares at the coarser of the evidence's and the donor's precision (OCR =
day, year mention = year); own evidence finer than the donor's refuses to
borrow.

**Donors.** Only rows that EARNED their date (own dossier pass or catch-up)
donate. A propagated date never donates again — otherwise an unhashed
intermediary B could carry A's date to C on a second pass across a known
A/C hash conflict (#1433).

**Perf.** Per-recipient eligibility is settled once before the donor loop
(#1434: an all-dated bucket is N reads, not N² guard calls). A scoped pass
buckets only the scope's groups; the O(records) key walk remains — a
maintained index is the real fix.

### Known follow-up (not fixed): dossier EVIDENCE propagation identity

`backfillDossierAcrossDuplicates` / `propagateBestDossier`
(`VideoScanModel+DossierPropagation.swift`) group by `partialMD5` **alone** —
no `sizeBytes`, no `contentHash` conflict check — when carrying OCR date
candidates, transcripts and captions between rows. Rule 1 then dates the
recipient from that evidence at catch-up confidence. Same identity class as
#1413 one layer down; it should adopt `haveVerifiedSameContent`. Filed as a
follow-up on 2026-09-12; not changed tonight (one bug per dispatch).

## GH #201 (2026-09-26): the scored triangulator — combine criteria, show the reason

*Code: `VideoScan/VideoScan/DateTriangulator.swift` (pure), the catch-up pass in
`VideoScanModel+DateInference.swift`, `RecordDateResolver` ·
tests: `VideoScanTests/DateTriangulatorTests.swift`*

**Rick's rule.** The inferred date is a machine **guesstimate** that combines
criteria and shows its written reason; he confirms (the inspector's date field
is the confirmation, and his date always wins).

Two live cases: `CapeCod_notsure_NTSC.mov` showed its 2008 Final Cut export
stamp (`make=Apple`, no model) over the transcript's "what year is it? 2004" ×3;
`TimmyBaby-1996/Media/Clip 19` (DV) inferred 1955 from "it was 1955 or 6 … On the
Waterfront" — a referenced year, and DV cannot predate 1995.

### Fields (additive, on `VideoRecord`)

| field | meaning |
|---|---|
| `inferredRecordDate` | the point estimate (unchanged — every reader sorts and files by it) |
| `inferredDateConfidence` | 0–1 (unchanged) |
| `inferredDateRange` | **new** — `{startYear, endYear}` when only the year is known; "2004" or "2003–2004". `RecordDateResolver` then files at YEAR precision, never a fabricated Jan 1, and the Angel makes no day key |
| `inferredDateReason` | **new** — the written reason; also "no evidence…" on a row a pass examined and found nothing on |
| `inferredDateSource` | unchanged vocabulary plus `"footage-shared from <uuid>"` |

### Criteria and weights

| criterion | weight | precision | note |
|---|---|---|---|
| on-screen burn-in date | 0.95 ≥3 frames · 0.85 2 · 0.75 1 | day | unchanged tiers |
| camera stamp (a MODEL, or GoPro/DJI/Insta360/Garmin) | 0.90 | day | a claim only beside content; alone it is the resolver's rank 2 |
| spoken NOW-cue year ("what year is it? 2004", "Christmas 2002", "happy new year 2000", "2004 Cape trip") | 0.65, +0.05 per repeat, cap 0.75 | year | |
| spoken year, no cue | 0.45, +0.05 per repeat, cap 0.55 | year | two cue-less years that disagree ⇒ "ambiguous", no date |
| caption year (VLM) | 0.45 | year | |
| age + People-tab birth year ("how old are you? eight", "8 years old", "5th birthday", "turned six") | 0.60 one named person · 0.30 any known person | 2-year window per person | the subject is the name nearest the age, else the record's one tagged person, else everyone with a birth year; no profiles ⇒ neutral |
| folder year ("TimmyBaby-1996") | 0.55 | year | a corroborator: claims only beside other content; stands alone only in a full dossier pass (the old 0.50 tier) |
| spoken REFERENCE year ("it was 1955 or 6", "back in", "born in", "class of", past tense + "in") | 0 | — | written into the reason, never dates the tape |
| export stamp (make with no model, or an `encoder`) | ceiling | — | "set aside as ingest"; a claim after it ×0.25 |
| media-era floor | constraint | — | DV ≥ 1995 · HDV ≥ 2003 · AVCHD/phone H.264 ≥ 2006 (only with a camera named); film scans (16mm / Super 8 / "film" / "reel" in the path) exempt; a claim below is set aside and named |
| catalog priors | constraint | — | 1950s / 1970s need two independent criteria at ≥ 0.90; 1940s / 1960s ×0.85; a lone soft claim outside 1984–2016 ×0.5 |

### Combination

1. Every candidate year is scored by **noisy-OR** over the claims allowing it
   (`1 − Π(1 − wᵢ)`: 0.75 ⊕ 0.30 = 0.83; 0.65 ⊕ 0.90 = 0.97 → cap 0.95). Ties go
   to the year with more supporters, then the earlier year.
2. **Adjacent** spoken years (2003 and 2004) are one tape across a New Year:
   the range widens, nothing is penalised.
3. A **disagreeing** claim no softer than the best evidence (hardness: burn-in /
   camera stamp 3, now-cue / named age 2, the rest 1) multiplies confidence by
   `1 − 0.5 × its weight` and widens the range; a softer one (a folder year
   against a burn-in) is only written into the reason. Two now-cues that
   disagree: the more-mentioned wins, confidence drops under the filing floor,
   the range shows both ("2004–2010").
4. **Day precision** when the strongest agreeing claim knows the day; else
   Jan 1 noon UTC of the year with the span (the intersection of what agreed —
   an age window 2004–2005 and a now-cue 2004 know 2004).
5. **Reason** = agreeing (strongest first); adjacent; the export set-aside; the
   era floor; "but … disagrees"; references; priors. Examples:
   `spoken now-cue 'what year it is… 2004' ×3; age 8 fits Timmy (born 1996) →
   2004–2005; export stamp 2008-10-23 set aside as ingest (Apple, no model)` ·
   `folder 'TimmyBaby-1996' names 1996; DV era floor 1995 respected; 1955
   mentioned as a reference (past), not the recording year`.
6. No content claim ⇒ `nil` + reason `no evidence` — a stamp alone, a file's
   copy date, or a filename year is **never** an inferred date.

### The catch-up pass (rule 0, rule 1, rule 2b)

- **Rule 0** — housekeeping: a legacy own-pass date with no evidence under 0.50
  (the old mtime / container-time fallback) is cleared with the reason
  `no evidence (a file's copy date is never an inferred date)`; a
  footage-shared date whose donor left the group is cleared.
- **Rule 1** — the triangulator runs on undated evidence-bearing rows, on
  **legacy** own / catch-up rows (no written reason) **once** so they gain a
  reason and the new rules (provenance kept), and on the scoped row of a
  transcript / caption writeback (`refreshScope`). A reasoned inference is
  settled — disagreeing evidence heals on the next dossier pass, as before.
- **Rule 2b** — one footage group (`FootageMembership.confidence ≥ likely`), one
  date: the strongest member claim by `ArchiveAngelEvent.DateClaim` ordering
  (a person's date > a camera's stamp > the dossier > a name / export stamp —
  software stamps demoted below the dossier for this purpose; then confidence,
  precision, earliest year). Members without a user date whose own claim is
  weaker inherit it: `shared from <file> (same footage): <the donor's reason>;
  own evidence said <year>`. A user date, a camera stamp or a dossier inference
  travels; a filename year or an export stamp never does. Shared rows are
  derived (never donors) and re-derived every pass.
- People-tab birth years come from the POI profiles via the read-only loader,
  cached 5 minutes; never read under a test host (tests inject
  `dateInferencePeople`).
- Log: the 2026-09-12 line is unchanged; a second line
  `date triangulation: N took their footage group's date, M re-triangulated
  with a written reason, K cleared (<trigger>)` is written only when non-zero.

### Resolver changes (rules v13)

- `embeddedConfidence`: a make with **no model** is a software stamp (0.80),
  like an `encoder`; `RecordDateResolver.namesDevice` is the one device rule
  (the Date column's displaced-stamp path and the Angel's `hasCameraOrigin`
  read it).
- A software stamp (≤ 0.85) is set aside by an inferred date ≥ 0.6 that
  disagrees by more than 2 years; a device stamp still needs the GH #166
  content-agreement tier (≥ 0.85).
- `resolve(… inferredDateRange:)`: a ranged inference resolves at year
  precision.

### Judgement calls made 2026-09-26 (for Rick to overrule)

- Weights as tabled; a single now-cue (0.65) clears the 0.6 filing floor at
  YEAR precision; a folder year alone (0.55) or a cue-less mention (0.45) is
  shown in the Date column but not filed.
- A range displays with an en dash: "2003–2004"; stored as two ints.
- Two now-cues that disagree: the more-mentioned year is the point estimate,
  confidence is penalised under the floor, the range spans both.
- The DV / HDV / AVCHD floors are HARD (a burn-in reading 1991 on a DV file is
  set aside and named in the reason — Rick can type 1991 if it is a dubbed tape).
- Footage groups share only at `likely` or better; `possible` links do not.
- A legacy own-pass date at ≥ 0.50 with no stored evidence is left as it is
  (its evidence cannot be re-read); it shows "from an earlier pass, no written
  reason" in the inspector.
