// PromoteArchiveIntegrityTests.swift
// Two archive-integrity bugs in Promote (Rick approved 2026-10-02):
//
//   GH #219 (residual) — "one Promote-time date drives the folder, the
//   filename, the manifest record_date and the copy's catalog record
//   together, or the Promote refuses." The 2026-09-27 fix (aba783fa) made a
//   typed YEAR / MONTH / DAY agree in all four places. What was left: a
//   Promote date the archived record cannot carry as Rick's date — a typed
//   DECADE ("1940s"; the user-date grammar has no decade form) or an Angel
//   MACHINE proposal (never written as Rick's) — left the SOURCE's own
//   userDate riding registration onto the copy, so the catalog said 1990
//   while the folder, filename and manifest said the 1940s.
//
//   GH #190 — "Promote let an identical file into the archive twice (same
//   sha256, different source path)." Promote must refuse — naming the file
//   already holding those bytes — when the archive's index (00_Index
//   manifest) or its fixity data (archive-copy records' archiveFixity)
//   already holds the source's sha256, including two identical files in the
//   same batch and two Promote jobs running at once. No second copy lands.
//
// Every fixture lives in a temp sandbox (`test_*`) — never
// /Volumes/FamilyArchive, never App Support (MasterArchiveTestSupport).
// Archived files are LOCKED by Promote; Sandbox.cleanup unlocks first.
//
// (For Rick: `@Suite(.serialized)` ≈ a gtest fixture whose cases run one at
// a time; `#require` ≈ ASSERT_*, `#expect` ≈ EXPECT_*.)

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

// MARK: - Shared helpers

@MainActor
enum PromoteIntegrityHarness {

    static func setup(_ label: String) throws -> (sb: MasterArchiveTestSupport.Sandbox, model: VideoScanModel) {
        let sb = try MasterArchiveTestSupport.makeSandbox(label)
        let model = MasterArchiveTestSupport.makeModel(sb)
        model.mediaLedger = MediaLedger(directory: sb.root.appendingPathComponent("ledger", isDirectory: true))
        try MasterArchiveTestSupport.initialize(model, in: sb)
        return (sb, model)
    }

