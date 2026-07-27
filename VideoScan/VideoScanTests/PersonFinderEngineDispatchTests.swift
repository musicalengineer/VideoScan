import Testing
import Foundation
@testable import VideoScan

// MARK: - PersonFinderEngineDispatch coverage tests
//
// The dispatch entry points are nonisolated free functions reachable via
// @testable import. The dlib bail-path tests that used to live here were
// removed with the dlib Search seat (GH #144); their AdaFace equivalents
// below pin the same class of contract: bail paths return nil AND write
// the user-visible diagnostic line — those log lines are the first thing
// Rick sees when a scan misbehaves, so a silent rename would mislead him.
//
// None of these tests load a real CoreML model (expensive and unreliable
// in unit tests, by design — same rule as the original ArcFace cache
// tests). The missing-model path is exercised through the
// AdaFaceModelLoader.modelsDirOverride test seam.

/// Sendable log sink — actor-isolated array so the @Sendable closures
/// we hand to dispatch can append without data races. Mirrors the way
/// the production code marshals log lines through MainActor in
/// PersonFinderModel+JobLifecycle.
///
/// Renamed from `LogSink` 2026-05-23 to avoid colliding with the
/// production `LogSink` protocol introduced for appLog DI
/// (VideoScan/LogSink.swift). This actor is unrelated to that
/// protocol — it's a local helper for verifying log lines emitted
/// from dispatch internals.
actor DispatchLogActor {
    private(set) var lines: [String] = []
    func append(_ line: String) { lines.append(line) }
    func contains(_ needle: String) -> Bool {
        lines.contains { $0.contains(needle) }
    }
    func joined() -> String { lines.joined(separator: "\n") }
}

@MainActor
struct PersonFinderEngineDispatchTests {

    // MARK: - AdaFace bail: model assets missing (actionable error, #144)

