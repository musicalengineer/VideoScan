# Immich → VideoScan: Face Identification Ideas

**Date:** 2026-06-20
**Source:** Immich (`immich-app/immich`), cloned locally at `~/dev/immich` (shallow, HEAD `b24a617`)
**Purpose:** Mine Immich's open-source people-identification pipeline for ideas applicable to VideoScan's "who is in this video" goal. Findings are from reading the actual source, not docs.

> **Correction worth flagging up front:** an earlier verbal summary claimed Immich clusters faces with **DBSCAN**. That is **wrong**. Immich uses **online greedy nearest-neighbor matching**, no batch clustering algorithm. The greedy approach is arguably a *better* fit for VideoScan's continuous-ingest model than DBSCAN would be — see below.

---

## 1. How Immich actually identifies people

Two-model InsightFace pipeline run through **ONNX Runtime**, plus an online assignment step in the server.

### Detection + embedding (Python ML microservice)

The ML service is a separate FastAPI process from the main server. Models come from the InsightFace `buffalo_l` pack (also `buffalo_m`, `buffalo_s`, `antelopev2`), downloaded from HuggingFace under `immich-app/{model_name}`.

- **Detection:** RetinaFace at **640×640** → bounding boxes, confidence scores, **5 facial landmarks**.
  `machine-learning/immich_ml/models/facial_recognition/detection.py`
- **Alignment:** `norm_crop()` (from `insightface.utils.face_align`) uses the 5 landmarks to produce a canonical **112×112** crop.
  `machine-learning/immich_ml/models/facial_recognition/recognition.py:77`
- **Recognition:** ArcFace on the 112×112 crop → **512-d embedding, L2-normalized**.
  `machine-learning/immich_ml/models/facial_recognition/recognition.py`

Detection and recognition are **separate, swappable ONNX models**. The quality gate (`minScore`) lives entirely on the detection side; the recognition model only ever sees crops that already passed.

### Storage + search (Postgres)

- Embeddings stored as `vector(512)` via **pgvector** *or* **VectorChord** (auto-detected at runtime).
  `server/src/schema/tables/face-search.table.ts`
- **HNSW index**, **cosine distance** (`<=>` operator), parameters `ef_construction = 300, m = 16`.
- kNN search is a single SQL query ordered by cosine distance, filtered to `distance <= maxDistance`.
  `server/src/repositories/search.repository.ts:315-349`

### Assignment — online greedy, NOT batch clustering

The core logic is `server/src/services/person.service.ts:459-541` (`handleRecognizeFaces`). For each newly embedded face:

1. **kNN search** for existing faces within `maxDistance` (cosine ≤ 0.5 default).
2. **"Core" test:** if the face has **≥ `minFaces` (default 3)** neighbors *and* its asset is in the main timeline, it's confident enough to anchor identity. Otherwise the face is **deferred** — re-queued for a later pass. This solves the cold-start / chicken-and-egg problem without a separate clustering job.
3. **Assign:** take the `personId` of a matched neighbor. If there are matches but none are named yet, run a *second* search restricted to faces that already have a person.
4. **Create:** a core face that matches no existing person → **create a new person**.
5. **No centroids.** A "person" is just a bag of face rows. All matching is **face-to-face kNN**, never face-to-centroid.

There is also an IoU (>0.5) de-dup against existing face rows in the same asset during detection, so re-running detection on an asset updates rather than duplicates faces (`person.service.ts:327-361`).

### Job/queue flow

```
AssetDetectFacesQueueAll → AssetDetectFaces (per asset)
    detect faces → store 512-d embeddings → queue FacialRecognition jobs

FacialRecognitionQueueAll → FacialRecognition (per face)
    kNN search → core? → assign to person / create person → PersonGenerateThumbnail
```

A nightly pass skips work entirely if no new faces exist since the last run (`person.service.ts:410-420`).

### Apple Silicon acceleration

