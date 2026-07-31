# POI Cycle 04 — Learned Donna Classifier Head (donna-lr)

Branch: `poi/c04-donna-classifier` (cut from main @ `ee97ab7`; eval-only —
production app behavior stays legacy). First learning-based cycle, per the
revised ladder (Rick-ratified 2026-07-19): post-processing levers on
unchanged ArcFace distances are retired; the corpus becomes training data.

## Concept — the single change

ArcFace remains the production feature extractor. A SMALL learned logistic-
regression head maps each per-face 512-d embedding to P(Donna):

> **P(Donna | face) = sigmoid(w·e + b)**, and video-level
> **`presence = "confirmed"` iff any face has P(Donna) ≥ p\*** (equivalently
> max ≥ p\*). Otherwise `"none"`. No compound gates; the cosine-threshold
> `hits` pipeline is still computed and reported unchanged but plays NO role
> in the donna-lr decision (pinned by test).

What fixed-threshold matching cannot exploit — the labeled hard negatives
(same-age adult women scoring cosine 0.85–0.94 against Donna references) —
becomes training signal: the classifier learns a direction in embedding
space that separates Donna from exactly those confusers.

Selected with `--presence-model donna-lr --presence-model-file <artifact>`
(optionally `--presence-model-sha256 <hex>` to hard-pin the artifact).
Default (no flags) remains the legacy any-hit arm. Model choice: logistic
regression only — a tiny MLP is justified only if LR demonstrably underfits,
and the CV evidence below shows the opposite failure mode (overconfidence,
not underfitting).

Inference is a 512-term dot product in Double on the CPU — no new ML
framework, no new dependency, deterministic given the embeddings. p\* ships
INSIDE the artifact; there is deliberately no invocation-time threshold
knob (the artifact is the frozen candidate; no post-commit tuning surface).

## Training-data provenance (contract: the 26 clips are now TRAINING POOL)

- Corpus: `tests/fixtures/videos/DonnaTestVideos/` — `Donna/` 13 clips,
  `NotDonna/` 13 clips, enumerated fresh at extraction start, READ-ONLY.
  Corpus fingerprint (sha256 over sorted `label/name|bytes` lines):
  `5b83da7cc55482df66b4db28e729bd889c1b1b577d6d4893dad40652ec550cb3`.
- Extraction: `tools/poi-c04/extract_embeddings.py` runs the Release
  person-eval CLI per clip with `--engine arcface --frame-step 10
  --dump-embeddings` against the production Donna reference folder
  (read-only) — every training vector comes from the PRODUCTION ArcFace
  path (decoder, sampling, detector, crop, alignment, CoreML model,
  L2 normalization). Nothing about the embedding stack was reinvented.
