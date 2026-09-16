# Facial recognition and person search

**Updated:** 2026-09-16. **Source snapshot:** `59ca9468c01e0068501206c63698286c10f4e8b7`. This guide
consolidates the person-search designs, evaluation procedures, and lessons from the Donna experiments.
“Current” below means checked against source at that snapshot, not a new accuracy assessment. No build or
recognition run was performed for this documentation pass. Historical results are dated and scoped.

## 1. Current system: two related workflows

**Person Finder / Search** scans video for a selected person, reports temporal segments, and can extract and
compile clips. **Find & Tag** runs a per-person recipe and writes machine-tier catalog tags. Their scoring
and thresholds differ. Both support review; neither makes a human confirmation on the user's behalf.

| Surface | Current source of truth | Role |
|---|---|---|
| Search engines and settings | `VideoScan/VideoScan/PersonFinderTypes.swift` | Engine registry, thresholds, persistence migration |
| Search lifecycle | `PersonFinderModel+JobLifecycle.swift` in the same directory | Per-job configuration, cache, presence floor, dispatch |
| Find & Tag job | `FindPersonJob.swift` | Batch lifecycle, pause/cancel/stall handling, verdict application |
| Recipe implementation | `NativeRecipeScorer.swift`, `RecipeScoring.swift` | Native decoder/detector/embedding path and scoring math |
| Tag ownership | `VideoScanModel+PeopleTags.swift` | Machine tiers, human veto, provenance |
| Recognition CLI | `PersonEvaluationCLI.swift`, `RecipeCalibrationCLI.swift` | Separate evaluation and recipe-calibration entry points |
| Blind review | `UnifiedReviewSession.swift` | Phase policy and write-sink routing |
| Compilation | `PersonFinderCompilation.swift` | Extraction, adjacent compatibility buckets, optional merge |

### Search engine contract

The registry offers **Vision**, **ArcFace (CoreML)**, **AdaFace (CoreML)**, and **Hybrid (Vision + AdaFace
fallback)**. The settings default remains Vision. The extension seam is an enum registry plus dispatch, not
a Swift protocol-based plugin loader: async engine functions return `pfVideoResult?` through the shared
progress, logging, distance, preview, pause, and cancellation conventions. A new engine must cover registry
metadata, production and eval dispatch, memory budgets, persistence migration, cache identity, and
result/preview integration.

Search configuration supports per-job engine assignment; the old proposal that all jobs must share one
global engine is obsolete. Saved dlib settings migrate to AdaFace; old Hybrid tokens migrate to the new
Hybrid seat. Unknown persisted tokens fall back through the existing defaults. dlib is absent from Search,
but `--person-eval --engine dlib` remains an isolated compatibility replay path using the deprecated Python
script. It does not restore dlib to the UI registry.

| Setting / score | Snapshot default | Interpretation |
|---|---:|---|
| Vision threshold | 0.52 | Lower distance is closer; not an ArcFace cosine |
| ArcFace threshold | 0.40 | Higher cosine is closer |
| AdaFace threshold | 0.30 | Separate embedding space despite the same 512 dimensions |
| Search frame step | 5 | Sample cadence, distinct from recipe FPS |
| Search landmark alignment | Off | Optional setting; not the recipe's alignment policy |
| Search match confidence floor | 7 | Matched face observations, not seven distinct frames |

The production Search floor reuses `EvalPresenceRule`, with an additional short-clip safeguard: if estimated
sampled frames (`duration × fps / frameStep`) are fewer than the floor, or duration/FPS is unknown, it falls
back to any-hit and logs that choice. Floor 1 explicitly selects the legacy any-hit behavior. Do not assume
a raw CLI floor comparison includes this production safeguard.

ArcFace and AdaFace vectors must remain separated by backend/model version in both reference caches and
per-video result-cache variants. Their identical shape does not make them interchangeable. Preserve
fresh-model and prediction-lock safety when changing CoreML concurrency; the MLE5 failure history is real.
The recipe explicitly uses the serialized prediction path, not ArcFace's experimental multi-slot predictor
pool.

### Native Find & Tag pipeline

`FindPersonJob` defaults to native ArcFace. `VIDEOSCAN_NATIVE_RECIPE=0` selects the retained Python
reference bridge; the job captures its engine at creation. The Donna gallery path remains machine-local
under `tests/fixtures/photos/Donna`, with decade subfolders. Donna is the tuned recipe; the original
per-person generalization design does not establish other recipes.

