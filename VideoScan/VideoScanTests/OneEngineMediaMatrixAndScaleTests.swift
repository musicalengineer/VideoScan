// OneEngineMediaMatrixAndScaleTests.swift
// GH #143 (folds in #241): the one Trash engine and the one removal marker
// over the five-format media matrix, and at catalog scale.
//
//   - MEDIA MATRIX: real ffmpeg, synthetic `test_*` fixtures in a temp dir
//     (never family media) — mp4/h264, mov/prores, mkv/ffv1+pcm,
//     mxf/mpeg2+pcm, avi/dv. For each format, Delete Duplicates proves the
//     copy byte for byte and moves it to the (test-host) Trash, and ⌘⌫ moves
//     another copy to a sandbox Trash. Both rows STAY, marked In the Trash
//     with the Trash path, and the bytes there are the original's (full
//     SHA-256) — the engine moves bytes, it never rewrites them.
//   - SCALE: 100k records — Remove from Catalog of 10k rows, Restore, and
//     the "Trash emptied" stat pass over 100k rows (10k In the Trash) — each
//     under a time budget, rows never deleted.

import CryptoKit
import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("One engine — media matrix and scale (GH #143, #241)", .serialized)
@MainActor
struct OneEngineMediaMatrixAndScaleTests {

    private static func sha256(_ path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func record(_ url: URL) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = url.path
        r.filename = url.lastPathComponent
        r.directory = url.deletingLastPathComponent().path
        r.ext = url.pathExtension
        r.sizeBytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        r.partialMD5 = "m"
        r.durationSeconds = 2.0
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        return r
    }

    /// One format through both doors.
    private func runMatrix(ext: String, videoCodec: String, extraVideoArgs: [String] = [],
                           audioCodec: String = "pcm_s16le", size: String = "320x240",
                           rate: String = "25") async throws {
        try #require(VerifyVideoTestMedia.toolsAvailable)
        let dir = try VerifyVideoTestMedia.makeScratchDir("oneengine_\(ext)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try VerifyVideoTestMedia.generate(into: dir, name: "test_om_master.\(ext)", videoCodec: videoCodec,
                                                       extraVideoArgs: extraVideoArgs, audioCodec: audioCodec,
                                                       size: size, rate: rate)
        let digest = try #require(Self.sha256(source))
        let extraURL = dir.appendingPathComponent("test_om_extra.\(ext)")
        let selectedURL = dir.appendingPathComponent("test_om_selected.\(ext)")
        try FileManager.default.copyItem(atPath: source, toPath: extraURL.path)
        try FileManager.default.copyItem(atPath: source, toPath: selectedURL.path)

        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: dir.appendingPathComponent("catalog", isDirectory: true))
        model.mediaLedger = MediaLedger(directory: dir.appendingPathComponent("ledger", isDirectory: true))
        let group = UUID()
        let keeper = record(URL(fileURLWithPath: source))
        keeper.duplicateGroupID = group; keeper.duplicateDisposition = .keep; keeper.duplicateConfidence = .high
        let extra = record(extraURL)
        extra.duplicateGroupID = group; extra.duplicateDisposition = .extraCopy; extra.duplicateConfidence = .high
        let selected = record(selectedURL)
        model.records = [keeper, extra, selected]
        _ = addVerifiedArchiveFamily(to: model, keeper: keeper)

        // Delete Duplicates: proved byte for byte, to the Trash, row kept.
        let dd = await model.deleteDuplicates(onVolume: dir.path)
        #expect(dd.deleted == 1, "\(ext): \(dd)")
        #expect(!FileManager.default.fileExists(atPath: extraURL.path))
        #expect(model.records.contains { $0 === extra })
        #expect(extra.removal?.state == .inTrash && extra.removal?.reason == .duplicate, "\(ext): \(String(describing: extra.removal))")
        let ddTrash = try #require(extra.removal?.trashPath, "\(ext): the Trash path is on the marker")
        #expect(Self.sha256(ddTrash) == digest, "\(ext): the Trash holds the original bytes")
        try? FileManager.default.removeItem(atPath: ddTrash)   // the test host's Trash, not Rick's

