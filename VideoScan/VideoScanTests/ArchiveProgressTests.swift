import Foundation
import Testing
@testable import VideoScan

/// The Archive tab's progress bar: verified ÷ unique, honest at the edges
/// (Rick 2026-08-21: "shows say 5% of files promoted to archive").
struct ArchiveProgressTests {

    @Test func fivePercentReadsAsFivePercent() {
        let p = ArchiveProgress(verified: 300, unverified: 0, uniqueTotal: 6_000)
        #expect(p.percentText == "5%")
        #expect(p.remaining == 5_700)
        #expect(p.headline == "5% of the family's 6,000 unique media files are safely archived")
        #expect(p.detail == "300 verified · 5,700 to go")
        #expect(abs(p.verifiedFraction - 0.05) < 0.0001)
    }

    @Test func unverifiedCopiesAreTheirOwnSegmentAndNeverCountAsDone() {
        let p = ArchiveProgress(verified: 2, unverified: 6, uniqueTotal: 100,
                                verifiedBytes: 50_000_000_000, uniqueBytes: 2_000_000_000_000)
        #expect(p.percentText == "2%")
        #expect(p.remaining == 92)
        #expect(abs(p.unverifiedFraction - 0.06) < 0.0001)
        #expect(p.detail.contains("6 copied, not yet verified"))
        #expect(p.detail.contains("verified"))
    }

    @Test func neverShowsAFalseZeroOrAFalseFinish() {
        #expect(ArchiveProgress(verified: 1, unverified: 0, uniqueTotal: 7_000).percentText == "<1%",
                "one verified file is not 0%")
        #expect(ArchiveProgress(verified: 6_999, unverified: 0, uniqueTotal: 7_000).percentText == ">99%",
                "one file to go is not 100%")
        #expect(ArchiveProgress(verified: 7_000, unverified: 0, uniqueTotal: 7_000).percentText == "100%")
        #expect(ArchiveProgress(verified: 0, unverified: 0, uniqueTotal: 0).percentText == "0%")
        #expect(ArchiveProgress(verified: 0, unverified: 0, uniqueTotal: 0).headline == "Nothing to archive yet")
    }

    @Test func archivedJunkCannotPushTheBarPastFull() {
        // The unique count excludes junk; a promoted junk file would
        // otherwise make verified > total.
        let p = ArchiveProgress(verified: 12, unverified: 1, uniqueTotal: 10)
        #expect(p.total == 13)
        #expect(p.remaining == 0)
        #expect(p.verifiedFraction <= 1)
        #expect(p.percentText == "92%", "12 of 13 — the unverified copy is not done")
    }

    @Test func negativeInputsAreClampedNotTrusted() {
        let p = ArchiveProgress(verified: -3, unverified: -1, uniqueTotal: -10)
        #expect(p.total == 0)
        #expect(p.percentText == "0%")
    }

    @Test func combinesTheMasterArchiveTotalsWithTheUniqueCount() {
        var storage = CatalogStorageTotals()
        storage.uniqueFileCount = 5_877
        storage.uniqueBytes = 3_000_000_000_000
        let totals = ArchivePromotionIndex.Totals(verified: 8, verifiedBytes: 190_000_000_000, unverified: 0)
        let p = ArchiveProgress.from(totals: totals, storage: storage)
        #expect(p.verified == 8)
        #expect(p.uniqueTotal == 5_877)
        #expect(p.percentText == "<1%")
        #expect(p.detail == "8 verified · 5,869 to go · 190 GB of 3 TB verified"
                || p.detail.hasPrefix("8 verified · 5,869 to go · "))
    }
}