1. Prepare one normalized centroid per usable era folder. The native gallery
   loader honors image orientation and requires exactly one sufficiently large,
   confident face per reference photo; empty eras are omitted.
2. Sample at 2 FPS. Use AVFoundation where it opens successfully, seeking for
   transport streams, and an ffmpeg raw-frame fallback for unsupported media.
   MKV, WebM, MXF, M2V, and M1V bypass the known-doomed AVFoundation open attempt.
3. Detect with Vision, filter detector confidence, orient the image, and align
   the crop with landmarks before CoreML embedding. This differs from the
   historical SCRFD-10G/ONNX reference pipeline.
4. Apply the optional genderage model as a conservative veto. Production jobs
   enable it: male-logit margin 1.0; minimum age 0, so the age veto is disabled.
   An unavailable gate model or failed assessment is permissive, not a silent
   rejection of the face. Record effective configuration when comparing runs.
5. Ignore faces below 25px short side. Faces at least 60px may vote; faces in
   the 25–59px band need cosine at least 0.55. Small strong matches can confirm
   a known identity; weak tiny faces must not dilute the evidence.
6. Compare each embedding against **all** era centroids, taking the maximum
   cosine. Era bands do not currently mean date-based routing to one centroid.
7. Score the clip as the mean of the top five gated face cosines. This is
   frame-level aggregation; the proposed tracker/track voting is not implied.
8. Apply the recipe-specific tiers and provenance through the catalog model.

| Recipe ID | Detected tier (`Donna*`) | Suspected tier (`Donna?`) |
|---|---:|---:|
| `recipe-v1-native` | score ≥ 0.46 | 0.26 ≤ score < 0.46 |
| `recipe-v1-python` | score ≥ 0.55 | 0.38 ≤ score < 0.55 |

These are current implementation constants, not portable operating points. The native suspected bar was
lowered from 0.30 after the August 5 margin-gate measurement. Thresholds require fresh calibration when
model, alignment, decoder/preprocessing, reference gallery, or attribute gate changes. AdaFace's name is not
evidence that it outperforms ArcFace on this archive.

Native setup failures fail the job; individual scoring errors remain per-clip results so the batch can
continue. `score == 0` with no error means no accepted evidence, not proof that a person is absent. Preserve
decoder-route telemetry, frame counts, and separate error reporting; zero-frame decode failures must not be
accepted as healthy negatives in an evaluation. The native AVFoundation route does not promise parity with
ffmpeg deinterlacing. The ffmpeg fallback applies yadif; this is a measured-comparison boundary.

### Tag authority and reruns

| Catalog data | Display / authority |
|---|---|
| `confirmedByUserPeople` | Plain name; human confirmation |
| `detectedPeople` | Name with `*`; confident machine result |
| `suspectedPeople` | Name with `?`; machine candidate |
| `rejectedPeople` | Human veto; recipe must leave that person untouched |

`applyRecipeVerdict` respects rejected and human-confirmed entries. A detected result removes the same
person's suspected tag. A suspected result does not weaken an existing detected tag. A below-tier result
**can clear that person's previous machine tags**. On changes, a signed machine note records recipe ID,
score, timestamp, and outcome. This supersedes the older draft's blanket “no-result never removes an
automatic tag” rule. A scoring error is not a below-tier score and must not be converted into one. The
proposed `PersonTag`/`contains` multi-source schema in the early tagging paper is not the current storage
contract.

## 2. Evidence custody and blind review

Keep **training**, **development**, and **sealed holdout** distinct. Split by source recording/event/tape,
not frame, extracted clip, or derivative filename. Two cuts from the same event can leak identity and
background information even when their filenames differ. A machine-found positive is selected for being easy
for that matcher; independent, human-found misses are valuable evaluation candidates, but any example
examined during tuning belongs outside the sealed holdout thereafter. Other-family tags are candidate
negatives, never labels.

The original 26 Donna/NotDonna clips became a **training pool from C4 onward**. Leave-one-clip-out
validation on that pool is development evidence. Selecting a threshold from those same cross-validation
predictions adds another fit; it cannot produce a fresh generalization grade.

Unified Review preserves two phases and two different answer schemas:

