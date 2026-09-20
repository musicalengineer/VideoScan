// AppSupportSnapshotTestSupport.swift
// The ISOLATION snapshot the settings-pollution tests take of the REAL
// ~/Library/Application Support/VideoScan tree (CleanupIsolationTests,
// VerifyAudioSchemaTests): rel-path → "size@mtime" for every product
// file. Shared here so both suites watch the same thing, with the
// exclusions spelled as exact FIRST PATH COMPONENTS (codex review
// 2026-09-20): `hasPrefix("team-channel")` would also have hidden a
// product folder that merely started with those letters.
//
// Excluded — written by OTHER processes at any moment, never by the app
// under test: the team-channel mailbox (codex, hooks; nightly 2026-09-20
// failed on team-channel/team-channel.sqlite3-shm alone, codex #1585),
// the channel watcher, the gh-codex relay.
//
// Positive controls live below: the snapshot MUST see a product file
// created, changed and deleted, and MUST see a folder whose name only
// starts like an excluded one — otherwise an isolation test that never
// fails is proving nothing.

import Foundation
import Testing
@testable import VideoScan

enum AppSupportSnapshot {
    /// Top-level folders other processes write; matched as whole
    /// components, never as string prefixes.
    static let excludedTopLevel: Set<String> = ["team-channel", "channel-watcher", "gh-codex"]

    static var realVideoScanRoot: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("VideoScan", isDirectory: true)
    }

    /// True when `rel` (a path relative to the tree root) belongs to an
    /// excluded top-level folder — its first component, exactly.
    static func isExcluded(_ rel: String) -> Bool {
        let first = rel.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? rel
        return excludedTopLevel.contains(first)
    }

    /// rel-path → "size@mtime" for everything under `root` that is not
    /// excluded (empty when the root is absent — also a valid state).
    static func take(root: URL? = realVideoScanRoot) -> [String: String] {
        guard let root, let e = FileManager.default.enumerator(atPath: root.path) else { return [:] }
        var snap: [String: String] = [:]
        for case let rel as String in e {
            if isExcluded(rel) { continue }
            let full = root.appendingPathComponent(rel).path
            let attrs = (try? FileManager.default.attributesOfItem(atPath: full)) ?? [:]
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? -1
            let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
            snap[rel] = "\(size)@\(mtime)"
        }
        return snap
    }
}

@Suite("Isolation snapshot — positive controls and the test-host pins", .serialized)
struct AppSupportSnapshotTests {

    private func scratch(_ tag: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_appsupport_snapshot_\(tag)_\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("POSITIVE CONTROL: a product file created, changed and deleted IS seen by the snapshot")
    func snapshotSeesCreateChangeDelete() throws {
        let root = try scratch("controls")
        defer { try? FileManager.default.removeItem(at: root) }
        let before = AppSupportSnapshot.take(root: root)
        #expect(before.isEmpty)

        // Created.
        let file = root.appendingPathComponent("archive-angel/evidence.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("one".utf8).write(to: file)
        let created = AppSupportSnapshot.take(root: root)
        #expect(created != before && created["archive-angel/evidence.json"] != nil, "\(created)")

        // Changed (a size change — mtime resolution is not relied on).
        try Data("one two".utf8).write(to: file)
        let changed = AppSupportSnapshot.take(root: root)
        #expect(changed["archive-angel/evidence.json"] != created["archive-angel/evidence.json"], "a changed file must read differently")

        // Deleted.
        try FileManager.default.removeItem(at: file)
        let deleted = AppSupportSnapshot.take(root: root)
        #expect(deleted["archive-angel/evidence.json"] == nil && deleted != changed)
    }

    @Test("exclusions are whole top-level components: team-channel/… is skipped, team-channel-ish/… and x/team-channel are seen")
    func exclusionsAreExactComponents() throws {
        let root = try scratch("exact")
        defer { try? FileManager.default.removeItem(at: root) }
        for rel in ["team-channel/team-channel.sqlite3-shm", "channel-watcher/state.json", "gh-codex/relay.log",
                    "team-channel-ish/product.json", "team-channelX", "catalog/team-channel/inside.json", "catalog.json"] {
            let url = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        let snap = AppSupportSnapshot.take(root: root)
        #expect(snap["team-channel/team-channel.sqlite3-shm"] == nil && snap["team-channel"] == nil)
        #expect(snap["channel-watcher/state.json"] == nil && snap["gh-codex/relay.log"] == nil)
        #expect(snap["team-channel-ish/product.json"] != nil, "a lookalike product folder is watched")
        #expect(snap["team-channelX"] != nil)
        #expect(snap["catalog/team-channel/inside.json"] != nil, "only the FIRST component is matched")
        #expect(snap["catalog.json"] != nil)
        #expect(AppSupportSnapshot.isExcluded("team-channel") && AppSupportSnapshot.isExcluded("team-channel/x/y"))
        #expect(!AppSupportSnapshot.isExcluded("team-channels") && !AppSupportSnapshot.isExcluded("a/team-channel"))
    }

    @Test("the test host's Angel evidence store and buffer root are pinned under temp — never Application Support or the real buffer")
    @MainActor
    func evidenceStoreAndBufferArePinnedUnderTemp() throws {
        #expect(TestEnvironment.isTestHost, "test host detection broke — every default path below would be Rick's")
        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL.resolvingSymlinksInPath().path
        let evidence = ArchiveAngelEvidenceStore.defaultDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        #expect(evidence.hasPrefix(temp), "evidence store default: \(evidence)")
        #expect(evidence.contains("archive-angel-\(ProcessInfo.processInfo.processIdentifier)"), "one folder per test process: \(evidence)")
        #expect(!evidence.contains("/Library/Application Support/"))
        if let real = AppSupportSnapshot.realVideoScanRoot {
            #expect(!evidence.hasPrefix(real.standardizedFileURL.resolvingSymlinksInPath().path))
        }
        // And the store built with no argument really lands there.
        #expect(ArchiveAngelEvidenceStore().directory.path == ArchiveAngelEvidenceStore.defaultDirectory.path)
        let buffer = ArchiveAngelPlanStore.defaultBufferRoot.standardizedFileURL.resolvingSymlinksInPath().path
        #expect(buffer.hasPrefix(temp) && !buffer.contains("/Movies/VideoScan Buffer"), "buffer root default: \(buffer)")
    }
}
