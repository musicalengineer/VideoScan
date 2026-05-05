# Regression-Test Backlog

**Last updated:** 2026-05-02
**Purpose:** A prioritized list of fixed bugs that deserve a regression test under the regression-test-by-revert pattern (see `development_practices.md`). Each entry has a sketch of how to test, current status, and an honest call on feasibility.

The bar: **every entry should produce a test that has been *seen to fail* on the broken code.** Tests that have never failed are theater — they don't lock the bug out, they just inflate coverage.

---

## How to use this doc

When picking the next regression test to write:

1. Pick the **highest "leverage / hour"** entry not yet checked off.
2. Find the original fix commit in git (this doc lists shas where known).
3. Write the test asserting *current* behavior.
4. Verify red-green-revert: revert the fix locally, run the test (should FAIL), restore the fix, run again (should PASS).
5. Tag the test with the convention: `// regression: #<issue> — <one-line summary>`.
6. Commit the test alongside no other code changes (test-only commit makes the regression record clean).
7. Update this doc — point at the actual test file:line, mark "✅ Done (verified-by-revert)" or "✅ Done (markered, revert audit pending)".

`grep "// regression:" -r VideoScan/VideoScanTests/` gives the running count of bugs locked out. That number is more meaningful than the coverage percentage.

---

## Priority 1 — Pure-logic, high leverage

These are pure-function tests with no UI or network dependency. Cheap to write, robust over time.

### #7 — Per-volume FD engine selection ✅ Done (markered, revert audit pending)
- **Fix:** `ScanJob.effectiveEngine` resolves `assignedEngine` (job override) > `assignedProfile.engine` > Vision default.
- **Tests:** `VideoScanTests/ScanConfigurationTests.swift`
  - `effectiveEngineDefaultsToVision`
  - `effectiveEngineUsesProfileEngine`
  - `effectiveEngineJobOverrideTakesPriority`
- **Next step:** revert `ScanJob.effectiveEngine` to a hardcoded `.vision`, confirm all three tests fail.

### #39 — Show in Catalog / Show Pair navigation ✅ Done (markered, revert audit pending)
- **Fix:** `VideoScanModel.catalogFilterIDs(for:pairMode:in:)` returns both record IDs when the record has a paired partner; falls back to `pairGroupID` when `pairedWith` is nil.
- **Tests:**
  - `VideoScanTests/CombineTests.swift` — `CatalogNavigationTests` (`singleRecordNoPairMode`, `pairModeWithPairedWith`, `pairModeWithPairGroupIDFallback`, `pairModeFromAudioSide`)
  - `VideoScanTests/BoundaryTests.swift` — `CatalogFilterBoundaryTests` (`emptyRecordsList`, `pairGroupWithMultipleMembers`)
- **Next step:** revert the `else if let gid = rec.pairGroupID` fallback branch, confirm `pairModeWithPairGroupIDFallback` and `pairModeFromAudioSide` go red.

### #28 — Byte size formatting (MBs/GBs) ✅ Done (markered, revert audit pending)
- **Fix:** `Formatting.humanSize` formats bytes correctly across kB/MB/GB/TB ranges.
- **Tests:** `VideoScanTests/FormattingTests.swift` — `humanSize`, `humanSizeEdgeCases`.
- **Next step:** intentionally break the divisor in `humanSize` (e.g. swap 1024 → 1000), confirm tests fail.

### #5 — Volume reachability (auto-wake) ✅ Done (markered, revert audit pending)
- **Fix:** `VolumeReachability.isReachable(path:)` correctly identifies offline volumes.
- **Tests:** `VideoScanTests/BoundaryTests.swift` — `VolumeReachabilityBoundaryTests` (`emptyPath`, `nonexistentVolume`); plus `ScanEngineTests.swift` `VolumeRootTests`.
- **Next step:** force `isReachable` to return `true` unconditionally, confirm `emptyPath` and `nonexistentVolume` fail.

### #23 — Catalog-aided skip during person search
- **Fix:** Person scan filters out catalog-known-bad records (audio-only, ffprobe-failed, no-streams) before processing. Live in `pfCatalogSkipSet()` in `PersonFinderModel.swift`.
- **Test:** Function reads from `CatalogStore.shared` (MainActor singleton). Two paths:
  - **Refactor first**: extract pure helper `pfCatalogSkipSet(from records: [VideoRecord])` and have the public function call it. Then unit test the pure helper with a synthetic record array. Cheapest correct route.
  - **Or**: build records on disk, load via CatalogStore. Heavier setup; not preferred.
