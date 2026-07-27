import Foundation
import Testing
@testable import VideoScan

// Adversarial RED tests for the AdaFace/Hybrid review of GH #144.
//
// These tests intentionally pin boundaries that the happy-path plugin tests
// do not exercise: the production job seam, persisted cache provenance,
// portable settings, legacy evaluator compatibility, corrupt assets, and
// cancellation before model work. No private media or installed model is used.

private actor AdaFaceAdversarialLogSink {
    private var lines: [String] = []

    func append(_ line: String) { lines.append(line) }
    func snapshot() -> [String] { lines }
}

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

    // MARK: Portable settings migration

    // regression: exporting an AdaFace operating point must not silently
    // restore the default 0.30 threshold on another machine.
    @Test func bundleSettingsRoundTripAdaFaceThreshold() throws {
        var original = PersonFinderSettings()
        original.recognitionEngine = .adaface
        original.adafaceThreshold = 0.42

        let encoded = try JSONEncoder().encode(SettingsSnapshot(from: original))
        let decoded = try JSONDecoder().decode(SettingsSnapshot.self, from: encoded)
        var restored = PersonFinderSettings()
        decoded.apply(to: &restored)

        #expect(restored.recognitionEngine == .adaface)
        #expect(restored.adafaceThreshold == 0.42,
                "portable settings must preserve the threshold that shaped AdaFace results")
    }

    // Backward compatibility: adding the field must not brick settings.json
    // written before AdaFace existed.
    @Test func bundleSettingsWithoutAdaFaceThresholdStillDecodes() throws {
        var settings = PersonFinderSettings()
        settings.recognitionEngine = .vision
        var object = try jsonObject(SettingsSnapshot(from: settings))
        object.removeValue(forKey: "adafaceThreshold")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(SettingsSnapshot.self, from: legacyData)
        var restored = PersonFinderSettings()
        decoded.apply(to: &restored)

        #expect(restored.recognitionEngine == .vision)
        #expect(restored.adafaceThreshold == 0.30)
    }

    // Poisoned portable values must not become match-everything thresholds or
    // brick the entire bundle. Numeric -3 is valid JSON but outside the legal
    // cosine band; the same lower clamp used by UserDefaults is expected.
    @Test func bundleSettingsClampsPoisonedAdaFaceThreshold() throws {
        var object = try jsonObject(SettingsSnapshot(from: PersonFinderSettings()))
        object["recognitionEngine"] = RecognitionEngine.adaface.rawValue
        object["adafaceThreshold"] = -3.0
        let poisonedData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(SettingsSnapshot.self, from: poisonedData)
        var restored = PersonFinderSettings()
        decoded.apply(to: &restored)

        #expect(restored.adafaceThreshold == 0.05,
                "portable settings must clamp the same poisoned values as UserDefaults restore")

        object["adafaceThreshold"] = 7.5
        let upperData = try JSONSerialization.data(withJSONObject: object)
        let upperSnapshot = try JSONDecoder().decode(SettingsSnapshot.self, from: upperData)
        upperSnapshot.apply(to: &restored)
        #expect(restored.adafaceThreshold == 0.95,
                "portable settings must clamp oversized cosine thresholds")
    }

    @Test func legacyProfileDefaultsAndPoisonedProfileClamps() throws {
        let legacy = Data("""
            {"name":"Donna","referencePath":"/tmp/refs",
             "engine":"AdaFace (CoreML)","visionThreshold":0.52,
             "arcfaceThreshold":0.40}
            """.utf8)
        let oldProfile = try JSONDecoder().decode(POIProfile.self, from: legacy)
        #expect(oldProfile.adafaceThreshold == 0.30,
                "pre-AdaFace profile JSON must retain the documented default")

        let poisoned = Data("""
            {"name":"Donna","referencePath":"/tmp/refs",
             "engine":"AdaFace (CoreML)","visionThreshold":0.52,
             "arcfaceThreshold":0.40,"adafaceThreshold":-9.0}
            """.utf8)
        let poisonedProfile = try JSONDecoder().decode(POIProfile.self, from: poisoned)
        var settings = PersonFinderSettings()
        settings.applyProfile(poisonedProfile)
        #expect(settings.adafaceThreshold == 0.05,
                "profile decode/apply must not install a match-everything cosine threshold")

        let oversized = Data("""
            {"name":"Donna","referencePath":"/tmp/refs",
             "engine":"AdaFace (CoreML)","visionThreshold":0.52,
             "arcfaceThreshold":0.40,"adafaceThreshold":7.5}
            """.utf8)
        settings.applyProfile(try JSONDecoder().decode(POIProfile.self, from: oversized))
        #expect(settings.adafaceThreshold == 0.95,
                "profile apply must clamp oversized cosine thresholds")
    }

    // MARK: Legacy evaluator isolation

    // regression: dlib leaves Search, not the standalone/replay evaluator.
    // Existing person-eval manifests emitted `--engine dlib`; parsing them
    // must remain accepted while the Search registry remains dlib-free.
    @Test func legacyDlibPersonEvalManifestStillParses() {
        let arguments = [
            "--person-eval", "--engine", "dlib",
            "--person", "Donna", "--references", "/tmp/refs",
            "--video", "/tmp/video.mov"
        ]
        #expect((try? PersonEvaluationCLI.parse(arguments)) != nil,
                "legacy dlib evaluation manifests must remain replayable outside Search")
    }

    @Test func searchRegistryRemainsDlibFree() {
        #expect(RecognitionEngine.allCases.allSatisfy {
            !$0.rawValue.lowercased().contains("dlib")
        })
    }

    // MARK: Model asset failures and cancellation

    // Invalid assets are handled without loading private models: an empty
    // directory with the expected .mlmodelc name exercises the corrupt-asset
    // branch and must be diagnosed differently from "not installed".
    @Test func corruptCompiledAssetReturnsActionableFailure() async throws {
        let modelsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("adaface-corrupt-\(UUID().uuidString)", isDirectory: true)
        let corrupt = modelsDir
            .appendingPathComponent(AdaFaceModelLoader.modelBaseName + ".mlmodelc", isDirectory: true)
        try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
        defer {
            AdaFaceModelLoader.modelsDirOverride = nil
            try? FileManager.default.removeItem(at: modelsDir)
        }

        AdaFaceModelLoader.modelsDirOverride = modelsDir.path
        await AdaFaceModelLoader.shared.reset()
        let (model, error) = await AdaFaceModelLoader.shared.getModel()

        #expect(model == nil)
        let message = try #require(error)
        #expect(message.contains("found but failed to load"))
        #expect(message.contains(corrupt.path))
        await AdaFaceModelLoader.shared.reset()
    }

    // regression: cancellation must be checked before model resolution or
    // reference embedding. With an empty isolated model directory, any log
    // proves the dispatch performed model work after cancellation.
    @Test func preCancelledDispatchDoesNoModelWork() async throws {
        let modelsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("adaface-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        defer {
            AdaFaceModelLoader.modelsDirOverride = nil
            try? FileManager.default.removeItem(at: modelsDir)
        }
        AdaFaceModelLoader.modelsDirOverride = modelsDir.path
        await AdaFaceModelLoader.shared.reset()

        let sink = AdaFaceAdversarialLogSink()
        let job = ScanJob(searchPath: "/tmp")
        var settings = PersonFinderSettings()
        settings.recognitionEngine = .adaface
        settings.referencePath = "/tmp"

        let task = Task {
            await pfRunAdaFaceEngine(
                filePath: "/tmp/never-open.mov", idx1: 1, total: 1,
                settings: settings, job: job, dash: nil,
                progressState: ThrottledMainActorUpdate(intervalSecs: 0.25),
                logFn: { await sink.append($0) },
                progressFn: { _ in }, distFn: { _ in }
            )
        }
        task.cancel()
        let result = await task.value

        #expect(result == nil)
        #expect((await sink.snapshot()).isEmpty,
                "pre-cancelled dispatch must return before model loading/logging")
        await AdaFaceModelLoader.shared.reset()
    }
}
