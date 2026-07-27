# AdaFace Plugin — Design & Provenance (GH #144)

Replaces dlib's seat in the Search algorithm registry with AdaFace, via the
existing `RecognitionEngine` plugin seam. dlib is removed from Search UI,
registry, settings, and dispatch. AdaFace does NOT become the default engine
(that stays `.vision`); promotion over ArcFace is gated on the Donna eval.

## 1. Plugin seam (recon findings)

The "plugin contract" is the `RecognitionEngine` enum registry in
`PersonFinderTypes.swift` plus one dispatch switch:

| Surface | File | Notes |
|---|---|---|
| Registry | `PersonFinderTypes.swift` — `enum RecognitionEngine` | UI iterates `allCases`; rawValue is the persistence token |
| Dispatch | `PersonFinderModel+JobLifecycle.swift` — `processOneVideo` switch | one case per engine, all funnel into `pfVideoResult` |
| Eval CLI dispatch | `PersonEvaluationCLI.swift` | mirrors the same switch |
| Engine picker UI | `ScanJobRow+Pickers.swift` — `inlineEnginePicker` | fully registry-driven (`ForEach(RecognitionEngine.allCases)`) — no per-engine branch needed to appear |
| Per-engine settings popover | `ScanJobRow+Pickers.swift` — `engineSettingsPopover` | had dlib-only Python path fields (removed) |
| Memory budgets | `MemoryPressure.swift` — `workerBudgetMB` / `hardCap` | per-engine case |
| Pre-flight | `PersonFinderModel+JobLifecycle.swift` `runJob` | dlib had a Python-config bail path (removed) |
| Per-video result cache | `PersonFinderCache.swift` | keyed by `(videoPath, size, modDate, person, engine.rawValue, threshold, refHash[+variant])` |

Engine contract: `(filePath, settings, callbacks) async -> pfVideoResult?`
with progress/log/dist callbacks, `PauseGate`, and `Task.isCancelled`
cooperative cancellation.

## 2. Model provenance

- **Paper**: AdaFace: Quality Adaptive Margin for Face Recognition,
  Kim et al., CVPR 2022. Chosen because the quality-adaptive margin
  is trained to remain discriminative on low-quality faces — a good fit
  for VHS-era family footage (see IJB-B/C low-quality benchmark results).
- **Code**: https://github.com/mk-minchul/AdaFace — **MIT license**.
- **Checkpoint**: `adaface_ir50_webface4m.ckpt` (IR-50 backbone, trained on
  WebFace4M), downloaded from the README's official Google Drive link
  (file id `1BmDRrhPsHSbXcWZoYFPJg2KJn1sd3QpN`).
  - SHA-256 recorded below in §6.
  - Backbone parity with ArcFace: our ArcFace model (`w600k_r50`, insightface)
    is also a ResNet-50-class backbone trained on WebFace600K (a cleaned
    subset of WebFace4M) — so the eval comparison is backbone- and
    data-scale-fair.
  - **Training-set license status**: the AdaFace *code* is MIT, but the
    WebFace4M dataset is released for **non-commercial research** use only,
    and the checkpoint is a derivative of it. For this personal/family
    archive project that is acceptable; do not redistribute the converted
    model publicly. (We deliberately avoided the MS1MV2 checkpoints —
    MS-Celeb-1M was retracted by Microsoft.)

## 3. Preprocessing (exact)

Canonical reference: `inference.py` in the AdaFace repo.

- Input: 112×112 aligned face crop.
- Channel order: **BGR** (`np_img[:,:,::-1]` from RGB).
- Normalization: `(x/255 − 0.5)/0.5` = `x·(2/255) − 1` per channel
  (i.e. (x−127.5)/127.5 — note **127.5**, not 128).
- Output: `(embedding[512], norm)` tuple; the embedding is compared by
  cosine after L2 normalization.

