// AtomicFilePublishSensorTests.swift
//
// Regression sensor for the P0 of 2026-09-14: VideoScan processes wedging
// unkillably at exit on a Sandbox.kext rename lock. It cost Rick a live demo
// and three reboots.
//
// Root cause, proven that day on two machines and reproduced from scratch in
// plain unsandboxed Python:
//
//   FileManager.replaceItemAt(_:withItemAt:) is renameatx_np(… RENAME_SWAP)
//   on APFS. Sandbox.kext's hook_vnode_notify_will_rename_swap takes an
//   IORWLock exclusively and holds it across the VFS rename; that thread then
//   sleeps on a vnode whose iocount is owned by a second thread parked in the
//   same hook. ABBA deadlock in the kernel. The threads never return, so the
//   process becomes an unkillable `?E` zombie, the rwlock is never released,
//   and only a reboot clears it.
//
//   TWO threads and 26 swaps of one path pair are enough. Disjoint paths are
//   fine; plain rename(2) on the same destination is fine (32,000 ops, 12.7s).
//   So the trigger is two concurrent rename-SWAPS onto ONE destination —
//   precisely what an atomic-save store does when two saves race.
//
// Evidence, spindumps, symbolicated kernel stacks and the three repro arms:
//   docs/incident_2026_09_14_sandbox_rename_wedge.md
//
// This sensor is deliberately a SOURCE sensor, not a behavioural one. A test
// that actually provoked the deadlock would wedge the test host and cost
// another reboot — there is no way to assert on this bug at runtime and live.
// So instead we pin the only thing that matters: RENAME_SWAP must not come
// back into production code.

import Testing
import Foundation
import VideoScanCore

@Suite
struct AtomicFilePublishSensorTests {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // VideoScanTests
            .deletingLastPathComponent()   // VideoScan
            .deletingLastPathComponent()   // repo root
    }

    /// Every production Swift file — the app target and VideoScanCore.
    /// Tests are excluded: a test may legitimately name the syscall in a
    /// comment, and this file certainly does.
    private func productionSources() throws -> [(String, String)] {
        let fm = FileManager.default
        var out: [(String, String)] = []
        for sub in ["VideoScan/VideoScan", "VideoScan/VideoScanCore/Sources"] {
            let root = repoRoot.appendingPathComponent(sub)
            guard let walk = fm.enumerator(at: root,
                                           includingPropertiesForKeys: nil,
                                           options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walk where url.pathExtension == "swift" {
                let rel = url.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
                out.append((rel, try String(contentsOf: url, encoding: .utf8)))
            }
        }
        return out
    }

    // MARK: - 1. The syscall must not come back

    @Test func productionCodeNeverCallsReplaceItemAt() throws {
        let sources = try productionSources()
        #expect(!sources.isEmpty, "the sensor must actually be reading sources")

        var offenders: [String] = []
        for (rel, text) in sources {
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.contains("replaceItemAt(") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                offenders.append("\(rel):\(n + 1)")
            }
        }
        #expect(offenders.isEmpty, """
            FileManager.replaceItemAt is RENAME_SWAP on APFS and deadlocks \
            inside Sandbox.kext when two saves race onto one destination — \
            an unkillable process that only a reboot clears (P0, 2026-09-14). \
            Use AtomicFilePublish.replaceItem(at:withItemAt:) instead. \
            Offending call sites: \(offenders.joined(separator: ", "))
            """)
    }

    @Test func productionCodeNeverRequestsRenameSwap() throws {
        var offenders: [String] = []
        for (rel, text) in try productionSources() {
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.contains("RENAME_SWAP") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
                    && !rel.hasSuffix("AtomicFilePublish.swift") {
                offenders.append("\(rel):\(n + 1)")
            }
        }
        #expect(offenders.isEmpty, """
            RENAME_SWAP deadlocks in Sandbox.kext under concurrent saves to one \
            path (P0, 2026-09-14). Offenders: \(offenders.joined(separator: ", "))
            """)
    }

    // MARK: - 2. The replacement actually does what the stores need

    @Test func replaceItemPublishesOverAnExistingFile() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("atomic-publish-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let dest = dir.appendingPathComponent("store.json")
        try Data("old".utf8).write(to: dest)
        let tmp = dir.appendingPathComponent(".store.json.tmp")
        try Data("new".utf8).write(to: tmp)

        try AtomicFilePublish.replaceItem(at: dest, withItemAt: tmp)

        #expect(try String(contentsOf: dest, encoding: .utf8) == "new")
        #expect(!FileManager.default.fileExists(atPath: tmp.path), "the temp is consumed")
    }

    @Test func replaceItemCreatesAFreshDestination() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("atomic-publish-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let dest = dir.appendingPathComponent("store.json")
        let tmp = dir.appendingPathComponent(".store.json.tmp")
        try Data("first".utf8).write(to: tmp)

        try AtomicFilePublish.replaceItem(at: dest, withItemAt: tmp)
        #expect(try String(contentsOf: dest, encoding: .utf8) == "first")
    }

    @Test func replaceItemReportsFailureWithErrno() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("atomic-publish-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Source does not exist ⇒ ENOENT, surfaced rather than swallowed.
        #expect(throws: AtomicFilePublish.Failure.self) {
            try AtomicFilePublish.replaceItem(
                at: dir.appendingPathComponent("dest"),
                withItemAt: dir.appendingPathComponent("missing"))
        }
    }

    /// The condition that wedges the kernel is two concurrent publishes to ONE
    /// destination. With rename(2) that is safe, and this asserts it stays
    /// safe: every publish either wins or loses, none corrupt, none hang.
    @Test func concurrentPublishesToOneDestinationAllSucceed() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("atomic-publish-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("store.json")

        await withTaskGroup(of: Void.self) { group in
            for writer in 0..<8 {
                group.addTask {
                    for i in 0..<250 {
                        let tmp = dir.appendingPathComponent(".store.\(writer)-\(i).tmp")
                        try? Data("w\(writer)".utf8).write(to: tmp)
                        try? AtomicFilePublish.replaceItem(at: dest, withItemAt: tmp)
                    }
                }
            }
        }

        let final = try String(contentsOf: dest, encoding: .utf8)
        #expect(final.hasPrefix("w"), "the destination holds one writer's whole payload, never a shred")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty, "every temp was consumed by its rename")
    }
}
