// PersonFinderEngineDispatch.swift
// CoreML engine dispatchers (ArcFace, AdaFace) extracted from
// PersonFinderModel.swift.
//
// Originally step 4 of 6 in the PersonFinderModel decomposition; the
// dlib/Python subprocess bridge that used to live here was removed with
// the dlib Search seat (GH #144 — AdaFace replaced it). These free
// functions handle the per-video work for the two CoreML embedding
// engines; they are invoked from the `switch settings.recognitionEngine`
// inside `PersonFinderModel.processOneVideo`.

import Foundation
import CoreGraphics
import CoreML

// MARK: - Shared reference-embedding job cache
//
// Reference embeddings are computed ONCE per job, then reused for every
// subsequent video. Historically this ran per video, which wasted
// N-references × predictions of work AND multiplied concurrent MLE5
// inference load enough to trip MLE5BindEmptyMemoryObjectToPort under
// multi-job scans even with per-call MLModel instances (crash 2026-05-12).
//
// The cache is keyed by FaceEmbeddingBackend token — AdaFace and ArcFace
// vectors are both 512-d but NOT comparable, so a job that is re-run with
// a different engine must never reuse the other backend's vectors.
//
// Race note: if multiple videos in one job hit the cache miss at the same
// time, they each compute a copy. That's fine — each uses its own MLModel,
// the work is bounded to one job's worth, and the last writer wins. No
// correctness issue, just minor wasted work on the first scan.
private func pfCachedReferenceEmbeddings(
    job: ScanJob,
    backendKey: String,
    logFn: @Sendable @escaping (String) async -> Void,
    logTag: String,
    compute: () -> ([[Float]], String?)
) async -> [[Float]]? {
    let cached = await MainActor.run { job.assignedRefEmbeddings[backendKey] ?? [] }
    if !cached.isEmpty { return cached }

    let (computed, refErr) = compute()
    if let refErr {
        await logFn("[\(logTag)] Reference loading failed: \(refErr)")
        return nil
    }
    await MainActor.run { job.assignedRefEmbeddings[backendKey] = computed }
    await logFn("[\(logTag)] Cached \(computed.count) reference embedding(s) for this job")
    return computed
}

// MARK: - ArcFace engine dispatch

/// ArcFace engine dispatch — loads the CoreML model + reference embeddings,
/// then delegates to `pfProcessVideoWithArcFace`. File-scope so the class
/// body stays small; all dependencies are passed explicitly.
// swiftlint:disable:next function_parameter_count
func pfRunArcFaceEngine(
    filePath: String,
    idx1: Int,
    total: Int,
    settings: PersonFinderSettings,
    job: ScanJob,
    dash: DashboardState?,
    progressState: ThrottledMainActorUpdate,
    logFn: @Sendable @escaping (String) async -> Void,
    progressFn: @Sendable @escaping (String) async -> Void,
    distFn: @Sendable @escaping (Float) async -> Void,
    distFnFinal: (@Sendable (Float) async -> Void)? = nil
) async -> pfVideoResult? {
    // Pre-start cancel guard (GH #142 class, codex adversarial #42): a job
    // cancelled before this arm runs must do NO engine work — no model
    // resolution, no log lines. The shared processOneVideo guard covers the
    // production path; this covers the arm itself (and hybrid's fallback
    // hop, which reaches the AdaFace arm below after the Vision pass).
    if Task.isCancelled { return nil }
    let (mlModel, err) = await ArcFaceModelLoader.shared.getModel()
    guard let mlModel else {
        await logFn("[arcface] Model load failed: \(err ?? "unknown")")
        return nil
    }

    // Shape the shared ArcFace inference pool for this job (idempotent, cheap
    // after the first video). Default K=1 keeps the serialized global-lock path;
    // K>1 is the experimental concurrent-inference prototype (P0-1).
    await ArcFacePredictor.shared.configure(concurrency: settings.arcfaceInferenceConcurrency)
    if settings.arcfaceInferenceConcurrency > 1 {
        await logFn("[arcface] EXPERIMENTAL concurrent inference pool K=\(ArcFacePredictor.shared.concurrency) (default is serialized K=1)")
    }

    guard let refEmbeddings = await pfCachedReferenceEmbeddings(
        job: job, backendKey: FaceEmbeddingBackend.arcface,
        logFn: logFn, logTag: "arcface",
        compute: {
            arcfaceLoadReferenceEmbeddings(
                from: settings.referencePath,
                largestFaceOnly: settings.largestFaceOnly,
                useLandmarkAlignment: settings.arcfaceLandmarkAlignment,
                model: mlModel
            )
        }
    ) else { return nil }

    return await pfProcessVideoWithArcFace(
        filePath: filePath, referenceEmbeddings: refEmbeddings,
        settings: settings, model: mlModel,
        index: idx1, total: total,
        pauseGate: job.pauseGate,
        logFn: logFn, progressFn: progressFn,
        frameFn: { img, matched, unmatched in
            await progressState.update {
                job.livePreview = ScanJob.LivePreview(frame: img, matched: matched, unmatched: unmatched)
            }
        },
        distFn: distFn,
        distFnFinal: distFnFinal,
        visionStatsFn: { fps, msPerFrame in
            let workers = await MemoryPressureMonitor.shared.currentWorkers()
            await MainActor.run {
                dash?.visionFPS = fps
                dash?.visionMsPerFrame = msPerFrame
                dash?.visionWorkers = workers
            }
        },
        previewRateFn: { job.previewRate }
    )
}

