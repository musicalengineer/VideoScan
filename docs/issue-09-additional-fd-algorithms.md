# Issue #9: More FD Algorithm Options — Confirm Pluggable Architecture

## Current Pluggable Architecture

The engine system is **functional dispatch, not protocol-based** (PersonFinderModel.swift lines 15-26):

```
Each engine implements the same async contract:
  (filePath, settings, callbacks) -> pfVideoResult?
```

### Adding a New Engine (Documented Steps)

1. Add case to `RecognitionEngine` enum (line 28)
2. Add matching `case` in the `switch settings.recognitionEngine` block in `processOne()` (line 668)
3. Implement the processing function matching the `pfVideoResult?` return type
4. (Optional) Add per-engine memory/concurrency tuning to `MemoryPressureMonitor`

### What Already Works
- Engine enum with metadata (title, subtitle, symbol, capabilities, requirements)
- Per-engine memory budgets in MemoryPressureMonitor
- Per-engine concurrency caps (hardCap)
- UI picker with engine descriptions
- Clean separation: dispatch logic is a simple switch, engines are independent functions

## Candidate Engines

### 1. CoreML with ArcFace/FaceNet (Recommended First Addition)

**What:** A CoreML model for face embedding, replacing Vision's built-in feature prints.

**Why:** Vision's `VNGenerateFaceFeaturePrintRequest` is a black box — can't tune it, can't fine-tune it, can't see what it's doing. CoreML gives full control.

**Implementation:**
```swift
case .coreml:
    // Use Vision for face DETECTION (it's fast on ANE)
    // Use CoreML for face RECOGNITION (custom/tunable model)
    let faces = detectFaces(in: frame)  // VNDetectFaceRectanglesRequest
    for face in faces {
        let crop = extractFaceCrop(frame, rect: face.boundingBox)
        let embedding = try coremlModel.prediction(input: crop)
        let distance = euclidean(embedding, referenceEmbedding)
    }
```

**Models available for CoreML conversion:**
- `insightface/buffalo_l` (ArcFace, ONNX → CoreML via coremltools)
- `facenet-pytorch` (PyTorch → CoreML)
- Apple's own `VNClassifyImageRequest` with custom classifier

**Effort:** 2-3 days (model conversion + integration)

### 2. ONNX Runtime (Cross-Platform Alternative)

**What:** Run ONNX models directly on macOS using Microsoft's ONNX Runtime.

**Why:** Huge model zoo (hundreds of face recognition models), no conversion needed, runs on CPU/GPU.

**Implementation:**
- Use `onnxruntime-swift` package (SPM compatible)
- Load any `.onnx` face recognition model
- Pre/post-processing in Swift

**Models:**
- `retinaface_resnet50` (detection)
- `arcface_r100` (recognition)
- `scrfd_10g` (lightweight detection)

**Effort:** 3-4 days (ONNX Runtime integration + model selection)

### 3. MediaPipe Face Detection

**What:** Google's MediaPipe provides fast, accurate face detection with landmarks.

**Why:** Better at difficult angles (profile, tilted) than Vision. Provides 468 face landmarks.

**Implementation:**
- MediaPipe has a Swift/iOS SDK
- Face detection + mesh in one pass
- Landmarks can improve face alignment before embedding extraction

**Effort:** 2-3 days

### 4. Custom CoreML Model (see issue-06)

A family-specific model fine-tuned on your media collection. This is the highest-accuracy option but requires the training pipeline from issue #6.

## Architecture Validation Checklist

To confirm the pluggable architecture works correctly:

- [ ] Add a new `RecognitionEngine` case (e.g., `.coreml`)
- [ ] Implement the processing function
- [ ] Verify it appears in the UI picker
- [ ] Verify per-engine memory budgets work
- [ ] Verify it can run simultaneously with another engine (issue #7)
- [ ] Verify results flow through to clip extraction and compilation
- [ ] Verify the RT FD window works (if the engine provides frames)

## Recommendation

**Start with CoreML + ArcFace.** It reuses Vision for detection (fast, already working) but replaces the recognition embedding with a known, tunable model. This validates the pluggable architecture with minimal risk and provides a foundation for the custom model training in issue #6.
