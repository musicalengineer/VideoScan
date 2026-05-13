// PersonFinderEngineDispatch.swift
// dlib (Python subprocess) bridge and ArcFace engine dispatcher extracted
// from PersonFinderModel.swift.
//
// Step 4 of 6 in the PersonFinderModel decomposition. Pure code movement
// from PersonFinderModel.swift — no logic changes. These free functions
// handle the per-video work for two of the four recognition engines;
// they are invoked from the `dispatchEngine()` switch inside
// `PersonFinderModel.processOneVideo`, which still lives in the model
// file and will move when `processOneVideo` itself relocates in step 6.

import Foundation
import CoreGraphics
import CoreML

// MARK: - dlib/Python video processing

private struct DlibSegmentJSON: Codable {
    let start: Double
    let end: Double
    let bestDist: Float
    let avgDist: Float
    let hitCount: Int
    enum CodingKeys: String, CodingKey {
        case start, end
        case bestDist = "best_dist"
        case avgDist  = "avg_dist"
        case hitCount = "hit_count"
    }
}

private struct DlibResultJSON: Codable {
    let video: String
    let duration: Double
    let fps: Double
    let error: String?
    let facesDetected: Int
    let hits: Int
    let bestDist: Float?
    let segments: [DlibSegmentJSON]
    enum CodingKeys: String, CodingKey {
        case video, duration, fps, error, segments, hits
        case facesDetected = "faces_detected"
        case bestDist      = "best_dist"
    }
}

private func pfDecodeDlibResult(from json: String) -> DlibResultJSON? {
    try? JSONDecoder().decode(DlibResultJSON.self, from: Data(json.utf8))
}

// MARK: - engine-dispatch internal — called only by PersonFinderModel.runDlib()
nonisolated func pfProcessVideoWithDlib(
    filePath: String,
    settings: PersonFinderSettings,
    index: Int,
    total: Int,
    pauseGate: PauseGate,
    logFn: @escaping @Sendable (String) async -> Void,
    progressFn: @escaping @Sendable (String) async -> Void,
    distFn: @escaping @Sendable (Float)  async -> Void
) async -> pfVideoResult? {
    // Check memory pressure before launching a heavyweight Python subprocess.
    // Once the subprocess is running it cannot be paused, so this is the
    // only effective gate for the dlib engine.
    await pauseGate.waitIfPaused()
    if Task.isCancelled { return nil }

    let filename = (filePath as NSString).lastPathComponent
    await progressFn(filename)
    await logFn("[\(index)/\(total)] \(filename)")
    await logFn("  dlib: python=\(settings.pythonPath)")
    await logFn("  dlib: script=\(settings.recognitionScript)")

    guard FileManager.default.isExecutableFile(atPath: settings.pythonPath) else {
        await logFn("  [\(index)/\(total)] \(filename) — Python executable not found or not executable")
        return nil
    }
    guard FileManager.default.fileExists(atPath: settings.recognitionScript) else {
        await logFn("  [\(index)/\(total)] \(filename) — recognition script not found")
        return nil
    }

    let stdout = await ProcessRunner.runStreaming(
        executable: settings.pythonPath,
        arguments: [
            settings.recognitionScript,
            "--ref-path", settings.referencePath,
            "--video", filePath,
            "--threshold", String(format: "%.4f", settings.threshold),
            "--frame-step", String(settings.frameStep),
            "--min-conf", String(format: "%.4f", settings.minFaceConfidence),
            "--pad", String(format: "%.2f", settings.pad),
            "--min-duration", String(format: "%.2f", settings.minDuration)
        ],
        environment: [
            "FACE_RECOG_MAX_RSS_MB": String(await MemoryPressureMonitor.shared.workerBudgetMB(for: .dlib))
        ],
        stderrLine: { line in Task { await logFn("  " + line) } }
    )

    await progressFn("")

    guard let jsonStr = stdout else {
        await logFn("  [\(index)/\(total)] \(filename) — failed to launch Python process")
        return nil
    }
    guard let result = pfDecodeDlibResult(from: jsonStr) else {
        let snippet = String(jsonStr.prefix(240)).replacingOccurrences(of: "\n", with: " ")
        await logFn("  [\(index)/\(total)] \(filename) — invalid JSON from Python script: \(snippet)")
        return nil
    }

    if let err = result.error {
        await logFn("  [\(index)/\(total)] \(filename) — error: \(err)")
        return pfVideoResult(filename: filename, filePath: filePath,
                             durationSeconds: result.duration, fps: result.fps,
                             totalHits: 0, segments: [])
    }

    if let bd = result.bestDist { await distFn(bd) }

    let segs = result.segments.map { s in
        pfSegment(startSecs: s.start, endSecs: s.end,
                  bestDistance: s.bestDist, avgDistance: s.avgDist)
    }
    let presence: Double = segs.map { $0.endSecs - $0.startSecs }.reduce(0, +)
    let bdStr     = result.bestDist.map { String(format: "%.3f", $0) } ?? "—"
    await logFn("  [\(index)/\(total)] \(filename) → \(result.hits) hits, \(segs.count) seg(s), \(pfFormatDuration(presence)) presence  (faces: \(result.facesDetected), best dist: \(bdStr))")

    return pfVideoResult(filename: filename, filePath: filePath,
                         durationSeconds: result.duration, fps: result.fps,
                         totalHits: result.hits, segments: segs)
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
    distFn: @Sendable @escaping (Float) async -> Void
) async -> pfVideoResult? {
    let (mlModel, err) = await ArcFaceModelLoader.shared.getModel()
    guard let mlModel else {
        await logFn("[arcface] Model load failed: \(err ?? "unknown")")
        return nil
    }

    // Reference embeddings: compute ONCE per job, then reuse for every
    // subsequent video. Previously this ran for every video, which:
    //  - wasted N-references × predictions of work per video
    //  - multiplied concurrent MLE5 inference load enough to trip
    //    MLE5BindEmptyMemoryObjectToPort under multi-job scans even
    //    with per-call MLModel instances (crash 2026-05-12 19:16).
    //
    // Race note: if multiple videos in this job arrive at the cache
    // miss at the same time, they each compute a copy. That's fine —
    // each uses its own MLModel, the work is bounded to one job's
    // worth, and the last writer wins on the cache field. No
    // correctness issue, just minor wasted work the first scan.
    let cached = await MainActor.run { job.assignedArcFaceEmbeddings }
    let refEmbeddings: [[Float]]
    if !cached.isEmpty {
        refEmbeddings = cached
    } else {
        let (computed, refErr) = arcfaceLoadReferenceEmbeddings(
            from: settings.referencePath,
            largestFaceOnly: settings.largestFaceOnly,
            model: mlModel
        )
        if let refErr {
            await logFn("[arcface] Reference loading failed: \(refErr)")
            return nil
        }
        refEmbeddings = computed
        await MainActor.run { job.assignedArcFaceEmbeddings = computed }
        await logFn("[arcface] Cached \(computed.count) reference embedding(s) for this job")
    }
    return await pfProcessVideoWithArcFace(
        filePath: filePath, referenceEmbeddings: refEmbeddings,
        settings: settings, model: mlModel,
        index: idx1, total: total,
        pauseGate: job.pauseGate,
        logFn: logFn, progressFn: progressFn,
        frameFn: { img, matched, unmatched in
            await progressState.update {
                job.liveFrame = img
                job.liveMatchedRects = matched
                job.liveUnmatchedRects = unmatched
            }
        },
        distFn: distFn,
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
