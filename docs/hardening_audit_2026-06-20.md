# VideoScan Face-Recognition Pipeline — Hardening / QA Audit

Date: 2026-06-20
Scope: READ-ONLY audit of the Person Finder recognition pipeline.
Auditor: QA pass (no source edited, no build, no git).

Files in scope:
- `VideoScan/VideoScan/PersonFinderModel.swift`
- `VideoScan/VideoScan/PersonFinderModel+JobLifecycle.swift`
- `VideoScan/VideoScan/PersonFinderDetection.swift`
- `VideoScan/VideoScan/PersonFinderEngineDispatch.swift`
- `VideoScan/VideoScan/ArcFaceEngine.swift`
- `VideoScan/VideoScan/PersonFinderCache.swift`
- `VideoScan/VideoScan/PersonFinderTypes.swift`
- `VideoScan/VideoScan/MemoryPressure.swift`
- `VideoScan/VideoScan/AsyncSemaphore.swift`

---

## Lightweight metrics

### Top longest Swift files (app source tree, excludes DerivedData / worktrees)

| Rank | Lines | File |
|------|-------|------|
| 1 | 1728 | CaptionOrchestrator.swift |
| 2 | 1686 | Models.swift |
| 3 | 1430 | PersonFinderView.swift |
| 4 | 1324 | DossierDashboardView.swift |
| 5 | 1323 | **PersonFinderModel+JobLifecycle.swift** (scoped) |
| 6 | 1197 | BundleExportImport.swift |
| 7 | 1165 | VolumeCompare.swift |
| 8 | 1127 | ScanJobRow.swift |
| 9 | 1073 | TranscodeJob.swift |
| 10 | 1036 | CatalogPurgeTests.swift |

(Scoped: `ArcFaceEngine.swift` = 677, `PersonFinderModel.swift` = 752, `PersonFinderDetection.swift` = 637.)

### Top longest functions in scoped files

| Lines (approx) | Function | File:line |
|------|----------|-----------|
| ~180 | `pfProcessVideo` | PersonFinderDetection.swift:456 |
| ~172 | `pfProcessVideoWithArcFace` | ArcFaceEngine.swift:504 |
| ~163 | `scanAllVideos` | JobLifecycle.swift:590 |
| ~151 | `runScan` | JobLifecycle.swift:951 |
| ~136 | `startJobAfterLoad` | JobLifecycle.swift:297 |
| ~122 | `processOneVideo` | JobLifecycle.swift:756 |
| ~90 | `arcfaceEmbedding` | ArcFaceEngine.swift:156 |
| ~78 | `restoreSessionFromDisk` | JobLifecycle.swift:1157 |
| ~70 | `getModel` | ArcFaceEngine.swift:78 |
| ~67 | `discoverVideos` | JobLifecycle.swift:882 |

### Marker counts (scoped files)

| Marker | Count |
|--------|-------|
| `try!` | 0 |
| `as!` | 0 |
| `TODO` / `FIXME` / `HACK` / `XXX` | 0 |

The scoped code is notably disciplined on force-unwrap and try!/as! — none present. The one genuinely dangerous force-style operation is a deliberate `unsafeBitCast` in the SQLite bind helper (see P2-1); it is correct C-bridging idiom, not a force-unwrap.

---

## Findings (ranked)

### P0 — ArcFace concurrency (the known latent bug)

#### P0-1 — Shared-MLModel race is *mitigated*, but the global prediction lock makes ArcFace inference fully serial across all jobs (correctness OK, throughput cliff). `[needs-review]`

File: `ArcFaceEngine.swift:30`, `ArcFaceEngine.swift:202`, `ArcFaceEngine.swift:67` (`ArcFaceModelLoader`).

