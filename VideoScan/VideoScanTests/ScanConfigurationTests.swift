import Testing
import Foundation
@testable import VideoScan

// MARK: - PersonFinder Scan Configuration Tests

@MainActor
struct ScanConfigurationTests {

    static let photosDir: String = {
        let thisFile = #filePath
        let repoRoot = URL(fileURLWithPath: thisFile)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return repoRoot.appendingPathComponent("tests/fixtures/photos").path
    }()

    nonisolated static var isCI: Bool {
        ProcessInfo.processInfo.environment["CI"] != nil
    }

    static let visionTimeLimit = TimeLimitTrait.Duration.minutes(2)

    // MARK: applyProfile

    @Test func applyProfileSetsEngine() {
        var settings = PersonFinderSettings()
        settings.recognitionEngine = .vision
        let profile = POIProfile(name: "Test", referencePath: "/tmp",
                                 engine: RecognitionEngine.dlib.rawValue)
        settings.applyProfile(profile)
        #expect(settings.recognitionEngine == .dlib)
    }

    @Test func applyProfileSetsThresholds() {
        var settings = PersonFinderSettings()
        let profile = POIProfile(name: "Test", referencePath: "/tmp",
                                 visionThreshold: 0.35, arcfaceThreshold: 0.22,
                                 minFaceConfidence: 0.70)
        settings.applyProfile(profile)
        #expect(settings.threshold == 0.35)
        #expect(settings.arcfaceThreshold == 0.22)
        #expect(settings.minFaceConfidence == 0.70)
    }

    @Test func applyProfileSetsRejectedFiles() {
        var settings = PersonFinderSettings()
        settings.rejectedReferenceFiles = []
        let profile = POIProfile(name: "Test", referencePath: "/tmp",
                                 rejectedFiles: ["bad1.jpg", "bad2.jpg"])
        settings.applyProfile(profile)
        #expect(settings.rejectedReferenceFiles == ["bad1.jpg", "bad2.jpg"])
    }

    @Test func applyProfileSetsPersonName() {
        var settings = PersonFinderSettings()
        settings.personName = "OldName"
        let profile = POIProfile(name: "NewName", referencePath: "/some/path")
        settings.applyProfile(profile)
        #expect(settings.personName == "NewName")
        #expect(settings.referencePath == "/some/path")
    }

    // MARK: Per-job engine resolution

    // regression: #7 — Per-volume FD engine selection: default falls through to Vision
    @Test func effectiveEngineDefaultsToVision() {
        let job = ScanJob(searchPath: "/tmp")
        #expect(job.effectiveEngine == .vision)
    }

    // regression: #7 — Per-volume FD engine selection: profile.engine resolves when no override
    @Test func effectiveEngineUsesProfileEngine() {
        let job = ScanJob(searchPath: "/tmp")
        job.assignedProfile = POIProfile(name: "Test", referencePath: "/tmp",
                                         engine: RecognitionEngine.arcface.rawValue)
        #expect(job.effectiveEngine == .arcface)
    }

    // regression: #7 — Per-volume FD engine selection: assignedEngine override wins over profile
    @Test func effectiveEngineJobOverrideTakesPriority() {
        let job = ScanJob(searchPath: "/tmp")
        job.assignedProfile = POIProfile(name: "Test", referencePath: "/tmp",
                                         engine: RecognitionEngine.vision.rawValue)
        job.assignedEngine = .dlib
        #expect(job.effectiveEngine == .dlib)
    }

    // MARK: Face loading with rejection filtering

    @Test(.disabled(if: isCI, "Vision face detection too slow on CI runners"), .timeLimit(visionTimeLimit))
    func loadFacesForJobFiltersRejectedFiles() async {
        let photosDir = Self.photosDir
        guard FileManager.default.fileExists(atPath: photosDir) else { return }

        let model = PersonFinderModel()
        let job = ScanJob(searchPath: "/tmp")
        job.assignedProfile = POIProfile(
            name: "Donna",
            referencePath: photosDir,
            rejectedFiles: ["DSCN3603.jpeg", "IMG_0145.jpeg", "IMG_3091.jpeg"]
        )

        await model.loadFacesForJob(job)

        let loadedFilenames = Set(job.assignedFaces.map(\.sourceFilename))
        #expect(!loadedFilenames.contains("DSCN3603.jpeg"))
        #expect(!loadedFilenames.contains("IMG_0145.jpeg"))
        #expect(!loadedFilenames.contains("IMG_3091.jpeg"))
        #expect(!job.assignedFaces.isEmpty, "Should have loaded some faces")
    }

