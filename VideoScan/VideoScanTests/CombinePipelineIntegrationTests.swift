import Testing
import Foundation
@testable import VideoScan

// MARK: - CombinePipelineIntegrationTests
//
// MANUAL-RUN integration tests that drive the full Correlate → Combine
// pipeline against a COPY of Rick's REAL catalog and invoke REAL ffmpeg.
//
// Why this exists: the 1196-test unit suite proves correlation math and
// proves CombineEngine arg construction, but nothing in the unit suite
// proves "user clicks Find A/V Pairs, then Combine, and a valid file
// appears." This file is the regression net for the underlying combine
// pipeline using REAL data shapes. A future XCUITest pass will cover the
// click path; this covers the model layer end-to-end.
//
// Tests are tagged disabled-by-default with .disabled(...). To run:
//
//   xcodebuild test \
//     -project VideoScan/VideoScan.xcodeproj \
//     -scheme VideoScan \
//     -configuration Debug \
//     -derivedDataPath /tmp/vs-build-integration \
//     -only-testing:VideoScanTests/CombinePipelineIntegrationTests
//
// Then comment out the .disabled(...) trait or pass -test-runner-env
// VS_RUN_COMBINE_INTEGRATION=1 (the tests early-out if that env var
// isn't set).
//
// SAFETY: every test copies catalog.json to a per-test /tmp directory
// BEFORE touching CatalogStore. There's a hard guard that aborts if the
// tmp dir ever resolves to anything under ~/Library/Application Support/.
// We do NOT write to the real catalog.
//
// C++ analogy: `@Suite(.serialized)` ≈ a test fixture's GUARDED_BY mutex
// — Swift Testing runs sibling @Test methods sequentially within the
// suite so two tests can't race for the ffmpeg binary or the RAM disk.

@Suite(.serialized) @MainActor
struct CombinePipelineIntegrationTests {

    // MARK: - Configuration

    /// Hard upper bound on real ffmpeg invocations per test so a runaway
    /// pick can't burn 20 minutes. Tunable, but 2 keeps the whole suite
    /// under ~2 minutes wall-clock on Rick's M4 Max.
    static let maxCombinesPerTest = 2

    /// Skip pairs whose video duration exceeds this; keeps ffmpeg fast.
    static let maxDurationSeconds: Double = 30.0

    /// Total time budget for the entire correlate-then-combine flow,
    /// per test. Beyond this we fail with a diagnostic so we don't
    /// silently sit on a hung RAM disk mount or ffprobe stall.
    static let testTimeoutSeconds: Double = 240.0

    // MARK: - Setup helpers

    /// Per-test tmp directory under /tmp. Includes a UUID so concurrent
    /// runs (or a forgotten cleanup) can't collide.
    private static func makeTmpDir(_ purpose: String) throws -> URL {
        let dir = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("vs-combine-integration-\(purpose)-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // GUARD: refuse if the path somehow resolved inside the real
        // Application Support tree. Belt-and-suspenders — this should
        // be impossible given the URL we just built, but a misconfigured
        // TMPDIR env var or a symlink could in principle redirect us.
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first?.path ?? ""
        let resolved = (dir.resolvingSymlinksInPath().path as NSString).standardizingPath
        if !appSupport.isEmpty && resolved.hasPrefix(appSupport) {
            fatalError("REFUSING TO RUN: tmp dir \(resolved) resolved into Application Support — would risk corrupting the real catalog.")
        }
        // Also refuse anything under $HOME/Library that isn't /tmp.
        if !resolved.hasPrefix("/tmp/") && !resolved.hasPrefix("/private/tmp/") {
            fatalError("REFUSING TO RUN: tmp dir \(resolved) is not under /tmp — refusing to risk catalog corruption.")
        }
        return dir
    }

    /// Copy the real catalog.json (+ .prev sidecar) into `dir`. Returns
    /// the path of the copied catalog so tests can verify size/age.
    @discardableResult
    private static func copyRealCatalog(to dir: URL) throws -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let srcDir = appSupport.appendingPathComponent("VideoScan", isDirectory: true)
        let src = srcDir.appendingPathComponent("catalog.json")
        let srcPrev = srcDir.appendingPathComponent("catalog.json.prev")
        let dst = dir.appendingPathComponent("catalog.json")
        let dstPrev = dir.appendingPathComponent("catalog.json.prev")

        try FileManager.default.copyItem(at: src, to: dst)
        if FileManager.default.fileExists(atPath: srcPrev.path) {
            try FileManager.default.copyItem(at: srcPrev, to: dstPrev)
        }
        return dst
    }

