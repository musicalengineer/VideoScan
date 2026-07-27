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
//     filterResults (né filterByPresence — now also applies the
//     match-confidence floor), scanAllVideos, processOneVideo,
//     discoverVideos, runScan
//   • Match-confidence floor (POI cycle-03 promotion, 2026-07-19):
//     presenceRule, matchFloorDecision, PFMatchFilterOutcome (file scope),
//     belowFloorSummaryLine, floorProvenanceLine
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

/// Outcome of the combined match-confidence-floor + min-presence filter
/// (PersonFinderModel.filterResults). Counts exist so the UI can say
/// honestly what was refused — no silent disappearance. File-scope (not
/// nested in PersonFinderModel) so it doesn't infer the class's @MainActor
/// isolation — it's a plain Sendable value used off-main by the scan path.
struct PFMatchFilterOutcome: Sendable {
    var valid: [pfVideoResult] = []
    /// Non-empty-segment videos refused by the confidence floor.
    var belowFloorCount: Int = 0
    /// Videos confirmed only via the short-clip any-hit safeguard.
    var shortClipFallbackCount: Int = 0
    /// Non-empty-segment videos refused by the min-presence-seconds gate
    /// (the pre-existing filter, unchanged).
    var belowPresenceCount: Int = 0
}

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

    // MARK: Match confidence floor (POI cycle-03 promotion, 2026-07-19)
    //
    // The graded minimum-hits rule, promoted from the eval CLI into the
    // production scan path. A video counts as FOUND only when its total
    // matched face observations (pfVideoResult.totalHits) reach the
    // user-set "Match Confidence Floor" (default 7 — the graded config;
    // 1 = legacy any-hit opt-out). The decision REUSES EvalPresenceRule —
    // same code the grade validated, not a reimplementation.
    //
    // Short-clip safeguard (false-negative guard the grade disclosed):
    // a very short video may sample fewer frames than the floor, making
    // the floor unreachable even when the person is in every frame. The
    // pipeline doesn't thread an exact sampled-frame count into
    // pfVideoResult, but every engine populates duration + fps, and the
    // sampling cadence is settings.frameStep — so estimated sampled
    // frames = duration × fps / frameStep (the same arithmetic the scan
    // loop's own frameInterval uses). When that estimate is below the
    // floor, the video falls back to any-hit and the fallback is logged.
    // Unknown duration/fps (estimate 0) also falls back — fails OPEN
    // toward legacy behavior, never toward a silent miss.
    //
    // All pure O(1)/O(n) value math — no I/O, no actors. Worst-case
    // memory: one copied array of kept results (≤ input size).

    /// Map the user's floor to the shared rule: 1 (or below, defensively)
    /// = the legacy any-hit arm; otherwise the graded minimum-hits mode.
    nonisolated static func presenceRule(floor: Int) -> EvalPresenceRule {
        floor <= 1 ? .legacy : .minimumHits(floor: floor)
    }

    /// Video-level "is the person in this video?" decision.
    /// Returns `confirmed` plus whether the short-clip any-hit fallback is
    /// what confirmed it (true only when the fallback CHANGED the outcome —
    /// i.e. hits were nonzero but below the floor on a too-short video).
    nonisolated static func matchFloorDecision(
        totalHits: Int,
        durationSeconds: Double,
        fps: Double,
        floor: Int,
        frameStep: Int
    ) -> (confirmed: Bool, usedShortClipFallback: Bool) {
        let effectiveFloor = max(1, floor)
        let rule = presenceRule(floor: effectiveFloor)
        let confirmedByFloor =
            rule.presence(hits: totalHits) == EvalPresenceRule.confirmedSpelling
        // Fallback is only relevant when the floor refused a real match.
        guard effectiveFloor > 1, !confirmedByFloor, totalHits > 0 else {
            return (confirmedByFloor, false)
        }
        let step = max(1, frameStep)
        let estimatedSampled = (durationSeconds > 0 && fps > 0)
            ? Int((durationSeconds * fps / Double(step)).rounded(.down))
            : 0
        if estimatedSampled < effectiveFloor {
            return (true, true)   // any-hit fallback for short/unknown clips
        }
        return (false, false)
    }

    /// Partition scan results by the match-confidence floor and the
    /// configured min-presence threshold. Supersedes the old private
    /// `filterByPresence` (whose presence semantics are preserved exactly,
    /// including the keep-empty-segment-results-when-minPresence≤0 quirk —
    /// downstream ClipResult builders still guard on `!segments.isEmpty`).
    /// Internal (not private) so unit tests can pin the gate directly —
    /// the seam PersonFinderPresenceArithmeticTests asked for.
    nonisolated static func filterResults(
        _ ordered: [pfVideoResult?],
        settings: PersonFinderSettings
    ) -> PFMatchFilterOutcome {
        var outcome = PFMatchFilterOutcome()
        let minSecs = settings.minPresenceSecs
        let floor = max(1, settings.matchConfidenceFloor)
        for r in ordered.compactMap({ $0 }) {
            let hasSegments = !r.segments.isEmpty
            // Floor gate — only for videos that would otherwise show as
            // found (segments exist). Empty-segment results were never
            // "found" and keep their legacy handling below.
            if hasSegments {
                let decision = matchFloorDecision(
                    totalHits: r.totalHits,
                    durationSeconds: r.durationSeconds,
                    fps: r.fps,
                    floor: floor,
                    frameStep: settings.frameStep
                )
                if !decision.confirmed {
                    outcome.belowFloorCount += 1
                    continue
                }
                if decision.usedShortClipFallback {
                    outcome.shortClipFallbackCount += 1
                }
            }
            // Presence gate — byte-for-byte the old filterByPresence logic.
            if minSecs > 0 && r.totalPresenceSecs < minSecs {
                if hasSegments { outcome.belowPresenceCount += 1 }
                continue
            }
            outcome.valid.append(r)
        }
        return outcome
    }

    /// The honest console line for floor-refused videos — pure + static so
    /// the exact wording is pinned by tests (MFO summary-line convention).
    nonisolated static func belowFloorSummaryLine(count: Int, floor: Int) -> String {
        let videos = count == 1 ? "video" : "videos"
        return "\(count) \(videos) had brief possible matches below the confidence floor (\(floor)) — not counted as found. Set the floor to 1 in search settings to count any single match."
    }

    /// One provenance line per job recording the floor in effect — written
    /// to videoscan.log next to the "Starting search…" headline. Pure +
    /// static so the format is pinned by tests (MFO logging convention).
    nonisolated static func floorProvenanceLine(personName: String, floor: Int) -> String {
        let f = max(1, floor)
        let rule = presenceRule(floor: f)
        let detail = f > 1
            ? "rule=\(rule.mode.rawValue), short clips fall back to any match"
            : "rule=\(rule.mode.rawValue), any single match counts"
        return "Match confidence floor for \(personName): \(f) (\(detail))"
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
        // CoreML reference embeddings (all backends) — they were computed
        // from the prior photos. The engine dispatchers rebuild the cache
        // on the next scan.
        job.assignedRefEmbeddings = [:]
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
        let threshold = profile.thresholdForEngine(engine)
        let refIdentifiers = Self.referenceCacheIdentifiers(
            referencePath: profile.referencePath,
            filenames: job.assignedFaces.map(\.sourceFilename)
        )
        guard !refIdentifiers.isEmpty else { return }

        let searchPath = job.searchPath
        let jobSettings = self.settings
        // Reconstruct the embed variant EXACTLY as a live run of this job
        // would: global settings overlaid with the profile, engine resolved
        // (mirrors runJob's jobSettings construction). Codex post-merge #2:
        // this path used to read the (never-set-here) process global.
        var overlaySettings = self.settings
        overlaySettings.applyProfile(profile)
        overlaySettings.recognitionEngine = engine
        let embedVariant = PersonFinderCache.embedVariant(for: overlaySettings)
        // Capture the catalog writeback closure on MainActor so the
        // detached Task below can invoke it inside its own MainActor.run.
        // The closure's `@MainActor` annotation makes its type Sendable
        // across the actor hop.
        let onComplete = self.onScanComplete
        // Identity-narrowing annotation for the restored rows — same
        // capture pattern as onComplete.
        let onAnnotate: @MainActor (ScanJob) -> Void = { [weak self] finishedJob in
            self?.annotateIdentityPlausibility(for: finishedJob)
        }

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
                    refFilenames: refIdentifiers,
                    embedVariant: embedVariant
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
            let filterOutcome = Self.filterResults(cachedResults, settings: jobSettings)
            let validResults = filterOutcome.valid

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
                // Honest accounting: cached matches the current floor refuses
                // are reported, never silently dropped.
                if filterOutcome.belowFloorCount > 0 {
                    job.appendLog(Self.belowFloorSummaryLine(
                        count: filterOutcome.belowFloorCount,
                        floor: max(1, jobSettings.matchConfidenceFloor)
                    ))
                }
                let (confirmed, suspected) = Self.splitByConfidence(
                    validResults, threshold: threshold
                )
                onComplete?(job.personLabel, confirmed, suspected)
                onAnnotate(job)
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

        // Embed-variant cache namespace (alignment toggle, AdaFace model
        // version, hybrid's fallback threshold) is computed per-job from
        // jobSettings and passed explicitly through every makeKey call —
        // the old process-global slot let concurrent jobs overwrite each
        // other and left restore paths unnamespaced (codex post-merge #2).

        // High-level narration to videoscan.log — emitted once volume + engine
        // are known. Per-job verbose detail continues to go to the job's
        // PersistentLog.
        let volumeName = URL(fileURLWithPath: job.searchPath).lastPathComponent
        appLog.write("Starting search for \(personName) on \(volumeName) using \(jobSettings.recognitionEngine.rawValue)")
        // Provenance: one line per job recording the match-confidence floor
        // in effect (POI cycle-03 promotion). Same pure-line-builder pattern
        // as MediaFileOperations.startSummaryLine.
        appLog.write(Self.floorProvenanceLine(
            personName: personName, floor: jobSettings.matchConfidenceFloor
        ))

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

        // AdaFace job-level pre-flight (#144 QA): a missing model must bail
        // the job ONCE with a clear error — not emit a per-video error for
        // thousands of files that all end "0 hits" (the removed dlib
        // pre-flight's UX). Synchronous existence probe only; an asset
        // that exists but is corrupt still surfaces via the dispatcher's
        // "found but failed to load" error on first video.
        // Hybrid is deliberately NOT gated: it degrades to Vision-only.
        if jobSettings.recognitionEngine == .adaface,
           !AdaFaceModelLoader.modelAssetsPresent() {
            let msg = "⚠ AdaFace model not installed — place \(AdaFaceModelLoader.modelBaseName).mlpackage in \(AdaFaceModelLoader.modelsDir)/ (see docs/design/adaface-plugin.md)."
            job.appendLog(msg)
            osLog.error("runJob bailed: AdaFace model missing (person=\(jobSettings.personName, privacy: .public))")
            job.status = .failed("AdaFace model missing")
            return
        }

        // All engines (Vision, ArcFace, AdaFace, Hybrid) need loaded reference
        // faces — the dlib-specific Python-config pre-flight went with the
        // dlib seat (#144).
        guard !faces.isEmpty else {
            let msg = "⚠ Load reference photos first. Select a person with \"Find Person\" or load photos globally."
            job.appendLog(msg)
            osLog.error("runJob bailed: faces.isEmpty (person=\(jobSettings.personName, privacy: .public), engine=\(jobSettings.recognitionEngine.rawValue, privacy: .public))")
            return
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

        let prints = Self.visionFeaturePrints(for: jobSettings.recognitionEngine, faces: faces)
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
        let effectiveFloor = max(1, jobSettings.matchConfidenceFloor)
        job.appendLog("  Match confidence floor: \(effectiveFloor)\(effectiveFloor > 1 ? " (short clips fall back to any match)" : " (any single match counts)")")
        if jobSettings.recognitionEngine == .arcface {
            // ArcFace ignores the generic Threshold above and uses its own cosine
            // threshold. Log the engine-specific knobs so each run is self-documenting
            // (especially the landmark-alignment switch, which changes the cache namespace).
            job.appendLog("  ArcFace: landmark alignment \(jobSettings.arcfaceLandmarkAlignment ? "ON (norm_crop lm-v1)" : "OFF (bbox crop)")")
            job.appendLog("  ArcFace: cosine threshold \(String(format: "%.2f", jobSettings.arcfaceThreshold)), inference concurrency \(jobSettings.arcfaceInferenceConcurrency)")
        }
        if jobSettings.recognitionEngine == .adaface {
            // Same self-documenting rule for AdaFace (#144). Serialized
            // inference only — AdaFace never joins the ArcFace K>1 pool.
            job.appendLog("  AdaFace: landmark alignment \(jobSettings.arcfaceLandmarkAlignment ? "ON (norm_crop lm-v1)" : "OFF (bbox crop)")")
            job.appendLog("  AdaFace: cosine threshold \(String(format: "%.2f", jobSettings.adafaceThreshold)) (model \(FaceEmbeddingBackend.adaface))")
        }
        if let profile = job.assignedProfile {
            job.appendLog("  Profile rejected: \(profile.rejectedFiles.count) files")
        }
        job.appendLog("  References loaded: \(faces.count)")
        osLog.info("References ready: \(faces.count) face(s) for \(jobSettings.personName, privacy: .public)")
        job.appendLog("  Feature prints for matching: \(prints.count)")
        let settings = jobSettings
        let dash = self.dashboard
        // Capture writeback on MainActor so the static nonisolated runScan
        // can invoke it inside its own MainActor.run completion hop.
        let onComplete = self.onScanComplete
        // Identity-narrowing annotation, same capture pattern. Weak self:
        // the closure runs at scan completion, possibly after teardown.
        let onAnnotate: @MainActor (ScanJob) -> Void = { [weak self] finishedJob in
            self?.annotateIdentityPlausibility(for: finishedJob)
        }
        job.scanTask = Task { [weak self, weak job] in
            guard let job else { return }
            await MainActor.run {
                dash?.visionActive = settings.recognitionEngine == .vision
                    || settings.recognitionEngine == .arcface
                    || settings.recognitionEngine == .adaface
                switch settings.recognitionEngine {
                case .arcface: dash?.activeEngineLabel = "ArcFace / CoreML + ANE"
                case .adaface: dash?.activeEngineLabel = "AdaFace / CoreML + ANE"
                default:       dash?.activeEngineLabel = "Vision / ANE"
                }
            }
            await PersonFinderModel.runScan(job: job, prints: prints, settings: settings, refFilenames: refCacheIdentifiers, dashboard: dash, onComplete: onComplete, onAnnotate: onAnnotate)
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
        job.pauseElapsedTimer()
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
        let personName = job.assignedProfile?.name ?? "(global)"
        let volumeName = URL(fileURLWithPath: job.searchPath).lastPathComponent
        if job.wasRestoredFromDisk {
            // Restored-from-disk pause: scanTask was nil'd by app exit, so
            // pauseGate.resume() would be a no-op. Re-invoke startJob — the
            // per-file PersonFinderCache lookup inside the scan loop skips
            // every video already cached and picks up where the user left
            // off. Wall-time cost of the skip is dominated by disk speed
            // (~minutes on LaCie, ~seconds on SSD). Reset the flag so a
            // subsequent in-process pause/resume follows the gate path.
            //
            // CRITICAL: startJob's first guard is `!job.status.isActive`,
            // and .paused IS considered active. Clear status to .idle so
            // startJob proceeds. The transition .paused → .idle → (whatever
            // startJob lands on) is brief and on MainActor, so no observer
            // sees the .idle state in practice. Caught 2026-06-03 by
            // resumeFromDiskPausedJobInvokesStartJobPath regression test.
            job.wasRestoredFromDisk = false
            job.status = .idle
            osLog.info("Job resumed (restored from disk → restart with cache skip): \(job.searchPath, privacy: .public)")
            appLog.write("Resumed search for \(personName) on \(volumeName) — cache replay")
            startJob(job)
        } else {
            // In-process pause: there's a live scanTask awaiting the gate.
            // Releasing the gate lets it continue between videos.
            Task { await job.pauseGate.resume() }
            job.status = .scanning
            job.resumeElapsedTimer()
            osLog.info("Job resumed (in-process): \(job.searchPath, privacy: .public)")
            appLog.write("Resumed search for \(personName) on \(volumeName)")
        }
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

    // filterByPresence was superseded 2026-07-19 by filterResults (above),
    // which layers the match-confidence floor on top of the identical
    // min-presence semantics.

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
        let cacheThreshold = settings.thresholdForEngine(settings.recognitionEngine)
        let embedVariant = PersonFinderCache.embedVariant(for: settings)
        var cachedCount = 0
        for path in videoFiles {
            if let key = PersonFinderCache.makeKey(
                videoPath: path, personName: settings.personName,
                engine: settings.recognitionEngine, threshold: cacheThreshold,
                refFilenames: refFilenames, embedVariant: embedVariant
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
                // Compose the SAME refHash makeKey stores (incl. variant),
                // or the diagnostic disagrees with the keys it explains.
                let currentRefHash = PersonFinderCache.composedRefHash(
                    refFilenames, embedVariant: embedVariant)
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
                    refFilenames: refFilenames, embedVariant: embedVariant
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
        let matchFloor = max(1, settings.matchConfidenceFloor)

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
                // Match-confidence floor decision (POI cycle-03 promotion):
                // computed once here so the live row, the hit counter, and
                // the per-video console line all agree — and agree with the
                // post-loop filterResults pass in runScan.
                let floorDecision: (confirmed: Bool, usedShortClipFallback: Bool)? =
                    result.flatMap { r in
                        guard !r.segments.isEmpty else { return nil }
                        return matchFloorDecision(
                            totalHits: r.totalHits,
                            durationSeconds: r.durationSeconds,
                            fps: r.fps,
                            floor: matchFloor,
                            frameStep: settings.frameStep
                        )
                    }
                // Build the per-video row up-front (outside MainActor.run) so
                // the hop into MainActor stays a quick assignment. Same
                // shape and floor + presence gates as the post-loop batch
                // publish in runScan, so a row appearing live is the same
                // row that ends up in the final ordered list.
                let liveRow: ClipResult? = {
                    guard let r = result, floorDecision?.confirmed == true else { return nil }
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
                    if floorDecision?.confirmed == true {
                        job.videosWithHits += 1
                        dash?.lastMatchFlashAt = Date()
                    }
                    // Honest per-video accounting for the floor — refused or
                    // rescued videos say so in the console, never vanish.
                    if let r = result, let d = floorDecision {
                        if !d.confirmed {
                            job.appendLog("  ↳ \(r.filename) — \(r.totalHits) brief match(es) below the confidence floor (\(matchFloor)); not counted as found")
                        } else if d.usedShortClipFallback {
                            job.appendLog("  ↳ \(r.filename) — very short clip: kept with \(r.totalHits) match(es) via the any-match fallback (too few sampled frames to reach the floor of \(matchFloor))")
                        }
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
        let threshold = settings.thresholdForEngine(settings.recognitionEngine)
        let embedVariant = PersonFinderCache.embedVariant(for: settings)

        // Cache check BEFORE waiting for disk warm — cache hits skip I/O entirely
        if let cacheKey = PersonFinderCache.makeKey(
            videoPath: filePath, personName: settings.personName,
            engine: settings.recognitionEngine,
            threshold: threshold, refFilenames: refFilenames,
            embedVariant: embedVariant
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
        // Terminal best-distance publish — unthrottled so the final value of a
        // video is never dropped by the throttle on a short tail (P2-4).
        let distFnFinal: @Sendable (Float) async -> Void = { dist in
            await MainActor.run { if dist < job.bestDist { job.bestDist = dist } }
        }

        @Sendable func runVision() async -> pfVideoResult? {
            await pfProcessVideo(
                filePath: videoFiles[idx], prints: prints,
                settings: settings, index: idx + 1, total: total,
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

        @Sendable func runArcFace() async -> pfVideoResult? {
            await pfRunArcFaceEngine(
                filePath: videoFiles[idx], idx1: idx + 1, total: total,
                settings: settings, job: job, dash: dash,
                progressState: progressState,
                logFn: logFn, progressFn: progressFn, distFn: distFn,
                distFnFinal: distFnFinal
            )
        }

        @Sendable func runAdaFace() async -> pfVideoResult? {
            await pfRunAdaFaceEngine(
                filePath: videoFiles[idx], idx1: idx + 1, total: total,
                settings: settings, job: job, dash: dash,
                progressState: progressState,
                logFn: logFn, progressFn: progressFn, distFn: distFn,
                distFnFinal: distFnFinal
            )
        }

        let r: pfVideoResult?
        switch settings.recognitionEngine {
        case .vision:  r = await runVision()
        case .arcface: r = await runArcFace()
        case .adaface: r = await runAdaFace()
        case .hybrid:
            // Vision first; AdaFace second look on misses (#144 — the
            // fallback seat dlib used to hold). A missing AdaFace model
            // logs its actionable error inside pfRunAdaFaceEngine and
            // returns nil, so the Vision result (0 hits) still stands.
            let v = await runVision()
            if let v, !v.segments.isEmpty {
                r = v
            } else {
                await job.appendLog("[hybrid] Vision: 0 hits — falling back to AdaFace")
                r = await runAdaFace() ?? v
            }
        }

        if let cacheKey = PersonFinderCache.makeKey(
            videoPath: filePath, personName: settings.personName,
            engine: settings.recognitionEngine,
            threshold: threshold, refFilenames: refFilenames,
            embedVariant: embedVariant
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
        )?,
        onAnnotate: (@MainActor (ScanJob) -> Void)? = nil
    ) async {
        let path = await job.searchPath
        let scanThreshold = settings.thresholdForEngine(settings.recognitionEngine)
        let scanRefHash = PersonFinderCache.cachedRefHash(refFilenames)
        let personLabel = settings.personName.isEmpty ? "(global)" : settings.personName
        // Main app log: the headline the user wants to skim — who, where, on what.
        osLog.notice("Search for \(personLabel, privacy: .public) on \(path, privacy: .public) — engine=\(settings.recognitionEngine.rawValue, privacy: .public)")
        // Per-job face_detect log: full cache-key details, for cache-miss diagnosis.
        let scanFloor = max(1, settings.matchConfidenceFloor)
        await job.appendLog("Search for \(personLabel) on \(path)")
        await job.appendLog("  engine=\(settings.recognitionEngine.rawValue) threshold=\(scanThreshold) floor=\(scanFloor) refs=\(refFilenames.count) refHash=\(scanRefHash)")
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

        // Match-confidence floor + presence filter — with honest accounting
        // for everything the gates refused (no silent disappearance).
        let filterOutcome = filterResults(orderedResults, settings: settings)
        let validResults = filterOutcome.valid
        if filterOutcome.belowFloorCount > 0 {
            await job.appendLog("\n" + Self.belowFloorSummaryLine(
                count: filterOutcome.belowFloorCount, floor: scanFloor
            ))
        }
        if filterOutcome.shortClipFallbackCount > 0 {
            await job.appendLog("Short-clip safeguard: \(filterOutcome.shortClipFallbackCount) very short video(s) kept with any match (too few sampled frames to reach the floor)")
        }
        if filterOutcome.belowPresenceCount > 0 {
            await job.appendLog("\nPresence filter: \(validResults.count) kept, \(filterOutcome.belowPresenceCount) below \(Int(settings.minPresenceSecs))s\n")
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
                // "Vision" / "ArcFace" / "AdaFace" / "Hybrid". Matches the UI
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

                // Identity narrowing: stamp plausibility + reason on each
                // result row from the POI's priors × the catalog's dossier
                // evidence (inferred date, scene captions). After
                // finalizeResults so it annotates the canonical row list.
                onAnnotate?(job)
            }
        }
    }

    // MARK: - Session restore (issue #89, part 2)

    /// Vision feature prints for the engines whose primary OR fallback pass
    /// consumes them: `.vision` and `.hybrid`. Hybrid's FIRST pass is Vision
    /// — the old `== .vision` gate handed hybrid an empty print array, so
    /// its Vision pass could never match and every video fell straight
    /// through to the fallback engine (codex post-merge review, #144).
    /// The CoreML engines embed references through their own pipelines and
    /// take no prints. Extracted so tests pin the exact function runJob uses.
    nonisolated static func visionFeaturePrints(
        for engine: RecognitionEngine,
        faces: [ReferenceFace]
    ) -> [VNFeaturePrintObservation] {
        switch engine {
        case .vision, .hybrid:   return faces.map(\.featurePrint)
        case .arcface, .adaface: return []
        }
    }

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
        let threshold = settings.thresholdForEngine(engine)
        // Persist the cache namespace this scan's keys were built with, so
        // rehydration reproduces identical keys without reconstruction
        // logic that could drift (codex post-merge #2). Belt-and-suspenders
        // engine pin: settings.recognitionEngine should already equal the
        // effective engine here.
        var variantSettings = settings
        variantSettings.recognitionEngine = engine
        let embedVariant = PersonFinderCache.embedVariant(for: variantSettings)
        let referencePath = job.assignedProfile?.referencePath ?? settings.referencePath
        let referenceFilenames = job.assignedFaces.map(\.sourceFilename)
        // Record the job's current status so a paused scan can come back as
        // .paused after app restart instead of being silently promoted to
        // .done. Only .paused and .done are meaningful across launches;
        // anything else (transient .scanning / .loading / .compiling) means
        // either the persist was triggered mid-flight (unusual) or the user
        // hasn't reached a bookmarkable state — we collapse those to .done
        // so the row is at least visible, with progress reflecting reality.
        let statusRaw: String
        switch job.status {
        case .paused:        statusRaw = "paused"
        default:             statusRaw = "done"
        }
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
            elapsedSecs: job.elapsedSecs,
            statusRaw: statusRaw,
            embedVariant: embedVariant
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

        var pendingRehydrations: [(ScanJob, PersistedJobDescriptor)] = []
        pendingRehydrations.reserveCapacity(descriptors.count)

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
            pendingRehydrations.append((job, descriptor))
        }

        // CONCURRENCY-CAPPED background rehydration. Each
        // rehydrateResultsFromCache call walks the descriptor's search path
        // (potentially a slow USB / network volume) via pfFindVideoFiles
        // and hashes ~500–1100 reference images per profile via blocking
        // getattrlist syscalls inside cachedRefHash. Rick's catalog had 9
        // persisted descriptors as of 2026-06-03 (matt, donna, rick, etc.)
        // with timmy at 1087 reference images, matt at 813, donna at 687…
        //
        // History of this site:
        //  - Original code: one Task.detached per descriptor in a loop, all
        //    fanning out in parallel. With N ≥ 4, blocking syscalls saturate
        //    Swift's cooperative pool (~14 slots on M4 Max) and starve other
        //    async tasks. Originally misdiagnosed (2026-06-02 evening) as
        //    the cause of the Triage Delete-Permanently hang; the real cause
        //    was the chained-.sheet race (fixed in 03b5600 / 000efd1).
        //  - Serialized variant (9be626e): one job at a time, no pool risk
        //    but pathologically slow startup — 9 × ~1 min on LaCie = ~9 min
        //    before the user could start any new work. Rick observed this
        //    2026-06-03 with the Matt scan apparently hanging when it was
        //    actually just queued behind 8 prior rehydrations.
        //
        // Current shape: TaskGroup with a 3-way concurrency cap. Each "slot"
        // takes one job from the queue, awaits its rehydration, then picks
        // up the next. Caps pool occupancy at 3 (out of ~14), leaving plenty
        // of headroom for UI tasks and new scans, while giving 3× the
        // parallelism vs serial. Empirically the disk-bound stages don't
        // benefit much past 3 (they fight over the same I/O bandwidth) so
        // 3 is the knee of the curve.
        let maxConcurrentRehydrations = 3
        // Identity-narrowing annotation for rehydrated rows. Weak self —
        // rehydration can outlive the model under test teardown. (The
        // provider may not be wired yet at app launch; its didSet
        // re-annotates all jobs when it arrives, so both orderings work.)
        let onAnnotate: @MainActor (ScanJob) -> Void = { [weak self] finishedJob in
            self?.annotateIdentityPlausibility(for: finishedJob)
        }
        // The floor in effect NOW governs which cached rows come back — a
        // row a fresh run would refuse must not resurrect via restart.
        // Captured on MainActor before the detached hop.
        let matchFloor = max(1, settings.matchConfidenceFloor)
        let frameStep = settings.frameStep
        Task.detached(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                var slotIndex = 0
                // Fill the initial slot quota.
                while slotIndex < min(maxConcurrentRehydrations, pendingRehydrations.count) {
                    let pair = pendingRehydrations[slotIndex]
                    group.addTask {
                        await Self.rehydrateResultsFromCache(job: pair.0, descriptor: pair.1, matchFloor: matchFloor, frameStep: frameStep, onAnnotate: onAnnotate)
                    }
                    slotIndex += 1
                }
                // As each completes, start the next pending one — keeps at
                // most `maxConcurrentRehydrations` running concurrently.
                while await group.next() != nil {
                    if slotIndex < pendingRehydrations.count {
                        let pair = pendingRehydrations[slotIndex]
                        group.addTask {
                            await Self.rehydrateResultsFromCache(job: pair.0, descriptor: pair.1, matchFloor: matchFloor, frameStep: frameStep, onAnnotate: onAnnotate)
                        }
                        slotIndex += 1
                    }
                }
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
        // Restore the status the job had when persisted. Old descriptors
        // (written before 2026-06-03) have statusRaw == nil and are treated
        // as .done. Paused jobs come back as .paused with progress
        // reflecting actual completion so the row shows e.g. "40% paused"
        // not the misleading "100% done" that the pre-fix code produced.
        if descriptor.statusRaw == "paused" {
            job.status = .paused
            let total = max(descriptor.videosTotal, 1)
            job.progress = Double(descriptor.videosScanned) / Double(total)
        } else {
            job.status = .done
            job.progress = 1.0
        }
        job.completedAt = descriptor.completedAt
        job.wasRestoredFromDisk = true
        // Restore the engine that actually ran. The descriptor knows (it was
        // recorded at completion); the live ScanJob doesn't infer this
        // correctly via fall-through to profile.engine — the profile's
        // default may differ from the engine the user picked for that
        // specific search. Without this, restored rows show the wrong
        // algorithm in the summary.
        if let engine = RecognitionEngine.migratePersisted(descriptor.engine) {
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
        descriptor: PersistedJobDescriptor,
        matchFloor: Int,
        frameStep: Int,
        onAnnotate: (@MainActor (ScanJob) -> Void)? = nil
    ) async {
        let fm = FileManager.default
        guard fm.fileExists(atPath: descriptor.searchPath) else { return }

        let refIdentifiers = referenceCacheIdentifiers(
            referencePath: descriptor.referencePath,
            filenames: descriptor.referenceFilenames
        )
        guard !refIdentifiers.isEmpty else { return }

        let engine = RecognitionEngine.migratePersisted(descriptor.engine) ?? .vision
        let videoFiles = pfFindVideoFiles(at: descriptor.searchPath, skipBundles: false)
        guard !videoFiles.isEmpty else { return }

        var cachedRows: [ClipResult] = []
        var hiddenBelowFloor = 0
        for path in videoFiles {
            guard let key = PersonFinderCache.makeKey(
                videoPath: path, personName: descriptor.personName,
                engine: engine, threshold: descriptor.threshold,
                refFilenames: refIdentifiers,
                // nil = pre-#144 descriptor → legacy "" namespace, correct
                // for the vision/arcface-unaligned rows those scans wrote.
                embedVariant: descriptor.embedVariant ?? ""
            ), let result = PersonFinderCache.shared.lookup(key: key),
                  !result.segments.isEmpty else { continue }
            // Same floor decision as a live scan — restored rows and fresh
            // rows must agree for the same cached evidence.
            let decision = matchFloorDecision(
                totalHits: result.totalHits,
                durationSeconds: result.durationSeconds,
                fps: result.fps,
                floor: matchFloor,
                frameStep: frameStep
            )
            guard decision.confirmed else {
                hiddenBelowFloor += 1
                continue
            }
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
        guard !cachedRows.isEmpty || hiddenBelowFloor > 0 else { return }
        await MainActor.run {
            job.results = cachedRows
            if hiddenBelowFloor > 0 {
                job.appendLog(belowFloorSummaryLine(count: hiddenBelowFloor, floor: matchFloor))
            }
            onAnnotate?(job)
        }
    }
}
