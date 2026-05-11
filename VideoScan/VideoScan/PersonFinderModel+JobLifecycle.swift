// PersonFinderModel+JobLifecycle.swift
// Job lifecycle management for PersonFinderModel, extracted from
// PersonFinderModel.swift as the final step (6 of 6) of the
// PersonFinderModel decomposition. Pure code movement — no logic changes.
//
// Contains, as an extension on PersonFinderModel:
//   • Job management: addJob, loadFacesForJob, removeJob, restoreFromCache
//   • Per-job lifecycle: startJob, startJobAfterLoad, stopJob, pauseJob,
//     resumeJob, togglePauseJob
//   • Bulk lifecycle: startAll, stopAll, pauseAll, resumeAll
//   • Core scan pipeline (nonisolated statics): resolveOutputDir,
//     filterByPresence, scanAllVideos, processOneVideo, discoverVideos,
//     runScan
//   • Two private helpers that travel with the methods above:
//     referenceCacheIdentifiers, pfScanLog
//
// Four ScanJob widenings applied in PersonFinderModel.swift (all
// fileprivate → internal) so the lifecycle methods here can manage
// the underlying tasks from across files:
//   - scanTask, timerTask (fields, pre-authorized by qa plan)
//   - startElapsedTimer(), stopElapsedTimer() (methods, approved as
//     task-lifecycle peers under the same precedent)
// taskStarted stays fileprivate (only used inside ScanJob).
//
// Deferred to a follow-up commit: extracting the inline engine-dispatch
// switch from processOneVideo into a dispatchEngine() helper. Per the
// Manager's review, this step is kept as pure code movement.

import Foundation
@preconcurrency import AVFoundation
import Vision
import os

private let pfScanLog = Logger(
    subsystem: "Rick-Breen.VideoScan",
    category: "scan"
)

extension PersonFinderModel {

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
