# POI Improvement Cycle 01 — Score-Based Presence Aggregation

**Branch:** `poi/c01-aggregation` · **Date:** 2026-07-17 · **One lever:** the
video-level presence decision rule. Thresholds, reference handling, engines,
sampling — all untouched.

## The change

### Before (any-hit rule)

The video-level decision was implicit: any frame hit ⇒ the video counts as a
match, and `PersonFinderModel.splitByConfidence` routed it to
**confirmed** (`detectedPeople`) whenever `bestDistance ≤ threshold − 0.05`,
else **suspected** (`suspectedPeople`). One stray frame with a strong distance
was enough to confirm a person into the catalog — the published dev-27
assessment showed 13/13 hard negatives predicted present (identity precision
50.0%, F1 65.0).

### After (score-based rule, `PresenceAggregation.classify`)

Per video, from counters the pipeline already produces:

```
hitRate = hits / max(1, framesWithFaces)

CONFIRMED  ⇔ hits ≥ minHits
             AND hitRate ≥ minHitRate
             AND medianHitDistance ≤ maxMedianDistance
SUSPECTED  ⇔ hits ≥ 1 but confirmed criteria not met
ABSENT     ⇔ hits == 0
```

`framesWithFaces` is fed by `pfVideoResult.facesDetected` — face observations
examined — which is the same denominator the published dev-27 hit-rate stats
used, so the parameter reasoning below is apples-to-apples.

The old rule remains selectable: `AggregationConfig.Mode.legacyAnyHit`
reproduces `splitByConfidence` exactly (parity pinned by
`legacyModeMatchesSplitByConfidence`), so the evaluator can A/B and the change
is revertable by flipping one config value.

## Per-parameter reasoning (from the published dev-27 report ONLY)

Source: `tools/person-eval/benchmarks/donna-dev-27/report.{md,json}` —
27 cases, ArcFace, identity F1 65.0, 13 FP / 1 FN. Per-case hits,
facesDetected, and bestDistance are published there; hit-rate = hits/faces.

| Parameter | Default | Reasoning |
|---|---|---|
| `mode` | `scoreBased` | The cycle's change. `legacyAnyHit` preserved for A/B. |
| `minHits` | **3** | Kills single/double-frame flips. Published negatives' low end: notdonna-10 had **2 hits** — pruned. Every published detected positive had ≥ 10 hits, so a floor of 3 costs zero published recall while removing the exact "one stray frame confirms Donna" failure mode. |
| `minHitRate` | **0.08** | Published positive hit-rates: median ~33% (range **8.7%**–63%; donna-6 was already a FN with 0 hits). Published negative hit-rates: median ~17% (range 3.3%–42%). 0.08 sits just under the weakest true positive (donna-5 at 0.087 — the recall guard) while pruning the negatives' low tail (notdonna-10 at 0.033, notdonna-8 at 0.068, notdonna-4 at 0.077). Deliberately NOT set near the medians: the two distributions overlap heavily in the middle, and cutting there would trade recall for precision blindly. |
| `maxMedianDistance` | **0.50** | The assessment shows best-distance separates poorly (positive bests 0.059–0.313 vs negative bests 0.056–0.482 — overlapping). Median-of-hit-distances should separate better: a true positive's hits cluster near its best, while a threshold-skimming negative only has hits because tail frames dipped under the cutoff, so its median crowds the hit ceiling (Vision: threshold 0.52; ArcFace: 1 − cosineThreshold = 0.60 at dev-27 settings). 0.50 is (a) strictly inside both ceilings, so a pure skimming distribution fails, and (b) far above every published positive best distance (max 0.313) plus reasonable spread, minimizing recall risk. Per-hit medians were not published in dev-27, so this default is deliberately lenient; tightening it with evaluator-published median stats is the obvious cycle-02 candidate. |

### Canonical config (defaults, byte-stable JSON)

```json
{"maxMedianDistance":0.5,"minHitRate":0.08,"minHits":3,"mode":"scoreBased"}
```

`minHitRate`/`maxMedianDistance` are `Double` so the canonical encoding
prints exactly `0.08`/`0.5` (Float would encode as `0.0799999982...`).
Byte-stability is pinned by `canonicalJSONIsByteStable`.

## Expected effect

- **Fewer FPs from stray frames:** published negatives notdonna-10 (2 hits),
  notdonna-8 (6.8%), notdonna-4 (7.7%) can no longer reach *confirmed*;
  threshold-skimmers whose hit medians crowd the ceiling are also downgraded.
  Downgraded negatives land in `suspectedPeople`, not `detectedPeople`.
- **Recall watch item:** sparse-hit positives. donna-5 (8.7% hit-rate) is
  deliberately kept by `minHitRate = 0.08`, but a future positive with a
  hit-rate in the 3–8% band, or with a hit-median above 0.50, would be
  downgraded confirmed → suspected. donna-6 (the existing FN, 0 hits at
  current thresholds) is unaffected either way.
