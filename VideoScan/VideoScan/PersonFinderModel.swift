// PersonFinderModel.swift
// Drives multi-volume person-finding scans inside the VideoScan app.
// Each ScanJob represents one search target (volume or folder).

import Foundation
import AVFoundation
import Vision
import CoreImage
import CoreGraphics
import SwiftUI
import Combine

// MARK: - Settings

// MARK: - Recognition Engine Registry
//
// To add a new engine:
//   1. Add a case below.
//   2. Add a matching case in the `switch settings.recognitionEngine` block
//      inside `processOne(idx:)` further down in this file.
//   3. (Optional) Add per-engine memory/concurrency tuning to MemoryPressureMonitor.
//
// Each engine implements the same async contract:
//   (filePath, settings, callbacks) -> pfVideoResult?
// so the dispatcher and the rest of the pipeline (clipping, compilation,
// dashboards) stay engine-agnostic.

enum RecognitionEngine: String, CaseIterable, Identifiable {
    case vision = "Vision (fast)"
    case dlib   = "dlib/Python (accurate)"
    case hybrid = "Hybrid (Vision + dlib fallback)"
    var id: String { rawValue }

    /// Short label for compact UI / chip overlays.
    var shortLabel: String {
        switch self {
        case .vision: return "Vision"
        case .dlib:   return "dlib"
        case .hybrid: return "Hybrid"
        }
    }
}

struct PersonFinderSettings: Equatable {
    var personName: String = "Donna"
    var referencePath: String = ""
    var outputDir: String = ""          // empty → Desktop/<name>_clips
    var threshold: Float = 0.52
    var minFaceConfidence: Float = 0.55
    var frameStep: Int = 5
    var pad: Double = 2.0
    var minDuration: Double = 1.0
    var minPresenceSecs: Double = 5.0
    var requirePrimary: Bool = false
    var concurrency: Int = 8
    var concatOutput: Bool = true
    var decadeChapters: Bool = false    // sort by decade with chapter markers
    var skipBundles: Bool = true        // skip .fcpbundle, .imovielibrary, etc.
    var largestFaceOnly: Bool = false   // use only the largest detected face per reference photo
    var previewRate: Int = 5            // show preview every N sampled frames (1 = every frame)

    // dlib/Python engine
    var recognitionEngine: RecognitionEngine = .vision
    var pythonPath: String = Self.defaultPythonPath
    var recognitionScript: String = Self.defaultScriptPath

    /// Auto-detect Python venv and script from project layout.
    private static var defaultPythonPath: String {
        // Look for venv relative to the app bundle's ancestor dev directory
        let candidates = [
            NSHomeDirectory() + "/dev/VideoScan/venv/bin/python3",
            "/opt/homebrew/bin/python3",
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) } ?? ""
    }

    private static var defaultScriptPath: String {
        let candidates = [
            NSHomeDirectory() + "/dev/VideoScan/scripts/face_recognize.py",
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) } ?? ""
    }

    var dlibReady: Bool {
        recognitionEngine == .dlib && !pythonPath.isEmpty && !recognitionScript.isEmpty
    }

    /// True when dlib is invokable, regardless of which engine is currently selected.
    /// Used by `.hybrid` to decide whether the dlib fallback pass can run.
    var dlibReadyForHybrid: Bool {
        !pythonPath.isEmpty && !recognitionScript.isEmpty
    }

    // MARK: - Persistence

    private static let defaults = UserDefaults.standard
    private static let prefix = "pf_"

    private static func firstExistingPath(_ candidates: [String]) -> String {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? ""
    }

    private static func firstExistingFile(_ candidates: [String]) -> String {
        candidates.first { FileManager.default.fileExists(atPath: $0) } ?? ""
    }

    private static func detectedPythonPath() -> String {
        let cwd = FileManager.default.currentDirectoryPath
        return firstExistingPath([
            (cwd as NSString).appendingPathComponent(".venv/bin/python"),
            (cwd as NSString).appendingPathComponent("venv/bin/python"),
            "/usr/bin/python3",
        ])
    }

    private static func detectedRecognitionScript() -> String {
        let cwd = FileManager.default.currentDirectoryPath
        return firstExistingFile([
            (cwd as NSString).appendingPathComponent("scripts/face_recognize.py"),
        ])
    }

    /// Restore settings from UserDefaults. Missing keys use struct defaults.
    static func restored() -> PersonFinderSettings {
        let d = defaults
        let p = prefix
        var s = PersonFinderSettings()
        if let v = d.string(forKey: "\(p)personName")        { s.personName = v }
        if let v = d.string(forKey: "\(p)referencePath")     { s.referencePath = v }
        if let v = d.string(forKey: "\(p)outputDir")         { s.outputDir = v }
        if let v = d.string(forKey: "\(p)pythonPath")        { s.pythonPath = v }
        if let v = d.string(forKey: "\(p)recognitionScript") { s.recognitionScript = v }
        if let v = d.string(forKey: "\(p)recognitionEngine") {
            s.recognitionEngine = RecognitionEngine(rawValue: v) ?? .vision
        }
        if d.object(forKey: "\(p)threshold") != nil        { s.threshold = d.float(forKey: "\(p)threshold") }
        if d.object(forKey: "\(p)minFaceConfidence") != nil { s.minFaceConfidence = d.float(forKey: "\(p)minFaceConfidence") }
        if d.object(forKey: "\(p)frameStep") != nil         { s.frameStep = d.integer(forKey: "\(p)frameStep") }
        if d.object(forKey: "\(p)pad") != nil               { s.pad = d.double(forKey: "\(p)pad") }
        if d.object(forKey: "\(p)minDuration") != nil       { s.minDuration = d.double(forKey: "\(p)minDuration") }
        if d.object(forKey: "\(p)minPresenceSecs") != nil   { s.minPresenceSecs = d.double(forKey: "\(p)minPresenceSecs") }
        if d.object(forKey: "\(p)concurrency") != nil       { s.concurrency = d.integer(forKey: "\(p)concurrency") }
        if d.object(forKey: "\(p)requirePrimary") != nil    { s.requirePrimary = d.bool(forKey: "\(p)requirePrimary") }
        if d.object(forKey: "\(p)concatOutput") != nil      { s.concatOutput = d.bool(forKey: "\(p)concatOutput") }
        if d.object(forKey: "\(p)decadeChapters") != nil    { s.decadeChapters = d.bool(forKey: "\(p)decadeChapters") }
        if d.object(forKey: "\(p)skipBundles") != nil       { s.skipBundles = d.bool(forKey: "\(p)skipBundles") }
        if d.object(forKey: "\(p)largestFaceOnly") != nil   { s.largestFaceOnly = d.bool(forKey: "\(p)largestFaceOnly") }
        if d.object(forKey: "\(p)previewRate") != nil      { s.previewRate = max(1, d.integer(forKey: "\(p)previewRate")) }
        if s.pythonPath.isEmpty || !FileManager.default.isExecutableFile(atPath: s.pythonPath) {
            s.pythonPath = detectedPythonPath()
        }
        if s.recognitionScript.isEmpty || !FileManager.default.fileExists(atPath: s.recognitionScript) {
            s.recognitionScript = detectedRecognitionScript()
        }
        return s
    }

    /// Save all settings to UserDefaults.
    func save() {
        let d = Self.defaults
        let p = Self.prefix
        d.set(personName,                     forKey: "\(p)personName")
        d.set(referencePath,                  forKey: "\(p)referencePath")
        d.set(outputDir,                      forKey: "\(p)outputDir")
        d.set(pythonPath,                     forKey: "\(p)pythonPath")
        d.set(recognitionScript,              forKey: "\(p)recognitionScript")
        d.set(recognitionEngine.rawValue,     forKey: "\(p)recognitionEngine")
        d.set(threshold,                      forKey: "\(p)threshold")
        d.set(minFaceConfidence,              forKey: "\(p)minFaceConfidence")
        d.set(frameStep,                      forKey: "\(p)frameStep")
        d.set(pad,                            forKey: "\(p)pad")
        d.set(minDuration,                    forKey: "\(p)minDuration")
        d.set(minPresenceSecs,                forKey: "\(p)minPresenceSecs")
        d.set(concurrency,                    forKey: "\(p)concurrency")
        d.set(requirePrimary,                 forKey: "\(p)requirePrimary")
        d.set(concatOutput,                   forKey: "\(p)concatOutput")
        d.set(decadeChapters,                 forKey: "\(p)decadeChapters")
        d.set(skipBundles,                    forKey: "\(p)skipBundles")
        d.set(largestFaceOnly,                forKey: "\(p)largestFaceOnly")
        d.set(previewRate,                    forKey: "\(p)previewRate")
    }
}

// MARK: - Job Status

enum ScanJobStatus: Equatable {
    case idle, loading, scanning, paused, extracting, done, cancelled
    case failed(String)

    var label: String {
        switch self {
        case .idle:       return "Idle"
        case .loading:    return "Loading reference…"
        case .scanning:   return "Scanning…"
        case .paused:     return "Paused"
        case .extracting: return "Extracting clips…"
        case .done:       return "Done"
        case .cancelled:  return "Cancelled"
        case .failed(let msg): return "Error: \(msg)"
        }
    }

    var isActive: Bool {
        switch self { case .loading, .scanning, .paused, .extracting: return true; default: return false }
    }
    var isIdle: Bool { self == .idle }
    var isDone: Bool { if case .done = self { return true }; return false }
    var isPaused: Bool { self == .paused }
}

// MARK: - Reference Face

struct ReferenceFace: Identifiable {
    let id = UUID()
    let featurePrint: VNFeaturePrintObservation
    let thumbnail: CGImage              // 256×256 normalized crop
    let sourceFilename: String
    let confidence: Float
    let rollDeg: Double                 // head tilt in degrees
    let yawDeg: Double                  // left/right turn
    let pitchDeg: Double                // up/down tilt
    let faceAreaPct: Float              // face bbox as % of source image area