// MARK: - AdaFace engine dispatch (GH #144)

/// AdaFace engine dispatch — same shape as `pfRunArcFaceEngine`. The video
/// pipeline is shared; the differences are all explicit at this call site:
///  - `AdaFaceModelLoader` (fresh per-worker MLModel instances)
///  - reference embeddings cached under the AdaFace backend key
///  - AdaFace's own cosine threshold (`settings.adafaceThreshold`)
///  - `useSharedPool: false` — never borrow from the ArcFace K>1 pool;
///    all AdaFace predictions serialize under the global prediction lock
///    with the caller's own model (the proven-safe MLE5 configuration).
// swiftlint:disable:next function_parameter_count
func pfRunAdaFaceEngine(
    filePath: String,
    idx1: Int,
    total: Int,
    settings: PersonFinderSettings,
    job: ScanJob,
    dash: DashboardState?,
    progressState: ThrottledMainActorUpdate,
    logFn: @Sendable @escaping (String) async -> Void,
    progressFn: @Sendable @escaping (String) async -> Void,
    distFn: @Sendable @escaping (Float) async -> Void,
    distFnFinal: (@Sendable (Float) async -> Void)? = nil
) async -> pfVideoResult? {
    // Pre-start cancel guard — same contract as the ArcFace arm above.
    if Task.isCancelled { return nil }
    let (mlModel, err) = await AdaFaceModelLoader.shared.getModel()
    guard let mlModel else {
        await logFn("[adaface] Model load failed: \(err ?? "unknown")")
        return nil
    }

    guard let refEmbeddings = await pfCachedReferenceEmbeddings(
        job: job, backendKey: FaceEmbeddingBackend.adaface,
        logFn: logFn, logTag: "adaface",
        compute: {
            arcfaceLoadReferenceEmbeddings(
                from: settings.referencePath,
                largestFaceOnly: settings.largestFaceOnly,
                useLandmarkAlignment: settings.arcfaceLandmarkAlignment,
                model: mlModel,
                useSharedPool: false
            )
        }
    ) else { return nil }

    return await pfProcessVideoWithArcFace(
        filePath: filePath, referenceEmbeddings: refEmbeddings,
        settings: settings, model: mlModel,
        index: idx1, total: total,
        pauseGate: job.pauseGate,
        logFn: logFn, progressFn: progressFn,
        frameFn: { img, matched, unmatched in
            await progressState.update {
                job.livePreview = ScanJob.LivePreview(frame: img, matched: matched, unmatched: unmatched)
            }
        },
        distFn: distFn,
        distFnFinal: distFnFinal,
        visionStatsFn: { fps, msPerFrame in
            let workers = await MemoryPressureMonitor.shared.currentWorkers()
            await MainActor.run {
                dash?.visionFPS = fps
                dash?.visionMsPerFrame = msPerFrame
                dash?.visionWorkers = workers
            }
        },
        previewRateFn: { job.previewRate },
        engineTag: "AdaFace",
        cosineThresholdOverride: settings.adafaceThreshold,
        useSharedPool: false
    )
}
