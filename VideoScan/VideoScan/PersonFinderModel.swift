// PersonFinderModel.swift
// Drives multi-volume person-finding scans inside the VideoScan app.
// Each ScanJob represents one search target (volume or folder).

import Foundation
@preconcurrency import AVFoundation
import Vision
import CoreImage
import CoreGraphics
import CoreML
import SwiftUI
import Combine
import os

/// Logger for the personfinder code path. Streamed remotely via:
///   log stream --process VideoScan \
///     --predicate 'subsystem == "Rick-Breen.VideoScan"' --style compact
///
/// Named `osLog` (not `log`) because there's a local `log = PersistentLog(...)`
/// inside runJob that would otherwise shadow this. In-app console
/// (job.appendLog) is for the user; this Logger is for the agent watching
/// remotely. Most failure paths log to both.
private let osLog = Logger(
    subsystem: "Rick-Breen.VideoScan",
    category: "personfinder"
)

let perfLog = Logger(
    subsystem: "Rick-Breen.VideoScan",
    category: "perf"
)
private let pfScanLog = Logger(
    subsystem: "Rick-Breen.VideoScan",
    category: "scan"
)
let signpostLog = OSSignposter(
    subsystem: "Rick-Breen.VideoScan",
    category: "perf"
)

// Value types (FramePerfAccumulator, RecognitionEngine, PersonFinderSettings,
// POIProfile, ScanJobStatus, Compilation{Mode,Settings,Status}, ReferenceFace,
// ReferenceLoadFailure, ClipResult, CompiledOutput, pfVideoResult, pfSegment)
// live in PersonFinderTypes.swift.

// MARK: - Scan Job

@MainActor
final class ScanJob: ObservableObject, Identifiable {
    let id = UUID()
    @Published var searchPath: String

    /// Per-job person assignment — nil means use global person.
    @Published var assignedProfile: POIProfile?
    var assignedFaces: [ReferenceFace] = []
    var personLabel: String { assignedProfile?.name ?? "" }

    /// Per-job engine override — nil means use profile's engine or global default.
    @Published var assignedEngine: RecognitionEngine?
    /// Resolved engine: job override > profile > global default
    var effectiveEngine: RecognitionEngine {
        if let e = assignedEngine { return e }
        if let p = assignedProfile, let e = RecognitionEngine(rawValue: p.engine) { return e }
        return .vision
    }

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

    // Compilation state (separate from scan lifecycle)
    @Published var compilationStatus: CompilationStatus = .idle
    @Published var compilationProgress: Double = 0.0
    @Published var compilationPhase: String = ""
    @Published var compilationClipsTotal: Int = 0
    @Published var compilationClipsDone: Int = 0
    fileprivate var compilationTask: Task<Void, Never>?

    /// Raw recognition results preserved for on-demand compilation.
    nonisolated(unsafe) var recognitionResults: [pfVideoResult] = []
    nonisolated(unsafe) var recognitionOutputDir: String = ""

    // Live frame preview
    @Published var liveFrame: CGImage?
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
        compilationTask?.cancel()
        Task { await pauseGate.resume() }  // release any waiters
        status = .idle; progress = 0; currentFile = ""
        videosTotal = 0; videosScanned = 0; videosWithHits = 0
        clipsFound = 0; presenceSecs = 0
        results = []; consoleLines = []
        compiledVideoPaths = []; elapsedSecs = 0
        compilationStatus = .idle; compilationProgress = 0
        compilationPhase = ""; compilationClipsTotal = 0; compilationClipsDone = 0
        recognitionResults = []; recognitionOutputDir = ""
        liveFrame = nil; liveMatchedRects = []; liveUnmatchedRects = []
        bestDist = .greatestFiniteMagnitude
        scanTask = nil; timerTask = nil; compilationTask = nil; taskStarted = nil
    }

    func finalizeResults(_ filtered: [ClipResult]) {
        results = filtered
        videosWithHits = filtered.count
        // High-level narration to videoscan.log — matches the "Starting search…"
        // line emitted in startJobAfterLoad.
        let personName = assignedProfile?.name ?? "(global)"
        let volumeName = URL(fileURLWithPath: searchPath).lastPathComponent
        let elapsed = taskStarted.map { Int(Date().timeIntervalSince($0)) } ?? 0
        appLog.write("Finished search for \(personName) on \(volumeName): \(filtered.count) video(s) with hits in \(elapsed)s")
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
        taskStarted = nil
    }
}

// MARK: - Person Finder Model

@MainActor
final class PersonFinderModel: ObservableObject {
    @Published var jobs: [ScanJob] = []
    @Published var settings = PersonFinderSettings.restored() {
        didSet { settings.save() }
    }
    /// UI state preserved across tab switches (model outlives the view).
    @Published var selectedJobID: UUID?
    @Published var expandedJobIDs = Set<UUID>()

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
    /// Name of the person being actively scanned — set at scan start, cleared when all jobs finish.
    @Published var scanningPersonName: String?
    /// The person that will be assigned to newly created jobs.
    @Published var selectedPersonForNewJobs: POIProfile?
    var referenceLoadError: String?
    @Published var referenceLoadFailures: [ReferenceLoadFailure] = []
    var isLoadingReference: Bool = false

    var referenceFeaturePrints: [VNFeaturePrintObservation] { referenceFaces.map(\.featurePrint) }
    var referencePhotoCount: Int { referenceFaces.count }

    init() {
        let floorGB = ScanPerformanceSettings.restored().memoryFloorGB
        Task { await MemoryPressureMonitor.shared.setFloorGB(floorGB) }
    }

    private static func referenceCacheIdentifiers(referencePath: String, filenames: [String]) -> [String] {
        guard !referencePath.isEmpty else { return filenames }
        let baseURL = URL(fileURLWithPath: referencePath)
        return filenames.map { baseURL.appendingPathComponent($0).path }
    }

    // MARK: Job management

    func addJob(path: String = "") {
        let job = ScanJob(searchPath: path)
        if let person = selectedPersonForNewJobs {
            job.assignedProfile = person
        }
        jobs.append(job)
    }

    /// Load reference faces for a specific job's assigned person.
    func loadFacesForJob(_ job: ScanJob) async {
        guard let profile = job.assignedProfile else { return }
        guard job.status == .idle else { return }
        job.status = .loading
        let largestOnly = profile.largestFaceOnly
        let (faces, _, _) = await Task.detached(priority: .userInitiated) {
            pfLoadReferencePhotos(from: profile.referencePath, largestFaceOnly: largestOnly)
        }.value
        let rejected = Set(profile.rejectedFiles)
        job.assignedFaces = rejected.isEmpty ? faces : faces.filter { !rejected.contains($0.sourceFilename) }
        job.status = .idle

        if !job.searchPath.isEmpty && !job.assignedFaces.isEmpty {
            restoreFromCache(job: job)
        }
    }

    func removeJob(_ job: ScanJob) {
        job.scanTask?.cancel()
        job.timerTask?.cancel()
        jobs.removeAll { $0.id == job.id }
    }

