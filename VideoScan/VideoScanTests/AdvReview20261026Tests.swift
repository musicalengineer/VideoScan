// AdvReview20261026Tests.swift
// Regression pins for the 2026-10-26 nightly adversarial review
// (docs/reviews/adversarial/2026-10-26.md), P2 F1 (MOPS-6): a Migrate where
// nothing was copied (or any file is left unproven) still said "Your files
// are safe … you can retire <drive>". F2 (⌘⌫) is in
// AdvReview20261026TrashTests.swift.

import Foundation
import Testing
@testable import VideoScan

@Suite struct RelocateSummaryAllSafeHeadlineTests {

    /// The headline's words moved from the sheet's private properties into
    /// `RelocateSummaryHeadline.init` (RelocateSummary.swift) with the fix;
    /// the reviewer's check follows them there so it can never pass vacuously.
    static var sheetFile: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VideoScan/MediaOps/RelocateSummary.swift")
    }

    /// The code of the property starting at `start`, up to `end`, comment
    /// lines dropped; nil when `end` is no longer there (the words are gone).
    static func codeBefore(_ end: String, inPropertyStarting start: String, of text: String) throws -> String? {
        let s = try #require(text.range(of: start), "\(start) not found")
        guard let e = text.range(of: end, range: s.upperBound..<text.endIndex) else { return nil }
        return text[s.upperBound..<e.lowerBound]
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    @Test func allSafeWordsAskAboutFailedAndUnmatchedFiles() throws {
        let text = try String(contentsOf: Self.sheetFile, encoding: .utf8)
        let checks = [
            ("init(_ s: RelocateSummary) {", "title = \"Your files are safe\""),
            ("init(_ s: RelocateSummary) {", "Everything's accounted for"),
        ]
        for (start, end) in checks {
            let code = try #require(try Self.codeBefore(end, inPropertyStarting: start, of: text),
                                    "\(end) not found after \(start) — move this check with the words")
            let asksEachCount = code.contains("salvageFailedCount") && code.contains("stillThereCount")
                && code.contains("notMarkedCount")
            let asksAPredicate = code.contains("ccountedFor") || code.contains("eedsAttention") || code.contains("llSafe")
            #expect(asksEachCount || asksAPredicate,
                    "\(start) reaches \(end) without asking whether a file failed to copy, was left at its path or was not marked")
        }
    }
}

/// The headline's words as a pure value of the summary: "safe" and
/// "retire" appear only when every file was copied-and-verified or has a
/// checksum-verified copy on a safe drive.
@Suite struct RelocateSummaryHeadlineTests {

    static func summary(dryRun: Bool = false, copied: Int = 0, backedUp: Int = 0, degraded: Int = 0,
                        salvageFailed: Int = 0, notMarked: Int = 0, stillThere: Int = 0,
                        adopted: Int = 0) -> RelocateSummary {
        RelocateSummary(
            isDryRun: dryRun, sourceVolumeName: "OldDrive", sourceVolumeRootPath: "/Volumes/OldDrive",
            destinationDisplay: "Workspace/from-OldDrive", destinationRootPath: "/Volumes/Workspace/from-OldDrive",
            succeededCount: copied, bytesCopied: Int64(copied) * 1_000, adoptedCount: adopted,
            safelyRedundantCount: backedUp + degraded, safelyRedundantBytes: 0,
            sourceMovesCount: 0, manuallyDeletedCount: 0, salvageFailedCount: salvageFailed, skippedCount: 0,
            safelyBackedUpCount: backedUp, degradedOnlyCount: degraded,
            salvageFailedPaths: [], witnessSamples: [], elapsedSeconds: 1, averageMBps: 0, snapshotPath: nil,
            notMarkedCount: notMarked, stillThereCount: stillThere)
    }

    static func saysSafeOrRetire(_ h: RelocateSummaryHeadline) -> Bool {
        let words = (h.title + " " + h.body).lowercased()
        return words.contains("safe") && !words.contains("not safe") || words.contains("retire")
            || words.contains("accounted for") || h.invitesRetire
    }

    /// The finding's own example: nothing copied, 37 backed up, 3 failed.
    @Test func nothingCopiedAndThreeFailedNeverSaysSafeOrRetire() {
        let h = RelocateSummaryHeadline(Self.summary(backedUp: 37, salvageFailed: 3))
        #expect(!Self.saysSafeOrRetire(h), "\(h)")
        #expect(h.tint == .orange)
        #expect(h.body.contains("No files were copied"), "\(h.body)")
        #expect(h.body.contains("3 files are not safe yet"), "\(h.body)")
        #expect(h.body.contains("Keep OldDrive"), "\(h.body)")
    }

    /// Every unproven bucket on its own withholds the safe/retire words —
    /// with or without copies.
    @Test(arguments: [
        (0, 0, 0, 1), (0, 0, 1, 0), (0, 1, 0, 0), (1, 0, 0, 0),
    ])
    func eachUnprovenBucketWithholdsSafeAndRetire(_ counts: (Int, Int, Int, Int)) {
        let (failed, notMarked, stillThere, degraded) = counts
        for copied in [0, 4] {
            let h = RelocateSummaryHeadline(Self.summary(copied: copied, backedUp: 2, degraded: degraded,
                                                         salvageFailed: failed, notMarked: notMarked,
                                                         stillThere: stillThere))
            #expect(!Self.saysSafeOrRetire(h), "copied \(copied), counts \(counts): \(h)")
            #expect(h.title == "Some files are not safe yet")
            #expect(h.body.contains("1 file is not safe yet"), "\(h.body)")
        }
    }

    /// Nothing copied and nothing backed up: no proof happened this run, so
    /// no "safe" and no retire line.
    @Test func nothingCopiedNothingBackedUpIsNotSafe() {
        let h = RelocateSummaryHeadline(Self.summary(adopted: 2))
        #expect(!Self.saysSafeOrRetire(h), "\(h)")
        #expect(h.title == "Nothing was copied")
    }

    /// The truly all-safe and copied-and-verified runs keep their words.
    @Test func provenRunsKeepTheirWords() {
        let allSafe = RelocateSummaryHeadline(Self.summary(backedUp: 37))
        #expect(allSafe.title == "Your files are safe" && allSafe.invitesRetire)
        #expect(allSafe.body.contains("Everything's accounted for — you can retire OldDrive"))
        let mixed = RelocateSummaryHeadline(Self.summary(copied: 3, backedUp: 1))
        #expect(mixed.title == "Files copied and verified" && mixed.invitesRetire)
        let dry = RelocateSummaryHeadline(Self.summary(dryRun: true, salvageFailed: 2))
        #expect(dry.title == "Dry-run preview" && !dry.invitesRetire)
    }
}
