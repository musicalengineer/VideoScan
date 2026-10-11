// ShowAgainDeleteDuplicatesTests.swift
// The delete-safety boundary after "Show these files again": showing a file
// again puts it back in the Delete Duplicates pool. That is only safe because
// Delete Duplicates proves the surviving copy in full at the moment of
// deletion. Pinned here end to end, after a real repair run:
//   * a shown-again file whose only "twin" is a labelled record with NO file
//     (one of the 9 missing) — never removed: there is no surviving copy;
//   * a shown-again file whose catalog twin has the same size and partial
//     MD5 but DIFFERENT bytes — never removed ("content differs");
//   * positive control: a shown-again file that IS a byte-identical copy of
//     a present keeper with a verified family — moved to the (test-host)
//     Trash, proving the pool really includes repaired files and the
//     refusals above are the proof talking, not an empty pool.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Show again — Delete Duplicates still refuses a sole copy", .serialized)
@MainActor
struct ShowAgainDeleteDuplicatesTests {

    @Test("after the repair, a sole copy is never removed; a proven copy still is")
    func soleCopyNeverRemoved() async throws {
        let sb = try ShowAgainSandbox.make("dd"); defer { sb.cleanup() }
        let model = sb.model
        func group(_ r: VideoRecord, _ g: UUID, _ d: DuplicateDisposition, md5: String) {
            r.duplicateGroupID = g; r.duplicateDisposition = d; r.duplicateConfidence = .high
            r.partialMD5 = md5; r.durationSeconds = 61
        }
        // 1. Sole copy: its twin is labelled AND missing.
        let sole = try sb.record("AVCHD_00042.MTS", bytes: 6_000)
        let ghost = try sb.record("AVCHD_00042 twin.MTS", bytes: 6_000, onDisk: false)
        let g1 = UUID()
        group(ghost, g1, .keep, md5: "m1"); group(sole, g1, .extraCopy, md5: "m1")
        // 2. Same size + partial MD5, different bytes.
        let lookalike = try sb.record("Clip 03.dv", bytes: 7_000)
        let different = try sb.record("Clip 03 other.dv", bytes: 7_000, stage: .none)
        try Data(repeating: 0x5A, count: 7_000).write(to: URL(fileURLWithPath: different.fullPath))
        let g2 = UUID()
        group(different, g2, .keep, md5: "m2"); group(lookalike, g2, .extraCopy, md5: "m2")
        // 3. Positive control: a byte-identical copy of a present keeper.
        let keeper = try sb.record("Thanksgiving2009.mov", bytes: 8_000, stage: .none)
        let copy = try sb.record("Thanksgiving2009 copy.mov", bytes: 8_000)
        try Data(contentsOf: URL(fileURLWithPath: keeper.fullPath)).write(to: URL(fileURLWithPath: copy.fullPath))
        let g3 = UUID()
        group(keeper, g3, .keep, md5: "m3"); group(copy, g3, .extraCopy, md5: "m3")
        addVerifiedArchiveFamily(to: model, keeper: keeper, in: sb.files)

        // The repair: sole, lookalike and copy are shown again; ghost stays.
        let reviewed = await model.showAgainReview(disk: ShowAgainSandbox.onlineRealStat)
        let run = await model.applyShowAgain(reviewed: reviewed, disk: ShowAgainSandbox.onlineRealStat)
        try #require(run.outcome == .shown, "\(run.outcome)")
        try #require(Set(run.shown.map(\.id)) == [sole.id, lookalike.id, copy.id], "\(run.shown.map(\.filename))")
        try #require(ghost.archiveStage == .manuallyDeleted)

        let result = await model.deleteDuplicates(onVolume: sb.files.path)

        #expect(FileManager.default.fileExists(atPath: sole.fullPath), "a sole copy was removed")
        #expect(FileManager.default.fileExists(atPath: lookalike.fullPath), "a file with different bytes was removed")
        #expect(!FileManager.default.fileExists(atPath: copy.fullPath), "positive control: the proven copy goes")
        #expect(FileManager.default.fileExists(atPath: keeper.fullPath))
        #expect(result.deleted == 1, "\(result)")
    }
}
