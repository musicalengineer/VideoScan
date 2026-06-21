# Face-Pipeline Test Gap Analysis — 2026-06-20

Scope: face-recognition / person-finder pipeline ("find Donna in video").
Goal: close highest-value regression gaps without modifying production source.

Build config for this work: **Debug, ONLY_ACTIVE_ARCH=YES (arm64)**,
derivedDataPath `/Users/rickb/dev/VideoScan/.deriveddata-overnight-tests`.
Optimizer parity not required (pure-logic units). New tests ran in 0.020s.

---

## STEP 1 — Current coverage (what IS tested)

The reachable pure-logic surface of the face pipeline is already
**well covered**. Verified by reading the test target
`VideoScan/VideoScanTests/`. Relevant existing coverage:

| Area | Test file | Notes |
|---|---|---|
| Engine resolution (job override > profile > global) | `ScanConfigurationTests` | `effectiveEngine*` cases |
| Profile → settings threshold/engine apply | `ScanConfigurationTests` | `applyProfileSetsThresholds`, `applyProfileSetsEngine` |
| dlib bail paths (python missing / non-exec / script missing / pre-cancel) | `PersonFinderEngineDispatchTests` | log-line assertions; disabled on virt-M1 CI |
| ArcFace ref-embedding cache shape + invalidation | `PersonFinderEngineDispatchTests` | pins the 2026-05-12 MLE5 crash fix |
| Cache key (videoPath/size/modDate/person/engine/threshold/refHash) miss matrix | `PersonFinderCacheTests` | incl. float-threshold precision, round-trip, clearAll |
| `dlibReady` / `dlibReadyForHybrid` | `PersonFinderLifecycleTests` | engine-independence pinned |
| `pfClampNominalFps` (incl. boundaries 240.0 / 240.001 / 0 / neg) | `PersonFinderFpsClampTests` | corrupt-metadata regression sensor |
| `pfShouldAbortForWatchdog` (60s floor, 10× rule, exact-budget edge) | `PersonFinderWatchdogTests` | full boundary set |
| `pfOrientationFromTransform` | `EngineSmokTests` | up/right cases |
| `pfNormalizeFaceCrop` (size contract, degenerate bbox → nil) | `PersonFinderBoundaryTests` | |
| `pfDetectFacesInBuffer` blank-buffer → empty | `PersonFinderBoundaryTests` | |
| `pfDownsampledForDetection` geometry | `PersonFinderDownsampleTests` | cap/aspect/portrait/zero/nil |
| pause/resume, removeJob, restoreFromCache no-op guards | `PersonFinderBoundaryTests` | |
| ArcFace MLE5 concurrency crash provocation | `StressTests/ArcFaceMLE5ProvocationTests`, `ArcFaceParallelSearchReproducerTests` | serialized-lock stress |
| Python dlib engine end-to-end | `tests/run_personfinder_tests.py` + `personfinder_cases.json` | manifest: self-test + 2 Donna clips, min faces/hits/segments |

Conclusion: the obvious reachable units already have sensors. The
remaining real gaps are mostly **behind `private` file-scope visibility**
in `PersonFinderDetection.swift` and cannot be tested without a seam.

---

## STEP 2 — Gaps, ranked

### Closed by this work (reachable, were untested)

1. **`arcfaceCosine` — the ArcFace match primitive.** 0 direct coverage.
   Every ArcFace hit decision is `arcfaceCosine(...) >= arcfaceThreshold`
   (default 0.40). Critically it is a **bare dot product** that is only a
   true cosine because callers pass L2-normalized embeddings (normalized
   in `arcfaceEmbedding`, ArcFaceEngine.swift ~L235). High blast radius if
   it drifts; silent (no crash) failure mode. **CLOSED.**

2. **`pfSegment.duration` / `pfVideoResult.totalPresenceSecs`.** 0 direct
   coverage. This arithmetic feeds the presence-inclusion gate
   (`filterByPresence`, JobLifecycle L574) that decides whether a scanned
   video appears in results at all. **CLOSED** (the property side; the
   filter function itself needs a seam — below).

### Open — blocked on a production seam (NOT closed; do not weaken)

3. **`pfVisionClusterSegments` (temporal grouping of hits → segments).**
   `private` in PersonFinderDetection.swift. Highest-value *untested* gap:
   gap-tolerance merge (`frameStep/fps*3`), padding, overlap merge,
   `minDuration` filter — all the clip-boundary logic. Needs visibility.

4. **Match-threshold boundary `best <= settings.threshold`** inside
   `pfVisionMatchCandidates` (`private`). The Vision-engine analogue of
   the arcface boundary now covered.

