// MasterArchivePromoteTests.swift
// The Promote job end-to-end against a temp sandbox — MEDIA MATRIX
// (checklist item 3), the idempotency SENSOR (item 5), and the codex QA
// round-2 requirements: crash-after-rename convergence, adopt-instead-of-
// _NN for an identical existing file, symlinked source refused, source
// mutated mid-copy refused, manifest-only row adopted, cancel leaves no
// partial. Everything under the process temp dir; the shared CatalogStore
// never loads or saves under tests, and the model's UserDefaults
// persistence is gated (ISOLATION, item 4 — asserted explicitly below).

import Foundation
import Testing
@testable import VideoScan

// MARK: - Media matrix

struct PromoteMatrixCase: Sendable, CustomStringConvertible {
    let label: String
    let filename: String
    let size: String
    let rate: String
    let videoCodec: String
    let audioCodec: String?
    let extraVideoArgs: [String]
    var description: String { label }
}

private let promoteMatrix: [PromoteMatrixCase] = [
    PromoteMatrixCase(label: "mp4/h264", filename: "test_pm_h264.mp4", size: "320x240", rate: "25",
                      videoCodec: "libx264", audioCodec: "aac", extraVideoArgs: []),
    PromoteMatrixCase(label: "mov/prores", filename: "test_pm_prores.mov", size: "320x240", rate: "25",
                      videoCodec: "prores", audioCodec: "pcm_s16le", extraVideoArgs: []),
    PromoteMatrixCase(label: "mkv/ffv1+pcm", filename: "test_pm_ffv1.mkv", size: "320x240", rate: "25",
                      videoCodec: "ffv1", audioCodec: "pcm_s16le", extraVideoArgs: []),
    PromoteMatrixCase(label: "mxf", filename: "test_pm_x264.mxf", size: "720x576", rate: "25",
                      videoCodec: "libx264", audioCodec: "pcm_s16le", extraVideoArgs: []),
    PromoteMatrixCase(label: "avi/dv", filename: "test_pm_dv.avi", size: "720x576", rate: "25",
                      videoCodec: "dvvideo", audioCodec: "pcm_s16le", extraVideoArgs: ["-pix_fmt", "yuv420p"]),
]

@Suite("Master Archive — Promote media matrix", .serialized)
@MainActor
struct MasterArchivePromoteMediaMatrixTests {

    @Test("promote every matrix container: dest exists, sha256 == source, manifest row, linked record",
          .timeLimit(.minutes(2)),
          arguments: promoteMatrix)
    func promoteAcrossMatrix(testCase: PromoteMatrixCase) async throws {
        try #require(CleanupTestMedia.toolsAvailable, "ffmpeg/ffprobe are required project dependencies")
        let sb = try MasterArchiveTestSupport.makeSandbox("mx")
        defer { sb.cleanup() }
        let src = try CleanupTestMedia.generate(into: sb.sources, name: testCase.filename, duration: 1.0,
                                                size: testCase.size, rate: testCase.rate,
                                                videoCodec: testCase.videoCodec,
                                                extraVideoArgs: testCase.extraVideoArgs,
                                                audioCodec: testCase.audioCodec)
        let model = MasterArchiveTestSupport.makeModel(sb)
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let rec = MasterArchiveTestSupport.makeRecord(path: src, userDate: "1992-07-15", starRating: 1)
        rec.detectedPeople = ["Donna"]
        model.records = [rec]

        let job = try #require(await MasterArchiveTestSupport.promote(model, ids: [rec.id]))
        guard case .finished = job.state else {
            Issue.record("promote did not finish: \(job.state)"); return
        }
        let files = MasterArchiveTestSupport.archivedFiles(sb)
        #expect(files.count == 1)
        let rel = try #require(files.first)
        #expect(rel.hasPrefix("30_Video/1990-1999/1992/1992-07-15_"), "\(rel)")
        #expect(rel.hasSuffix("." + (testCase.filename as NSString).pathExtension.lowercased()))
        let destPath = sb.archiveRoot.appendingPathComponent(rel).path
        let expected = try #require(MasterArchiveTestSupport.sha256(ofFile: src))
        #expect(MasterArchiveTestSupport.sha256(ofFile: destPath) == expected)

        // Manifest row.
        let rows = MasterArchiveTestSupport.manifestRows(sb)
        #expect(rows.count == 1)
        #expect(rows.first?[ArchiveManifestCSV.relPathColumn] == rel)
        #expect(rows.first?[ArchiveManifestCSV.sha256Column] == expected)
        #expect(rows.first?[ArchiveManifestCSV.sourceRecordIDColumn] == rec.id.uuidString)
        #expect(rows.first?[10] == "Donna")

        // Linked record + source stamp.
        #expect(model.records.count == 2)
        let copy = try #require(model.masterArchiveCopy(of: rec))
        #expect(copy.derivedFrom == rec.id)
        #expect(copy.derivationKind == ArchivePromotion.derivationKind)
        #expect(copy.fullPath == destPath)
        #expect(copy.archiveFixity?.digest == expected)
        #expect(copy.archiveFixity?.algorithm == "sha256")
        #expect(copy.contentHash != expected, "full sha256 never lands in the segmented contentHash")
        #expect(copy.starRating == 3)
        #expect(copy.archiveStage == .masterAssigned)
        #expect(copy.lifecycleStage == .archived)
        #expect(copy.originalFullPath == src)
        #expect(copy.userDate == "1992-07-15")
        #expect(copy.detectedPeople == ["Donna"])
        #expect(copy.notes.contains("Promote "))
        #expect(model.promotionSource(of: copy) === rec)
        #expect(rec.archiveStage == .masterAssigned)
        #expect(rec.starRating == 3)
        #expect(rec.notes.contains("promoted to Master Archive as \(rel)"))
        #expect(FileManager.default.fileExists(atPath: src), "source never moved")
        // Journal converged to done.
        let latest = ArchivePromoteJournal.latestBySource(in: sb.journalURL)
        #expect(latest[rec.id]?.state == .done)
        #expect(!FileManager.default.fileExists(atPath: destPath + ".partial"))
    }
}

