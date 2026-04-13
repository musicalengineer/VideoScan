# Issue #3: dlib Algorithm — RT FD Window Empty

## Problem

When using the dlib engine, the Realtime Face Detection window shows "Waiting for frames..." and never displays any video frames or face detection boxes.

## Root Cause

Architecture mismatch between Vision and dlib processing paths.

**Vision path** (`pfProcessVideo`, line 1072): Processes video frames in Swift using AVFoundation. Each frame is a CGImage that gets passed to both Vision (for face detection) and the `frameFn` callback (for RT display). The callback updates `job.liveFrame`, `job.liveMatchedRects`, and `job.liveUnmatchedRects`, which the `ActiveJobFaceDetectView` observes.

**dlib path** (`pfProcessVideoWithDlib`, line 1341): Launches a Python subprocess that does ALL the work — frame extraction, face detection, recognition, and segmentation — internally. Swift never sees any video frames. The function signature has no `frameFn` parameter. The subprocess returns only a JSON result with segments and hit counts.

Since the RT FD window reads `job.liveFrame` (which is only set by the Vision path's `frameFn` callback), the window stays empty when dlib is active.

## Proposed Fix: Parallel Frame Preview Thread

Add a lightweight Swift-side frame sampler that runs alongside the dlib subprocess to feed the RT display.

### Approach

1. **Add `frameFn` to `pfProcessVideoWithDlib`** signature
2. **Launch a parallel async task** that extracts frames from the video using AVAssetImageGenerator at the same frame step rate
3. **Parse dlib's stderr** for progress/face-location data (the Python script already logs per-frame results to stderr)
4. **Overlay face boxes** from dlib's streaming output onto the sampled frames

### Implementation Sketch

```swift
private nonisolated func pfProcessVideoWithDlib(
    filePath: String,
    settings: PersonFinderSettings,
    index: Int, total: Int,
    pauseGate: PauseGate,
    logFn:      @escaping @Sendable (String) async -> Void,
    progressFn: @escaping @Sendable (String) async -> Void,
    frameFn:    @escaping @Sendable (CGImage, [CGRect], [CGRect]) async -> Void,  // NEW
    distFn:     @escaping @Sendable (Float)  async -> Void
) async -> pfVideoResult? {

    // Launch frame preview sampler in parallel with the Python subprocess
    let previewTask = Task.detached {
        let asset = AVURLAsset(url: URL(fileURLWithPath: filePath))
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 640, height: 360)
        
        let duration = try await asset.load(.duration).seconds
        let step = Double(settings.frameStep) / (settings.fps ?? 30.0)
        var t = 0.0
        while t < duration && !Task.isCancelled {
            if let img = try? gen.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil) {
                await frameFn(img, [], [])  // face rects added when we parse stderr
            }
            t += step
        }
    }

    // ... existing dlib subprocess launch ...
    // When subprocess finishes, cancel the preview task
    previewTask.cancel()
}
```

### Enhanced Approach: Parse dlib Face Locations from stderr

Modify `face_recognize.py` to emit per-frame face coordinates in a parseable format on stderr:

```python
# In face_recognize.py, per-frame output:
print(f"FRAME:{frame_num}:{json.dumps(face_rects)}:{json.dumps(match_rects)}", file=sys.stderr)
```

Then in Swift, parse these lines in the `stderrLine` callback to update the RT display with actual face boxes:

```swift
stderrLine: { line in
    if line.hasPrefix("FRAME:") {
        // Parse face rectangles and feed to frameFn
        let parts = line.split(separator: ":")
        // ... decode rects, call frameFn with current frame + rects
    }
    Task { await logFn("  " + line) }
}
```

## Complexity

**Medium-high.** The parallel frame sampler is straightforward, but synchronizing frame timing between Swift's AVAssetImageGenerator and Python's opencv frame extraction requires care. The enhanced approach (parsing stderr for face rects) is more valuable but requires coordinating frame indices between the two.

## Alternative: Simple Progress-Only Display

A simpler option: instead of showing live face detection, show a progress animation with the current frame and processing stats (faces found, segments, etc.) parsed from dlib's stderr. This doesn't show face boxes but at least gives visual feedback that dlib is working.