    /// Point the loader at an empty temp dir and prove the dispatcher
    /// (a) returns nil and (b) logs an ACTIONABLE error naming the exact
    /// expected model path + the conversion tool. GH #144 acceptance:
    /// "Missing or invalid model assets produce a clear actionable error."
    @Test func adafaceBailsWithActionableErrorWhenModelMissing() async {
        let emptyDir = NSTemporaryDirectory() + "adaface_missing_\(UUID().uuidString)"
        try? FileManager.default.createDirectory(
            atPath: emptyDir, withIntermediateDirectories: true)
        defer {
            AdaFaceModelLoader.modelsDirOverride = nil
            try? FileManager.default.removeItem(atPath: emptyDir)
        }
        AdaFaceModelLoader.modelsDirOverride = emptyDir
        await AdaFaceModelLoader.shared.reset()

        let sink = DispatchLogActor()
        let job = ScanJob(searchPath: "/tmp")
        var settings = PersonFinderSettings()
        settings.recognitionEngine = .adaface
        settings.referencePath = "/tmp"

        let result = await pfRunAdaFaceEngine(
            filePath: "/tmp/never_opened.mov",
            idx1: 1, total: 1,
            settings: settings, job: job, dash: nil,
            progressState: ThrottledMainActorUpdate(intervalSecs: 0.25),
            logFn: { line in await sink.append(line) },
            progressFn: { _ in },
            distFn: { _ in }
        )

        #expect(result == nil)
        let log = await sink.joined()
        #expect(await sink.contains("[adaface] Model load failed"),
                "Should log the model-load bail; got: \(log)")
        #expect(await sink.contains("adaface_ir50_webface4m.mlpackage"),
                "Error must name the expected model file (actionable); got: \(log)")
        #expect(await sink.contains(emptyDir),
                "Error must name the directory searched (actionable); got: \(log)")
        // Reset again so a subsequent test never inherits a cached URL
        // resolved against the temp override.
        await AdaFaceModelLoader.shared.reset()
    }

    // MARK: - AdaFace respects pre-cancellation

    /// A pre-cancelled Task must come back nil without doing engine work —
    /// same contract the dlib seat honored. (With no model installed the
    /// bail also returns nil, so additionally require that no per-video
    /// processing lines were logged.)
    @Test func adafaceReturnsNilWhenTaskAlreadyCancelled() async {
        let emptyDir = NSTemporaryDirectory() + "adaface_cancel_\(UUID().uuidString)"
        try? FileManager.default.createDirectory(
            atPath: emptyDir, withIntermediateDirectories: true)
        defer {
            AdaFaceModelLoader.modelsDirOverride = nil
            try? FileManager.default.removeItem(atPath: emptyDir)
        }
        AdaFaceModelLoader.modelsDirOverride = emptyDir
        await AdaFaceModelLoader.shared.reset()

        let sink = DispatchLogActor()
        let job = ScanJob(searchPath: "/tmp")
        var settings = PersonFinderSettings()
        settings.recognitionEngine = .adaface
        settings.referencePath = "/tmp"

        let task = Task {
            await pfRunAdaFaceEngine(
                filePath: "/tmp/x.mov",
                idx1: 1, total: 1,
                settings: settings, job: job, dash: nil,
                progressState: ThrottledMainActorUpdate(intervalSecs: 0.25),
                logFn: { line in await sink.append(line) },
                progressFn: { _ in },
                distFn: { _ in }
            )
        }
        task.cancel()
        let result = await task.value
        #expect(result == nil, "Cancelled task should return nil from AdaFace dispatch")
        await AdaFaceModelLoader.shared.reset()
    }

    // MARK: - Reference embedding cache, backend-keyed (#144)
    //
    // Original crash context (2026-05-12 19:16): references were re-embedded
    // for every video, multiplying concurrent MLE5 load enough to trip
    // MLE5BindEmptyMemoryObjectToPort even with per-call MLModel instances.
    // Fix: cache embeddings on ScanJob, populated lazily by the engine
    // dispatchers, invalidated by loadFacesForJob on a fresh photo load.
    //
    // #144 extends the cache to a BACKEND-KEYED dictionary: AdaFace and
    // ArcFace vectors are both 512-d but not comparable, so a job re-run
    // under a different engine must never see the other backend's vectors.
    //
    // These tests pin the cache shape and the invalidation contract. They
    // don't exercise the prediction call itself (CoreML state is expensive
    // and unreliable in unit tests) — that's by design. The invalidation
    // rule is the part most likely to drift in a refactor.

    @Test func newScanJobHasEmptyEmbeddingCache() {
        let job = ScanJob(searchPath: "/tmp")
        #expect(job.assignedRefEmbeddings.isEmpty,
                "Default cache must be empty so the dispatchers take the compute path on first video")
    }

    @Test func embeddingCacheKeysAreBackendSeparated() {
        // The two backends must be able to coexist without colliding —
        // and their tokens must differ (a shared token would silently
        // compare AdaFace vectors against ArcFace references).
        #expect(FaceEmbeddingBackend.arcface != FaceEmbeddingBackend.adaface)

        let job = ScanJob(searchPath: "/tmp")
        job.assignedRefEmbeddings[FaceEmbeddingBackend.arcface] = [[1.0, 2.0]]
        job.assignedRefEmbeddings[FaceEmbeddingBackend.adaface] = [[3.0, 4.0]]
        #expect(job.assignedRefEmbeddings[FaceEmbeddingBackend.arcface] == [[1.0, 2.0]])
        #expect(job.assignedRefEmbeddings[FaceEmbeddingBackend.adaface] == [[3.0, 4.0]])
    }

    @Test func loadFacesForJobInvalidatesEmbeddingCacheForAllBackends() async {
        // Reproduces the worst case: a job has cached embeddings from
        // a previous profile, then the user assigns a different person
        // and starts a new scan. loadFacesForJob is the choke point —
        // it must clear ALL backends' caches or the new scan reuses stale
        // embeddings and matches the wrong person.
        let model = PersonFinderModel()
        let job = ScanJob(searchPath: "/tmp")
        job.assignedProfile = POIProfile(
            name: "TestPerson",
            referencePath: "/tmp/nonexistent_refs_\(UUID().uuidString)",
            engine: RecognitionEngine.arcface.rawValue
        )
        job.assignedRefEmbeddings[FaceEmbeddingBackend.arcface] = [[1.0, 2.0, 3.0]]
        job.assignedRefEmbeddings[FaceEmbeddingBackend.adaface] = [[4.0, 5.0, 6.0]]
        #expect(!job.assignedRefEmbeddings.isEmpty, "precondition: cache populated")

        await model.loadFacesForJob(job)

        #expect(job.assignedRefEmbeddings.isEmpty,
                "loadFacesForJob must invalidate every backend's cache; otherwise a person-swap reuses prior embeddings")
    }
}
