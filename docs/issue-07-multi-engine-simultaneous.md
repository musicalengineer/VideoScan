# Issue #7: Support Different FD Algorithms on Different Volumes Simultaneously

## Problem

Currently all Person Finder scan jobs use the same recognition engine (the global setting in PersonFinderSettings). Users should be able to run Vision on one volume and dlib on another simultaneously.

## Current Architecture

### Engine Selection
- `RecognitionEngine` enum: `.vision`, `.dlib`, `.hybrid` (PersonFinderModel.swift line 28)
- Stored in `PersonFinderSettings.recognitionEngine` (global, app-wide)
- Snapshot taken at job start: `let settings = self.settings` (line 439)
- All jobs launched from the same start action get the same engine

### Job Model
- `ScanJob` class (line 309) has no per-job engine field
- Jobs can be paused/resumed independently
- Each job tracks its own state, results, live frame, etc.

### Memory Budget
- `MemoryPressureMonitor` already has per-engine budgets (MemoryPressure.swift line 76)
- `workerBudgetMB(for: .vision)` = 3072 MB, `for: .dlib` = 1024 MB
- `hardCap` limits concurrency per engine type
- This is already architecture-aware — it just needs per-job engine to key off of

## Proposed Changes

### 1. Add per-job engine override to ScanJob

```swift
class ScanJob: ObservableObject, Identifiable {
    // ... existing fields ...
    @Published var engineOverride: RecognitionEngine? = nil
    
    var effectiveEngine: RecognitionEngine {
        engineOverride ?? PersonFinderSettings.shared.recognitionEngine
    }
}
```

### 2. Update job dispatch to use per-job engine

In `processOne(idx:)` (line 605), change:
```swift
// Before:
switch settings.recognitionEngine {

// After:
switch job.effectiveEngine {
```

### 3. Add engine picker per-job in the UI

In PersonFinderView's job configuration area, add a `Picker` for engine selection:
```swift
Picker("Engine", selection: $job.engineOverride ?? settings.recognitionEngine) {
    ForEach(RecognitionEngine.allCases) { engine in
        Text(engine.shortLabel).tag(engine)
    }
}
.pickerStyle(.segmented)
```

### 4. Update memory tracking for mixed engines

The MemoryPressureMonitor already supports per-engine budgets. The main change is tracking active workers by engine type:

```swift
func recommendedConcurrency(requested: Int, engine: RecognitionEngine) -> Int {
    // Consider OTHER running jobs' engine types when computing budget
    let visionWorkers = activeJobs.filter { $0.effectiveEngine == .vision }.count
    let dlibWorkers = activeJobs.filter { $0.effectiveEngine == .dlib }.count
    // Allocate remaining budget for this engine type
}
```

## Complexity

**Low-medium.** The functional dispatch pattern already supports this — the engine is just a switch case. The main work is:
1. Adding the per-job field (~10 lines)
2. Updating the dispatch to read from job instead of global settings (~5 lines)
3. Adding the UI picker (~15 lines)
4. Updating memory tracking (~20 lines)

The hardest part is testing — verifying that Vision and dlib can run simultaneously without stepping on each other's memory. The existing per-engine memory budgets handle most of this.

## Validation Plan

1. Start a Vision scan on Volume A
2. While it's running, start a dlib scan on Volume B
3. Verify both produce results
4. Verify memory stays within bounds
5. Verify RT FD window shows correct engine's output for each job
