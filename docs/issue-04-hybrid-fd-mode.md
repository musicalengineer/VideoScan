# Issue #4: Hybrid FD Mode Doesn't Work

## Problem

Hybrid mode is supposed to use Vision as a fast first pass and fall back to dlib for cases Vision misses (profiles, glasses, dim lighting). In practice, it rarely invokes dlib because the fallback logic is too conservative.

## Root Cause

The fallback condition at PersonFinderModel.swift line 676 is:

```swift
case .hybrid:
    let v = await runVision()
    if let v, !v.segments.isEmpty {  // <-- BUG: Any Vision hit skips dlib entirely
        r = v
    } else {
        // dlib only runs if Vision found ZERO segments
        ...
    }
```

If Vision detects *any* face hit (even a borderline false positive at distance 0.49), it creates segments, and hybrid returns Vision's results without ever consulting dlib. This defeats the purpose — the hard cases (dim lighting, partial face, glasses) often produce low-quality Vision hits that shouldn't be trusted alone.

## Three Sub-Problems

### 1. Fallback logic too coarse
Vision creating any segment at all prevents dlib from running. Should use quality-based thresholds instead of a binary "found anything" check.

### 2. No frame display during dlib fallback
When hybrid does fall back to dlib (on the rare occasion Vision finds zero hits), the RT FD window goes blank because dlib has no `frameFn` (Issue #3).

### 3. No merged results
Even if both engines ran, there's no logic to merge Vision and dlib segment results. Hybrid should be able to combine hits from both engines.

## Proposed Fix

### Phase 1: Smarter Fallback (Quick Fix)

Replace the binary check with a quality threshold. If Vision's best distance is above a "confident" threshold, also run dlib:

```swift
case .hybrid:
    let v = await runVision()
    let visionConfident = (v?.segments ?? []).contains { seg in
        seg.bestDistance < settings.threshold * 0.85  // well below threshold = confident
    }
    if let v, visionConfident {
        r = v
    } else {
        // Vision absent or marginal — try dlib
        if !settings.dlibReadyForHybrid {
            await job.appendLog("[hybrid] Vision: marginal/no hits — dlib not configured")
            r = v
        } else {
            let hitCount = v?.segments.count ?? 0
            let bestDist = v?.segments.map(\.bestDistance).min()
            await job.appendLog("[hybrid] Vision: \(hitCount) hit(s), best dist \(bestDist.map { String(format: "%.3f", $0) } ?? "—") — running dlib for second opinion")
            let d = await runDlib()
            r = pfMergeResults(vision: v, dlib: d)
        }
    }
```

### Phase 2: Segment Merging

When both engines produce results, merge them intelligently:

```swift
private func pfMergeResults(vision: pfVideoResult?, dlib: pfVideoResult?) -> pfVideoResult? {
    guard let v = vision else { return dlib }
    guard let d = dlib else { return v }
    
    // Union of segments, preferring the one with better (lower) distance
    var merged = v.segments
    for dSeg in d.segments {
        if let overlap = merged.firstIndex(where: { overlaps($0, dSeg) }) {
            // Keep the one with better distance
            if dSeg.bestDistance < merged[overlap].bestDistance {
                merged[overlap] = dSeg
            }
        } else {
            merged.append(dSeg)  // dlib found something Vision missed
        }
    }
    merged.sort { $0.startSecs < $1.startSecs }
    
    return pfVideoResult(
        filename: v.filename, filePath: v.filePath,
        durationSeconds: v.durationSeconds, fps: v.fps,
        totalHits: merged.count, segments: merged
    )
}
```

### Phase 3: Parallel Execution (Optional)

For maximum accuracy, run both engines simultaneously and merge:

```swift
case .hybrid:
    async let visionResult = runVision()
    async let dlibResult = runDlib()
    let v = await visionResult
    let d = await dlibResult
    r = pfMergeResults(vision: v, dlib: d)
```

This doubles compute but guarantees both engines contribute. Only viable when memory allows (check MemoryPressureMonitor).

## Recommendation

**Phase 1 is a quick fix** — change the single `if` condition and add logging. This can be done now.

**Phase 2 requires the merge function** — moderate effort, ~1 hour.

**Phase 3 is a future optimization** — requires memory budget coordination for running Vision + Python simultaneously.