- **Binary "hits > 0" presence is unchanged** — absent ⟺ zero hits, exactly
  as before. The lever moves videos between the confirmed and suspected
  tiers; nothing that used to be invisible becomes visible or vice versa.

## What was touched (attribution / revert range)

- **New:** `VideoScan/VideoScan/PersonPresenceAggregation.swift` — the pure
  rule (`PresenceTier`, `AggregationConfig`, `PresenceAggregation`).
- **`PersonFinderTypes.swift`** — `pfVideoResult` gains two additive fields
  with defaults: `framesSampled: Int = 0`, `medianHitDistance: Float? = nil`.
- **`PersonFinderDetection.swift` / `ArcFaceEngine.swift`** — populate the
  two new fields at the end of the per-video pass (median over the per-hit
  distances already accumulated in the loop; O(hits) transient memory,
  ≤ ~172 KB for a 2-hour clip sampled every 5th frame).
- **`PersonFinderModel+JobLifecycle.swift`** — the two `splitByConfidence`
  call sites (`runScan` completion, `restoreFromCache`) now call
  `PresenceAggregation.aggregate(_:threshold:config: .standard)`.
  `splitByConfidence` itself is retained verbatim (legacy mode + parity
  tests).
- **`PersonEvaluationCLI.swift`** — config surface for the evaluator (below).
- **Tests:** `VideoScanTests/PresenceAggregationTests.swift` (new).
- **This doc.**

Revert = revert the single cycle commit on `poi/c01-aggregation`, or ship
with `mode: .legacyAnyHit`.

## Evaluator config surface

The person-eval harness (`tools/person-eval/` — **unmodified**) records the
JSON the production CLI prints. `PersonEvaluationCLI` output (already
`sortedKeys`-encoded) adds, alongside the existing `engine` field:

- `aggregation` — the full `AggregationConfig` object (canonical field set:
  `maxMedianDistance`, `minHitRate`, `minHits`, `mode`) → this is the
  evaluator's config-hash surface.
- `presence` — the video-level decision: `"confirmed" | "suspected" | "absent"`.
- `hitRate`, `medianHitDistance`, `framesSampled` — the rule's inputs, for
  offline analysis.
- `schemaVersion` bumped 1 → 2 (purely additive fields; existing keys keep
  their old names, types, and semantics — `hits`/`segments` are still the raw
  pipeline values, so the frozen harness computes identical binary presence).

New CLI flags for A/B without touching the harness (manifest command-level):
`--aggregation score|legacy`, `--min-hits N`, `--min-hit-rate X`,
`--max-median-distance X`.

## Degradations (documented, tested)

- **Cached rows predating this cycle** (`pf_cache` doesn't persist
  `facesDetected` or the new median): `framesWithFaces = 0` ⇒ the hit-rate
  criterion passes trivially (`hits / max(1,0)`), and the median falls back
  to the median of the segments' `avgDistance` (which IS persisted). The
  decision then rests on `minHits` + segment-median — strictly no worse than
  the legacy any-hit rule. Pinned by `zeroFacesDenominatorDegradesGracefully`
  and `classifyResultFallsBackToSegmentMedian`.
- **dlib results** have no per-frame data: same segment-median fallback; if
  there are no segments either, the median criterion fails ⇒ *suspected*,
  never a silent confirm (`missingMedianDowngradesToSuspected`).

## Existing tests

No existing test pinned the any-hit video-level rule as such;
`FamilyTaggingTests`' `splitByConfidence` cases now pin the retained
**legacy** mode (still green, unchanged). No test updates were required.

## Future-cycle candidates (out of scope for cycle 01 — one lever only)

1. **Tighten `maxMedianDistance` per-engine** (relative to the engine's hit
   ceiling) once the evaluator publishes per-hit median distributions.
2. **Persist `facesDetected` + `medianHitDistance` in `pf_cache`** (additive
   SQLite columns + migration) so cache-restored rows classify at full
   fidelity instead of the degraded path.
3. **Segment-weighted median for the fallback** — weight segment
   `avgDistance` by per-segment hit count (dlib publishes `hit_count`;
   Vision/ArcFace segments don't record it today).
4. **Face-size prior:** dev-27 `face_stats.json` shows tiny faces
   (`median_face_h` ~48–55 px) among both TPs and hard negatives — a
   min-face-height term could disambiguate, but it's a second lever.
5. **Presence-seconds criterion:** `minPresenceSecs` exists but is a
   pre-filter, not part of the confirmed bar; folding presence duration into
   the score is a natural extension.
6. **Emit `threshold` in the CLI output** alongside `aggregation` so the
   whole decision context is in one hashable object.
