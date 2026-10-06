// ArchiveReconcilePinningTests.swift
// Pinning tests from cloud review N1008-T-Archive (verified by local qa
// 2026-10-06) for three Archive write-path guards that no assertion
// covered — deleting any of them used to ship silently:
//   F2  reconcile indexes a journaled destination ONLY when its on-disk
//       digest equals the trusted digest (PromoteToArchiveJob+Steps
//       `guard let expected, actual == expected`);
//   F4  ArchiveManifestCSV.append refuses a manifest whose first line is
//       not a recognized header (`expectedHeaders:` on the append leg,
//       not just `validate`);
//   F5  reconcile of an `intent` with no final file removes the stale
//       `.partial` and closes the intent as `abandoned`.
// Every fixture is a synthetic temp-dir sandbox (MasterArchiveTestSupport)
// — never App Support, never real media.

import Foundation
import Testing
@testable import VideoScan

@Suite("Archive — N1008 reconcile & manifest pinning", .serialized)
@MainActor
struct ArchiveReconcilePinningTests {

    /// A 64 KiB source plus its catalog record dated 1999, in a fresh,
    /// initialized sandbox archive.
    private func rig(_ label: String) throws -> (MasterArchiveTestSupport.Sandbox, VideoScanModel, VideoRecord, URL) {
        let sb = try MasterArchiveTestSupport.makeSandbox(label)
        let src = try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent("test_src_0.mov"),
                                                         bytes: 64 * 1024, seed: 1)
        let model = MasterArchiveTestSupport.makeModel(sb)
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let rec = MasterArchiveTestSupport.makeRecord(path: src.path, userDate: "1999")
        model.records = [rec]
        return (sb, model, rec, src)
    }

    private static let plantedRel = "30_Video/1990-1999/1999/1999-xx-xx_test_src_0.mov"

    // MARK: F2 — reconcile confirms the digest before indexing

    /// A journaled destination holding DIFFERENT bytes (same size — a
    /// truncated-then-padded copy, a file dropped in by hand) must never be
    /// indexed as the source's archive copy, whatever the journal claims.
    @Test("N1008-F2: journal 'renamed' with sha(source) + same-size DIFFERENT bytes at the destination → not indexed, not linked, bytes untouched",
          arguments: [true, false])
    func reconcileRefusesADestinationWithOtherBytes(journalCarriesSHA: Bool) async throws {
        let (sb, model, rec, src) = try rig("n1008_f2_\(journalCarriesSHA)")
        defer { sb.cleanup() }
        let sourceSHA = try #require(MasterArchiveTestSupport.sha256(ofFile: src.path))
        let planted = sb.archiveRoot.appendingPathComponent(Self.plantedRel)
        try FileManager.default.createDirectory(at: planted.deletingLastPathComponent(), withIntermediateDirectories: true)
        try MasterArchiveTestSupport.writeBlob(at: planted, bytes: 64 * 1024, seed: 99)   // same size, other bytes
        let plantedBytes = try Data(contentsOf: planted)
        #expect(MasterArchiveTestSupport.sha256(ofFile: planted.path) != sourceSHA, "fixture: bytes must differ")
        // Case true: the journal names the source's digest (renamed). Case
        // false: an intent with no digest, source present — reconcile must
        // hash the source and still find the mismatch.
        try ArchivePromoteJournal.append(.init(sourceRecordID: rec.id, sourcePath: src.path, destRelPath: Self.plantedRel,
                                               state: journalCarriesSHA ? .renamed : .intent,
                                               sha256: journalCarriesSHA ? sourceSHA : nil,
                                               copyRecordID: nil, at: Date()),
                                         rootPath: sb.archiveRoot.path)

        let job = try #require(await MasterArchiveTestSupport.promote(model, ids: [rec.id]))
        guard case .finished = job.state else { Issue.record("promote did not finish: \(job.state)"); return }

        let rows = MasterArchiveTestSupport.manifestRows(sb)
        #expect(!rows.contains { $0[ArchiveManifestCSV.relPathColumn] == Self.plantedRel },
                "the planted file was indexed as an archive copy: \(rows.map { $0[ArchiveManifestCSV.relPathColumn] })")
        #expect(model.masterArchiveCopy(of: rec)?.fullPath != planted.path,
                "the source is linked to a file whose bytes are not its own")
        MasterArchiveTestSupport.unlockTree(sb.root)
        #expect(try Data(contentsOf: planted) == plantedBytes, "the planted file was changed")
        // Every row the run DID write names bytes that match it.
        for row in rows {
            let path = sb.archiveRoot.appendingPathComponent(row[ArchiveManifestCSV.relPathColumn]).path
            #expect(MasterArchiveTestSupport.sha256(ofFile: path) == row[ArchiveManifestCSV.sha256Column])
        }
    }

    // MARK: F4 — the append leg checks the header itself

    @Test("N1008-F4: ArchiveManifestCSV.append on a header-less manifest throws, and the file is byte-identical")
    func appendRefusesAHeaderlessManifest() throws {
        let (sb, _, rec, src) = try rig("n1008_f4")
        defer { sb.cleanup() }
        let foreign = Data("not,a,header\n".utf8)
        try foreign.write(to: sb.manifestURL)
        let row = ArchiveManifestCSV.Row(promotedAt: Date(), archiveRelPath: Self.plantedRel, sha256: "s", sizeBytes: 1,
                                         originalPath: src.path, originalVolume: "v", recordID: UUID(),
                                         sourceRecordID: rec.id, recordDate: "", dateConfidence: "", people: [], starRating: 3)
        // (Swift Testing: `#expect(throws: T.self) { … }` ≈ gtest EXPECT_THROW(stmt, T).)
        #expect(throws: ArchivePromoteEngine.Failure.self) { try ArchiveManifestCSV.append(row, rootPath: sb.archiveRoot.path) }
        #expect(try Data(contentsOf: sb.manifestURL) == foreign, "a row was appended to a manifest without a header")
    }

    // MARK: F5 — crash-leftover partial cleanup

    @Test("N1008-F5: journal 'intent' + <dest>.partial + no final file → an empty-plan Promote removes the partial and closes the intent as abandoned")
    func reconcileRemovesAStalePartialAndAbandonsTheIntent() async throws {
        let (sb, model, rec, src) = try rig("n1008_f5")
        defer { sb.cleanup() }
        let dest = sb.archiveRoot.appendingPathComponent(Self.plantedRel)
        let partial = URL(fileURLWithPath: dest.path + ".partial")
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: 4096).write(to: partial)
        try ArchivePromoteJournal.append(.init(sourceRecordID: rec.id, sourcePath: src.path, destRelPath: Self.plantedRel,
                                               state: .intent, sha256: nil, copyRecordID: nil, at: Date()),
                                         rootPath: sb.archiveRoot.path)
        #expect(ArchivePromoteJournal.latestBySource(rootPath: sb.archiveRoot.path)[rec.id]?.state == .intent, "fixture")

        let job = try #require(await MasterArchiveTestSupport.promote(model, ids: []))
        #expect(job.plan.entries.isEmpty, "fixture: the plan must be empty — only reconcile may act")
        guard case .finished = job.state else { Issue.record("promote did not finish: \(job.state)"); return }

        #expect(!FileManager.default.fileExists(atPath: partial.path), "the crash-leftover partial is still there")
        #expect(!FileManager.default.fileExists(atPath: dest.path), "reconcile must not create the destination")
        #expect(ArchivePromoteJournal.latestBySource(rootPath: sb.archiveRoot.path)[rec.id]?.state == .abandoned,
                "the intent was not closed")
        #expect(MasterArchiveTestSupport.manifestRows(sb).isEmpty)
    }
}