- Rows (label = clip's folder): **4,014 Donna face rows / 4,065 NotDonna
  face rows = 8,079 total** across the 26 clips (per-clip counts in the
  fold table below).
- Training: `tools/poi-c04/train_donna_lr.py`, existing venv
  (sklearn 1.8.0 / numpy 2.4.4, both already present — no new installs).
  LogisticRegression, sklearn defaults (L2, C=1.0 — deliberately untuned),
  `class_weight="balanced"`, lbfgs, `max_iter=5000`, `tol=1e-8`. The final
  fit is executed twice and byte-compared (deterministic).
- **Sensitive-data rule (C2, unchanged):** the JSONL embedding dumps are
  raw biometric data and live only in local scratch — never committed. The
  committed artifact contains ONLY the weights vector, bias, p\*, and
  aggregate provenance (no embeddings, no absolute paths, no reference
  filenames).

## The train/holdout contract (grading consequence — explicit)

**These 26 clips are compromised for grading from this cycle forward**: the
candidate was trained on them, so any accuracy measured on them is
training-pool evidence, not generalization. Everything in this document is
**cross-validated development evidence, NOT a grade**. The official C4
grade runs later, by codex, on the sealed holdout Rick is building
(clips the trainer has never seen). Until that set exists, C4 has no grade.

## CV protocol + development numbers (NOT a grade)

Leave-one-clip-out (26 folds). The fold unit is the WHOLE CLIP — never
frame-level splits, because frames within a clip are near-duplicates and
frame-level splitting would leak the held-out clip into training. Per fold:
train on the other 25 clips' rows, score the held-out clip's faces, record
the max P(Donna). Clip decision: max ≥ p\*.

p\* was chosen from these 26 held-out max-probabilities: the decision
surface only changes at observed values, so the trainer scans the midpoints
between consecutive distinct scores and takes the midpoint of the WIDEST
BA-maximizing gap. **Chosen p\* = 0.9848848696322601** (gap width 0.0049,
interval [0.982430, 0.987339]). Disclosure: choosing p\* on the same CV
predictions is itself a fit to the training pool — one more reason these
numbers are development evidence only.

Aggregate (at p\*): **balanced accuracy 0.769231 — TP 11, FN 2, FP 4, TN 9
(TPR 0.8462, TNR 0.6923).**

Comparators on the same protocol:

| Arm | TP | FN | FP | TN | Balanced accuracy |
|---|---:|---:|---:|---:|---:|
| legacy any-hit (same extraction runs) | 13 | 0 | 13 | 0 | 0.500 |
| historical legacy bar (C1) | 13 | 0 | 11 | 2 | 0.577 |
| C3 minimumHits=7 (graded 2026-07-19, separate runs) | 13 | 0 | 10 | 3 | 0.615 |
| **C4 donna-lr, LOCO CV** | **11** | **2** | **4** | **9** | **0.769** |

Per-fold table (fold = held-out clip; maxP under the model trained on the
other 25; ✗ = misclassified at p\*):

| Held-out clip | rows | maxP | at p\* |
|---|---:|---:|---|
| Donna-1.mov | 464 | 0.991190 | ok |
| Donna-2.mov | 30 | 0.996523 | ok |
| Donna-3.mov | 131 | 0.988545 | ok |
| Donna-4.mov | 39 | 0.996831 | ok |
| Donna-5.mov | 161 | 0.994916 | ok |
| Donna-7.mov | 25 | 0.966483 | ✗ FN |
| Donna-8.mov | 2488 | 0.994724 | ok |
| Donna-9.mov | 65 | 0.995962 | ok |
| Donna-10.mov | 51 | 0.990288 | ok |
| Donna-11.mov | 272 | 0.987339 | ok |
| Donna-12.mov | 202 | 0.997658 | ok |
| Donna-13.mov | 41 | 0.988501 | ok |
| Donna-14.mov | 45 | 0.976281 | ✗ FN |
| NotDonna-1.mov | 163 | 0.995317 | ✗ FP |
| NotDonna-2.mov | 1379 | 0.916842 | ok |
| NotDonna-3.mov | 332 | 0.965512 | ok |
| NotDonna-4.mov | 117 | 0.973256 | ok |
| NotDonna-5.mov | 107 | 0.979497 | ok |
| NotDonna-6.mp4 | 1452 | 0.914816 | ok |
| NotDonna-7.mov | 69 | 0.992994 | ✗ FP |
| NotDonna-8.mov | 59 | 0.996588 | ✗ FP |
| NotDonna-9.mov | 64 | 0.993424 | ✗ FP |
| NotDonna-10.mov | 60 | 0.955589 | ok |
| NotDonna-11.mov | 151 | 0.960011 | ok |
| NotDonna-12.mov | 93 | 0.925378 | ok |
| NotDonna-13.mov | 19 | 0.982430 | ok |

Notable: the classifier corrects 9 of the 13 legacy false positives —
including NotDonna-4 (the C2 finding "a negative closer than every
positive": cosine could not separate it; the learned direction does). The
four surviving FPs (NotDonna-1/7/8/9, maxP 0.993–0.997) are presumably the
hardest same-age adult-women confusers — consistent with the C2 evidence
that the remaining signal is not in a blurry SD face crop (C5/C6 levers).

## FN-risk statement

**This is the first candidate arm with Donna false negatives in its
development evidence: Donna-7 (maxP 0.966) and Donna-14 (0.976).** Legacy
and C3 both hold recall 1.0; C4 trades 2 positives for 9 corrected
negatives on the training pool. Donna-14 was also C1's graded FN — it is a
genuinely hard positive. If sealed-holdout grading surfaces FNs, that is
the mechanism (a real Donna whose era/quality puts her below the learned
boundary), not noise; per-round disclosure applies. Whether the FN/FP
trade is acceptable is Rick's call at integration time, not the grader's.

## Determinism (measured, not hidden)

- The classifier layer is deterministic: CPU dot product in Double from a
  fixed artifact — 100 repeated inferences are bit-identical (pinned by
  `inferenceIsDeterministicAcrossRepeats`). Training is deterministic:
  double lbfgs fit byte-compared before the artifact is written.
- The UPSTREAM ArcFace embeddings are not bit-stable run to run (known
  since C2: ±0.02 cosine). Measured on this branch (Release, Donna-13,
  two back-to-back donna-lr runs): `maxFaceProbability` 0.991666 vs
  0.992180, `hits` 18 vs 19 — decisions identical, raw stats drift.
- **Knife-edge disclosure:** p\*'s optimal gap is only ~0.005 wide, and
  held-out max-probabilities cluster tightly under 1.0 (near-duplicate
  frames make LR overconfident). Upstream embedding drift of ±0.02 cosine
  can move a boundary clip's maxP by more than the gap — NotDonna-13
  (0.9824) and Donna-11 (0.9873) sit within one drift of p\*. Expect some
  decision flips between grading rounds; per-file AB/BA pairing and
  per-round disclosure are the mitigations. This is a sharper knife edge
  than C3's two-hit margin and a stated weakness of the candidate.

## Honest limitations

- 26 clips, 13 of them defining "Donna" across specific eras/lighting/tape
  stocks: the model can latch onto era artifacts as easily as identity.
  **The sealed holdout is the real test**; the CV number is expected to be
  optimistic (p\* fitting, above, compounds this).
- Row imbalance within classes: Donna-8 alone contributes 2,488 of the
  4,014 positive rows (62%); NotDonna-2 + NotDonna-6 contribute 2,831 of
  4,065 negatives. `class_weight="balanced"` equalizes classes, not clips —
  long clips dominate their class's geometry. Per-clip row weighting is a
  disclosed future lever, deliberately not smuggled in.
- Probability calibration is poor (everything near 1.0); p\* compensates
  numerically but fragilely. Quality-weighted pooling / deinterlacing (C5)
  attack the input side; calibration is a cheap follow-up lever.
- The four residual FPs score higher than most true positives — face-crop
  information alone likely cannot separate them (the "4-year-old test"
  argument for C6's whole-person witness).

## Canonical config

Emitted as `aggregation` in the CLI JSON — the exact configuration that
ran, byte-stable (sorted keys, no whitespace, nil fields omitted;
`modelSHA256` is computed from the artifact bytes actually read, never
echoed from the command line):

- Candidate arm:
  `{"mode":"donnaLR","modelSHA256":"7ff1ad9a25fb4d434793b9fd399c23712a2905cc4ebd225285ad02e71eea6858","probThreshold":0.9848848696322601}`
- Legacy arm: `{"mode":"legacyAnyHit"}`
  sha256 `4f475fab1db48dba996da6415cdac83c9fd38837c0a036704c395e7ff953af16`
  (byte-identical to prior cycles' legacy config object).

Model artifact: `tools/poi-c04/models/donna-lr-v1.json` (~12 KB), sha256
`7ff1ad9a25fb4d434793b9fd399c23712a2905cc4ebd225285ad02e71eea6858`.
A donna-lr run that fails before its model loads emits `{"mode":"donnaLR"}`
(no hash, no threshold — truthful attribution: no model governed any
decision), presence `none`, exit 2.

Field-name note — RESOLVED 2026-07-23: this branch originally named the
config field `presenceModel`, while production main (C3, promoted) names
its rule field `aggregation`. The team agreed to unify on production's
name, and since only C4 may change this round, this branch renamed its
emitted JSON key `presenceModel` → `aggregation`. JSON-surface change
only: the CLI flags (`--presence-model`, `--presence-model-file`,
`--presence-model-sha256`) and internal Swift types/files
(EvalPresenceModel.swift etc.) are unchanged, and the config VALUE bytes
and their sha256 pins above are unchanged (the pins are over the value
bytes, not the field name). C3 legacy-arm output is now byte-identical to
prior cycles, including the field name.

## A/B reproduction (grader — SEALED HOLDOUT ONLY)

Release build, same binary both arms, per-file AB/BA pairing, schema v2,
positive ⇔ `presence == "confirmed"` (exact spelling). **Do not grade on
the 26 training clips** (train/holdout contract above).

```
# legacy arm (production defaults; any-hit presence)
VideoScan --person-eval --engine arcface --person Donna \
    --references "<production refs dir>" --video <clip> --frame-step 10

# candidate arm (learned Donna classifier head)
VideoScan --person-eval --engine arcface --person Donna \
    --references "<production refs dir>" --video <clip> --frame-step 10 \
    --presence-model donna-lr \
    --presence-model-file "<repo>/tools/poi-c04/models/donna-lr-v1.json" \
    --presence-model-sha256 7ff1ad9a25fb4d434793b9fd399c23712a2905cc4ebd225285ad02e71eea6858
```

No `--threshold` in either arm (production default; it feeds the unchanged
`hits` reporting only). The candidate's emitted `aggregation` must carry
exactly the pinned `modelSHA256` above. Corpus-fingerprint discipline
unchanged. `maxFaceProbability` in the candidate output supports
threshold-sensitivity reporting from a single run.

## Validation surface (pinned by tests)

`VideoScan/VideoScanTests/EvalPresenceModelTests.swift` (46 test
executions incl. parameterized cases):

- Canonical config bytes + sha256 pins (both arms), 100× byte-stability,
  Codable round-trip, mode-only bytes for the failed-load attribution.
- LR inference math: known weights ⇒ known probability (0.5 / 0.75 exact),
  weights+bias composition, monotonicity, dimension mismatch ⇒ nil
  (fail closed), 100× bit-identical repeats.
- Presence boundary at p\* (inclusive ≥, `nextUp`/`nextDown` neighbors),
  no-scorable-faces ⇒ `none` even under an always-confirm model.
- Artifact loader fail-closed: missing file, malformed/empty/wrong-shape
  JSON, wrong formatVersion/kind/featureDim, weights-count mismatch,
  non-finite parameters, probThreshold outside (0,1), expected-sha256
  mismatch; sha match accepted case-insensitively; reported hash equals the
  file-bytes hash.
- Committed-artifact regression sensor: `donna-lr-v1.json` loads, 512
  finite weights, p\* in (0,1).
- Flag truth table: donna-lr requires file + ArcFace engine; rejects —
  missing model file (no silent default artifact), non-ArcFace engines,
  `--face-presence-only` combination, inert file/sha flags without the
  mode or with legacy mode, duplicates, unknown modes, malformed sha
  spellings, missing values. `--dump-embeddings` requires ArcFace, rejects
  presence-only/empty/duplicate, composes with donna-lr. Pre-existing
  flags regression-guarded.
- Output schema: emitted `aggregation` bytes, presence spelling, raw
  `hits` unchanged, classifier fields omitted (not null) on legacy runs,
  and the decoupling pin: hits 0 + confident face ⇒ confirmed while
  hits 9 + low probabilities ⇒ none.

## Implementation decisions (recorded for review)

- schemaVersion 2, purely additive over 1 (same discipline as C2/C3):
  default-run recognition behavior and raw fields unchanged; the JSON adds
  `aggregation` + `presence` (and, donna-lr only, `maxFaceProbability`,
  `facesScored`; dump runs add `embeddingsDumped`).
- Per-face embeddings reach the CLI via a new OPTIONAL streaming hook on
  `pfProcessVideoWithArcFace` (`faceEmbeddingFn`, default nil ⇒ collection
  disabled, zero allocation, production scans untouched). Consumers are
  O(1)-state (classifier max/count) or streaming (JSONL dump) — worst-case
  extra memory is one frame's faces × 2 KB.
- `--dump-embeddings` is the committed, re-runnable extraction mechanism
  (training must be reproducible from the repo); its OUTPUT is sensitive
  and stays in scratch.
- The loader hard-requires featureDim 512 (the production ArcFace width) —
  a mismatched artifact can never silently score garbage.
- Non-confirmed spelling `none`, exit-code and error-output conventions
  follow C3 exactly (truthful attribution on failed runs).

## What was touched (attribution / revert range)

- **New:** `VideoScan/VideoScan/EvalPresenceModel.swift` (config +
  classifier + loader); `tools/poi-c04/` (extractor, trainer, model
  artifact); `VideoScan/VideoScanTests/EvalPresenceModelTests.swift`;
  this doc.
- **`ArcFaceEngine.swift`** — optional `faceEmbeddingFn` hook +
  `collectFaceEmbeddings` pass-through (default-off).
- **`PersonEvaluationCLI.swift`** — flags, schemaV2 additive output,
  classifier scoring, embedding dump; truthful-config plumbing.
- Corpus, references, labels, `tools/person-eval/`: untouched.
