import Foundation
import Testing
@testable import VideoScan

// REGRESSION SENSOR (GH #148 residual): a COMPLETED AdaFace search whose
// engine came from the GLOBAL app setting — profile has no/legacy/Vision
// engine token and there is no per-job override — must persist a descriptor
// that reproduces the LIVE scan's cache key, so its rows rehydrate on restart
// instead of showing "Found no matches" with an empty table.
//
// Root cause that this pins: makeDescriptor derived the persisted engine from
// `job.effectiveEngine`, whose fallback was hard-coded `.vision`. The live
// scan's engine came from `jobSettings.recognitionEngine` (= the global). When
// the engine was global-driven, the descriptor recorded Vision, poisoning the
// persisted threshold (0.52) and embedVariant ("") so every AdaFace cache row
// missed on rehydration. Fixed by resolving through
// `effectiveEngine(globalDefault: settings.recognitionEngine)`.
//
// Five-dimension notes (docs/testing_retrospective_2026_07_05.md):
//  - Logic: cache-key identity across the persist→rehydrate boundary.
//  - Isolation: PersonFinderCache/ScanJobsStorage both redirect to per-process
//    scratch under a test host, so this never touches Rick's real cache/history.
//  - Sensor: keyIdentity_* pins the fix at the production key seam;
//    endToEnd_* proves an actual store→lookup round-trip returns the rows.
@MainActor
@Suite("AdaFace restore regression", .serialized)
struct AdaFaceRestoreRegressionTests {
    private var fixturePhotos: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("tests/fixtures/photos").path
    }

    // Inline copy of the PRIVATE referenceCacheIdentifiers so the test can
    // reproduce both production call sites verbatim.
    private func refIDs(_ path: String, _ names: [String]) -> [String] {
        guard !path.isEmpty else { return names }
        let base = URL(fileURLWithPath: path)
        return names.map { base.appendingPathComponent($0).path }
    }

    private func loadFaces() async throws -> [ReferenceFace] {
        let path = fixturePhotos
        let (faces, _, err) = await Task.detached {
            pfLoadReferencePhotos(from: path, largestFaceOnly: false)
        }.value
        return try #require(faces.isEmpty ? nil : faces,
                            "fixture faces did not load: \(err ?? "unknown")")
    }

    /// Build a live-scan cache key and the descriptor-rehydration cache key for
    /// a job whose engine is GLOBAL-driven (profile token = `profileEngineRaw`,
    /// no per-job override), mirroring startJobAfterLoad + makeDescriptor.
    private func liveAndRehydrateKeys(
        profileEngineRaw: String,
        faces: [ReferenceFace],
        videoPath: String
    ) throws -> (PersonFinderCache.CacheKey, PersonFinderCache.CacheKey, PersistedJobDescriptor) {
        var settings = PersonFinderSettings()
        settings.personName = "Donna"
        settings.recognitionEngine = .adaface          // GLOBAL engine
        settings.adafaceThreshold = 0.30
        settings.referencePath = fixturePhotos

        let profile = POIProfile(
            name: "Donna", referencePath: fixturePhotos,
            engine: profileEngineRaw, adafaceThreshold: 0.30)
        let job = ScanJob(searchPath: "/tmp/restore-regression")
        job.assignedProfile = profile
        job.assignedFaces = faces

        // LIVE (processOneVideo): jobSettings = global overlaid with profile.
        var jobSettings = settings
        jobSettings.applyProfile(profile)               // no valid engine token → stays .adaface
        let liveRefIDs = refIDs(jobSettings.referencePath, job.assignedFaces.map(\.sourceFilename))
        let liveKey = try #require(PersonFinderCache.makeKey(
            videoPath: videoPath, personName: jobSettings.personName,
            engine: jobSettings.recognitionEngine,
            threshold: jobSettings.thresholdForEngine(jobSettings.recognitionEngine),
            refFilenames: liveRefIDs,
            embedVariant: PersonFinderCache.embedVariant(for: jobSettings)))

        // REHYDRATE: makeDescriptor → JSON round-trip → rehydrate key.
        let descriptor = PersonFinderModel.makeDescriptor(from: job, settings: jobSettings)
        let data = try JSONEncoder().encode(descriptor)
        let decoded = try JSONDecoder().decode(PersistedJobDescriptor.self, from: data)
        let rehydrateRefIDs = refIDs(decoded.referencePath, decoded.referenceFilenames)
        let rehydrateKey = try #require(PersonFinderCache.makeKey(
            videoPath: videoPath, personName: decoded.personName,
            engine: RecognitionEngine.migratePersisted(decoded.engine) ?? .vision,
            threshold: decoded.threshold, refFilenames: rehydrateRefIDs,
            embedVariant: decoded.embedVariant ?? ""))

        return (liveKey, rehydrateKey, decoded)
    }

    // Profile token variants where the engine is NOT overridden to a different
    // engine, so the live scan runs the GLOBAL AdaFace: non-resolving tokens
    // ("AdaFace"/"vision" are not the real rawValues; "" is unset) leave the
    // global in place, and the legacy "dlib/Python (accurate)" token migrates
    // straight to AdaFace. A real "Vision (fast)" token is deliberately absent
    // — that IS a Vision job and correctly persists as Vision.
    @Test(arguments: ["AdaFace", "vision", "", "dlib/Python (accurate)"])
    func keyIdentity_globalDrivenAdaface(profileEngineRaw: String) async throws {
        let faces = try await loadFaces()
        let video = NSTemporaryDirectory() + "reg_\(UUID().uuidString).mov"
        FileManager.default.createFile(atPath: video, contents: Data(repeating: 0x42, count: 4096))
        defer { try? FileManager.default.removeItem(atPath: video) }

        let (live, rehydrate, descriptor) = try liveAndRehydrateKeys(
            profileEngineRaw: profileEngineRaw, faces: faces, videoPath: video)

        #expect(live == rehydrate,
                "global-driven AdaFace descriptor must reproduce the live cache key (profile token \"\(profileEngineRaw)\")")
        // Pin the three columns the old bug corrupted.
        #expect(descriptor.engine == RecognitionEngine.adaface.rawValue,
                "descriptor recorded \(descriptor.engine), not AdaFace")
        #expect(descriptor.threshold == 0.30,
                "descriptor threshold \(descriptor.threshold) is not the AdaFace cosine 0.30")
        var adaSettings = PersonFinderSettings()
        adaSettings.recognitionEngine = .adaface
        let expectedVariant = PersonFinderCache.embedVariant(for: adaSettings)
        #expect(descriptor.embedVariant == expectedVariant,
                "descriptor embedVariant lost the AdaFace namespace token")
    }

    // End-to-end: store a hit row under the LIVE key, then rehydrate through
    // the persisted descriptor and confirm the actual cache lookup returns the
    // row (non-empty results), not a miss.
    @Test func endToEnd_globalDrivenAdafaceRowsRehydrate() async throws {
        let faces = try await loadFaces()
        let video = NSTemporaryDirectory() + "reg_\(UUID().uuidString).mov"
        FileManager.default.createFile(atPath: video, contents: Data(repeating: 0x42, count: 4096))
        defer { try? FileManager.default.removeItem(atPath: video) }

        let (live, rehydrate, _) = try liveAndRehydrateKeys(
            profileEngineRaw: "", faces: faces, videoPath: video)
        #expect(live == rehydrate)

        // Live scan writes a matched row (6 hits, one segment) under the live key.
        let result = pfVideoResult(
            filename: (video as NSString).lastPathComponent, filePath: video,
            durationSeconds: 71, fps: 30, totalHits: 6,
            segments: [pfSegment(startSecs: 2, endSecs: 10, bestDistance: 0.381, avgDistance: 0.44)],
            facesDetected: 318)
        PersonFinderCache.shared.store(key: live, result: result)
        defer { PersonFinderCache.shared.clearAll() }

        // Restart rehydration looks up under the descriptor-derived key.
        let restored = try #require(PersonFinderCache.shared.lookup(key: rehydrate),
            "restored AdaFace search found no matches — cache key diverged from the live write")
        #expect(!restored.segments.isEmpty, "rehydrated row lost its segments")
        #expect(restored.totalHits == 6)
    }
}