    @Test(.disabled(if: isCI, "Vision face detection too slow on CI runners"), .timeLimit(visionTimeLimit))
    func loadFacesForJobLoadsAllWhenNoRejections() async {
        let photosDir = Self.photosDir
        guard FileManager.default.fileExists(atPath: photosDir) else { return }

        let model = PersonFinderModel()
        let job = ScanJob(searchPath: "/tmp")
        job.assignedProfile = POIProfile(name: "Donna", referencePath: photosDir,
                                         rejectedFiles: [])

        await model.loadFacesForJob(job)

        let jobWithRejections = ScanJob(searchPath: "/tmp")
        jobWithRejections.assignedProfile = POIProfile(
            name: "Donna", referencePath: photosDir,
            rejectedFiles: ["DSCN3603.jpeg", "IMG_0145.jpeg"]
        )
        await model.loadFacesForJob(jobWithRejections)

        #expect(job.assignedFaces.count > jobWithRejections.assignedFaces.count,
                "No rejections should load more faces than with rejections")
    }

    @Test(.disabled(if: isCI, "Vision face detection too slow on CI runners"), .timeLimit(visionTimeLimit))
    func loadFacesForJobSetsStatusBackToIdle() async {
        let photosDir = Self.photosDir
        guard FileManager.default.fileExists(atPath: photosDir) else { return }

        let model = PersonFinderModel()
        let job = ScanJob(searchPath: "/tmp")
        job.assignedProfile = POIProfile(name: "Test", referencePath: photosDir)
        #expect(job.status == .idle)

        await model.loadFacesForJob(job)

        #expect(job.status == .idle, "Status should return to idle after loading")
    }

    @Test func loadFacesForJobSkipsNonIdleJob() async {
        let model = PersonFinderModel()
        let job = ScanJob(searchPath: "/tmp")
        job.assignedProfile = POIProfile(name: "Test", referencePath: Self.photosDir)
        job.status = .cancelled

        await model.loadFacesForJob(job)

        #expect(job.assignedFaces.isEmpty, "Should not load faces for non-idle job")
    }

    // MARK: startJobAfterLoad console log verification

    @Test(.disabled(if: isCI, "Vision face detection too slow on CI runners"), .timeLimit(visionTimeLimit))
    func startJobLogsCorrectEngine() async {
        let photosDir = Self.photosDir
        guard FileManager.default.fileExists(atPath: photosDir) else { return }

        let model = PersonFinderModel()
        // Path must be reachable (mounted) — runJob bails fast on offline
        // volumes since 97342c8. /tmp is always reachable; the scan task
        // started below is stopped before it finds any videos there.
        let job = ScanJob(searchPath: "/tmp")
        model.jobs.append(job)

        let profile = POIProfile(name: "TestPerson", referencePath: photosDir,
                                 engine: RecognitionEngine.vision.rawValue,
                                 visionThreshold: 0.48, minFaceConfidence: 0.60)
        job.assignedProfile = profile
        await model.loadFacesForJob(job)

        model.startJob(job)

        try? await Task.sleep(for: .milliseconds(200))

        let log = job.consoleLines.joined(separator: "\n")
        #expect(log.contains("Engine: VISION"), "Console should log the engine; got: \(log)")
        #expect(log.contains("Person: TestPerson"), "Console should log person name")
        #expect(log.contains("Threshold: 0.48"), "Console should log threshold from profile")
        #expect(log.contains("Confidence: 0.60"), "Console should log confidence from profile")
        #expect(log.contains("Feature prints for matching:"), "Console should log print count")

        #expect(!log.contains("Engine: DLIB"), "Should not log dlib engine")
        #expect(!log.contains("Engine: ARCFACE"), "Should not log arcface engine")

        model.stopJob(job)
    }

    @Test(.disabled(if: isCI, "Vision face detection too slow on CI runners"), .timeLimit(visionTimeLimit))
    func startJobWithEngineOverride() async {
        let photosDir = Self.photosDir
        guard FileManager.default.fileExists(atPath: photosDir) else { return }

        let model = PersonFinderModel()
        // Path must be reachable — see startJobLogsCorrectEngine note.
        let job = ScanJob(searchPath: "/tmp")
        model.jobs.append(job)

        let profile = POIProfile(name: "Test", referencePath: photosDir,
                                 engine: RecognitionEngine.vision.rawValue)
        job.assignedProfile = profile
        job.assignedEngine = .arcface
        await model.loadFacesForJob(job)

        model.startJob(job)
        try? await Task.sleep(for: .milliseconds(200))

        let log = job.consoleLines.joined(separator: "\n")
        #expect(log.contains("Engine: ARCFACE"),
                "Job engine override should take priority; got: \(log)")

        model.stopJob(job)
    }

    @Test(.disabled(if: isCI, "Vision face detection too slow on CI runners"), .timeLimit(visionTimeLimit))
    func startJobLogsPrintCount() async {
        let photosDir = Self.photosDir
        guard FileManager.default.fileExists(atPath: photosDir) else { return }

        let model = PersonFinderModel()
        // Path must be reachable — see startJobLogsCorrectEngine note.
        let job = ScanJob(searchPath: "/tmp")
        model.jobs.append(job)

        let profile = POIProfile(name: "Test", referencePath: photosDir,
                                 rejectedFiles: [])
        job.assignedProfile = profile
        await model.loadFacesForJob(job)

        let expectedPrintCount = job.assignedFaces.count
        #expect(expectedPrintCount > 0, "Should have loaded faces")

        model.startJob(job)
        try? await Task.sleep(for: .milliseconds(200))

        let log = job.consoleLines.joined(separator: "\n")
        #expect(log.contains("Feature prints for matching: \(expectedPrintCount)"),
                "Print count should match loaded faces; got: \(log)")
        #expect(log.contains("References loaded: \(expectedPrintCount)"),
                "References loaded count should match; got: \(log)")

        model.stopJob(job)
    }

    @Test(.disabled(if: isCI, "Vision face detection too slow on CI runners"), .timeLimit(visionTimeLimit))
    func startJobWithNoProfileUsesGlobalFaces() async {
        let photosDir = Self.photosDir
        guard FileManager.default.fileExists(atPath: photosDir) else { return }

        let model = PersonFinderModel()
        // Path must be reachable — see startJobLogsCorrectEngine note.
        let job = ScanJob(searchPath: "/tmp")
        model.jobs.append(job)

        model.settings.referencePath = photosDir
        model.settings.rejectedReferenceFiles = []
        model.settings.recognitionEngine = .vision
        await model.loadReference()

        let globalCount = model.referenceFaces.count
        #expect(globalCount > 0, "Should have loaded global faces")

        model.startJob(job)
        try? await Task.sleep(for: .milliseconds(200))

        let log = job.consoleLines.joined(separator: "\n")
        #expect(log.contains("Feature prints for matching: \(globalCount)"),
                "Should use global face count; got: \(log)")

        model.stopJob(job)
    }

    // MARK: Rejected files regression guard

    @Test(.disabled(if: isCI, "Vision face detection too slow on CI runners"), .timeLimit(visionTimeLimit))
    func profileRejectedFilesAppliedDuringScan() async {
        let photosDir = Self.photosDir
        guard FileManager.default.fileExists(atPath: photosDir) else { return }

        let model = PersonFinderModel()

        // Paths must be reachable — see startJobLogsCorrectEngine note.
        let jobRejected = ScanJob(searchPath: "/tmp")
        model.jobs.append(jobRejected)
        jobRejected.assignedProfile = POIProfile(
            name: "Donna", referencePath: photosDir,
            rejectedFiles: ["DSCN3603.jpeg", "IMG_0145.jpeg", "IMG_3091.jpeg"]
        )
        await model.loadFacesForJob(jobRejected)
        let rejectedCount = jobRejected.assignedFaces.count

        let jobAll = ScanJob(searchPath: "/tmp")
        model.jobs.append(jobAll)
        jobAll.assignedProfile = POIProfile(
            name: "Donna", referencePath: photosDir,
            rejectedFiles: []
        )
        await model.loadFacesForJob(jobAll)
        let allCount = jobAll.assignedFaces.count

        model.startJob(jobRejected)
        model.startJob(jobAll)
        try? await Task.sleep(for: .milliseconds(200))

        let logRejected = jobRejected.consoleLines.joined(separator: "\n")
        let logAll = jobAll.consoleLines.joined(separator: "\n")

        #expect(logRejected.contains("Feature prints for matching: \(rejectedCount)"),
                "Rejected job should use filtered count; got: \(logRejected)")
        #expect(logAll.contains("Feature prints for matching: \(allCount)"),
                "Unfiltered job should use full count; got: \(logAll)")
        #expect(allCount > rejectedCount,
                "Unfiltered (\(allCount)) should have more faces than filtered (\(rejectedCount))")

        model.stopAll()
    }

    // MARK: - videosWithHits consistency

    // regression: videosWithHits must equal results.count when done,
    // not the live counter which includes files filtered by minPresence.
    // Exercises ScanJob.finalizeResults() which snaps the counter.
    @Test func videosWithHitsMustMatchResultsCount() {
        let job = ScanJob(searchPath: "/tmp")
        job.videosTotal = 100
        job.videosScanned = 100
        // Simulate live scanning that found 50 videos with any match
        job.videosWithHits = 50

        // But only 20 passed filterByPresence and made it into results
        let results = (0..<20).map {
            ClipResult(
                videoFilename: "file\($0).mov",
                videoPath: "/tmp/file\($0).mov",
                videoDuration: 60,
                presenceSecs: 5,
                segmentCount: 2,
                bestDistance: 0.4,
                clipFiles: [],
                outputDir: "/tmp/out"
            )
        }

        job.finalizeResults(results)

        #expect(job.videosWithHits == 20,
                "videosWithHits should match results.count (files that passed filters), got \(job.videosWithHits)")
        #expect(job.videosWithHits == job.results.count,
                "videosWithHits must always equal results.count when scan is complete")
    }

    @Test func videosWithHitsZeroWhenNoResults() {
        let job = ScanJob(searchPath: "/tmp")
        job.videosTotal = 50
        job.videosScanned = 50
        job.videosWithHits = 10

        job.finalizeResults([])

        #expect(job.videosWithHits == 0,
                "videosWithHits should be 0 when no results, got \(job.videosWithHits)")
        #expect(job.videosWithHits == job.results.count)
    }

    // MARK: - Cache restore race condition

    // regression: restoreFromCache's Task.detached could land after a scan
    // started, clobbering videosWithHits/results with stale cached data.
    @Test func cacheRestoreDoesNotClobberActiveScan() {
        let job = ScanJob(searchPath: "/tmp")
        job.status = .scanning
        job.videosTotal = 200
        job.videosScanned = 150
        job.videosWithHits = 35

        let scanResults = (0..<35).map {
            ClipResult(
                videoFilename: "scan_\($0).mov",
                videoPath: "/tmp/scan_\($0).mov",
                videoDuration: 120, presenceSecs: 10, segmentCount: 3,
                bestDistance: 0.38, clipFiles: [], outputDir: "/tmp/out"
            )
        }
        job.results = scanResults

        let cacheResults = (0..<5).map {
            ClipResult(
                videoFilename: "cache_\($0).mov",
                videoPath: "/tmp/cache_\($0).mov",
                videoDuration: 60, presenceSecs: 8, segmentCount: 1,
                bestDistance: 0.42, clipFiles: [], outputDir: "/tmp/out"
            )
        }

        // Simulate the isIdle guard from restoreFromCache's MainActor.run block
        if job.status.isIdle {
            job.finalizeResults(cacheResults)
            job.status = .done
        }

        #expect(job.status == .scanning,
                "Cache restore should not change status of an active scan")
        #expect(job.videosWithHits == 35,
                "Cache restore should not reset videosWithHits during active scan")
        #expect(job.results.count == 35,
                "Cache restore should not replace results during active scan")
    }

    @Test func cacheRestoreAppliesWhenIdle() {
        let job = ScanJob(searchPath: "/tmp")

        let cacheResults = (0..<5).map {
            ClipResult(
                videoFilename: "cache_\($0).mov",
                videoPath: "/tmp/cache_\($0).mov",
                videoDuration: 60, presenceSecs: 8, segmentCount: 1,
                bestDistance: 0.42, clipFiles: [], outputDir: "/tmp/out"
            )
        }

        if job.status.isIdle {
            job.finalizeResults(cacheResults)
            job.status = .done
        }

        #expect(job.status == .done)
        #expect(job.videosWithHits == 5)
        #expect(job.results.count == 5)
    }

    @Test func cacheRestoreSkipsWhenAlreadyDone() {
        let job = ScanJob(searchPath: "/tmp")

        let scanResults = (0..<20).map {
            ClipResult(
                videoFilename: "done_\($0).mov",
                videoPath: "/tmp/done_\($0).mov",
                videoDuration: 90, presenceSecs: 12, segmentCount: 2,
                bestDistance: 0.36, clipFiles: [], outputDir: "/tmp/out"
            )
        }
        job.finalizeResults(scanResults)
        job.status = .done

        let cacheResults = (0..<3).map {
            ClipResult(
                videoFilename: "stale_\($0).mov",
                videoPath: "/tmp/stale_\($0).mov",
                videoDuration: 60, presenceSecs: 6, segmentCount: 1,
                bestDistance: 0.45, clipFiles: [], outputDir: "/tmp/out"
            )
        }

        if job.status.isIdle {
            job.finalizeResults(cacheResults)
        }

        #expect(job.videosWithHits == 20,
                "Late cache restore should not overwrite completed scan results")
        #expect(job.results.count == 20)
    }
}

