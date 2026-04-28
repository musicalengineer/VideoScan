# Family Media Training Model

**Status:** Brainstorm. Captures the architecture, training stack, vector-search stack, data pipeline, and a phased plan for building a face recognition model trained on Rick's family video — for when off-the-shelf face detection (Vision, ArcFace pretrained, dlib) isn't accurate enough on the long tail.

**Goal:** A face recognition model that knows our family. It should reliably identify Donna at age 25 vs age 60, Tim vs Timmy, the kids across decades of changing haircuts, lighting, and tape generations. The pretrained models we ship today are good general-purpose recognizers; this is about closing the gap on the cases they consistently miss.

**Scope of this doc:** Long arc, not next sprint. Captured so design decisions we make now (tagging, embedding storage, engine plug-in points) don't make this future work harder.

---

## What kind of model is this, exactly

Plain-English summary so we don't talk past each other later:

- **Not an LLM.** No text in, no text out. These are **computer vision models**.
- **Category:** face recognition / face embedding models.
- **Backbone architectures:** CNNs (ResNet-style — what ArcFace and most production systems use) or Vision Transformers (ViT — newer, less battle-tested in this domain).
- **What the model actually outputs:** a fixed-length vector (512-D for ArcFace) per face — an "embedding" that encodes the identity. Same person → similar vectors; different person → distant vectors.
- **Training paradigm:** **metric learning** (learn a distance space) + **transfer learning** (start from pretrained weights, fine-tune on family data). We are NOT training from scratch — that needs millions of identities and weeks of GPU time. We're adapting an existing model to our specific people.

Three knobs we can turn, in increasing cost and risk:

1. **Frozen backbone + classifier head.** Use ArcFace as-is to produce embeddings, train a small MLP on top to classify "Donna / Tim / Timmy / unknown." Days to set up, hours to retrain, no risk of damaging the backbone.
2. **Partial fine-tune.** Unfreeze the last 1–2 layers of ArcFace, retrain on family pairs. Better at capturing family-specific features (the "kids look like each other" problem) but needs more data and care.
3. **Full fine-tune.** Unfreeze the whole backbone. Highest ceiling, easiest to overfit and break. Last resort.

Phase 1 of any plan is option 1. We may never need 2 or 3.

---

## Three-layer architecture

```
┌──────────────────────────────────────────────────────────┐
│  Layer 3 — Query Engine                                  │
│  "Find Donna in this video" / "Who is this face?"        │
│  → embed query face, ANN search in vector index, return  │
│    matched record IDs + confidence                       │
└──────────────────────────────────────────────────────────┘
                          │
┌──────────────────────────────────────────────────────────┐
│  Layer 2 — Vector Index                                  │
│  ~21M embeddings @ 512-D float32 ≈ 30 GB                 │
│  sqlite-vec for v1 (unifies with metadata_cache.sqlite)  │
│  FAISS sidecar if/when sqlite-vec gets slow              │
└──────────────────────────────────────────────────────────┘
                          │
┌──────────────────────────────────────────────────────────┐
│  Layer 1 — Embedding Model                               │
│  Pretrained ArcFace (frozen) + family classifier head    │
│  Trained on labeled family frames                        │
│  Apple Silicon: PyTorch MPS → coremltools → CoreML       │
└──────────────────────────────────────────────────────────┘
```

Each layer is independently replaceable. The embedding model can change without rebuilding the catalog if we re-embed once and swap the index. The vector index can change without retraining the model.

---

## Layer 1 — the embedding model

**Starting point: ArcFace pretrained on MS1M / Glint360K.** Already integrated as a CoreML engine in VideoScan. It produces 512-D embeddings via cosine similarity. Pretrained weights know "faces" in general — they don't yet know *our* faces specifically.

### Training stack pick: PyTorch MPS

| Stack | Training | Inference | Verdict for this project |
|---|---|---|---|
| **PyTorch MPS** | Yes, on M-series GPU | Yes | **Pick for training.** Mature, vast face-recognition ecosystem (InsightFace, facenet-pytorch), MPS backend works on M4 Max. |
| **coremltools → CoreML** | No (inference only) | Yes, ANE-accelerated | **Pick for shipping.** Convert PyTorch → CoreML for the macOS app's runtime. ArcFace already runs this way today. |
| **ONNX Runtime CoreML EP** | No | Yes | Useful if we want one model file that runs on Mac, iOS, Linux servers. Inference only. |
| **MLX** | Yes, Apple-native | Yes | Tempting but the face-recognition recipe ecosystem is thin. Revisit in 12 months. |
| **TensorFlow / Keras** | Yes | Possible | Skip. PyTorch has won the face-recognition research community. |

**Workflow:** train in PyTorch on the Mac Studio's MPS backend → export to ONNX → convert to CoreML via `coremltools` → drop the `.mlpackage` into the app, swap the engine. Same path ArcFace already follows; no new infrastructure.

### Loss function

Standard ArcFace loss (additive angular margin) for fine-tuning. If we go with the frozen-backbone + classifier head route, plain cross-entropy on the head is fine.