- **Status:** Not yet.
- **Estimated time:** 30 min if going the refactor route.

### #35 — POI storage location/migration
- **Fix:** `POIStorage.folder/migrateLegacyIfNeeded` handles the move from old `~/dev/VideoScan/poi_*` to `~/Library/Application Support/VideoScan/POI/`.
- **Test:** Set up a fake legacy structure in a temp dir, override the legacy paths via a test seam, run migration, assert files moved + new structure correct.
- **Status:** May exist already. Verify and add gaps.
- **Estimated time:** 1 hour (file I/O fixtures).

---

## Priority 2 — Mid-difficulty (state machine, concurrency)

### #40 — Combine main-thread blocking
- **Fix:** Long combine operations run via `Task.detached` instead of cooperative pool, freeing the main thread.
- **Test:** Hard to assert "main isn't blocked" deterministically. Practical alternative: instrument the combine entry to record the actor it ran on, assert it ran off-main. Less rigorous but catches naive regressions.
- **Estimated time:** 1-2 hours.

### #1 — MP4 corrupted when codecs muxed
- **Fix:** Combine engine detects codec incompatibility before stream-copy mux, falls back to re-encode.
- **Test:** Likely covered in `CombineTests.swift`. Verify the codec-detect path has a regression test that would fail if the auto-detect was reverted. Add a `// regression: #1` marker if the test exists; write one if it doesn't.
- **Status:** Verify-existing.
- **Estimated time:** 30 min verification.

---

## Priority 3 — Worth doing eventually

### #12 — Delete duplicates safety
- **Fix:** Cross-volume duplicates are not flagged for deletion — only same-volume duplicates where keeper exists on the same volume.
- **Test:** Construct a duplicate group split across two volumes; assert `volumesWithDeletableDuplicates` does NOT include them. *Probably already exists as `VolumesWithDeletableDuplicatesTests/crossVolumeDupsNotReported`.*
- **Status:** Verify-existing — find and add `// regression: #12` marker.

### #37 — Add/remove photos from POI
- **Fix:** Edit-Person sheet adds/removes reference photos from the POI folder cleanly.
- **Test:** Create a temp POI, add a photo file, assert in folder; remove, assert gone. File-I/O test, mid-difficulty due to filesystem dependencies.
- **Estimated time:** 1 hour.

### #32 — Recover broken videos
- **Fix:** Decision tree for recovery (which broken-state files are recoverable vs not).
- **Test:** Pure logic if the decision is in code; mock the input states, assert classification. Valuable when this lands.

---

## Hard / impractical (don't write unit tests for these)

These need integration tests, visual regression, or system-level test infrastructure:

| # | Title | Why |
|---|---|---|
| #24 | Photos import slow during scan | Timing-dependent; can only assert dispatch was off-main, not that it's "fast enough" |
| #3 | dlib RT FD window empty | Requires running Python subprocess + dlib in test env |
| #4 | Hybrid FD doesn't work | Requires both Vision + dlib running |
| #19 #20 #38 #41 | UI layout | SwiftUI views; not unit-testable in any meaningful way |
| #13 | CI fails | Process/infrastructure |

For these, the right move is either:
- **Manual test plan** with reproducer steps documented in the issue.
- **Smoke / integration test** that's run separately from unit suite (slow, optional).
- **Accept that they live as known-fragile areas** with clear reproducers in the issue tracker.

---

## Already covered (assumed-tested; verify when convenient)

These have visible tests in the suite — but per the philosophy, "verified-to-fail-on-broken-code" is the bar, not just "exists":

- #1 mp4 codec mux → `CombineTests.swift`
- #9 FD engine cases → `ScanEngineTests.swift` / `ModelTests.swift`
- #28 byte formatting → `FormattingTests` ✅ markered
- #30 import/export catalogs → `CatalogTests.swift`
- #35 POI storage → exists in tests
- #5 volume reachability → `BoundaryTests` + `ScanEngineTests` ✅ markered
- #12 cross-volume duplicate safety → `DuplicateDetectorTests`

A separate audit pass should verify each of these *would* fail under regression, not just "still passes today." Schedule that as a half-day exercise sometime.

---

## Pattern for new tests

Tag every regression test with the issue number so they're greppable:

```swift
// regression: #39 — Show in Catalog should include pair partner via pairGroupID fallback
@Test func catalogFilterIDs_pairMode_includesPairGroupMembers() { … }
```

Run `grep -r "// regression:" VideoScan/VideoScanTests/` to count locked-out bugs.