Determination (the asked-for answer):
- The MLModel instance is **NOT** shared across concurrent tasks in the steady state. `ArcFaceModelLoader.getModel()` (line 78) constructs a **fresh `MLModel`** per call; the only cached thing is the resolved `compiledURL`. Each `pfRunArcFaceEngine` call (`PersonFinderEngineDispatch.swift:154`) does `await ArcFaceModelLoader.shared.getModel()` and passes that per-call instance down into `pfProcessVideoWithArcFace`. So two concurrent videos get two distinct `MLModel`s. This matches the documented fix for the original `MLE5BindEmptyMemoryObjectToPort` crash.
- Access to `model.prediction(from:)` is **additionally serialized** by a single process-wide `OSAllocatedUnfairLock` (`arcfacePredictionLock`, line 30) wrapping every prediction call (line 202). Plus an ObjC `@try/@catch` (`VSCatchObjCException`) so an MLE5 NSException that survives serialization is downgraded to a `nil` embedding instead of a SIGABRT.

So: the bug is **masked twice over** — distinct instances AND a global serialization lock AND an exception firewall. The current concurrency limit does not expose it; it is exposed only if both layers are removed.

Why this is still a P0-class concern (throughput / silent-failure, not crash):
1. The global lock serializes *every* ArcFace prediction in the whole process. With N concurrent video workers (`MemoryPressureMonitor.hardCap` allows up to `processorCount` for `.arcface`, MemoryPressure.swift:99), all of them funnel through one lock. The per-frame embedding (`arcfaceEmbedding`, line 156) holds the lock for the entire `model.prediction` duration. This means ArcFace effectively runs at ~1× inference regardless of the worker count the memory guard hands out — the parallelism the rest of the pipeline negotiates is an illusion for the recognition step. This is the dominant scaling risk on a large archive scan.
2. The exception firewall **silently swallows** MLE5 failures: on a caught NSException, `arcfaceEmbedding` returns `nil` (line 226), the face is dropped, and the frame simply contributes no embedding. A run where MLE5 is misbehaving would silently under-detect the target person with no surfaced error to the user — only an `appLog`/`os.Logger` line. `arcfaceExceptionCount` is incremented but never surfaced to the job console or results. For a tool whose whole job is "did we find Donna," silent per-frame embedding loss is a correctness hazard worth a visible signal.

Fix sketch:
- Short term `[safe-additive]`: surface the exception counter. When `arcfaceExceptionCount` crosses a threshold during a job, emit one `job.appendLog` line ("ArcFace inference instability: N frames dropped") so a degraded run is visible. (The plumbing isn't trivially additive because `arcfaceEmbedding` has no `job` handle — see SAFE-ADDITIVE list for the minimal version: log via the existing `appLog` at first occurrence only, already partly done at line 218; add a one-time WARN that is greppable. Treat the deeper surfacing as `[needs-review]`.)
- Medium term `[needs-review]`: the global lock is the throughput cliff. Options: (a) confirm whether distinct-instance inference is *actually* safe now on the current macOS SDK via the existing stress scripts (`scripts/run_arcface_super_stress.sh`, `scripts/run_arcface_parallel_repro.sh`) and, if clean, replace the global lock with a per-instance lock (or no lock) so distinct MLModels run in parallel; (b) if still unsafe, keep the lock but stop pretending ArcFace parallelizes — cap `hardCap(.arcface)` to a small number so the memory guard doesn't hand out workers that just queue on the lock (saves the memory/decoder cost of N stalled workers). Either way the current state — N workers contending on one lock — is the worst of both.

This is the P0. It is not currently a crash, but it is a silent-correctness + throughput problem that lives exactly where the user's primary use case runs.

#### P0-2 — ArcFace reference-embedding cache has a benign-but-real read/compute race that can double-spend the serialized model lock under multi-job. `[needs-review]`

File: `PersonFinderEngineDispatch.swift:172`–`187`.

`pfRunArcFaceEngine` reads `job.assignedArcFaceEmbeddings` on MainActor (line 172); on miss it computes embeddings (which run through the serialized prediction lock) and writes back (line 187). The in-code comment acknowledges that concurrent first-videos in one job each compute a copy ("last writer wins"). Correctness is fine, but the wasted work is *N reference photos × prediction-lock acquisitions* per racing video, and those acquisitions serialize against every other job's live frame inference. On a job with 600–1100 reference images (Rick's catalog has timmy at 1087, donna at 687 per the JobLifecycle restore comment), the first few videos of a fresh ArcFace job can each re-embed the full reference set under the global lock — a multi-thousand-prediction stall that blocks all other ArcFace inference process-wide.

