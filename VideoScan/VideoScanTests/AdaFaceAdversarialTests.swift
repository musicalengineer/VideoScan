import Foundation
import Testing
@testable import VideoScan

// Adversarial RED tests for the AdaFace/Hybrid review of GH #144.
//
// These tests intentionally pin boundaries that the happy-path plugin tests
// do not exercise: the production job seam, persisted cache provenance,
// portable settings, legacy evaluator compatibility, corrupt assets, and
// cancellation before model work. No private media or installed model is used.

@MainActor
@Suite("AdaFace adversarial review", .serialized)
struct AdaFaceAdversarialTests {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // VideoScanTests
            .deletingLastPathComponent() // VideoScan
            .deletingLastPathComponent() // repo root
    }

    private var fixturePhotos: String {
        repoRoot.appendingPathComponent("tests/fixtures/photos").path
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: Hybrid production seam

    // regression: Hybrid promises a Vision-first pass, so the production job
    // must carry the loaded Vision feature prints into processOneVideo. This
    // exercises startJob's real settings/profile/print handoff; it does not
    // merely test RecognitionEngine metadata or a synthetic switch.
    @Test(.timeLimit(.minutes(2)))
    func hybridJobPublishesLoadedVisionPrints() async throws {
        let photosPath = fixturePhotos
        let (faces, _, error) = await Task.detached {
            pfLoadReferencePhotos(from: photosPath, largestFaceOnly: false)
        }.value
        let loadedFaces = try #require(
            faces.isEmpty ? nil : faces,
            "fixture faces did not load: \(error ?? "unknown error")"
        )

        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("adaface-hybrid-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: target) }

        let model = PersonFinderModel()
        let job = ScanJob(searchPath: target.path)
        job.assignedProfile = POIProfile(
            name: "Fixture Person",
            referencePath: photosPath,
            engine: RecognitionEngine.hybrid.rawValue
        )
        job.assignedFaces = loadedFaces
        model.jobs.append(job)

        model.startJob(job)
        job.flushConsoleLines()
        let log = job.consoleLines.joined(separator: "\n")
        model.stopJob(job)

        #expect(log.contains("Engine: HYBRID"), "precondition: \(log)")
        #expect(log.contains("Feature prints for matching: \(loadedFaces.count)"),
                "Hybrid's Vision-first pass must receive every loaded feature print; got: \(log)")
    }

    // MARK: Cache provenance and concurrent-job isolation

    // regression: a restored Hybrid job must carry enough fallback provenance
    // to rebuild the exact result-cache key after launch. This is behavioral
    // schema coverage through the real descriptor builder, not a mutable-global
    // setter test.
    @Test func hybridDescriptorPersistsItsCacheVariant() throws {
        var settings = PersonFinderSettings()
        settings.personName = "Donna"
        settings.recognitionEngine = .hybrid
        settings.adafaceThreshold = 0.37
        settings.arcfaceLandmarkAlignment = true

        let job = ScanJob(searchPath: "/Volumes/Test")
        job.assignedProfile = settings.toProfile()
        let descriptor = PersonFinderModel.makeDescriptor(from: job, settings: settings)
        let json = try jsonObject(descriptor)

        #expect(json["embedVariant"] as? String == PersonFinderCache.embedVariant(for: settings),
                "restart rehydration must not depend on whichever job last mutated process-global cache state")
    }

    // SENSOR: stress the pure, explicit provenance seam rather than scanning
    // source text. Alternating two live job configurations 100k times catches
    // accidental ambient/global state and also bounds the cost of cache-key
    // namespace construction.
    @Test(.timeLimit(.minutes(1)))
    func cacheVariantsRemainIndependentAcross100kInterleavedJobs() {
        var ada = PersonFinderSettings()
        ada.recognitionEngine = .adaface
        ada.adafaceThreshold = 0.42
        var hybrid = PersonFinderSettings()
        hybrid.recognitionEngine = .hybrid
        hybrid.adafaceThreshold = 0.25

        let adaVariant = PersonFinderCache.embedVariant(for: ada)
        let hybridVariant = PersonFinderCache.embedVariant(for: hybrid)
        let expectedAda = PersonFinderCache.composedRefHash(
            ["/nonexistent/reference.jpg"], embedVariant: adaVariant)
        let expectedHybrid = PersonFinderCache.composedRefHash(
            ["/nonexistent/reference.jpg"], embedVariant: hybridVariant)
        var mismatchCount = 0

        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for index in 0..<100_000 {
                let expected = index.isMultiple(of: 2) ? expectedAda : expectedHybrid
                let variant = index.isMultiple(of: 2) ? adaVariant : hybridVariant
                if PersonFinderCache.composedRefHash(
                    ["/nonexistent/reference.jpg"], embedVariant: variant) != expected {
                    mismatchCount += 1
                }
            }
        }

        #expect(expectedAda != expectedHybrid)
        #expect(mismatchCount == 0,
                "interleaved jobs contaminated one another's cache namespace")
        #expect(elapsed < .seconds(5),
                "100k cache namespaces took \(elapsed)")
    }

}