- **Holdout first:** yes/no answers write only to the sealed holdout CSV through
  its serialized write chain. Candidate scores must not even be loaded while
  an actionable blind row can be presented.
- **Candidate second:** four-tier ratings write to `ValidationLabelStore` and
  catalog writeback. Candidate fetching starts only on the phase transition.
- Returning to holdout via Continue Reviewing purges all candidate state.
  Back within candidates cannot cross into answered blind rows.
- `ReviewWriteRouting` rejects a holdout/candidate answer mismatch; it never
  coerces one answer schema into the other. Holdout navigation wraps over
  actionable rows; candidate navigation is linear.
- Offline, hidden, unplayable, and still-saving rows must retain honest progress
  and resume behavior. Do not display candidate counts during blind review.

**Private data:** family media, labels with private paths, and detailed reports stay local and ignored. The
stricter C2 biometric rule applies to raw embedding dumps, reference audit paths/filenames, and per-face
provenance: local `/private/tmp` scratch only, consumed in place; never git, issues/PRs, public or shared
reports, app logs, or team-channel messages. Publish aggregate statistics and configuration hashes, not
biometric vectors or identifying path lists. Machine-consumed datasets, model artifacts, and JSONL metric
streams are separate assets; consolidating Markdown does not authorize changing or retiring them.

## 3. Running evaluations deliberately

### Machine and build routing

Use Debug for normal development. Recognition grades and production comparisons use a Release binary with an
explicit source commit and binary SHA-256. Record model/gallery/configuration identity and corpus content
fingerprints as well. Do not run app-binary recognition, app smoke, or UI tests on Rick's active M4. Route
to M5/M1, or use an explicitly declared M4 quiet window. The commands below are procedures, not instructions
to start a scan during a documentation pass.

### Production-engine adapter

```sh
/path/to/VideoScan.app/Contents/MacOS/VideoScan \
  --person-eval --engine arcface --person Donna \
  --references /private/reference-gallery --video /private/example.mov \
  --frame-step 10 --aggregation minimum-hits --min-hits 7
```

The adapter directly uses production engine functions without catalog mutation, clip extraction, or
result-cache shortcuts. Current flags also include `--threshold`, `--min-face-confidence`,
`--largest-face-only`, and the reference-free `--face-presence-only --video ...` probe. The face-only probe
measures observed faces, not target identity, and cannot combine with the hit floor.

CLI output schema v2 contains raw `facesDetected`, `hits`, `segments`, `bestDistance`, timing/memory/error
fields, plus the exact `aggregation` and `presence` decision. Only `presence == "confirmed"` is a positive
for the POI confirmed-only grade. Default CLI aggregation is legacy any-hit; the floor requires both
`--aggregation minimum-hits` and an explicit positive `--min-hits`. Conflicting, duplicate aggregation, or
inert floor flags fail parsing. Matched observations can include multiple faces in one sampled frame.

**Important evaluator distinction:** `tools/person-eval/person_eval.py` currently computes identity presence
from **any predicted segment or `hits > 0`**, not schema-v2 `presence`. Passing the floor flag does not
change that evaluator's headline rule. Its identity F1 and a confirmed-only POI grade answer different
questions; do not label one as the other. Recipe calibration is a third surface.

### Standalone evaluator and labels

The manifest schema is v1, independent of the adapter's result schema v2. It supplies `suite`, `engine`
(`name`, `person`, `referencePath`, timeout, command array), and cases with stable `id`, `video`, tags, and
expected `anyFace`, `targetPerson`, and optional time segments. Relative paths resolve against the manifest.
Command placeholders include `{app}`, `{video}`, `{person}`, and `{references}`. Engine stdout must be one
JSON object. Prerecorded result fixtures test scoring deterministically; they are not recognition evidence.

```sh
python3 tools/person-eval/person_eval.py private/donna-manifest.json \
  --app /path/to/VideoScan.app/Contents/MacOS/VideoScan \
  --json output/person-eval-private/report.json \
  --markdown output/person-eval-private/report.md
```

Reports include face and identity precision/recall/F1, FP/FN, by-tag results, segment overlap, elapsed time,
and peak reported RSS. Missing denominators are `null`/N/A. Positive clips without timeline labels are not
scored as if their entire duration were ground-truth presence. The generated Rick/no-person smoke manifest
at `tests/fixtures/person_eval/videoscan_rick_smoke.json` is an integration sensor, not Donna accuracy
evidence.