Fix sketch `[needs-review]`: gate the per-job reference-embedding computation behind a single-flight (e.g. an `actor`-isolated "computing" flag or a cached `Task<[[Float]], Never>` on the job) so only the first racing video computes and the others await it. This is an architectural-ish change to the job's embedding cache; flag for review rather than overnight application.

---

### P1 — Concurrency / error-handling / lifecycle

#### P1-1 — `acquireWorkerSlot` / `recommendedConcurrency` window: a worker can be admitted by `recommendedConcurrency` then re-block in `acquireWorkerSlot`, but the slot accounting can over-admit on a memory drop. `[needs-review]`

File: `PersonFinderModel+JobLifecycle.swift:670` (recommendedConcurrency), `:784` (acquireWorkerSlot), `MemoryPressure.swift:114`–`145`.

`scanAllVideos` seeds `scanConcurrency` tasks (line 680) using `recommendedConcurrency`, and each `processOneVideo` *also* calls `acquireWorkerSlot` (line 784). These are two independent admission gates against the same `activeWorkers` counter. `recommendedConcurrency` subtracts `activeWorkers` but is read once at seed time; `acquireWorkerSlot` loops on `canStartWorker`. The seed count and the per-worker acquire can disagree, and because `decrementWorkers` is fired from a detached `Task` in a `defer` (line 788: `defer { Task { await ...decrementWorkers() } }`), the decrement is **not ordered** w.r.t. the next worker's acquire — the slot is released asynchronously, so under churn the counter can transiently under- or over-count. Worst case is a brief over-admission (more workers than the memory budget intends) right when memory is already tight — the opposite of what the guard wants. Not a crash; a guard-weakening race.

Fix sketch `[needs-review]`: make the release synchronous with respect to the worker's structured lifetime — `await MemoryPressureMonitor.shared.decrementWorkers()` directly in a non-Task defer (the enclosing function is already `async`), so the slot is returned before the task completes and the waiter wakes deterministically. Removing the `Task { }` wrapper around the decrement is the core change; confirm no actor-reentrancy issue first.

#### P1-2 — `recommendedConcurrency == 0`-style starvation is guarded, but `acquireWorkerSlot` can busy-wait via continuation re-append with no fairness. `[needs-review]`

File: `MemoryPressure.swift:129`–`136`.

`acquireWorkerSlot` loops: on failure it parks a continuation in `slotWaiters`; `resumeWaitersIfPossible` (line 138) resumes **all** waiters at once on any decrement, and each then re-checks `canStartWorker` and may re-park. With many workers and a tight budget this is a thundering-herd: every decrement wakes every waiter, all but one re-park. Functionally correct (it makes progress) but wasteful and non-FIFO — a late arrival can repeatedly jump ahead of an early one. On a long scan this is just CPU churn on the actor, but it muddies the "honest concurrency" story.

Fix sketch `[needs-review]`: resume only as many waiters as there are newly-available slots, and prefer FIFO (`slotWaiters.removeFirst()` in a loop bounded by available slots) instead of `removeAll()`. Architectural enough to warrant review.

#### P1-3 — `pfProcessVideo` / `pfProcessVideoWithArcFace`: `previewImage` retains a full-resolution `CGImage` across the `await frameFn` outside the autoreleasepool. `[safe-additive]`

File: `PersonFinderDetection.swift:541`–`585`; `ArcFaceEngine.swift:584`–`626`.

