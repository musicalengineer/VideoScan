import Foundation
import Testing
@testable import VideoScan

// MARK: - Volume analyze queue tests (2026-07-14)
//
// Pins the FIFO enqueue model that replaced the "disable Analyze while
// another volume runs" dead button: intent is never blocked, volumes
// line up and run one at a time, the pending line survives relaunch,
// and DossierAutoResume decides whether a restored line auto-starts.
//
// Dimensions per the feature-test checklist:
//   Logic (FIFO order / dequeue / positions / Analyze All selection),
//   Isolation (poisoned real standard defaults must be ignored by a
//   test-host orchestrator; persistence exercised via injected suite),
//   Sensor (scope-skipped audio never reaches the runner AND never
//   mutates the record — reversible, not junk).
// Scale is covered in AnalysisScopeTests (the gate is the only new
// O(records) pass). Media matrix: N/A — stub runner, no media opened.

// MARK: Fixtures

@MainActor
private func queueRecord(fullPath: String,
                         streamTypeRaw: String = StreamType.videoAndAudio.rawValue) -> VideoRecord {
    let r = VideoRecord()
    r.filename = (fullPath as NSString).lastPathComponent
    r.fullPath = fullPath
    r.streamTypeRaw = streamTypeRaw
    r.durationSeconds = 3.0
    r.lifecycleStage = .cataloged
    return r
}

/// Three tiny "volumes" (tmp subdirectories) with one media stand-in
/// each. Returns (root, volumePrefixes, records).
@MainActor
private func makeThreeVolumes(tag: String) throws -> (String, [String], [VideoRecord]) {
    let root = NSTemporaryDirectory() + "vs-queue-\(tag)-\(UUID().uuidString)/"
    var prefixes: [String] = []
    var recs: [VideoRecord] = []
    for name in ["volA", "volB", "volC"] {
        let dir = root + name + "/"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let file = dir + "clip.mp4"
        FileManager.default.createFile(atPath: file, contents: Data("x".utf8))
        prefixes.append(dir)
        recs.append(queueRecord(fullPath: file))
    }
    return (root, prefixes, recs)
}

/// Poll until the queue is fully drained (nothing queued, nothing
/// dispatching, nothing running). The 20 ms sleep yields the MainActor
/// so the orchestrator's dispatch Tasks make progress.
@MainActor
private func awaitQueueDrain(_ orch: CaptionOrchestrator,
                             timeoutSeconds: Double = 15) async -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if orch.queuedVolumePrefixes.isEmpty,
           !orch.queueDispatchInFlight,
           !orch.currentStatus.isActive {
            return true
        }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return false
}

// MARK: - Tests

@MainActor
@Suite("CaptionOrchestrator analyze queue")
struct CaptionOrchestratorQueueTests {