Build and review the local labeling queue, then export from the **reviewed** file:

```sh
python3 tools/person-eval/build_label_queue.py \
  --catalog "$HOME/Library/Application Support/VideoScan/catalog.json" \
  --poi-root "$HOME/Library/Application Support/VideoScan/POI" \
  --target Donna --output /tmp/donna-queue.json --csv /tmp/donna-review.csv
python3 tools/person-eval/apply_label_csv.py \
  --queue /tmp/donna-queue.json --csv /tmp/donna-review.csv \
  --output /tmp/donna-reviewed.json
python3 tools/person-eval/label_queue_to_manifest.py \
  --queue /tmp/donna-reviewed.json --output /tmp/donna-development.json \
  --engine ArcFace --references /private/reference-gallery \
  --dataset-version donna-development-v1 --set development
```

Human CSV fields include `targetPerson`, `anyFace`, `reviewedBy`, and `set` (`development` or `holdout`);
resolve source-group conflicts before export. `--quality --set holdout` requires reviewed, balanced,
holdout-eligible data with no unresolved leakage warnings. The export helper's current engine choices still
omit AdaFace even though the adapter supports it; do not assume registry and tooling parity. Compare reports
using the existing person-eval comparison tooling, retaining case recoveries/regressions as well as
aggregate deltas.

### Nightly publication contract

The canonical private manifest is `output/person-eval-private/nightly/manifest.json`, or the
`VIDEOSCAN_PERSON_EVAL_MANIFEST` override. Public rows contain sanitized scores/counts/engine labels/status,
never media/reference paths. Readiness is separate from quality: 0 absent manifest, 25 configured awaiting
run, 50 live development/ineligible evidence, 75 quality-intended but failed/ineligible or provenance-gated,
100 publication-eligible. Zero readiness is not zero accuracy.

A publishable report requires explicit `publication.tier: "quality"`, a stable `datasetVersion`, `holdout:
true`, live results for every case, both positive and negative identity labels, and no engine errors.
Fixture/smoke/development and one-sided suites cannot become production quality scores.
`--require-publishable` still writes diagnosis reports but exits 4 when ineligible. Source-group isolation
needs independent review; report eligibility alone does not prove it. The nightly quality firewall
additionally requires `VIDEOSCAN_PERSON_EVAL_ALLOW_QUALITY=1` after that review; this guide does not open
it. The dashboard's production rows require clean main on the primary local nightly.

`docs/poi-cycles/metrics.jsonl` remains the machine-readable experiment stream. Cycles must be unique,
ordered, and contiguous; exactly one `productionBaseline` may exist, and it must be a passing formal grade.
Validate a deliberate metrics edit with `python3 scripts/publish_poi_cycle_metrics.py --check`; this is not
an authorization to publish remotely. Development scores stay separate from the production grade. Missing or
invalid streams must not fabricate a score.

### Recipe calibration and volume triage

```sh
/path/to/VideoScan.app/Contents/MacOS/VideoScan --recipe-calibrate \
  --gallery /private/era-gallery --corpus /private/development-corpus \
  --engine arcface --sex-gate --sex-gate-min-age 0 --sex-gate-male-margin 1.0
python3 scripts/find_donna_scan.py /Volumes/Example \
  --binary /path/to/VideoScan.app/Contents/MacOS/VideoScan \
  --out output/person-eval-private/volume-pass --jobs 1 --frame-step 10 --min-hits 7
```

Calibration reports score distributions, pairwise AUC, and a small-face-bar sweep. It is a native-space
development measurement; use the same gate settings as the intended production arm. The volume script is
existing diagnostic Python tooling around the Swift adapter, not an alternate app implementation. It
defaults to sequential evaluation for HDDs, resumes by recorded path in `scan-progress.jsonl`, and emits
candidate CSV/HTML plus errors. `--no-resume` archives the old progress log; changed binary/configuration
warrants a fresh output directory rather than silently mixing runs. Confirmed rows are machine candidates,
not truth. Near misses have `presence == "none"` and at least three hits; review them for misses and hard
negatives without contaminating holdout.

## 4. Historical evidence: what the experiments established

These results do not establish present-day archive-wide accuracy. The checked-in metric stream still
identifies C3 as its passing production baseline.