    enum Quality { case good, fair, poor }

    var quality: Quality {
        if confidence >= 0.80 && abs(yawDeg) < 30 && abs(rollDeg) < 25 { return .good }
        if confidence >= 0.60 { return .fair }   // confidence is the primary gate; angle is a bonus
        return .poor
    }
}

// MARK: - Clip Result (shown in results table)

struct ClipResult: Identifiable {
    let id = UUID()
    let videoFilename: String
    let videoPath: String
    let videoDuration: Double
    let presenceSecs: Double
    let segmentCount: Int
    let bestDistance: Float
    var clipFiles: [String]
    let outputDir: String
}

// MARK: - Compiled Output (one per bucket — see docs/compilation-bucketing.md)

struct CompiledOutput: Identifiable, Equatable, Hashable {
    let id = UUID()
    let path: String          // absolute path to the .mp4/.mov on disk
    let label: String         // shortLabel from CompatKey, e.g. "h264_1080p2997_aac48k_2ch"
    let clipCount: Int
    let durationSecs: Double
    let bytesOnDisk: Int64

    static func == (lhs: CompiledOutput, rhs: CompiledOutput) -> Bool {
        lhs.id == rhs.id
    }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Scan Job

@MainActor
final class ScanJob: ObservableObject, Identifiable {
    let id = UUID()
    @Published var searchPath: String

    @Published var status: ScanJobStatus = .idle
    @Published var progress: Double = 0.0
    @Published var currentFile: String = ""
    @Published var videosTotal: Int = 0
    @Published var videosScanned: Int = 0
    @Published var videosWithHits: Int = 0
    @Published var clipsFound: Int = 0
    @Published var presenceSecs: Double = 0.0
    @Published var results: [ClipResult] = []
    @Published var consoleLines: [String] = []
    @Published var compiledVideoPaths: [CompiledOutput] = []
    @Published var elapsedSecs: Double = 0.0

    // Live frame preview
    @Published var liveFrame: CGImage? = nil
    @Published var liveMatchedRects: [CGRect] = []     // Vision normalized coords, bottom-left origin
    @Published var liveUnmatchedRects: [CGRect] = []

    // Best feature-print distance seen across all videos (lower = closer match)
    @Published var bestDist: Float = .greatestFiniteMagnitude

    /// Display rate for live preview — adjustable in realtime from UI.
    /// Read by the scan loop each frame; not part of the snapshot settings.
    /// nonisolated(unsafe): Int reads are atomic on ARM64; written from MainActor, read from scan loop.
    nonisolated(unsafe) var previewRate: Int = 5

    fileprivate var scanTask: Task<Void, Never>?
    fileprivate var timerTask: Task<Void, Never>?
    fileprivate var taskStarted: Date?

    /// Cooperative pause gate — tasks check this between videos
    let pauseGate = PauseGate()

    /// Persistent log file for this scan job — crash-safe, immediate writes.
    nonisolated(unsafe) var persistentLog: PersistentLog?

    init(searchPath: String) { self.searchPath = searchPath }

    func appendLog(_ line: String) {
        persistentLog?.write(line)
        consoleLines.append(line)
        if consoleLines.count > 2000 { consoleLines.removeFirst(consoleLines.count - 2000) }
    }

    func reset() {
        scanTask?.cancel(); timerTask?.cancel()
        Task { await pauseGate.resume() }  // release any waiters
        status = .idle; progress = 0; currentFile = ""
        videosTotal = 0; videosScanned = 0; videosWithHits = 0
        clipsFound = 0; presenceSecs = 0
        results = []; consoleLines = []
        compiledVideoPaths = []; elapsedSecs = 0
        liveFrame = nil; liveMatchedRects = []; liveUnmatchedRects = []
        bestDist = .greatestFiniteMagnitude
        scanTask = nil; timerTask = nil; taskStarted = nil
    }

    fileprivate func startElapsedTimer() {
        taskStarted = Date()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                await MainActor.run { [weak self] in
                    guard let self, let s = self.taskStarted else { return }
                    self.elapsedSecs = Date().timeIntervalSince(s)
                }
            }
        }
    }

    fileprivate func stopElapsedTimer() {
        timerTask?.cancel()
        if let s = taskStarted { elapsedSecs = Date().timeIntervalSince(s) }
    }
}

// MARK: - Person Finder Model

@MainActor
final class PersonFinderModel: ObservableObject {
    @Published var jobs: [ScanJob] = []
    @Published var settings = PersonFinderSettings.restored() {
        didSet { settings.save() }
    }
    /// Optional reference to DashboardState for publishing Vision/ANE metrics.
    weak var dashboard: DashboardState?

    /// Binding wrapper that auto-saves settings on every write.
    /// Use `model.settingsBinding.threshold` etc. in SwiftUI controls.
    /// @Observable kills didSet, so we explicitly save here.
    var settingsBinding: Binding<PersonFinderSettings> {
        Binding(
            get: { self.settings },
            set: { self.settings = $0; $0.save() }
        )
    }
    var referenceFaces: [ReferenceFace] = []
    var referenceSources: [String] = []     // display labels for each loaded source folder/file
    var referenceLoadError: String? = nil
    var isLoadingReference: Bool = false

    var referenceFeaturePrints: [VNFeaturePrintObservation] { referenceFaces.map(\.featurePrint) }
    var referencePhotoCount: Int { referenceFaces.count }

    init() {
        let floorGB = ScanPerformanceSettings.restored().memoryFloorGB
        Task { await MemoryPressureMonitor.shared.setFloorGB(floorGB) }
    }

    // MARK: Job management

    func addJob(path: String = "") {
        jobs.append(ScanJob(searchPath: path))
    }

    func removeJob(_ job: ScanJob) {
        job.scanTask?.cancel()
        job.timerTask?.cancel()
        jobs.removeAll { $0.id == job.id }
    }

    func startJob(_ job: ScanJob) {
        guard !job.status.isActive else { return }

        // Ensure settings are saved before we snapshot them for the scan
        settings.save()
        let settings = self.settings

        job.appendLog("Engine: \(settings.recognitionEngine.rawValue)")
        if settings.recognitionEngine == .dlib {
            job.appendLog("  Python: \(settings.pythonPath.isEmpty ? "(empty)" : settings.pythonPath)")
            job.appendLog("  Script: \(settings.recognitionScript.isEmpty ? "(empty)" : settings.recognitionScript)")
            job.appendLog("  Ref path: \(settings.referencePath.isEmpty ? "(empty)" : settings.referencePath)")
            guard settings.dlibReady else {
                job.appendLog("⚠ Set Python path and script path in Settings before scanning with dlib.")
                return
            }
            guard !settings.referencePath.isEmpty else {
                job.appendLog("⚠ Set reference photos path first.")
                return
            }
        } else {
            job.appendLog("  References loaded: \(referenceFaces.count)")
            guard !referenceFaces.isEmpty else {
                job.appendLog("⚠ Load reference photos first.")
                return
            }
        }

        job.reset()
        job.status = .scanning
        job.previewRate = settings.previewRate
        let log = PersistentLog(name: "facedetect")
        log.start()
        job.persistentLog = log
        job.startElapsedTimer()

        let prints = settings.recognitionEngine == .vision ? referenceFeaturePrints : []
        let dash = self.dashboard
        job.scanTask = Task { [weak job] in
            guard let job else { return }
            await MainActor.run { dash?.visionActive = settings.recognitionEngine == .vision }
            await PersonFinderModel.runScan(job: job, prints: prints, settings: settings, dashboard: dash)
            await MainActor.run { dash?.visionActive = false; dash?.visionFPS = 0; dash?.visionMsPerFrame = 0 }
            log.close()
        }
    }

    func stopJob(_ job: ScanJob) {
        job.scanTask?.cancel()
        job.stopElapsedTimer()
        if job.status.isActive { job.status = .cancelled }
    }

    func pauseJob(_ job: ScanJob) {
        guard job.status == .scanning else { return }
        Task { await job.pauseGate.pause() }
        job.status = .paused
    }

    func resumeJob(_ job: ScanJob) {
        guard job.status == .paused else { return }
        Task { await job.pauseGate.resume() }
        job.status = .scanning
    }

    func togglePauseJob(_ job: ScanJob) {
        if job.status == .paused {
            resumeJob(job)
        } else if job.status == .scanning {
            pauseJob(job)
        } else {
            job.appendLog("[pause] Ignored — current status is \(job.status.label) (only Scanning/Paused can toggle)")
        }
    }

    func startAll() {
        for job in jobs where job.status.isIdle { startJob(job) }
    }

    func stopAll() { for job in jobs { stopJob(job) } }

    func pauseAll() {
        for job in jobs where job.status == .scanning { pauseJob(job) }
    }

    func resumeAll() {
        for job in jobs where job.status == .paused { resumeJob(job) }
    }

    var hasActiveJobs: Bool { jobs.contains { $0.status == .scanning } }
    var hasPausedJobs: Bool { jobs.contains { $0.status == .paused } }

    // MARK: Reference loading

    /// Append reference photos from `path` to the existing pool (does not clear previous loads).
    func loadReference(from path: String? = nil) async {
        let p = path ?? settings.referencePath
        guard !p.isEmpty else { referenceLoadError = "No reference path set."; return }

        isLoadingReference = true
        referenceLoadError = nil

        let largestOnly = settings.largestFaceOnly
        let (faces, errMsg) = await Task.detached(priority: .userInitiated) {
            pfLoadReferencePhotos(from: p, largestFaceOnly: largestOnly)
        }.value

        if let err = errMsg {
            referenceLoadError = err
        } else {
            referenceFaces.append(contentsOf: faces)
            let label = (p as NSString).lastPathComponent
            if !referenceSources.contains(label) { referenceSources.append(label) }
        }
        isLoadingReference = false
    }

    func removeReferenceFace(id: UUID) {
        referenceFaces.removeAll { $0.id == id }
        if referenceFaces.isEmpty { referenceSources = [] }
    }