5. **`pfDecodeDlibResult` (dlib JSON → segments mapping).** `private`.
   Malformed/partial JSON handling and field-name contract
   (`best_dist`, `avg_dist`, `hit_count`) are unprotected.

6. **Threshold-by-engine selection** `recognitionEngine == .arcface ?
   arcfaceThreshold : threshold`. Duplicated inline at JobLifecycle L767
   AND L602. If the two copies drift, the cache pre-count and the cache
   write key disagree. Needs extraction to a helper to test.

7. **`filterByPresence`** itself (`private nonisolated static`). The
   keep/skip partition + skipped-count. Property arithmetic is now pinned;
   the partition logic is not.

8. **Settings persistence isolation.** `PersonFinderSettings.save()` /
   `restored()` use `UserDefaults.standard` directly (Types.swift L203).
   Tests that exercise persistence would pollute Rick's real `pf_*` prefs.
   Untestable safely without injecting a `UserDefaults` suite.

---

## STEP 3/4 — New tests added (all GREEN)

Synchronized file group — both files were auto-included by the test target
(no `project.pbxproj` edit required; confirmed by build pickup).

### `VideoScan/VideoScanTests/PersonFinderArcFaceCosineTests.swift`
Suite `arcfaceCosine`, 10 tests. Asserts:
- identical unit vectors → 1.0; orthogonal → 0; antiparallel → -1
- result stays in [-1,1] over 64 random unit-vector pairs
- length mismatch → -1 never-match sentinel (both arg orders)
- empty/empty → 0 (equal length passes guard) — distinct from mismatch
- threshold boundary: cosine exactly 0.40 satisfies `>= 0.40` (inclusive);
  0.35 fails; 0.45 passes (constructed via known-cosine unit pairs)
- **normalization-contract tripwire**: a 3× scaled input yields a 3× score,
  documenting that correctness depends on callers passing L2-normalized
  embeddings. If the function is ever made to self-normalize, this fails
  and forces a conscious paired change.

### `VideoScan/VideoScanTests/PersonFinderPresenceArithmeticTests.swift`
Suite `pfSegment / pfVideoResult presence arithmetic`, 8 tests. Asserts:
- `pfSegment.duration` = end − start; zero-length → 0
- `totalPresenceSecs` = sum of segment durations; 0 when no segments;
  single-segment equals its duration
- characterization: overlapping segments **sum, not union** (pins what IS;
  production clusters before this layer so inputs are disjoint)
- presence gate boundary against default `minPresenceSecs == 5.0`:
  exactly 5.0s is KEPT (inclusive `>=`), 4.9s is SKIPPED

### Green confirmation
```
xcodebuild test -scheme VideoScan -configuration Debug
  -destination 'platform=macOS,arch=arm64' ONLY_ACTIVE_ARCH=YES
  -derivedDataPath .deriveddata-overnight-tests
  -only-testing:VideoScanTests/PersonFinderArcFaceCosineTests
  -only-testing:VideoScanTests/PersonFinderPresenceArithmeticTests
→ ** TEST SUCCEEDED **  18 tests in 2 suites passed in 0.020s
```

---

## STEP 5 — Remaining gaps needing product seams (proposals)

Non-additive; for `feature-dev`/Rick to decide. None applied here.

- **Make `pfVisionClusterSegments` testable.** Either change `private` →
  `internal` (preferred — intra-target tests), or add a thin
  `internal`-visible wrapper. Then test: gap-tolerance split, pad clamp to
  `[0, duration]`, overlap merge, `minDuration` drop, empty-in → empty-out,
  single-hit → single segment.
- **Extract the threshold-by-engine selection** into one helper
  `func effectiveThreshold(_ settings) -> Float` and call it from both
  L767 and L602. Then a 4-line test pins arcface vs non-arcface and kills
  the drift risk between the cache pre-count and the write key.
- **`internal`-ize `filterByPresence`** (or its pure core) to test the
  keep/skip partition and the skipped-count (empty-segment results must
  not be counted as skipped).
- **Inject `UserDefaults` into `PersonFinderSettings`** (default
  `.standard`, override with a named suite in tests) so save/restore
  round-trips can be tested without polluting Rick's real `pf_*` prefs.
- **`internal`-ize `pfDecodeDlibResult`** to test malformed/partial JSON
  and the snake_case field contract.

---

## Bug candidates

**None.** No new test failed; nothing was removed for revealing a product
bug. The `arcfaceCosine` magnitude-sensitivity is **intended** behavior
(documented contract: inputs are pre-normalized), so it is pinned as a
contract test, not flagged as a bug.

One thing to keep visible (not a bug): the threshold-by-engine expression
is duplicated at JobLifecycle.swift L767 and L602. Today they are
identical; the extraction proposal above removes the latent drift risk.