CoreML conversion bakes all of this in:
- `ct.ImageType(color_layout=BGR, scale=2/255.0, bias=[-1,-1,-1])` — CoreML
  handles the ARGB pixel-buffer → BGR conversion, so the Swift side feeds the
  exact same 112×112 RGB `CVPixelBuffer` it already builds for ArcFace.
- Input feature name **`faceImage`**, output a single 512-d MultiArray —
  deliberately the same I/O contract as `w600k_r50.mlpackage`, so the proven
  `arcfaceEmbedding()` CoreML plumbing (resize → pixel buffer → predict →
  L2-normalize) is reused verbatim.
- Alignment convention: same 5-landmark ArcFace template (insightface
  `norm_crop`) — AdaFace uses the identical alignment as ArcFace, so the
  existing crop paths (`pfNormalizeFaceCrop` bbox crop, and the optional
  `arcfaceAlignedCrop` norm_crop) apply unchanged.

Conversion + parity scripts: `tools/adaface/convert_adaface_coreml.py` and
`tools/adaface/parity_check.py`. Parity gate: cosine(CoreML, PyTorch) ≥ 0.999
per test image.

**Parity results (2026-07-27, 30 images from `tests/fixtures/photos`,
CPU_ONLY compute for determinism):**
- fp32 conversion: **30/30 pass, cosine = 1.000000** on every image — the
  preprocessing/channel-order/normalization pipeline is exact.
- fp16 conversion (the deployed artifact, same precision as the ArcFace
  `w600k_r50` package, 83 MB): **29/30 ≥ 0.999**, min 0.998992, typical
  0.9994–0.9997. The single sub-gate image is weight-quantization noise
  (proven by the fp32 run), not a conversion bug.
- Toolchain: Python 3.12 venv, torch 2.7.0, coremltools 8.3.0. (The shared
  project venv is Python 3.14, where coremltools' native BlobWriter fails
  to load — do not use it for conversion.)

## 4. Score interpretation & threshold

