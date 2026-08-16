// MasterArchiveTestSupport.swift
// Shared fixtures for the Master Archive / Promote to Archive suites:
// an isolated temp "volume" holding the archive root, a record factory
// pointing at real on-disk files, and a helper that runs one Promote job
// to completion. Everything lives under the process temp dir — the real
// App Support catalog, UserDefaults and /Volumes are never touched.

import Foundation
@testable import VideoScan

enum MasterArchiveTestSupport {

    /// A fresh temp dir tree: `<tmp>/test_marchive_<label>_<8>/` with
    /// `Sources/` (files to promote) and `Archive/` (the target volume).
    struct Sandbox {
        let root: URL
        let sources: URL
        let archiveVolume: URL
        var archiveRoot: URL { MasterArchiveLayout.rootURL(forTargetPath: archiveVolume.path) }
        var manifestURL: URL { MasterArchiveLayout.manifestURL(rootPath: archiveRoot.path) }
        var journalURL: URL { ArchivePromoteJournal.url(rootPath: archiveRoot.path) }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    static func makeSandbox(_ label: String) throws -> Sandbox {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("test_marchive_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        let archive = root.appendingPathComponent("Archive", isDirectory: true)
        try fm.createDirectory(at: sources, withIntermediateDirectories: true)
        try fm.createDirectory(at: archive, withIntermediateDirectories: true)
        return Sandbox(root: root, sources: sources, archiveVolume: archive)
    }

    /// Write `bytes` of deterministic pseudo-random content (seeded) so
    /// two files with different seeds never collide and the sha256 is
    /// stable across runs.
    @discardableResult
    static func writeBlob(at url: URL, bytes: Int, seed: UInt64) throws -> URL {
        var state = seed &+ 0x9E3779B97F4A7C15
        var data = Data(capacity: bytes)
        for _ in 0..<bytes {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            data.append(UInt8(truncatingIfNeeded: state))
        }
        try data.write(to: url)
        return url
    }

    /// A catalog record for an on-disk file, shaped the way the promote
    /// path reads it (fullPath / sizeBytes / streamTypeRaw / ext / dates).
    @MainActor
    static func makeRecord(path: String,
                           streamType: StreamType = .videoAndAudio,
                           userDate: String? = nil,
                           inferredDate: Date? = nil,
                           inferredConfidence: Float? = nil,
                           starRating: Int = 0) -> VideoRecord {
        let r = VideoRecord()
        r.filename = (path as NSString).lastPathComponent
        r.fullPath = path
        r.directory = (path as NSString).deletingLastPathComponent
        r.ext = (path as NSString).pathExtension
        r.streamTypeRaw = streamType.rawValue
        r.userDate = userDate
        r.inferredRecordDate = inferredDate
        r.inferredDateConfidence = inferredConfidence
        r.starRating = starRating
        let attrs = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
        r.sizeBytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        return r
    }

    /// A model whose catalog store is ISOLATED in the sandbox (so
    /// `saveCatalogNow()` really writes and returns true — the journal can
    /// reach `done`) — never the shared App Support store.
    @MainActor
    static func makeModel(_ sandbox: Sandbox) -> VideoScanModel {
        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: sandbox.root.appendingPathComponent("catalog", isDirectory: true))
        return model
    }

    /// Initialize the sandbox's archive volume as the model's master and
    /// return the result.
    @MainActor
    @discardableResult
    static func initialize(_ model: VideoScanModel, in sandbox: Sandbox) throws -> VideoScanModel.MasterArchiveInitResult {
        try model.initializeMasterArchive(at: sandbox.archiveVolume)
    }

    /// Run ONE promote job for `ids` to completion; returns the job.
    @MainActor
    static func promote(_ model: VideoScanModel, ids: [UUID]) async -> PromoteToArchiveJob? {
        guard let plan = model.buildPromotePlan(recordIDs: ids) else { return nil }
        let job = PromoteToArchiveJob(plan: plan, model: model)
        job.start()
        await job.task?.value
        return job
    }

    /// Manifest data rows (header excluded), parsed into fields.
    static func manifestRows(_ sandbox: Sandbox) -> [[String]] {
        guard let text = try? String(contentsOf: sandbox.manifestURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").dropFirst().map { ArchiveManifestCSV.fields(ofLine: String($0)) }
    }

    /// Every regular file under the archive root, EXCLUDING 00_Index.
    static func archivedFiles(_ sandbox: Sandbox) -> [String] {
        let fm = FileManager.default
        guard let e = fm.enumerator(atPath: sandbox.archiveRoot.path) else { return [] }
        var out: [String] = []
        for case let rel as String in e {
            if rel.hasPrefix(MasterArchiveLayout.indexFolder) { continue }
            var isDir: ObjCBool = false
            let full = sandbox.archiveRoot.appendingPathComponent(rel).path
            if fm.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue { out.append(rel) }
        }
        return out.sorted()
    }

    static func sha256(ofFile path: String) -> String? {
        try? CatalogStore.sha256HexStreaming(fileURL: URL(fileURLWithPath: path))
    }
}