### Compute budget on M4 Max

Frozen-backbone classifier training over ~10k labeled family faces: **minutes**, not hours. Partial fine-tune: hours. Full fine-tune of ArcFace on M4 Max MPS: probably overnight, possibly multiple days depending on data size. None of this requires a cloud GPU.

---

## Layer 2 — the vector index

### Scale math

- Estimated raw video: **~10 TB** across all volumes.
- Average bitrate ~5 Mbps → ~16k seconds per GB → ~50M video seconds total.
- Sample 1 frame/sec, ~1 face/frame on average → **~50M face embeddings worst case**.
- Realistic with deduplication and "no faces in this frame" filtering: **~10–20M embeddings**.
- 512-D float32 = 2 KB per embedding → **~20–40 GB index**.

This is "moderately large but not exotic." Every option below handles it.

### Vector store comparison

| Store | Fit | Notes |
|---|---|---|
| **sqlite-vec** | **v1 pick.** | Extension to SQLite. We already have `metadata_cache.sqlite`. One file, no daemon, queries compose with our existing SQL (joins to records, volumes, tags). Fast enough for tens of millions of vectors with cosine similarity. |
| **FAISS** | **v2 pick if sqlite-vec gets slow.** | Facebook's library. Fastest ANN search, supports billions of vectors. Pure library, no server. Sidecar — keep sqlite for metadata, FAISS for vectors. |
| **Qdrant** | **Skip.** | Server-based (HTTP/gRPC). Powerful but the deployment model is wrong for a self-contained Mac app. |
| **Chroma** | **Skip.** | Easier than Qdrant but slower at TB scale and worse search quality than FAISS. |
| **pgvector / Postgres** | **Skip.** | Adds Postgres as a dependency. We don't want that. |
| **Annoy / HNSWlib raw** | **Skip.** | We'd reinvent FAISS poorly. |

**Decision sequence:** ship on sqlite-vec. Measure query latency on real data. If a "find Donna in 10 TB" query takes >2s, port the vector column to a FAISS sidecar and keep the rest in SQLite.

### What gets indexed

One row per face detection, not per frame:

```
embedding_id (PK)
record_id        -> VideoRecord
frame_time_ms    -> position in the video
face_bbox        -> rect within the frame
embedding        -> 512-D float32 vector
detector_score   -> face detection confidence (Vision / MTCNN)
embedded_with    -> which engine produced it (model versioning)
```

`embedded_with` is critical — when we retrain or swap models, we need to know which embeddings are stale.

---

## Layer 3 — the query engine

Two query shapes, both cheap once the index exists:

1. **"Find Donna" (1:N).** Embed the user's chosen reference face. ANN search returns the K nearest face embeddings. Group by record_id, threshold by similarity, count consecutive hits, output ranges.
2. **"Who is this?" (1:1 lookup).** Embed an unknown face. ANN search. If the top result's similarity exceeds threshold AND that face has a confirmed person tag, propagate the tag. This is what the tagging system in `tagging_people.md` will use under the hood once embeddings exist.

Both of these become **near-instant** once the index is built. The slow part — face detection and embedding extraction — happens once at scan time. Search is the cheap part.

---

## Data — the actual hard part

The model is the easy bit. **Labels are the bottleneck.**

### Label sources, in order of yield

1. **Apple Photos people clustering** (~bootstrap). Apple has already clustered faces across the photo library. Names attached to clusters are high-precision labels we can import for free. Probably gives us a few thousand labeled Donna / Tim / Timmy / kid faces with no manual work. See the Apple Photos source in `tagging_people.md`.
2. **Reference photos** already loaded into POI profiles. ~5–20 high-quality faces per person. Tiny but pristine.
3. **Manual tagging via the tag review queue** (the data flywheel). User confirms or rejects auto-tags. Each click is a labeled example. Over weeks of casual use, this generates the majority of training data — *if* the tagging UI is fast enough that the user doesn't dread it.
4. **Known-clean clips** the user explicitly marks as "this whole clip is just Donna." Cheap bulk labeling — every face in the clip is a positive example.

Realistic targets:

- **Bootstrap (Apple Photos + reference photos):** 2k–5k labels per person. Enough for the frozen-backbone classifier.
- **After 3 months of tagging use:** 10k–50k labels. Enough for partial fine-tuning.
- **After a year:** 100k+ labels. Enough for full fine-tuning if we still need it (probably we won't).

### Labeling effort estimate

Even with the Apple Photos bootstrap, expect 20–40 hours of manual review across all family members to get a clean training set. The tag review queue UI in `tagging_people.md` is what makes that 20–40 hours bearable. **Bad tagging UI = no training data = no custom model.**

This is why tagging needs to land before training.

### Active learning loop

```
1. Train model v1 on bootstrap labels.
2. Run model on unlabeled videos.
3. Surface low-confidence predictions to the user.
   ("I think this is Donna at 0.61 — yes or no?")
4. User confirms → new labels.
5. Retrain. Loop.
```

This is roughly an order of magnitude more efficient than randomly labeling. Each label the user provides is one the model is most confused about, so the marginal improvement per click is highest.

---

## Why this is worth doing

The pretrained ArcFace model fails our family in three predictable ways:

1. **Decade gap.** Donna at 25 (1990s VHS) and Donna at 60 (2024 4K) are both Donna, but their embeddings are far apart in pretrained space. Family-specific fine-tuning can pull them closer because we have direct evidence linking them.
2. **Family resemblance.** Tim and Timmy and their brothers look alike — pretrained models trained on celebrities have never seen "people who are related" as a special challenge. Fine-tuning on our family forces the model to learn the discriminating features.
3. **Tape-era artifacts.** VHS chroma noise, camcorder white balance, deinterlacing. Pretrained models were trained on Instagram-quality faces. Fine-tuning on our actual footage teaches the model to ignore artifacts that aren't identity signal.

A model that's 85% accurate on home video is enough to make the tagging system useful at scale. The pretrained engines are closer to 60–70% on the hard cases, which is where the manual review hours pile up.

---

## Phased plan

| Phase | Deliverable | Approximate effort |
|---|---|---|
| **0** | Embedding storage layer (sqlite-vec column on `metadata_cache.sqlite`); embed every detected face during scans alongside existing recognition | ~1–2 days |
| **1** | Bootstrap labels: Apple Photos people import + reference photos → labeled embedding set | ~1 day (depends on tagging system being live) |
| **2** | Frozen-backbone classifier head trained in PyTorch on bootstrap labels; CoreML export; new "FamilyClassifier" engine option | ~2–3 days |
| **3** | Active learning loop: tag review queue feeds new labels → weekly retrain | ~1 day on top of tagging system |
| **4** | Vector search query engine: "find Donna" reads from sqlite-vec instead of running face detection | ~2 days |
| **5** *(if needed)* | Partial fine-tune of last ArcFace layers on accumulated labels | ~1 week |
| **6** *(probably not)* | Full fine-tune | weeks |

Phases 0–2 are what unlock the rest. Phase 4 is the payoff — search becomes "instant" instead of "let it run overnight."

**Critical dependency:** Phase 1 needs the tagging system from `tagging_people.md` to be live (at minimum the manual + Apple Photos sources). Without tags, there's no labeled training data.

---

## Open questions

1. **When do we know pretrained isn't good enough?** Calibrate against ground truth from `find_person.py` runs. If pretrained ArcFace + manual review gets >90% precision/recall on hard cases, custom training is unnecessary. Decision point: revisit after Phases 0–2 of tagging deliver real metrics.
2. **Per-person classifiers vs one multi-class model?** A separate binary classifier per person ("is this Donna? yes/no") is simpler, parallelizable, easier to retrain incrementally. A single multi-class head ("is this Donna / Tim / Timmy / unknown") is more compact but requires retraining the whole head when adding a new POI. Lean toward per-person — matches the POI mental model and the existing per-person scan job architecture.
3. **Embedding versioning.** When we retrain, old embeddings become stale relative to the new model. Strategy: tag every embedding with `embedded_with: model_version`. Re-embed on demand when the gallery is searched, or batch re-embed in the background. Either way, don't blow away existing embeddings when training a new model — they're still useful for the old model.
4. **Negative examples.** Easy to get positives ("here's Donna"). Negatives are trickier — random other faces? Deliberately hard cases (other family members)? The InsightFace literature has good answers; need a careful read before training.
5. **Privacy of training data.** This stays entirely local — no model leaves the Mac, no embeddings upload, no cloud GPU. The only cross-machine flow is the bundle export, which already round-trips POI photos. Embeddings could ride along in the bundle too if we want the iPad to do recognition without re-embedding (probably not worth it given the iPad scope is browse + edit).
6. **Model file size.** Fine-tuned ArcFace `.mlpackage` is ~250 MB. Acceptable but not trivial — won't ship inside the app bundle, will live in `~/Library/Application Support/VideoScan/Models/` and download on first use, or be exported with the bundle.
7. **MLX revisit cadence.** MLX is Apple-native and improving fast. Worth a re-evaluation in mid-2027 when face-recognition recipes mature. Not now.

---

## What this enables, beyond accuracy

A custom-trained recognizer is also the foundation for things off-the-shelf models can't do:

- **Family-tree-aware recognition.** "This is probably one of the boys" — a sibling-aware confidence model that can fall back to "one of {Tim, Timmy, the others}" when individual identification is uncertain. Useful in low-quality footage where the model can't tell brothers apart but can tell they're siblings.
- **Age-aware retrieval.** "Show me Donna in her 30s." The model already learns age implicitly during fine-tuning; we can surface it explicitly with date-of-record metadata as auxiliary supervision.
- **Pet recognition.** Same architecture, different training data. If the family had a beloved dog across decades, the same pipeline finds the dog.
- **Era / location embeddings.** Speculative but: train a separate model that embeds "what kind of footage is this" (1990s home video vs 2010s phone vs 2020s 4K). Useful for the reel-building workflow ("compile a 1990s Christmas reel").

These are bonuses. The core win is the recognition accuracy that makes the family legacy workflow actually work.