    func removeReferenceFaces(belowConfidence threshold: Float) {
        referenceFaces.removeAll { $0.confidence < threshold }
        if referenceFaces.isEmpty { referenceSources = [] }
    }

    func clearReference() {
        referenceFaces = []
        referenceSources = []
        referenceLoadError = nil
        settings.referencePath = ""
    }

    // MARK: Core scan (nonisolated — runs on cooperative thread pool, NOT on MainActor)

    private nonisolated static func runScan(
        job: ScanJob,
        prints: [VNFeaturePrintObservation],
        settings: PersonFinderSettings,
        dashboard: DashboardState?
    ) async {
        let path = await job.searchPath
        await job.appendLog("Scanning: \(path)")

        // Find video files — use Task.detached so blocking FileManager calls
        // don't stall the cooperative thread pool (critical for network volumes)
        let skipBundles = settings.skipBundles
        let videoFiles = await Task.detached(priority: .userInitiated) {
            pfFindVideoFiles(at: path, skipBundles: skipBundles)
        }.value
        guard !videoFiles.isEmpty else {
            await job.appendLog("No video files found.")
            await MainActor.run { job.status = .failed("No videos found") }
            return
        }

        await MainActor.run {
            job.videosTotal = videoFiles.count
            job.appendLog("Found \(videoFiles.count) video(s)\n")
        }

        if Task.isCancelled { await MainActor.run { job.status = .cancelled }; return }

        // Process concurrently — bounded task group
        let total = videoFiles.count
        var orderedResults = [pfVideoResult?](repeating: nil, count: total)
        let dash = dashboard

        // Closure that dispatches to the right engine — keeps the task group logic identical
        // regardless of which recognition backend is active.
        @Sendable func processOne(idx: Int) async -> (Int, pfVideoResult?) {
            // Pause gate: wait here if user (or memory pressure) paused this job
            await job.pauseGate.waitIfPaused()
            if Task.isCancelled { return (idx, nil) }

            // Reserve a worker slot atomically so multiple jobs cannot overbook
            // the same memory budget based on a stale snapshot.
            await MemoryPressureMonitor.shared.acquireWorkerSlot(
                requested: settings.concurrency,
                engine: settings.recognitionEngine
            )
            defer { Task { await MemoryPressureMonitor.shared.decrementWorkers() } }

            let logFn:      @Sendable (String) async -> Void = { line in await job.appendLog(line) }

            // Throttle MainActor dispatches to avoid beachball under high concurrency.
            // Progress, frame preview, and distance updates are coalesced to ~4 Hz.
            let progressState = ThrottledMainActorUpdate(intervalSecs: 0.25)
            let progressFn: @Sendable (String) async -> Void = { file in
                await progressState.update { job.currentFile = file }
            }
            let distFn:     @Sendable (Float)  async -> Void = { dist in
                await progressState.update { if dist < job.bestDist { job.bestDist = dist } }
            }

            // Vision branch — used by .vision and as the first pass of .hybrid.
            @Sendable func runVision() async -> pfVideoResult? {
                await pfProcessVideo(
                    filePath: videoFiles[idx], prints: prints,
                    settings: settings, index: idx + 1, total: total,
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

            // dlib branch — used by .dlib and as the fallback pass of .hybrid.
            @Sendable func runDlib() async -> pfVideoResult? {
                await pfProcessVideoWithDlib(
                    filePath: videoFiles[idx], settings: settings,
                    index: idx + 1, total: total,
                    pauseGate: job.pauseGate,
                    logFn: logFn, progressFn: progressFn, distFn: distFn
                )
            }

            let r: pfVideoResult?
            switch settings.recognitionEngine {
            case .vision:
                r = await runVision()
            case .dlib:
                r = await runDlib()
            case .hybrid:
                // Pass 1: fast Vision sweep on the ANE.
                let v = await runVision()
                if let v, !v.segments.isEmpty {
                    r = v
                } else {
                    // Pass 2: dlib as a "second look" — catches profile / glasses
                    // / dim-light cases Vision tends to miss. Only runs when Vision
                    // came up empty, so the common-case path stays fast.
                    if !settings.dlibReadyForHybrid {
                        await job.appendLog("[hybrid] Vision: 0 hits — dlib not configured, skipping fallback")
                        r = v
                    } else {
                        await job.appendLog("[hybrid] Vision: 0 hits — falling back to dlib")
                        r = await runDlib()
                    }
                }
            }
            return (idx, r)
        }

        await withTaskGroup(of: (Int, pfVideoResult?).self) { group in
            var submitted = 0
            let scanConcurrency = await MemoryPressureMonitor.shared.recommendedConcurrency(
                requested: settings.concurrency,
                engine: settings.recognitionEngine
            )
            if scanConcurrency != settings.concurrency {
                let available = MemoryPressureMonitor.shared.availableMemoryString()
                await job.appendLog(
                    "Memory guard: using \(scanConcurrency)/\(settings.concurrency) parallel scan(s) for \(settings.recognitionEngine.rawValue) with \(available) free."
                )
            }
            let seed = min(scanConcurrency, total)
            for i in 0..<seed {
                group.addTask { await processOne(idx: i) }
                submitted += 1
            }

            for await (idx, result) in group {
                if Task.isCancelled { break }
                orderedResults[idx] = result
                await MainActor.run {
                    job.videosScanned += 1
                    job.progress = Double(job.videosScanned) / Double(job.videosTotal)
                    if let r = result, !r.segments.isEmpty {
                        job.videosWithHits += 1
                        dash?.lastMatchFlashAt = Date()
                    }
                }
                if submitted < total {
                    let nextIdx = submitted
                    group.addTask { await processOne(idx: nextIdx) }
                    submitted += 1
                }
            }
        }

        if Task.isCancelled { await MainActor.run { job.status = .cancelled; job.stopElapsedTimer() }; return }

        // Presence filter
        let validResults = orderedResults.compactMap { $0 }.filter {
            settings.minPresenceSecs <= 0 || $0.totalPresenceSecs >= settings.minPresenceSecs
        }
        let skipped = orderedResults.compactMap { $0 }.filter {
            settings.minPresenceSecs > 0 && $0.totalPresenceSecs < settings.minPresenceSecs && !$0.segments.isEmpty
        }.count

        if skipped > 0 {
            await job.appendLog("\nPresence filter: \(validResults.count) kept, \(skipped) below \(Int(settings.minPresenceSecs))s\n")
        }

        // Determine output directory
        let outputDir: String
        let settingsOutput = settings.outputDir
        if settingsOutput.isEmpty {
            let desktop = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Desktop")
                .appendingPathComponent("\(pfSanitize(settings.personName))_clips")
                .path
            outputDir = desktop
        } else {
            outputDir = settingsOutput
        }

        // Extract clips
        await MainActor.run { job.status = .extracting; job.currentFile = "" }

        let totalClips = validResults.reduce(0) { $0 + $1.segments.count }
        if totalClips > 0 {
            await job.appendLog("Extracting \(totalClips) clip(s) to: \(outputDir)\n")
        }

        var workResults = validResults
        await pfExtractAllClips(
            results: &workResults, personName: settings.personName,
            outputDir: outputDir, concurrency: settings.concurrency,
            logFn: { line in await job.appendLog(line) }
        )

        // Build ClipResult objects for the UI results table
        let clipResults: [ClipResult] = workResults.compactMap { r -> ClipResult? in
            guard !r.segments.isEmpty else { return nil }
            return ClipResult(
                videoFilename: r.filename,
                videoPath: r.filePath,
                videoDuration: r.durationSeconds,
                presenceSecs: r.totalPresenceSecs,
                segmentCount: r.segments.count,
                bestDistance: r.segments.map(\.bestDistance).min() ?? 0,
                clipFiles: r.clipFiles,
                outputDir: outputDir
            )
        }

        let totalPresence = workResults.map(\.totalPresenceSecs).reduce(0, +)
        let foundClips = workResults.reduce(0) { $0 + $1.clipFiles.filter { !$0.isEmpty }.count }

        // Bucketed compilation — see docs/compilation-bucketing.md for the
        // full design. We group consecutive clips by ffprobe-derived
        // CompatKey, then stream-copy each bucket into its own output file.
        // This replaces the old single-file libx264 transcode that broke
        // around the first codec/format boundary in mixed archives.
        var compiledOutputs: [CompiledOutput] = []
        let allClipPaths = workResults.flatMap(\.clipFiles).filter { !$0.isEmpty }
            .map { (outputDir as NSString).appendingPathComponent($0) }

        if foundClips > 0 && (settings.concatOutput || settings.decadeChapters) {
            let df = DateFormatter(); df.dateFormat = "yyyyMMdd_HHmmss"
            let stamp = df.string(from: Date())
            let name = pfSanitize(settings.personName)
            if settings.decadeChapters {
                await job.appendLog("\nNote: decade-chapter output is paused while bucketed")
                await job.appendLog("compilation lands. See docs/compilation-bucketing.md.")
            }
            await job.appendLog("\nBuilding compatibility-bucketed compilations…")
            compiledOutputs = await pfCompileBuckets(
                results: workResults,
                outputDir: outputDir,
                jobName: name,
                stamp: stamp,
                logFn: { line in await job.appendLog(line) }
            )

            // Clean up intermediate clip files after successful compilation.
            // Skip every output file (defensive — outputs live in the same
            // dir as clips, but should never collide by name).
            if !compiledOutputs.isEmpty {
                let outputPaths = Set(compiledOutputs.map(\.path))
                let fm = FileManager.default
                var removed = 0
                for clipPath in allClipPaths {
                    if outputPaths.contains(clipPath) { continue }
                    try? fm.removeItem(atPath: clipPath)
                    removed += 1
                }
                await job.appendLog("  Cleaned up \(removed) intermediate clip file(s)")
            }
        }

        let finalCompiledOutputs = compiledOutputs
        await MainActor.run {
            job.results = clipResults
            job.clipsFound = foundClips
            job.presenceSecs = totalPresence
            job.compiledVideoPaths = finalCompiledOutputs
            job.status = .done
            job.progress = 1.0
            job.currentFile = ""
            job.stopElapsedTimer()
            job.appendLog("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            job.appendLog("Done. \(job.videosWithHits) video(s) with hits, \(foundClips) clip(s), \(pfFormatDuration(totalPresence)) total presence.")
        }
    }
}

// MARK: - Internal data types

struct pfVideoResult {
    let filename: String
    let filePath: String
    let durationSeconds: Double
    let fps: Double
    let totalHits: Int
    let segments: [pfSegment]
    var clipFiles: [String] = []

    nonisolated var totalPresenceSecs: Double { segments.map { $0.endSecs - $0.startSecs }.reduce(0, +) }
}

struct pfSegment {
    var startSecs: Double
    var endSecs: Double
    var bestDistance: Float
    var avgDistance: Float
    var duration: Double { endSecs - startSecs }
}

// Shared CIContext — expensive to create, reuse across calls
private let pfCIContext = CIContext(options: [.useSoftwareRenderer: false])

// MARK: - Reference photo loading

// Returns ([ReferenceFace], errorMessage) — errorMessage is nil on success.
private nonisolated func pfLoadReferencePhotos(from path: String, largestFaceOnly: Bool) -> ([ReferenceFace], String?) {
    let fm = FileManager.default
    let imageExts: Set<String> = ["jpg","jpeg","png","heic","heif","tiff","tif","bmp","gif"]
    var imagePaths: [String] = []
    var isDir: ObjCBool = false
    fm.fileExists(atPath: path, isDirectory: &isDir)
    if isDir.boolValue {
        guard let e = fm.enumerator(atPath: path) else { return ([], "Cannot enumerate \(path)") }
        while let el = e.nextObject() as? String {
            if imageExts.contains((el as NSString).pathExtension.lowercased()) {
                imagePaths.append((path as NSString).appendingPathComponent(el))
            }
        }
        imagePaths.sort()
    } else {
        imagePaths = [path]
    }
    guard !imagePaths.isEmpty else { return ([], "No images found in \(path)") }

    var faces: [ReferenceFace] = []
    for imgPath in imagePaths {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: imgPath) as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
        let req = VNDetectFaceRectanglesRequest(); req.revision = 3
        let handler = VNImageRequestHandler(cgImage: img, options: [:])
        try? handler.perform([req])

        var candidates = (req.results ?? []).filter { $0.confidence >= 0.5 }
        if largestFaceOnly, let largest = candidates.max(by: {
            ($0.boundingBox.width * $0.boundingBox.height) < ($1.boundingBox.width * $1.boundingBox.height)
        }) { candidates = [largest] }

        for obs in candidates {
            guard let cropped = pfNormalizeFaceCrop(from: img, observation: obs),
                  let fp = pfGenerateFeaturePrint(for: cropped) else { continue }
            let face = ReferenceFace(
                featurePrint: fp,
                thumbnail: cropped,
                sourceFilename: (imgPath as NSString).lastPathComponent,
                confidence: obs.confidence,
                rollDeg: (obs.roll?.doubleValue ?? 0) * 180 / .pi,
                yawDeg: (obs.yaw?.doubleValue ?? 0) * 180 / .pi,
                pitchDeg: (obs.pitch?.doubleValue ?? 0) * 180 / .pi,
                faceAreaPct: Float(obs.boundingBox.width * obs.boundingBox.height * 100)
            )
            faces.append(face)
        }
    }
    guard !faces.isEmpty else { return ([], "No faces detected in reference photos") }
    return (faces, nil)
}

// MARK: - Video discovery

nonisolated func pfFindVideoFiles(at searchPath: String, skipBundles: Bool) -> [String] {
    let pfSkipDirectories: Set<String> = [
        ".Spotlight-V100", ".Trashes", ".fseventsd", ".TemporaryItems",
        ".DocumentRevisions-V100", ".PKInstallSandboxManager-SystemSoftware",
        ".MobileBackups", ".vol", ".hotfiles.btree",
        "System", "Library", "usr", "bin", "sbin", "private", "cores", "dev",
        "node_modules", ".git", ".svn", ".hg", "DerivedData", "__pycache__",
        ".Trash", "Caches", "Logs", "DiagnosticReports"
    ]
    let pfBundleExtensions: Set<String> = [
        "fcpbundle","imovielibrary","photoslibrary","aplibrary","dvdmedia",
        "imovieproject","dvdproj","prproj","aep","aet","fcp"
    ]
    let pfVideoExtensions: Set<String> = [
        "mov","qt","mp4","m4v","m4p","m4b","avi","divx","wmv","asf","mkv","webm","mxf",
        "mts","m2ts","ts","m2t","trp","tp","mpg","mpeg","mpe","mpv","m2v","m2p","mp2v","vob","dat",
        "dv","dif","3gp","3g2","3gpp","3gpp2","flv","f4v","mod","tod","ogv","ogm",
        "mjpeg","mjpg","hevc","h264","h265","264","265","rm","rmvb","amv","wtv","dvr-ms"
    ]
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: searchPath, isDirectory: &isDir) else { return [] }
    if !isDir.boolValue {
        return pfVideoExtensions.contains((searchPath as NSString).pathExtension.lowercased()) ? [searchPath] : []
    }
    var files: [String] = []
    guard let e = fm.enumerator(atPath: searchPath) else { return [] }
    while let el = e.nextObject() as? String {
        // Skip system/hidden/irrelevant directories early
        let component = (el as NSString).lastPathComponent
        if pfSkipDirectories.contains(component) {
            e.skipDescendants(); continue
        }
        if skipBundles {
            let parts = el.components(separatedBy: "/")
            if parts.dropLast().contains(where: { pfBundleExtensions.contains(($0 as NSString).pathExtension.lowercased()) }) {
                e.skipDescendants(); continue
            }
            if pfBundleExtensions.contains((el as NSString).pathExtension.lowercased()) {
                e.skipDescendants(); continue
            }
        }
        if pfVideoExtensions.contains((el as NSString).pathExtension.lowercased()) {
            let base = searchPath.hasSuffix("/") ? searchPath : searchPath + "/"
            files.append(base + el)
        }
    }
    var seen = Set<String>(); var deduped: [String] = []
    for path in files.sorted() {
        let key = "\((path as NSString).lastPathComponent)|\((try? fm.attributesOfItem(atPath: path)[.size] as? Int) ?? -1)"
        if seen.insert(key).inserted { deduped.append(path) }
    }
    return deduped
}

// MARK: - Face detection utilities

private func pfDetectFaces(in image: CGImage) -> [VNFaceObservation] {
    let req = VNDetectFaceRectanglesRequest(); req.revision = 3
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    try? handler.perform([req])
    return (req.results ?? []).sorted { $0.confidence > $1.confidence }
}

private nonisolated func pfNormalizeFaceCrop(from source: CGImage, observation: VNFaceObservation, outputSize: Int = 256) -> CGImage? {
    let imgW = CGFloat(source.width)
    let imgH = CGFloat(source.height)
    let bbox = observation.boundingBox

    // Vision and CIImage both use bottom-left origin — no Y flip needed for these coordinates
    let faceCX = (bbox.origin.x + bbox.width / 2) * imgW
    let faceCY = (bbox.origin.y + bbox.height / 2) * imgH
    let roll   = CGFloat(observation.roll?.doubleValue ?? 0)

    // Expand crop 70% beyond face bbox to include forehead, chin and sides
    let sideLen = max(bbox.width * imgW, bbox.height * imgH) * 1.7
    guard sideLen > 4 else { return nil }

    let ciImage = CIImage(cgImage: source)

    // De-rotate around the face centre so the face is upright
    let deRoll = CGAffineTransform(translationX: faceCX, y: faceCY)
        .rotated(by: -roll)
        .translatedBy(x: -faceCX, y: -faceCY)
    let rotated = ciImage.transformed(by: deRoll)

    // Crop a square centred on the face
    let cropOrigin = CGPoint(x: faceCX - sideLen / 2, y: faceCY - sideLen / 2)
    let cropRect   = CGRect(origin: cropOrigin, size: CGSize(width: sideLen, height: sideLen))
    let cropped    = rotated.cropped(to: cropRect)

    // Translate to (0,0) then scale to the desired output size
    let scale = CGFloat(outputSize) / sideLen
    let finalCI = cropped
        .transformed(by: CGAffineTransform(translationX: -cropOrigin.x, y: -cropOrigin.y))
        .transformed(by: CGAffineTransform(scaleX: scale, y: scale))

    return pfCIContext.createCGImage(finalCI,
        from: CGRect(x: 0, y: 0, width: CGFloat(outputSize), height: CGFloat(outputSize)))
}

private nonisolated func pfGenerateFeaturePrint(for image: CGImage) -> VNFeaturePrintObservation? {
    let req = VNGenerateImageFeaturePrintRequest()
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    try? handler.perform([req])
    return req.results?.first as? VNFeaturePrintObservation
}

/// Map a track's preferredTransform to the CGImagePropertyOrientation Vision expects.
private nonisolated func pfOrientationFromTransform(_ t: CGAffineTransform) -> CGImagePropertyOrientation {
    switch (t.a, t.b, t.c, t.d) {
    case (0,  1, -1,  0): return .right  // 90° CW  — phone portrait, home-button right
    case (0, -1,  1,  0): return .left   // 90° CCW — phone portrait, home-button left
    case (-1,  0,  0, -1): return .down  // 180°    — upside down
    default:              return .up     // identity / landscape
    }
}

/// Phase-1 face detection: run Vision directly on the CVPixelBuffer (no CGImage needed).
/// Vision handles YpCbCr natively and dispatches to the Neural Engine / ANE.
private nonisolated func pfDetectFacesInBuffer(_ buffer: CVPixelBuffer,
                                               orientation: CGImagePropertyOrientation) -> [VNFaceObservation] {
    let req = VNDetectFaceRectanglesRequest(); req.revision = 3
    let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: orientation, options: [:])
    try? handler.perform([req])
    return (req.results ?? []).sorted { $0.confidence > $1.confidence }
}

