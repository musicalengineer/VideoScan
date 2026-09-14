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
        // A source sensor that reads nothing passes forever. VideoScan has
        // several hundred production Swift files; if this ever drops to a
        // handful the path logic has broken, not the codebase.
        #expect(sources.count > 150,
                "the sensor must actually be reading sources — saw \(sources.count)")

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

    // MARK: - 1b. The PATTERN must not drift back either

    /// The syscall sensor above is necessary but not sufficient. The two
    /// torn-file bugs found on 2026-09-14 (`.plan.json.tmp` and
    /// `.evidence.json.tmp`, both fixed temp names) existed because the
    /// write-temp-then-publish pattern had been copy-pasted into seven call
    /// sites with five different conventions. Pin the single entry point.
    @Test func sidecarStoresPublishThroughTheWrapper() throws {
        let stores = [
            "VideoScan/VideoScan/ArchiveAngelPlan.swift",
            "VideoScan/VideoScan/ArchiveAngelEvidenceStore.swift",
            "VideoScan/VideoScan/IgnoredContentStore.swift",
            "VideoScan/VideoScan/HoldoutClearStore.swift",
            "VideoScan/VideoScan/ResearchStore.swift",
            "VideoScan/VideoScanCore/Sources/VideoScanCore/PreviewDiskCache.swift",
        ]
        var missing: [String] = []
        for rel in stores {
            let text = try String(contentsOf: repoRoot.appendingPathComponent(rel),
                                  encoding: .utf8)
            // Either entry point counts — writeJSON(_:to:) funnels into
            // write(_:to:). Matching only "write(" would fail a store that
            // legitimately uses the JSON form.
            let routed = text.contains("AtomicFilePublish.write(")
                || text.contains("AtomicFilePublish.writeJSON(")
            if !routed { missing.append(rel) }
        }
        #expect(missing.isEmpty, """
            These stores publish files and must do it through \
            AtomicFilePublish.write(_:to:), which owns the unique temp name, \
            the rename(2), the cleanup and the stall logging. Hand-rolling it \
            is how the fixed-temp-name bugs got in. Missing: \
            \(missing.joined(separator: ", "))
            """)
    }

    /// Bare `rename(2)` is SAFE for the wedge — 32,000 contended renames onto
    /// one destination completed clean on 2026-09-14. This sensor is therefore
    /// about keeping the *publishing pattern* in one place, not about safety,
    /// and it is an EXACT-SET assertion: a new bare `rename(` anywhere fails
    /// here until someone justifies it below, and a file that stops calling
    /// rename fails too, so the list cannot rot.
    ///
    /// `renamex_np` / `renameatx_np` with RENAME_EXCL are a different, safe
    /// call and are deliberately not matched.
    @Test func onlyKnownSitesCallRenameDirectly() throws {
        /// Each of these publishes a file that is ALREADY ON DISK, which is
        /// not what AtomicFilePublish.write(_:to:) models (it takes Data).
        /// Converting them to AtomicFilePublish.replaceItem is worth doing,
        /// but not in the same change as a P0 fix — they are recently
        /// hardened paths. Tracked as follow-up in the incident doc.
        let justified: Set<String> = [
            // the wrapper itself
            "VideoScan/VideoScanCore/Sources/VideoScanCore/AtomicFilePublish.swift",
            // publishes a resumed .partial media copy (82f92b46, crash-safe rescue)
            "VideoScan/VideoScan/RescueFileCopier.swift",
            // rebases a symlink atomically (People #3, codex review 2026-09-13)
            "VideoScan/VideoScan/POIStorage.swift",
            // publishes a validated CyberBrain archive
            "VideoScan/VideoScanCore/Sources/VideoScanCore/CyberBrainWriter.swift",
        ]

        var found: Set<String> = []
        for (rel, text) in try productionSources() {
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//") else { continue }
                // Strip string literals first — "rename(2) failed: ..." in a
                // diagnostic message is not a call. (This sensor's own first
                // run flagged exactly that, POIStorage.swift:835.)
                let code = String(trimmed).replacingOccurrences(
                    of: "\"[^\"]*\"", with: "", options: .regularExpression)
                if code.range(of: "(^|[^A-Za-z_])rename\\(",
                              options: .regularExpression) != nil {
                    found.insert(rel)
                }
            }
        }

        #expect(found == justified, """
            Publishing a file belongs in AtomicFilePublish so the temp name, \
            cleanup and stall logging stay in one place. \
            New/unjustified: \(found.subtracting(justified).sorted().joined(separator: ", ")). \
            Listed but no longer calling rename: \
            \(justified.subtracting(found).sorted().joined(separator: ", ")).
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

    // MARK: - 3. The wrapper's own safeguards

    @Test func writeCreatesMissingDirectories() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("atomic-publish-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("nested/deeper/store.json")

        try AtomicFilePublish.write(Data("hello".utf8), to: dest)
        #expect(try String(contentsOf: dest, encoding: .utf8) == "hello")
    }

    @Test func writeLeavesNoTempBehindOnSuccess() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("atomic-publish-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        for i in 0..<20 {
            try AtomicFilePublish.write(Data("v\(i)".utf8),
                                        to: dir.appendingPathComponent("store.json"))
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names == ["store.json"], "exactly the published file, no temps: \(names)")
    }

    @Test func writeLeavesNoTempBehindOnFailure() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("atomic-publish-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Publishing ONTO an existing directory fails at the rename (EISDIR).
        let dest = dir.appendingPathComponent("occupied")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: dest.appendingPathComponent("child"), withIntermediateDirectories: true)

        #expect(throws: (any Error).self) {
            try AtomicFilePublish.write(Data("boom".utf8), to: dest)
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty, "a failed publish must not litter: \(leftovers)")
    }

    @Test func writeJSONRoundTrips() throws {
        struct Payload: Codable, Equatable { let name: String; let count: Int }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("atomic-publish-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("payload.json")

        let value = Payload(name: "Donna", count: 3)
        try AtomicFilePublish.writeJSON(value, to: dest)
        let back = try JSONDecoder().decode(Payload.self, from: Data(contentsOf: dest))
        #expect(back == value)
    }

    /// The forensics hook. A non-empty in-flight list at process exit is the
    /// signature of the 2026-09-14 wedge, so it must be accurate and must
    /// drain.
    @Test func inFlightIsEmptyWhenIdleAndDrainsAfterPublishing() async throws {
        #expect(AtomicFilePublish.inFlightSummary() == nil, "idle before")

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("atomic-publish-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        await withTaskGroup(of: Void.self) { group in
            for w in 0..<8 {
                group.addTask {
                    for i in 0..<100 {
                        try? AtomicFilePublish.write(
                            Data("w\(w)-\(i)".utf8),
                            to: dir.appendingPathComponent("shared.json"))
                    }
                }
            }
        }

        #expect(AtomicFilePublish.inFlight().isEmpty,
                "every publish must deregister: \(AtomicFilePublish.inFlightSummary() ?? "-")")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty, "no temps survive 800 racing publishes")
    }
}
