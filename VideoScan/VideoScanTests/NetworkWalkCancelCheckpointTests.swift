// NetworkWalkCancelCheckpointTests.swift
// REGRESSION GH #164: a user cancel mid-walk on a NETWORK root saved a scan
// checkpoint from the PARTIAL walk, with walkHadEnumerationErrors = false.
// A later resume completes only that partial list and can finalize as
// complete — and a complete scan prunes records under the directories the
// cancelled walk never reached (the prune chain).
//
// Cause: runTargetProbeGroup's walk loop broke on Task.isCancelled without
// marking the walk aborted, and the stream's iterator also simply ends on a
// cancelled task; either way the post-walk checkpoint save ran.
//
// Red/green:
//   cancelledNetworkWalkSavesNoCheckpoint — RED before the fix (a checkpoint
//   exists for the root), GREEN after.
//   completedNetworkWalkStillSavesCheckpoint — green both sides (the fix must
//   not stop the honest post-walk checkpoint).

import Testing
import Foundation
@testable import VideoScan

@MainActor
@Suite("Network walk cancel — no partial checkpoint (GH #164)", .serialized, .scratchCleanup)
struct NetworkWalkCancelCheckpointTests {

    private static func makeTree(files: Int) throws -> URL {
        let dir = try TestScratch.unique("vs_netcancel_")
        for i in 0..<files {
            let sub = dir.appendingPathComponent("d\(i % 4)", isDirectory: true)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            try Data(repeating: 0xAB, count: 4096).write(to: sub.appendingPathComponent("clip\(i).mov"))
        }
        return dir
    }

    private static func model() -> VideoScanModel {
        let m = VideoScanModel()
        m.scanOptions.skipChecksums = true
        m.scanOptions.skipSmallFiles = false
        return m
    }

    @Test("a cancelled walk on a network root leaves no checkpoint behind")
    func cancelledNetworkWalkSavesNoCheckpoint() async throws {
        let dir = try Self.makeTree(files: 40)
        ScanCheckpointStorage.delete(for: dir.path)
        defer { ScanCheckpointStorage.delete(for: dir.path) }
        let model = Self.model()
        let target = CatalogScanTarget(searchPath: dir.path)
        await target.pauseGate.pause()   // no probe touches a file

        // The task is created and cancelled before it first runs (this test
        // holds the main actor until the await below), so the walk is
        // cancelled before it can finish — deterministic.
        let task = Task { () -> Int in
            let r = await model.runTargetProbeGroup(
                target: target, root: dir.path, volName: "NetVol",
                rootIsNetwork: true, ramMountPoint: nil)
            return r.discovered
        }
        task.cancel()
        await target.pauseGate.resume()
        let discovered = await task.value

        #expect(discovered < 40, "the walk was cancelled; it cannot have seen every file (saw \(discovered))")
        #expect(!ScanCheckpointStorage.exists(for: dir.path),
                "a cancelled walk saved a checkpoint of \(ScanCheckpointStorage.load(for: dir.path)?.totalDiscovered ?? -1) path(s) — a resume would treat a partial discovery as complete")
    }

    @Test("a completed walk on a network root still saves its post-walk checkpoint")
    func completedNetworkWalkStillSavesCheckpoint() async throws {
        let dir = try Self.makeTree(files: 6)
        ScanCheckpointStorage.delete(for: dir.path)
        defer { ScanCheckpointStorage.delete(for: dir.path) }
        let model = Self.model()
        let target = CatalogScanTarget(searchPath: dir.path)
        await target.pauseGate.pause()

        let task = Task { () -> Int in
            let r = await model.runTargetProbeGroup(
                target: target, root: dir.path, volName: "NetVol",
                rootIsNetwork: true, ramMountPoint: nil)
            return r.discovered
        }
        // The checkpoint is written right after the walk, before probing.
        for _ in 0..<600 where target.filesFound != 6 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let cp = ScanCheckpointStorage.load(for: dir.path)
        await target.pauseGate.resume()
        _ = await task.value

        let saved = try #require(cp, "a complete network walk must leave a resumable checkpoint")
        #expect(saved.totalDiscovered == 6)
        #expect(saved.walkHadEnumerationErrors == false)
    }
}