- Match score = cosine similarity of L2-normalized 512-d embeddings,
  range [−1, 1], higher = same identity (same convention as ArcFace;
  the pipeline's "distance" fields carry `1 − cosine`).
- Default threshold: **0.30** (`adafaceThreshold`). AdaFace embeddings
  produce somewhat lower same-identity cosines than ArcFace on hard pairs;
  published verification operating points for IR-50-class models sit around
  0.25–0.40 cosine. 0.30 is a starting point — tune on the Donna eval
  before any promotion decision.

## 5. Backend-keyed embeddings

AdaFace and ArcFace embeddings live in the same 512-d shape but are NOT
comparable. Keying:

- **Per-video result cache** (`PersonFinderCache`): already keyed by
  `engine.rawValue` — `"AdaFace (CoreML)"` vs `"ArcFace (CoreML)"` rows can
  never collide. Additionally the ref-hash gains a backend/model-version
  variant token `adaface-ir50wf4m-v1` (same mechanism as ArcFace's `lm-v1`
  alignment variant), so a future checkpoint swap busts the cache
  deterministically.
- **Per-job reference embeddings**: `ScanJob.assignedRefEmbeddings` is a
  dictionary keyed by backend token (`arcface|w600k_r50` /
  `adaface|ir50_webface4m_v1`) replacing the old single
  `assignedArcFaceEmbeddings` field — switching a job between engines can
  never reuse cross-backend vectors.

## 6. Model packaging & distribution

Follows the ArcFace pattern exactly:
- `.mlpackage` lives in `~/dev/VideoScan/models/adaface_ir50_webface4m.mlpackage`
  (the `/models/` dir is gitignored; models are distributed out-of-band).
- Runtime compiles `.mlpackage → .mlmodelc` once and caches it alongside.
- App-bundle fallback (`adaface_ir50_webface4m.mlmodelc` as a bundle resource)
  is honored, same as ArcFace.
- Missing model → actionable error string naming the expected path.

Checkpoint SHA-256 (`adaface_ir50_webface4m.ckpt`, 596,517,267 bytes):
`52cca7c64808fea6f44f9b9aee2b0e091bf96c1ab4f6e31bedcdf5d77009b4f8`
Converted mlpackage produced by `tools/adaface/convert_adaface_coreml.py`
(records coremltools + torch versions in the model metadata).

## 7. Concurrency model (ArcFace MLE5 lessons applied)

- Per-worker `MLModel` instances from day one: `AdaFaceModelLoader` (actor)
  resolves/compiles the model URL once, then hands a FRESH `MLModel` per
  `getModel()` call — never a shared instance across concurrent inference.
- All predictions run under the process-wide prediction lock via the
  existing `arcfaceEmbedding(..., useSharedPool: false)` path, i.e. the
  serialized configuration that has been crash-free since 2026-05. AdaFace
  does NOT participate in the experimental ArcFace K>1 pool
  (`ArcFacePredictor` slots hold ArcFace models; borrowing them from the
  AdaFace path would be a cross-model bug).
- Worst-case memory: one 112×112×4 crop + one 512-float embedding per
  in-flight face, model weights ~175 MB fp16 once per worker; budgeted at
  768 MB/worker in `MemoryPressureMonitor` (same as ArcFace).

## 8. dlib removal & migration

dlib footprint audit (2026-07-27):

**Removed (Search-path only):**
- `RecognitionEngine.dlib` case + all its registry metadata.
- `pfProcessVideoWithDlib` + JSON decode types (`PersonFinderEngineDispatch.swift`).
- dlib pre-flight bail + log lines in `runJob`.
- `dlibReady` / `dlibReadyForHybrid`, `pythonPath` / `recognitionScript`
  settings, their persistence keys and UI fields.
- `.dlib` memory budget cases.
- Eval CLI dlib dispatch.
- dlib-specific tests (replaced by AdaFace equivalents + sensor).

**Kept (not Search-path):**
- `scripts/face_recognize.py` — the engine the app used to shell out to.
  Kept on disk, header marked DEPRECATED (no longer reachable from Search);
  still runnable standalone.
- `scripts/fd_diagnostic.py`, `scripts/find_donna_scan.py`,
  `scripts/find_person.py`, `tools/person-eval/*` — diagnostic/eval tooling
  that imports dlib independently. Untouched.
- The dlib Python venv note in `AudioTranscriber.swift`/`ProcessRunner.swift`
  comments (whisper venv separation rationale) — historical context, accurate.

**Hybrid seat**: `.hybrid` was "Vision + dlib fallback". It becomes
"Vision + AdaFace fallback" — same shape, better fallback. Its rawValue
(persistence token) changes accordingly and is migrated.

**Deterministic migration** — `RecognitionEngine.migratePersisted(_:)`:
| Persisted token | Result |
|---|---|
| `"dlib/Python (accurate)"` | `.adaface` (least surprise: dlib's "accurate second engine" seat) |
| `"Hybrid (Vision + dlib fallback)"` | `.hybrid` (new rawValue) |
| current rawValues | themselves |
| anything else (poisoned) | `nil` → caller falls back to `.vision` exactly as before |

Applied at every decode site: `PersonFinderSettings.restoreStrings`,
`POIProfile` apply/read sites (`applyProfile`, `effectiveEngine`,
Find-Person picker), scan-jobs restore (`descriptor.engine`), and
`BundleModels`.

**Regression sensor**: `ModelTests` asserts `.dlib` no longer exists —
`RecognitionEngine.allCases` contains no case whose rawValue/title/display
name mentions "dlib", and AdaFace occupies a seat. A UI-facing sensor also
greps the registry metadata strings.

## 9. Eval gating

AdaFace ships selectable but non-default. Promotion to default (or to the
recommended engine for POI profiles) requires beating ArcFace on the Donna
eval (`PersonEvaluationCLI` / graded POI cycles). Not part of this change.