| Experiment | Evidence / outcome | Durable lesson |
|---|---|---|
| July 11 six-positive development probe | Vision 0/6, ArcFace 5/6; no reviewed negatives | Detector misses and identity misses need separate diagnosis; one-sided F1 is not a quality grade |
| C1 score aggregation, July 17 | Formal fail: BA .500 vs historical .577; added FN and FP | Compound rate/distance gates did not fix confuser embeddings |
| C2 reference curation, July 18 | Formal fail: BA .538/.577 across repeats | True Donna references fragment by era/quality; dominant-component pruning can hurt era coverage; confusers reached cosine .85–.94 |
| C3 floor 7, July 19 | Formal pass: BA .6154 both repeats, FN 0, 26 clips | Count floor helped this corpus; short appearances and sampling cadence remain limitations |
| C4 logistic head | Development LOCO BA .769, TP/FN/FP/TN 11/2/4/9; no formal holdout grade | Hard negatives helped, but long clips dominate, probabilities overconfident, threshold gap ~.005 |
| C5 deinterlace + quality pooling, July 20 | Formal fail: BA .6154/.6923; strict improvement required in both rounds | Average improvement cannot hide boundary flips; only one corpus clip exercised deinterlacing |
| August 1 Python recipe smoke | 28 development clips, AUC .995; at .40: 14/15 positives, 0/13 FP | Promising smoke, not G2/G3 or native validation |
| August 1 gallery audit | 60 photos, six eras, 56 clean voting references; four flags | Two tiny faces and two attribute mislabels justified conservative gating; no vectors persisted |

The C3 canonical candidate is `{"minHits":7,"mode":"minimumHits"}`, SHA-256
`e981faa37be39891b21a1f650858e24cfef989e2816bf71fe043c2cd15dbe7ea`. Legacy is `{"mode":"legacyAnyHit"}`.
Formal paired grades freeze the binary, configuration and reference set, enumerate/fingerprint the corpus
fresh, retain raw argv/stdout/stderr/exits, and report both AB/BA repeats and every FN. A failed candidate
does not become an approved improvement because its average or best run looks better. The original ≥90% BA
objective was aspirational, not a measured result or standing authorization for further changes.

Historical C4 used a 512-term logistic-regression head, `sigmoid(w·e+b)`, with clip presence based on
maximum face probability, independent of raw cosine hits. Its weights-only artifact
`tools/poi-c04/models/donna-lr-v1.json` pins threshold `0.9848848696322601` and SHA-256
`7ff1ad9a25fb4d434793b9fd399c23712a2905cc4ebd225285ad02e71eea6858`. It trained on 8,079 production ArcFace
rows from the 26-clip training pool. C5 used bwdif and dropped the bottom quartile by pre-normalization
embedding norm before recounting hits, while preserving floor 7 in both comparison arms.

**Historical command warning:** the present `PersonEvaluationCLI.parse` does not accept the C2
`--audit-references`/`--reference-calibration`, C4 `--presence-model`/`--dump-embeddings`, or C5
`--embedding-quality` switches. Their old documents describe branch-specific experiment contracts. Retained
tools/artifacts do not prove the corresponding CLI plumbing is currently wired. Reproducing those
experiments requires their recorded source revision and a reviewed execution environment; do not paste their
flags into today's CLI.

## 5. Synthetic benchmark: transport and identity, not Donna recall

The existing generator uses ControlFace10K fictional identities under CC-BY-4.0, with explicit license
acceptance and `ATTRIBUTION.json` recording source revision and selection. Generate locally with `python3
tools/person-eval/build_synthetic_identity_corpus.py --accept-license --identity-count 25 --seed 1959`. The
default creates 100 verification cases from 25 identities: same/different identity through H.264 MP4 and
FFV1 MKV; 50 unique videos. Outputs remain ignored. Each run has a portable per-identity gallery/corpus
layout for recipe calibration.

Keep three lanes: generic identity verification, Donna hard negatives against a frozen Donna gallery, and
real held-out Donna-positive recall. Synthetic strangers cannot be Donna positives. Report route-specific
scores/tiers, frames, faces, errors and time, plus pairwise route tolerance; never tune and finally report
on the same identities. Publisher demographic labels are cohort metadata, not VideoScan ancestry inference.
No blonde-hair selection was performed; the face-only cohort does not test body shape or establish
“slim/petite” features.

