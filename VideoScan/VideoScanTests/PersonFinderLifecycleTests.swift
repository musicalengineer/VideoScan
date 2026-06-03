import Testing
import Foundation
@testable import VideoScan

// MARK: - PersonFinderModel Lifecycle & Dispatch Tests
//
// Pre-refactor safety harness. These tests capture *current* observable
// behavior of PersonFinderModel — they exist so the planned split of the
// god-object (job lifecycle → JobController, processOne → RecognitionDispatcher,
// reference loading → ReferenceCoordinator) can be validated for regressions.
//
// Style mirrors ScanConfigurationTests.swift: Swift Testing (@Test, #expect),
// MainActor-bound (model is @MainActor), drive the public API only —
// no DI seams, no test-only hooks in production code.
//
// C++ analogy: think of @Test as TEST_F, #expect as EXPECT_TRUE/EXPECT_EQ.
// There is no test fixture inheritance here — Swift Testing uses
// per-test struct instances. Setup/teardown is per-test by value, not RAII.

@MainActor
struct PersonFinderLifecycleTests {

    static let photosDir: String = {
        let thisFile = #filePath
        let repoRoot = URL(fileURLWithPath: thisFile)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return repoRoot.appendingPathComponent("tests/fixtures/photos").path
    }()

    // MARK: - addJob

    // Refactor risk: addJob is a one-liner now but is the gateway used by
    // the UI; if a JobController absorbs it, the side effect must persist.
    @Test func addJobAppendsJobWithGivenPath() {
        let model = PersonFinderModel()
        #expect(model.jobs.isEmpty)

        model.addJob(path: "/tmp")
        #expect(model.jobs.count == 1)
        #expect(model.jobs[0].searchPath == "/tmp")
        #expect(model.jobs[0].status == .idle)
        #expect(model.jobs[0].assignedProfile == nil)
    }

    // Refactor risk: selectedPersonForNewJobs is a UI-driven default that
    // must be applied at addJob time, not later. Verifies the assignment hook.
    @Test func addJobAppliesSelectedPersonForNewJobs() {
        let model = PersonFinderModel()
        let profile = POIProfile(name: "Donna", referencePath: "/tmp/refs",
                                 engine: RecognitionEngine.arcface.rawValue)
        model.selectedPersonForNewJobs = profile

        model.addJob(path: "/tmp")
        #expect(model.jobs.count == 1)
        #expect(model.jobs[0].assignedProfile?.name == "Donna")
        // effectiveEngine should now resolve via the assigned profile.
        #expect(model.jobs[0].effectiveEngine == .arcface)
    }

    // MARK: - removeJob

    // Refactor risk: removeJob also cancels per-job tasks. If lifecycle
    // moves to a controller, this teardown order matters.
    @Test func removeJobRemovesByID() {
        let model = PersonFinderModel()
        model.addJob(path: "/tmp/a")
        model.addJob(path: "/tmp/b")
        model.addJob(path: "/tmp/c")
        #expect(model.jobs.count == 3)

        let middle = model.jobs[1]
        model.removeJob(middle)
        #expect(model.jobs.count == 2)
        #expect(model.jobs.map(\.searchPath) == ["/tmp/a", "/tmp/c"])
    }