/// Phase-2 image: apply the track's preferredTransform so the CGImage is right-side-up,
/// matching the oriented coordinate space Vision used for bounding boxes.
private nonisolated func pfOrientedCGImage(from buffer: CVPixelBuffer,
                                           transform: CGAffineTransform) -> CGImage? {
    var ci = CIImage(cvPixelBuffer: buffer).transformed(by: transform)
    // Transform may shift the extent off-origin — translate back to (0,0)
    ci = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.origin.x,
                                               y: -ci.extent.origin.y))
    return pfCIContext.createCGImage(ci, from: ci.extent)
}

// MARK: - Video processing

private nonisolated func pfProcessVideo(
    filePath: String,
    prints: [VNFeaturePrintObservation],
    settings: PersonFinderSettings,
    index: Int,
    total: Int,
    pauseGate: PauseGate,
    logFn: @escaping @Sendable (String) async -> Void,
    progressFn: @escaping @Sendable (String) async -> Void,
    frameFn: @escaping @Sendable (CGImage, [CGRect], [CGRect]) async -> Void,
    distFn: @escaping @Sendable (Float) async -> Void,
    visionStatsFn: @escaping @Sendable (Double, Double) async -> Void = { _, _ in },
    previewRateFn: @escaping @Sendable () -> Int = { 5 }
) async -> pfVideoResult? {
    let filename = (filePath as NSString).lastPathComponent
    let asset = AVURLAsset(url: URL(fileURLWithPath: filePath),
                           options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])

    let videoTrack: AVAssetTrack
    let duration: Double
    let fps: Double
    do {
        guard let t = try await asset.loadTracks(withMediaType: .video).first else {
            await logFn("[\(index)/\(total)] \(filename) — skipped (no video track)")
            return nil
        }
        videoTrack = t
        duration = CMTimeGetSeconds(try await asset.load(.duration))
        fps = Double(try await videoTrack.load(.nominalFrameRate))
    } catch {
        await logFn("[\(index)/\(total)] \(filename) — skipped (\(error.localizedDescription))")
        return nil
    }
    let totalFrames = Int(duration * fps)
    guard totalFrames > 0, fps > 0 else { return nil }

    await progressFn(filename)
    await logFn("[\(index)/\(total)] \(filename)  (\(pfFormatDuration(duration)), \(String(format:"%.1f",fps)) fps)")

    // ── AVAssetReader: hardware-decode sequential stream (no seeks, no re-decode) ────────────
    let preferredTransform: CGAffineTransform
    do { preferredTransform = try await videoTrack.load(.preferredTransform) } catch {
        await logFn("[\(index)/\(total)] \(filename) — skipped (can't load transform)")
        return nil
    }
    let orientation = pfOrientationFromTransform(preferredTransform)

    let reader: AVAssetReader
    do { reader = try AVAssetReader(asset: asset) } catch {
        await logFn("[\(index)/\(total)] \(filename) — skipped (AVAssetReader: \(error.localizedDescription))")
        return nil
    }
    // Request YpCbCr — hardware decoder's native format; Vision and CIImage both accept it directly
    let trackOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    ])
    trackOutput.alwaysCopiesSampleData = false
    reader.add(trackOutput)
    guard reader.startReading() else {
        await logFn("[\(index)/\(total)] \(filename) — skipped (AVAssetReader failed to start)")
        return nil
    }

    var hits: [(timeSecs: Double, distance: Float)] = []
    var totalFacesDetected = 0
    var bestDistEver: Float = .greatestFiniteMagnitude  // closest match seen regardless of threshold
    let frameInterval = Double(settings.frameStep) / fps // seconds between processed frames
    var lastProcessedTime = -frameInterval               // ensures first frame is processed
    var sampledSoFar = 0
    let milestones: Set<Int> = [25, 50, 75]             // % checkpoints for console progress lines
    var loggedMilestones = Set<Int>()
    var visionFrameTimes: [Double] = []                  // per-frame processing times for FPS tracking

    while true {
        if Task.isCancelled { reader.cancelReading(); break }

        // All Obj-C bridged objects (CMSampleBuffer, CVPixelBuffer, VNFaceObservation,
        // CGImage, VNFeaturePrint) are created inside autoreleasepool so they drain
        // each iteration instead of piling up until the function returns.
        var frameTime: Double = 0
        var frameHits: [(Double, Float)] = []
        var frameMatchedRects: [CGRect] = []
        var frameUnmatchedRects: [CGRect] = []
        var previewImage: CGImage? = nil
        var facesThisFrame = 0
        var shouldSkip = false

        autoreleasepool {
            guard let sampleBuffer = trackOutput.copyNextSampleBuffer() else {
                shouldSkip = true  // end of stream
                return
            }

            let t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            guard t - lastProcessedTime >= frameInterval else {
                shouldSkip = true  // not time yet, skip
                frameTime = -1     // sentinel: skip but don't break
                return
            }
            lastProcessedTime = t
            frameTime = t

            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                shouldSkip = true
                frameTime = -1
                return
            }

            // Phase 1: face detection on raw CVPixelBuffer — Vision dispatches to ANE
            let frameStart = CFAbsoluteTimeGetCurrent()
            let allFaces = pfDetectFacesInBuffer(pixelBuffer, orientation: orientation)
            let candidates: [VNFaceObservation] = settings.requirePrimary
                ? (allFaces.max(by: { ($0.boundingBox.width * $0.boundingBox.height) < ($1.boundingBox.width * $1.boundingBox.height) }).map { [$0] } ?? [])
                : allFaces

            if !candidates.isEmpty,
               let img = pfOrientedCGImage(from: pixelBuffer, transform: preferredTransform) {
                // Phase 2: CGImage only when faces present
                for obs in candidates {
                    guard obs.confidence >= settings.minFaceConfidence else { continue }
                    guard let cropped = pfNormalizeFaceCrop(from: img, observation: obs),
                          let fp = pfGenerateFeaturePrint(for: cropped) else { continue }
                    facesThisFrame += 1
                    var best: Float = .greatestFiniteMagnitude
                    for ref in prints { var d: Float = 0; if (try? ref.computeDistance(&d, to: fp)) != nil, d < best { best = d } }
                    if best < bestDistEver { bestDistEver = best }
                    if best <= settings.threshold {
                        frameHits.append((t, best))
                        frameMatchedRects.append(obs.boundingBox)
                    } else {
                        frameUnmatchedRects.append(obs.boundingBox)
                    }
                }
                totalFacesDetected += facesThisFrame
                sampledSoFar += 1
                visionFrameTimes.append(CFAbsoluteTimeGetCurrent() - frameStart)
                let rate = max(1, previewRateFn())
                if sampledSoFar % rate == 0 { previewImage = img }
            } else {
                sampledSoFar += 1
                visionFrameTimes.append(CFAbsoluteTimeGetCurrent() - frameStart)
            }
        }
        // -- autoreleasepool drained: all Obj-C temporaries released --

        // Periodic memory pressure check — every 5 sampled frames.
        // With multiple concurrent videos on 4K content, a 30-frame window
        // allows multi-GB spikes before the check fires. 5 frames keeps
        // pressure response tight without measurable overhead (the check
        // itself is a single Mach VM stats call).
        if sampledSoFar > 0 && sampledSoFar % 5 == 0 {
            await pauseGate.waitIfPaused()
            if Task.isCancelled { reader.cancelReading(); break }
        }

        if shouldSkip {
            if frameTime == -1 { continue }  // skip frame, keep going
            else { break }                    // end of stream
        }

        hits.append(contentsOf: frameHits)

        // Async calls outside autoreleasepool
        if let img = previewImage {
            await frameFn(img, frameMatchedRects, frameUnmatchedRects)
        }

        // Publish Vision/ANE throughput stats every 10 sampled frames
        if visionFrameTimes.count >= 10 {
            let avg = visionFrameTimes.reduce(0, +) / Double(visionFrameTimes.count)
            let currentFPS = avg > 0 ? 1.0 / avg : 0
            await visionStatsFn(currentFPS, avg * 1000)  // fps, ms/frame
            visionFrameTimes.removeAll(keepingCapacity: true)
        }

        let pct = duration > 0 ? Int(frameTime / duration * 100) : 0
        await progressFn("\(filename)  [t=\(String(format:"%.0f",frameTime))s / \(String(format:"%.0f",duration))s · \(hits.count) hit(s)]")
        for m in milestones where pct >= m && !loggedMilestones.contains(m) {
            loggedMilestones.insert(m)
            let distStr = bestDistEver < .greatestFiniteMagnitude ? String(format: "%.3f", bestDistEver) : "—"
            await logFn("    \(m)% — t=\(String(format:"%.0f",frameTime))s/\(String(format:"%.0f",duration))s, \(totalFacesDetected) faces detected, \(hits.count) hit(s), best dist \(distStr)")
            await distFn(bestDistEver)
        }
    }

    // Final best-dist push so the dashboard always reflects the completed video
    await distFn(bestDistEver)

    if reader.status == .failed {
        await logFn("[\(index)/\(total)] \(filename) — reader error: \(reader.error?.localizedDescription ?? "unknown")")
    }

    let distStr = bestDistEver < .greatestFiniteMagnitude ? String(format: "%.3f", bestDistEver) : "—"

    guard !hits.isEmpty else {
        await logFn("  [\(index)/\(total)] \(filename) → no match  (faces detected: \(totalFacesDetected), best dist: \(distStr), threshold: \(String(format: "%.3f", settings.threshold)))")
        return pfVideoResult(filename: filename, filePath: filePath,
                             durationSeconds: duration, fps: fps, totalHits: 0, segments: [])
    }

    // Cluster hits into segments
    let gapTol = Double(settings.frameStep) / fps * 3.0
    let sorted = hits.sorted { $0.timeSecs < $1.timeSecs }
    var raw: [(start: Double, end: Double, distances: [Float])] = []
    var cur = (start: sorted[0].timeSecs, end: sorted[0].timeSecs, distances: [sorted[0].distance])
    for h in sorted.dropFirst() {
        if h.timeSecs - cur.end <= gapTol { cur.end = h.timeSecs; cur.distances.append(h.distance) }
        else { raw.append(cur); cur = (h.timeSecs, h.timeSecs, [h.distance]) }
    }
    raw.append(cur)

    var padded = raw.map { (max(0, $0.start - settings.pad), min(duration, $0.end + settings.pad), $0.distances) }
    padded.sort { $0.0 < $1.0 }
    var merged: [(Double, Double, [Float])] = []
    for seg in padded {
        if var last = merged.last, seg.0 <= last.1 {
            last.1 = max(last.1, seg.1); last.2.append(contentsOf: seg.2); merged[merged.count - 1] = last
        } else { merged.append(seg) }
    }

    let segs: [pfSegment] = merged.compactMap { s in
        guard (s.1 - s.0) >= settings.minDuration else { return nil }
        let avg = s.2.reduce(0,+) / Float(s.2.count)
        return pfSegment(startSecs: s.0, endSecs: s.1, bestDistance: s.2.min() ?? 0, avgDistance: avg)
    }
    let presence = segs.reduce(0) { $0 + ($1.endSecs - $1.startSecs) }
    let bestHitDist = hits.map(\.distance).min() ?? 0
    await logFn("  [\(index)/\(total)] \(filename) → \(hits.count) hits, \(segs.count) seg(s), \(pfFormatDuration(presence)) presence  (faces: \(totalFacesDetected), best dist: \(String(format: "%.3f", bestHitDist)))")

    return pfVideoResult(filename: filename, filePath: filePath,
                         durationSeconds: duration, fps: fps, totalHits: hits.count, segments: segs)
}

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