The August 5 M5 Release baseline decoded all 100 cases (24 frames/faces each), with pairwise AUC .7552; only
5/50 same-identity cases reached the high recipe tier and 8/50 either tier, versus 0/50 different
identities. These tier names refer to generic identity tests, not Donna prevalence. Exact-image controls
scored .996 MP4/.999 MKV. A cross-route pair differed by .161 and flipped tier; median absolute route
difference was .0115. That baseline **failed** route invariance. This consolidation did not rerun it or
certify the issue fixed. Source observed then: `420c04b5ba37df6b81a0ba7600b6c0d5b72aa97b`; binary SHA-256
`3eebe4ae1ef27b4fcb4bc7399684f97944ad38f06b5d6190fa1023754daeee94`. Use
`tools/person-eval/summarize_synthetic_identity_benchmark.py --log ... --output ... --binary-sha256 ...
--source-commit ...` for captured run logs.

## 6. Unfinished designs and review priorities

The following are directions to evaluate, not assertions that all are implemented:

- **Observation/track persistence:** retain selected high-quality track exemplars
  with record ID, time, bounding box, quality, model version, person assignment,
  and provenance. Reuse detection work across queries without retaining every
  near-duplicate frame. Start with measured local SQLite/packed-vector costs;
  sqlite-vec/FAISS/HNSW are options, not approved dependencies or promised latency.
- **Identity assignment:** borrow core/deferred assignment, correction vetoes,
  ambiguous states, explicit merge/reassign/hide workflows, and model-version
  invalidation. Immich and PhotoPrism audits describe dated photo-manager
  implementations; they are architectural references, not current product facts.
- **Tracking and richer evidence:** track-level votes, best-frame quality,
  same-frame cannot-links, body/voice/context channels and age/date priors require
  independent measurements. The original MiVOLO/CR-FIQA/AdaFace recipe was a
  proposal; the implemented native recipe is not that entire pipeline.
- **Training:** prefer measuring a frozen embedding plus small classifier before
  partial/full backbone fine-tuning. Use reviewed positives and hard negatives,
  source-disjoint holdouts, per-model provenance, local data, and bounded storage.
  Training-size, runtime and vector-index estimates in early brainstorms were
  forecasts, not benchmarks. A positive video label does not label every face.
- **Catalog priors:** codec/date/folder signals can prioritize work. Do not silently
  discard short, small, low-score or “no target found” media as junk. No person
hit is not no face, and no face is not no family value. Partial hashes alone
  do not prove content identity; negative caches need configuration/version and
  honest completed-coverage invalidation. Keyframes do not guarantee scene starts.
- **Original recipe gates:** gallery audit → development comparison → new era-
  stratified blind holdout → one-volume human review before broader promotion.
  The historical G1/smoke results do not certify every later gate completed.
- **Hardening:** re-check worker cancellation/accounting, fair admission, cache
  restore bounds, single-flight reference preparation, prediction failure
  visibility, typed/strided model output, terminal progress and preview lifetime.
  June audit findings are historical leads, not a verified list of open bugs.
  `thresholdForEngine` now exists, illustrating why old “missing seam” claims
  need source checks before reopening them.

Validation should span logic, 100k-record scale where applicable, actual media routes (MP4/H.264,
MOV/ProRes, MKV/FFV1+PCM, MXF, AVI/DV), poisoned preferences/ caches, and production-scale regression
sensors. Accuracy experiments supplement unit and transport tests; they do not replace them. Inspect
detector recall, identity recall, false positives, decoder failures and performance separately.

The April diagnostic/CLI handoffs add two durable lessons: separable still-photo embeddings do not
demonstrate video-frame accuracy, and duration/frame-budget filters can hide thousands of short family
clips. Existing legacy tools `scripts/fd_diagnostic.py`, `scripts/fd_scan_volume.py`, and
`scripts/find_person.py` belong to that earlier FaceNet/dlib research lane; their distance thresholds and
STRONG/WEAK labels are not current recipe tiers. Verify the interpreter and installed packages before
replay: the recorded venv had Python 3.12 packages behind a Python 3.14 default symlink. A `no_frames`
decode outcome is an operational error to inspect, not proof of no target person or proof that media is
unrecoverable. Labeled timelines and human corrections remain the foundation for deciding which engine
changes actually help.

