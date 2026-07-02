// ScanLifecycleGuardTests.swift
// Regression suite for the double-start hazard (QA 2026-07-02, fix/qa-minors):
// startTarget had no status.isActive guard, so a programmatic double-start of
// the SAME target spawned two scanTasks whose completion merges could
// interleave at commitScanResults' single await. QA traced the interleave as
// safe-by-construction except a narrow TOCTOU; the systemic fix is refusing
// the double-start at the door. Same hazard existed in resumeTarget.
//
// Red/green: both tests FAIL before the guard —
//   - secondStartOfActiveTargetIsNoOp: the second startTarget deletes the
//     in-flight checkpoint and re-snapshots the preserved-fields map
//     (clobbering the sentinel) before spawning a second scanTask.
//   - resumeOfActiveTargetIsNoOp: the second resumeTarget re-snapshots the
//     map and resets filesFound from the checkpoint.
// Both PASS after: an active target refuses a second start/resume with no
// side effects (checkpoint intact, snapshot map untouched, progress
// counters untouched).
//
// Determinism note: startTarget/resumeTarget only SPAWN the scan Task; on
// the main actor that task cannot begin running until the test suspends.
// Every assertion below sits between two synchronous calls (no awaits), so
// the running scan never races the fixture. Cleanup stops the target and
// awaits the task like ScanMergeScopeTests test 16.

import Testing
import Foundation
@testable import VideoScan

/// Model with a deterministic in-memory scan policy — same rationale as
/// ScanMergeScopeTests.makePipelineModel: never read the developer's live
/// UserDefaults, never call ScanOptions.save() (settings-pollution class).
@MainActor
private func makeGuardTestModel() -> VideoScanModel {
    let model = VideoScanModel()
    var opts = ScanOptions()
    opts.skipSmallFiles = false
    opts.skipChecksums = true
    opts.probeExtensionless = false
    model.scanOptions = opts
    return model
}

private func makeTempDir(_ label: String) throws -> URL {
    var dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("vs_lifecycleguard_\(label)_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    if let canonical = try dir.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath {
        dir = URL(fileURLWithPath: canonical, isDirectory: true)
    }
    return dir
}

/// A preserved-fields sentinel: a map entry a re-snapshot could never
/// produce (the key is not a real record path), so its survival proves the
/// second start did NOT call snapshotPreservedFieldsForRescan again.
@MainActor
private func makeSentinelSnapshot() -> [String: RescanPreservedFields] {
    let rec = VideoRecord()
    rec.fullPath = "/SENTINEL/never-a-real-path.mov"
    rec.notes = "sentinel"   // isWorthRestoring, for realism
    return [rec.fullPath: RescanPreservedFields(from: rec)]
}

@Suite("Scan lifecycle — double-start / double-resume guard")
struct ScanLifecycleGuardTests {

    // MARK: - 1. startTarget while the target is already active is a no-op

    @Test @MainActor
    func secondStartOfActiveTargetIsNoOp() async throws {
        let dir = try makeTempDir("start")
        defer { try? FileManager.default.removeItem(at: dir) }

        let model = makeGuardTestModel()
        let target = CatalogScanTarget(searchPath: dir.path)
        model.scanTargets = [target]

        model.startTarget(target)
        let task = target.scanTask
        defer {
            model.stopTarget(target)
            ScanCheckpointStorage.delete(for: dir.path)
        }
        #expect(target.status == .scanning, "Fixture sanity: first start must be running")

        // Simulate the running scan's in-flight state: a checkpoint on disk
        // (the probe loop writes these periodically) and a preserved-fields
        // snapshot the completion merge will consume. A second start must
        // touch NEITHER.
        ScanCheckpointStorage.save(ScanCheckpoint(
            volumePath: dir.path,
            startedAt: Date(),
            discoveredPaths: [dir.appendingPathComponent("clip.mov").path],
            totalDiscovered: 1,
            skipChecksums: true))
        model.pendingPreservedFields[dir.path] = makeSentinelSnapshot()
        target.filesScanned = 42   // in-flight progress a restart would zero

        model.startTarget(target)   // must refuse: target is already active

        #expect(ScanCheckpointStorage.load(for: dir.path) != nil,
                "Double-start must NOT delete the in-flight checkpoint (RED pre-guard: startTarget deletes it unconditionally)")
        #expect(model.pendingPreservedFields[dir.path]?["/SENTINEL/never-a-real-path.mov"] != nil,
                "Double-start must NOT re-snapshot the preserved-fields map (RED pre-guard: the sentinel is clobbered)")
        #expect(target.filesScanned == 42,
                "Double-start must not reset in-flight progress counters")
        #expect(target.status == .scanning)

        _ = await task?.value   // drain the (single) scan task
    }

    // MARK: - 2. resumeTarget while the target is already active is a no-op

    @Test @MainActor
    func resumeOfActiveTargetIsNoOp() async throws {
        let dir = try makeTempDir("resume")
        defer { try? FileManager.default.removeItem(at: dir) }

        let model = makeGuardTestModel()
        let target = CatalogScanTarget(searchPath: dir.path)
        model.scanTargets = [target]

        // Start AFTER any stale checkpoint would have been cleared, then
        // plant a checkpoint so a pre-guard resume takes the real resume
        // path (snapshot + filesFound reset + second task) rather than
        // falling through to startTarget.
        model.startTarget(target)
        let task = target.scanTask
        defer {
            model.stopTarget(target)
            ScanCheckpointStorage.delete(for: dir.path)
        }
        #expect(target.status == .scanning, "Fixture sanity: first start must be running")

        ScanCheckpointStorage.save(ScanCheckpoint(
            volumePath: dir.path,
            startedAt: Date(),
            discoveredPaths: [dir.appendingPathComponent("clip.mov").path],
            totalDiscovered: 7,
            skipChecksums: true))
        model.pendingPreservedFields[dir.path] = makeSentinelSnapshot()
        target.filesFound = 123   // in-flight progress a resume would clobber

        model.resumeTarget(target)   // must refuse: target is already active

        #expect(model.pendingPreservedFields[dir.path]?["/SENTINEL/never-a-real-path.mov"] != nil,
                "Resume of an active target must NOT re-snapshot the preserved-fields map (RED pre-guard)")
        #expect(target.filesFound == 123,
                "Resume of an active target must not reset filesFound from the checkpoint (RED pre-guard: becomes 7)")
        #expect(target.status == .scanning)

        _ = await task?.value   // drain the (single) scan task
    }
}
