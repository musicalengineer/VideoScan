import Testing
import Foundation
@testable import VideoScan

// MARK: - PersonFinderEngineDispatch coverage tests
//
// PersonFinderEngineDispatch.swift had 0% coverage before this file
// (xccov: 0/153 executable lines). The dispatch entry points are
// nonisolated free functions reachable via @testable import.
//
// Strategy: exercise the bail paths that don't require launching real
// Python subprocesses or loading CoreML models. Each test pins a single
// guard and asserts (a) the function returns nil and (b) the log line
// the production code wrote matches the expected diagnostic — those
// log lines are user-visible, so a silent rename would mislead Rick
// when a scan misbehaves.

/// Sendable log sink — actor-isolated array so the @Sendable closures
/// we hand to dispatch can append without data races. Mirrors the way
/// the production code marshals log lines through MainActor in
/// PersonFinderModel+JobLifecycle.
actor LogSink {
    private(set) var lines: [String] = []
    func append(_ line: String) { lines.append(line) }
    func contains(_ needle: String) -> Bool {
        lines.contains { $0.contains(needle) }
    }
    func joined() -> String { lines.joined(separator: "\n") }
}

@MainActor
struct PersonFinderEngineDispatchTests {

    // dlib bail-path tests hang on the 7 GB virtualized-M1 GitHub runner:
    // pfProcessVideoWithDlib enters a memory-pressure pauseGate that waits
    // for >4 GB free, which never happens on the constrained VM, so the
    // test sits forever instead of reaching the path-validation guard
    // it's trying to cover. Tests still run locally where they finish
    // in ~1 ms each. Re-enable when we move CI to a self-hosted runner
    // (M1 MBP planned) or refactor pfProcessVideoWithDlib to short-circuit
    // input validation before the memory check.
    // VS_VIRT_M1 is injected by VideoScan-CI.xctestplan's environmentVariableEntries.
    // ProcessInfo's view of CI=true (set by GitHub Actions) doesn't survive
    // the hop into xcodebuild's xctest child process, so we use a plan-scoped
    // env var that we control directly.
    private static let dlibTestsHangOnCI: Bool =
        ProcessInfo.processInfo.environment["VS_VIRT_M1"] != nil

    // MARK: - dlib bail: Python path empty / non-executable