    func restoreFromCache(job: ScanJob) {
        guard job.status.isIdle else { return }
        guard let profile = job.assignedProfile, !job.searchPath.isEmpty else { return }

        let personName = profile.name
        let engine = job.effectiveEngine
        let threshold = engine == .arcface ? profile.arcfaceThreshold : profile.visionThreshold
        let refIdentifiers = Self.referenceCacheIdentifiers(
            referencePath: profile.referencePath,
            filenames: job.assignedFaces.map(\.sourceFilename)
        )
        guard !refIdentifiers.isEmpty else { return }

        let searchPath = job.searchPath
        let jobSettings = self.settings

        job.scanTask = Task.detached(priority: .utility) {
            let skipBundles = jobSettings.skipBundles
            let videoFiles = pfFindVideoFiles(at: searchPath, skipBundles: skipBundles)
            guard !videoFiles.isEmpty else { return }

            var cachedResults: [pfVideoResult] = []
            var hits = 0
            for path in videoFiles {
                guard !Task.isCancelled else { return }
                guard let key = PersonFinderCache.makeKey(
                    videoPath: path, personName: personName,
                    engine: engine, threshold: threshold,
                    refFilenames: refIdentifiers
                ), let result = PersonFinderCache.shared.lookup(key: key) else { continue }
                hits += 1
                if !result.segments.isEmpty {
                    cachedResults.append(result)
                }
            }

            guard hits > 0 else { return }
            guard !Task.isCancelled else { return }
            osLog.info("Cache restore: \(hits)/\(videoFiles.count) cached, \(cachedResults.count) with hits for \(personName, privacy: .public)")

            let outputDir = Self.resolveOutputDir(jobSettings)
            let (validResults, _) = Self.filterByPresence(cachedResults, settings: jobSettings)

            let clipResults: [ClipResult] = validResults.compactMap { r -> ClipResult? in
                guard !r.segments.isEmpty else { return nil }
                return ClipResult(
                    videoFilename: r.filename,
                    videoPath: r.filePath,
                    videoDuration: r.durationSeconds,
                    presenceSecs: r.totalPresenceSecs,
                    segmentCount: r.segments.count,
                    bestDistance: r.segments.map(\.bestDistance).min() ?? 0,
                    clipFiles: [],
                    outputDir: outputDir
                )
            }
            let totalPresence = validResults.map(\.totalPresenceSecs).reduce(0, +)
            let totalSegments = validResults.reduce(0) { $0 + $1.segments.count }

            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard job.status.isIdle else { return }
                job.finalizeResults(clipResults)
                job.recognitionResults = validResults
                job.recognitionOutputDir = outputDir
                job.presenceSecs = totalPresence
                job.clipsFound = totalSegments
                job.videosTotal = videoFiles.count
                job.videosScanned = hits
                job.status = .done
                job.stopElapsedTimer()
                job.appendLog("Restored from cache: \(clipResults.count) video(s) with hits, \(totalSegments) segment(s)")
            }
        }
    }

    func startJob(_ job: ScanJob) {
        guard !job.status.isActive else { return }

        // If job has an assigned profile but no faces loaded yet, load them first
        if job.assignedProfile != nil && job.assignedFaces.isEmpty {
            Task {
                await loadFacesForJob(job)
                startJobAfterLoad(job)
            }
            return
        }
        startJobAfterLoad(job)
    }

    private func startJobAfterLoad(_ job: ScanJob) {
        guard !job.status.isActive else { return }

        // Resolve person name for narration
        let personName: String
        if let profile = job.assignedProfile {
            personName = profile.name
        } else if let name = scanningPersonName, !name.isEmpty {
            personName = name
        } else {
            personName = "(global)"
        }

        // Build per-job settings: overlay assigned profile if present
        settings.save()
        var jobSettings = self.settings
        if let profile = job.assignedProfile {
            jobSettings.applyProfile(profile)
        }
        // Per-job engine override takes priority over profile engine
        if let engineOverride = job.assignedEngine {
            jobSettings.recognitionEngine = engineOverride
        }

        // High-level narration to videoscan.log — emitted once volume + engine
        // are known. Per-job verbose detail continues to go to the job's
        // PersistentLog.
        let volumeName = URL(fileURLWithPath: job.searchPath).lastPathComponent
        appLog.write("Starting search for \(personName) on \(volumeName) using \(jobSettings.recognitionEngine.rawValue)")

        // Pick reference faces: job-specific or global
        let faces = job.assignedProfile != nil ? job.assignedFaces : self.referenceFaces

        // Pre-flight checks (before reset clears console)
        osLog.notice("runJob: person=\(jobSettings.personName, privacy: .public) engine=\(jobSettings.recognitionEngine.rawValue, privacy: .public) folder=\(job.searchPath, privacy: .public) faces=\(faces.count) prints=\(faces.count)")

        // Volume reachability — common failure mode is targeting an offline
        // external drive. Without this check, findVideos returns 0 and the
        // user gets a confusing "No videos found" instead of "Volume offline."
        if !VolumeReachability.isReachable(path: job.searchPath) {
            let volumeName = VolumeReachability.volumeName(forPath: job.searchPath)
            let msg = "⚠ Volume \"\(volumeName)\" is offline. Mount it and try again."
            job.appendLog(msg)
            osLog.error("runJob bailed: volume offline (\(job.searchPath, privacy: .public))")
            job.status = .failed("Volume \"\(volumeName)\" offline")
            return
        }

        if jobSettings.recognitionEngine == .dlib {
            guard jobSettings.dlibReady else {
                let msg = "⚠ Set Python path and script path in Settings before scanning with dlib."
                job.appendLog(msg)
                osLog.error("runJob bailed: dlib not configured (person=\(jobSettings.personName, privacy: .public))")
                return
            }
            guard !jobSettings.referencePath.isEmpty else {
                let msg = "⚠ Set reference photos path first."
                job.appendLog(msg)
                osLog.error("runJob bailed: empty referencePath (person=\(jobSettings.personName, privacy: .public))")
                return
            }
        } else {
            guard !faces.isEmpty else {
                let msg = "⚠ Load reference photos first. Select a person with \"Find Person\" or load photos globally."
                job.appendLog(msg)
                osLog.error("runJob bailed: faces.isEmpty (person=\(jobSettings.personName, privacy: .public), engine=\(jobSettings.recognitionEngine.rawValue, privacy: .public))")
                return
            }
        }

        job.reset()
        job.status = .scanning
        osLog.info("Job started: \(job.searchPath, privacy: .public) — \(jobSettings.recognitionEngine.rawValue, privacy: .public) for \(jobSettings.personName, privacy: .public)")
        scanningPersonName = jobSettings.personName
        job.previewRate = jobSettings.previewRate
        // One log per person so a later scan of a different person can't
        // wipe the previous run's evidence. Sanitize the person name for a
        // safe filename (spaces → underscores, strip anything non-alphanum).
        let safePerson: String = {
            let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "-_"))
            let underscored = jobSettings.personName.replacingOccurrences(of: " ", with: "_")
            let scalars = underscored.unicodeScalars.filter { allowed.contains($0) }
            let s = String(String.UnicodeScalarView(scalars))
            return s.isEmpty ? "unknown" : s
        }()
        let log = PersistentLog(name: "facedetect_\(safePerson)")
        log.start()
        job.persistentLog = log
        job.appendLog("Log file: ~/Library/Logs/VideoScan/facedetect_\(safePerson).log")
        job.startElapsedTimer()

        let prints = jobSettings.recognitionEngine == .vision ? faces.map(\.featurePrint) : []
        let refFilenames = faces.map(\.sourceFilename)
        let refCacheIdentifiers = Self.referenceCacheIdentifiers(
            referencePath: jobSettings.referencePath,
            filenames: refFilenames
        )

        // Diagnostic log — after reset so these survive in the console
        job.appendLog("Build: \(BuildInfo.summary)")
        job.appendLog("Person: \(jobSettings.personName)")
        job.appendLog("Engine: \(jobSettings.recognitionEngine.title)")
        job.appendLog("  Threshold: \(String(format: "%.2f", jobSettings.threshold)), Confidence: \(String(format: "%.2f", jobSettings.minFaceConfidence))")
        job.appendLog("  FrameStep: \(jobSettings.frameStep), Concurrency: \(jobSettings.concurrency)")
        if let profile = job.assignedProfile {
            job.appendLog("  Profile rejected: \(profile.rejectedFiles.count) files")
        }
        job.appendLog("  References loaded: \(faces.count)")
        osLog.info("References ready: \(faces.count) face(s) for \(jobSettings.personName, privacy: .public)")
        job.appendLog("  Feature prints for matching: \(prints.count)")
        if jobSettings.recognitionEngine == .dlib {
            job.appendLog("  Python: \(jobSettings.pythonPath.isEmpty ? "(empty)" : jobSettings.pythonPath)")
            job.appendLog("  Script: \(jobSettings.recognitionScript.isEmpty ? "(empty)" : jobSettings.recognitionScript)")
            job.appendLog("  Ref path: \(jobSettings.referencePath.isEmpty ? "(empty)" : jobSettings.referencePath)")
        }
        let settings = jobSettings
        let dash = self.dashboard
        job.scanTask = Task { [weak self, weak job] in
            guard let job else { return }
            await MainActor.run {
                dash?.visionActive = settings.recognitionEngine == .vision || settings.recognitionEngine == .arcface
                dash?.activeEngineLabel = settings.recognitionEngine == .arcface ? "ArcFace / CoreML + ANE" : "Vision / ANE"
            }
            await PersonFinderModel.runScan(job: job, prints: prints, settings: settings, refFilenames: refCacheIdentifiers, dashboard: dash)
            await MainActor.run {
                dash?.visionActive = false; dash?.visionFPS = 0; dash?.visionMsPerFrame = 0
                // Clear scanningPersonName when no jobs are still scanning
                if let self, !self.jobs.contains(where: { $0.status == .scanning }) {
                    self.scanningPersonName = nil
                }
            }
            log.close()
        }
    }

    func stopJob(_ job: ScanJob) {
        let prev = job.status
        job.scanTask?.cancel()
        job.stopElapsedTimer()
        if prev.isActive {
            job.status = .cancelled
            job.currentFile = ""
            osLog.info("Job stopped: \(job.searchPath, privacy: .public) — was \(prev.label, privacy: .public), scanned \(job.videosScanned)/\(job.videosTotal)")
            let personName = job.assignedProfile?.name ?? "(global)"
            let volumeName = URL(fileURLWithPath: job.searchPath).lastPathComponent
            appLog.write("Stopped search for \(personName) on \(volumeName) (scanned \(job.videosScanned)/\(job.videosTotal))")
        }
    }

    func pauseJob(_ job: ScanJob) {
        guard job.status == .scanning else { return }
        Task { await job.pauseGate.pause() }
        job.status = .paused
        osLog.info("Job paused: \(job.searchPath, privacy: .public)")
        let personName = job.assignedProfile?.name ?? "(global)"
        let volumeName = URL(fileURLWithPath: job.searchPath).lastPathComponent
        appLog.write("Paused search for \(personName) on \(volumeName)")
    }

    func resumeJob(_ job: ScanJob) {
        guard job.status == .paused else { return }
        Task { await job.pauseGate.resume() }
        job.status = .scanning
        osLog.info("Job resumed: \(job.searchPath, privacy: .public)")
        let personName = job.assignedProfile?.name ?? "(global)"
        let volumeName = URL(fileURLWithPath: job.searchPath).lastPathComponent
        appLog.write("Resumed search for \(personName) on \(volumeName)")
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
        // Load faces for jobs with assigned profiles that don't have faces yet
        Task {
            for job in jobs where job.status.isIdle && job.assignedProfile != nil && job.assignedFaces.isEmpty {
                await loadFacesForJob(job)
            }
            for job in jobs where job.status.isIdle { startJob(job) }
        }
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

    // MARK: - Compilation (on-demand)

    @Published var compilationSettings = CompilationSettings.restored() {
        didSet { compilationSettings.save() }
    }

    func startCompilation(job: ScanJob) {
        guard job.status.isDone else { return }
        guard !job.recognitionResults.isEmpty else {
            job.appendLog("⚠ No recognition results to compile.")
            return
        }
        guard !job.compilationStatus.isActive else { return }

        let results = job.recognitionResults
        let outputDir = job.recognitionOutputDir
        let personName = job.assignedProfile?.name ?? "Unknown"
        let compSettings = compilationSettings
        let scanSettings = settings
        let totalSegs = results.reduce(0) { $0 + $1.segments.count }
        osLog.info("Compilation started: person=\(personName, privacy: .public) mode=\(compSettings.mode.rawValue, privacy: .public) segments=\(totalSegs) videos=\(results.count)")

        job.compilationStatus = .extracting
        job.compilationProgress = 0
        job.compilationPhase = "Extracting clips…"
        job.compilationClipsTotal = results.reduce(0) { $0 + $1.segments.count }
        job.compilationClipsDone = 0
        job.compiledVideoPaths = []
        job.appendLog("\n━ Compilation started ━━━━━━━━━━━━━━━━━━━━━")

        job.compilationTask = Task.detached(priority: .userInitiated) {
            await Self.runCompilation(
                job: job,
                results: results,
                outputDir: outputDir,
                personName: personName,
                compilationSettings: compSettings,
                scanSettings: scanSettings
            )
        }
    }

    func cancelCompilation(job: ScanJob) {
        osLog.info("Compilation cancelled by user")
        job.compilationTask?.cancel()
        job.compilationStatus = .idle
        job.compilationPhase = ""
        job.compilationProgress = 0
    }

    private nonisolated static func runCompilation(
        job: ScanJob,
        results: [pfVideoResult],
        outputDir: String,
        personName: String,
        compilationSettings: CompilationSettings,
        scanSettings: PersonFinderSettings
    ) async {
        let totalClips = results.reduce(0) { $0 + $1.segments.count }
        osLog.info("Extraction phase: \(totalClips) clip(s) from \(results.count) video(s) → \(outputDir, privacy: .public)")
        await job.appendLog("Extracting \(totalClips) clip(s) to: \(outputDir)")

        var workResults = results
        var clipsDone = 0
        let clipTotal = totalClips

        for i in 0..<workResults.count {
            if Task.isCancelled {
                await MainActor.run { job.compilationStatus = .idle; job.compilationPhase = "Cancelled" }
                return
            }
            let r = workResults[i]
            let segCount = r.segments.count
            if segCount == 0 { continue }

            await MainActor.run {
                job.compilationPhase = "Extracting from \(r.filename) (\(clipsDone + 1)–\(clipsDone + segCount) of \(clipTotal))"
            }

            // Extract clips for this single video result
            var single = [workResults[i]]
            await pfExtractAllClips(
                results: &single, personName: personName,
                outputDir: outputDir, concurrency: compilationSettings.concurrency,
                logFn: { line in await job.appendLog(line) }
            )
            workResults[i] = single[0]
            clipsDone += segCount
            await MainActor.run {
                job.compilationClipsDone = clipsDone
                job.compilationProgress = Double(clipsDone) / Double(clipTotal)
            }
        }

        if Task.isCancelled {
            await MainActor.run { job.compilationStatus = .idle; job.compilationPhase = "Cancelled" }
            return
        }

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
        let foundClips = workResults.reduce(0) { $0 + $1.clipFiles.filter { !$0.isEmpty }.count }
        osLog.info("Extraction done: \(foundClips) clip file(s) — entering compile phase")

        await MainActor.run {
            job.results = clipResults
            job.clipsFound = foundClips
        }

        let allClipPaths = workResults.flatMap(\.clipFiles).filter { !$0.isEmpty }
            .map { (outputDir as NSString).appendingPathComponent($0) }

        let compiled = await compileAndCleanup(
            workResults: workResults,
            foundClips: foundClips,
            compilationSettings: compilationSettings,
            personName: personName,
            outputDir: outputDir,
            allClipPaths: allClipPaths,
            job: job
        )

        await MainActor.run {
            job.compiledVideoPaths = compiled
            job.compilationStatus = .done
            job.compilationProgress = 1.0
            let totalDur = compiled.reduce(0.0) { $0 + $1.durationSecs }
            job.compilationPhase = compiled.isEmpty
                ? "No clips to compile"
                : "\(compiled.count) video(s), \(pfFormatDuration(totalDur))"
            job.appendLog("\n━ Compilation complete: \(compiled.count) output(s), \(foundClips) clip(s) ━")
        }
        let totalBytes = compiled.reduce(Int64(0)) { $0 + $1.bytesOnDisk }
        osLog.info("Compilation done: \(compiled.count) output(s), \(foundClips) clip(s), \(totalBytes) bytes on disk")
    }

    // MARK: Reference loading

    /// Append reference photos from `path` to the existing pool (does not clear previous loads).
    func loadReference(from path: String? = nil) async {
        let p = path ?? settings.referencePath
        guard !p.isEmpty else { referenceLoadError = "No reference path set."; return }

        isLoadingReference = true
        referenceLoadError = nil

        let largestOnly = settings.largestFaceOnly
        let rejected = Set(settings.rejectedReferenceFiles)
        let (faces, failures, errMsg) = await Task.detached(priority: .userInitiated) {
            pfLoadReferencePhotos(from: p, largestFaceOnly: largestOnly)
        }.value

        // Surface load failures (photos that couldn't produce a face)
        let newFailures = rejected.isEmpty
            ? failures
            : failures.filter { !rejected.contains($0.filename) }
        referenceLoadFailures.append(contentsOf: newFailures)

        if let err = errMsg {
            referenceLoadError = err
        } else {
            let filtered = rejected.isEmpty ? faces : faces.filter { !rejected.contains($0.sourceFilename) }
            referenceFaces.append(contentsOf: filtered)
            let label = (p as NSString).lastPathComponent
            if !referenceSources.contains(label) { referenceSources.append(label) }
            // "N previously removed" was noise — rejected photos are a user
            // choice, not an error condition worth surfacing. Only the "no
            // usable face" count matters (that one signals broken photos).
            if !newFailures.isEmpty {
                referenceLoadError = "\(newFailures.count) photo(s) had no usable face"
            }
        }
        isLoadingReference = false
    }

    func removeReferenceFace(id: UUID) {
        if let face = referenceFaces.first(where: { $0.id == id }) {
            settings.rejectedReferenceFiles.append(face.sourceFilename)
            settings.save()
        }
        referenceFaces.removeAll { $0.id == id }
        if referenceFaces.isEmpty { referenceSources = [] }
        syncRejectionsToProfile()
    }

    func removeReferenceFaces(belowConfidence threshold: Float) {
        let rejected = referenceFaces.filter { $0.confidence < threshold }.map(\.sourceFilename)
        settings.rejectedReferenceFiles.append(contentsOf: rejected)
        settings.save()
        referenceFaces.removeAll { $0.confidence < threshold }
        if referenceFaces.isEmpty { referenceSources = [] }
        syncRejectionsToProfile()
    }

    /// Sync the current rejection list back to the active POI profile on disk.
    private func syncRejectionsToProfile() {
        let name = settings.personName
        guard !name.isEmpty,
              var profile = savedProfiles.first(where: { $0.name.lowercased() == name.lowercased() })
        else { return }
        profile.rejectedFiles = settings.rejectedReferenceFiles
        try? profile.save()
        savedProfiles = POIProfile.listAll()
    }

    func clearReference() {
        referenceFaces = []
        referenceSources = []
        referenceLoadError = nil
        referenceLoadFailures = []
        settings.referencePath = ""
        settings.rejectedReferenceFiles = []
        settings.save()
    }

    // MARK: - POI Profile management

    @Published var savedProfiles: [POIProfile] = POIProfile.listAll()

    func saveCurrentPOI() {
        let cover = POIProfile.bestCoverFilename(from: referenceFaces)
        let profile = settings.toProfile(coverImageFilename: cover)
        guard !profile.name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        try? profile.save()
        savedProfiles = POIProfile.listAll()
        referenceLoadError = nil   // clear stale info messages
    }

    func loadPOI(_ profile: POIProfile) async {
        // Clear current reference state
        referenceFaces = []
        referenceSources = []
        referenceLoadError = nil

        // Apply profile to settings
        settings.applyProfile(profile)
        settings.save()

        // Reload reference photos for this person
        if !settings.referencePath.isEmpty {
            await loadReference()
        }
    }

    /// Save an edited profile back to disk and refresh the gallery.
    /// If the name changed, delete the old file first.
    func updateProfile(_ updated: POIProfile, oldName: String? = nil) {
        if let old = oldName, old.lowercased() != updated.name.lowercased() {
            try? POIProfile.delete(name: old)
        }
        try? updated.save()
        savedProfiles = POIProfile.listAll()

        // If the edited person is the currently active one, sync settings
        if settings.personName.lowercased() == (oldName ?? updated.name).lowercased() {
            settings.applyProfile(updated)
            settings.save()
        }
    }

    func deletePOI(_ profile: POIProfile) {
        try? POIProfile.delete(name: profile.name)
        savedProfiles = POIProfile.listAll()
    }

    func reorderProfiles(fromID: String, toID: String) {
        guard fromID != toID,
              let fromIdx = savedProfiles.firstIndex(where: { $0.id == fromID }),
              let toIdx = savedProfiles.firstIndex(where: { $0.id == toID })
        else { return }
        let moving = savedProfiles.remove(at: fromIdx)
        savedProfiles.insert(moving, at: toIdx)
        for i in savedProfiles.indices {
            savedProfiles[i].sortOrder = i
            try? savedProfiles[i].save()
        }
    }

    // MARK: Core scan (nonisolated — runs on cooperative thread pool, NOT on MainActor)

    /// Resolve the effective output directory — user-provided path, or
    /// `~/Desktop/<person>_clips` when the setting is blank.
    private nonisolated static func resolveOutputDir(_ settings: PersonFinderSettings) -> String {
        let override = settings.outputDir
        if !override.isEmpty { return override }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop")
            .appendingPathComponent("\(pfSanitize(settings.personName))_clips")
            .path
    }

    /// Partition scan results by the configured min-presence threshold.
    /// Returns (kept, skippedCount). `skipped` counts non-empty results that
    /// fell below the threshold — empty-segment entries are already excluded.
    private nonisolated static func filterByPresence(
        _ ordered: [pfVideoResult?],
        settings: PersonFinderSettings
    ) -> (valid: [pfVideoResult], skipped: Int) {
        let nonNil = ordered.compactMap { $0 }
        let minSecs = settings.minPresenceSecs
        let valid = nonNil.filter { minSecs <= 0 || $0.totalPresenceSecs >= minSecs }
        let skipped = nonNil.filter {
            minSecs > 0 && $0.totalPresenceSecs < minSecs && !$0.segments.isEmpty
        }.count
        return (valid, skipped)
    }

    /// Drive the parallel scan of every discovered video. Returns the
    /// index-preserving `[pfVideoResult?]` array the caller will filter.
    /// Extracted so `runScan` stays focused on phase sequencing.
    private nonisolated static func scanAllVideos(
        videoFiles: [String],
        prints: [VNFeaturePrintObservation],
        settings: PersonFinderSettings,
        refFilenames: [String],
        job: ScanJob,
        dash: DashboardState?
    ) async -> [pfVideoResult?] {
        let total = videoFiles.count
        var orderedResults = [pfVideoResult?](repeating: nil, count: total)

        // Cache summary — so the user can see how many will be fast (cached) vs slow (new)
        let cacheThreshold = settings.recognitionEngine == .arcface
            ? settings.arcfaceThreshold : settings.threshold
        var cachedCount = 0
        for path in videoFiles {
            if let key = PersonFinderCache.makeKey(
                videoPath: path, personName: settings.personName,
                engine: settings.recognitionEngine, threshold: cacheThreshold,
                refFilenames: refFilenames
            ), PersonFinderCache.shared.lookup(key: key) != nil {
                cachedCount += 1
            }
        }
        let toProcess = total - cachedCount
        await job.appendLog("Cache: \(cachedCount)/\(total) cached, \(toProcess) to process")

        // Start serialized disk feeder for slow volumes (external HDD/USB/SMB).
        // One thread reads sequentially at full bandwidth; workers wait for warm pages.
        let feeder: DiskFeeder?
        if let firstFile = videoFiles.first,
           VolumeSpeed.detect(path: firstFile) == .slow {
            let skipCheck: @Sendable (String) -> Bool = { path in
                guard let key = PersonFinderCache.makeKey(
                    videoPath: path, personName: settings.personName,
                    engine: settings.recognitionEngine, threshold: cacheThreshold,
                    refFilenames: refFilenames
                ) else { return false }
                return PersonFinderCache.shared.lookup(key: key) != nil
            }
            let f = DiskFeeder(files: videoFiles, budgetBytes: PageCacheWarmer.budgetBytes, shouldSkip: skipCheck)
            await f.start()
            feeder = f
            await job.appendLog("Disk feeder: warming files sequentially for \(total) video(s) on slow volume")
        } else {
            feeder = nil
        }

        // Hoisted so each completed-video result can be turned into a
        // ClipResult and appended to job.results live (see below).
        let liveOutputDir = resolveOutputDir(settings)
        let minPresence = settings.minPresenceSecs

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
                group.addTask {
                    return await processOneVideo(
                        idx: i, videoFiles: videoFiles, prints: prints,
                        settings: settings, refFilenames: refFilenames,
                        total: total, job: job, dash: dash,
                        feeder: feeder
                    )
                }
                submitted += 1
            }

            for await (idx, result) in group {
                if Task.isCancelled { break }
                orderedResults[idx] = result
                // Build the per-video row up-front (outside MainActor.run) so
                // the hop into MainActor stays a quick assignment. Same
                // shape and presence gate as the post-loop batch publish in
                // runScan, so a row appearing live is the same row that
                // ends up in the final ordered list.
                let liveRow: ClipResult? = {
                    guard let r = result, !r.segments.isEmpty else { return nil }
                    guard minPresence <= 0 || r.totalPresenceSecs >= minPresence else { return nil }
                    return ClipResult(
                        videoFilename: r.filename,
                        videoPath: r.filePath,
                        videoDuration: r.durationSeconds,
                        presenceSecs: r.totalPresenceSecs,
                        segmentCount: r.segments.count,
                        bestDistance: r.segments.map(\.bestDistance).min() ?? 0,
                        clipFiles: [],
                        outputDir: liveOutputDir
                    )
                }()
                await MainActor.run {
                    job.videosScanned += 1
                    job.progress = Double(job.videosScanned) / Double(job.videosTotal)
                    if let r = result, !r.segments.isEmpty {
                        job.videosWithHits += 1
                        dash?.lastMatchFlashAt = Date()
                    }
                    // Live-append: completion-order during the scan; the
                    // post-loop batch publish at runScan replaces this with
                    // the canonical idx-ordered list.
                    if let row = liveRow {
                        job.results.append(row)
                    }
                }
                if submitted < total {
                    let nextIdx = submitted
                    group.addTask {
                        return await processOneVideo(
                            idx: nextIdx, videoFiles: videoFiles, prints: prints,
                            settings: settings, refFilenames: refFilenames,
                            total: total, job: job, dash: dash,
                            feeder: feeder
                        )
                    }
                    submitted += 1
                }
            }
        }

        // Clean up feeder
        if let feeder = feeder {
            await feeder.cancel()
            let warmed = await feeder.bytesWarmed
            let skipped = await feeder.skippedCount
            await job.appendLog("Disk feeder done: \(warmed / (1024*1024*1024))GB warmed, \(skipped) files cache-skipped")
        }

        return orderedResults
    }

    // swiftlint:disable:next function_parameter_count
    private nonisolated static func processOneVideo(
        idx: Int, videoFiles: [String], prints: [VNFeaturePrintObservation],
        settings: PersonFinderSettings, refFilenames: [String],
        total: Int,
        job: ScanJob, dash: DashboardState?,
        feeder: DiskFeeder? = nil
    ) async -> (Int, pfVideoResult?) {
        await job.pauseGate.waitIfPaused()
        if Task.isCancelled { return (idx, nil) }

        let filePath = videoFiles[idx]
        let threshold = settings.recognitionEngine == .arcface
            ? settings.arcfaceThreshold : settings.threshold

        // Cache check BEFORE waiting for disk warm — cache hits skip I/O entirely
        if let cacheKey = PersonFinderCache.makeKey(
            videoPath: filePath, personName: settings.personName,
            engine: settings.recognitionEngine,
            threshold: threshold, refFilenames: refFilenames
        ), let cached = PersonFinderCache.shared.lookup(key: cacheKey) {
            let tag = cached.segments.isEmpty ? "no hits" : "\(cached.segments.count) segment(s)"
            await job.appendLog("[\(idx + 1)/\(total)] \((filePath as NSString).lastPathComponent) — cache hit (\(tag))")
            return (idx, cached)
        }

        // Cache miss — wait for disk feeder to warm this file before proceeding
        await feeder?.waitForWarm(idx)

        await MemoryPressureMonitor.shared.acquireWorkerSlot(
            requested: settings.concurrency,
            engine: settings.recognitionEngine
        )
        defer { Task { await MemoryPressureMonitor.shared.decrementWorkers() } }

        let logFn: @Sendable (String) async -> Void = { line in await job.appendLog(line) }
        let progressState = ThrottledMainActorUpdate(intervalSecs: 0.25)
        let progressFn: @Sendable (String) async -> Void = { file in
            await progressState.update { job.currentFile = file }
        }
        let distFn: @Sendable (Float) async -> Void = { dist in
            await progressState.update { if dist < job.bestDist { job.bestDist = dist } }
        }

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

        @Sendable func runArcFace() async -> pfVideoResult? {
            await pfRunArcFaceEngine(
                filePath: videoFiles[idx], idx1: idx + 1, total: total,
                settings: settings, job: job, dash: dash,
                progressState: progressState,
                logFn: logFn, progressFn: progressFn, distFn: distFn
            )
        }

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
        case .vision:  r = await runVision()
        case .arcface: r = await runArcFace()
        case .dlib:    r = await runDlib()
        case .hybrid:
            let v = await runVision()
            if let v, !v.segments.isEmpty {
                r = v
            } else if !settings.dlibReadyForHybrid {
                await job.appendLog("[hybrid] Vision: 0 hits — dlib not configured, skipping fallback")
                r = v
            } else {
                await job.appendLog("[hybrid] Vision: 0 hits — falling back to dlib")
                r = await runDlib()
            }
        }

        if let cacheKey = PersonFinderCache.makeKey(
            videoPath: filePath, personName: settings.personName,
            engine: settings.recognitionEngine,
            threshold: threshold, refFilenames: refFilenames
        ) {
            if let r {
                PersonFinderCache.shared.store(key: cacheKey, result: r)
            } else if !Task.isCancelled {
                let skip = pfVideoResult(
                    filename: (filePath as NSString).lastPathComponent,
                    filePath: filePath, durationSeconds: 0, fps: 0,
                    totalHits: 0, segments: []
                )
                PersonFinderCache.shared.store(key: cacheKey, result: skip)
                await job.appendLog("  [\(idx + 1)/\(total)] \((filePath as NSString).lastPathComponent) — cached as unreadable")
            }
        }

        return (idx, r)
    }

    /// Discover and catalog-filter video files for a job. Returns nil (and sets
    /// .failed on the job) if nothing is scannable; the caller should bail out.
    private nonisolated static func discoverVideos(
        job: ScanJob,
        settings: PersonFinderSettings
    ) async -> [String]? {
        let path = await job.searchPath
        let skipBundles = settings.skipBundles
        // Task.detached so blocking FileManager calls don't stall the cooperative
        // thread pool (critical for network volumes).
        var videoFiles = await Task.detached(priority: .userInitiated) {
            pfFindVideoFiles(at: path, skipBundles: skipBundles)
        }.value
        guard !videoFiles.isEmpty else {
            await job.appendLog("No video files found.")
            osLog.error("Scan bailed: no videos found in \(path, privacy: .public)")
            await MainActor.run { job.status = .failed("No videos found"); job.stopElapsedTimer() }
            return nil
        }

        // Catalog prefilter (issue #66) — uses all available catalog metadata
        // to avoid expensive Vision/ArcFace work on files we already know
        // about. Categories: unscannable (audio-only/broken), already-known
        // (target in detectedPeople from prior scan), junk-scored, too-short,
        // low-resolution.
        if settings.skipCatalogBadFiles {
            let targetName = await MainActor.run { job.personLabel }
            let skipResult = await MainActor.run {
                pfPersonScanSkipResult(targetPersonName: targetName)
            }
            let allSkip = skipResult.all
            if !allSkip.isEmpty {
                let before = videoFiles.count
                videoFiles.removeAll { allSkip.contains($0) }
                let skipped = before - videoFiles.count
                if skipped > 0 {
                    var parts: [String] = []
                    if !skipResult.unscannable.isEmpty {
                        parts.append("\(skipResult.unscannable.count) unscannable")
                    }
                    if !skipResult.alreadyKnown.isEmpty {
                        parts.append("\(skipResult.alreadyKnown.count) already-known for \(targetName)")
                    }
                    if !skipResult.junkScored.isEmpty {
                        parts.append("\(skipResult.junkScored.count) junk-scored")
                    }
                    if !skipResult.tooShort.isEmpty {
                        parts.append("\(skipResult.tooShort.count) too-short")
                    }
                    if !skipResult.lowResolution.isEmpty {
                        parts.append("\(skipResult.lowResolution.count) low-resolution")
                    }
                    let detail = parts.isEmpty ? "" : " (\(parts.joined(separator: ", ")))"
                    await job.appendLog("Catalog prefilter skipped \(skipped) file(s)\(detail)")
                }
                if videoFiles.isEmpty {
                    await job.appendLog("No scannable video files remain after catalog filter.")
                    osLog.error("Scan bailed: catalog filter removed all videos in \(path, privacy: .public)")
                    await MainActor.run { job.status = .failed("All files filtered by catalog"); job.stopElapsedTimer() }
                    return nil
                }
            }
        }

        await MainActor.run {
            job.videosTotal = videoFiles.count
            job.appendLog("Found \(videoFiles.count) video(s)\n")
        }
        return videoFiles
    }

    /// Build bucketed compilations and remove now-redundant intermediate clips.
    /// Returns the compiled outputs (empty if compilation was not requested or produced nothing).
    private nonisolated static func compileAndCleanup(
        workResults: [pfVideoResult],
        foundClips: Int,
        compilationSettings: CompilationSettings,
        personName: String,
        outputDir: String,
        allClipPaths: [String],
        job: ScanJob
    ) async -> [CompiledOutput] {
        guard foundClips > 0 else { return [] }

        let df = DateFormatter(); df.dateFormat = "yyyyMMdd_HHmmss"
        let stamp = df.string(from: Date())
        let name = pfSanitize(personName)
        await job.appendLog("\nBuilding compatibility-bucketed compilations…")
        await MainActor.run { job.compilationStatus = .compiling; job.compilationProgress = 0; job.compilationPhase = "Building compilations…" }
        let bucketCompiled = await pfCompileBuckets(
            results: workResults,
            outputDir: outputDir,
            jobName: name,
            stamp: stamp,
            logFn: { line in await job.appendLog(line) }
        )

        var compiled = bucketCompiled
        if bucketCompiled.count > 1 && compilationSettings.mode == .singleVideo {
            await MainActor.run { job.compilationStatus = .merging; job.compilationProgress = 0; job.compilationPhase = "Merging \(bucketCompiled.count) bucket(s) into single file…" }
            await job.appendLog("\nMerging \(bucketCompiled.count) bucket(s) into a single compilation…")
            let mergedName = "\(name)_compilation_\(stamp).mp4"
            let mergedPath = (outputDir as NSString).appendingPathComponent(mergedName)
            if await pfMergeBucketsToSingleFile(
                bucketPaths: bucketCompiled.map(\.path),
                outputPath: mergedPath,
                logFn: { line in await job.appendLog(line) }
            ) {
                let fm = FileManager.default
                let totalDur = bucketCompiled.reduce(0.0) { $0 + $1.durationSecs }
                let totalClips = bucketCompiled.reduce(0) { $0 + $1.clipCount }
                for b in bucketCompiled { try? fm.removeItem(atPath: b.path) }
                compiled = [CompiledOutput(
                    path: mergedPath,
                    label: "merged",
                    clipCount: totalClips,
                    durationSecs: totalDur,
                    bytesOnDisk: pfFileSize(at: mergedPath)
                )]
                await job.appendLog("  ✓ Merged into \(mergedName) (\(pfFormatDuration(totalDur)))")
            } else {
                await job.appendLog("  ⚠ Merge failed; keeping \(bucketCompiled.count) bucket files as fallback")
            }
        }

        if !compiled.isEmpty {
            let outputPaths = Set(compiled.map(\.path))
            let fm = FileManager.default
            var removed = 0
            for clipPath in allClipPaths where !outputPaths.contains(clipPath) {
                try? fm.removeItem(atPath: clipPath)
                removed += 1
            }
            await job.appendLog("  Cleaned up \(removed) intermediate clip file(s)")
        }
        return compiled
    }

    private nonisolated static func runScan(
        job: ScanJob,
        prints: [VNFeaturePrintObservation],
        settings: PersonFinderSettings,
        refFilenames: [String],
        dashboard: DashboardState?
    ) async {
        let path = await job.searchPath
        await job.appendLog("Scanning: \(path)")
        PersonFinderCache.shared.resetStats()

        guard let videoFiles = await discoverVideos(job: job, settings: settings) else { return }

        if Task.isCancelled {
            osLog.info("Job cancelled before scan: \(path, privacy: .public)")
            await MainActor.run { job.status = .cancelled; job.currentFile = ""; job.stopElapsedTimer() }
            return
        }

        let orderedResults = await scanAllVideos(
            videoFiles: videoFiles, prints: prints,
            settings: settings, refFilenames: refFilenames,
            job: job, dash: dashboard
        )

        if Task.isCancelled {
            let (scanned, total) = await MainActor.run { (job.videosScanned, job.videosTotal) }
            osLog.info("Job cancelled after scan: \(path, privacy: .public) — scanned \(scanned)/\(total)")
            await MainActor.run { job.status = .cancelled; job.currentFile = ""; job.stopElapsedTimer() }
            return
        }

        // Presence filter
        let (validResults, skipped) = filterByPresence(orderedResults, settings: settings)
        if skipped > 0 {
            await job.appendLog("\nPresence filter: \(validResults.count) kept, \(skipped) below \(Int(settings.minPresenceSecs))s\n")
        }

        let outputDir = resolveOutputDir(settings)

        // Preliminary results — published BEFORE extraction so the user
        // sees the per-video matches table immediately when scanning ends,
        // not after several minutes of clip extraction. Each row has the
        // filename, hits, presence time, and best cosine; only `clipFiles`
        // is empty (no extracted-clip paths yet) and gets filled in by
        // the second publish below after extraction runs.
        let preliminaryResults: [ClipResult] = validResults.compactMap { r -> ClipResult? in
            guard !r.segments.isEmpty else { return nil }
            return ClipResult(
                videoFilename: r.filename,
                videoPath: r.filePath,
                videoDuration: r.durationSeconds,
                presenceSecs: r.totalPresenceSecs,
                segmentCount: r.segments.count,
                bestDistance: r.segments.map(\.bestDistance).min() ?? 0,
                clipFiles: [],
                outputDir: outputDir
            )
        }
        let preliminaryPresence = validResults.map(\.totalPresenceSecs).reduce(0, +)
        await MainActor.run {
            job.results = preliminaryResults
            job.presenceSecs = preliminaryPresence
        }
        let totalSegments = validResults.reduce(0) { $0 + $1.segments.count }
        PersonFinderCache.shared.logSummary()
        osLog.notice("Scan complete: \(preliminaryResults.count) video(s) with hits, \(totalSegments) segment(s), \(pfFormatDuration(preliminaryPresence), privacy: .public) presence — ready for compilation")

        // Store recognition data for on-demand compilation later
        await MainActor.run {
            let wasCancelled = job.status == .cancelled
            job.recognitionResults = validResults
            job.recognitionOutputDir = outputDir
            job.clipsFound = totalSegments
            job.currentFile = ""
            if wasCancelled {
                job.appendLog("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                job.appendLog("Stopped. Scanned \(job.videosScanned)/\(job.videosTotal) video(s), \(job.videosWithHits) with hits, \(totalSegments) segment(s).")
            } else {
                job.videosScanned = job.videosTotal
                job.finalizeResults(preliminaryResults)
                job.status = .done
                job.progress = 1.0
                job.stopElapsedTimer()
                // Same sentence the UI shows on the collapsed/expanded row
                // (see ScanJobRow.summaryText) — mirrored to the OS log so
                // an agent reading `log stream` sees what the user sees.
                // hits = unique videos that matched (= job.results.count),
                // not the running videosWithHits counter, which we've seen
                // diverge under multi-segment / cache-restored conditions.
                let hits = job.results.count
                let total = job.videosTotal
                let elapsedMin = Int(job.elapsedSecs) / 60
                let elapsedSec = Int(job.elapsedSecs) % 60
                let elapsed = "\(elapsedMin)m \(elapsedSec)s"
                let volumeName = VolumeReachability.volumeName(forPath: job.searchPath)
                let onVol = volumeName.isEmpty ? "" : " on \(volumeName)"
                let stats = "(Searched \(total) total file\(total == 1 ? "" : "s"). Elapsed time \(elapsed))"
                let person = job.personLabel
                let summary: String
                if hits > 0 {
                    summary = "Search Complete: Found \(person) in \(hits) file\(hits == 1 ? "" : "s")\(onVol). \(stats)"
                } else {
                    summary = "Search Complete: Found no matches for \(person)\(onVol). \(stats)"
                }
                osLog.info("\(summary, privacy: .public)")
                pfScanLog.info("\(summary, privacy: .public)")
                job.appendLog("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                job.appendLog(summary)
                job.appendLog("Done. \(job.videosWithHits) video(s) with hits, \(totalSegments) segment(s), \(pfFormatDuration(preliminaryPresence)) total presence.")
                if totalSegments > 0 {
                    job.appendLog("Use Create Composite Video to extract and compile clips.")
                }
            }
        }
    }
}

// Shared CIContext — expensive to create, reuse across calls
private let pfCIContext = CIContext(options: [.useSoftwareRenderer: false])

// MARK: - Reference photo loading

// Returns ([ReferenceFace], errorMessage) — errorMessage is nil on success.
private nonisolated func pfLoadReferencePhotos(from path: String, largestFaceOnly: Bool) -> ([ReferenceFace], [ReferenceLoadFailure], String?) {
    let fm = FileManager.default
    let imageExts: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "bmp", "gif"]
    var imagePaths: [String] = []
    var isDir: ObjCBool = false
    fm.fileExists(atPath: path, isDirectory: &isDir)
    if isDir.boolValue {
        guard let e = fm.enumerator(atPath: path) else { return ([], [], "Cannot enumerate \(path)") }
        while let el = e.nextObject() as? String {
            if imageExts.contains((el as NSString).pathExtension.lowercased()) {
                imagePaths.append((path as NSString).appendingPathComponent(el))
            }
        }
        imagePaths.sort()
    } else {
        imagePaths = [path]
    }
    guard !imagePaths.isEmpty else { return ([], [], "No images found in \(path)") }

    var faces: [ReferenceFace] = []
    var failures: [ReferenceLoadFailure] = []
    for imgPath in imagePaths {
        let filename = (imgPath as NSString).lastPathComponent
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: imgPath) as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            failures.append(ReferenceLoadFailure(filename: filename, reason: "Could not read image"))
            continue
        }
        let req = VNDetectFaceRectanglesRequest(); req.revision = 3
        let handler = VNImageRequestHandler(cgImage: img, options: [:])
        do {
            try handler.perform([req])
        } catch {
            failures.append(ReferenceLoadFailure(filename: filename, reason: "Vision error: \(error.localizedDescription)"))
            continue
        }

        let allResults = req.results ?? []
        if allResults.isEmpty {
            failures.append(ReferenceLoadFailure(filename: filename, reason: "No face detected"))
            continue
        }

        var candidates = allResults.filter { $0.confidence >= 0.5 }
        if candidates.isEmpty {
            let best = allResults.map { $0.confidence }.max() ?? 0
            failures.append(ReferenceLoadFailure(filename: filename, reason: "Face confidence too low (\(Int(best * 100))%)"))
            continue
        }

        if largestFaceOnly, let largest = candidates.max(by: {
            ($0.boundingBox.width * $0.boundingBox.height) < ($1.boundingBox.width * $1.boundingBox.height)
        }) { candidates = [largest] }

        var addedFromThisImage = false
        for obs in candidates {
            guard let cropped = pfNormalizeFaceCrop(from: img, observation: obs),
                  let fp = pfGenerateFeaturePrint(for: cropped) else { continue }
            let face = ReferenceFace(
                featurePrint: fp,
                thumbnail: cropped,
                sourceFilename: filename,
                confidence: obs.confidence,
                rollDeg: (obs.roll?.doubleValue ?? 0) * 180 / .pi,
                yawDeg: (obs.yaw?.doubleValue ?? 0) * 180 / .pi,
                pitchDeg: (obs.pitch?.doubleValue ?? 0) * 180 / .pi,
                faceAreaPct: Float(obs.boundingBox.width * obs.boundingBox.height * 100)
            )
            faces.append(face)
            addedFromThisImage = true
        }
        if !addedFromThisImage {
            failures.append(ReferenceLoadFailure(filename: filename, reason: "Face crop or feature print failed"))
        }
    }
    guard !faces.isEmpty else { return ([], failures, "No faces detected in reference photos") }
    return (faces, failures, nil)
}

