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

    // MARK: Confidence-tier split (Step 1b)
    //
    // Splits a presence-filtered result set into "confirmed" (strong-match)
    // and "suspected" (borderline) buckets so the catalog writeback can
    // route names to `detectedPeople` vs `suspectedPeople`. Lives here so
    // PersonFinder owns the classification — it has the engine + threshold
    // context — and the catalog stays a dumb sink.

    /// How close to the threshold a match has to be to count as
    /// "suspected" rather than "confirmed". A `bestDistance` of
    /// `threshold - margin` is the cutoff: closer than that → confirmed.
    nonisolated static let confidenceMargin: Float = 0.05

    /// Partition `results` into (confirmed, suspected). All entries are
    /// assumed to have passed the presence filter (i.e. bestDistance
    /// already ≤ threshold). The strong-match cutoff is `threshold − margin`:
    /// distances at or below it become confirmed; distances within the
    /// margin of the threshold become suspected.
    nonisolated static func splitByConfidence(
        _ results: [pfVideoResult],
        threshold: Float,
        margin: Float = confidenceMargin
    ) -> (confirmed: [pfVideoResult], suspected: [pfVideoResult]) {
        var confirmed: [pfVideoResult] = []
        var suspected: [pfVideoResult] = []
        let strongCutoff = threshold - margin
        for r in results {
            let bestDist = r.segments.map(\.bestDistance).min()
                ?? .greatestFiniteMagnitude
            if bestDist <= strongCutoff {
                confirmed.append(r)
            } else {
                suspected.append(r)
            }
        }
        return (confirmed, suspected)
    }

    private nonisolated static func referenceCacheIdentifiers(referencePath: String, filenames: [String]) -> [String] {
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

    // MARK: - "Search for Family" (Step 3)
    //
    // Fans a search across every saved POI profile against a single target
    // path. Each POI becomes its own ScanJob, running in parallel via the
    // existing per-job Task.detached path — per the parallelize-aggressively
    // design principle. Single right-click ⇒ N concurrent scans across all
    // your family members.

    /// Enqueue (but don't start) one ScanJob per saved POI profile that has
    /// reference photos loaded. Profiles with empty `referencePath` are
    /// skipped — they'd fail at startJob's pre-flight anyway. Returns the
    /// newly-appended jobs so the UI can expand / focus them.
    ///
    /// Pure side effect on `jobs`. Split from `startFamilyScan(at:)` so
    /// tests can verify the enqueue behavior without driving Task.detached
    /// file I/O.
    @discardableResult
    func enqueueFamilyJobs(at path: String) -> [ScanJob] {
        let viable = savedProfiles.filter { !$0.referencePath.isEmpty }
        let newJobs: [ScanJob] = viable.map { profile in
            let job = ScanJob(searchPath: path)
            job.assignedProfile = profile
            jobs.append(job)
            return job
        }
        return newJobs
    }

    /// Fan-out entry point: enqueue + immediately start every Family scan.
    /// Each job runs on its own detached Task so engines run in parallel.
    /// Returns the new jobs (typically used by the UI to expand them).
    @discardableResult
    func startFamilyScan(at path: String) -> [ScanJob] {
        let newJobs = enqueueFamilyJobs(at: path)
        // Narrative log line at the user-triggered fan-out boundary —
        // one line per "Search for Family" click. Each subsequent
        // per-job "Starting search for X on Y…" line comes from
        // startJobAfterLoad's existing appLog.write, so this is the
        // headline above that detail.
        if !newJobs.isEmpty {
            let volume = URL(fileURLWithPath: path).lastPathComponent
            let names = newJobs.compactMap { $0.assignedProfile?.name }
                .joined(separator: ", ")
            appLog.write("Search for Family on \(volume): \(newJobs.count) parallel job(s) — \(names)")
            let skipped = savedProfiles.count - newJobs.count
            if skipped > 0 {
                appLog.write("  Skipped \(skipped) profile(s) without reference photos")
            }
        }
        for job in newJobs {
            startJob(job)
        }
        return newJobs
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
        // Loading a fresh reference set invalidates any previously-cached
        // ArcFace embeddings — they were computed from the prior photos.
        // pfRunArcFaceEngine will rebuild the cache on the next scan.
        job.assignedArcFaceEmbeddings = []
        job.status = .idle

        if !job.searchPath.isEmpty && !job.assignedFaces.isEmpty {
            restoreFromCache(job: job)
        }
    }

    func removeJob(_ job: ScanJob) {
        job.scanTask?.cancel()
        job.timerTask?.cancel()
        jobs.removeAll { $0.id == job.id }
        // Also drop the on-disk descriptor so the search doesn't reappear
        // on next launch. No-op for jobs that never reached save() (the
        // descriptor file simply isn't there). Without this, deleting a
        // completed search via the UI looked successful but the entry
        // would resurrect on relaunch via restoreSessionFromDisk.
        ScanJobsStorage.delete(id: job.id)
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
        // Capture the catalog writeback closure on MainActor so the
        // detached Task below can invoke it inside its own MainActor.run.
        // The closure's `@MainActor` annotation makes its type Sendable
        // across the actor hop.
        let onComplete = self.onScanComplete

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
                let (confirmed, suspected) = Self.splitByConfidence(
                    validResults, threshold: threshold
                )
                onComplete?(job.personLabel, confirmed, suspected)
            }
        }
    }

    func startJob(_ job: ScanJob) {
        guard !job.status.isActive else { return }

        // Volume reachability — fail fast BEFORE the async loadFacesForJob
        // Task hop. Otherwise the user sees spinning/face-loading activity
        // and an eventual confusing error instead of an immediate "offline"
        // diagnosis. startJobAfterLoad still re-checks as a belt-and-suspenders
        // guard against the (rare) volume-goes-offline-mid-load race.
        if !VolumeReachability.isReachable(path: job.searchPath) {
            let volumeName = VolumeReachability.displayLabel(forPath: job.searchPath)
            let msg = "⚠ Volume \"\(volumeName)\" is offline. Mount it and try again."
            job.appendLog(msg)
            osLog.error("startJob bailed: volume offline (\(job.searchPath, privacy: .public))")
            job.status = .failed("Volume \"\(volumeName)\" offline")
            return
        }

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
            let volumeName = VolumeReachability.displayLabel(forPath: job.searchPath)
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
        // Capture writeback on MainActor so the static nonisolated runScan
        // can invoke it inside its own MainActor.run completion hop.
        let onComplete = self.onScanComplete
        job.scanTask = Task { [weak self, weak job] in
            guard let job else { return }
            await MainActor.run {
                dash?.visionActive = settings.recognitionEngine == .vision || settings.recognitionEngine == .arcface
                dash?.activeEngineLabel = settings.recognitionEngine == .arcface ? "ArcFace / CoreML + ANE" : "Vision / ANE"
            }
            await PersonFinderModel.runScan(job: job, prints: prints, settings: settings, refFilenames: refCacheIdentifiers, dashboard: dash, onComplete: onComplete)
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
            job.completedAt = Date()
            job.currentFile = ""
            osLog.info("Job stopped: \(job.searchPath, privacy: .public) — was \(prev.label, privacy: .public), scanned \(job.videosScanned)/\(job.videosTotal)")
            let personName = job.assignedProfile?.name ?? "(global)"
            let volumeName = URL(fileURLWithPath: job.searchPath).lastPathComponent
            appLog.write("Stopped search for \(personName) on \(volumeName) (scanned \(job.videosScanned)/\(job.videosTotal))")
            // Persist so the partially-scanned search reappears on next launch.
            // Resume is free: the cache short-circuits already-processed videos
            // when the user re-runs from the restored row.
            Self.persistDescriptor(for: job, settings: settings)
        }
    }

    func pauseJob(_ job: ScanJob) {
        guard job.status == .scanning else { return }
        Task { await job.pauseGate.pause() }
        job.status = .paused
        job.completedAt = Date()
        osLog.info("Job paused: \(job.searchPath, privacy: .public)")
        let personName = job.assignedProfile?.name ?? "(global)"
        let volumeName = URL(fileURLWithPath: job.searchPath).lastPathComponent
        appLog.write("Paused search for \(personName) on \(volumeName)")
        // Same rationale as stopJob — a paused search the user comes back to
        // tomorrow should reappear in the jobs list, not vanish.
        Self.persistDescriptor(for: job, settings: settings)
    }

    /// Save a tiny descriptor of the current job state so it survives app
    /// restart (issue #89). Called on any worth-bookmarking transition:
    /// .done, .paused, .cancelled. Idempotent — re-saving for the same
    /// job.id overwrites in place (no duplicates). Dispatched off MainActor
    /// so a slow disk doesn't stall the UI.
    ///
    /// Static + settings-by-value so the runScan path (nonisolated static)
    /// can call it without holding a reference to the model.
    static func persistDescriptor(for job: ScanJob, settings: PersonFinderSettings) {
        let descriptor = makeDescriptor(from: job, settings: settings)
        let cap = ScanJobsStorage.defaultLimit
        Task.detached(priority: .utility) {
            do {
                try ScanJobsStorage.save(descriptor)
                let evicted = ScanJobsStorage.enforceLimit(keep: cap)
                if evicted > 0 {
                    osLog.notice("Session history: kept newest \(cap), evicted \(evicted) older search descriptor(s)")
                }
            } catch {
                osLog.error("Failed to persist scan-job descriptor: \(error.localizedDescription, privacy: .public)")
            }
        }
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

        // Cache-miss diagnostic: if NONE of the videos are cached, sample the
        // first file and explain why we couldn't reuse prior scans. Logged to
        // the per-job face_detect log only — the main app log already has the
        // headline "Search for X on Y" line.
        if cachedCount == 0 && total > 0 {
            let samplePath = videoFiles[0]
            let fm = FileManager.default
            if let attrs = try? fm.attributesOfItem(atPath: samplePath),
               let size = attrs[.size] as? Int64,
               let mod = attrs[.modificationDate] as? Date {
                let rows = PersonFinderCache.shared.cachedRowsForVideo(
                    videoPath: samplePath, fileSize: size, modDate: mod
                )
                let currentRefHash = PersonFinderCache.cachedRefHash(refFilenames)
                let why = PersonFinderCache.cacheMissDiagnostic(
                    currentPersonName: settings.personName,
                    currentEngine: settings.recognitionEngine.rawValue,
                    currentThreshold: cacheThreshold,
                    currentRefHash: currentRefHash,
                    cachedRows: rows
                )
                await job.appendLog("Cache miss diagnosis (sample: \((samplePath as NSString).lastPathComponent)): \(why)")
            }
        }

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
        dashboard: DashboardState?,
        onComplete: (
            @MainActor (
                _ personLabel: String,
                _ confirmed: [pfVideoResult],
                _ suspected: [pfVideoResult]
            ) -> Void
        )?
    ) async {
        let path = await job.searchPath
        let scanThreshold = settings.recognitionEngine == .arcface
            ? settings.arcfaceThreshold : settings.threshold
        let scanRefHash = PersonFinderCache.cachedRefHash(refFilenames)
        let personLabel = settings.personName.isEmpty ? "(global)" : settings.personName
        // Main app log: the headline the user wants to skim — who, where, on what.
        osLog.notice("Search for \(personLabel, privacy: .public) on \(path, privacy: .public) — engine=\(settings.recognitionEngine.rawValue, privacy: .public)")
        // Per-job face_detect log: full cache-key details, for cache-miss diagnosis.
        await job.appendLog("Search for \(personLabel) on \(path)")
        await job.appendLog("  engine=\(settings.recognitionEngine.rawValue) threshold=\(scanThreshold) refs=\(refFilenames.count) refHash=\(scanRefHash)")
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
                job.completedAt = Date()
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
                let volumeName = VolumeReachability.displayLabel(forPath: job.searchPath)
                let onVol = volumeName.isEmpty ? "" : " on \(volumeName)"
                // displayName drops the parenthetical descriptor — just
                // "Vision" / "ArcFace" / "dlib" / "Hybrid". Matches the UI
                // summary in ScanJobRow.summaryText so log and screen agree.
                let engineName = job.effectiveEngine.displayName
                let usingEngine = " using algorithm: \(engineName)"
                let stats = "(Searched \(total) total file\(total == 1 ? "" : "s"). Elapsed time \(elapsed))"
                let person = job.personLabel
                let summary: String
                if hits > 0 {
                    summary = "Search Complete: Found \(person) in \(hits) file\(hits == 1 ? "" : "s")\(onVol)\(usingEngine). \(stats)"
                } else {
                    summary = "Search Complete: Found no matches for \(person)\(onVol)\(usingEngine). \(stats)"
                }
                osLog.info("\(summary, privacy: .public)")
                pfScanLog.info("\(summary, privacy: .public)")
                job.appendLog("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                job.appendLog(summary)
                job.appendLog("Done. \(job.videosWithHits) video(s) with hits, \(totalSegments) segment(s), \(pfFormatDuration(preliminaryPresence)) total presence.")
                if totalSegments > 0 {
                    job.appendLog("Use Create Composite Video to extract and compile clips.")
                }

                // Persist a descriptor so this completed search reappears in
                // the jobs list after app restart. Same helper used by pause
                // and stop, so all three "worth bookmarking" transitions go
                // through one code path.
                Self.persistDescriptor(for: job, settings: settings)

                // Catalog writeback: splits matches by confidence tier, then
                // appends `personLabel` to each matched VideoRecord's
                // `detectedPeople` (confirmed) or `suspectedPeople`
                // (borderline) list. Wired by VideoScanApp.
                let (confirmed, suspected) = Self.splitByConfidence(
                    validResults, threshold: scanThreshold
                )
                onComplete?(person, confirmed, suspected)
            }
        }
    }

    // MARK: - Session restore (issue #89, part 2)

    /// Build the on-disk descriptor for a finished job. Called from runScan
    /// at the .done transition and from any future "force re-save" path.
    /// Pure data extraction — no I/O — so it's straight-line testable.
    static func makeDescriptor(
        from job: ScanJob,
        settings: PersonFinderSettings
    ) -> PersistedJobDescriptor {
        let personName = job.assignedProfile?.name
            ?? (settings.personName.isEmpty ? "(global)" : settings.personName)
        let folderName = job.assignedProfile.map { POIStorage.sanitize($0.name) }
        let engine = job.effectiveEngine
        let threshold = engine == .arcface ? settings.arcfaceThreshold : settings.threshold
        let referencePath = job.assignedProfile?.referencePath ?? settings.referencePath
        let referenceFilenames = job.assignedFaces.map(\.sourceFilename)
        return PersistedJobDescriptor(
            id: job.id,
            personName: personName,
            profileFolderName: folderName,
            searchPath: job.searchPath,
            engine: engine.rawValue,
            threshold: threshold,
            referencePath: referencePath,
            referenceFilenames: referenceFilenames,
            completedAt: Date(),
            videosScanned: job.videosScanned,
            videosTotal: job.videosTotal,
            videosWithHits: job.videosWithHits,
            clipsFound: job.clipsFound,
            presenceSecs: job.presenceSecs,
            elapsedSecs: job.elapsedSecs
        )
    }

    /// Restore completed jobs from disk at app launch. Each descriptor turns
    /// into a ScanJob in .done state with summary stats from the descriptor;
    /// per-video result rows rehydrate in the background from the existing
    /// PersonFinderCache via `rehydrateResultsFromCache`.
    @MainActor
    func restoreSessionFromDisk() {
        let descriptors = ScanJobsStorage.listAll()
        guard !descriptors.isEmpty else { return }
        osLog.info("Session restore: \(descriptors.count) prior search(es) found on disk")

        for descriptor in descriptors {
            let job = Self.makeJob(from: descriptor)

            // Reattach the POI profile if it still exists. If the profile was
            // deleted since the search ran, the job still shows up with the
            // person's name from the descriptor — just no profile object to
            // open in the editor. This is the one I/O step that lives outside
            // makeJob so the pure constructor stays testable.
            if let folderName = descriptor.profileFolderName,
               let profile = try? POIProfile.load(name: folderName) {
                job.assignedProfile = profile
            }

            jobs.append(job)

            // Background rehydration — populate results from the SQLite cache.
            Task.detached(priority: .utility) {
                await Self.rehydrateResultsFromCache(job: job, descriptor: descriptor)
            }
        }
    }

    /// Pure constructor: build an in-memory ScanJob from a persisted
    /// descriptor. No filesystem I/O — the caller does any POI profile
    /// reattachment separately. Extracted from restoreSessionFromDisk so
    /// the data-shape part of restore is unit-testable without spinning
    /// up the whole model + filesystem.
    @MainActor
    static func makeJob(from descriptor: PersistedJobDescriptor) -> ScanJob {
        let job = ScanJob(searchPath: descriptor.searchPath, id: descriptor.id)
        job.videosScanned = descriptor.videosScanned
        job.videosTotal = descriptor.videosTotal
        job.videosWithHits = descriptor.videosWithHits
        job.clipsFound = descriptor.clipsFound
        job.presenceSecs = descriptor.presenceSecs
        job.elapsedSecs = descriptor.elapsedSecs
        job.status = .done
        job.completedAt = descriptor.completedAt
        job.progress = 1.0
        // Restore the engine that actually ran. The descriptor knows (it was
        // recorded at completion); the live ScanJob doesn't infer this
        // correctly via fall-through to profile.engine — the profile's
        // default may differ from the engine the user picked for that
        // specific search. Without this, restored rows show the wrong
        // algorithm in the summary.
        if let engine = RecognitionEngine(rawValue: descriptor.engine) {
            job.assignedEngine = engine
        }
        return job
    }

    /// Walk the descriptor's searchPath and ask the cache for any prior
    /// result rows matching the descriptor's search params. Populates
    /// `job.results` with whatever the cache returns. Skips silently if the
    /// volume isn't reachable (Rick's "(offline)" case is handled in the UI
    /// layer by inspecting job.results.isEmpty alongside searchPath
    /// reachability — this method just doesn't crash).
    private nonisolated static func rehydrateResultsFromCache(
        job: ScanJob,
        descriptor: PersistedJobDescriptor
    ) async {
        let fm = FileManager.default
        guard fm.fileExists(atPath: descriptor.searchPath) else { return }

        let refIdentifiers = referenceCacheIdentifiers(
            referencePath: descriptor.referencePath,
            filenames: descriptor.referenceFilenames
        )
        guard !refIdentifiers.isEmpty else { return }

        let engine = RecognitionEngine(rawValue: descriptor.engine) ?? .vision
        let videoFiles = pfFindVideoFiles(at: descriptor.searchPath, skipBundles: false)
        guard !videoFiles.isEmpty else { return }

        var cachedRows: [ClipResult] = []
        for path in videoFiles {
            guard let key = PersonFinderCache.makeKey(
                videoPath: path, personName: descriptor.personName,
                engine: engine, threshold: descriptor.threshold,
                refFilenames: refIdentifiers
            ), let result = PersonFinderCache.shared.lookup(key: key),
                  !result.segments.isEmpty else { continue }
            cachedRows.append(ClipResult(
                videoFilename: result.filename,
                videoPath: result.filePath,
                videoDuration: result.durationSeconds,
                presenceSecs: result.totalPresenceSecs,
                segmentCount: result.segments.count,
                bestDistance: result.segments.map(\.bestDistance).min() ?? 0,
                clipFiles: [],
                outputDir: ""
            ))
        }
        guard !cachedRows.isEmpty else { return }
        await MainActor.run { job.results = cachedRows }
    }
}