    // regression: removeJob historically only cleared the in-memory `jobs`
    // array but left the on-disk descriptor behind, so deleted searches
    // would silently reappear on the next app launch (Rick's M5 report,
    // 2026-05-21). This test pins down that removeJob propagates the
    // delete all the way to disk.
    @Test func removeJobAlsoDeletesPersistedDescriptor() throws {
        // Start from a known-clean storeDir. Under tests this resolves to
        // a per-process temp dir (see ScanJobsStorage.storeDir), so
        // clearing here doesn't touch Rick's real Application Support.
        let dir = ScanJobsStorage.storeDir
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let descriptor = PersistedJobDescriptor(
            id: UUID(),
            personName: "TestPerson",
            profileFolderName: nil,
            searchPath: "/tmp/test_search",
            engine: "vision",
            threshold: 0.5,
            referencePath: "/tmp/test_refs",
            referenceFilenames: [],
            completedAt: Date(),
            videosScanned: 1,
            videosTotal: 1,
            videosWithHits: 0,
            clipsFound: 0,
            presenceSecs: 0,
            elapsedSecs: 0
        )
        try ScanJobsStorage.save(descriptor)
        #expect(ScanJobsStorage.listAll().count == 1)

        // init() skips restore under tests; call it explicitly so we can
        // see a job that originated from disk.
        let model = PersonFinderModel()
        model.restoreSessionFromDisk()
        #expect(model.jobs.count == 1)

        let job = model.jobs[0]
        model.removeJob(job)

        #expect(model.jobs.isEmpty)
        #expect(
            ScanJobsStorage.listAll().isEmpty,
            "removeJob must delete the persisted descriptor; otherwise the search reappears on app relaunch"
        )
    }

    // MARK: - startJob: pre-flight bailouts (captures volume-offline guard
    //                  added in commit 97342c8)

    // regression: 97342c8 — startJobAfterLoad now bails fast with .failed
    // when the search volume isn't reachable. Without this guard, the user
    // got a confusing "No videos found" message after a long enumeration.
    @Test func startJobFailsWhenVolumeOffline() {
        let model = PersonFinderModel()
        // No profile → startJob skips loadFacesForJob and lands directly in
        // startJobAfterLoad. This avoids the async Task hop and the
        // unrelated reference-folder enumeration that would otherwise race
        // the assertion. Reachability is the FIRST guard in
        // startJobAfterLoad, so it fires before the faces.isEmpty check.
        let job = ScanJob(searchPath: "/Volumes/_DefinitelyNotMounted_VS_Test")
        model.jobs.append(job)

        model.startJob(job)
        // Synchronous: no Task hop expected since assignedProfile is nil
        // AND faces are empty — startJob goes straight to startJobAfterLoad.

        // Status should be .failed("Volume … offline"), not .idle/.scanning.
        if case .failed(let msg) = job.status {
            #expect(msg.contains("offline"), "Expected offline message; got: \(msg)")
        } else {
            Issue.record("Expected .failed status for offline volume; got \(job.status.label)")
        }
        job.flushConsoleLines()  // bypass the 200ms appendLog batch for sync test read
        let log = job.consoleLines.joined(separator: "\n")
        #expect(log.contains("offline"), "Console should mention offline; got: \(log)")
    }

    // Regression: when a profile IS assigned, the previous offline guard
    // sat downstream of `Task { await loadFacesForJob(...); startJobAfterLoad(...) }`,
    // so the UI showed spinning/face-loading activity before failing with
    // a confusing message. The user-visible bug Rick reported: "starts
    // spinning saying something about indexes, then fails with no clear
    // reason." Fix: hoist the reachability check into `startJob` so it
    // fires BEFORE the async Task hop, regardless of profile state.
    //
    // This test pins the contract: after `startJob` returns, an offline
    // volume must already be in .failed("…offline…"). If the offline
    // guard ever drifts back below the Task hop, this fails because the
    // detached Task hasn't run yet and `job.status` is still .idle.
    @Test func startJobWithProfileFailsFastOnOfflineVolume() {
        let model = PersonFinderModel()
        let profile = POIProfile(
            name: "Donna",
            referencePath: "/tmp/_VS_Test_NonexistentRefs",
            engine: RecognitionEngine.vision.rawValue
        )
        let job = ScanJob(searchPath: "/Volumes/_DefinitelyNotMounted_VS_Test")
        job.assignedProfile = profile
        model.jobs.append(job)

        model.startJob(job)

        // Synchronous expectation — no polling. If status isn't .failed
        // here, the offline check is downstream of the Task hop.
        if case .failed(let msg) = job.status {
            #expect(msg.contains("offline"),
                    "Expected offline message; got: \(msg)")
        } else {
            let msg = "Offline volume must fail BEFORE async face-loading Task; got \(job.status.label). If this fires, the reachability guard moved back into startJobAfterLoad."
            Issue.record(Comment(rawValue: msg))
        }
    }

    // Refactor risk: startJob has TWO entry points — direct (faces already
    // loaded) and async (loads faces first, then calls startJobAfterLoad).
    // This test exercises the direct path with a noop bail (no faces).
    @Test func startJobBailsOnEmptyFacesForVision() {
        let model = PersonFinderModel()
        // Force engine to vision so we hit the vision branch (UserDefaults
        // from a previous run could have set this to dlib).
        model.settings.recognitionEngine = .vision
        let job = ScanJob(searchPath: "/tmp")   // reachable
        model.jobs.append(job)
        // No profile → uses global referenceFaces, which is empty → bail.
        // Note: assignedProfile nil means startJob skips loadFacesForJob and
        // goes directly to startJobAfterLoad, hitting the !faces.isEmpty guard.

        model.startJob(job)

        job.flushConsoleLines()  // bypass 200ms appendLog batch for sync test read
        let log = job.consoleLines.joined(separator: "\n")
        #expect(log.contains("Load reference photos first"),
                "Should log the load-references hint; got: \(log)")
        // No scanTask spun up → status stays .idle (no transition).
        #expect(job.status == .idle)
    }

    // Refactor risk: dlib pre-flight is a distinct branch from vision.
    // If the dispatcher moves, this guard must move with it (or be
    // preserved at the controller layer).
    @Test func startJobBailsWhenDlibNotConfigured() async {
        let model = PersonFinderModel()
        let job = ScanJob(searchPath: "/tmp")
        model.jobs.append(job)
        // Profile with dlib engine but no python/script paths → bail.
        // Pre-seed an "already loaded" empty assignedFaces sentinel by
        // setting status to non-idle then back — but actually, the simpler
        // route is to call startJobAfterLoad's equivalent path: leave
        // assignedProfile nil and instead set settings directly. That hits
        // the no-profile branch which uses global referenceFaces.
        //
        // Easier: assign a profile but ALSO pre-populate assignedFaces with
        // an empty array (already the default) — startJob's gate is
        // `assignedFaces.isEmpty` AND a non-nil profile → load via Task.
        // We can't easily skip the Task hop, so we accept the async path.
        let profile = POIProfile(name: "T", referencePath: "/tmp/refs",
                                 engine: RecognitionEngine.dlib.rawValue)
        job.assignedProfile = profile
        // Force settings into the dlib-unconfigured state. applyProfile
        // inside startJobAfterLoad copies recognitionEngine from the profile
        // but does not touch pythonPath/recognitionScript.
        model.settings.pythonPath = ""
        model.settings.recognitionScript = ""

        model.startJob(job)
        // Poll for the bail to land — loadFacesForJob + startJobAfterLoad are
        // both async hops, and loadFacesForJob transitions through .loading.
        // Fixed-sleep raced under contention (failed in full suite, passed
        // solo). Poll only on the same conditions the assertions check, so we
        // never short-circuit on a transient (.loading) state with empty log.
        let bailLogged: () -> Bool = {
            job.flushConsoleLines()  // bypass 200ms appendLog batch for sync test read
            let log = job.consoleLines.joined(separator: "\n")
            return log.contains("Set Python path") ||
                   log.contains("Set reference photos path") ||
                   log.contains("offline")
        }
        // 30s deadline — full suite running in parallel with codex stress
        // worktree on the same machine pushed the previous 5s deadline past
        // its budget (16s observed). Bail conditions are deterministic; this
        // poll completes in ms when the system is unloaded, and only wears
        // the long deadline in the rare contention case.
        let deadline = Date().addingTimeInterval(30.0)
        while !bailLogged() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }

        // Status should NOT be .scanning. It can be .idle (loadFacesForJob
        // restored idle then dlib-bail returned without setting status) or
        // .failed if reachability fired first — both prove no scan started.
        #expect(job.status != .scanning,
                "Dlib not configured should prevent scanning; got \(job.status.label)")
        job.flushConsoleLines()  // bypass 200ms appendLog batch for sync test read
        let log = job.consoleLines.joined(separator: "\n")
        let bailedOnConfig = log.contains("Set Python path")
        let bailedOnRefs   = log.contains("Set reference photos path")
        let bailedOnOffline = log.contains("offline")
        #expect(bailedOnConfig || bailedOnRefs || bailedOnOffline,
                "Should log one of the dlib pre-flight messages; got: \(log)")
    }

    // MARK: - startJob: no-op when already active

    // Refactor risk: startJob's idempotency guard (!status.isActive) prevents
    // double-starts. Any controller must preserve this.
    @Test func startJobNoOpWhenAlreadyScanning() {
        let model = PersonFinderModel()
        let job = ScanJob(searchPath: "/tmp")
        model.jobs.append(job)
        job.status = .scanning   // simulate already-running
        let originalLineCount = job.consoleLines.count

        model.startJob(job)

        // Should bail at the top guard — no log lines added, no status change.
        #expect(job.status == .scanning)
        #expect(job.consoleLines.count == originalLineCount,
                "startJob on active job should not log anything")
    }

    // MARK: - stopJob

    // Refactor risk: stopJob transitions .scanning|.paused|.loading → .cancelled
    // but is a no-op on terminal states. The set of "active" states is
    // explicit in ScanJobStatus.isActive — verify the behavior matches.
    @Test func stopJobTransitionsActiveToCancelled() {
        let model = PersonFinderModel()
        let job = ScanJob(searchPath: "/tmp")
        model.jobs.append(job)
        job.status = .scanning
        job.currentFile = "doing_something.mov"

        model.stopJob(job)

        #expect(job.status == .cancelled,
                "Active scan should transition to .cancelled; got \(job.status.label)")
        #expect(job.currentFile == "", "currentFile cleared on stop")
    }

    @Test func stopJobNoOpOnIdleJob() {
        let model = PersonFinderModel()
        let job = ScanJob(searchPath: "/tmp")
        model.jobs.append(job)
        #expect(job.status == .idle)

        model.stopJob(job)

        // .idle isn't .isActive — status should stay .idle, not flip to .cancelled.
        #expect(job.status == .idle,
                "stopJob on idle job should be a no-op; got \(job.status.label)")
    }

    // Note: stopJob on a job with a real scanTask can't be asserted without
    // actually spinning up a scan. Flagging for feature-dev: when the
    // controller refactor lands, consider exposing scanTask state for tests.

    // MARK: - pauseJob / resumeJob / togglePauseJob

    // Refactor risk: pause/resume gates a cooperative actor (PauseGate).
    // If the controller refactor reroutes pause through a different
    // mechanism, these state transitions must remain identical.
    @Test func pauseJobOnlyTransitionsFromScanning() {
        let model = PersonFinderModel()
        let job = ScanJob(searchPath: "/tmp")
        model.jobs.append(job)

        // .idle → pauseJob is a no-op (guard requires .scanning)
        model.pauseJob(job)
        #expect(job.status == .idle)

        // .scanning → .paused
        job.status = .scanning
        model.pauseJob(job)
        #expect(job.status == .paused)

        // .paused → pauseJob again is a no-op
        model.pauseJob(job)
        #expect(job.status == .paused)
    }

    @Test func resumeJobOnlyTransitionsFromPaused() {
        let model = PersonFinderModel()
        let job = ScanJob(searchPath: "/tmp")
        model.jobs.append(job)

        // .idle → resumeJob is a no-op
        model.resumeJob(job)
        #expect(job.status == .idle)

        // .scanning → resumeJob is a no-op (not paused)
        job.status = .scanning
        model.resumeJob(job)
        #expect(job.status == .scanning)

        // .paused → .scanning
        job.status = .paused
        model.resumeJob(job)
        #expect(job.status == .scanning)
    }

    // Refactor risk: togglePauseJob logs to job.appendLog when called from
    // a non-scanning/paused state — that log line is user-visible.
    @Test func togglePauseLogsHintFromIdleState() {
        let model = PersonFinderModel()
        let job = ScanJob(searchPath: "/tmp")
        model.jobs.append(job)
        #expect(job.status == .idle)

        model.togglePauseJob(job)

        #expect(job.status == .idle, "Toggle on idle should not transition")
        job.flushConsoleLines()  // bypass 200ms appendLog batch for sync test read
        let log = job.consoleLines.joined(separator: "\n")
        #expect(log.contains("[pause]"), "Should log a pause-ignored line; got: \(log)")
        #expect(log.contains("Ignored"), "Hint should explain the no-op; got: \(log)")
    }

    @Test func togglePauseSwitchesScanningAndPaused() {
        let model = PersonFinderModel()
        let job = ScanJob(searchPath: "/tmp")
        model.jobs.append(job)

        job.status = .scanning
        model.togglePauseJob(job)
        #expect(job.status == .paused)

        model.togglePauseJob(job)
        #expect(job.status == .scanning)
    }

    // MARK: - Bulk operations (startAll/stopAll/pauseAll/resumeAll)

    // Refactor risk: bulk ops iterate jobs and apply per-status filters.
    // Easy to break during refactor by tightening the filter.
    @Test func stopAllCancelsActiveJobsOnly() {
        let model = PersonFinderModel()
        let j1 = ScanJob(searchPath: "/tmp/a"); j1.status = .scanning
        let j2 = ScanJob(searchPath: "/tmp/b"); j2.status = .paused
        let j3 = ScanJob(searchPath: "/tmp/c"); j3.status = .idle
        let j4 = ScanJob(searchPath: "/tmp/d"); j4.status = .done
        model.jobs = [j1, j2, j3, j4]

        model.stopAll()

        #expect(j1.status == .cancelled, "scanning → cancelled")
        #expect(j2.status == .cancelled, "paused → cancelled (isActive)")
        #expect(j3.status == .idle, "idle stays idle")
        #expect(j4.status == .done, "done stays done")
    }

    @Test func pauseAllOnlyAffectsScanningJobs() {
        let model = PersonFinderModel()
        let j1 = ScanJob(searchPath: "/tmp/a"); j1.status = .scanning
        let j2 = ScanJob(searchPath: "/tmp/b"); j2.status = .scanning
        let j3 = ScanJob(searchPath: "/tmp/c"); j3.status = .idle
        let j4 = ScanJob(searchPath: "/tmp/d"); j4.status = .paused
        model.jobs = [j1, j2, j3, j4]

        model.pauseAll()

        #expect(j1.status == .paused)
        #expect(j2.status == .paused)
        #expect(j3.status == .idle, "idle untouched by pauseAll")
        #expect(j4.status == .paused, "already-paused untouched")
    }

    @Test func resumeAllOnlyAffectsPausedJobs() {
        let model = PersonFinderModel()
        let j1 = ScanJob(searchPath: "/tmp/a"); j1.status = .paused
        let j2 = ScanJob(searchPath: "/tmp/b"); j2.status = .scanning
        let j3 = ScanJob(searchPath: "/tmp/c"); j3.status = .idle
        model.jobs = [j1, j2, j3]

        model.resumeAll()

        #expect(j1.status == .scanning, "paused → scanning")
        #expect(j2.status == .scanning, "scanning untouched")
        #expect(j3.status == .idle)
    }

    // MARK: - Derived state (hasActiveJobs / hasPausedJobs)

    // Refactor risk: these are computed properties — if rephrased as
    // @Published cached values during refactor, the truth-table must hold.
    @Test func hasActiveJobsReflectsScanningCount() {
        let model = PersonFinderModel()
        #expect(!model.hasActiveJobs)

        let j1 = ScanJob(searchPath: "/tmp/a"); j1.status = .idle
        model.jobs = [j1]
        #expect(!model.hasActiveJobs)

        j1.status = .scanning
        #expect(model.hasActiveJobs)

        j1.status = .paused
        #expect(!model.hasActiveJobs, "paused is active for other purposes, but hasActiveJobs is scanning-only")
    }

    @Test func hasPausedJobsTracksPausedOnly() {
        let model = PersonFinderModel()
        let j1 = ScanJob(searchPath: "/tmp/a"); j1.status = .paused
        let j2 = ScanJob(searchPath: "/tmp/b"); j2.status = .scanning
        model.jobs = [j1, j2]

        #expect(model.hasPausedJobs)

        j1.status = .scanning
        #expect(!model.hasPausedJobs)
    }

    // MARK: - clearReference

    // Refactor risk: clearReference wipes both runtime state AND settings.
    // If reference loading moves to a coordinator, this side-effect on
    // settings.referencePath / .rejectedReferenceFiles must persist.
    @Test func clearReferenceWipesStateAndSettings() {
        let model = PersonFinderModel()
        model.settings.referencePath = "/tmp/refs"
        model.settings.rejectedReferenceFiles = ["bad1.jpg", "bad2.jpg"]
        model.referenceSources = ["refs"]
        model.referenceLoadError = "stale error"

        model.clearReference()

        #expect(model.referenceFaces.isEmpty)
        #expect(model.referenceSources.isEmpty)
        #expect(model.referenceLoadError == nil)
        #expect(model.settings.referencePath == "")
        #expect(model.settings.rejectedReferenceFiles.isEmpty)
    }

    // MARK: - cancelCompilation

    // Refactor risk: cancelCompilation resets transient compilation state.
    // No active task is required to assert this — guard test for no-task path.
    @Test func cancelCompilationResetsStateEvenWithoutActiveTask() {
        let model = PersonFinderModel()
        let job = ScanJob(searchPath: "/tmp")
        job.compilationStatus = .compiling
        job.compilationProgress = 0.5
        job.compilationPhase = "Building compilations…"
        model.jobs.append(job)

        model.cancelCompilation(job: job)

        #expect(job.compilationStatus == .idle)
        #expect(job.compilationPhase == "")
        #expect(job.compilationProgress == 0.0)
    }

    // MARK: - startCompilation pre-flight

    // Refactor risk: startCompilation gates on .isDone + non-empty
    // recognitionResults. Both guards must remain after split — they prevent
    // the most common UI-driven misuse (clicking "Compile" too early).
    @Test func startCompilationBailsWhenJobNotDone() {
        let model = PersonFinderModel()
        let job = ScanJob(searchPath: "/tmp")
        job.status = .scanning   // not .done
        model.jobs.append(job)

        model.startCompilation(job: job)

        #expect(job.compilationStatus == .idle,
                "Compilation should not start while scan is still running")
    }

    @Test func startCompilationBailsWhenNoRecognitionResults() {
        let model = PersonFinderModel()
        let job = ScanJob(searchPath: "/tmp")
        job.status = .done
        // recognitionResults is empty by default
        model.jobs.append(job)

        model.startCompilation(job: job)

        #expect(job.compilationStatus == .idle)
        job.flushConsoleLines()  // bypass 200ms appendLog batch for sync test read
        let log = job.consoleLines.joined(separator: "\n")
        #expect(log.contains("No recognition results"),
                "Should log the empty-results message; got: \(log)")
    }

    // MARK: - removeReferenceFaces below confidence

    // Refactor risk: confidence-based pruning appends to rejectedReferenceFiles
    // (which is what makes the rejection persist across reloads). If the
    // reference coordinator owns this, settings must still be the persistence
    // sink.
    @Test func removeReferenceFacesBelowConfidenceUpdatesRejections() {
        let model = PersonFinderModel()
        // referenceFaces is internal-mutable; we can't construct a real
        // VNFeaturePrintObservation, so this test is gap-flagged below.
        // What we CAN test: an empty pool + a confidence threshold call
        // is a safe no-op that doesn't crash and doesn't grow rejections.
        model.settings.rejectedReferenceFiles = []

        model.removeReferenceFaces(belowConfidence: 0.5)

        #expect(model.settings.rejectedReferenceFiles.isEmpty,
                "No faces in pool → nothing to reject")
    }
    // GAP: A test that actually populates referenceFaces with a low-confidence
    // entry and verifies the filename ends up in rejectedReferenceFiles would
    // require either a real VNFeaturePrintObservation (requires running Vision
    // on a fixture image, which the existing `loadFacesForJob*` tests already
    // exercise) or a model-level seam. Both are out of scope for this
    // pre-refactor harness — leaving for the refactor agent to consider.

    // MARK: - RecognitionEngine metadata (UI labels)
    //
    // Refactor risk: a likely move target is to lift RecognitionEngine into
    // its own file (RecognitionEngine.swift) so the dispatcher can live
    // outside the god-object. The string getters are user-visible and must
    // round-trip identically.

    @Test func recognitionEngineRawValueRoundTrips() {
        for engine in RecognitionEngine.allCases {
            let rt = RecognitionEngine(rawValue: engine.rawValue)
            #expect(rt == engine, "rawValue must round-trip for \(engine)")
        }
    }

    @Test func recognitionEngineLabelsAreDistinct() {
        // Each engine has unique title, subtitle, capability and requirements.
        // If any two collapse to the same string, the UI loses information.
        let titles = Set(RecognitionEngine.allCases.map(\.title))
        let subtitles = Set(RecognitionEngine.allCases.map(\.subtitle))
        let capabilities = Set(RecognitionEngine.allCases.map(\.capabilitySummary))
        let requirements = Set(RecognitionEngine.allCases.map(\.requirementsSummary))
        #expect(titles.count == RecognitionEngine.allCases.count)
        #expect(subtitles.count == RecognitionEngine.allCases.count)
        #expect(capabilities.count == RecognitionEngine.allCases.count)
        #expect(requirements.count == RecognitionEngine.allCases.count)
    }

    @Test func recognitionEngineTitleUppercase() {
        // The console log lines (`Engine: VISION`) rely on `.title` being
        // already uppercase. Catching a casing change here is cheaper than
        // discovering it via a regex search through ScanConfigurationTests.
        for engine in RecognitionEngine.allCases {
            #expect(engine.title == engine.title.uppercased(),
                    "Engine title should be uppercase for log lines: \(engine.title)")
        }
    }

    // MARK: - PersonFinderSettings.dlibReadyForHybrid

    // Refactor risk: hybrid mode uses dlibReadyForHybrid (engine-independent)
    // while dlibReady is gated on engine == .dlib. The naming is subtle and
    // easy to swap during refactor. Pin the contract.
    @Test func dlibReadyForHybridIgnoresEngine() {
        var s = PersonFinderSettings()
        s.pythonPath = "/usr/bin/python3"
        s.recognitionScript = "/tmp/face_recognize.py"
        s.recognitionEngine = .vision   // not dlib
        #expect(s.dlibReadyForHybrid,
                "dlibReadyForHybrid should ignore the current engine")
        #expect(!s.dlibReady,
                "dlibReady is gated on engine == .dlib")

        s.recognitionEngine = .dlib
        #expect(s.dlibReady)
    }

    @Test func dlibReadyForHybridFalseWhenPathsMissing() {
        var s = PersonFinderSettings()
        s.pythonPath = ""
        s.recognitionScript = "/tmp/face_recognize.py"
        #expect(!s.dlibReadyForHybrid)
        s.pythonPath = "/usr/bin/python3"
        s.recognitionScript = ""
        #expect(!s.dlibReadyForHybrid)
    }

    // MARK: - FramePerfAccumulator
    //
    // Refactor risk: low — a value type unlikely to move. But it's used
    // for diagnostic logging that surfaces in osLog, and a math regression
    // here would silently corrupt the perf summary. Cheap to pin down.

    @Test func framePerfAccumulatorAccumulates() {
        var acc = FramePerfAccumulator()
        acc.addFrame(decode: 0.010, detect: 0.020, orient: 0.005, match: 0.015)
        acc.addFrame(decode: 0.010, detect: 0.020, orient: 0.005, match: 0.015)

        // Stored in ms: 0.010s × 1000 = 10ms per frame × 2 frames = 20ms.
        #expect(acc.frameCount == 2)
        #expect(acc.decodeMs == 20.0)
        #expect(acc.faceDetectMs == 40.0)
        #expect(acc.orientMs == 10.0)
        #expect(acc.matchMs == 30.0)
        #expect(acc.totalMs == 100.0)
    }

    @Test func framePerfAccumulatorSummaryFormatsAllFields() {
        var acc = FramePerfAccumulator()
        acc.addFrame(decode: 0.010, detect: 0.020, orient: 0.005, match: 0.015)
        acc.skippedFrames = 3
        acc.videoOpenMs = 7

        let summary = acc.summary(filename: "test.mov", wallMs: 200)
        #expect(summary.contains("test.mov"))
        #expect(summary.contains("1 frames"))
        #expect(summary.contains("skipped 3"))
    }

    // MARK: - Gaps documented for refactor-agent (not test failures)
    //
    // The following methods are intentionally NOT covered by this harness:
    //
    //   • runScan / scanAllVideos / processOneVideo — driving these requires
    //     real video files and a settled MainActor handoff. The existing
    //     ScanConfigurationTests cover the *configuration* surface around them
    //     (engine selection, threshold logging). The dispatch switch inside
    //     processOneVideo is the hot refactor target; it should be lifted
    //     into a standalone RecognitionDispatcher with its own test target.
    //
    //   • restoreFromCache (the Task.detached body) — fires on a background
    //     thread and writes to MainActor; asserting on it without a real
    //     scan target is racy. ScanConfigurationTests/cacheRestore* test the
    //     *result* shape (job.results + status), which is the contract
    //     refactor-agent should preserve.
    //
    //   • Compilation pipeline (runCompilation, compileAndCleanup, all the
    //     pf* helpers in the bottom half of the file) — requires real ffmpeg
    //     output. Cover via integration tests, not lifecycle tests.
    //
    //   • POI persistence round-trip (saveCurrentPOI, loadPOI, updateProfile,
    //     deletePOI) — touches ~/Library/Application Support and would
    //     pollute the dev machine's POI gallery. Covered by POIProfile's
    //     Codable round-trip in a separate file if added later.
}