// MARK: - Catalog skip set, person-scan prefilter, video discovery
// Moved to PersonFinderCatalogFilter.swift (step 2 of 6 PersonFinderModel split).

// MARK: - Face detection utilities

private func pfDetectFaces(in image: CGImage) -> [VNFaceObservation] {
    let req = VNDetectFaceRectanglesRequest(); req.revision = 3
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    try? handler.perform([req])
    return (req.results ?? []).sorted { $0.confidence > $1.confidence }
}

nonisolated func pfNormalizeFaceCrop(from source: CGImage, observation: VNFaceObservation, outputSize: Int = 256) -> CGImage? {
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
nonisolated func pfOrientationFromTransform(_ t: CGAffineTransform) -> CGImagePropertyOrientation {
    switch (t.a, t.b, t.c, t.d) {
    case (0, 1, -1, 0): return .right  // 90° CW  — phone portrait, home-button right
    case (0, -1, 1, 0): return .left   // 90° CCW — phone portrait, home-button left
    case (-1, 0, 0, -1): return .down  // 180°    — upside down
    default:              return .up     // identity / landscape
    }
}

/// Phase-1 face detection: run Vision directly on the CVPixelBuffer (no CGImage needed).
/// Vision handles YpCbCr natively and dispatches to the Neural Engine / ANE.
nonisolated func pfDetectFacesInBuffer(_ buffer: CVPixelBuffer,
                                      orientation: CGImagePropertyOrientation) -> [VNFaceObservation] {
    let req = VNDetectFaceRectanglesRequest(); req.revision = 3
    let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: orientation, options: [:])
    try? handler.perform([req])
    return (req.results ?? []).sorted { $0.confidence > $1.confidence }
}