    /// A source file + its catalog record (appended to the model).
    static func source(_ sb: MasterArchiveTestSupport.Sandbox, _ model: VideoScanModel,
                       name: String, seed: UInt64, bytes: Int = 40_000,
                       subfolder: String? = nil) throws -> VideoRecord {
        var dir = sb.sources
        if let subfolder {
            dir = dir.appendingPathComponent(subfolder, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let url = try MasterArchiveTestSupport.writeBlob(at: dir.appendingPathComponent(name), bytes: bytes, seed: seed)
        let rec = MasterArchiveTestSupport.makeRecord(path: url.path)
        model.records.append(rec)
        return rec
    }

    /// A byte-for-byte copy of `of`'s file at another path / name.
    static func twin(of rec: VideoRecord, _ sb: MasterArchiveTestSupport.Sandbox, _ model: VideoScanModel,
                     name: String, subfolder: String = "other_card") throws -> VideoRecord {
        let dir = sb.sources.appendingPathComponent(subfolder, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try FileManager.default.copyItem(atPath: rec.fullPath, toPath: url.path)
        let twin = MasterArchiveTestSupport.makeRecord(path: url.path)
        model.records.append(twin)
        return twin
    }

    static func job(_ model: VideoScanModel, ids: [UUID],
                    edit: (inout ArchivePromotePlan) -> Void = { _ in }) throws -> PromoteToArchiveJob {
        var plan = try #require(model.buildPromotePlan(recordIDs: ids))
        edit(&plan)
        return PromoteToArchiveJob(plan: plan, model: model)
    }

    static func run(_ model: VideoScanModel, ids: [UUID],
                    edit: (inout ArchivePromotePlan) -> Void = { _ in }) async throws -> PromoteToArchiveJob {
        let j = try job(model, ids: ids, edit: edit)
        j.start()
        await j.task?.value
        await j.completionTask?.value
        return j
    }

    static func outcome(_ job: PromoteToArchiveJob, _ id: UUID) -> PromoteToArchiveJob.FileOutcome? {
        job.outcomes.first { $0.recordID == id }
    }

    static func partials(_ sb: MasterArchiveTestSupport.Sandbox) -> [String] {
        ((try? FileManager.default.subpathsOfDirectory(atPath: sb.archiveRoot.path)) ?? [])
            .filter { $0.hasSuffix(".partial") }
    }

    /// Distinct sha256 values among the archive's media files.
    static func archivedDigests(_ sb: MasterArchiveTestSupport.Sandbox) -> [String] {
        MasterArchiveTestSupport.archivedFiles(sb).compactMap {
            MasterArchiveTestSupport.sha256(ofFile: sb.archiveRoot.appendingPathComponent($0).path)
        }
    }
}

// MARK: - GH #219 (residual): the date the archived record cannot carry

@Suite("GH #219 — Promote date: folder, filename, manifest and catalog agree, or Promote refuses", .serialized)
@MainActor
struct PromoteDateAgreementTests {

    typealias H = PromoteIntegrityHarness

    @Test("typed YEAR: folder, filename, manifest record_date and the copy's catalog date are one value")
    func typedYearAllFourAgree() async throws {
        let (sb, model) = try H.setup("219year")
        defer { sb.cleanup() }
        let rec = try H.source(sb, model, name: "test_tape.mov", seed: 1)
        rec.userDate = "1990"; rec.userDateConfidence = UserDateConfidence.known.rawValue
        let job = try await H.run(model, ids: [rec.id]) {
            $0.archiveDateOverrides[rec.id] = .year(1947); $0.archiveDateSources[rec.id] = .typed
        }
        #expect(H.outcome(job, rec.id)?.kind == .promoted, "\(job.outcomes)")
        let rel = try #require(MasterArchiveTestSupport.archivedFiles(sb).first)
        #expect(rel.hasPrefix("30_Video/1940-1949/1947/1947-xx-xx_"), "folder + filename: \(rel)")
        let row = try #require(MasterArchiveTestSupport.manifestRows(sb).first)
        #expect(row[8] == "1947-xx-xx" && row[9] == "user-estimated", "manifest: \(row[8]) / \(row[9])")
        let copy = try #require(model.masterArchiveCopy(of: rec))
        #expect(copy.userDate == "1947", "catalog: \(copy.userDate ?? "nil")")
        #expect(copy.resolvedDateDisplay.hasPrefix("1947"), "Date column: \(copy.resolvedDateDisplay)")
        #expect(rec.userDate == "1990", "the SOURCE is never re-dated")
    }

    @Test("typed DECADE over the source's own (known) date in another decade → REFUSED, nothing written")
    func typedDecadeContradictingOwnDateRefused() async throws {
        let (sb, model) = try H.setup("219decade")
        defer { sb.cleanup() }
        let rec = try H.source(sb, model, name: "test_tape.mov", seed: 2)
        rec.userDate = "1990"; rec.userDateConfidence = UserDateConfidence.known.rawValue
        let job = try await H.run(model, ids: [rec.id]) {
            $0.archiveDateOverrides[rec.id] = .decade(startYear: 1940); $0.archiveDateSources[rec.id] = .typed
        }
        let o = try #require(H.outcome(job, rec.id))
        #expect(o.kind == .failed, "a contradiction must refuse, not promote: \(o.kind) — \(o.detail)")
        #expect(o.detail.contains("1940s") && o.detail.contains("1990"), "the refusal names both dates: \(o.detail)")
        #expect(MasterArchiveTestSupport.archivedFiles(sb).isEmpty, "no file")
        #expect(MasterArchiveTestSupport.manifestRows(sb).isEmpty, "no manifest row")
        #expect(ArchivePromoteJournal.latestBySource(rootPath: sb.archiveRoot.path)[rec.id] == nil,
                "refused BEFORE the journal intent — zero bytes written")
        #expect(H.partials(sb).isEmpty)
        #expect(model.masterArchiveCopy(of: rec) == nil)
        #expect(rec.userDate == "1990")
    }

    @Test("an Angel MACHINE proposal that contradicts the source's own date → REFUSED, nothing written")
    func machineProposalContradictingOwnDateRefused() async throws {
        let (sb, model) = try H.setup("219machine")
        defer { sb.cleanup() }
        let rec = try H.source(sb, model, name: "test_tape.mov", seed: 3)
        rec.userDate = "2004"; rec.userDateConfidence = UserDateConfidence.estimated.rawValue
        let job = try await H.run(model, ids: [rec.id]) {
            $0.archiveDateOverrides[rec.id] = .year(1999)          // no source = machine
        }
        let o = try #require(H.outcome(job, rec.id))
        #expect(o.kind == .failed, "\(o.kind) — \(o.detail)")
        #expect(o.detail.contains("1999") && o.detail.contains("2004"), "\(o.detail)")
        #expect(MasterArchiveTestSupport.archivedFiles(sb).isEmpty && MasterArchiveTestSupport.manifestRows(sb).isEmpty)
        #expect(model.masterArchiveCopy(of: rec) == nil)
    }

    @Test("typed DECADE on an undated source → promoted under the decade; the record claims no other date")
    func typedDecadeUndatedSourcePromoted() async throws {
        let (sb, model) = try H.setup("219undated")
        defer { sb.cleanup() }
        let rec = try H.source(sb, model, name: "test_tape.mov", seed: 4)
        let job = try await H.run(model, ids: [rec.id]) {
            $0.archiveDateOverrides[rec.id] = .decade(startYear: 1940); $0.archiveDateSources[rec.id] = .typed
        }
        #expect(H.outcome(job, rec.id)?.kind == .promoted, "\(job.outcomes)")
        let rel = try #require(MasterArchiveTestSupport.archivedFiles(sb).first)
        #expect(rel.hasPrefix("30_Video/1940-1949/xxxx-xx-xx_"), "\(rel)")
        let row = try #require(MasterArchiveTestSupport.manifestRows(sb).first)
        #expect(row[8] == "1940s" && row[9] == "user-estimated", "\(row[8]) / \(row[9])")
        let copy = try #require(model.masterArchiveCopy(of: rec))
        #expect(copy.userDate == nil, "no user date contradicts the decade: \(copy.userDate ?? "nil")")
    }

    @Test("typed DECADE that CONTAINS the source's own date → promoted; the record's 1945 sits inside the 1940s")
    func typedDecadeContainingOwnDatePromoted() async throws {
        let (sb, model) = try H.setup("219inside")
        defer { sb.cleanup() }
        let rec = try H.source(sb, model, name: "test_tape.mov", seed: 5)
        rec.userDate = "1945"; rec.userDateConfidence = UserDateConfidence.known.rawValue
        let job = try await H.run(model, ids: [rec.id]) {
            $0.archiveDateOverrides[rec.id] = .decade(startYear: 1940); $0.archiveDateSources[rec.id] = .typed
        }
        #expect(H.outcome(job, rec.id)?.kind == .promoted, "\(job.outcomes)")
        #expect(MasterArchiveTestSupport.manifestRows(sb).first?[8] == "1940s")
        #expect(model.masterArchiveCopy(of: rec)?.userDate == "1945")
    }
}

// MARK: - GH #190: the same bytes never land in the archive twice

@Suite("GH #190 — Promote refuses bytes the archive already holds", .serialized)
@MainActor
struct PromoteDuplicateBytesTests {

    typealias H = PromoteIntegrityHarness

    @Test("promote A, then a byte-identical B from another path → B refused, naming A's archived file; no second copy")
    func secondPromoteOfSameBytesRefused() async throws {
        let (sb, model) = try H.setup("190second")
        defer { sb.cleanup() }
        let a = try H.source(sb, model, name: "test_Christmas_1994_etc.mkv", seed: 11)
        let first = try await H.run(model, ids: [a.id])
        #expect(H.outcome(first, a.id)?.kind == .promoted, "\(first.outcomes)")
        let relA = try #require(MasterArchiveTestSupport.archivedFiles(sb).first)

        let b = try H.twin(of: a, sb, model, name: "test_Chrsitmas_1994_misc.mkv")
        let second = try await H.run(model, ids: [b.id])
        let o = try #require(H.outcome(second, b.id))
        #expect(o.kind != .promoted && o.kind != .adopted, "\(o.kind) — \(o.detail)")
        #expect(o.detail.contains(relA), "the refusal names the archived file: \(o.detail)")
        #expect(MasterArchiveTestSupport.archivedFiles(sb) == [relA], "exactly one copy")
        #expect(MasterArchiveTestSupport.manifestRows(sb).count == 1, "exactly one manifest row")
        #expect(ArchivePromoteJournal.latestBySource(rootPath: sb.archiveRoot.path)[b.id] == nil,
                "refused before the journal intent")
        #expect(H.partials(sb).isEmpty)
        #expect(model.masterArchiveCopy(of: b) == nil, "B is not linked to anything")
        #expect(FileManager.default.fileExists(atPath: b.fullPath), "the source is never touched")
    }

    @Test("after a RELAUNCH (no process claims, no catalog link) the 00_Index manifest alone refuses the twin")
    func manifestLegAloneRefuses() async throws {
        let (sb, model) = try H.setup("190relaunch")
        defer { sb.cleanup() }
        let a = try H.source(sb, model, name: "test_tape_a.mov", seed: 17)
        _ = try await H.run(model, ids: [a.id])
        let relA = try #require(MasterArchiveTestSupport.archivedFiles(sb).first)
        // A new process: in-memory claims gone; the catalog lost the copy
        // record too (an unsaved catalog) — only the manifest knows.
        model.promoteDigestClaims = [:]
        model.records.removeAll { model.isArchiveCopy($0) }
        let b = try H.twin(of: a, sb, model, name: "test_tape_b.mov")
        let job = try await H.run(model, ids: [b.id])
        let o = try #require(H.outcome(job, b.id))
        #expect(o.kind == .skipped && o.detail.contains(relA), "\(o.kind) — \(o.detail)")
        #expect(MasterArchiveTestSupport.archivedFiles(sb) == [relA])
        #expect(MasterArchiveTestSupport.manifestRows(sb).count == 1)
    }

    @Test("RACE: two identical files in ONE batch → one lands, the other is refused naming it")
    func sameBatchIdenticalBytes() async throws {
        let (sb, model) = try H.setup("190batch")
        defer { sb.cleanup() }
        let a = try H.source(sb, model, name: "test_tape_a.mov", seed: 12)
        let b = try H.twin(of: a, sb, model, name: "test_tape_b.mov")
        let job = try await H.run(model, ids: [a.id, b.id])
        let files = MasterArchiveTestSupport.archivedFiles(sb)
        #expect(files.count == 1, "\(files)")
        #expect(MasterArchiveTestSupport.manifestRows(sb).count == 1)
        let landed = job.outcomes.filter { $0.kind == .promoted }
        let refused = job.outcomes.filter { $0.kind != .promoted && $0.kind != .adopted }
        #expect(landed.count == 1 && refused.count == 1, "\(job.outcomes)")
        if let rel = files.first { #expect(refused.first?.detail.contains(rel) == true, "\(refused)") }
    }

    @Test("RACE: two Promote JOBS of identical bytes started together → exactly one copy")
    func concurrentJobsIdenticalBytes() async throws {
        let (sb, model) = try H.setup("190jobs")
        defer { sb.cleanup() }
        let a = try H.source(sb, model, name: "test_tape_a.mov", seed: 13, bytes: 3_000_000)
        let b = try H.twin(of: a, sb, model, name: "test_tape_b.mov")
        let j1 = try H.job(model, ids: [a.id])
        let j2 = try H.job(model, ids: [b.id])
        j1.start(); j2.start()
        await j1.task?.value; await j2.task?.value
        await j1.completionTask?.value; await j2.completionTask?.value
        #expect(MasterArchiveTestSupport.archivedFiles(sb).count == 1, "\(MasterArchiveTestSupport.archivedFiles(sb))")
        #expect(MasterArchiveTestSupport.manifestRows(sb).count == 1)
        let kinds = (j1.outcomes + j2.outcomes).map(\.kind)
        #expect(kinds.filter { $0 == .promoted }.count == 1, "\(kinds)")
        #expect(H.partials(sb).isEmpty)
    }

    @Test("the archive's FIXITY data counts too: an archive copy known only to the catalog (no manifest row) blocks its twin")
    func catalogFixityLegRefuses() async throws {
        let (sb, model) = try H.setup("190fixity")
        defer { sb.cleanup() }
        let a = try H.source(sb, model, name: "test_tape_a.mov", seed: 14)
        // An archive file the catalog knows (verified fixity) but the
        // manifest does not list (an older tool, a lost row).
        let rel = "30_Video/1990-1999/1994/1994-xx-xx_Legacy_Tape.mov"
        let dest = sb.archiveRoot.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: a.fullPath, toPath: dest.path)
        let sha = try #require(MasterArchiveTestSupport.sha256(ofFile: dest.path))
        let legacy = MasterArchiveTestSupport.makeRecord(path: dest.path)
        legacy.derivationKind = ArchivePromotion.derivationKind
        legacy.archiveFixity = ArchiveFixity(digest: sha, verifiedAt: Date(), sizeBytes: legacy.sizeBytes)
        model.records.append(legacy)

        let job = try await H.run(model, ids: [a.id])
        let o = try #require(H.outcome(job, a.id))
        #expect(o.kind != .promoted && o.kind != .adopted, "\(o.kind) — \(o.detail)")
        #expect(o.detail.contains(rel), "\(o.detail)")
        #expect(MasterArchiveTestSupport.archivedFiles(sb) == [rel])
        #expect(MasterArchiveTestSupport.manifestRows(sb).isEmpty, "no row appended for a refusal")
    }

    @Test("ISOLATION: a POISONED index (not UTF-8) refuses the whole Promote — nothing copied, nothing appended")
    func poisonedIndexRefuses() async throws {
        let (sb, model) = try H.setup("190poison")
        defer { sb.cleanup() }
        let a = try H.source(sb, model, name: "test_tape_a.mov", seed: 15)
        let h = try FileHandle(forWritingTo: sb.manifestURL)
        try h.seekToEnd()
        try h.write(contentsOf: Data([0xFF, 0xFE, 0x0A]))
        try h.close()
        let before = try Data(contentsOf: sb.manifestURL)
        let job = try await H.run(model, ids: [a.id])
        guard case .failed = job.state else { Issue.record("a poisoned index must refuse: \(job.state) \(job.outcomes)"); return }
        #expect(MasterArchiveTestSupport.archivedFiles(sb).isEmpty)
        #expect(try Data(contentsOf: sb.manifestURL) == before, "the index is never rewritten by a refusal")
    }

    @Test("ISOLATION: another archive's bytes never block this one (claims are per model + root)")
    func otherArchiveDoesNotBlock() async throws {
        let (sb1, m1) = try H.setup("190iso1")
        defer { sb1.cleanup() }
        let (sb2, m2) = try H.setup("190iso2")
        defer { sb2.cleanup() }
        let a = try H.source(sb1, m1, name: "test_tape.mov", seed: 16)
        _ = try await H.run(m1, ids: [a.id])
        let url = sb2.sources.appendingPathComponent("test_tape.mov")
        try FileManager.default.copyItem(atPath: a.fullPath, toPath: url.path)
        let b = MasterArchiveTestSupport.makeRecord(path: url.path)
        m2.records.append(b)
        let job = try await H.run(m2, ids: [b.id])
        #expect(H.outcome(job, b.id)?.kind == .promoted, "\(job.outcomes)")
        #expect(MasterArchiveTestSupport.archivedFiles(sb2).count == 1)
    }

    @Test("SENSOR: a tree with duplicate pairs, promoted in mixed batches twice → one archive file per distinct sha256")
    func sensorOneFilePerDigest() async throws {
        let (sb, model) = try H.setup("190sensor")
        defer { sb.cleanup() }
        var recs: [VideoRecord] = []
        for i in 0..<5 {
            let r = try H.source(sb, model, name: "test_src_\(i).mov", seed: UInt64(100 + i), bytes: 20_000 + i)
            recs.append(r)
            if i % 2 == 0 { recs.append(try H.twin(of: r, sb, model, name: "test_dup_\(i).mov", subfolder: "dups_\(i)")) }
        }
        // Batch 1: every other record; batch 2: all of them; batch 3: all again.
        _ = try await H.run(model, ids: recs.enumerated().filter { $0.offset % 2 == 0 }.map(\.element.id))
        _ = try await H.run(model, ids: recs.map(\.id))
        if let plan = model.buildPromotePlan(recordIDs: recs.map(\.id)), !plan.entries.isEmpty {
            let j = PromoteToArchiveJob(plan: plan, model: model); j.start(); await j.task?.value
        }
        let digests = H.archivedDigests(sb)
        #expect(digests.count == 5, "5 distinct sources → 5 files, got \(digests.count): \(MasterArchiveTestSupport.archivedFiles(sb))")
        #expect(Set(digests).count == digests.count, "no sha256 twice in the archive")
        let rows = MasterArchiveTestSupport.manifestRows(sb)
        #expect(Set(rows.map { $0[ArchiveManifestCSV.sha256Column] }).count == rows.count, "no sha256 twice in the manifest")
        #expect(H.partials(sb).isEmpty)
    }
}

// MARK: - GH #190 media matrix

struct DupMatrixCase: Sendable, CustomStringConvertible {
    let label, filename, size, videoCodec: String
    let audioCodec: String?
    let extra: [String]
    var description: String { label }
}

private let dupMatrix: [DupMatrixCase] = [
    .init(label: "mp4/h264", filename: "test_dup_h264.mp4", size: "320x240", videoCodec: "libx264", audioCodec: "aac", extra: []),
    .init(label: "mov/prores", filename: "test_dup_prores.mov", size: "320x240", videoCodec: "prores", audioCodec: "pcm_s16le", extra: []),
    .init(label: "mkv/ffv1+pcm", filename: "test_dup_ffv1.mkv", size: "320x240", videoCodec: "ffv1", audioCodec: "pcm_s16le", extra: []),
    .init(label: "mxf", filename: "test_dup_x264.mxf", size: "720x576", videoCodec: "libx264", audioCodec: "pcm_s16le", extra: []),
    .init(label: "avi/dv", filename: "test_dup_dv.avi", size: "720x576", videoCodec: "dvvideo", audioCodec: "pcm_s16le", extra: ["-pix_fmt", "yuv420p"]),
]

@Suite("GH #190 — duplicate refusal across the media matrix", .serialized)
@MainActor
struct PromoteDuplicateMediaMatrixTests {

