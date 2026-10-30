# Video LLMs for the Breen media — a pluggable approach lab (design, 2026-10-30)

*Rick said "design it" on 2026-10-30, after reading two outside architecture documents (an FMIS/RAG sketch and a
"Modular Video Intelligence Architecture" PDF). This is the VideoScan answer: how a video model becomes one more
evidence engine in the INGEST → MANAGE → ARCHIVE spine, how we plug in one approach after another and measure which
earns its place, and what "an expert on the Breen media" means under the rulings. It builds on
`docs/design/provenance_retroactive_2026_10_26.md` (Phases A–E, the assertion table),
`docs/research/provenance_retroactive_fingerprinting_2026-10-25.md` (what exists, what the outside specs got wrong),
`docs/research/family_event_learning_review_2026-10-16.md` (what "training on our media" may mean) and
`docs/design/events_design.md` §1 (the ten evidence rules). It repeats none of them where a pointer will do.
Claude Code and Rick read this as the starting point; it is not yet built.*

## 0. In one page

1. **A video LLM is an evidence engine, never an authority.** It emits typed, timestamped, machine-signed
   *assertions* (era, scene, on-screen text, occasion kind, room features, spoken name beside a visible child) with a
   rationale and the frames it looked at. The catalog, `DateTriangulator`, Events and the Provenance sheet rank that
   evidence by evaluated rules; Rick confirms; a rejected value is never re-proposed. This is Charter §Agentic and
   DECISIONS 2026-08-16 (no fine-tune as a fact store), 2026-08-14 (deterministic facts, LLM phrases) and
   2026-09-23 (similarity never creates lineage).
2. **"Plug in an approach, try it, plug in the next" is three seams, not one.** A *Sampler* turns a file into model
   input (stills today; chronological windows and timed audio segments next). An *Approach* is one model + one host +
   one prompt family + one output contract, registered by id and revision. A *Judge* scores an approach against
   ground truth VideoScan already holds (73 Rick-dated files, 5,635 camera-dated files, 18 confirmed events,
   1,448 OCR dates). Every approach lands its raw output in a lab sidecar; only a **promoted** approach may write the
   catalog, and only through the existing tables and the one commit door.
3. **Everything runs local** (DECISIONS 2026-10-10). The M5 Ultra holds one resident 20–40 GB model beside the app;
   the M4 keeps the 3B model and read-only model jobs. A cloud slot exists in the registry for *derived text only*
   and ships disabled, behind a payload-class gate with a sensor, until Rick rules on the backlog question.
4. **Learning means examples first, weights last.** Example memory (Rick's confirmed events, names, dates retrieved
   into the prompt) → a small pair classifier over his Events decisions → LoRA on extraction only if errors are
   extraction errors. Never a model that "knows" that Donna was in Maine in 1998; that lives in CyberBrain and the
   catalog, inspectable and correctable.