/// Phase-2 image: apply the track's preferredTransform so the CGImage is right-side-up,
/// matching the oriented coordinate space Vision used for bounding boxes.
nonisolated func pfOrientedCGImage(from buffer: CVPixelBuffer,
                                           transform: CGAffineTransform) -> CGImage? {
    var ci = CIImage(cvPixelBuffer: buffer).transformed(by: transform)
    // Transform may shift the extent off-origin — translate back to (0,0)
    ci = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.origin.x,
                                               y: -ci.extent.origin.y))
    return pfCIContext.createCGImage(ci, from: ci.extent)
}

// MARK: - Video processing

/// Bundle of reader + track metadata returned by `pfOpenVisionVideoReader`.
private struct PFVisionReaderContext {
    let asset: AVURLAsset
    let reader: AVAssetReader
    let trackOutput: AVAssetReaderTrackOutput
    let duration: Double
    let fps: Double
    let orientation: CGImagePropertyOrientation
    let transform: CGAffineTransform
}

/// Open and validate the video asset, returning a fully configured reader or
/// logging + returning nil on any failure. Mirrors `openArcFaceVideoReader`.
private func pfOpenVisionVideoReader(
    filePath: String,
    filename: String,
    index: Int,
    total: Int,
    logFn: @escaping @Sendable (String) async -> Void
) async -> PFVisionReaderContext? {
    let fileURL = URL(fileURLWithPath: filePath)

    let asset = AVURLAsset(url: fileURL,
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
    guard duration > 0, fps > 0, Int(duration * fps) > 0 else { return nil }

    let preferredTransform: CGAffineTransform
    do { preferredTransform = try await videoTrack.load(.preferredTransform) } catch {
        await logFn("[\(index)/\(total)] \(filename) — skipped (can't load transform)")
        return nil
    }

    let reader: AVAssetReader
    do { reader = try AVAssetReader(asset: asset) } catch {
        await logFn("[\(index)/\(total)] \(filename) — skipped (AVAssetReader: \(error.localizedDescription))")
        return nil
    }
    let trackOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    ])
    trackOutput.alwaysCopiesSampleData = false
    reader.add(trackOutput)
    guard reader.startReading() else {
        await logFn("[\(index)/\(total)] \(filename) — skipped (AVAssetReader failed to start)")
        return nil
    }

    return PFVisionReaderContext(
        asset: asset,
        reader: reader,
        trackOutput: trackOutput,
        duration: duration,
        fps: fps,
        orientation: pfOrientationFromTransform(preferredTransform),
        transform: preferredTransform
    )
}