        // ⌘⌫: to a sandbox Trash, row kept.
        let trashDir = dir.appendingPathComponent("trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        let sandbox = SandboxTrash(dir: trashDir)
        let cat = await model.trashSelectedRecords([selected], confirmed: model.catalogTrashPlan(for: [selected]), fileOperation: sandbox.operation)
        #expect(cat.items.map(\.outcome.kind) == [.moved], "\(ext): \(cat.items.map(\.outcome))")
        #expect(selected.removal?.state == .inTrash && selected.removal?.reason == .catalogTrash)
        let landed = try FileManager.default.contentsOfDirectory(atPath: trashDir.path)
        #expect(landed.count == 1)
        #expect(landed.first.flatMap { Self.sha256(trashDir.appendingPathComponent($0).path) } == digest)

        #expect(FileManager.default.fileExists(atPath: source) && Self.sha256(source) == digest, "\(ext): the keeper is untouched")
        #expect(!keeper.isPurged)
    }

    @Test("mp4/h264+aac", .timeLimit(.minutes(2)))
    func mp4() async throws {
        try await runMatrix(ext: "mp4", videoCodec: "libx264", extraVideoArgs: ["-preset", "ultrafast"], audioCodec: "aac")
    }

    @Test("mov/prores+pcm", .timeLimit(.minutes(2)))
    func mov() async throws { try await runMatrix(ext: "mov", videoCodec: "prores") }

    @Test("mkv/ffv1+pcm", .timeLimit(.minutes(2)))
    func mkv() async throws { try await runMatrix(ext: "mkv", videoCodec: "ffv1") }

    @Test("mxf/mpeg2+pcm", .timeLimit(.minutes(2)))
    func mxf() async throws {
        try await runMatrix(ext: "mxf", videoCodec: "mpeg2video", extraVideoArgs: ["-g", "15", "-aspect", "4:3"], size: "720x576")
    }

    @Test("avi/dv+pcm", .timeLimit(.minutes(2)))
    func avi() async throws {
        try await runMatrix(ext: "avi", videoCodec: "dvvideo", extraVideoArgs: ["-pix_fmt", "yuv411p", "-aspect", "4:3"],
                            size: "720x480", rate: "30000/1001")
    }

    // MARK: Scale

    @Test("100k records: Remove 10k, Restore 10k, Trash-emptied pass — each within budget", .timeLimit(.minutes(2)))
    func removeRestoreAndEmptiedPassAt100k() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test_oneengine_scale_\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: dir.appendingPathComponent("catalog", isDirectory: true))
        model.mediaLedger = MediaLedger(directory: dir.appendingPathComponent("ledger", isDirectory: true))
        var recs: [VideoRecord] = []
        recs.reserveCapacity(100_000)
        for i in 0..<100_000 {
            let r = VideoRecord()
            r.fullPath = dir.appendingPathComponent("v\(i).mov").path   // internal paths: never "offline"
            r.filename = "v\(i).mov"
            if i % 10 == 9 {   // 10k already In the Trash; their Trash copies are gone
                r.removal = .inTrash(movedAt: Date(), trashPath: dir.appendingPathComponent(".Trash/v\(i).mov").path, reason: .junk)
            }
            recs.append(r)
        }
        model.records = recs
        let toRemove = Set(recs.enumerated().filter { $0.offset % 10 == 0 }.map(\.element.id))
        let clock = ContinuousClock()

        var removed = 0
        let removeTime = clock.measure { removed = model.purgeRecords(ids: toRemove) }
        #expect(removed == 10_000)
        #expect(removeTime < .seconds(5), "Remove 10k of 100k took \(removeTime)")

        var restored = false
        let restoreTime = clock.measure { restored = model.undoLastPurge() }
        #expect(restored)
        #expect(restoreTime < .seconds(5), "Restore 10k of 100k took \(restoreTime)")

        var emptied = 0
        let emptiedTime = clock.measure { emptied = model.noteEmptiedTrash(in: model.records) }
        #expect(emptied == 10_000)
        #expect(emptiedTime < .seconds(5), "Trash-emptied pass over 100k took \(emptiedTime)")

        #expect(model.records.count == 100_000, "no row was deleted")
        #expect(model.records.count { $0.removal == nil } == 90_000)
    }
}