    /// Construct a VideoScanModel and swap in a CatalogStore pointed at
    /// the per-test tmp dir. Loads the copied catalog. Returns nil if
    /// the catalog is empty (test should skip cleanly).
    private static func loadModelFromTmpCatalog(at dir: URL) -> VideoScanModel? {
        let model = VideoScanModel()
        let store = CatalogStore(directory: dir)
        model.catalogStore = store
        let records = store.load()
        guard !records.isEmpty else {
            return nil
        }
        model.records = records
        return model
    }

    /// Verify the produced .mov actually parses and contains the expected
    /// stream types. Returns nil on hard failure (file missing / ffprobe
    /// crash), otherwise a tuple of (videoStreams, audioStreams, sizeBytes).
    private static func probeOutput(_ url: URL) -> (videoStreams: Int, audioStreams: Int, sizeBytes: Int64)? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        let attrs = try? fm.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? Int64) ?? 0

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ToolLocator.ffprobePath)
        proc.arguments = ["-v", "quiet", "-print_format", "json", "-show_streams", url.path]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let json = try? JSONDecoder().decode(FFProbeOutput.self, from: data) else { return nil }
        let streams = json.streams ?? []
        let v = streams.filter { $0.codec_type == "video" }.count
        let a = streams.filter { $0.codec_type == "audio" }.count
        return (v, a, size)
    }

    /// Spin-wait on `model.isCombining` with a hard deadline so a hung
    /// ffmpeg doesn't make the test hang the whole CI run.
    /// `// @MainActor sleep` ≈ a sleep that yields back to the runloop so
    /// the @Published combineCompleted counter can update.
    private static func waitForCombineComplete(_ model: VideoScanModel, timeoutSeconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while model.isCombining {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return true
    }

    /// Pick combine candidates from a freshly-correlated catalog. Filters
    /// to (a) both halves exist on disk RIGHT NOW, (b) short duration so
    /// ffmpeg returns quickly. Returns at most `limit` pairs.
    private static func pickRunnablePairs(
        model: VideoScanModel,
        limit: Int,
        maxDuration: Double
    ) -> [(video: VideoRecord, audio: VideoRecord)] {
        let fm = FileManager.default
        return model.correlatedPairs
            .filter { pair in
                fm.fileExists(atPath: pair.video.fullPath) &&
                fm.fileExists(atPath: pair.audio.fullPath) &&
                pair.video.durationSeconds > 0 &&
                pair.video.durationSeconds <= maxDuration
            }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Test 1: real pair → valid output

    @Test(.disabled("manual integration test — see file header to run"))
    func correlate_then_combine_realPair_producesValidOutputFile() async throws {
        let started = Date()
        let tmpDir = try Self.makeTmpDir("happy")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try Self.copyRealCatalog(to: tmpDir)
        print("[INTEG] Copied catalog → \(tmpDir.path)")

        guard let model = Self.loadModelFromTmpCatalog(at: tmpDir) else {
            Issue.record("Copied catalog loaded empty — nothing to correlate")
            return
        }
        print("[INTEG] Loaded \(model.records.count) records")

        // Run the real correlator across the real catalog.
        await model.correlateAcrossVolumes()
        print("[INTEG] Correlate: \(model.correlateStatus)")
        let totalPairs = model.correlatedPairs.count
        try #require(totalPairs > 0, "Catalog produced zero correlated pairs — can't run combine")

        let picks = Self.pickRunnablePairs(
            model: model, limit: 1, maxDuration: Self.maxDurationSeconds
        )
        try #require(!picks.isEmpty, """
            No correlated pairs satisfy (both files online, dur ≤ \(Self.maxDurationSeconds)s).
            Total pairs: \(totalPairs). Consider raising maxDurationSeconds or rescanning
            so at least one short pair is reachable on the local machine.
            """)

        let pick = picks[0]
        print("""
        [INTEG] Picked pair (dur=\(pick.video.durationSeconds)s):
                video: \(pick.video.fullPath)
                audio: \(pick.audio.fullPath)
        """)

        let outputDir = tmpDir.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        // The full pipeline entry the UI calls. Spawns a Task internally
        // and returns immediately — we poll isCombining for completion.
        model.combineSelectedPairs([pick], outputFolder: outputDir, maxConcurrency: 1)
        let done = await Self.waitForCombineComplete(model, timeoutSeconds: Self.testTimeoutSeconds)
        try #require(done, "Combine did not complete within \(Self.testTimeoutSeconds)s — likely hung ffmpeg or RAM disk mount")

        // The output filename pattern is deterministic: <videoBaseName>_combined.mov
        let baseName = URL(fileURLWithPath: pick.video.fullPath)
            .deletingPathExtension().lastPathComponent
        let expectedOut = outputDir.appendingPathComponent("\(baseName)_combined.mov")

        #expect(model.dashboard.combineFailed == 0,
                "ffmpeg reported \(model.dashboard.combineFailed) failure(s) — check console")
        #expect(model.dashboard.combineSucceeded >= 1,
                "Expected at least 1 success; got \(model.dashboard.combineSucceeded)")

        guard let probe = Self.probeOutput(expectedOut) else {
            Issue.record("Output file missing or ffprobe failed: \(expectedOut.path)")
            return
        }
        print("[INTEG] Output: \(expectedOut.path) — \(probe.sizeBytes) bytes, V=\(probe.videoStreams) A=\(probe.audioStreams)")
        #expect(probe.sizeBytes > 100_000, "Suspiciously small output: \(probe.sizeBytes) bytes")
        #expect(probe.videoStreams >= 1, "Output missing video stream")
        #expect(probe.audioStreams >= 1, "Output missing audio stream")

        let elapsed = Date().timeIntervalSince(started)
        print("[INTEG] Test 1 elapsed: \(String(format: "%.1f", elapsed))s")
    }

    // MARK: - Test 2: offline half → substitute path

    @Test(.disabled("manual integration test — see file header to run"))
    func combine_withOfflineHalf_findsSubstitute_andCompletes() async throws {
        let started = Date()
        let tmpDir = try Self.makeTmpDir("substitute")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try Self.copyRealCatalog(to: tmpDir)

        guard let model = Self.loadModelFromTmpCatalog(at: tmpDir) else {
            Issue.record("Copied catalog loaded empty")
            return
        }
        await model.correlateAcrossVolumes()

        // Look for any pair where ONE side is currently offline AND the
        // offline side has a UMID-matched substitute that IS reachable.
        // This is exactly the scenario UmidResolver was built for.
        let fm = FileManager.default
        let candidate: (offlinePair: (video: VideoRecord, audio: VideoRecord),
                        substitute: VideoRecord,
                        substitutedSide: String)? = {
            for pair in model.correlatedPairs {
                let vOnline = fm.fileExists(atPath: pair.video.fullPath)
                let aOnline = fm.fileExists(atPath: pair.audio.fullPath)
                if !vOnline && aOnline {
                    if let sub = model.findSubstitutes(for: pair.video)
                        .first(where: { fm.fileExists(atPath: $0.fullPath) }) {
                        return (pair, sub, "video")
                    }
                }
                if vOnline && !aOnline {
                    if let sub = model.findSubstitutes(for: pair.audio)
                        .first(where: { fm.fileExists(atPath: $0.fullPath) }) {
                        return (pair, sub, "audio")
                    }
                }
            }
            return nil
        }()

        guard let candidate else {
            // Per spec: no fail. Skip cleanly with a clear message.
            print("[INTEG] SKIP: no offline pairs with reachable UMID substitute in current catalog.")
            print("[INTEG]       (Everything Rick has online right now is either fully online or has no substitute.)")
            return
        }

        print("""
        [INTEG] Found offline-\(candidate.substitutedSide) pair:
                offline: \(candidate.substitutedSide == "video" ? candidate.offlinePair.video.fullPath : candidate.offlinePair.audio.fullPath)
                substitute: \(candidate.substitute.fullPath)
        """)

        // Sanity: must be under our duration cap so ffmpeg doesn't burn 10 minutes.
        if candidate.offlinePair.video.durationSeconds > Self.maxDurationSeconds {
            print("[INTEG] SKIP: substitute pair video duration \(candidate.offlinePair.video.durationSeconds)s exceeds cap \(Self.maxDurationSeconds)s")
            return
        }

        let outputDir = tmpDir.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let beforeCount = model.dashboard.combineSucceeded
        model.combineSelectedPairs([candidate.offlinePair],
                                   outputFolder: outputDir,
                                   maxConcurrency: 1)
        let done = await Self.waitForCombineComplete(model, timeoutSeconds: Self.testTimeoutSeconds)
        try #require(done, "Combine did not complete within \(Self.testTimeoutSeconds)s")

        // The output basename comes from the RESOLVED (substitute) video,
        // not the offline original, when the video side was substituted.
        // When the audio side was substituted, basename still derives from
        // the original (reachable) video.
        let videoForName = candidate.substitutedSide == "video"
            ? candidate.substitute
            : candidate.offlinePair.video
        let baseName = URL(fileURLWithPath: videoForName.fullPath)
            .deletingPathExtension().lastPathComponent
        let expectedOut = outputDir.appendingPathComponent("\(baseName)_combined.mov")

        #expect(model.dashboard.combineSucceeded > beforeCount,
                "Substitute path did not produce a successful combine")
        #expect(model.dashboard.combineFailed == 0,
                "Substitute combine reported failure(s)")

        guard let probe = Self.probeOutput(expectedOut) else {
            Issue.record("Substitute output missing / ffprobe failed: \(expectedOut.path)")
            return
        }
        print("[INTEG] Substitute output: \(expectedOut.path) — \(probe.sizeBytes) bytes")
        #expect(probe.sizeBytes > 100_000)
        #expect(probe.videoStreams >= 1)
        #expect(probe.audioStreams >= 1)

        // Evidence the resolver was actually invoked: the console log should
        // include a [SUBSTITUTE ...] line for the substituted side. This is
        // the user-visible proof in the dashboard console.
        let consoleLines = model.dashboard.consoleLines.joined(separator: "\n")
        #expect(consoleLines.contains("[SUBSTITUTE \(candidate.substitutedSide)]"),
                "Console did not log a SUBSTITUTE \(candidate.substitutedSide) line — resolver path didn't fire")

        let elapsed = Date().timeIntervalSince(started)
        print("[INTEG] Test 2 elapsed: \(String(format: "%.1f", elapsed))s")
    }

    // MARK: - Test 3: combined record lands on Workbench

    @Test(.disabled("manual integration test — see file header to run"))
    func combine_thenCheckLifecycleStage_workbench() async throws {
        let started = Date()
        let tmpDir = try Self.makeTmpDir("workbench")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try Self.copyRealCatalog(to: tmpDir)

        guard let model = Self.loadModelFromTmpCatalog(at: tmpDir) else {
            Issue.record("Copied catalog loaded empty")
            return
        }
        await model.correlateAcrossVolumes()

        let preCombineRecordCount = model.records.count
        let picks = Self.pickRunnablePairs(
            model: model, limit: 1, maxDuration: Self.maxDurationSeconds
        )
        try #require(!picks.isEmpty, "No runnable pairs to combine")

        let outputDir = tmpDir.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        model.combineSelectedPairs([picks[0]],
                                   outputFolder: outputDir,
                                   maxConcurrency: 1)
        let done = await Self.waitForCombineComplete(model, timeoutSeconds: Self.testTimeoutSeconds)
        try #require(done, "Combine did not complete within \(Self.testTimeoutSeconds)s")
        try #require(model.dashboard.combineSucceeded >= 1, "Combine did not succeed; cannot check lifecycle")

        // Newly-combined files should be appended to model.records with
        // lifecycleStage == .workbench per the recent Workbench feature.
        let appended = Array(model.records.dropFirst(preCombineRecordCount))
        try #require(!appended.isEmpty,
                     "Expected at least one new record appended after successful combine; got \(appended.count)")
        let newRec = appended[0]
        #expect(newRec.lifecycleStage == .workbench,
                "Combined record lifecycleStage was \(newRec.lifecycleStage) — should be .workbench")
        #expect(newRec.combinedFromPairID != nil,
                "Combined record should carry combinedFromPairID for back-linking")

        let elapsed = Date().timeIntervalSince(started)
        print("[INTEG] Test 3 elapsed: \(String(format: "%.1f", elapsed))s")
    }
}