/// Per-frame result from the Vision feature-print pipeline.
private struct PFVisionFrameMatch {
    var hits: [(Double, Float)] = []
    var matchedRects: [CGRect] = []
    var unmatchedRects: [CGRect] = []
    var facesDetected: Int = 0
    var bestDistInFrame: Float = .greatestFiniteMagnitude
}

/// For each candidate face, generate a Vision feature print and compare against
/// each reference print. Returns matched/unmatched rects and the best distance.
private func pfVisionMatchCandidates(
    timeSecs: Double,
    orientedImage: CGImage,
    candidates: [VNFaceObservation],
    referencePrints: [VNFeaturePrintObservation],
    settings: PersonFinderSettings
) -> PFVisionFrameMatch {
    var m = PFVisionFrameMatch()
    for obs in candidates {
        guard obs.confidence >= settings.minFaceConfidence,
              let cropped = pfNormalizeFaceCrop(from: orientedImage, observation: obs),
              let fp = pfGenerateFeaturePrint(for: cropped) else { continue }
        m.facesDetected += 1

        var best: Float = .greatestFiniteMagnitude
        for ref in referencePrints {
            var d: Float = 0
            if (try? ref.computeDistance(&d, to: fp)) != nil, d < best { best = d }
        }
        if best < m.bestDistInFrame { m.bestDistInFrame = best }

        if best <= settings.threshold {
            m.hits.append((timeSecs, best))
            m.matchedRects.append(obs.boundingBox)
        } else {
            m.unmatchedRects.append(obs.boundingBox)
        }
    }
    return m
}

