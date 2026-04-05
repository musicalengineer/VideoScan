# Face Recognition Diagnosis — April 4 2026

## What We Did

Built `FaceDiagnose.swift` — a diagnostic CLI that runs the exact same Vision pipeline
as the app, but dumps every face/distance/reference detail to the console.

Ran it against a fresh test video (`Donna_dicky-unit-test3.MOV`, 20s, 30fps) with
both Rick and Donna on camera, using the full reference photo set (30 photos).

---

## Key Findings

### 1. VNFeaturePrint is the wrong tool for this job

`VNFeaturePrint` is a **general-purpose image similarity embedding** — trained on scenes,
objects, textures. It was never trained for face *identity* matching.

Apple Photos uses a purpose-built **face recognition neural network** trained specifically
for identity matching across age, lighting, and expression variation. That's why Photos
recognizes Donna well across decades; our app can't reliably do the same with VNFeaturePrint.

### 2. Rick and Donna score nearly identically against the best reference photo

At timestamps where both Rick and Donna were visible (17s mark), both faces scored
**~0.42–0.49** against `IMG_3347.jpeg`. The model cannot separate them.
There is no threshold value that accepts Donna and rejects Rick.

### 3. Only one reference photo is doing real work

Out of 30 reference photos:
- `IMG_3347.jpeg` (Donna, older, full body, kitchen wall, slight profile) — drove **103 of 105 hits**
- Everything else was essentially noise

The "any single reference wins" matching logic means the whole system depends on this
one photo. If it's removed or slightly off, everything fails.

### 4. Donna2025.jpg is poorly calibrated

The most recent photo of Donna gives distances of **0.67–0.73** for her own face in
the test video. It should be giving 0.35–0.45. Something is wrong with it — likely
angle, lighting, or hair.

### 5. Several reference photos are actively harmful

| Photo | Problem |
|-------|---------|
| DSCN0221.jpeg | Yaw -60.7° (extreme profile) — distances >1.0 to everyone |
| donna-8x10.jpeg | Yaw -48.5° — same problem |
| Donna3.jpg | From 1997 — 29 years of age difference |
| DSCN2459.jpeg | Distances ~1.0 to all faces |

### 6. Legacy media compounds the problem

VHS/Hi-8/SD video has lower resolution, compression artifacts, interlacing, and color
degradation — all of which hurt feature print quality. VNFeaturePrint has no age
progression model, so younger Donna and older Donna appear as two different people.

---

## Distance Data from Test Video

```
Best dist ever:    0.3861  (true positive — Donna close-up, 0–3s)
Dist p5/p50/p95:   0.426 / 0.700 / 0.828

Hits at threshold 0.52:   105  (29.2% of all detected faces)
  — Confident (< 0.40):     2
  — Borderline (0.40–0.52): 103   <-- all borderline, same range as Rick's face

Faces detected total: 360
```