The per-frame `autoreleasepool` (Detection:543, ArcFace:586) correctly wraps detection + embedding. But `previewImage` (the full oriented `CGImage`, captured at Detection:574 / ArcFace:615) is assigned to a `var` declared **outside** the pool and then used at Detection:583 / ArcFace:624 (`await frameFn(img, ...)`) — i.e. it is held alive across the `await`, outside the pool, until the next loop iteration overwrites it. On a 4K source this is a ~33 MB oriented bitmap pinned across a main-actor hop. It only materializes every `previewRate` frames (default 5), so it's bounded, but on N concurrent workers each holding one across an await, that's N × (preview-cadence) large bitmaps live simultaneously. Low-severity leak-ish retention, not a true leak.

Fix sketch `[safe-additive]`: after `await frameFn(...)`, set `previewImage = nil` (and/or wrap the `await frameFn` body so the reference drops promptly). Minimal, behavior-preserving. See SAFE-ADDITIVE list.

#### P1-4 — `ProcessRunner.runStreaming` stderr handler spawns an unbounded `Task` per line. `[needs-review]`

File: `PersonFinderEngineDispatch.swift:99`.

`stderrLine: { line in Task { await logFn("  " + line) } }` creates a detached `Task` for **every** stderr line of the dlib Python subprocess. A chatty/erroring script (e.g. a stack trace, or a progress spew) can spawn thousands of unordered tasks racing into `job.appendLog`. `appendLog` is MainActor and batches, so it won't crash, but ordering is lost (interleaved log lines) and the task spawn rate is unbounded. dlib is the least-used engine, so this is P1 not P0.

Fix sketch `[needs-review]`: forward stderr through an ordered async channel (or make `stderrLine` itself `async` and `await` it) instead of fire-and-forget `Task`. Touches the ProcessRunner contract — review.

#### P1-5 — Swallowed Vision errors in reference + per-frame feature printing. `[safe-additive]` (logging only)

File: `PersonFinderDetection.swift:142`–`147` (`pfGenerateFeaturePrint`), `:221` (`pfDetectFacesInBuffer` `try?`), `ArcFaceEngine.swift:291` (`try? handler.perform` in `arcfaceLoadReferenceEmbeddings`).

`pfGenerateFeaturePrint` does `try? handler.perform([req])` and returns `req.results?.first` — a Vision failure is indistinguishable from "no feature print" and is silently dropped. Same pattern in `pfDetectFacesInBuffer` (per-frame, hot path — acceptable to stay quiet there for perf, but a *rate-limited* warn would help diagnose a systematic ANE failure). The reference-photo path (`arcfaceLoadReferenceEmbeddings`, line 291) swallows the detect error entirely — a reference photo that errors in Vision is silently skipped with no `ReferenceLoadFailure` entry (unlike the Vision reference loader at Detection:54–59, which *does* record the failure). This is an asymmetry: ArcFace reference loading gives the user less feedback than Vision reference loading.