/// Cluster raw timestamped hits into padded, duration-filtered segments.
/// Identical algorithm to the ArcFace variant.
private func pfVisionClusterSegments(
    hits: [(timeSecs: Double, distance: Float)],
    settings: PersonFinderSettings,
    fps: Double,
    duration: Double
) -> [pfSegment] {
    guard !hits.isEmpty else { return [] }

    let gapTol = Double(settings.frameStep) / fps * 3.0
    let sorted = hits.sorted { $0.timeSecs < $1.timeSecs }
    var raw: [(start: Double, end: Double, distances: [Float])] = []
    var cur = (start: sorted[0].timeSecs, end: sorted[0].timeSecs, distances: [sorted[0].distance])
    for h in sorted.dropFirst() {
        if h.timeSecs - cur.end <= gapTol {
            cur.end = h.timeSecs; cur.distances.append(h.distance)
        } else {
            raw.append(cur); cur = (h.timeSecs, h.timeSecs, [h.distance])
        }
    }
    raw.append(cur)

    var padded = raw.map { (max(0, $0.start - settings.pad),
                           min(duration, $0.end + settings.pad),
                           $0.distances) }
    padded.sort { $0.0 < $1.0 }

    var merged: [(Double, Double, [Float])] = []
    for seg in padded {
        if var last = merged.last, seg.0 <= last.1 {
            last.1 = max(last.1, seg.1)
            last.2.append(contentsOf: seg.2)
            merged[merged.count - 1] = last
        } else {
            merged.append(seg)
        }
    }

    return merged.compactMap { s in
        guard (s.1 - s.0) >= settings.minDuration else { return nil }
        let avg = s.2.reduce(0, +) / Float(s.2.count)
        return pfSegment(startSecs: s.0, endSecs: s.1,
                         bestDistance: s.2.min() ?? 0, avgDistance: avg)
    }
}