// MARK: - Sensor + convergence + safety

@Suite("Master Archive — Promote sensor & convergence", .serialized)
@MainActor
struct MasterArchivePromoteSensorTests {

    private func seed(_ sb: MasterArchiveTestSupport.Sandbox, count: Int, bytes: Int = 64 * 1024) throws -> [URL] {
        try (0..<count).map { i in
            try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent("test_src_\(i).mov"),
                                                   bytes: bytes + i, seed: UInt64(i + 1))
        }
    }

    @Test("SENSOR: a synthetic tree promoted twice → exactly one copy + one manifest row per source; manifest sha matches file")
    func promoteTwiceIsIdempotent() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("sensor")
        defer { sb.cleanup() }
        let files = try seed(sb, count: 6)
        let model = MasterArchiveTestSupport.makeModel(sb)
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let recs = files.enumerated().map { i, u in
            MasterArchiveTestSupport.makeRecord(path: u.path,
                                                streamType: i % 2 == 0 ? .videoAndAudio : .audioOnly,
                                                userDate: i < 3 ? "200\(i)" : nil)
        }
        model.records = recs
        let ids = recs.map(\.id)

        let first = try #require(await MasterArchiveTestSupport.promote(model, ids: ids))
        guard case .finished(let s1) = first.state else { Issue.record("first run: \(first.state)"); return }
        #expect(s1.hasPrefix("Promoted 6"))
        let second = try #require(await MasterArchiveTestSupport.promote(model, ids: ids))
        // buildPromotePlan already skips promoted sources → an empty plan finishes with 0/0.
        guard case .finished = second.state else { Issue.record("second run: \(second.state)"); return }
        #expect(second.plan.entries.isEmpty)
        #expect(second.plan.alreadyPromotedCount == 6)

        // A job built with the ORIGINAL plan (stale) must also skip.
        let stale = PromoteToArchiveJob(plan: first.plan, model: model)
        stale.start(); await stale.task?.value
        guard case .finished(let s3) = stale.state else { Issue.record("stale run: \(stale.state)"); return }
        #expect(s3.contains("skipped 6"), "\(s3)")

        let archived = MasterArchiveTestSupport.archivedFiles(sb)
        #expect(archived.count == 6, "\(archived)")
        #expect(archived.filter { $0.hasPrefix("20_Audio/") }.count == 3)
        #expect(archived.filter { $0.hasPrefix("30_Video/") }.count == 3)
        let rows = MasterArchiveTestSupport.manifestRows(sb)
        #expect(rows.count == 6)
        for row in rows {
            let path = sb.archiveRoot.appendingPathComponent(row[ArchiveManifestCSV.relPathColumn]).path
            #expect(MasterArchiveTestSupport.sha256(ofFile: path) == row[ArchiveManifestCSV.sha256Column])
        }
        #expect(model.records.count == 12)
        #expect(model.records.filter { model.isArchiveCopy($0) }.count == 6)
        for r in recs { #expect(model.masterArchiveCopy(of: r) != nil) }
    }

    @Test("crash after rename (file exists, no manifest row, no record) CONVERGES: one file, one row, one link")
    func crashAfterRenameConverges() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("crash1")
        defer { sb.cleanup() }
        let src = try seed(sb, count: 1)[0]
        let model = MasterArchiveTestSupport.makeModel(sb)
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let rec = MasterArchiveTestSupport.makeRecord(path: src.path, userDate: "1999")
        model.records = [rec]

        // Simulate the crash: journal says intent, the final file is there.
        let rel = "30_Video/1990-1999/1999/1999-xx-xx_test_src_0.mov"
        let dest = sb.archiveRoot.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: src, to: dest)
        try ArchivePromoteJournal.append(.init(sourceRecordID: rec.id, sourcePath: src.path, destRelPath: rel,
                                               state: .intent, sha256: nil, copyRecordID: nil, at: Date()),
                                         rootPath: sb.archiveRoot.path)

        let job = try #require(await MasterArchiveTestSupport.promote(model, ids: [rec.id]))
        guard case .finished = job.state else { Issue.record("\(job.state)"); return }
        #expect(MasterArchiveTestSupport.archivedFiles(sb) == [rel], "no _02 duplicate")
        let rows = MasterArchiveTestSupport.manifestRows(sb)
        #expect(rows.count == 1)
        #expect(rows.first?[ArchiveManifestCSV.relPathColumn] == rel)
        #expect(model.masterArchiveCopy(of: rec)?.fullPath == dest.path)
        #expect(ArchivePromoteJournal.latestBySource(in: sb.journalURL)[rec.id]?.state == .done)
    }

    @Test("crash after manifest append (row, no record) is adopted, not re-copied")
    func manifestOnlyRowAdopted() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("crash2")
        defer { sb.cleanup() }
        let src = try seed(sb, count: 1)[0]
        let model = MasterArchiveTestSupport.makeModel(sb)
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let rec = MasterArchiveTestSupport.makeRecord(path: src.path)
        model.records = [rec]
        let rel = "30_Video/Undated/xxxx-xx-xx_test_src_0.mov"
        let dest = sb.archiveRoot.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: src, to: dest)
        let sha = try #require(MasterArchiveTestSupport.sha256(ofFile: src.path))
        try ArchiveManifestCSV.append(.init(promotedAt: Date(), archiveRelPath: rel, sha256: sha, sizeBytes: 1,
                                            originalPath: src.path, originalVolume: "v", recordID: UUID(),
                                            sourceRecordID: rec.id, recordDate: "", dateConfidence: "",
                                            people: [], starRating: 3), rootPath: sb.archiveRoot.path)

        let job = try #require(await MasterArchiveTestSupport.promote(model, ids: [rec.id]))
        guard case .finished(let summary) = job.state else { Issue.record("\(job.state)"); return }
        #expect(summary.contains("adopted 1"), "\(summary)")
        #expect(MasterArchiveTestSupport.archivedFiles(sb) == [rel])
        #expect(MasterArchiveTestSupport.manifestRows(sb).count == 1, "no second row")
        #expect(model.masterArchiveCopy(of: rec)?.fullPath == dest.path)
    }

    @Test("an identical file already at the destination name is ADOPTED; a different one gets _02")
    func adoptIdenticalElseSuffix() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("adopt")
        defer { sb.cleanup() }
        let files = try seed(sb, count: 2)
        let model = MasterArchiveTestSupport.makeModel(sb)
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let a = MasterArchiveTestSupport.makeRecord(path: files[0].path)   // identical copy pre-placed
        let b = MasterArchiveTestSupport.makeRecord(path: files[1].path)   // different bytes, same name
        model.records = [a, b]

        // Pre-place a's bytes at a's name; and a foreign file at b's name.
        let relA = "30_Video/Undated/xxxx-xx-xx_test_src_0.mov"
        let relB = "30_Video/Undated/xxxx-xx-xx_test_src_1.mov"
        let undated = sb.archiveRoot.appendingPathComponent("30_Video/Undated")
        try FileManager.default.createDirectory(at: undated, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: files[0], to: sb.archiveRoot.appendingPathComponent(relA))
        try MasterArchiveTestSupport.writeBlob(at: sb.archiveRoot.appendingPathComponent(relB), bytes: 64 * 1024 + 1, seed: 999)

        let job = try #require(await MasterArchiveTestSupport.promote(model, ids: [a.id, b.id]))
        guard case .finished(let summary) = job.state else { Issue.record("\(job.state)"); return }
        #expect(summary.contains("Promoted 1"), "\(summary)")
        #expect(summary.contains("adopted 1"), "\(summary)")
        let archived = MasterArchiveTestSupport.archivedFiles(sb)
        #expect(archived == [relA, relB, "30_Video/Undated/xxxx-xx-xx_test_src_1_02.mov"], "\(archived)")
        #expect(model.masterArchiveCopy(of: a)?.fullPath == sb.archiveRoot.appendingPathComponent(relA).path)
        #expect(model.masterArchiveCopy(of: b)?.fullPath == sb.archiveRoot.appendingPathComponent("30_Video/Undated/xxxx-xx-xx_test_src_1_02.mov").path)
        // The foreign file at relB was never touched.
        #expect(MasterArchiveTestSupport.sha256(ofFile: sb.archiveRoot.appendingPathComponent(relB).path)
                != MasterArchiveTestSupport.sha256(ofFile: files[1].path))
    }

    @Test("a symlinked source is refused (O_NOFOLLOW); nothing lands in the archive")
    func symlinkedSourceRefused() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("symlink")
        defer { sb.cleanup() }
        let real = try seed(sb, count: 1)[0]
        let link = sb.sources.appendingPathComponent("test_link.mov")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let model = MasterArchiveTestSupport.makeModel(sb)
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let rec = MasterArchiveTestSupport.makeRecord(path: link.path)
        model.records = [rec]
        let job = try #require(await MasterArchiveTestSupport.promote(model, ids: [rec.id]))
        guard case .failed(let msg) = job.state else { Issue.record("expected failure, got \(job.state)"); return }
        #expect(msg.contains("failed 1"), "\(msg)")
        #expect(job.outcomes.first?.detail.contains("not a regular file") == true, "\(job.outcomes.first?.detail ?? "")")
        #expect(MasterArchiveTestSupport.archivedFiles(sb).isEmpty)
        #expect(MasterArchiveTestSupport.manifestRows(sb).isEmpty)
        #expect(model.records.count == 1)
    }

    @Test("a symlink planted inside the archive tree refuses the copy (containment)")
    func symlinkInsideArchiveRefused() throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("symtree")
        defer { sb.cleanup() }
        _ = try VideoScanModel.scaffoldMasterArchive(rootURL: sb.archiveRoot)
        let src = try seed(sb, count: 1)[0]
        // 30_Video/Undated → symlink to somewhere outside.
        let outside = sb.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: sb.archiveRoot.appendingPathComponent("30_Video/Undated"),
                                                   withDestinationURL: outside)
        let handle = try ArchivePromoteEngine.openSource(path: src.path)
        defer { handle.close() }
        #expect(throws: ArchivePromoteEngine.Failure.self) {
            try ArchivePromoteEngine.copyVerifyPublish(source: handle, root: sb.archiveRoot.path,
                                                       relativePath: "30_Video/Undated/xxxx-xx-xx_x.mov")
        }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: outside.path))?.isEmpty == true)
    }

    @Test("engine: source mutated mid-copy is refused and the partial removed; a clean copy publishes with fd == path identity")
    func engineToctou() throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("toctou")
        defer { sb.cleanup() }
        _ = try VideoScanModel.scaffoldMasterArchive(rootURL: sb.archiveRoot)
        let src = try seed(sb, count: 1, bytes: 3 * (1 << 20))[0]   // 3 chunks

        // Mutate the source during the copy (from the progress callback).
        let h1 = try ArchivePromoteEngine.openSource(path: src.path)
        var poisoned = false
        let rel = "30_Video/Undated/xxxx-xx-xx_toctou.mov"
        #expect(throws: ArchivePromoteEngine.Failure.self) {
            try ArchivePromoteEngine.copyVerifyPublish(source: h1, root: sb.archiveRoot.path, relativePath: rel,
                                                       progress: { _ in
                if !poisoned {
                    poisoned = true
                    // Append a byte via a separate descriptor — size+mtime change.
                    if let fh = try? FileHandle(forWritingTo: src) {
                        _ = try? fh.seekToEnd(); try? fh.write(contentsOf: Data([0x42])); try? fh.close()
                    }
                }
            })
        }
        h1.close()
        #expect(!FileManager.default.fileExists(atPath: sb.archiveRoot.appendingPathComponent(rel).path))
        #expect(!FileManager.default.fileExists(atPath: sb.archiveRoot.appendingPathComponent(rel + ".partial").path))

        // Now a clean run publishes.
        let h2 = try ArchivePromoteEngine.openSource(path: src.path)
        defer { h2.close() }
        let result = try ArchivePromoteEngine.copyVerifyPublish(source: h2, root: sb.archiveRoot.path, relativePath: rel)
        let dest = sb.archiveRoot.appendingPathComponent(rel).path
        #expect(result.sha256 == MasterArchiveTestSupport.sha256(ofFile: dest))
        #expect(result.sha256 == MasterArchiveTestSupport.sha256(ofFile: src.path))
        #expect(result.sizeBytes == 3 * (1 << 20) + 1)
        // Second publish to the same name is refused (RENAME_EXCL / no clobber).
        #expect(throws: ArchivePromoteEngine.Failure.self) {
            try ArchivePromoteEngine.copyVerifyPublish(source: h2, root: sb.archiveRoot.path, relativePath: rel)
        }
        #expect(result.sha256 == MasterArchiveTestSupport.sha256(ofFile: dest), "not clobbered")
    }

    @Test("engine: destination escaping the root and a symlink source are refused before any I/O")
    func engineContainment() throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("contain")
        defer { sb.cleanup() }
        _ = try VideoScanModel.scaffoldMasterArchive(rootURL: sb.archiveRoot)
        let src = try seed(sb, count: 1)[0]
        let h = try ArchivePromoteEngine.openSource(path: src.path)
        defer { h.close() }
        #expect(throws: ArchivePromoteEngine.Failure.self) {
            try ArchivePromoteEngine.copyVerifyPublish(source: h, root: sb.archiveRoot.path, relativePath: "../escaped.mov")
        }
        #expect(!FileManager.default.fileExists(atPath: sb.archiveVolume.appendingPathComponent("escaped.mov").path))
        let link = sb.sources.appendingPathComponent("lnk.mov")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: src)
        #expect(throws: ArchivePromoteEngine.Failure.self) { _ = try ArchivePromoteEngine.openSource(path: link.path) }
        #expect(throws: ArchivePromoteEngine.Failure.self) { _ = try ArchivePromoteEngine.openSource(path: sb.sources.path) }
    }

    @Test("cancel mid-batch leaves no partials; completed files stay indexed")
    func cancelIsClean() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("cancel")
        defer { sb.cleanup() }
        let files = try seed(sb, count: 3, bytes: 8 * (1 << 20))
        let model = MasterArchiveTestSupport.makeModel(sb)
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let recs = files.map { MasterArchiveTestSupport.makeRecord(path: $0.path) }
        model.records = recs
        let plan = try #require(model.buildPromotePlan(recordIDs: recs.map(\.id)))
        let job = PromoteToArchiveJob(plan: plan, model: model)
        job.start()
        // Let the first file land, then cancel.
        while job.outcomes.isEmpty && job.state.isActive {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        job.cancel()
        await job.task?.value
        #expect(job.state == .cancelled || !job.state.isActive)
        let leftovers = (try? FileManager.default.subpathsOfDirectory(atPath: sb.archiveRoot.path))?
            .filter { $0.hasSuffix(".partial") } ?? []
        #expect(leftovers.isEmpty, "\(leftovers)")
        let archived = MasterArchiveTestSupport.archivedFiles(sb)
        #expect(archived.count == MasterArchiveTestSupport.manifestRows(sb).count)
        #expect(archived.count == model.records.filter { model.isArchiveCopy($0) }.count)
    }

    @Test("ISOLATION: nothing under App Support and no UserDefaults key is written by Initialize + Promote")
    func isolation() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("iso")
        defer { sb.cleanup() }
        let sharedPath = CatalogStore.shared.fileLocation
        let sharedBefore = (try? FileManager.default.attributesOfItem(atPath: sharedPath))?[.modificationDate] as? Date
        let keysBefore = Set(UserDefaults.standard.dictionaryRepresentation().keys)

        let src = try seed(sb, count: 1)[0]
        let model = MasterArchiveTestSupport.makeModel(sb)
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let rec = MasterArchiveTestSupport.makeRecord(path: src.path)
        model.records = [rec]
        _ = await MasterArchiveTestSupport.promote(model, ids: [rec.id])
        model.saveCatalogNow()

        let sharedAfter = (try? FileManager.default.attributesOfItem(atPath: sharedPath))?[.modificationDate] as? Date
        #expect(sharedBefore == sharedAfter, "shared catalog.json untouched")
        let added = Set(UserDefaults.standard.dictionaryRepresentation().keys).subtracting(keysBefore)
        #expect(added.isEmpty, "UserDefaults polluted with: \(added.sorted())")
        #expect(model.masterArchive?.rootPath.hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path) == true)
    }
}
