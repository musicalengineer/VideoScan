import Testing
import Foundation
import os
@testable import VideoScan

// MARK: - PauseGateTestHostDefaultTests
//
// Regression net for CI run 36192353105 (2026-09-25, main 65d97169): the
// "Unit tests — pure-logic suites" step hit its 60-minute timeout inside
// DiscoveryCompletenessPipelineTests.tripAcrossCountryShapeCatalogsExactlyTheValidMedia.
// Its last log line: "Memory pressure HIGH — available: 2188 MB, threshold:
// 4096 MB". Every probe child of a catalog scan checkpoints on its target's
// PauseGate (VideoScanModel+ProbeEngine runProbeChild), whose memory
// auto-pause read the 7 GB runner's free RAM against the 4 GB floor and
// waited for memory that never came. The day before, the same class hung
// CombineNeverOverwritesTests through the Combine gate.
//
// Fix: a PauseGate built without an explicit `autoPause:` defaults memory
// auto-pause OFF in a test host (PauseGate.defaultAutoPause). The app's
// default is unchanged. These tests pin both branches, the app-created
// gates, and — deterministically, with an injected "memory is always low"
// reading — a whole catalog scan finishing instead of hanging.

/// Await a catalog scan's unstructured task, forwarding the CALLER's
/// cancellation (e.g. a Swift Testing time limit) to it. A bare
/// `await target.scanTask?.value` ignores the waiter's cancellation: an
/// unstructured Task is not a child, so a stalled scan would outlive the
/// time limit that was supposed to end it.
/// C++ analogy: joining a std::jthread while forwarding our stop_token.
enum ScanTaskAwait {
    @MainActor
    static func value(of target: CatalogScanTarget) async {
        guard let task = target.scanTask else { return }
        await withTaskCancellationHandler {
            _ = await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

@Suite("PauseGate — memory auto-pause is OFF by default in a test host", .timeLimit(.minutes(1)))
struct PauseGateTestHostDefaultTests {

    // MARK: Policy (both branches)

    @Test("the app keeps memory auto-pause ON by default; a test host gets it OFF")
    func defaultPolicyByHost() {
        #expect(PauseGate.defaultAutoPause(isTestHost: false),
                "production default must stay ON — the app still pauses scans under real memory pressure")
        #expect(!PauseGate.defaultAutoPause(isTestHost: true),
                "a test must never wait on the host's free RAM")
    }

    @Test("fixture sanity: this process is detected as a test host")
    func thisProcessIsATestHost() {
        #expect(TestHostDetection.isTestHost)
    }

    // MARK: Gate behavior under a simulated low-memory host

    @Test("RED 2026-09-25: a default gate under 'memory is always low' passes straight through and never reads memory")
    func defaultGate_lowMemory_passesThrough() async {
        let consulted = OSAllocatedUnfairLock(initialState: false)
        let gate = PauseGate(pressureCheck: { consulted.withLock { $0 = true }; return true },
                             recheckInterval: .milliseconds(50))
        #expect(await gate.isAutoPauseEnabled == false)
        let returned = await PauseGateCancellationTests.waiterReturns(on: gate, cancelAfter: nil, within: 2)
        #expect(returned, "pre-fix this waiter auto-paused and waited for memory forever (the CI hang)")
        #expect(!consulted.withLock { $0 }, "with auto-pause off the gate must not even read memory")
        await gate.resume()   // releases the waiter if the default ever regresses
    }

    @Test("explicit autoPause: true still auto-pauses in a test host (opt-in wins)")
    func explicitOptIn_stillAutoPauses() async {
        let gate = PauseGate(pressureCheck: { true }, recheckInterval: .milliseconds(50), autoPause: true)
        #expect(await gate.isAutoPauseEnabled)
        let returned = await PauseGateCancellationTests.waiterReturns(on: gate, cancelAfter: nil, within: 0.4)
        #expect(!returned, "an opted-in gate under sustained pressure must wait")
        await gate.resume()
    }

    @Test("setAutoPause(true) after construction re-enables auto-pause")
    func setAutoPause_overridesDefault() async {
        let gate = PauseGate(pressureCheck: { true })
        await gate.setAutoPause(true)
        #expect(await gate.isAutoPauseEnabled)
        await gate.resume()
    }

    // MARK: Sensor — the gates the app builds

    @MainActor @Test("SENSOR: the Combine gate and a scan target's gate are auto-pause OFF in a test host")
    func appCreatedGates_areOffInTestHost() async {
        let model = VideoScanModel()
        #expect(await model.combinePauseGate.isAutoPauseEnabled == false)
        let target = CatalogScanTarget(searchPath: NSTemporaryDirectory())
        #expect(await target.pauseGate.isAutoPauseEnabled == false)
    }

    // MARK: Pipeline — a whole catalog scan under a low-memory host

    @MainActor @Test("RED 2026-09-25: a catalog scan whose gate reads 'memory is always low' still finishes and catalogs")
    func scanUnderLowMemory_finishes() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: ToolLocator.ffprobePath),
                     "ffprobe is a required project dependency")
        var dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vs_lowmem_scan_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let canonical = try dir.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath {
            dir = URL(fileURLWithPath: canonical, isDirectory: true)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        // Junk-byte .mov: ffprobe fails, but extensioned damaged media is
        // still cataloged — discovery + the probe checkpoint are under test,
        // not decodability.
        let clip = dir.appendingPathComponent("test_lowmem_clip.mov").path
        try Data(repeating: 0, count: 64).write(to: URL(fileURLWithPath: clip))

        let model = VideoScanModel()
        var opts = ScanOptions()          // in-memory only — never .save()d
        opts.skipSmallFiles = false
        opts.skipChecksums = true
        model.scanOptions = opts
        model.scanTargets.removeAll()

        // The host "has" no free memory; the gate's policy is the default.
        let gate = PauseGate(pressureCheck: { true }, recheckInterval: .milliseconds(50))
        let target = CatalogScanTarget(searchPath: dir.path, pauseGate: gate)
        model.scanTargets.append(target)
        model.startTarget(target)

        // Watchdog: a stalled scan fails in 30 s instead of burning the
        // suite's time limit (and, pre-fix, the CI step's 60 minutes).
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let scanTask = target.scanTask
        let watchdog = Task {
            try await Task.sleep(for: .seconds(30))
            timedOut.withLock { $0 = true }
            scanTask?.cancel()
        }
        await ScanTaskAwait.value(of: target)
        watchdog.cancel()

        #expect(!timedOut.withLock { $0 },
                "the scan stalled on the memory auto-pause (pre-fix behavior on a low-memory host)")
        #expect(model.records.contains { $0.fullPath == clip },
                "the scan must reach ffprobe and catalog the file")
    }
}