    @Test(.disabled(if: Self.dlibTestsHangOnCI, "Hangs on GH virt-M1 (see comment above)"))
    func dlibBailsWhenPythonPathEmpty() async {
        let sink = LogSink()
        var settings = PersonFinderSettings()
        settings.pythonPath = ""
        settings.recognitionScript = ""
        settings.referencePath = "/tmp"

        let result = await pfProcessVideoWithDlib(
            filePath: "/tmp/never_opened.mov",
            settings: settings,
            index: 1,
            total: 1,
            pauseGate: PauseGate(),
            logFn: { line in await sink.append(line) },
            progressFn: { _ in },
            distFn: { _ in }
        )

        #expect(result == nil)
        let log = await sink.joined()
        #expect(await sink.contains("Python executable not found"),
                "Should log Python not-found bail; got: \(log)")
    }

    @Test(.disabled(if: Self.dlibTestsHangOnCI, "Hangs on GH virt-M1 (see comment above)"))
    func dlibBailsWhenPythonPathNonExecutable() async {
        // Point pythonPath at a real-but-not-executable file (this source
        // file itself), so isExecutableFile returns false.
        let sink = LogSink()
        var settings = PersonFinderSettings()
        settings.pythonPath = #filePath  // exists, not executable
        settings.recognitionScript = #filePath
        settings.referencePath = "/tmp"

        let result = await pfProcessVideoWithDlib(
            filePath: "/tmp/never_opened.mov",
            settings: settings,
            index: 1,
            total: 1,
            pauseGate: PauseGate(),
            logFn: { line in await sink.append(line) },
            progressFn: { _ in },
            distFn: { _ in }
        )

        #expect(result == nil)
        #expect(await sink.contains("Python executable not found"),
                "Non-executable pythonPath should hit the same bail")
    }

    @Test(.disabled(if: Self.dlibTestsHangOnCI, "Hangs on GH virt-M1 (see comment above)"))
    func dlibBailsWhenRecognitionScriptMissing() async {
        // Use the system /bin/sh as a real executable, then point
        // recognitionScript at a path that doesn't exist. This passes
        // the python guard and falls through to the script-existence guard.
        let sink = LogSink()
        var settings = PersonFinderSettings()
        settings.pythonPath = "/bin/sh"  // exists, executable on every macOS
        settings.recognitionScript = "/tmp/nonexistent_script_\(UUID().uuidString).py"
        settings.referencePath = "/tmp"

        let result = await pfProcessVideoWithDlib(
            filePath: "/tmp/never_opened.mov",
            settings: settings,
            index: 1,
            total: 1,
            pauseGate: PauseGate(),
            logFn: { line in await sink.append(line) },
            progressFn: { _ in },
            distFn: { _ in }
        )

        #expect(result == nil)
        let log = await sink.joined()
        #expect(await sink.contains("recognition script not found"),
                "Missing script should hit the script-existence bail; got: \(log)")
    }

    // MARK: - dlib pre-flight log lines (diagnostics surface)

    @Test(.disabled(if: Self.dlibTestsHangOnCI, "Hangs on GH virt-M1 (see comment above)"))
    func dlibLogsPythonAndScriptPathsBeforeBailing() async {
        // The production code writes "  dlib: python=..." and
        // "  dlib: script=..." before the existence checks. These lines
        // are the first thing Rick sees when a scan misbehaves; they
        // need to keep being emitted even when the bail fires.
        let sink = LogSink()
        var settings = PersonFinderSettings()
        settings.pythonPath = "/usr/bin/false"  // exists + executable
        settings.recognitionScript = "/tmp/missing_\(UUID().uuidString).py"
        settings.referencePath = "/tmp"

        _ = await pfProcessVideoWithDlib(
            filePath: "/tmp/whatever.mov",
            settings: settings,
            index: 7,
            total: 42,
            pauseGate: PauseGate(),
            logFn: { line in await sink.append(line) },
            progressFn: { _ in },
            distFn: { _ in }
        )

        #expect(await sink.contains("dlib: python="),
                "Pre-bail diagnostics should include python path line")
        #expect(await sink.contains("dlib: script="),
                "Pre-bail diagnostics should include script path line")
        #expect(await sink.contains("[7/42]"),
                "Index/total formatting should reach the log")
    }

    // MARK: - dlib respects pre-cancellation

    @Test(.disabled(if: Self.dlibTestsHangOnCI, "Hangs on GH virt-M1 (see comment above)"))
    func dlibReturnsEarlyWhenTaskAlreadyCancelled() async {
        // pfProcessVideoWithDlib calls Task.isCancelled right after
        // pauseGate.waitIfPaused(). A pre-cancelled Task should return
        // nil before any subprocess work or even the path-check guards.
        let sink = LogSink()
        var settings = PersonFinderSettings()
        settings.pythonPath = "/bin/sh"
        settings.recognitionScript = "/tmp/whatever.py"
        settings.referencePath = "/tmp"

        let task = Task {
            await pfProcessVideoWithDlib(
                filePath: "/tmp/x.mov",
                settings: settings,
                index: 1, total: 1,
                pauseGate: PauseGate(),
                logFn: { line in await sink.append(line) },
                progressFn: { _ in },
                distFn: { _ in }
            )
        }
        task.cancel()
        let result = await task.value
        #expect(result == nil, "Cancelled task should return nil from dlib dispatch")
    }

    // MARK: - ArcFace reference embedding cache (crash 2026-05-12 19:16)
    //
    // Stack: arcfaceLoadReferenceEmbeddings → arcfaceEmbedding →
    // MLE5BindEmptyMemoryObjectToPort → SIGABRT, hit during multi-job
    // scan with concurrency=32, frameStep=1. Root cause: references
    // were re-embedded for every video, multiplying concurrent MLE5
    // load enough to trip the engine race even with per-call MLModel
    // instances. Fix: cache embeddings on ScanJob, populated lazily by
    // pfRunArcFaceEngine, invalidated by loadFacesForJob on a fresh
    // reference-photo load.
    //
    // These tests pin the cache shape and the invalidation contract.
    // They don't exercise the prediction call itself (CoreML state is
    // expensive and unreliable in unit tests) — that's by design. The
    // invalidation rule is the part most likely to drift in a refactor.

    @Test func newScanJobHasEmptyArcFaceEmbeddingCache() {
        let job = ScanJob(searchPath: "/tmp")
        #expect(job.assignedArcFaceEmbeddings.isEmpty,
                "Default cache must be empty so pfRunArcFaceEngine takes the compute path on first video")
    }

    @Test func loadFacesForJobInvalidatesArcFaceEmbeddingCache() async {
        // Reproduces the worst case: a job has cached embeddings from
        // a previous profile, then the user assigns a different person
        // and starts a new scan. loadFacesForJob is the choke point —
        // it must clear the cache or the new scan reuses stale embeddings
        // and matches the wrong person.
        let model = PersonFinderModel()
        let job = ScanJob(searchPath: "/tmp")
        job.assignedProfile = POIProfile(
            name: "TestPerson",
            referencePath: "/tmp/nonexistent_refs_\(UUID().uuidString)",
            engine: RecognitionEngine.arcface.rawValue
        )
        job.assignedArcFaceEmbeddings = [[1.0, 2.0, 3.0], [4.0, 5.0, 6.0]]
        #expect(!job.assignedArcFaceEmbeddings.isEmpty, "precondition: cache populated")

        await model.loadFacesForJob(job)

        #expect(job.assignedArcFaceEmbeddings.isEmpty,
                "loadFacesForJob must invalidate the cache; otherwise a person-swap reuses prior embeddings")
    }
}
