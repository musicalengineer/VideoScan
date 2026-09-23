// ArchiveAngelTestFixity.swift
// Test support: REAL whole-file fixity for Archive Angel fact-inheritance
// tests (codex #1659 — a digest lends only while a stat confirms it still
// describes the file, so fixtures use real files, real SHA-256 and real
// stat stamps; no fake stamps).

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@MainActor
enum AngelTestFixity {

    /// Hash `r`'s file in full and bind the digest to its current stamp.
    static func capture(_ r: VideoRecord) throws {
        let digest = try #require(try ArchivePromoteEngine.sha256(path: r.fullPath))
        let size = Int64((try FileManager.default.attributesOfItem(atPath: r.fullPath)[.size] as? NSNumber)?.int64Value ?? 0)
        r.sizeBytes = size
        r.contentFixity = try #require(ContentFixity.captured(path: r.fullPath, digest: digest, byteCount: size))
    }

    /// A byte-identical copy of `original`'s file named `name` in `dir`,
    /// catalogued, with REAL fixity on both.
    static func verifiedTwin(of original: VideoRecord, named name: String, in dir: URL) throws -> VideoRecord {
        let url = dir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.copyItem(atPath: original.fullPath, toPath: url.path)
        let twin = MasterArchiveTestSupport.makeRecord(path: url.path)
        twin.contentHash = original.contentHash
        twin.durationSeconds = original.durationSeconds
        try capture(original)
        try capture(twin)
        return twin
    }
}