    @Test("rapid enqueues run every volume exactly once, FIFO order")
    func fifoOrderAcrossThreeVolumes() async throws {
        let model = VideoScanModel()
        let (root, prefixes, recs) = try makeThreeVolumes(tag: "fifo")
        defer { try? FileManager.default.removeItem(atPath: root) }
        model.records = recs

        let stub = StubDossierRunner(modelID: "stub-vlm-queue")
        let orch = CaptionOrchestrator(runnerFactory: { stub })

        // Express intent on all three without waiting — the exact
        // gesture the old disabled button blocked.
        for p in prefixes {
            orch.enqueueAnalyze(volumePrefix: p, model: model)
        }
        #expect(await awaitQueueDrain(orch), "queue never drained")

        let processed = await stub.pathsCalled()
        #expect(processed == recs.map(\.fullPath),
                "volumes must run once each, in enqueue order; got \(processed)")
    }

    @Test("enqueue while busy queues with 1-based positions; dequeue removes")
    func positionsAndDequeue() {
        let model = VideoScanModel()
        let orch = CaptionOrchestrator()
        // Simulate a running batch so enqueues stay queued.
        orch.currentStatus = .running(progress: 0.5, currentFile: "x", etaSec: nil)
        orch.currentVolumePrefix = "/Volumes/A/"

        orch.enqueueAnalyze(volumePrefix: "/Volumes/B/", model: model)
        orch.enqueueAnalyze(volumePrefix: "/Volumes/C/", model: model)
        // Idempotent: re-clicking Analyze on a queued volume is a no-op.
        orch.enqueueAnalyze(volumePrefix: "/Volumes/B/", model: model)
        // Enqueueing the volume that's currently analyzing is a no-op.
        orch.enqueueAnalyze(volumePrefix: "/Volumes/A/", model: model)

        #expect(orch.queuedVolumePrefixes == ["/Volumes/B/", "/Volumes/C/"])
        #expect(orch.queuePosition(of: "/Volumes/B/") == 1)
        #expect(orch.queuePosition(of: "/Volumes/C/") == 2)
        #expect(orch.queuePosition(of: "/Volumes/A/") == nil)

        orch.dequeueAnalyze(volumePrefix: "/Volumes/B/")
        #expect(orch.queuedVolumePrefixes == ["/Volumes/C/"])
        #expect(orch.queuePosition(of: "/Volumes/C/") == 1)

        // Leave nothing running for later tests sharing the actor.
        orch.currentStatus = .idle
    }

    @Test("startAnalyzing reports ran-vs-refused so single-file jobs can wait")
    func startAnalyzingReturnValue() async {
        let model = VideoScanModel()
        let orch = CaptionOrchestrator()

        orch.currentStatus = .running(progress: 0.1, currentFile: "x", etaSec: nil)
        let refused = await orch.startAnalyzing(volumePrefix: "/Volumes/B/", model: model)
        #expect(refused == false, "busy orchestrator must refuse (return false)")

        orch.currentStatus = .idle
        let ran = await orch.startAnalyzing(volumePrefix: "/nonexistent-prefix/", model: model)
        #expect(ran == true, "an empty candidate set is still a completed run")
    }

    @Test("queue persists to the injected suite and restores paused without auto-resume")
    func persistenceAndPausedRestore() throws {
        let suiteName = "vs-test-queue-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = VideoScanModel()

        let first = CaptionOrchestrator(defaults: defaults)
        first.currentStatus = .running(progress: 0.5, currentFile: "x", etaSec: nil)
        first.enqueueAnalyze(volumePrefix: "/Volumes/B/", model: model)
        first.enqueueAnalyze(volumePrefix: "/Volumes/C/", model: model)
        #expect(defaults.stringArray(forKey: CaptionOrchestrator.queuedVolumesPrefsKey)
                == ["/Volumes/B/", "/Volumes/C/"])
        first.currentStatus = .idle

        // Relaunch with DossierAutoResume unset → line restores PAUSED
        // (visible, never auto-started, never silently dropped).
        let second = CaptionOrchestrator(defaults: defaults)
        #expect(second.queuedVolumePrefixes == ["/Volumes/B/", "/Volumes/C/"])
        #expect(second.queuePaused == true)

        // Relaunch with DossierAutoResume ON → not paused.
        defaults.set(true, forKey: "DossierAutoResume")
        let third = CaptionOrchestrator(defaults: defaults)
        #expect(third.queuedVolumePrefixes == ["/Volumes/B/", "/Volumes/C/"])
        #expect(third.queuePaused == false)
    }

    @Test("resumePersistedWork puts interrupted volumes ahead of the pending line")
    func resumeOrdersInterruptedFirst() throws {
        let suiteName = "vs-test-queue-resume-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(["/Volumes/Queued1/", "/Volumes/Queued2/"],
                     forKey: CaptionOrchestrator.queuedVolumesPrefsKey)
        defaults.set(["/Volumes/Interrupted/"],
                     forKey: CaptionOrchestrator.activeVolumesPrefsKey)
        defaults.set(true, forKey: "DossierAutoResume")

        let model = VideoScanModel()
        let orch = CaptionOrchestrator(defaults: defaults)
        // Hold the orchestrator "busy" so resume only reorders the
        // line without dispatching (keeps the assertion synchronous).
        orch.currentStatus = .running(progress: 0.1, currentFile: "x", etaSec: nil)
        orch.resumePersistedWork(model: model)
        #expect(orch.queuedVolumePrefixes ==
                ["/Volumes/Interrupted/", "/Volumes/Queued1/", "/Volumes/Queued2/"])
        orch.currentStatus = .idle
    }

    @Test("isolation: a test-host orchestrator on REAL standard defaults neither reads nor writes them")
    func poisonedStandardDefaultsIgnored() {
        let key = CaptionOrchestrator.queuedVolumesPrefsKey
        let poison = ["/Volumes/PoisonA/", "/Volumes/PoisonB/"]
        let original = UserDefaults.standard.stringArray(forKey: key)
        UserDefaults.standard.set(poison, forKey: key)
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        let model = VideoScanModel()
        let orch = CaptionOrchestrator()   // defaults: .standard, in a test host
        #expect(orch.queuedVolumePrefixes.isEmpty,
                "test-host orchestrator must not inherit the user's live queue")

        orch.currentStatus = .running(progress: 0.5, currentFile: "x", etaSec: nil)
        orch.enqueueAnalyze(volumePrefix: "/Volumes/TestOnly/", model: model)
        #expect(UserDefaults.standard.stringArray(forKey: key) == poison,
                "test-host orchestrator must not write the user's live prefs")
        orch.currentStatus = .idle
    }

    @Test("pfAnalyzeAllPrefixes picks volumes with remaining work, minus queued and active")
    func analyzeAllSelection() {
        let out = pfAnalyzeAllPrefixes(
            remainingByVolume: [
                (prefix: "/Volumes/A/", remaining: 10),
                (prefix: "/Volumes/B/", remaining: 0),
                (prefix: "/Volumes/C/", remaining: 3),
                (prefix: "/Volumes/D/", remaining: 7),
                (prefix: "/Volumes/E/", remaining: 2),
            ],
            queued: ["/Volumes/D/"],
            activePrefix: "/Volumes/A/"
        )
        #expect(out == ["/Volumes/C/", "/Volumes/E/"])
    }
}