Two relevant paths (directly answers VideoScan's open ANE-utilization question):

- **ONNX Runtime `CoreMLExecutionProvider`** — all compute units enabled, compiled model cached under `{model}/coreml/`. `machine-learning/immich_ml/sessions/ort.py:157-164`.
- **Hand-rolled ANN backend** in `machine-learning/ann/` — compiles models to a `.mlmodelc` for the Neural Engine directly. Tuning levels 0–3 via `MACHINE_LEARNING_ANN_TUNING_LEVEL`.

Provider preference order: CUDA → MIGraphX (ROCm) → OpenVINO → **CoreML** → CPU.
`machine-learning/immich_ml/models/constants.py:91-97`

### One decades-relevant detail: birthdate prior

Face search accepts a `minBirthDate` filter — it won't match a face to a person whose recorded birth date is *after* the asset's creation date (`search.repository.ts`, `minBirthDate` clause). A cheap, effective identity prior. This is essentially VideoScan's own dossier birthdate-prior idea, already shipping in Immich.

### Tunable parameters (server defaults)

`server/src/config.ts:305-311`

| Parameter | Default | Range | Meaning |
|---|---|---|---|
| `modelName` | `buffalo_l` | — | InsightFace model pack |
| `minScore` | **0.7** | 0.1–1.0 | Min detection confidence |
| `maxDistance` | **0.5** | 0.1–2.0 | Max cosine distance to count as a match |
| `minFaces` | **3** | ≥1 | Min neighbors for a face to be "core" |
| `enabled` | `true` | — | Master switch |

`minFaces` is overridable per-user via `user_metadata.preferences.people.minimumFaces`.

---

## 2. What's worth stealing for VideoScan

| Idea | Why it fits VS |
|---|---|
| **Online greedy assignment, not batch DBSCAN** | VS ingests video continuously. No need to re-cluster the whole archive each scan — embed each face hit, kNN against what exists, assign or defer. Incremental by nature, simpler than DBSCAN. |
| **"Core / deferred" two-pass** | Solves cold-start without a separate clustering job. Blurry / low-quality video frames naturally stay deferred until enough good frames of that person accumulate — ideal for noisy video. |
| **ArcFace 512-d + cosine, as a pluggable embedding backend** | Slots into the existing `processOne()` dispatch (`project_pluggable_face_detect`). Use Vision for detection + landmarks, ArcFace for the embedding that actually generalizes across decades. Detection and recognition stay decoupled, exactly as Immich keeps them. |
| **Local vector index instead of pairwise distance loops** | At archive scale, replace the O(n) feature-print loop with **sqlite-vec or Faiss locally** (no Postgres needed). HNSW + cosine, same as Immich. |
| **`minBirthDate` prior** | Family birthdates already exist in the dossier vision. Free precision gain; trivial to add as a filter on candidate matches. |
| **CoreML execution provider** | Clean route to the M4 Max ANE for ArcFace with no model rewrite. The `ann/` backend is the more aggressive option if CoreML EP underutilizes the NE. |
| **Unsupervised "who's here" without reference photos** | Today VS matches frames against pre-made Donna reference photos. Immich's model — embed everything, group by similarity, name a group once — surfaces people you never made references for, and is robust where a single reference photo won't match a 30-years-younger face. This is the `project_family_id_plan_5step` cluster→POI→classifier loop, with a working reference implementation. |

---

## 3. What NOT to copy

Immich is **photo-first**. For video it extracts a single keyframe/thumbnail and treats it as a photo. **VideoScan's frame-by-frame sampling + temporal grouping of consecutive hits into segments is strictly better** for the "who's in this video" question. Borrow the **embed → match → assign** architecture; keep VideoScan's own video front-end and segment logic.

---

## 4. Concrete adaptation sketch

The cleanest first step, in priority order:

1. **Add an ArcFace embedding backend** (CoreML EP) alongside Vision in the `processOne()` dispatch. Vision detects + supplies landmarks; ArcFace consumes a `norm_crop`-style 112×112 aligned crop → 512-d normalized embedding.
2. **Persist 512-d embeddings in a local vector store** (sqlite-vec or Faiss), HNSW + cosine.
3. **Online greedy assignment** with the core/deferred two-pass: kNN within `maxDistance`; ≥ `minFaces` good neighbors → core; assign to matched person or mint a new one; defer the rest.
4. **Add the birthdate prior** as a candidate filter once per-person birthdates are wired in.
5. **Surface unnamed groups in the UI** for one-click naming — the POI labeling step.

Starting points in the cloned repo:
- Embedding: `~/dev/immich/machine-learning/immich_ml/models/facial_recognition/recognition.py`
- Greedy assignment: `~/dev/immich/server/src/services/person.service.ts:459`
- Vector search SQL: `~/dev/immich/server/src/repositories/search.repository.ts:315`
- CoreML / ANE: `~/dev/immich/machine-learning/immich_ml/sessions/ort.py:157` and `~/dev/immich/machine-learning/ann/`

---

## Related VideoScan notes
- `project_pluggable_face_detect` — Vision / ArcFace / dlib / Hybrid dispatch in `processOne()`
- `project_family_id_plan_5step` — cluster → POI → classifier loop
- `project_metadata_dossier_vision` — birthdate priors → triangulated identity
- `project_ane_utilization` — whether Vision/ML saturates the M4 Max ANE
- `project_arcface_concurrency_bug` — latent shared-MLModel crash under concurrent inference (relevant once ArcFace is a backend)

## New Comments from Jun 29 2026 from Codex on things we can use from immich in VideoScan:

 Yes. Immich’s most valuable contribution is not its web/Docker stack; it is its persistent face data model and incremental identity assignment.

  VideoScan already has much of the ML technology:

  - ArcFace 512-dimensional embeddings and cosine matching.
  - The same InsightFace buffalo_l recognition model family Immich uses.
  - Optional five-landmark alignment.
  - Face clustering and cluster-to-POI promotion.
  - Birth/death dates and catalog person tags.

  The critical difference is persistence. VideoScan currently caches the final answer—“Donna appears in these segments”—in VideoScan/VideoScan/
  VideoScan/PersonFinderCache.swift:7. Immich stores every useful face observation and its embedding, then improves identity assignments over time.

  The best ideas to adopt are:

  1. A native SQLite face-observation store

  Store something like:

  face_observation
    videoRecordID
    timestamp
    boundingBox
    detectionConfidence
    qualityScore
    arcfaceEmbedding
    embeddingModelVersion
    personID nullable
    assignmentStatus
    source/provenance

  Then face detection and embedding happen once. Searching for another person, changing a threshold, merging identities, or rebuilding catalog tags
  no longer requires decoding the videos again.

  The existing detectedPeople and suspectedPeople arrays should become derived summaries, not the primary recognition data.

  2. Immich’s core/deferred assignment algorithm

  Immich searches nearby embeddings, creates a person only when a face has enough similar neighbors, and defers isolated or uncertain faces for
  another pass. The implementation is compact in immich/server/src/services/person.service.ts:459.

  That fits family videos well:

  - Repeated good appearances establish an identity.
  - Blurry/profile/background faces do not create junk people.
  - Naming one cluster improves later assignments.
  - Previously unknown people can be discovered without reference photos.

  3. Adapt it to video using face tracks

  Do not persist every sampled frame. VideoScan’s default sampling can produce several observations per second; copying Immich literally would create
  huge numbers of near-identical embeddings.

  Associate faces across adjacent samples using bounding-box overlap plus ArcFace similarity, forming short face tracks. Persist perhaps the best 1–3
  representative faces per track. This is the important video-specific layer Immich does not provide—it processes an asset preview rather than
  exploiting the temporal sequence.

  4. A local vector-search layer

  Immich stores 512-dimensional vectors in an HNSW cosine index: immich/server/src/schema/tables/face-search.table.ts:4.

  VideoScan does not need Postgres. Start with SQLite containing packed float vectors and exact Accelerate/vDSP cosine search. Add sqlite-vec or an
  HNSW implementation only after measurements show it is needed. The expensive operation today is repeatedly decoding and embedding video, not
  comparing a few vectors.

  5. Rich identity correction workflows

  Immich treats recognition as editable data:

  - Name an unnamed group.
  - Merge duplicate people.
  - Move an incorrectly assigned face.
  - Select a representative face.
  - Hide unimportant/background people.
  - Re-run only unassigned faces.

  VideoScan already promotes clusters into POIs in VideoScan/VideoScan/VideoScan/IdentifyFamilyModel.swift:498, but persisting face-to-person
  assignments would make corrections durable rather than merely adding more reference images.

  6. Finish activating existing VideoScan work

  Landmark-aligned ArcFace crops exist but remain optional in VideoScan/VideoScan/VideoScan/ArcFaceEngine.swift:319. After accuracy testing,
  alignment should probably become the default because it matches ArcFace’s training geometry.

  Birthdate filtering should also move into candidate matching, as Immich does at immich/server/src/services/person.service.ts:487, rather than being
  only a post-hoc suggestion mechanism.

  Recommended implementation order:

  1. Add the SQLite face/track schema and model-version invalidation.
  2. Modify the ArcFace scan to persist track representatives.
  3. Query known POIs against stored embeddings and rebuild catalog tags.
  4. Add core/deferred grouping for unnamed people.
  5. Add merge, split/reassign, hide, and representative-face UI.
  6. Benchmark before adding HNSW.

  One important constraint: copy the architecture, not Immich source blindly. Immich is AGPL, and its own ML README says its permission for
  InsightFace models does not extend to third-party redistribution or commercial use: immich/machine-learning/README.md:38. VideoScan already
  contains w600k_r50, so that model’s distribution terms should be resolved before distributing the app.

  No Docker, server, browser UI, or Python service is required for this design. It can remain a native Swift/CoreML application with a local SQLite
  database.
