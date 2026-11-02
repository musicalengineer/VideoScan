// CatalogTrashPairGroupFixtures.swift
// Shared fixtures for the recovered A/V pair suites of Delete Selected
// Files (CatalogTrashPairGroup*Tests): rows, pairing, the pure plan with
// stubbed identity, a sandboxed disk + model, real files, and the console
// reader. (A protocol with default methods ≈ a C++ mixin base class.)

import CryptoKit
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

/// A sandboxed archive + model for one test.
struct PairGroupDisk {
    let sb: MasterArchiveTestSupport.Sandbox
    let model: VideoScanModel
}

/// A non-Sendable reference handed into the @Sendable seams. (≈ a C++
/// raw pointer the test promises to touch only on the main thread.)
final class PairGroupRef<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }

@MainActor
protocol PairGroupFixtures {}

@MainActor
extension PairGroupFixtures {
    typealias Disk = PairGroupDisk
    typealias Ref<T> = PairGroupRef<T>

    static var stubID: PairHalfIdentity { PairHalfIdentity(device: 1, inode: 1, size: 1, mtimeNs: 1) }

    func rec(_ path: String, _ stream: StreamType = .videoAndAudio) -> VideoRecord {
        let r = VideoRecord()
        r.filename = (path as NSString).lastPathComponent
        r.fullPath = path
        r.directory = (path as NSString).deletingLastPathComponent
        r.ext = (path as NSString).pathExtension
        r.streamTypeRaw = stream.rawValue
        r.sizeBytes = 1_000
        return r
    }

    /// Link `halves` as one group the way the correlator does (first ↔ second).
    @discardableResult
    func pair(_ halves: VideoRecord...) -> UUID {
        let gid = UUID()
        for h in halves { h.pairGroupID = gid }
        if halves.count == 2 { halves[0].pairedWith = halves[1]; halves[1].pairedWith = halves[0] }
        return gid
    }

    func plan(_ sel: [VideoRecord], catalog: [VideoRecord],
              archive: Set<UUID> = [], offline: Set<UUID> = [],
              unreadable: Set<UUID> = []) -> VideoScanModel.CatalogTrashPlan {
        VideoScanModel.catalogTrashPlan(
            for: sel, catalog: catalog,
            isMasterArchive: { archive.contains($0.id) }, isOffline: { offline.contains($0.id) },
            identity: { unreadable.contains($0.id) ? nil : Self.stubID })
    }

    func disk(_ label: String, archive: Bool = false) throws -> Disk {
        let sb = try MasterArchiveTestSupport.makeSandbox(label)
        let model = MasterArchiveTestSupport.makeModel(sb)
        model.mediaLedger = MediaLedger(directory: sb.root.appendingPathComponent("ledger", isDirectory: true))
        if archive { try MasterArchiveTestSupport.initialize(model, in: sb) }
        return Disk(sb: sb, model: model)
    }

    func file(_ d: Disk, _ name: String, seed: UInt64, _ stream: StreamType, in dir: URL? = nil) throws -> VideoRecord {
        let url = try MasterArchiveTestSupport.writeBlob(at: (dir ?? d.sb.sources).appendingPathComponent(name), bytes: 1024, seed: seed)
        return MasterArchiveTestSupport.makeRecord(path: url.path, streamType: stream)
    }

    func exists(_ r: VideoRecord) -> Bool { FileManager.default.fileExists(atPath: r.fullPath) }

    func consoleLine(_ model: VideoScanModel, containing s: String) async -> String? {
        for _ in 0..<200 {
            if let line = model.dashboard.consoleLines.first(where: { $0.contains(s) }) { return line }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    /// A half with a known copy elsewhere, its row carrying a whole-file
    /// SHA-256 fixity stamped from the file (the only-copy gate's identity).
    func fileWithFixity(_ d: Disk, _ name: String, bytes: Data, _ stream: StreamType) throws -> VideoRecord {
        let url = d.sb.sources.appendingPathComponent(name)
        try bytes.write(to: url)
        let r = MasterArchiveTestSupport.makeRecord(path: url.path, streamType: stream)
        r.sizeBytes = Int64(bytes.count)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        r.contentFixity = ContentFixity.captured(path: url.path, digest: digest, byteCount: Int64(bytes.count))
        return r
    }

    static func sha256(_ path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
