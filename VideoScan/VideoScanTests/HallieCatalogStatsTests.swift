import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

/// Catalog-wide numbers answered before translation (overnight cycle 2).
struct HallieCatalogStatsTests {

    @Test func recognisesCatalogWideQuestionsAndNothingElse() {
        let cases: [(String, HallieCatalogStats.Question)] = [
            ("how many are archived", .archived),
            ("How many videos have been archived so far?", .archived),
            ("what percentage is archived", .archived),
            ("how many duplicates are there", .duplicates),
            ("how many duplicate files do we have?", .duplicates),
            ("How much disk space does the whole archive take up?", .diskSpace),
            ("how big is the catalog", .diskSpace),
            ("How much footage is there altogether?", .footage),
            ("how many hours of video do we have", .footage),
            ("how many years of footage do we have", .years),
            ("what years does the archive cover", .years),
            ("how many videos do we have", .total),
            ("How many files are in the catalog altogether?", .total),
        ]
        for (text, expected) in cases {
            #expect(HallieCatalogStats.detect(text) == expected, Comment(rawValue: text))
        }
        for text in ["how many videos of donna", "how many videos from 1995", "how many duplicates of this video",
                     "how many videos in westford", "how old is this tape", "show me the archive",
                     "how many videos have all four boys in them", "what's your source"] {
            #expect(HallieCatalogStats.detect(text) == nil, Comment(rawValue: text))
        }
    }

    private func record(_ name: String, bytes: Int64, seconds: Double, year: Int?,
                        fixity: Bool = false, md5: String? = nil) -> VideoRecord {
        let r = VideoRecord()
        r.filename = name
        r.fullPath = "/Volumes/LaCie/\(name)"
        r.sizeBytes = bytes
        r.durationSeconds = seconds
        if let year {
            r.embeddedCreationDate = Calendar.current.date(from: DateComponents(year: year, month: 6, day: 1))
        }
        if let md5 { r.partialMD5 = md5 }
        if fixity {
            r.archiveFixity = ArchiveFixity(digest: "abc", verifiedAt: Date(), sizeBytes: bytes)
        }
        return r
    }

    @Test func computesTheNumbersAndAnswersPlainly() {
        let records = [
            record("a.mov", bytes: 1_000_000_000, seconds: 3600, year: 1991, fixity: true),
            record("b.mov", bytes: 2_000_000_000, seconds: 1800, year: 2005),
            record("c.mov", bytes: 500_000_000, seconds: 600, year: nil),
        ]
        let stats = HallieCatalogStats.compute(records: records)
        #expect(stats.fileCount == 3)
        #expect(stats.archivedVerified == 1)
        #expect(stats.totalDurationSeconds == 6000)
        #expect(stats.earliestYear == 1991)
        #expect(stats.latestYear == 2005)

        #expect(HallieCatalogStats.answer(.years, stats: stats).prose
                == "The footage runs from 1991 to 2005 — about 15 years of the family's life. (Undated files aren't counted here.)")
        #expect(HallieCatalogStats.answer(.footage, stats: stats).prose.hasPrefix("About 1.7 hours of footage altogether, in 3 files"))
        let archived = HallieCatalogStats.answer(.archived, stats: stats)
        #expect(archived.prose.hasPrefix("1 file has a verified copy in the Master Archive — "))
        #expect(archived.route == .aggregate)
        #expect(archived.outcome == .answered)
        #expect(archived.answerPlan?.isComposable == false, "numbers are never re-phrased by the model")
        #expect(HallieCatalogStats.answer(.total, stats: stats).prose.hasPrefix("There are 3 media files in the catalog"))
        #expect(HallieCatalogStats.answer(.diskSpace, stats: stats).prose.hasPrefix("Everything in the catalog takes up"))
    }

    @Test func emptyCatalogAnswersHonestly() {
        let stats = HallieCatalogStats.compute(records: [])
        #expect(HallieCatalogStats.answer(.total, stats: stats).prose == "The catalog is empty right now.")
        #expect(HallieCatalogStats.answer(.years, stats: stats).prose.hasPrefix("I can't put years to the footage yet"))
        #expect(HallieCatalogStats.answer(.archived, stats: stats).prose.hasPrefix("Nothing has a verified copy"))
    }

    @Test func preTranslationAnswersLocallyOnlyWhenTheSnapshotIsSupplied() {
        let stats = HallieCatalogStats.compute(records: [record("a.mov", bytes: 10, seconds: 10, year: 1999)])
        let withStats = HallieTurnExecutor.preTranslation(
            question: "how many are archived", playAfterAnswer: false,
            memory: .init(), isKnownPerson: { _ in false }, catalogStats: stats)
        guard case .answer(let result) = withStats else { Issue.record("should answer locally"); return }
        #expect(result.queryDescription == "catalog-stats archived")

        let without = HallieTurnExecutor.preTranslation(
            question: "how many are archived", playAfterAnswer: false,
            memory: .init(), isKnownPerson: { _ in false })
        guard case .translate = without else { Issue.record("without a snapshot it must fall through"); return }
    }

    @Test func hundredThousandRecordsComputeWithinBudget() {
        let records = (0..<100_000).map { i in
            record("f\(i).mov", bytes: 1_000_000, seconds: 60, year: 1980 + (i % 40), fixity: i % 50 == 0)
        }
        let start = Date()
        let stats = HallieCatalogStats.compute(records: records)
        let elapsed = Date().timeIntervalSince(start)
        #expect(stats.fileCount == 100_000)
        #expect(stats.archivedVerified == 2_000)
        #expect(elapsed < 3.0, "took \(elapsed)s")
    }
}