### Models, licensing, and focused specifications

Keep model-code licenses separate from weights and training-data terms. AdaFace code is MIT; the recorded
WebFace4M checkpoint restrictions prohibit treating that as public redistribution permission. InsightFace
model permissions granted to Immich do not automatically extend to VideoScan. MiVOLO weight terms need
separate review before adoption/distribution. These are carried-forward project constraints, not a new legal
determination. Copy architectural ideas deliberately; Immich's AGPL source cannot be transplanted as if
license-free.

Original research entry points (dated evidence, not newly verified benchmarks): [AdaFace code and
license](https://github.com/mk-minchul/AdaFace), [SCRFD](https://arxiv.org/abs/2105.04714),
[MiVOLO](https://arxiv.org/abs/2307.04616), [per-person calibration paper cited in the
digest](https://arxiv.org/abs/2606.04469), [ControlFace10K source and
license](https://huggingface.co/datasets/HuMInGameLab/ControlFace10K), and [SIG synthetic identity
paper](https://arxiv.org/abs/2409.08345). For the audited implementations, see
[Immich](https://github.com/immich-app/immich) and [PhotoPrism](https://github.com/photoprism/photoprism);
consult the recorded audit revision before assuming today's repository matches the old findings.

Retain [AdaFace conversion and provenance](design/adaface-plugin.md) as the focused specification: exact
112px BGR normalization, checkpoint hash, fp32/fp16 parity gates, model packaging, backend cache tokens and
migration details are needed for reproducible model work. Its dated installation instructions require
checking actual model locations before reuse. Retain [compilation bucketing](compilation-bucketing.md) as
the focused media specification: adjacent compatible runs preserve chronology; A/B/A is three runs, with a
30-minute soft cap and codec-appropriate containers. Its original “no test target” and “single-file merge
deferred” status is historical: `PersonFinderCompilation.swift` now includes `pfMergeBucketsToSingleFile`.
Stream-copy bucket assembly does not mean preceding AVFoundation extraction was lossless. Keep those
separate claims when changing the export path.

## 7. Provenance and historical source inventory

All following originals were read at source snapshot `59ca9468c01e0068501206c63698286c10f4e8b7`; retrieve
detailed historical tables, branch hashes and designs from that revision. Paths are provenance, not live
links or instructions to rerun old work. No original log or conversation grants new authorization. The
retained focused specifications are identified above.

- `docs/find-and-tag-design.md`; `docs/tagging_people.md`
- `docs/compilation-bucketing.md`; `docs/catalog-aided-face-detection.md`
- `docs/family_media_training_model.md`; `docs/find_donna_scan.md`
- `docs/donna-recipe-v1.md`; `docs/donna-recipe-smoke-2026-08-01.md`
- `docs/donna-gallery-report-2026-08-01.md`
- `docs/person-recognition-evaluator.md`; `docs/person-eval-handoff-2026-07-11.md`
- `docs/synthetic_person_benchmark.md`
- `docs/design/adaface-plugin.md`; `docs/design/unified-review.md`
- `docs/issue-02-face-detection-accuracy.md`; `docs/issue-03-dlib-rt-window.md`
- `docs/issue-04-hybrid-fd-mode.md`; `docs/issue-06-custom-face-model.md`
- `docs/issue-07-multi-engine-simultaneous.md`; `docs/issue-09-additional-fd-algorithms.md`
- `docs/immich_ideas.md`; `docs/immich_reassessment_2026-06-20.md`
- `docs/hardening_audit_2026-06-20.md`; `docs/test_gap_face_pipeline_2026-06-20.md`
- `docs/poi-cycles/ledger.md`; `docs/poi-cycles/cycle-01-aggregation.md`
- `docs/poi-cycles/cycle-02-refs-threshold.md`; `docs/poi-cycles/cycle-03-minimum-hits.md`
- `docs/poi-cycles/cycle-04-donna-classifier.md`; `docs/poi-cycles/cycle-05-embedding-quality.md`
- `docs/research/immich-photoprism-face-audit-2026-08-01.md`
- `docs/research/person-id-deep-research-2026-08-01.md`
- `docs/session_handoff_2026_04_24.md`; `docs/morning_briefing_2026_04_23.md`