Distance histogram clusters:
- **0.40–0.55**: ~112 faces — Donna AND Rick both land here (can't separate)
- **0.65–0.85**: ~218 faces — clear non-matches (other people, or bad angles)

---

## What Would Actually Fix It

### Option A: Switch recognition engine to `face_recognition` (Python/dlib)

The `face_recognition` library uses dlib's deep residual network — the same *class* of
model as Apple Photos. Specifically trained for face identity matching across age and
lighting variation.

```bash
pip install face_recognition
```

- Reference photos → `face_recognition.load_image_file()` + `face_recognition.face_encodings()`
- Video frames → same encoding, then `face_recognition.compare_faces()` or `face_recognition.face_distance()`
- Default tolerance is 0.6; tighter (~0.5) for less false positives

This is 10–20 lines of Python for the recognition step. Keep Swift app for everything
else (video discovery, frame extraction, clip cutting, UI).

**Pros:** Correct model for the job, handles age variation, ~99.38% accuracy on LFW benchmark
**Cons:** Python, slightly slower than ANE-accelerated Vision, another dependency

### Option B: Core ML with ArcFace or FaceNet model

Use a face recognition model (ArcFace, FaceNet) converted to Core ML format.
Keeps everything in Swift/native, uses Apple Silicon acceleration.

More work to set up but same class of model as Option A.

### Option C: Keep VNFeaturePrint + voting + better references

If staying with the current approach:
1. Require **K-of-N references to agree** (e.g., 3 out of 30) instead of any-single-match
2. Remove extreme-angle reference photos (yaw > 40°)
3. Add 5–10 good frontal photos of Donna per decade
4. Age-segregate references: use 1980s photos for 1980s videos, 1990s for 1990s, etc.

This won't fully solve the Rick/Donna separation problem but reduces false positives significantly.

---

## Recommendation

Use `face_recognition` for the recognition step. It's the right tool.
The Python prototype would be fast to build and test against the same unit test video.
If it works, the Swift app calls out to a Python subprocess (same pattern as ffmpeg/ffprobe).

---

## On Training a Custom Model — Is It Reasonable?

### Your Original Instinct Was Sound

Feeding all your media into a trainable model is a legitimate and well-trodden approach.
The reason the app went a different direction is that cataloging/scanning is useful
regardless of recognition accuracy — but for the *recognition* step specifically,
your instinct was right.

### What "Training a Model" Actually Means Here

There are three levels, from simplest to most involved:

**Level 1: No training needed — just use a better pre-trained model (face_recognition/dlib)**
- dlib's ResNet descriptor is already trained on ~3 million faces
- You give it reference photos of Donna at query time — no training step
- This is what `face_diagnose.py` does
- Effectively what Apple Photos uses under the hood
- **This is the right first move. Build and test it before going further.**

**Level 2: Fine-tune embeddings with your own photos (metric learning)**
- Take a pre-trained face model, add a small training pass on Donna's photos
- Makes the model's embedding space specifically better at discriminating Donna
  from people who look similar (e.g., family members, or Rick)
- Tools: PyTorch + ArcFace loss, or Apple's Create ML
- Requires: ~50–200 labeled face crops of Donna (positive), ~500+ other faces (negative)
- **Worth doing if Level 1 still produces false positives on family members**

**Level 3: Train a personal binary classifier**
- Crop every face from every reference photo → label as Donna / not-Donna
- Train a small classifier on top of frozen embeddings
- Output: probability that a given face is Donna
- Threshold on probability instead of distance
- **More interpretable than raw distance, easier to tune per-video**

### The "Feed All Media Into a Model" Approach

What you were originally thinking sounds like building a **personal face index**:
1. Scan all photos/videos → extract all face crops
2. Cluster similar faces (unsupervised) → you identify which cluster is Donna
3. Use that cluster's centroid + variance to match faces in unscanned videos

This is essentially what Apple Photos does. The challenge:
- Clustering quality depends on the face model — needs Level 1 or 2 quality model
- The clustering step requires human review to label clusters ("which one is Donna?")
- But once done, the index is very fast to query

**Practical path:** Level 1 first (face_recognition prototype running now). If the
accuracy is good enough, done. If family member false positives remain, Level 2
(fine-tuning). The personal face index is a longer-term project that pays off once
the recognition quality is proven.

### Apple Create ML Option (Stays Native Swift)

Apple's Create ML has an Image Classifier task. You could:
1. Extract face crops from all Donna photos → label "Donna"
2. Extract face crops from all other photos → label "other"
3. Train a Core ML model in Create ML (GUI, no code needed)
4. Drop the `.mlmodel` file into the Xcode project
5. Replace `VNGenerateImageFeaturePrintRequest` with your trained model

This keeps everything native, uses Apple Silicon Neural Engine, and produces a model
specifically calibrated to your family's faces. The downside: needs enough labeled
negative examples to generalize well, and Create ML's face handling is less refined
than dlib's purpose-built pipeline.

### Bottom Line

| Approach | Effort | Accuracy | Stays in Swift |
|----------|--------|----------|----------------|
| VNFeaturePrint (current) | Done | Poor for identity | Yes |
| face_recognition/dlib | ~1 day | Good | No (Python) |
| Create ML fine-tune | ~2 days | Good | Yes |
| Full personal face index | ~1 week | Excellent | Either |

Start with the dlib prototype (running now). It will tell us immediately if the
model quality gap is as large as expected. If it separates Rick and Donna cleanly
at the same threshold, that's the answer.

---

## Files

| File | Purpose |
|------|---------|
| `FaceDiagnose.swift` | Diagnostic CLI — run against any video+refs to see raw distances |
| `unit_tests/videos/` | Test videos |
| `unit_tests/photos/` | Reference photos |
| `unit_tests/diagnose_new.txt` | Full verbose output from today's run |