// MARK: - Scope gate at the batch boundary (regression sensors)

@MainActor
@Suite("Analyze scope gate in volume batches")
struct AnalyzeScopeBatchTests {

    @Test("sensor: scope-skipped audio never reaches the runner and is NOT mutated")
    func scopedOutAudioUntouched() async throws {
        let model = VideoScanModel()
        let root = NSTemporaryDirectory() + "vs-scope-batch-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        // The cover-art mp3: ffprobe says Video+Audio, so stream-type
        // filtering alone would feed it to frame extraction.
        let mp3Path = root + "Highway Star.mp3"
        FileManager.default.createFile(atPath: mp3Path, contents: Data("x".utf8))
        let mp3 = queueRecord(fullPath: mp3Path)

        // Extensionless recovered essence: must still be analyzed.
        let orphanPath = root + "recovered_essence"
        FileManager.default.createFile(atPath: orphanPath, contents: Data("x".utf8))
        let orphan = queueRecord(fullPath: orphanPath,
                                 streamTypeRaw: StreamType.ffprobeFailed.rawValue)

        model.records = [mp3, orphan]

        let stub = StubDossierRunner(modelID: "stub-vlm-scope")
        let orch = CaptionOrchestrator(runnerFactory: { stub })
        await orch.startAnalyzing(volumePrefix: root, model: model)

        let processed = await stub.pathsCalled()
        #expect(processed == [orphanPath],
                "default scope must keep the mp3 away from the runner, keep the orphan in")

        // Scope-skipped is reversible — NOT junk, NOT purged, NOT
        // processed. Flipping the toggle must be able to bring the
        // record back exactly as it was.
        #expect(mp3.dossierProcessedAt == nil)
        #expect(mp3.mediaDisposition == .unreviewed)
        #expect(mp3.purgedAt == nil)
        #expect(mp3.lifecycleStage == .cataloged)
    }

    @Test("audio toggle ON analyzes the audio file but still skips frame extraction")
    func scopeOnTranscribesWithoutVLM() async throws {
        let model = VideoScanModel()
        let root = NSTemporaryDirectory() + "vs-scope-on-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let mp3Path = root + "song.mp3"
        FileManager.default.createFile(atPath: mp3Path, contents: Data("x".utf8))
        let mp3 = queueRecord(fullPath: mp3Path)
        model.records = [mp3]

        let stub = StubDossierRunner(modelID: "stub-vlm-scope-on")
        let orch = CaptionOrchestrator(runnerFactory: { stub })
        var scope = orch.analysisScope
        scope.includeAudioOnly = true
        orch.updateAnalysisScope(scope)

        let transcriber = StubAudioTranscriber(modelID: "stub-whisper-scope-on")
        await orch.startAnalyzing(volumePrefix: root, model: model,
                                  transcriber: transcriber)

        // VLM must never see the mp3 (cover art ≠ video)…
        let vlmPaths = await stub.pathsCalled()
        #expect(vlmPaths.isEmpty,
                "audio-classified files must skip frame extraction even when in scope")
        // …but Whisper does, and the dossier banks.
        #expect(transcriber.calledPaths == [mp3Path])
        #expect(mp3.dossierProcessedAt != nil)
    }

    @Test("ignoringScope lets a single-file batch analyze a scoped-out audio file")
    func ignoringScopeWins() async throws {
        let model = VideoScanModel()
        let root = NSTemporaryDirectory() + "vs-scope-ignore-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let mp3Path = root + "memo.mp3"
        FileManager.default.createFile(atPath: mp3Path, contents: Data("x".utf8))
        let mp3 = queueRecord(fullPath: mp3Path)
        model.records = [mp3]

        let stub = StubDossierRunner(modelID: "stub-vlm-ignore")
        let orch = CaptionOrchestrator(runnerFactory: { stub })
        let transcriber = StubAudioTranscriber(modelID: "stub-whisper-ignore")

        // Default scope (audio OFF) + ignoringScope=true — the exact
        // shape of an AnalyzeJob for "Transcribe Audio on THIS mp3".
        await orch.startAnalyzing(volumePrefix: mp3Path, model: model,
                                  transcriber: transcriber,
                                  ignoringScope: true)

        #expect(transcriber.calledPaths == [mp3Path],
                "explicit per-file intent must beat the scope defaults")
        #expect(mp3.dossierProcessedAt != nil)
    }
}