    typealias H = PromoteIntegrityHarness

    @Test("each container: the original lands, its byte-identical twin is refused naming it",
          .timeLimit(.minutes(2)), arguments: dupMatrix)
    func matrix(c: DupMatrixCase) async throws {
        try #require(CleanupTestMedia.toolsAvailable, "ffmpeg/ffprobe are required project dependencies")
        let (sb, model) = try H.setup("190mx")
        defer { sb.cleanup() }
        let src = try CleanupTestMedia.generate(into: sb.sources, name: c.filename, duration: 1.0, size: c.size,
                                                rate: "25", videoCodec: c.videoCodec, extraVideoArgs: c.extra,
                                                audioCodec: c.audioCodec)
        let a = MasterArchiveTestSupport.makeRecord(path: src, userDate: "1994")
        model.records.append(a)
        let b = try H.twin(of: a, sb, model, name: "copy_of_" + c.filename)
        b.userDate = "1994"
        _ = try await H.run(model, ids: [a.id])
        let rel = try #require(MasterArchiveTestSupport.archivedFiles(sb).first)
        let job = try await H.run(model, ids: [b.id])
        let o = try #require(H.outcome(job, b.id))
        #expect(o.kind != .promoted && o.kind != .adopted && o.detail.contains(rel), "\(o.kind) — \(o.detail)")
        #expect(MasterArchiveTestSupport.archivedFiles(sb) == [rel])
        #expect(MasterArchiveTestSupport.manifestRows(sb).count == 1)
    }
}
