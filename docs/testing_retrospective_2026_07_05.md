# Testing Retrospective — 2026-07-05

Triggered by three same-day escapes, all found in production use rather
than by the 2,353-test suite. Rick's questions: are bugs getting in?
are the unit tests too simplistic? how do we write better tests at
feature time? and how do we get automated integration tests that drive
the real app with real data?

## The three specimens

| Bug | Class | Why the suite missed it |
|---|---|---|
| Test-host restored REAL scan targets (`restoreScanTargets` ungated; M5/M1 prefs contain `/`) | **Environment boundary** | Tests pass on any machine whose prefs are benign. The failure is code × machine-state, and CI machines were clean. |
| Volumes-window beachball (4 full-catalog sweeps per row per keystroke; 91% of a main-thread sample) | **Cost boundary** | The code is *correct*. No correctness assertion can go red on O(n) work in a view body. |
| Analyze fails on FFV1/Matroska masters (AVFoundation gatekeepers in front of ffmpeg-capable stages) | **Capability boundary** | Fixture monoculture: every media fixture was mp4/mov — formats AVFoundation happens to read. |

**Conclusion: bugs are not getting into function-level logic** — the
suite is good at that. They enter at boundaries the suite holds
constant: the machine, the clock, the media zoo, the cost. This matches
the walker-incident lesson (see `project_complexity_humility`):
integration-boundary bugs escape unit tests *systematically*.

## Are the unit tests too simplistic?

Not simplistic — **narrow in the dimensions they vary**. They vary
logic inputs thoroughly while holding constant:

1. **Environment** — clean UserDefaults, present volumes, empty caches
2. **Media** — mp4/mov fixtures only (until `test_ffv1_pcm_4s.mkv`)
3. **Cost** — assertions check *what* was computed, never *how much*

## The feature-test checklist (adopted 2026-07-05)

Applied to every feature/fix from now on (also in CLAUDE.md):

1. **Logic** — the tests we already write
2. **Scale** — if it iterates `records`, exercise at 100k synthetic
   records with an explicit time budget (pattern:
   `VolumeStatusCacheTests.aggregatePassStaysWithinBudgetAtScale`)
3. **Media matrix** — if it opens media files, run across the codec
   matrix: mp4/h264, mov/prores, mkv/ffv1+pcm, mxf, avi/dv. Synthetic
   generation is one ffmpeg line each (see the mkv fixture recipe in
   `MKVDossierPipelineTests.swift`)
4. **Isolation** — if it reads global state (UserDefaults, shared
   caches, real paths), add a poisoned-state test (pattern:
   `ScanTargetRestoreIsolationTests`)
5. **Sensor** — leave one regression sensor behind that pins the fixed
   behavior at production scale

Static tier (planned, not built): custom SwiftLint rule flagging
`records.filter/.contains/.count` inside `*View.swift` /
`*Window.swift` — crude but would have flagged the beachball at commit
time. Tier 1 of `project_bug_prevention_strategy`.

## Integration tests that drive the real app

Assets already in hand:

- **TestDriver** launches the real app in CI (Smoke/Diagnostic)
- UI carries `accessibilityIdentifier`s (`catalog.row.analyze`,
  `volumeRow.markRetired`, …) — XCUITest-ready
- The test-host isolation seam (2026-07-05) is exactly the plumbing a
  sandboxed launch needs: one `VS_DATA_DIR`-style override and the real
  app boots against a snapshot data directory instead of the live
  catalog
- Catalog snapshot = copying catalog.json + metadata_cache.sqlite —
  cheap; media referenced by it may be offline, which integration
  scenarios must tolerate (or use a curated fixture tree)

### The ladder (one, then two, then three…)

- **Rung 0 (prerequisite)**: every nightly logs "UI test runner
  hung/timed out" — we already own a UI test target that silently never
  runs. Diagnose and fix the hang first.
- **Rung 1**: launch app on a real-catalog snapshot; search "Donna" →
  assert results; type 20 chars in Volume notes → assert elapsed
  budget. *Catches 2 of today's 3 bugs.*
- **Rung 2**: right-click Analyze on the mkv fixture through the real
  UI; await dossier completion; assert a transcript landed. *Catches
  the third.*
- **Rung 3**: scan fixture tree → Finder-rename files → rescan →
  assert record identity survived (move-rename arc end-to-end).

Cadence: nightly on the M4 alongside TestDriver, not per-commit.
Data: an anonymized/synthetic 100k-record catalog generator plus a
small real-media fixture tree; never the live catalog.

## Fixed today (all merged to main 2026-07-05)

- `983d4c3` test-host restore isolation (+ regression tests)
- `ee6dc98`/`a9fc171` Volumes-window beachball → VolumeStatusCache
  (+ parity, isolation, perf-sensor tests)
- `2cdb4d4` mkv/FFV1 Analyze → ffmpeg fallbacks (+ media-matrix seed
  fixture and tests)