private nonisolated func pfProcessVideoWithDlib(
    filePath: String,
    settings: PersonFinderSettings,
    index: Int,
    total: Int,
    pauseGate: PauseGate,
    logFn:      @escaping @Sendable (String) async -> Void,
    progressFn: @escaping @Sendable (String) async -> Void,
    distFn:     @escaping @Sendable (Float)  async -> Void
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
            "--ref-path",       settings.referencePath,
            "--video",          filePath,
            "--threshold",      String(format: "%.4f", settings.threshold),
            "--frame-step",     String(settings.frameStep),
            "--min-conf",       String(format: "%.4f", settings.minFaceConfidence),
            "--pad",            String(format: "%.2f", settings.pad),
            "--min-duration",   String(format: "%.2f", settings.minDuration),
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

// MARK: - Clip extraction

private func pfExtractAllClips(
    results: inout [pfVideoResult],
    personName: String,
    outputDir: String,
    concurrency: Int,
    logFn: @escaping @Sendable (String) async -> Void
) async {
    let fm = FileManager.default
    try? fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

    struct Work { let ri: Int; let si: Int; let clipName: String; let url: URL; let asset: AVURLAsset; let start: Double; let end: Double }
    var items: [Work] = []
    for ri in 0..<results.count {
        guard !results[ri].segments.isEmpty else { continue }
        let asset = AVURLAsset(url: URL(fileURLWithPath: results[ri].filePath),
                               options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let stem = pfSanitize((results[ri].filename as NSString).deletingPathExtension)
        results[ri].clipFiles = Array(repeating: "", count: results[ri].segments.count)
        for (si, seg) in results[ri].segments.enumerated() {
            let ts = Int(seg.startSecs)
            let name = String(format: "%@_%@_%02dh%02dm%02ds_%03d.mov",
                              pfSanitize(personName), stem, ts/3600, (ts%3600)/60, ts%60, si+1)
            let outURL = URL(fileURLWithPath: outputDir).appendingPathComponent(name)
            if fm.fileExists(atPath: outURL.path) { try? fm.removeItem(at: outURL) }
            items.append(Work(ri: ri, si: si, clipName: name, url: outURL, asset: asset,
                              start: seg.startSecs, end: seg.endSecs))
        }
    }

    let workCount = items.count
    await withTaskGroup(of: (Int, Bool).self) { group in
        var submitted = 0
        for i in 0..<min(concurrency, workCount) {
            let w = items[i]; group.addTask { (i, await pfExtractClip(asset: w.asset, start: w.start, end: w.end, to: w.url)) }
            submitted += 1
        }
        for await (idx, ok) in group {
            let w = items[idx]
            if ok { await logFn("  → Saved: \(w.clipName)"); results[w.ri].clipFiles[w.si] = w.clipName }
            if submitted < workCount {
                let nw = items[submitted]; let ni = submitted
                group.addTask { (ni, await pfExtractClip(asset: nw.asset, start: nw.start, end: nw.end, to: nw.url)) }
                submitted += 1
            }
        }
    }
}

private func pfExtractClip(asset: AVURLAsset, start: Double, end: Double, to url: URL) async -> Bool {
    guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else { return false }
    session.timeRange = CMTimeRangeMake(start: CMTimeMakeWithSeconds(start, preferredTimescale: 600),
                                        duration: CMTimeMakeWithSeconds(end - start, preferredTimescale: 600))
    do { try await session.export(to: url, as: .mov); return true }
    catch { return false }
}

// MARK: - Concatenation

// MARK: - Decade helpers

private func pfExtractYear(from path: String) -> Int {
    // Try 4-digit year in path/filename
    let pattern = try? NSRegularExpression(pattern: #"\b(19[5-9]\d|20[0-3]\d)\b"#)
    let s = path as NSString
    if let m = pattern?.firstMatch(in: path, range: NSRange(location: 0, length: s.length)) {
        return Int(s.substring(with: m.range)) ?? 0
    }
    // Fall back to file creation date
    if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
       let created = attrs[.creationDate] as? Date {
        return Calendar.current.component(.year, from: created)
    }
    return 0
}

private func pfDecadeLabel(for year: Int) -> String {
    guard year > 0 else { return "Unknown" }
    let decade = (year / 10) * 10
    return "\(decade)s"
}

private struct pfClipEntry {
    let clipPath: String
    let year: Int
    let decade: String
}

private func pfBuildSortedClipEntries(results: [pfVideoResult], outputDir: String) -> [pfClipEntry] {
    var entries: [pfClipEntry] = []
    for r in results {
        let year = pfExtractYear(from: r.filePath)
        let decade = pfDecadeLabel(for: year)
        for name in r.clipFiles where !name.isEmpty {
            let fullPath = (outputDir as NSString).appendingPathComponent(name)
            entries.append(pfClipEntry(clipPath: fullPath, year: year, decade: decade))
        }
    }
    return entries.sorted { a, b in a.year == b.year ? a.clipPath < b.clipPath : a.year < b.year }
}

private func pfConcatenateWithDecadeChapters(
    results: [pfVideoResult],
    outputDir: String,
    outputPath: String,
    logFn: @escaping @Sendable (String) async -> Void
) async {
    let entries = pfBuildSortedClipEntries(results: results, outputDir: outputDir)
    guard !entries.isEmpty else { await logFn("  No clips to compile."); return }

    let fm = FileManager.default
    let ffmpegCandidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
    guard let ffmpegPath = ffmpegCandidates.first(where: { fm.fileExists(atPath: $0) }) else {
        await logFn("  ⚠ ffmpeg not found — install via: brew install ffmpeg")
        return
    }

    // Load durations for chapter timestamp calculation
    var durations: [Double] = []
    for e in entries {
        let a = AVURLAsset(url: URL(fileURLWithPath: e.clipPath),
                           options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let dur = (try? await CMTimeGetSeconds(a.load(.duration))) ?? 0
        durations.append(dur)
    }

    // Compute chapter boundaries at decade transitions
    struct PFChapter { let title: String; let startMs: Int64 }
    var chapters: [PFChapter] = []
    var cumulativeMs: Int64 = 0
    var currentDecade = ""
    for (i, entry) in entries.enumerated() {
        if entry.decade != currentDecade {
            chapters.append(PFChapter(title: entry.decade, startMs: cumulativeMs))
            currentDecade = entry.decade
        }
        cumulativeMs += Int64(durations[i] * 1000)
    }

    let tmp = NSTemporaryDirectory()
    let ts = Int(Date().timeIntervalSince1970)
    let listPath = (tmp as NSString).appendingPathComponent("pf_dlist_\(ts).txt")
    let metaPath = (tmp as NSString).appendingPathComponent("pf_dmeta_\(ts).txt")

    let listContent = entries.map { "file '\($0.clipPath)'" }.joined(separator: "\n")
    try? listContent.write(toFile: listPath, atomically: true, encoding: .utf8)

    var meta = ";FFMETADATA1\n\n"
    for (i, ch) in chapters.enumerated() {
        let end = i + 1 < chapters.count ? chapters[i + 1].startMs : cumulativeMs
        meta += "[CHAPTER]\nTIMEBASE=1/1000\nSTART=\(ch.startMs)\nEND=\(end)\ntitle=\(ch.title)\n\n"
    }
    try? meta.write(toFile: metaPath, atomically: true, encoding: .utf8)

    if fm.fileExists(atPath: outputPath) { try? fm.removeItem(atPath: outputPath) }
    let decadeList = chapters.map(\.title).joined(separator: " · ")
    await logFn("  Building decade chapter video (\(decadeList))…")

    let process = Process()
    process.executableURL = URL(fileURLWithPath: ffmpegPath)
    process.arguments = [
        "-f", "concat", "-safe", "0", "-i", listPath,
        "-i", metaPath,
        "-map_metadata", "1",
        "-map_chapters", "1",
        "-vf", "scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30000/1001",
        "-c:v", "libx264", "-preset", "fast", "-crf", "18",
        "-c:a", "aac", "-b:a", "192k",
        "-y", outputPath
    ]
    process.standardOutput = FileHandle.nullDevice
    let stderrPipe = Pipe()
    process.standardError = stderrPipe

    // Drain stderr asynchronously to prevent pipe buffer deadlock.
    // ffmpeg can emit thousands of warning lines with mixed-format inputs;
    // if the 64KB pipe buffer fills, ffmpeg blocks and the output is truncated.
    var stderrData = Data()
    stderrPipe.fileHandleForReading.readabilityHandler = { handle in
        let chunk = handle.availableData
        if !chunk.isEmpty { stderrData.append(chunk) }
    }

    do { try process.run() } catch {
        await logFn("  ⚠ Could not launch ffmpeg: \(error.localizedDescription)")
        try? fm.removeItem(atPath: listPath); try? fm.removeItem(atPath: metaPath)
        return
    }

    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
        process.terminationHandler = { _ in cont.resume() }
        if !process.isRunning { cont.resume() }
    }
    stderrPipe.fileHandleForReading.readabilityHandler = nil
    try? fm.removeItem(atPath: listPath); try? fm.removeItem(atPath: metaPath)

    if process.terminationStatus == 0 {
        let totalSecs = durations.reduce(0, +)
        await logFn("  → Decade video saved: \(outputPath)")
        await logFn("  → Duration: \(pfFormatDuration(totalSecs))  Chapters: \(decadeList)")
    } else {
        await logFn("  ⚠ ffmpeg exited with code \(process.terminationStatus)")
        if let errStr = String(data: stderrData, encoding: .utf8), !errStr.isEmpty {
            let lines = errStr.components(separatedBy: .newlines).suffix(10)
            for line in lines where !line.isEmpty {
                await logFn("    stderr: \(line)")
            }
        }
    }
}

// MARK: - Concat (simple, no chapters)

private func pfConcatenateClips(
    results: [pfVideoResult],
    outputDir: String,
    outputPath: String,
    logFn: @escaping @Sendable (String) async -> Void
) async {
    let paths = results.flatMap(\.clipFiles).filter { !$0.isEmpty }
        .map { (outputDir as NSString).appendingPathComponent($0) }
    guard !paths.isEmpty else { return }

    let fm = FileManager.default
    let ffmpegCandidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
    guard let ffmpegPath = ffmpegCandidates.first(where: { fm.fileExists(atPath: $0) }) else {
        await logFn("  ⚠ ffmpeg not found — install via: brew install ffmpeg")
        return
    }

    let tmp = NSTemporaryDirectory()
    let ts = Int(Date().timeIntervalSince1970)
    let listPath = (tmp as NSString).appendingPathComponent("pf_concat_\(ts).txt")
    let listContent = paths.map { "file '\($0)'" }.joined(separator: "\n")
    try? listContent.write(toFile: listPath, atomically: true, encoding: .utf8)

    if fm.fileExists(atPath: outputPath) { try? fm.removeItem(atPath: outputPath) }

    await logFn("  Normalising and compiling \(paths.count) clips via ffmpeg…")

    let process = Process()
    process.executableURL = URL(fileURLWithPath: ffmpegPath)
    process.arguments = [
        "-f", "concat", "-safe", "0", "-i", listPath,
        "-vf", "scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30000/1001",
        "-c:v", "libx264", "-preset", "fast", "-crf", "18",
        "-c:a", "aac", "-b:a", "192k",
        "-y", outputPath
    ]
    process.standardOutput = FileHandle.nullDevice
    let stderrPipe = Pipe()
    process.standardError = stderrPipe

    // Drain stderr asynchronously to prevent pipe buffer deadlock.
    var stderrData = Data()
    stderrPipe.fileHandleForReading.readabilityHandler = { handle in
        let chunk = handle.availableData
        if !chunk.isEmpty { stderrData.append(chunk) }
    }

    do { try process.run() } catch {
        await logFn("  ⚠ Could not launch ffmpeg: \(error.localizedDescription)")
        try? fm.removeItem(atPath: listPath)
        return
    }

    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
        process.terminationHandler = { _ in cont.resume() }
        if !process.isRunning { cont.resume() }
    }
    stderrPipe.fileHandleForReading.readabilityHandler = nil
    try? fm.removeItem(atPath: listPath)

    if process.terminationStatus == 0 {
        await logFn("  → Compiled video: \(outputPath)")
    } else {
        await logFn("  ⚠ ffmpeg concat exited with code \(process.terminationStatus)")
        if let errStr = String(data: stderrData, encoding: .utf8), !errStr.isEmpty {
            let lines = errStr.components(separatedBy: .newlines).suffix(10)
            for line in lines where !line.isEmpty {
                await logFn("    stderr: \(line)")
            }
        }
    }
}

// MARK: - Compatibility bucketing
//
// See docs/compilation-bucketing.md for design rationale. The short version:
// the ffmpeg concat demuxer requires every input to share identical stream
// parameters (codec, pix_fmt, resolution, SAR, audio layout, etc). With
// mixed family-archive material that condition fails about ten minutes
// into a typical compilation. Instead of forcing a lossy re-encode, we
// group consecutive clips by a CompatKey and stream-copy each group into
// its own output file. Multiple files, but every byte preserved.

/// All the stream parameters that the concat demuxer cares about for
/// stream copy. Two clips are concat-copy compatible iff their CompatKey
/// values are equal. The fields are intentionally strict — better to
/// over-bucket than to silently produce a broken file.
private struct CompatKey: Hashable {
    // Video
    let vCodec:      String   // "h264", "hevc", "dvvideo", "mpeg2video", "none"
    let vProfile:    String   // "High", "Main", ""
    let pixFmt:      String   // "yuv420p", "yuv422p10le"
    let width:       Int
    let height:      Int
    let sar:         String   // "1:1", "10:11"
    let fpsRational: String   // "30000/1001", "25/1", "0/0" if VFR
    let colorSpace:  String
    let colorRange:  String
    // Audio
    let aCodec:      String   // "aac", "pcm_s16le", "ac3", "none"
    let aSampleRate: Int      // 0 if no audio
    let aChannels:   Int      // 0 if no audio
    let aLayout:     String
    // Container shape
    let hasAudio:    Bool

    /// Filename-safe short label, e.g. "h264_1080p2997_aac48k_2ch".
    var shortLabel: String {
        let codecShort: String = {
            switch vCodec {
            case "h264":       return "h264"
            case "hevc":       return "hevc"
            case "dvvideo":    return "dv"
            case "mpeg2video": return "mpeg2"
            case "prores":     return "prores"
            case "mjpeg":      return "mjpeg"
            case "vp9":        return "vp9"
            case "av1":        return "av1"
            default:           return vCodec.isEmpty ? "novideo" : vCodec
            }
        }()
        let res = "\(height)p"
        let fps: String = {
            // r_frame_rate "num/den" → rounded label
            let parts = fpsRational.split(separator: "/").compactMap { Double($0) }
            guard parts.count == 2, parts[1] > 0 else { return "vfr" }
            let f = parts[0] / parts[1]
            if abs(f - 23.976) < 0.05 { return "2398" }
            if abs(f - 24)     < 0.05 { return "24" }
            if abs(f - 25)     < 0.05 { return "25" }
            if abs(f - 29.97)  < 0.05 { return "2997" }
            if abs(f - 30)     < 0.05 { return "30" }
            if abs(f - 50)     < 0.05 { return "50" }
            if abs(f - 59.94)  < 0.05 { return "5994" }
            if abs(f - 60)     < 0.05 { return "60" }
            return String(format: "%.0f", f)
        }()
        let audio: String = {
            guard hasAudio else { return "noaudio" }
            let codecShort: String = {
                switch aCodec {
                case "aac":       return "aac"
                case "pcm_s16le": return "pcm"
                case "pcm_s24le": return "pcm24"
                case "ac3":       return "ac3"
                case "eac3":      return "eac3"
                case "mp3":       return "mp3"
                case "opus":      return "opus"
                default:          return aCodec.isEmpty ? "audio" : aCodec
                }
            }()
            let kHz = aSampleRate / 1000
            return "\(codecShort)\(kHz)k_\(aChannels)ch"
        }()
        return pfSanitize("\(codecShort)_\(res)\(fps)_\(audio)")
    }

    /// True iff every codec/pixfmt in this key can legally live inside an
    /// `.mp4` (ISO BMFF) container. Anything exotic gets `.mov`, which is
    /// the more permissive of the two.
    var preferredExtension: String {
        let mp4Codecs: Set<String> = ["h264", "hevc", "mpeg2video", "mpeg4", "av1"]
        let mp4Audio:  Set<String> = ["aac", "ac3", "eac3", "mp3", "opus"]
        let mp4PixFmt: Set<String> = ["yuv420p", "yuvj420p", "nv12", "yuv420p10le"]
        if !mp4Codecs.contains(vCodec) { return "mov" }
        if hasAudio && !mp4Audio.contains(aCodec) { return "mov" }
        if !mp4PixFmt.contains(pixFmt) { return "mov" }
        return "mp4"
    }
}

/// Run ffprobe on a clip and parse out a CompatKey. Returns nil if the
/// probe failed or the file lacks a video stream.
private func pfProbeCompatKey(path: String) async -> CompatKey? {
    let fm = FileManager.default
    let ffprobeCandidates = ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe", "/usr/bin/ffprobe"]
    guard let ffprobePath = ffprobeCandidates.first(where: { fm.fileExists(atPath: $0) }) else { return nil }
    guard fm.fileExists(atPath: path) else { return nil }

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: ffprobePath)
    proc.arguments = [
        "-v", "error",
        "-print_format", "json",
        "-show_streams",
        "-show_format",
        path
    ]
    let outPipe = Pipe()
    proc.standardOutput = outPipe
    proc.standardError = FileHandle.nullDevice
    do { try proc.run() } catch { return nil }
    proc.waitUntilExit()
    guard proc.terminationStatus == 0 else { return nil }

    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let streams = root["streams"] as? [[String: Any]] else { return nil }

    let video = streams.first(where: { ($0["codec_type"] as? String) == "video" })
    let audio = streams.first(where: { ($0["codec_type"] as? String) == "audio" })

    guard let v = video else { return nil }

    func str(_ d: [String: Any]?, _ k: String) -> String { (d?[k] as? String) ?? "" }
    func int(_ d: [String: Any]?, _ k: String) -> Int {
        if let i = d?[k] as? Int { return i }
        if let s = d?[k] as? String, let i = Int(s) { return i }
        return 0
    }

    let vCodec     = str(v, "codec_name")
    let vProfile   = str(v, "profile")
    let pixFmt     = str(v, "pix_fmt")
    let width      = int(v, "width")
    let height     = int(v, "height")
    let sar        = str(v, "sample_aspect_ratio").isEmpty ? "1:1" : str(v, "sample_aspect_ratio")
    let fps        = str(v, "r_frame_rate").isEmpty ? "0/0" : str(v, "r_frame_rate")
    let colorSpace = str(v, "color_space")
    let colorRange = str(v, "color_range")

    let hasAudio  = audio != nil
    let aCodec    = hasAudio ? str(audio, "codec_name")     : "none"
    let aRate     = hasAudio ? int(audio, "sample_rate")    : 0
    let aChannels = hasAudio ? int(audio, "channels")       : 0
    let aLayout   = hasAudio ? str(audio, "channel_layout") : ""

    return CompatKey(
        vCodec: vCodec, vProfile: vProfile, pixFmt: pixFmt,
        width: width, height: height, sar: sar, fpsRational: fps,
        colorSpace: colorSpace, colorRange: colorRange,
        aCodec: aCodec, aSampleRate: aRate, aChannels: aChannels, aLayout: aLayout,
        hasAudio: hasAudio
    )
}

/// One bucket worth of clips, all sharing a CompatKey, in timeline order.
private struct pfBucket {
    let key: CompatKey
    var entries: [pfClipEntry]
    var totalDurationSecs: Double
}

/// Strict-adjacent bucketing: walks the timeline-sorted entries and starts
/// a new bucket whenever the next clip's key differs from the current
/// bucket's key, OR appending it would exceed `maxSecs`. Probes via
/// ffprobe; logs and skips clips that fail to probe.
private func pfBucketByCompat(
    entries: [pfClipEntry],
    maxSecs: Double,
    logFn: @escaping @Sendable (String) async -> Void
) async -> [pfBucket] {
    var buckets: [pfBucket] = []
    var current: pfBucket? = nil

    for entry in entries {
        guard let key = await pfProbeCompatKey(path: entry.clipPath) else {
            await logFn("  ⚠ ffprobe failed for \((entry.clipPath as NSString).lastPathComponent) — skipping")
            continue
        }
        // Cheap duration probe via AVAsset (already used elsewhere in this file).
        let asset = AVURLAsset(url: URL(fileURLWithPath: entry.clipPath),
                               options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let dur = (try? await CMTimeGetSeconds(asset.load(.duration))) ?? 0

        if var b = current,
           b.key == key,
           b.totalDurationSecs + dur <= maxSecs {
            b.entries.append(entry)
            b.totalDurationSecs += dur
            current = b
        } else {
            if let b = current { buckets.append(b) }
            current = pfBucket(key: key, entries: [entry], totalDurationSecs: dur)
        }
    }
    if let b = current { buckets.append(b) }
    return buckets
}

/// Top-level driver for the bucketed compilation pipeline. Returns one
/// CompiledOutput per bucket actually written to disk.
private func pfCompileBuckets(
    results: [pfVideoResult],
    outputDir: String,
    jobName: String,
    stamp: String,
    logFn: @escaping @Sendable (String) async -> Void
) async -> [CompiledOutput] {
    let entries = pfBuildSortedClipEntries(results: results, outputDir: outputDir)
    guard !entries.isEmpty else {
        await logFn("  No clips to compile.")
        return []
    }

    let maxBucketSecs: Double = 30 * 60   // 30-minute soft cap per bucket
    let buckets = await pfBucketByCompat(entries: entries, maxSecs: maxBucketSecs, logFn: logFn)
    guard !buckets.isEmpty else { return [] }

    await logFn("  Found \(entries.count) clip(s) → \(buckets.count) compatibility bucket(s).")

    let fm = FileManager.default
    let ffmpegCandidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
    guard let ffmpegPath = ffmpegCandidates.first(where: { fm.fileExists(atPath: $0) }) else {
        await logFn("  ⚠ ffmpeg not found — install via: brew install ffmpeg")
        return []
    }

    var outputs: [CompiledOutput] = []
    for (idx, bucket) in buckets.enumerated() {
        let ordinal = String(format: "%02d", idx + 1)
        let label   = bucket.key.shortLabel
        let ext     = bucket.key.preferredExtension
        let outName = "\(jobName)_compilation_\(ordinal)_\(label)_\(stamp).\(ext)"
        let outPath = (outputDir as NSString).appendingPathComponent(outName)

        await logFn("  → Bucket \(ordinal)/\(buckets.count): \(label) — \(bucket.entries.count) clip(s), \(pfFormatDuration(bucket.totalDurationSecs))")

        if let written = await pfStreamCopyConcat(
            ffmpegPath: ffmpegPath,
            entries: bucket.entries,
            outputPath: outPath,
            logFn: logFn
        ) {
            outputs.append(CompiledOutput(
                path: written,
                label: label,
                clipCount: bucket.entries.count,
                durationSecs: bucket.totalDurationSecs,
                bytesOnDisk: pfFileSize(at: written)
            ))
        }
    }
    return outputs
}

/// Stream-copy a list of clips into one output file via the ffmpeg concat
/// demuxer. Returns the output path on success, nil on failure.
private func pfStreamCopyConcat(
    ffmpegPath: String,
    entries: [pfClipEntry],
    outputPath: String,
    logFn: @escaping @Sendable (String) async -> Void
) async -> String? {
    let fm = FileManager.default
    let tmp = NSTemporaryDirectory()
    let ts = Int(Date().timeIntervalSince1970 * 1000)
    let listPath = (tmp as NSString).appendingPathComponent("pf_bucket_\(ts).txt")

    // ffmpeg concat demuxer requires single-quoted paths with internal
    // single quotes escaped as '\''.
    let listContent = entries.map { e -> String in
        let escaped = e.clipPath.replacingOccurrences(of: "'", with: "'\\''")
        return "file '\(escaped)'"
    }.joined(separator: "\n")
    do { try listContent.write(toFile: listPath, atomically: true, encoding: .utf8) }
    catch {
        await logFn("  ⚠ Could not write concat list: \(error.localizedDescription)")
        return nil
    }

    if fm.fileExists(atPath: outputPath) { try? fm.removeItem(atPath: outputPath) }

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: ffmpegPath)
    proc.arguments = [
        "-hide_banner", "-nostdin",
        "-f", "concat", "-safe", "0", "-i", listPath,
        "-map", "0:v?", "-map", "0:a?",
        "-c", "copy",
        "-movflags", "+faststart",
        "-y", outputPath
    ]
    proc.standardOutput = FileHandle.nullDevice
    let stderrPipe = Pipe()
    proc.standardError = stderrPipe

    // Drain stderr to prevent the 64KB pipe buffer from deadlocking ffmpeg
    // when it emits many warnings (mixed-input archives produce a lot).
    let stderrBox = pfStderrBox()
    stderrPipe.fileHandleForReading.readabilityHandler = { handle in
        let chunk = handle.availableData
        if !chunk.isEmpty { stderrBox.append(chunk) }
    }

    do { try proc.run() } catch {
        await logFn("  ⚠ Could not launch ffmpeg: \(error.localizedDescription)")
        try? fm.removeItem(atPath: listPath)
        return nil
    }

    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
        proc.terminationHandler = { _ in cont.resume() }
        if !proc.isRunning { cont.resume() }
    }
    stderrPipe.fileHandleForReading.readabilityHandler = nil
    try? fm.removeItem(atPath: listPath)

    if proc.terminationStatus == 0 {
        await logFn("    ✓ \((outputPath as NSString).lastPathComponent)")
        return outputPath
    } else {
        await logFn("    ⚠ ffmpeg exited with code \(proc.terminationStatus)")
        if let errStr = String(data: stderrBox.data, encoding: .utf8), !errStr.isEmpty {
            for line in errStr.components(separatedBy: .newlines).suffix(8) where !line.isEmpty {
                await logFn("      stderr: \(line)")
            }
        }
        return nil
    }
}

/// Tiny reference-type box so the readabilityHandler closure can append
/// without tripping Swift 6 sendable-capture diagnostics.
private final class pfStderrBox: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    func append(_ chunk: Data) { lock.lock(); buffer.append(chunk); lock.unlock() }
    var data: Data { lock.lock(); defer { lock.unlock() }; return buffer }
}

private func pfFileSize(at path: String) -> Int64 {
    let attrs = try? FileManager.default.attributesOfItem(atPath: path)
    return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
}

// MARK: - Utilities

nonisolated func pfSanitize(_ s: String) -> String {
    var r = s.replacingOccurrences(of: " ", with: "_")
    let ok = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
    r = String(r.unicodeScalars.filter { ok.contains($0) })
    return r
}

func pfFormatDuration(_ secs: Double) -> String {
    let t = Int(secs); let h = t/3600; let m = (t%3600)/60; let s = t%60
    return h > 0 ? "\(h)h \(m)m \(s)s" : m > 0 ? "\(m)m \(s)s" : "\(s)s"
}

func pfFormatBytes(_ bytes: Int64) -> String {
    let f = ByteCountFormatter()
    f.allowedUnits = [.useMB, .useGB]
    f.countStyle = .file
    return f.string(fromByteCount: bytes)
}
