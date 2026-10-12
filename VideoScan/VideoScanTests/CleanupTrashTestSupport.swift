// CleanupTrashTestSupport.swift
// Shared fixtures for the Triage ▸ Cleanup suites (2026-10-12):
//   - `CleanupTrashFixture`: pure-plan rows and disk facts, no files (the
//     logic and scale suites);
//   - `CleanupTrashSandbox`: a temp folder spelled by its REAL path (the
//     probe treats "/var/…" as a path through a link — it is one), an
//     isolated model (catalog store + ledger in the sandbox, keeper order by
//     folder), and records carrying a stored full SHA-256.
// The run suites move files through the real engine; under the test host
// `MediaTrash.move` lands them in a per-process scratch Trash, never Rick's.

import CryptoKit
import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

enum CleanupTrashFixture {

    /// Rick's seed order, short: FamilyArchive › LaCie › SanDisk. Unlisted
    /// /Volumes names all rank alike (they tie).
    static let policy = DuplicateKeeperPolicy(precedence: ["FamilyArchive", "LaCieWorkspace", "SanDiskWorkspace"])

    static func stamp(device: UInt64 = 7, inode: UInt64, size: Int64) -> FileIdentityStamp {
        FileIdentityStamp(device: device, inode: inode, size: size, mtimeNs: 1, ctimeNs: 2, volumeUUID: "ABCD")
    }

    static func row(_ path: String, size: Int64 = 1_000, digest: String? = "d1", junk: Bool = false,
                    archived: Bool = false, pair: Bool = false, setAside: Bool = false,
                    protection: CleanupProtection? = nil, marks: Int = 0, id: UUID = UUID()) -> CleanupRow {
        CleanupRow(id: id, path: path, filename: (path as NSString).lastPathComponent,
                   volumeName: DuplicateKeeperPolicy.volumeName(forPath: path) ?? "",
                   sizeBytes: size, fullDigest: digest, isJunk: junk, isArchived: archived, isPairHalf: pair,
                   isSetAside: setAside, protection: protection, humanMarks: marks)
    }

    /// The plan with explicit facts for some paths; every other path is a
    /// plain file with its own inode at the row's size.
    static func plan(_ rows: [CleanupRow], facts: [String: CleanupDiskFacts] = [:],
                     policy: DuplicateKeeperPolicy = policy) -> CleanupPlan {
        var auto: [String: CleanupDiskFacts] = [:]
        for (i, r) in rows.enumerated() where facts[r.path] == nil && auto[r.path] == nil {
            auto[r.path] = .file(stamp(inode: UInt64(10_000 + i), size: r.sizeBytes))
        }
        return CleanupPlanner.plan(rows: rows,
                                   facts: { facts[$0] ?? auto[$0] ?? .missing },
                                   rank: { policy.volumeRank(forPath: $0) })
    }

    static func reasons(_ plan: CleanupPlan) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: plan.leftAlone.map { ($0.key.key, $0.value.files) })
    }
}

/// One test's sandbox. `cleanup()` removes it.
struct CleanupTrashSandbox {
    let root: URL

    init(_ label: String) throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test_cleanuptrash_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: SourceTree.canonicalPath(tmp), isDirectory: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    /// A sub-folder (created).
    func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    func write(_ rel: String, _ data: Data) throws -> URL {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    /// A model whose catalog store and ledger live in the sandbox; the
    /// keeper order lists `keepFirst` folders (absolute path prefixes) best
    /// first, so files in one folder outrank another's.
    @MainActor
    func model(keepFirst: [String]) -> VideoScanModel {
        let m = VideoScanModel()
        m.catalogStore = CatalogStore(directory: root.appendingPathComponent("catalog", isDirectory: true))
        m.mediaLedger = MediaLedger(directory: root.appendingPathComponent("ledger", isDirectory: true))
        m.duplicateKeeperSettings.volumePrecedence = keepFirst.map { root.appendingPathComponent($0).path }
        return m
    }

    /// A catalog row over `url`, with its stored full SHA-256 (as Fill In
    /// Full Hashes leaves it) unless `digest` overrides it.
    @MainActor
    static func record(_ url: URL, digest: String? = nil, junk: Bool = false) throws -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = url.path
        r.filename = url.lastPathComponent
        r.directory = url.deletingLastPathComponent().path
        r.ext = url.pathExtension
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        let data = try Data(contentsOf: url)
        r.sizeBytes = Int64(data.count)
        let stamp = try #require(FileIdentityStamp.capture(path: url.path))
        r.contentFixity = ContentFixity(digest: digest ?? sha256(data), byteCount: Int64(data.count), stamp: stamp)
        if junk { r.mediaDisposition = .confirmedJunk }
        return r
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(path: String) -> String? {
        FileManager.default.contents(atPath: path).map(sha256)
    }
}

/// Run one Cleanup job to its end over `selection` (no MFO centre; the
/// acknowledged save is a seam that answers yes).
@MainActor
func runCleanupTrash(_ model: VideoScanModel, _ selection: CleanupSelection,
                     configure: (CleanupTrashJob) -> Void = { _ in }) async -> CleanupTrashJob {
    let job = CleanupTrashJob(model: model, selection: selection)
    job.saveCatalogForTesting = { true }
    configure(job)
    job.start()
    await job.task?.value
    return job
}