5. **Order of work by proof per hour:** wrap what exists as approach `A0` and publish its baseline numbers (one day,
   no new model) → chronological windows + a strict JSON contract on the same 3B model (`A1`) → Qwen3-VL on the Ultra
   through a Python worker (`A2`, the Phase E era benchmark finally runs) → promotion into `provenance_assertions`
   (Phase C, schema v14, Rick's approval, Codex) → embeddings for room/occasion retrieval (`A4`) → example memory and
   the pair classifier (`A5`).

## 1. What the outside documents proposed, and what VideoScan does instead

| Outside proposal | Here | Why |
|---|---|---|
| Fine-tune / "train" an LLM on the archive; Neo4j graph as the family's truth | Example memory over CyberBrain + the GEDCOM graph in Core; facts stay in data | DECISIONS 2026-08-16; `cyberbrain_design.md` §2 lists the six reasons |
| Gemini / GPT-4o / Claude on raw hour-long video | Local VLM on the Ultra; cloud never sees family pixels or audio | DECISIONS 2026-10-10 (rule 13 of CLAUDE.md) |
| Celery/Redis/Prefect worker pool, MinIO object store, Qdrant/pgvector | One MFO job with a lane per volume; media stays where it is; vectors and raw runs in a sidecar SQLite beside `audio-fingerprints.sqlite` | ARCHITECTURE §4 (MFO), 10/14 ruling (bulk in a sidecar, the catalog carries the stamp), rule 6 (one commit door) |
| DBSCAN clusters become "Events"; LLM names them from one keyframe | Events v1 proposes; a learned score may only *rank* suggestions; Rick confirms | `events_design.md` §1 rules 5 and 9; the 10/16 review §2 ("the same table every Christmas is an adversarial dataset") |
| InsightFace / FaceNet identity across 40 years | Frozen (Rick 10/23). Within-occasion continuity only (same clothes, same voice for an afternoon) | ARCHITECTURE §3 People |
| Model's own `confidence_score: 0.95` shown to the user | Confidence words come from evaluated rules on Rick's footage; the raw number is stored, never displayed | `events_design.md` rule 9 |
| "LLM → Cypher query" over the graph | Hallie's QueryAST → deterministic executors (built, paused) | DECISIONS 2026-08-14 |
| Structured JSON per temporal window with era clues, environmental fingerprint, audio anchors | **Adopted.** This is the one new thing. It becomes the output contract of §3.3 and lands in `provenance_assertions` | Charter §Provenance ("machine generated needing human confirmation") |
| "Contextual constellations": green shag carpet in 15 videos across 10 years = Grandpa's house | **Adopted as context, not identity**: a `roomFeatures` field family, retrieval by embedding, gated on the 18 confirmed events | BACKLOG "recurring locations as context not identity" |
| Audio-visual alignment ("look over here, Jimmy" + a child in frame) | **Adopted** once Whisper segment timing is retained (BACKLOG) — a `spokenNamePresence` field, probabilistic, within-occasion | the 10/16 review §4 |

## 2. What exists today (pointers)

| Piece | Where | State |
|---|---|---|
| In-process VLM, Qwen2.5-VL-3B-4bit on MLX-Swift (`mlx-swift-examples` 2.29.1), one still per call, three prompts (date / scene / text), 448×448 | `Media/CaptionRunner.swift` (`CaptionRunner` protocol, `MLXVLMCaptionRunner` actor), `Media/CaptionOrchestrator*.swift` | live; 4,518 contents captioned; 1,448 OCR date candidates |
| Frame extraction, AVFoundation then ffmpeg fallback (FFV1/MKV masters) | `extractFramesForCaptioning` | live, tested on an MKV fixture |
| Whisper medium on MLX through a long-lived Python worker (JSONL over stdin/stdout) | `scripts/whisper_worker.py`, `Media/WhisperWorkerTranscriber.swift` | live; **segment timing discarded** |
| Date fusion with ranked claim kinds (`ocrBurnIn, cameraStamp, spokenNow, …, eraFloor, prior`) | `Catalog/DateTriangulator.swift` | live; no `era` kind yet |
| Events v1 (nine phrase-rule categories, folder/date adjacency), decisions stored apart from model output | `Events/`, `EventsDecisionStore` | live; 18 confirmed events, 42 members |
| Hallie's LLM host: Ollama, `qwen3.8:27b-mlx`, failover hosts, structured-output capability probe | `Hallie/LLM/` | built, paused 10/16 |
| Tool-transport benchmark discipline (run record: model tag + digest, prompt hash, git SHA, seed, corpus hash) | `tools/qwen-bench/` | the template for §4's harness |
| Catalog tables for derived text: `captions (scene/ocrDate/ocrText)`, `caption_runs`, `transcripts`, `dossiers`, `inferred_dates`; bound-vs-`derived_unverified` discipline | `docs/design/catalog_sqlite_schema_v1.sql` | live; triggers refuse silent replacement |
| Provenance assertion table with the rejected-value veto | `provenance_retroactive_2026_10_26.md` §v14 | designed, not built (schema v14 needs Rick) |
| Python venvs: `venv-mlx/` (mlx-vlm, mlx-whisper, Python 3.12), separate from `venv/` | `scripts/requirements-mlx.txt`, `docs/guides/ops/python_paths.md` | live on all fleet nodes |

## 3. The design

### 3.1 Shape: three ports and a registry

```
            Sampler                         Approach                         Judge
  file ───▶ (stills | windows | audio) ───▶ model + host + prompt + ───▶ raw run in sidecar ───▶ scores vs ground truth
            pure plan, shared decode         output contract                (lab notebook)         (promote / reject)
                                                   │
                                     promoted only ▼
                              catalog, through the one commit door:
                  provenance_assertions · captions · transcripts · inferred_dates(era)
```

C++ reading: `VideoEvidenceApproach` is an abstract base class; `ApproachRegistry` is a factory keyed by
`(id, revision)`; the output contract is a strict parser that throws rather than coerces; the sidecar is the lab
notebook every run writes before anyone decides whether it was any good.

Everything in this section lives in **one new app folder `VideoScan/VideoScan/ModelLab/`** plus pure types in Core
(`VideoScanCore/Sources/VideoScanCore/ModelLab/`). **No `extension VideoScanModel`** (rule 12). State the UI needs
lives in a `ModelLabStore` feature store injected through the environment (#337 pattern); Phase 0 needs none, the job
owns its results (the `PairCompareJob` pattern).

### 3.2 Sampler — how a file becomes model input

```swift
/// Pure: given probe facts, returns a plan. Decode happens in the job through the existing extractors.
protocol EvidenceSampler: Sendable {
    var id: String { get }                       // "stills-8", "window-60s-1fps-scenecut", "audio-segments"
    func plan(for probe: SamplerProbe) -> SamplePlan
}
struct SamplerProbe: Sendable { let durationS: Double; let fps: Double; let hasAudio: Bool; let sceneCutsS: [Double]? }
struct SamplePlan: Sendable { let windows: [SampleWindow] }
struct SampleWindow: Sendable, Equatable {
    let startS: Double, endS: Double            // closed range in the file
    let frameTimesS: [Double]                   // what the model sees, in order
    let audioRange: ClosedRange<Double>?        // nil = no audio for this window
}
```

| Sampler | What it does | Serves |
|---|---|---|
| `StillsSampler(n)` | today's `framesEvenlySpaced`, middle 90 % | `A0` control; OCR date/text |
| `WindowSampler(seconds: 60, fps: 1, cutAt: sceneCuts)` | consecutive chronological windows, boundaries snapped to scene cuts (ffmpeg `select='gt(scene,0.3)'` today; the Phase B 1 fps picture timeline when it exists) | era, scene, occasion, room features |
| `AudioSegmentSampler` | Whisper segments **with timing** (the worker returns `segments: [{start, end, text}]`; a one-line change in `whisper_worker.py`, a new column-free write: `transcripts.text` unchanged, segments go to the sidecar until a schema row is approved) | spoken-name presence, spoken year |

Samplers never decode. The job decodes through `extractFramesForCaptioning` (AVFoundation, ffmpeg fallback) and
`ProcessRunner` for audio, one lane per volume, exactly as the backfill jobs do. A window of N frames at 448×448 is
N × ~600 KB in flight; 60 frames ≈ 36 MB. No cache needed.

### 3.3 Approach — one model, one host, one prompt family, one contract

```swift
protocol VideoEvidenceApproach: Sendable {
    var id: ApproachID { get }                    // model + prompt family + sampler, e.g. "qwen3-vl-32b-4bit/era-v1/window-60s"
    var revision: Int { get }                     // bump on any prompt or parameter change; prompt text is hashed into the run record
    var host: ApproachHost { get }                // .mlxSwift | .pythonWorker(venv: "venv-mlx", script:) | .ollama(hosts:) | .remoteTextOnly
    var accepts: PayloadClasses { get }           // [.pixels, .audio, .derivedText] — what the model may be sent
    var emits: Set<FieldFamily> { get }           // era, scene, ocrDate, ocrText, occasionKind, roomFeatures, carrierClues, spokenNamePresence
    var resources: ResourceProfile { get }        // peak RAM GB, needs one resident model, expected s/window on Ultra and M4
    func run(_ window: SampleWindow, frames: [CGImage], audio: URL?, transcript: [TimedSegment], context: PromptContext) async throws -> ApproachOutput
}
```

- **Hosts.** `.mlxSwift` is `MLXVLMCaptionRunner` as it is. `.pythonWorker` is the Whisper worker shape (one
  long-lived process per job, JSONL request/response, `mx.set_cache_limit`, `clear_cache` per request) running
  `mlx-vlm` in `venv-mlx` — this is how Qwen3-VL's native video input and Gemma 4 arrive without waiting for
  `MLXVLM` to support them. `.ollama` reuses `OllamaEndpoints` for vision-capable tags. `.remoteTextOnly` exists so
  the registry has a slot; it is `enabled = false` and the runner **refuses** any payload class but `.derivedText`
  before a byte leaves the process (sensor, §6).
- **One resident model at a time** (`CaptionRunner.swift` already enforces this); the job declares its
  `ResourceProfile` and refuses to start on a host that cannot hold it (the 3B model fits the M4; a 32B 4-bit model
  is the Ultra's job; a 65–75 GB Gemma 4 31B at long context is Ultra-only with a warning).
- **The output contract is a fixed JSON schema per field family.** The model is told the schema; a Swift `Decodable`
  with every field typed decodes it; a response that does not decode is dropped and logged as `schemaInvalid`, never
  repaired, never coerced (the Hallie translator's fail-closed rule). One schema per family so a model that is good
  at OCR and bad at era does not drag the other down:

```json
{ "family": "era", "window": [120.0, 180.0],
  "yearRange": [1991, 1995], "rationale": "4:3, camcorder OSD 'SP', boxy sedan, CRT television",
  "cues": [{"kind": "technical", "text": "analog tracking lines at frame bottom", "atS": 131.0},
           {"kind": "cultural",  "text": "Charlotte Hornets starter jacket",       "atS": 140.0}],
  "selfConfidence": 0.7 }
```

```json
{ "family": "roomFeatures", "window": [0.0, 60.0],
  "setting": "indoor", "locationType": "residential living room",
  "features": ["green shag carpet", "brick fireplace", "oak panelling"], "selfConfidence": 0.8 }
```

- **`ApproachOutput` → `EvidenceAssertion`** (pure, in Core): subject = content digest (never a path, rule 6),
  range = the window, field = family-specific (`era.yearRange`, `room.feature`, `occasion.kind`, …), value, `by =
  "machine:<approach id>@r<revision>"`, `evidence_json` = rationale + cues + frame times + prompt hash + host +
  elapsed. `selfConfidence` is kept in `evidence_json` and is **not** the confidence the UI shows (`events_design` rule 9).
- **`PromptContext`** is where example memory enters later (§5 `A5`): a handful of Rick-confirmed examples retrieved
  by similarity, and the known constraints (the birth years of the people tagged on the file, the folder year, the
  carrier if confirmed). Phase 0–2 pass an empty context so the baseline is the bare model.

### 3.4 Where output goes

| Stage | Store | Rule |
|---|---|---|
| Every run, every approach | **sidecar `model-lab.sqlite`** beside `audio-fingerprints.sqlite`: `runs (run_id, approach_id, revision, prompt_hash, host, model_digest, git_sha, started_at)`, `outputs (run_id, content_digest, size_bytes, window_start_s, window_end_s, family, raw_json, schema_valid, elapsed_s)`, `segments (content_digest, engine, start_s, end_s, text)` for timed transcripts; `vectors` for §5 `A4`. Keyed by digest; open/close/WAL rules exactly as `provenance_retroactive_2026_10_26.md` §sidecars; never in git; nightly `.backup` with the catalog | the lab notebook; append-only; `BEFORE DELETE … RAISE(ABORT)` |
| Promoted approach only | the catalog, through `CatalogCommitter`: `provenance_assertions` (state `inferred`, Phase C / v14) for era, carrier clues, room features, occasion kind; `captions` for scene/OCR text (existing kinds); `inferred_dates` with a new `source = 'era:<approach>'` and a `DateCriterionClaim.Kind.era` ranked **below `pathHint`** at confidence ≤ 0.3 with a ±7-year range | an approach is promoted by a Judge verdict (§4) recorded in `docs/reviews/video_llm_benchmarks.md` and one DECISIONS line; never by a flag flip alone |
| Archived rows | background writers add metadata only; never a name or date (rule 3) | unchanged |

An unpromoted approach cannot reach the catalog: the only writer is the promotion job, and it takes an approach id
that must appear in the promoted set compiled into the build (a sensor proves it, §6).

### 3.5 The job

One MFO job, verb **Analyze with Model…** (`MediaFileOperationKind` new case), one engine (rule 4):

- Inputs: a selection or a volume, one approach, one sampler, a budget (max windows per file, max files). Lane per
  volume. Pause/Stop via `JobPauseCoordinator` where the work is a child process; cancellation checked between windows.
- START line names approach id, revision, prompt hash, host, model digest, sampler, file count. Progress: files N of
  M, window k of K, s/window rolling. OUTCOME: windows run · schema-valid · invalid · skipped (unreadable) · s/window
  · peak RAM · sidecar rows before/after (rule 5, ARCHITECTURE §4 Logging).
- Read-only toward media (never writes, never re-encodes; frames are ripped to a temp dir and removed).
- Machines: the Ultra runs big models on local drives. The M4 may run **read-only model jobs** on the 3B model only;
  no family media over SMB from the M4 beyond that (STATUS 10/26).
- Catalog Status: a model-lab run never changes the catalog's truth state; a promotion run stamps like any other
  cycler (last completed pass + digest).

## 4. The Judge — benchmarks are the red/green for a model

A model is admitted the way a bug fix is: seen failing (baseline numbers), then seen passing a bar. Per family:

| Family | Ground truth already held | Split | Metric | Bar to promote |
|---|---|---|---|---|
| **era** | 73 Rick-dated rows + a stratified 200 of the 5,635 `creation_time` rows (iPhone era · DV 1995–2005 · VHS 1984–95 transfers) | by decade and by carrier; frozen manifest of digests in `.scratch/`, never paths | MAE in years; share within ±5 y; per decade | MAE < 7 y on the VHS/DV strata (the still-photo ceiling in the literature) — Phase E's bar, unchanged |
| **ocrDate / ocrText** | the 1,448 OCR candidates with `DateTriangulator`'s verdict | by carrier | exact match of the date string; schema-valid rate | ≥ the 3B baseline on both; no regression on `Clip 03_converted.mov` ("JUN 21 1991", 11 of 15 frames) |
| **occasionKind** | 18 confirmed events (42 members) + rejections + "different occasion" decisions | by occasion and by lineage (copies excluded from both sides so the task is not trivially easy) | precision@k of suggested members; category accuracy over the nine | precision@5 ≥ 0.8 on held-out occasions |
| **roomFeatures** (retrieval) | **needs one hour of Rick**: label ~50 clips with "which house / which room" (CyberBrain place ids) | by decade | precision@k "same place" | ≥ 0.8 before it may suggest; otherwise stays a lab result |
| **spokenNamePresence** | People tags on the file + the timed transcript | by file | precision of "name spoken at t AND a child visible at t" against Rick's tags | reported; may never assert identity, only within-occasion continuity |
| **scene** (free text) | none | — | schema-valid rate; words per window; s/window | reported only; scene text is search fodder, not a fact |

Every family also reports **cost**: seconds per window on the Ultra and the M4, peak RAM, model load time. A model
that is 2 points better and 20× slower loses on 450 hours of footage; the table says so in numbers.

**Harness.** `tools/video-llm-bench/` (Python, `venv-mlx`) following `tools/qwen-bench`'s discipline: a run record
with the exact model tag and digest, prompt hash, sampler id, git SHA, corpus hash and seed; per-clip JSONL in
`.scratch/` (DECISIONS 2026-10-26: per-clip year guesses on named family footage never enter the repo); a `summarize`
command that writes aggregates only. The Swift side has a test target that decodes every family schema from fixture
JSON (valid, invalid, adversarial: extra keys, wrong types, a year of 19910, a range reversed) and proves fail-closed.
The harness can drive any registered approach through the same JSONL request shape the job uses, so a number in the
benchmark is the number the job will get.

**What a verdict looks like.** One table per approach in `docs/reviews/video_llm_benchmarks.md` (overwritten, not
multiplied, per CLAUDE.md), one DECISIONS line on promotion ("2026-11-xx — `qwen3-vl-32b-4bit/era-v1/window-60s@r3`
promoted for `era`; MAE 5.8 y VHS/DV, 4.1 y DV; 2.3 s/window Ultra"). The number is the argument; the doc is the record.

## 5. The approach ladder — what to try, in order, and what each proves

| # | Approach | Host | Change from the previous rung | Proves / disproves | Go / no-go |
|---|---|---|---|---|---|
| **A0** | Qwen2.5-VL-3B-4bit, stills, the three existing prompts | `.mlxSwift` (as is) | none — wrapped as an approach | the **baseline**: schema-valid rate of today's free text parsed into the families, OCR exact-match, s/frame | always runs; it is the control every later rung is compared to |
| **A1** | same model, `WindowSampler` 60 s @ 1 fps, strict JSON contract, era + scene + roomFeatures prompts | `.mlxSwift` | sampler and contract | does structure and chronology help a small model? is the 3B model even able to hold 60 frames? (if not, 10 frames per window — measure) | go to A2 regardless; A1 decides whether the M4 keeps a useful role |
| **A2** | Qwen3-VL-8B then 32B Instruct 4-bit, native video input with timestamps | `.pythonWorker` (`mlx-vlm`, pinned; keep a 5-clip regression set because mlx-vlm's video path broke once in Sep 2026) | model and host | **Phase E**: the era bar; OCR parity; occasionKind | promote `era` only on the bar; otherwise the prompt stays research |
| **A3** | Gemma 4 31B (or the strongest Apache/Gemma-licensed open VLM at the time) | `.pythonWorker` | model only, same contract | is a second model family better on VHS-era footage? | keep whichever wins per family; two approaches may be promoted for different families |
| **A4** | Embeddings: SigLIP 2 (Core ML / ANE) then Qwen3-VL-Embedding-2B; mean-pool one frame per 10 s per window; vectors in the sidecar | `.mlxSwift` or Core ML | not a generator: retrieval by example | roomFeatures and occasionKind as *retrieval* (find windows like this one), gated on the 18 events and Rick's 50 place labels | precision@k ≥ 0.8 or it stays in the lab; it may only ever *suggest* in the Related ladder, distance shown |
| **A5** | Example memory: `PromptContext` carries Rick's nearest confirmed examples (from A4's vectors) and known constraints (birth years of tagged people, folder year, confirmed carrier) | any | context only | the first "learning": does the model's era/occasion error fall with examples it did not see at training? | this is what "expert on the Breen media" means under DECISIONS 2026-08-16; then the pair classifier of the 10/16 review (logistic regression over frozen features and Events decisions) |
| **A6** | LoRA on the VLM with `mlx-vlm`'s adapter training, on **extraction** (reading OSDs, naming carrier clues) using A0–A5's schema-valid outputs that Rick confirmed | `.pythonWorker` | weights | only if A5's residual errors are extraction errors, not judgement errors | never trained on names, dates or relations; the adapter is one more `revision`, benchmarked like any other |

Not on the ladder, by ruling: any cloud VLM on pixels or audio; face identity across decades; a model that writes a
date on an archived row; DBSCAN or any clustering that *creates* an event without Rick.

## 6. Tests (rule 8: five dimensions + truth) and sensors

- **Logic:** schema decoding for every family (valid / invalid / adversarial); `EvidenceAssertion` mapping; sampler
  plans (window boundaries snap to cuts, never overlap, cover the file, last window may be short; zero-length and
  one-frame files); approach registry refuses a duplicate `(id, revision)`.
- **Scale:** a `SamplePlan` for 100k files × 450 h in the time budget; a sidecar with 1.6 M `outputs` rows pages in
  256-row keyset pages without blocking a writer (the audio store's rule 5); the harness summarizer over 200k JSONL lines.
- **Media matrix:** mp4/h264, mov/prores, mkv/ffv1+pcm, mxf, avi/dv all yield frames and audio through the two-tier
  extractor; the MKV fixture already exists.
- **Isolation (poisoned state):** a sidecar with a newer schema is refused in words; a worker that dies mid-window
  marks the window `failed`, not `schemaInvalid`, and the job continues; a corrupt `raw_json` row never crashes a
  summary; an approach whose model weights are missing refuses at START, not after decoding 400 files.
- **Sensor (the lane):** (1) **remote refusal** — a `.remoteTextOnly` approach handed a `.pixels` payload throws
  before any network call (a fake transport asserts zero bytes sent); (2) **no unpromoted write** — the promotion
  job with an id outside the compiled promoted set refuses and writes nothing (rows before == rows after);
  (3) **fail-closed schema** — a hand-made near-miss JSON yields zero assertions and one `schemaInvalid` row;
  (4) **MFO lifecycle** — START/OUTCOME lines present with the counts; a cancelled job has `finishedAt` set once.
- **Truth:** an era assertion shown anywhere carries its range, its approach id and "machine-generated, unconfirmed"
  wording; `FileFact` evidence names the window and the frames (the Catalog inspector line, the Provenance sheet).
- **Catalog writer (promotion only):** an edit inside the debounce window, during a write hold, across a role flip,
  then relaunch — the rule 8 writer quartet — plus Codex (data-risk: it writes the Provenance sheet's inputs).

## 7. Privacy and safety, carried by code

- Rule 13 is enforced in the runner, not in a review: every approach declares `accepts`; the job refuses to send a
  payload class the host is not local for. Sensor (1) above pins it.
- Model weights live in `~/.cache/huggingface` and `~/.ollama`, never in git (`steps/50_models.sh` lists them).
- Per-clip benchmark results, prompts that quote family names, and the corpus manifest stay in `.scratch/`. The repo
  holds aggregates and the schema fixtures (synthetic clips from `TestDriver`, never family footage).
- Nothing in this design touches media, renames, moves or re-encodes; frames are ripped to a temp directory the job
  removes. Hallie's "never touches files" extends to every approach.
- The archive volume's choke point is untouched: a model job opens archive files read-only through the same path
  Find Master uses (`SQLITE_OPEN_READONLY` for sidecars, read-only URLs for media).

## 8. Phases

| Phase | Builds | Schema | Gate | Who decides |
|---|---|---|---|---|
| **0 — the lab, no new model** (≈ 2 days) | Core types (`EvidenceSampler`, `VideoEvidenceApproach`, `EvidenceAssertion`, schemas); `ApproachRegistry`; sidecar `model-lab.sqlite`; `A0` wrapping `MLXVLMCaptionRunner`; the MFO job; `tools/video-llm-bench/` with `validate-corpus`, `run`, `summarize`; the era/OCR corpus manifests; **baseline numbers published** | none (sidecar only) | sensors green; the five dimensions; baseline table in `docs/reviews/video_llm_benchmarks.md` | Claude (module-internal); Rick sees the numbers |
| **1 — windows and contract** | `WindowSampler` with scene cuts; `AudioSegmentSampler` and the Whisper worker returning segments; `A1` | none | A1 vs A0 table | Claude |
| **2 — the Ultra model** | `.pythonWorker` host; pinned `mlx-vlm`; `A2` (8B, then 32B); `A3`; **Phase E era benchmark** | none | the era bar; cost table | Rick rules on promotion from the numbers |
| **3 — promotion** | the promotion job → `provenance_assertions` (v14) · `inferred_dates` era source · `DateCriterionClaim.Kind.era`; Provenance sheet and inspector wording | **v14** (Phase C of the provenance design; Rick approves) | writer quartet; Codex pass; truth tests | Rick (schema, wording); Codex |
| **4 — retrieval and learning** | `A4` vectors + Related-ladder suggestions; Rick's 50 place labels; `A5` example memory; the pair classifier export of Events decisions (the 10/16 review §5) | sidecar; later a `places` link if Rick wants it | precision@k gates; the classifier's held-out table | Rick (what is suggested where) |
| **5 — adapters** | `A6` LoRA on extraction, only if Phase 4's errors say so | none | same benchmark, one more revision | Rick |

Phase 0 is the unit of "design it" that can start now; it runs on the M4 and the 3B model while the Ultra bring-up
and the Phase A spot tests finish, and it touches no catalog table.

## 9. Rulings wanted from Rick (numbered; one at a time when we get there)

1. **Cloud on derived text** (captions, transcripts, never pixels or audio) for later labelling: allowed behind the
   payload gate, or local only? The slot ships disabled either way. (BACKLOG, open since 10/12.)
2. **The 50 place labels** for `roomFeatures`: an hour of your time in the Catalog, or defer `A4` until after Phase 3?
3. **Which model first on the Ultra**: Qwen3-VL-32B 4-bit (≈ 20 GB, native video) or Gemma 4 31B (65–75 GB at long
   context)? Default: Qwen first, Gemma as `A3`.
4. **Schema v14** timing: Phase 3 needs it; it is the same approval the provenance design already asks for.

## 10. Sources

Repo: `docs/design/provenance_retroactive_2026_10_26.md` · `docs/research/provenance_retroactive_fingerprinting_2026-10-25.md`
· `docs/research/family_event_learning_review_2026-10-16.md` · `docs/design/events_design.md` · `docs/design/cyberbrain_design.md`
· `Media/CaptionRunner.swift` · `scripts/whisper_worker.py` · `tools/qwen-bench/README.md` · `docs/DECISIONS.md`
(2026-08-14, 2026-08-16, 2026-09-23, 2026-10-10, 2026-10-26). Outside input (Rick, 2026-10-29): "SW_Video_LLMs_MediaExpert"
and "Modular Video Intelligence Architecture for Apple Silicon & Cloud"; their useful parts are in §1's last three rows.
