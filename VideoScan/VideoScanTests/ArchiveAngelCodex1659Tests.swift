// ArchiveAngelCodex1659Tests.swift
// codex #1659 (2026-09-23) — re-verification of the #1654 fixes at 00b16d91;
// the probe in ~/Library/Logs/VideoScan/review_1656_00b16d91/ as red tests:
//
//   P1  a STALE full-fixity donor: A and B verified byte-identical, then B
//       rewritten at the same size and given a known 1991-07. B's stored
//       ContentFixity no longer describes the file (describesFileNow ==
//       false) — it must not lend to A, at plan build or at Promote.
//   P2  the rollback's durable catalog save must not block the main actor
//       (no synchronous saveCatalogNow in the Angel); the crash-simulation
//       test (ArchiveAngelCodex1654Tests.rollbackSurvivesACrash) still holds.
//
// Real 512-byte files, real SHA-256, real stat stamps — no stamp mocking.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Archive Angel — codex #1659: stale fixity donors, non-blocking durable rollback", .serialized)
@MainActor
struct ArchiveAngelCodex1659Tests {

    private struct Fixture {
        let sb: MasterArchiveTestSupport.Sandbox
        let model: VideoScanModel
        let target: VideoRecord
        let donor: VideoRecord
    }

    /// A and B byte-identical, both with a REAL captured ContentFixity; then
    /// (when `rewriteDonor`) B rewritten in place at the same size with other
    /// bytes, its catalogue fixity left as it was, and a known 1991-07 typed
    /// on it — codex's probe.
    private func fixture(_ label: String, rewriteDonor: Bool, media: Bool = false) async throws -> Fixture {
        let sb = try MasterArchiveTestSupport.makeSandbox(label)
        let model = MasterArchiveTestSupport.makeModel(sb)
        model.scanTargets = []
        model.previewSweep.stop()
        model.archiveAngel.sweep.stop()
        let a = sb.sources.appendingPathComponent(media ? "test_full_a.mp4" : "test_full_a.bin")
        let b = sb.sources.appendingPathComponent(media ? "test_full_b.mp4" : "test_full_b.bin")
        if media {
            // A real 4 s clip (the Angel only picks video), copied byte for byte.
            let r = await ProcessRunner.runProcess(
                executable: ToolLocator.ffmpegPath,
                arguments: ["-hide_banner", "-loglevel", "error", "-y",
                            "-f", "lavfi", "-i", "testsrc=size=320x240:rate=30:duration=4",
                            "-f", "lavfi", "-i", "sine=frequency=440:duration=4",
                            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", a.path],
                deadlineSeconds: 120)
            try #require(r.exitCode == 0, "fixture: \(r.stderr)")
        } else {
            try Data((0..<512).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 1) }).write(to: a)
        }
        try FileManager.default.copyItem(at: a, to: b)
        let bytes = try Data(contentsOf: a)
        let size = Int64(bytes.count)
        let digest = try #require(try ArchivePromoteEngine.sha256(path: a.path))
        let target = MasterArchiveTestSupport.makeRecord(path: a.path, starRating: 3)
        let donor = MasterArchiveTestSupport.makeRecord(path: b.path)
        for r in [target, donor] {
            r.durationSeconds = 600; r.videoCodec = "h264"; r.audioCodec = "aac"; r.isPlayable = "Yes"
        }
        target.contentFixity = try #require(ContentFixity.captured(path: a.path, digest: digest, byteCount: size))
        donor.contentFixity = try #require(ContentFixity.captured(path: b.path, digest: digest, byteCount: size))
        if rewriteDonor {
            Thread.sleep(forTimeInterval: 0.01)          // a distinct ctime
            var other = bytes
            other[other.count / 2] ^= 0xFF
            let h = try FileHandle(forWritingTo: b)
            try h.write(contentsOf: other)
            try h.close()
            #expect(donor.contentFixity?.describesFileNow(FileIdentityStamp.capture(path: b.path)) == false,
                    "the probe's precondition: B's stored fixity no longer describes B")
        }
        donor.userDate = "1991-07"; donor.userDateConfidence = "known"
        donor.userPlace = "Nantucket"; donor.userPlaceConfidence = "known"
        model.records = [target, donor]
        return Fixture(sb: sb, model: model, target: target, donor: donor)
    }

    private func entry(_ rec: VideoRecord, proposedDate: String?) -> ArchiveAngelPlan.Entry {
        ArchiveAngelPlan.Entry(id: rec.id, sourcePath: rec.fullPath, filename: rec.filename, sizeBytes: rec.sizeBytes,
                               sourceContentHash: rec.contentHash, sourceModifiedAt: nil, durationSeconds: 600,
                               score: 105, evidence: [], proposedName: rec.filename, proposedDate: proposedDate,
                               status: .ready)
    }

    @Test("RED P1: plan build — a donor rewritten since its fixity was taken lends nothing (codex probe)")
    func staleDonorAtPlanBuild() async throws {
        let f = try await fixture("c1659_plan", rewriteDonor: true, media: true); defer { f.sb.cleanup() }
        let buffer = f.sb.root.appendingPathComponent("Buffer", isDirectory: true)
        try FileManager.default.createDirectory(at: buffer, withIntermediateDirectories: true)
        let center = MediaFileOperationsCenter()
        let job = ArchiveAngelJob(model: f.model, center: center, count: 1, makeLossless: false,
                                  bufferRoot: buffer, explicitRecordIDs: [f.target.id])
        job.start()
        await job.task?.value
        _ = center
        let row = try #require(job.plan.entries.first, "\(job.plan.log.suffix(5))")
        #expect(row.inheritedDate == nil, "a stale donor lent \(row.inheritedDate?.value ?? "") at plan build")
        #expect(row.inheritedPlace == nil)
        #expect(row.proposedDate != "1991-07")
    }

    @Test("RED P1: Promote — a stale donor's known date is never stamped (codex probe)")
    func staleDonorAtPromote() async throws {
        let f = try await fixture("c1659_promote", rewriteDonor: true); defer { f.sb.cleanup() }
        try MasterArchiveTestSupport.initialize(f.model, in: f.sb)
        var plan = ArchiveAngelPlan(batchDir: f.sb.root.appendingPathComponent("batch-c1659").path,
                                    requestedCount: 1, makeLossless: false,
                                    entries: [entry(f.target, proposedDate: nil)])
        plan.status = .ready
        let job = ArchiveAngelPromoter().promote(plan: &plan, model: f.model, center: MediaFileOperationsCenter()) { _ in }
        #expect(f.target.userDate == nil, "a stale donor's \(f.target.userDate ?? "") was stamped as \(f.target.userDateConfidence ?? "")")
        #expect(f.target.userPlace == nil)
        job?.cancel()
        await job?.task?.value
    }

    @Test("P1: the stat at the stamp boundary — the stale donor is not fresh, the unchanged target is; nothing is stamped")
    func staleDonorAtPromoteWithVerification() async throws {
        let f = try await fixture("c1659_promote_verified", rewriteDonor: true); defer { f.sb.cleanup() }
        try MasterArchiveTestSupport.initialize(f.model, in: f.sb)
        var plan = ArchiveAngelPlan(batchDir: f.sb.root.appendingPathComponent("batch-c1659v").path,
                                    requestedCount: 1, makeLossless: false,
                                    entries: [entry(f.target, proposedDate: nil)])
        plan.status = .ready
        let fresh = await ArchiveAngelPromoter.verifiedFixity(for: plan, catalog: f.model)
        #expect(fresh == [f.target.id], "only the unchanged target's fixity describes its file now")
        let job = ArchiveAngelPromoter().promote(plan: &plan, model: f.model, center: MediaFileOperationsCenter(),
                                                 freshFixity: fresh) { _ in }
        #expect(f.target.userDate == nil, "a stale donor's \(f.target.userDate ?? "") was stamped")
        #expect(f.target.userPlace == nil)
        job?.cancel()
        await job?.task?.value
    }

    @Test("P1 control: an UNCHANGED verified twin still lends — at plan build and at the stamp boundary")
    func freshTwinLends() async throws {
        let f = try await fixture("c1659_control", rewriteDonor: false, media: true); defer { f.sb.cleanup() }
        let buffer = f.sb.root.appendingPathComponent("Buffer", isDirectory: true)
        try FileManager.default.createDirectory(at: buffer, withIntermediateDirectories: true)
        let center = MediaFileOperationsCenter()
        let job = ArchiveAngelJob(model: f.model, center: center, count: 1, makeLossless: false,
                                  bufferRoot: buffer, explicitRecordIDs: [f.target.id])
        job.start()
        await job.task?.value
        _ = center
        let row = try #require(job.plan.entries.first, "\(job.plan.log.suffix(5))")
        #expect(row.inheritedDate?.value == "1991-07" && row.inheritedDate?.fromFilename == "test_full_b.mp4")
        try MasterArchiveTestSupport.initialize(f.model, in: f.sb)
        var plan = ArchiveAngelPlan(batchDir: f.sb.root.appendingPathComponent("batch-c1659c").path,
                                    requestedCount: 1, makeLossless: false,
                                    entries: [entry(f.target, proposedDate: "1991-07")])
        plan.status = .ready
        let fresh = await ArchiveAngelPromoter.verifiedFixity(for: plan, catalog: f.model)
        #expect(fresh == [f.target.id, f.donor.id])
        let promote = ArchiveAngelPromoter().promote(plan: &plan, model: f.model, center: MediaFileOperationsCenter(),
                                                     freshFixity: fresh) { _ in }
        #expect(f.target.userDate == "1991-07" && f.target.userDateConfidence == "known")
        promote?.cancel()
        await promote?.task?.value
    }

    @Test("P2: the acknowledged catalog save really reaches disk and never runs the synchronous path")
    func acknowledgedSaveIsDurable() async throws {
        let f = try await fixture("c1659_ack", rewriteDonor: false); defer { f.sb.cleanup() }
        f.target.userNotes = "acknowledged-\(UUID().uuidString.prefix(6))"
        let ok = await f.model.saveCatalogAcknowledged()
        #expect(ok)
        let onDisk = try String(contentsOf: f.model.catalogStore.catalogFileURL, encoding: .utf8)
        #expect(onDisk.contains(f.target.userNotes), "the acknowledged snapshot is on disk")
    }

    @Test("RED P2: the Angel never saves the catalog synchronously on the main actor (codex #1659)")
    func noSynchronousCatalogSave() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VideoScan/ArchiveAngel")
        var offenders: [String] = []
        for url in ArchiveAngelBoundarySensorTests.swiftFiles(under: dir) {
            let code = ArchiveAngelBoundarySensorTests.code(of: url)
            if code.contains("saveCatalogNow(") { offenders.append(url.lastPathComponent) }
        }
        #expect(offenders.isEmpty, "synchronous saveCatalogNow (encode + write + F_FULLFSYNC on the main actor) in \(offenders)")
    }
}
