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
// Module-wide logger — used by Compilation extension and (in step 6) JobLifecycle extension.
let osLog = Logger(
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
    var compilationTask: Task<Void, Never>?

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

    // MARK: - Compilation lifecycle
    // startCompilation / cancelCompilation / runCompilation /
    // compileAndCleanup moved to PersonFinderCompilation.swift
    // (step 5 of 6 PersonFinderModel split, bundled with the free-func
    // compilation helpers).

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

    // compileAndCleanup moved to PersonFinderCompilation.swift
    // (step 5 of 6 PersonFinderModel split, bundled).

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

// MARK: - Catalog skip set, person-scan prefilter, video discovery
// Moved to PersonFinderCatalogFilter.swift (step 2 of 6 PersonFinderModel split).

// MARK: - Vision detection pipeline
// Moved to PersonFinderDetection.swift (step 3 of 6 PersonFinderModel split).
// Symbols relocated: pfCIContext, pfLoadReferencePhotos, pfNormalizeFaceCrop,
// pfGenerateFeaturePrint, pfOrientationFromTransform, pfDetectFacesInBuffer,
// pfOrientedCGImage, PFVisionReaderContext, pfOpenVisionVideoReader,
// PFVisionFrameMatch, pfVisionMatchCandidates, pfVisionClusterSegments,
// pfLogMilestones, pfProcessVideo. Dead helper pfDetectFaces(in:) removed.

// MARK: - dlib/Python video processing
// Moved to PersonFinderEngineDispatch.swift (step 4 of 6 PersonFinderModel split).
// Symbols relocated: DlibSegmentJSON, DlibResultJSON, pfDecodeDlibResult,
// pfProcessVideoWithDlib. pfProcessVideoWithDlib widened private → internal
// because its caller PersonFinderModel.runDlib() remains here until step 6.

// MARK: - Clip extraction / compatibility bucketing / compilation
// Moved to PersonFinderCompilation.swift (step 5 of 6 PersonFinderModel
// split, bundled). Symbols relocated:
//   • free funcs/types: pfExtractAllClips, pfExtractClip,
//     pfBuildSortedClipEntries, CompatKey, pfBucket, pfBucketByCompat,
//     pfCompileBuckets, pfStreamCopyConcat, pfMergeBucketsToSingleFile,
//     pfRunFFmpeg, pfStderrBox, pfFileSize, pfExtractYear, pfDecadeLabel,
//     pfClipEntry, pfProbeCompatKey
//   • PersonFinderModel methods (now in `extension PersonFinderModel`):
//     startCompilation, cancelCompilation, runCompilation, compileAndCleanup
// Widenings applied (private → internal): pfBuildSortedClipEntries,
// pfExtractYear, pfClipEntry — to enable PersonFinderBoundaryTests
// coverage of sort/year-extraction contracts.

// MARK: - Utilities
// pfSanitize / pfFormatDuration / pfFormatBytes moved to PersonFinderCatalogFilter.swift
// (step 2 of 6 PersonFinderModel split).

// MARK: - ArcFace engine dispatch
// pfRunArcFaceEngine moved to PersonFinderEngineDispatch.swift
// (step 4 of 6 PersonFinderModel split).