Fix sketch `[safe-additive]`: in `arcfaceLoadReferenceEmbeddings`, capture the `perform` error and skip with a logged reason (mirror the Vision loader's `ReferenceLoadFailure` shape if the return type allowed it; minimally, `arcfaceLogger.warning`). For `pfGenerateFeaturePrint`, add a one-line rate-limited debug log on `perform` throw. Pure observability, no happy-path change.

#### P1-6 — `arcfaceEmbedding` raw-pointer copy assumes contiguous Float32 MLMultiArray without checking `dataType` / strides. `[needs-review]`

File: `ArcFaceEngine.swift:229`–`238`.

```
let ptr = arr.dataPointer.bindMemory(to: Float.self, capacity: count)
for i in 0..<count { embedding[i] = ptr[i] }
```

This binds the multiarray's data pointer to `Float` and walks it linearly. It does not verify `arr.dataType == .float32` nor that `arr.strides` describe a contiguous layout. The w600k_r50 model output is float32/contiguous in practice, so it works — but if the model is ever recompiled/replaced (the loader explicitly supports a runtime-supplied `.mlpackage` in `~/dev/VideoScan/models/`, ArcFaceEngine:113) with a `Float16` or strided output, this reads garbage embeddings with no error — every match silently wrong. Given the model file is user-replaceable, this is a real robustness gap.

Fix sketch `[needs-review]`: guard `arr.dataType == .float32` and contiguous strides before the raw copy; fall back to `arr[i]` subscripting (slower, type-safe) otherwise, or return `nil` with a logged "unexpected model output type." Review because it touches the hot inner loop.

#### P1-7 — `restoreFromCache` (auto-run on `loadFacesForJob`) starts a detached scan task that races job status without holding the cap used elsewhere. `[needs-review]`

File: `PersonFinderModel+JobLifecycle.swift:184`–`267`, invoked from `loadFacesForJob:168`.

`restoreFromCache` fires a `Task.detached` that walks `pfFindVideoFiles` (blocking FS) on every `loadFacesForJob`. Unlike `restoreSessionFromDisk` (which caps rehydration concurrency at 3, JobLifecycle:1210), this path has **no global cap** — if the user loads faces for several jobs in quick succession (e.g. "Search for Family" enqueues one job per POI, JobLifecycle:112), each `loadFacesForJob` can spawn its own uncapped detached cache-walk over a slow volume. This is the exact pool-saturation pattern the restore code was rewritten to avoid (see the history comment at JobLifecycle:1190). It writes `job.status = .done` inside a `guard job.status.isIdle` (line 250), so a concurrent `startJob` could interleave the idle check.

Fix sketch `[needs-review]`: route `restoreFromCache` cache-walks through the same capped TaskGroup mechanism as `restoreSessionFromDisk`, or at minimum a shared `AsyncSemaphore` so the family-scan fan-out can't saturate the cooperative pool on a LaCie. Architectural — review.

#### P1-8 — `PersonFinderCache` is a single `NSLock`-guarded SQLite connection shared across all concurrent workers; every lookup/store serializes on it. `[needs-review]` / `[architectural]`

File: `PersonFinderCache.swift:13`–`14`, `185`, `233`.

One `OpaquePointer db` + one `NSLock`. `scanAllVideos` does a full pre-pass `lookup` over every file (JobLifecycle:605) plus per-worker `lookup`/`store` (JobLifecycle:771, 859) — all serialize on `lock`. On a many-thousand-file volume with N workers this lock is a contention point, and each `lookup` does a fresh `prepare_v2`/`step`/`finalize` (no statement caching). Correct, but a scaling bottleneck that compounds with the ArcFace global lock. Also: the pre-pass in `scanAllVideos` and the per-worker check duplicate the same lookup work — every file is looked up at least twice.

Fix sketch `[architectural]`: prepared-statement caching, or WAL-mode read connections per worker, or fold the pre-pass result into the per-worker path so each file is looked up once. Defer to a perf pass; flag as architectural.

---

### P2 — Lower-severity / hygiene

#### P2-1 — `unsafeBitCast(-1, to: sqlite3_destructor_type.self)` for SQLITE_TRANSIENT. `[safe-additive]`

File: `PersonFinderCache.swift:411`–`412`.

This is the standard SQLITE_TRANSIENT idiom (the C macro is `(sqlite3_destructor_type)-1`), so it's correct. But it's the single scariest-looking unchecked cast in the scoped code and would benefit from a named constant + comment so a future reader doesn't "fix" it into a crash.

Fix sketch `[safe-additive]`: define `let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)` once with a comment, reference it in `bind`. Behavior-identical.

#### P2-2 — `pfProcessVideo` / `pfProcessVideoWithArcFace` are ~180 lines each with near-duplicate frame-loop bodies. `[architectural]`

File: `PersonFinderDetection.swift:456`, `ArcFaceEngine.swift:504`.

The two engine loops are structurally identical (open reader → seeker/prefetcher branch → for-await frame → autoreleasepool detect+match → milestones → cluster). They've already been partially factored (shared `openXReader`, `XMatchCandidates`, `XClusterSegments`), but the outer 180-line driver is copy-pasted with `cosine`/`distance` polarity flipped. Divergence risk: a bug fixed in one (e.g. the cancellation comment block, or the watchdog) must be hand-mirrored. The `arcFaceClusterSegments` and `pfVisionClusterSegments` are *byte-for-byte* identical except the type — a latent drift hazard.

Fix sketch `[architectural]`: hoist the shared frame-driver into one generic function parameterized by a per-frame matcher closure and a "better than" comparator. Large refactor — architectural, not overnight.

#### P2-3 — `availableMemory()` counts `free + inactive` pages as available — optimistic under file-cache pressure. `[needs-review]`

File: `MemoryPressure.swift:31`–`42`.

`inactive_count` includes reclaimable file-backed pages, so this over-reports "available" memory, which makes the concurrency guard *more* permissive than true free RAM. On a heavy scan that's also warming the page cache (the DiskFeeder does exactly this), the guard may admit workers against memory that's actually backing warmed video pages. Usually fine on a 64–128 GB Mac Studio; riskier on the M1 MBP test runner.

Fix sketch `[needs-review]`: consider subtracting a fraction of `inactive`, or incorporate `compressor`/`purgeable` stats, or use `os_proc_available_memory`-style signals. Review — tuning, not a clear bug.

#### P2-4 — `ThrottledMainActorUpdate` drops the *last* update under a quiet tail. `[safe-additive]`

File: `MemoryPressure.swift:317`–`322`.

`update` runs the block only if `now - lastUpdate >= interval`, else silently drops. If the final progress/frame update of a video arrives within the throttle window, it's dropped and never re-fired — the live preview / `currentFile` / `bestDist` can be left one update stale at end-of-file. Minor UI staleness; `runScan`'s terminal MainActor.run fixes the headline fields, but `bestDist` updates via `distFn`→`progressState.update` can lag. Note `pfProcessVideo` does a final unthrottled `await distFn(bestDistEver)` at Detection:615 — but that goes through `progressState.update` too (processOneVideo:795), so it can still be throttled-dropped.

Fix sketch `[safe-additive]`: the final `distFn` call at end of `pfProcessVideo`/`pfProcessVideoWithArcFace` should bypass the throttle (call `MainActor.run` directly for the terminal best-distance). Low-risk; see SAFE-ADDITIVE list.

#### P2-5 — `ScanJob.scheduleConsoleFlush` timer leak window on rapid reset. `[safe-additive]`

File: `PersonFinderModel.swift:192`–`214`, `reset()` at `:216`.

`scheduleConsoleFlush` sets `consoleFlushScheduled = true` and spawns a detached `Task` that sleeps 200ms then flushes. `reset()` (line 216) sets `consoleFlushScheduled = false` and clears `pendingConsoleLines` but does **not** cancel the in-flight flush Task — the orphaned task wakes 200ms later, finds `pendingConsoleLines` empty (guard at line 208 returns early), harmless. But it has already flipped `consoleFlushScheduled = false` at line 207 before the guard, so a flush scheduled-then-reset-then-appended sequence could double-schedule. Edge-case, low severity.

Fix sketch `[safe-additive]`: hold the flush `Task` handle and cancel it in `reset()` / `stopElapsedTimer()`. Localized.

#### P2-6 — `arcfaceCosine` / `arcfaceEmbedding` use scalar loops where Accelerate (vDSP) would be safer and faster. `[needs-review]`

File: `ArcFaceEngine.swift:236`–`237`, `249`–`254`.

L2-normalize and dot-product are hand-rolled scalar loops over 512 floats, run per face per frame per reference. Not a correctness issue, but on a large scan with many references this is measurable CPU. Mentioned for the performance lever, not reliability.

Fix sketch `[needs-review]`: `vDSP_svesq` / `vDSP_dotpr` / `vDSP_vsmul`. Perf pass.

---

## RECOMMENDED SAFE-ADDITIVE FIXES

These are low-risk, localized, and do not change happy-path behavior. Listed in apply order. The Manager may apply these overnight; each is independently revertible.

1. **P2-1 — Name the SQLITE_TRANSIENT cast.**
   File: `PersonFinderCache.swift:409`–`414` (the `bind` helper).
   Change: add a file-scope `private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)` with a one-line comment ("SQLite's (sqlite3_destructor_type)-1 — copy the bound text") and reference it inside `bind` instead of the inline `unsafeBitCast`. Behavior-identical; pure readability/safety-of-future-edits.

2. **P1-3 — Drop the preview bitmap promptly after the MainActor hop.**
   File: `PersonFinderDetection.swift:583`–`585` and `ArcFaceEngine.swift:624`–`626`.
   Change: after `await frameFn(img, ...)`, add `previewImage = nil` so the full-res oriented `CGImage` isn't pinned across the next loop iteration / await. Minimal, behavior-preserving, reduces peak retained memory on high-res sources under N workers.

3. **P2-4 — Make the terminal best-distance update bypass the throttle.**
   File: `PersonFinderDetection.swift:615` and `ArcFaceEngine.swift:656` (the end-of-video `await distFn(...)`), in concert with the `distFn` definition at `PersonFinderModel+JobLifecycle.swift:795`.
   Change: ensure the *final* best-distance publish reaches MainActor unconditionally (e.g. add an unthrottled `force`-style update path, or call `MainActor.run { if dist < job.bestDist { job.bestDist = dist } }` directly for the terminal call). Fixes a stale `bestDist` on short tails. Keep the per-frame `distFn` throttled as-is. Scope this as additive: introduce an optional non-throttled call site for the terminal update only.

4. **P1-5 (ArcFace half) — Record ArcFace reference-photo Vision failures.**
   File: `ArcFaceEngine.swift:289`–`291` (`arcfaceLoadReferenceEmbeddings`, the `try? handler.perform([req])`).
   Change: capture the thrown error and `arcfaceLogger.warning(...)` / `appLog.write(...)` a "reference photo X: Vision detect failed" line before `continue`, mirroring the Vision loader's feedback. Pure observability — no change to which faces succeed. (Full parity with `ReferenceLoadFailure` is `[needs-review]` because the return tuple shape differs; the log line is the safe-additive subset.)

5. **P1-5 (per-frame half) — Rate-limited warn on feature-print failure.**
   File: `PersonFinderDetection.swift:142`–`147` (`pfGenerateFeaturePrint`).
   Change: capture the `perform` error and emit a debug/warn log on throw (rate-limited or first-occurrence-only to avoid hot-loop spam). No happy-path change; aids diagnosis of a systematic ANE failure.

6. **P0-1 (observability subset only) — Surface ArcFace MLE5 exception instability.**
   File: `ArcFaceEngine.swift:212`–`219` (the `arcfaceExceptionCount` increment block).
   Change: the per-exception `appLog.write`/`arcfaceLogger.error` already fires. Add a first-occurrence-only WARN with a stable, greppable marker (e.g. `"⚠️ ARCFACE_MLE5_INSTABILITY first occurrence — recognition may under-detect"`) so a degraded run is one grep away in `videoscan.log`. Do **not** touch the lock or the per-instance model strategy here — that is the `[needs-review]` part of P0-1. This subset is pure logging.

7. **P2-5 — Cancel the in-flight console flush task on reset.**
   File: `PersonFinderModel.swift:192`–`199` (`scheduleConsoleFlush`) and `:216` (`reset`).
   Change: store the flush `Task` in a property and cancel it in `reset()` (and optionally `stopElapsedTimer()`), closing the double-schedule edge window. Localized; the guard at line 208 already makes the orphaned task harmless, so this is hardening, not a bug fix.

Everything else (P0-1 lock/throughput rework, P0-2 single-flight embedding cache, P1-1/1-2 slot accounting, P1-4 stderr task fan-out, P1-6 MLMultiArray dtype guard, P1-7 uncapped restoreFromCache, P1-8 cache connection model, P2-2 driver dedup, P2-3 availableMemory tuning, P2-6 vDSP) is tagged `[needs-review]` or `[architectural]` and should NOT be applied unattended — bring to Rick.
