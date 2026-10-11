// JunkTrashTestSupport.swift
// Shared fixtures for the Delete Junk streamline suites (2026-10-09):
// a temp sandbox, an isolated model (catalog store + ledger in the
// sandbox — never App Support), confirmed-junk records over tiny synthetic
// files, and a stand-in "Trash" — the routine's `remove` seam moves files
// into a sandbox folder so no test fills the real Trash.

import Foundation
import Testing
@testable import VideoScan

/// One test's sandbox. `cleanup()` removes it.
struct JunkTrashSandbox {
    let root: URL
    let files: URL
    let trash: SandboxTrash

    init(_ label: String) throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test_junktrash_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
        files = root.appendingPathComponent("files", isDirectory: true)
        let trashDir = root.appendingPathComponent("trash", isDirectory: true)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        trash = SandboxTrash(dir: trashDir)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    /// A model whose catalog store and ledger live in the sandbox.
    @MainActor
    func model() -> VideoScanModel {
        let m = VideoScanModel()
        m.catalogStore = CatalogStore(directory: root.appendingPathComponent("catalog", isDirectory: true))
        m.mediaLedger = MediaLedger(directory: root.appendingPathComponent("ledger", isDirectory: true))
        return m
    }

    /// A file of `bytes` synthetic bytes in the sandbox.
    @discardableResult
    func write(_ name: String, bytes: Int = 1_024, fill: UInt8 = 0x5A) throws -> URL {
        let url = files.appendingPathComponent(name)
        try Data(repeating: fill, count: bytes).write(to: url)
        return url
    }

    /// A Confirmed Junk record over the file at `url` (size from disk).
    @MainActor
    func junk(_ url: URL) -> VideoRecord {
        let r = VideoRecord()
        r.filename = url.lastPathComponent
        r.fullPath = url.path
        r.directory = url.deletingLastPathComponent().path
        r.ext = url.pathExtension
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        r.mediaDisposition = .confirmedJunk
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        r.sizeBytes = size ?? 0
        return r
    }
}

/// The sandbox "Trash": records each file it is handed and moves it into
/// the sandbox, never to the real Trash. Optionally throws instead.
/// (`@unchecked Sendable` + a lock ≈ a C++ class guarded by a std::mutex.)
final class SandboxTrash: @unchecked Sendable {
    let dir: URL
    private let lock = NSLock()
    private var handed: [String] = []
    private var failing: Error?

    init(dir: URL) { self.dir = dir }

    /// Every path handed to the file operation, in order.
    var attempts: [String] { lock.withLock { handed } }

    /// From now on, every hand-off throws `error` and moves nothing.
    func failEverything(with error: Error) { lock.withLock { failing = error } }

    /// The `remove` seam.
    var operation: @Sendable (URL) throws -> Void {
        { [self] url in try self.take(url) }
    }

    private func take(_ url: URL) throws {
        let failure: Error? = lock.withLock {
            handed.append(url.path)
            return failing
        }
        if let failure { throw failure }
        let dest = dir.appendingPathComponent("\(UUID().uuidString.prefix(8))_\(url.lastPathComponent)")
        try FileManager.default.moveItem(at: url, to: dest)
    }
}

/// A scan target for a temp folder (so it can be marked Read only).
@MainActor
func junkTrashScanTarget(_ path: String) -> CatalogScanTarget {
    let t = CatalogScanTarget(searchPath: path)
    t.role = .workspace
    t.isReachable = true
    return t
}