private nonisolated func pfLogMilestones(
    frameTime: Double, duration: Double, filename: String,
    index: Int, total: Int, hits: [(timeSecs: Double, distance: Float)],
    totalFacesDetected: Int, bestDistEver: Float,
    milestones: Set<Int>, loggedMilestones: inout Set<Int>,
    progressFn: @escaping @Sendable (String) async -> Void,
    logFn: @escaping @Sendable (String) async -> Void,
    distFn: @escaping @Sendable (Float) async -> Void
) async {
    let pct = duration > 0 ? Int(frameTime / duration * 100) : 0
    await progressFn("\(filename)  [t=\(String(format: "%.0f", frameTime))s / \(String(format: "%.0f", duration))s · \(hits.count) hit(s)]")
    for m in milestones where pct >= m && !loggedMilestones.contains(m) {
        loggedMilestones.insert(m)
        let distStr = bestDistEver < .greatestFiniteMagnitude ? String(format: "%.3f", bestDistEver) : "—"
        await logFn("    \(m)% — t=\(String(format: "%.0f", frameTime))s/\(String(format: "%.0f", duration))s, \(totalFacesDetected) faces detected, \(hits.count) hit(s), best dist \(distStr)")
        await distFn(bestDistEver)
    }
}

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
    var perf = FramePerfAccumulator()
    let videoOpenStart = CFAbsoluteTimeGetCurrent()
    let spVideo = signpostLog.beginInterval("video", id: .exclusive, "\(filename, privacy: .public)")
    guard let ctx = await pfOpenVisionVideoReader(
        filePath: filePath, filename: filename, index: index, total: total, logFn: logFn
    ) else {
        signpostLog.endInterval("video", spVideo)
        return nil
    }
    perf.videoOpenMs = (CFAbsoluteTimeGetCurrent() - videoOpenStart) * 1000
    let wallStart = CFAbsoluteTimeGetCurrent()

    await progressFn(filename)
    await logFn("[\(index)/\(total)] \(filename)  (\(pfFormatDuration(ctx.duration)), \(String(format: "%.1f", ctx.fps)) fps)")

    var hits: [(timeSecs: Double, distance: Float)] = []
    var totalFacesDetected = 0
    var bestDistEver: Float = .greatestFiniteMagnitude
    let frameInterval = Double(settings.frameStep) / ctx.fps
    var sampledSoFar = 0
    let milestones: Set<Int> = [25, 50, 75]
    var loggedMilestones = Set<Int>()
    var visionFrameTimes: [Double] = []

    // For MPEG-TS containers (mts/m2ts/ts), sequential AVAssetReader demux
    // wastes ~98% of the work; SeekingFrameProvider uses
    // AVAssetImageGenerator instead for a 10–34× speedup on those files.
    // The reader is preflighted in pfMakeReadingContext but isn't used on
    // the seeker path, so cancelling it before we start is safe (no race).
    let ext = (filePath as NSString).pathExtension.lowercased()
    let useSeeker = ext == "mts" || ext == "m2ts" || ext == "ts"

    let seekProvider: SeekingFrameProvider? = useSeeker
        ? SeekingFrameProvider(asset: ctx.asset, duration: ctx.duration, frameInterval: frameInterval)
        : nil
    let prefetcher: FramePrefetcher? = useSeeker
        ? nil
        : FramePrefetcher(reader: ctx.reader, trackOutput: ctx.trackOutput, frameInterval: frameInterval)
    if useSeeker { ctx.reader.cancelReading() }

    let frameStream = seekProvider?.frames() ?? prefetcher!.frames()
    for await frame in frameStream {
        if Task.isCancelled {
            // Don't call ctx.reader.cancelReading() here on the prefetcher
            // path — it races with the producer queue's in-flight
            // copyNextSampleBuffer and crashes inside CoreMedia
            // (`_dispatch_semaphore_dispose` / FigSimpleMutexUnlock).
            // The for-await exit triggers AsyncStream onTermination, which
            // sets the producer's cancel flag; after the in-flight
            // copyNextSampleBuffer returns the queue exits cleanly and
            // AVAssetReader's deinit handles teardown without a race.
            // Same applies to the seeker path — just break.
            break
        }
        if let sp = seekProvider { sp.releaseSlot() } else { prefetcher!.releaseSlot() }

        let frameTime = frame.presentationTime
        var frameMatch = PFVisionFrameMatch()
        var previewImage: CGImage?

        autoreleasepool {
            let t1 = CFAbsoluteTimeGetCurrent()
            let allFaces = pfDetectFacesInBuffer(frame.pixelBuffer, orientation: ctx.orientation)
            let candidates: [VNFaceObservation] = settings.requirePrimary
                ? (allFaces.max(by: { ($0.boundingBox.width * $0.boundingBox.height) < ($1.boundingBox.width * $1.boundingBox.height) }).map { [$0] } ?? [])
                : allFaces
            let t2 = CFAbsoluteTimeGetCurrent()

            var orientTime = 0.0
            var matchTime = 0.0
            if !candidates.isEmpty,
               let img = pfOrientedCGImage(from: frame.pixelBuffer, transform: ctx.transform) {
                let t3 = CFAbsoluteTimeGetCurrent()
                orientTime = t3 - t2
                frameMatch = pfVisionMatchCandidates(
                    timeSecs: frameTime,
                    orientedImage: img,
                    candidates: candidates,
                    referencePrints: prints,
                    settings: settings
                )
                matchTime = CFAbsoluteTimeGetCurrent() - t3
                if frameMatch.bestDistInFrame < bestDistEver {
                    bestDistEver = frameMatch.bestDistInFrame
                }
                totalFacesDetected += frameMatch.facesDetected
                let rate = max(1, previewRateFn())
                if (sampledSoFar + 1) % rate == 0 { previewImage = img }
            }
            perf.addFrame(decode: frame.decodeSeconds, detect: t2 - t1, orient: orientTime, match: matchTime)
            sampledSoFar += 1
            visionFrameTimes.append(CFAbsoluteTimeGetCurrent() - t1 + frame.decodeSeconds)
        }

        hits.append(contentsOf: frameMatch.hits)

        if let img = previewImage {
            await frameFn(img, frameMatch.matchedRects, frameMatch.unmatchedRects)
        }

        if sampledSoFar % 5 == 0 {
            await pauseGate.waitIfPaused()
            // See top of this for-await: don't call cancelReading() from
            // the consumer side — it races with the prefetcher's in-flight
            // copyNextSampleBuffer. Just break; the AsyncStream onTermination
            // path handles the reader teardown safely.
            if Task.isCancelled { break }
        }

        if visionFrameTimes.count >= 10 {
            let avg = visionFrameTimes.reduce(0, +) / Double(visionFrameTimes.count)
            await visionStatsFn(avg > 0 ? 1.0 / avg : 0, avg * 1000)
            visionFrameTimes.removeAll(keepingCapacity: true)
        }

        await pfLogMilestones(
            frameTime: frameTime, duration: ctx.duration, filename: filename,
            index: index, total: total, hits: hits, totalFacesDetected: totalFacesDetected,
            bestDistEver: bestDistEver, milestones: milestones,
            loggedMilestones: &loggedMilestones, progressFn: progressFn, logFn: logFn, distFn: distFn
        )
    }

    let wallMs = (CFAbsoluteTimeGetCurrent() - wallStart) * 1000
    let summary = perf.summary(filename: filename, wallMs: wallMs)
    perfLog.notice("\(summary, privacy: .public)")
    signpostLog.endInterval("video", spVideo)

    await distFn(bestDistEver)
    if ctx.reader.status == .failed {
        await logFn("[\(index)/\(total)] \(filename) — reader error: \(ctx.reader.error?.localizedDescription ?? "unknown")")
    }

    let distStr = bestDistEver < .greatestFiniteMagnitude ? String(format: "%.3f", bestDistEver) : "—"

    guard !hits.isEmpty else {
        await logFn("  [\(index)/\(total)] \(filename) → no match  (faces detected: \(totalFacesDetected), best dist: \(distStr), threshold: \(String(format: "%.3f", settings.threshold)))")
        return pfVideoResult(filename: filename, filePath: filePath,
                             durationSeconds: ctx.duration, fps: ctx.fps, totalHits: 0, segments: [])
    }

    let segs = pfVisionClusterSegments(hits: hits, settings: settings, fps: ctx.fps, duration: ctx.duration)
    let presence = segs.reduce(0) { $0 + ($1.endSecs - $1.startSecs) }
    let bestHitDist = hits.map(\.distance).min() ?? 0
    await logFn("  [\(index)/\(total)] \(filename) → \(hits.count) hits, \(segs.count) seg(s), \(pfFormatDuration(presence)) presence  (faces: \(totalFacesDetected), best dist: \(String(format: "%.3f", bestHitDist)))")

    return pfVideoResult(filename: filename, filePath: filePath,
                         durationSeconds: ctx.duration, fps: ctx.fps,
                         totalHits: hits.count, segments: segs)
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
    if #available(macOS 15.0, *) {
        do { try await session.export(to: url, as: .mov); return true } catch { return false }
    } else {
        session.outputURL = url
        session.outputFileType = .mov
        return await withCheckedContinuation { cont in
            session.exportAsynchronously { cont.resume(returning: session.status == .completed) }
        }
    }
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
    let vCodec: String   // "h264", "hevc", "dvvideo", "mpeg2video", "none"
    let vProfile: String   // "High", "Main", ""
    let pixFmt: String   // "yuv420p", "yuv422p10le"
    let width: Int
    let height: Int
    let sar: String   // "1:1", "10:11"
    let fpsRational: String   // "30000/1001", "25/1", "0/0" if VFR
    let colorSpace: String
    let colorRange: String
    // Audio
    let aCodec: String   // "aac", "pcm_s16le", "ac3", "none"
    let aSampleRate: Int      // 0 if no audio
    let aChannels: Int      // 0 if no audio
    let aLayout: String
    // Container shape
    let hasAudio: Bool

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
        let mp4Audio: Set<String> = ["aac", "ac3", "eac3", "mp3", "opus"]
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
    guard let ffprobePath = ToolLocator.firstExecutable(in: ToolLocator.ffprobeCandidates) else { return nil }
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
    var current: pfBucket?

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

    guard let ffmpegPath = ToolLocator.firstExecutable(in: ToolLocator.ffmpegCandidates) else {
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
    do { try listContent.write(toFile: listPath, atomically: true, encoding: .utf8) } catch {
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

/// Merge multiple bucket compilation files into ONE single output file via
/// hardware-accelerated re-encode (h264_videotoolbox on Apple Silicon).
///
/// Two-pass strategy:
///   1. Re-encode each bucket file to a normalized format (1280×720, h264,
///      30fps, AAC 128k 48kHz stereo). Writes to a temp dir.
///   2. Stream-copy concat the normalized files into the final output path
///      (fast — no second re-encode).
///
/// Returns true on success, false on any failure (caller should keep the
/// original bucket files as fallback).
private func pfMergeBucketsToSingleFile(
    bucketPaths: [String],
    outputPath: String,
    targetHeight: Int = 720,
    logFn: @escaping @Sendable (String) async -> Void
) async -> Bool {
    let fm = FileManager.default
    guard let ffmpegPath = ToolLocator.firstExecutable(in: ToolLocator.ffmpegCandidates) else {
        await logFn("  ⚠ ffmpeg not found for merge step")
        return false
    }

    let workDir = (NSTemporaryDirectory() as NSString)
        .appendingPathComponent("pf_merge_\(Int(Date().timeIntervalSince1970 * 1000))")
    try? fm.createDirectory(atPath: workDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: workDir) }

    var normalizedPaths: [String] = []
    for (idx, src) in bucketPaths.enumerated() {
        let dst = (workDir as NSString)
            .appendingPathComponent("norm_\(String(format: "%04d", idx)).mp4")
        let ok = await pfRunFFmpeg(
            ffmpegPath: ffmpegPath,
            args: [
                "-hide_banner", "-nostdin", "-y",
                "-i", src,
                "-vf", "scale=-2:\(targetHeight),setsar=1,format=yuv420p",
                "-c:v", "h264_videotoolbox",
                "-b:v", "4M",
                "-c:a", "aac", "-b:a", "128k", "-ar", "48000", "-ac", "2",
                "-r", "30",
                "-movflags", "+faststart",
                dst
            ]
        )
        if ok && fm.fileExists(atPath: dst) {
            normalizedPaths.append(dst)
            await logFn("  Normalized \(idx + 1)/\(bucketPaths.count) bucket(s)")
        } else {
            await logFn("  ⚠ Normalize failed for bucket \(idx + 1) — aborting merge")
            return false
        }
    }
    guard !normalizedPaths.isEmpty else { return false }

    // Concat the normalized files (stream-copy, fast)
    let listPath = (workDir as NSString).appendingPathComponent("concat.txt")
    let listContent = normalizedPaths
        .map { "file '\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }
        .joined(separator: "\n")
    do { try listContent.write(toFile: listPath, atomically: true, encoding: .utf8) } catch {
        await logFn("  ⚠ Could not write merge concat list: \(error.localizedDescription)")
        return false
    }

    if fm.fileExists(atPath: outputPath) { try? fm.removeItem(atPath: outputPath) }

    let ok = await pfRunFFmpeg(
        ffmpegPath: ffmpegPath,
        args: [
            "-hide_banner", "-nostdin", "-y",
            "-f", "concat", "-safe", "0", "-i", listPath,
            "-c", "copy",
            "-movflags", "+faststart",
            outputPath
        ]
    )
    return ok && fm.fileExists(atPath: outputPath)
}

/// Run ffmpeg synchronously (in an async context) with the given args.
/// Returns true if exit status was 0. Drains stderr to avoid pipe deadlock.
private func pfRunFFmpeg(ffmpegPath: String, args: [String]) async -> Bool {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: ffmpegPath)
    proc.arguments = args
    proc.standardOutput = FileHandle.nullDevice
    let stderrPipe = Pipe()
    proc.standardError = stderrPipe
    let stderrBox = pfStderrBox()
    stderrPipe.fileHandleForReading.readabilityHandler = { handle in
        let chunk = handle.availableData
        if !chunk.isEmpty { stderrBox.append(chunk) }
    }
    do {
        try proc.run()
    } catch {
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        return false
    }
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
        DispatchQueue.global(qos: .userInitiated).async {
            proc.waitUntilExit()
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            cont.resume()
        }
    }
    return proc.terminationStatus == 0
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
// pfSanitize / pfFormatDuration / pfFormatBytes moved to PersonFinderCatalogFilter.swift
// (step 2 of 6 PersonFinderModel split).

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
    let (refEmbeddings, refErr) = arcfaceLoadReferenceEmbeddings(
        from: settings.referencePath,
        largestFaceOnly: settings.largestFaceOnly,
        model: mlModel
    )
    if let refErr {
        await logFn("[arcface] Reference loading failed: \(refErr)")
        return nil
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
