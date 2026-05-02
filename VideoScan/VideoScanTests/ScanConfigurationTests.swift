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

    @Test func effectiveEngineDefaultsToVision() {
        let job = ScanJob(searchPath: "/tmp")
        #expect(job.effectiveEngine == .vision)
    }

    @Test func effectiveEngineUsesProfileEngine() {
        let job = ScanJob(searchPath: "/tmp")
        job.assignedProfile = POIProfile(name: "Test", referencePath: "/tmp",
                                         engine: RecognitionEngine.arcface.rawValue)
        #expect(job.effectiveEngine == .arcface)
    }

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
        let job = ScanJob(searchPath: "/tmp/nonexistent_scan_path")
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
        let job = ScanJob(searchPath: "/tmp/nonexistent")
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
        let job = ScanJob(searchPath: "/tmp/nonexistent")
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
        let job = ScanJob(searchPath: "/tmp/nonexistent")
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

        let jobRejected = ScanJob(searchPath: "/tmp/nonexistent")
        model.jobs.append(jobRejected)
        jobRejected.assignedProfile = POIProfile(
            name: "Donna", referencePath: photosDir,
            rejectedFiles: ["DSCN3603.jpeg", "IMG_0145.jpeg", "IMG_3091.jpeg"]
        )
        await model.loadFacesForJob(jobRejected)
        let rejectedCount = jobRejected.assignedFaces.count

        let jobAll = ScanJob(searchPath: "/tmp/nonexistent2")
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
}
