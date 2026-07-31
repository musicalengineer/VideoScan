# POI Cycle 05 — Embedding-Quality Pipeline (deinterlace + quality pooling)

Branch: `poi/c05-embedding-quality` (cut from main @ `31014a6`; eval-only —
production app behavior stays exactly as merged/promoted, including the C3
floor). Implemented under Rick's overnight autonomy grant (2026-07-19) and
codex's grade-owner ruling (`docs/team-channel/`
`2026-07-19-2132-codex-overnight-ownership-and-c5-gate.md`).

## Acceptance bar (grade-owner ruling, stated up front)

The bar RATCHETS to C3's graded result: the candidate must achieve balanced
accuracy **strictly greater than 0.6153846154** in **BOTH** fresh paired
repeats, with no concealed FN and complete process/config/corpus/reference
evidence. **The primary control arm is C3 minimumHits=7** (legacy pipeline +
floor-7 presence); legacy any-hit is reported as a secondary/historical arm
only. Both arms of the grade run floor-7 presence, so the pipeline is the
only difference — one attributable change.

## The single change

`--embedding-quality on` selects the **embedding-quality pipeline**: two
mechanically-coupled input-quality levers (research sweep 2026-07-17 §2,
items #1 and #2), packaged as ONE candidate because both act on the same
surface — the quality of the embeddings the unchanged matcher consumes —
and are exercised through one flag, one frozen config, one revert:

1. **Deinterlace-before-detection.** If the source is interlaced (probed
   `field_order`; DV always — the format is interlaced by definition and
   its containers routinely say "unknown"), the eval decodes frames for
   face detection through ffmpeg `bwdif=mode=send_frame` (ProRes 422
   temporary analysis copy, deleted after the run). Progressive sources
   pass through untouched. `send_frame` keeps one frame out per frame in,
   so the frame-step sampling grid matches the legacy arm exactly — only
   pixel content changes.
2. **Quality-weighted pooling.** Every embedded face observation carries a
   free quality signal: the PRE-normalization L2 norm of its ArcFace
   embedding (it was always computed for the normalizing divide and thrown
   away). Within a video, the bottom quartile of observations by quality is
   dropped (⌊n·0.25⌋, deterministic tie-break) BEFORE hits are counted;
   hits, segments, and the presence decision are computed from the
   survivors. `rawHits` reports the pre-pooling count alongside.

Nothing else moves: production ArcFace path (decoder, sampling, detector,
crop, alignment, model, threshold), full unmodified reference set, default
threshold, `--frame-step 10`, and the C3 aggregation surface are all
unchanged. Default runs (no flag, or explicit `off`) are byte-identical to
pre-cycle-05 builds — pinned by test.

### Filter choice: bwdif, not yadif_videotoolbox (recorded)

- **Determinism:** bwdif is a CPU filter with reproducible output; the
  VideoToolbox path is GPU + hwupload/hwdownload. This cycle *measures*
  run-to-run variance — the deinterlacer must not be a variance source.
- **Quality:** community ranking is consistently QTGMC > bwdif > yadif;
  bwdif is ffmpeg's best quality/speed default (research doc §1).
- **Speed is irrelevant at eval scale** (SD deinterlaces far above real
  time on this hardware either way).

### Why this is attributable

C1 failed as a compound *decision* gate; C5 deliberately contains no
decision-rule change at all — presence stays exactly C3's floor-7 in the
primary comparison. Both levers act strictly upstream (input quality), are
selected by one flag, described by one frozen config, and reverted by not
passing the flag (or reverting this branch). Per-clip, `deinterlaced` in
the output records whether lever 1 actually fired, so any grade delta can
be decomposed honestly after the fact.

## Canonical config

Emitted as `embeddingQuality` in the CLI JSON, byte-stable (sorted keys, no
whitespace), alongside the unchanged C3 `aggregation` object. There are
deliberately NO tuning sub-flags — the config is a compile-time constant
(no post-commit tuning surface):

- Candidate arm:
  `{"deinterlace":"bwdif","mode":"embeddingQuality","poolDropQuartile":0.25}`
  sha256 `48cf5564254a6e92b523687cffeb6bf227dfe47640a1ee2bf0ac2d52a4b6e61b`
- Legacy/control arms: the field is OMITTED (not null) — output
  byte-identical to pre-cycle builds; `aggregation` continues to carry
  `{"minHits":7,"mode":"minimumHits"}` (sha256 `e981faa3…dbe7ea`) or
  `{"mode":"legacyAnyHit"}` (sha256 `4f475fab…53af16`) exactly as in C3/C4.

A run that fails after parsing emits the requested `embeddingQuality`
config in its error output (truthful attribution), presence `none`, exit 2.
A probe or transcode failure is a HARD error — never a silent fall-through
to the interlaced original.

## Development A/B on the TRAINING corpus (NOT a grade)

**Evidence tier: development, training pool.** Corpus =
`tests/fixtures/videos/DonnaTestVideos/` — 13 Donna / 13 NotDonna, the C4+
TRAINING clips. **`Donna-15.mov` (added 2026-07-19) was EXCLUDED as a
sealed-holdout candidate** per the grade-owner ruling; it appeared in no
run, no analysis, no tuning. Corpus fingerprint (sha256 over sorted
`label/name|bytes`):
`330469f36836d099efc3669ea5e80d5f90dadd46a03d7db7535099cbb5312967`.

Protocol: Release binary from this branch (sha256 `e1d64060…ebe94e`), same
binary both arms, two paired rounds with AB/BA ordering, floor-7 presence
in BOTH arms (the grade's shape). 104/104 processes exit 0. Raw outputs +
runner + analyzer preserved at `/private/tmp/poi-c05-dev-ab-20260719/`.

### Headline (floor-7 = primary; any-hit secondary)

| Arm | Round | TP | FN | FP | TN | Balanced accuracy |
|---|---|---:|---:|---:|---:|---:|
| control (legacy pipeline + floor-7) | 1 | 13 | 0 | 10 | 3 | 0.615385 |
| control (legacy pipeline + floor-7) | 2 | 13 | 0 | 10 | 3 | 0.615385 |
| **candidate (embedding-quality + floor-7)** | 1 | 13 | 0 | 10 | 3 | **0.615385** |
| **candidate (embedding-quality + floor-7)** | 2 | 13 | 0 | 7 | 6 | **0.730769** |
| secondary: any-hit presence (both arms, both rounds) | — | 13 | 0 | 13 | 0 | 0.500000 |

The control reproduces C3's graded 0.6154 exactly, both rounds (same 3
TNs: NotDonna-8/10/13). The candidate matches it in round 1 and corrects
three additional FPs in round 2 (NotDonna-4/5/9 pooled to 6/5/6 hits —
under the floor). **Honest read: the candidate's gain is real but sits on
a knife edge** — in round 1 those same clips pooled to 7/8/8, exactly at
or one above the floor. Against the formal bar (strictly > 0.6154 in BOTH
repeats) this development evidence shows the candidate passing one round
of two; the graded outcome will turn on those three boundary negatives.
Disclosed, not concealed — the grade exists to measure exactly this.

Any-hit (secondary): 0.500 in all four cells. Expected — pooling removes
observations but a weak negative keeps ≥1 surviving matched observation,
so any-hit cannot benefit from this lever. The pipeline's value is only
realized THROUGH the floor.

### Per-clip table (hits; c = control, raw→p = candidate raw→pooled)

| clip | label | c r1 | c r2 | cand r1 | cand r2 | dropped r1 | deint | floor-7 ctl | floor-7 cand |
|---|---|---:|---:|---|---|---:|---|---|---|
| Donna-1 | POS | 92 | 98 | 91→78 | 98→84 | 116 | no | conf/conf | conf/conf |
| Donna-2 | POS | 12 | 10 | 11→10 | 11→10 | 7 | no | conf/conf | conf/conf |
| Donna-3 | POS | 62 | 58 | 63→49 | 62→49 | 32 | no | conf/conf | conf/conf |
| Donna-4 | POS | 26 | 23 | 24→19 | 24→19 | 9 | no | conf/conf | conf/conf |
| Donna-5 | POS | 11 | 10 | 12→11 | 14→13 | 40 | no | conf/conf | conf/conf |
| Donna-7 | POS | 13 | 14 | 12→10 | 13→11 | 6 | no | conf/conf | conf/conf |
| Donna-8 | POS | 647 | 671 | 685→520 | 690→523 | 622 | no | conf/conf | conf/conf |
| Donna-9 | POS | 41 | 35 | 39→35 | 38→34 | 16 | no | conf/conf | conf/conf |
| Donna-10 | POS | 11 | 14 | 11→8 | 11→8 | 12 | no | conf/conf | conf/conf |
| Donna-11 | POS | 58 | 80 | 71→51 | 54→39 | 71 | **yes** | conf/conf | conf/conf |
| Donna-12 | POS | 39 | 19 | 24→20 | 22→18 | 50 | no | conf/conf | conf/conf |
| Donna-13 | POS | 21 | 20 | 20→13 | 21→15 | 10 | no | conf/conf | conf/conf |
| Donna-14 | POS | 14 | 17 | 12→10 | 14→10 | 11 | no | conf/conf | conf/conf |
| NotDonna-1 | NEG | 34 | 21 | 29→25 | 30→25 | 40 | no | conf/conf | conf/conf |
| NotDonna-2 | NEG | 328 | 311 | 324→254 | 327→255 | 344 | no | conf/conf | conf/conf |
| NotDonna-3 | NEG | 69 | 77 | 69→54 | 74→58 | 83 | no | conf/conf | conf/conf |
| NotDonna-4 | NEG | 9 | 10 | 11→7 | 9→6 | 29 | no | conf/conf | conf/**none** |
| NotDonna-5 | NEG | 8 | 11 | 11→8 | 8→5 | 26 | no | conf/conf | conf/**none** |
| NotDonna-6 | NEG | 312 | 314 | 316→231 | 322→239 | 363 | no | conf/conf | conf/conf |
| NotDonna-7 | NEG | 21 | 19 | 25→20 | 26→20 | 17 | no | conf/conf | conf/conf |
| NotDonna-8 | NEG | 5 | 5 | 5→4 | 4→3 | 14 | no | none/none | none/none |
| NotDonna-9 | NEG | 9 | 10 | 9→8 | 8→6 | 16 | no | conf/conf | conf/**none** |
| NotDonna-10 | NEG | 5 | 6 | 5→4 | 8→5 | 15 | no | none/none | none/none |
| NotDonna-11 | NEG | 62 | 63 | 52→38 | 61→46 | 37 | no | conf/conf | conf/conf |
| NotDonna-12 | NEG | 15 | 14 | 15→10 | 14→12 | 23 | no | conf/conf | conf/conf |
| NotDonna-13 | NEG | 6 | 6 | 6→4 | 7→5 | 4 | no | none/none | none/none |

## Deinterlace lever: nearly unmeasurable on THIS corpus (disclosed)

Probing the 26 training clips: **exactly one** (Donna-11.mov, `dvvideo`,
field_order absent → DV rule) triggers deinterlacing; every other clip
reports `progressive`. So the training-corpus evidence overwhelmingly
measures the POOLING lever; the deinterlace lever executed correctly
(verified end-to-end on Donna-11: `deinterlaced:true`, temp created and
deleted, presence unchanged) but has almost no corpus to move. Additional
honest limitation: interlace detection is CONTAINER-metadata-based —
SD clips transcoded from interlaced originals with combing baked in but
flagged progressive (plausibly several NotDonna clips) will NOT trigger
it. Content-based detection (ffmpeg `idet`) is a different, future lever.
If the sealed holdout contains true interlaced sources (DV/MTS), the grade
will exercise lever 1 for real; per-clip `deinterlaced` makes that visible.

## FN-risk statement (against the floor — the ruling's framing)

Pooling strictly reduces hit counts (pooled ⊆ raw, pinned by test), so
with the floor fixed at 7 the confirmation bar is effectively HARDER in
the candidate arm — the mechanism that corrects weak FPs is the same one
that could create a Donna FN. Quantified on the training corpus:

- **Zero Donna clips crossed below the floor** under pooling, in either
  round. FN = 0 in all four candidate cells.
- **Thinnest positive margin: Donna-10, pooled 8 hits in both rounds** —
  one hit above the floor. Donna-2/-7/-14 pool to 10–11. Under the
  measured ±1–3 per-clip hit drift, Donna-10 is the plausible holdout-FN
  shape; a graded FN there is mechanism, not noise, and must be disclosed
  per round.
- Structural guard: ⌊n·0.25⌋ = 0 for n < 4, so pooling is the identity
  for very sparse clips — it cannot erase a short genuine appearance
  outright; the C3 short-clip exposure (a brief appearance never reaching
  7 raw hits) carries over UNCHANGED, neither created nor fixed here.

## Run-to-run variance (measured, both arms — the codex instability finding)

Same binary, same clip, round 1 vs round 2:

| | control | candidate |
|---|---|---|
| clips with rawHits changed | 24/26 | 23/26 |
| mean \|Δ decision-hits\| | 5.62 | 2.35 |
| max \|Δ decision-hits\| | 24 | 12 |
| facesDetected changed | 0/26 | 0/26 |
| floor-7 decision flips | 0 | 3 (NotDonna-4/5/9) |
| any-hit decision flips | 0 | 0 |

Two findings, both disclosed:

1. **The candidate reduces raw-stat variance by ~2×** (mean hit delta
   5.62 → 2.35, max 24 → 12) — consistent with the hypothesis that
   better/filtered inputs stabilize the pipeline. Face DETECTION is
   already stable (0/26 changed); the drift lives in embedding/matching,
   and pooling filters exactly the low-quality embeddings that drift.
2. **Decision variance moved the other way** (0 → 3 flips): pooling
   pushes the three weakest negatives from safely-above-the-floor to
   straddling it, so smaller drift now crosses a boundary. The flips are
   the candidate's *improvement* appearing and disappearing — in every
   flip the r2 direction (none) is the correct label. Determinism note:
   CPU-forcing CoreML was considered and REJECTED — it would change the
   embeddings themselves (FP16 ANE vs FP32 CPU), i.e. a second
   attributable change and a divergence from the production path. The
   upstream ±0.02-cosine ArcFace drift (known since C2) is therefore
   still present and measured above, not hidden.

## A/B reproduction (grader)

Release build, same binary both arms, per-file AB/BA pairing, schema v2,
positive ⇔ `presence == "confirmed"` (exact spelling), fresh corpus
enumeration + fingerprint, sealed holdout per the standing contract.

```
# PRIMARY control arm (C3 as graded/promoted: legacy pipeline, floor-7)
VideoScan --person-eval --engine arcface --person Donna \
    --references "<production refs dir>" --video <clip> --frame-step 10 \
    --aggregation minimum-hits --min-hits 7

# candidate arm (embedding-quality pipeline, same floor-7 presence)
VideoScan --person-eval --engine arcface --person Donna \
    --references "<production refs dir>" --video <clip> --frame-step 10 \
    --aggregation minimum-hits --min-hits 7 --embedding-quality on

# SECONDARY/historical arms: the same two commands without
# `--aggregation minimum-hits --min-hits 7` (any-hit presence).
```

No `--threshold` in either arm (production default). The candidate's
emitted `embeddingQuality` must carry exactly the canonical bytes/sha256
above; `aggregation` must carry C3's exact bytes in both arms. In
candidate outputs, `hits`/`segments`/`presence` are post-pooling and
`rawHits`/`observationsTotal`/`observationsDropped`/`deinterlaced` support
per-clip decomposition. `bestDistance` keeps raw pre-pooling semantics in
both arms (diagnostic only). References, corpus, and labels are
codex-owned and untouched by this branch.

## Validation surface (pinned by tests)

`VideoScan/VideoScanTests/EvalEmbeddingQualityTests.swift` (33 test cases,
all passing, incl. parameterized cases); full suite green in this worktree
(2970 tests: 2923 passed / 0 failed / 47 skipped, UI excluded), Release
`build-for-testing` green.

- Canonical config bytes + sha256 pin, 100× byte-stability, Codable
  round-trip, frozen-constants sensor.
- Pooling math: exact ⌊n·q⌋ table (incl. n<4 identity), known norms ⇒
  known survivor sets, deterministic 50× tie-break, matched-flag-blind
  quartile, pooled-⊆-raw invariant over a 50-shape deterministic sweep,
  empty input.
- Interlace decision table, exhaustive: DV always (any/no field_order,
  case-insensitive), tt/bb/tb/bt ⇒ yes, progressive/unknown/missing ⇒ no.
- Flag truth table: on/off; `off` on any engine (spells the default); ON
  requires ArcFace (vision/dlib/hybrid rejected — the quality signal
  doesn't exist there); conflicts with `--face-presence-only`; duplicates
  and 8 malformed value spellings rejected; missing value rejected;
  composes with the C3 floor order-independently; pre-existing C3 truth
  table regression-guarded.
- Output schema: legacy runs omit all five cycle-05 keys (byte parity
  sensor); candidate outputs embed the exact canonical config bytes with
  the C3 aggregation object intact; floor-semantics interaction pinned
  (raw 8 confirms, pooled 6 does not).

## Implementation decisions (recorded for review)

- schemaVersion stays 2 — the additions are purely additive AND omitted
  entirely on non-candidate runs, so every existing consumer sees
  byte-identical output (same discipline as C4's additive fields).
- Observations reach the CLI via a new OPTIONAL streaming hook on
  `pfProcessVideoWithArcFace` (`observationFn`, default nil ⇒ no
  recording, no allocation — production scans byte-identical; the same
  default-off pattern as C4's `faceEmbeddingFn`). The CLI accumulates
  ≈32 B/observation — worst case ≈7 MB for a 10-hour clip at frame-step
  10; ≈80 KB on this corpus.
- `arcfaceEmbedding` now also returns the pre-norm L2 (computed anyway;
  all existing callers ignore it — no behavior change).
- The deinterlaced ProRes temp streams to disk (never held in memory),
  worst-case disk ≈ source size for SD DV, deleted in a `defer`;
  ffprobe/ffmpeg run through `ProcessRunner` + `ToolLocator` with
  deadlines (120 s probe / 7200 s transcode) — no new subprocess pattern.
- Segments in candidate runs are re-clustered from the pooled hit list
  with the SAME production clustering function (made internal, not
  duplicated).
- Field-name note (Manager): C5 adds `embeddingQuality` beside C3's
  `aggregation`; C4's unmerged branch uses `presenceModel`. The C4 config
  -surface unification flag remains open — nothing here worsens it.

## What was touched (attribution / revert range)

- **New:** `VideoScan/VideoScan/EvalEmbeddingQuality.swift` (config +
  pooling math + interlace table);
  `VideoScan/VideoScanTests/EvalEmbeddingQualityTests.swift`; this doc.
- **`ArcFaceEngine.swift`** — pre-norm L2 surfaced from the (unchanged)
  normalization; optional `observationFn` hook + per-face recording
  (default-off); `arcFaceClusterSegments` visibility private → internal.
- **`PersonEvaluationCLI.swift`** — flag + strict validation, ffprobe
  interlace probe, bwdif prepass, pooling + re-clustering, additive
  output fields, truthful-config plumbing.
- Corpus, references, labels, `tools/person-eval/`, production scan
  paths: untouched.
