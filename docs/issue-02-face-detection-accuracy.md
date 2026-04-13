# Issue #2: Face Detection Accuracy Needs Improvement

## Problem

Face detection/recognition accuracy is insufficient for reliable person finding across a large family video collection. False positives (wrong person matched) and false negatives (missed appearances) both occur too frequently.

## Current Implementation

### Vision Engine (PersonFinderModel.swift)
- Uses `VNDetectFaceRectanglesRequest` for detection
- Uses `VNGenerateFaceFeaturePrintRequest` for recognition embeddings
- Compares embeddings via `VNFeaturePrintObservation.distance` (L2-like metric)
- Threshold: 0.52 (lower = stricter match)
- Min face confidence: 0.55
- Frame step: 5 (processes every 5th frame)

### dlib Engine (face_recognize.py)
- Uses dlib's HOG/CNN face detector
- Uses `dlib_face_recognition_resnet_model_v1` for 128-dim embeddings
- Euclidean distance comparison
- Same threshold/confidence parameters passed from Swift

## Known Accuracy Issues

1. **Borderline distances (0.40–0.52 range):** Vision produces hits in this range that can't reliably distinguish between similar-looking family members. Two people of similar age/complexion can produce distances very close to each other.

2. **Age progression:** Reference photos from 2020s don't match well against 1990s video. The person's appearance changes significantly over decades.

3. **Video quality degradation:** VHS-quality, interlaced, and analog-captured video produces noisy face embeddings. Low resolution means fewer facial features are captured.

4. **Lighting and angle:** Indoor home video from the 80s-90s has poor, uneven lighting. Side profiles and partial faces are common in candid footage.

5. **Frame step too aggressive:** At frame_step=5 and 30fps, only every ~167ms is checked. Quick appearances (walking past camera, turning head briefly) can be missed.

## Improvement Approaches

### Quick Wins (days)

#### 1. Adaptive thresholding per-reference-photo
Instead of a single global threshold (0.52), compute per-reference statistics:
```swift
// During reference loading, compute distances between all reference pairs
let pairDistances = references.combinations(ofCount: 2).map { pair in
    pair[0].distance(to: pair[1])
}
let meanIntraDistance = pairDistances.mean()
let adaptiveThreshold = meanIntraDistance * 1.2  // 20% above intra-class mean
```
If reference photos are tight (low variance), use a stricter threshold. If they're spread (different ages/lighting), use a looser one.

#### 2. Multi-scale face detection
Run face detection at multiple resolutions to catch small/distant faces:
```swift
let scales: [CGFloat] = [1.0, 1.5, 2.0]
for scale in scales {
    let scaled = frame.resize(by: scale)
    let faces = detectFaces(in: scaled)
    // Adjust face rects back to original coordinates
}
```

#### 3. Temporal smoothing
If a face is matched at frame N, lower the threshold for frames N±2. People don't teleport — if they're in one frame, they're likely in adjacent frames.
```swift
if previousFrameHadMatch && distance < threshold * 1.15 {
    // Accept slightly weaker matches near confirmed matches
    acceptHit()
}
```

#### 4. Better preprocessing
Before embedding extraction:
- Histogram equalization for lighting normalization
- Face alignment using eye landmarks (Vision provides these)
- Crop to consistent face aspect ratio

### Medium Effort (weeks)

#### 5. Ensemble scoring
Run both Vision and dlib on the same frame, combine scores:
```swift
let visionDist = visionEmbedding.distance(to: reference)
let dlibDist = dlibEmbedding.distance(to: reference)
let combined = 0.6 * normalize(visionDist) + 0.4 * normalize(dlibDist)
```
Two independent models disagreeing is a strong signal for rejection.

#### 6. Fine-tuned model (see issue-06-custom-face-model.md)
Train a model specifically on this family's faces. Even Option C (SVM on Vision embeddings) could yield 10-15% accuracy improvement.

#### 7. Face tracking instead of per-frame detection
Use `VNTrackObjectRequest` to track detected faces across frames instead of re-detecting every frame. This:
- Reduces computation (track is cheaper than detect)
- Provides temporal coherence (same face across frames)
- Catches frames where detection fails but tracking continues

### Longer Term (months)

#### 8. Video-specific preprocessing
- Deinterlace before processing (many family videos are interlaced)
- Temporal denoising for VHS-quality sources
- Super-resolution upscaling for low-res faces (Real-ESRGAN or similar)

#### 9. Negative reference set
Allow the user to mark "NOT this person" — faces that were incorrectly matched. Use these as hard negatives to improve discrimination:
```swift
if minDistanceToPositiveRef < threshold && minDistanceToNegativeRef > threshold * 0.8 {
    // Good match to target AND far from known non-targets
    acceptHit()
}
```

## Metrics and Evaluation

Before making changes, establish a baseline:
1. Pick 5-10 video clips where you know exactly when the target person appears
2. Run detection, record: true positives, false positives, false negatives
3. Compute precision (TP / (TP + FP)) and recall (TP / (TP + FN))
4. After each improvement, re-run and compare

The existing test infrastructure (`tests/personfinder_cases.json`) can be extended for this.

## Recommendation

Start with **#1 (adaptive thresholding)** and **#3 (temporal smoothing)** — both are small code changes with outsized impact. Then **#4 (preprocessing)** for the VHS-era material. These three together should significantly reduce both false positives and false negatives before investing in model training or ensemble approaches.
