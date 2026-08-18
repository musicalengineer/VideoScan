import Foundation
import Testing
@testable import VideoScan

// MARK: - MediaBytes — the one user-facing byte formatter (Rick 2026-08-18)
//
// Finder, `df -H`, and drive labels are DECIMAL. The app used to mix
// base-1024 arithmetic with "GB"/"TB" labels, so a 5.41 TB drive read
// "4.9 TB". These tests pin the decimal base, the requested shape, and
// every unit boundary so the mismatch can't quietly return.
//
// Five-dimension coverage: Logic only — a pure function of one integer.
// No I/O, no shared state, nothing to scale.

@Suite("MediaBytes — decimal units, requested shape")
struct MediaBytesTests {

    // MARK: Base

    /// The whole point: 10^12 bytes is "1.0 TB", not "0.9 TB".
    @Test func decimalNotBinary() {
        #expect(MediaBytes.display(1_000_000_000_000) == "1.0 TB")
        #expect(MediaBytes.display(1_000_000_000) == "1.0 GB")
        #expect(MediaBytes.display(1_000_000) == "1.0 MB")
        #expect(MediaBytes.display(1_000) == "1.0 KB")
        // The old base-1024 constants now read as what Finder shows.
        #expect(MediaBytes.display(1_099_511_627_776) == "1.1 TB")
        #expect(MediaBytes.display(1_073_741_824) == "1.1 GB")
    }

    /// Rick's own example: the LaCie that Finder calls 5.41 TB.
    @Test func matchesFinderForRicksDrive() {
        #expect(MediaBytes.display(5_410_000_000_000) == "5.4 TB")
        // The catalog's real gross figure on 2026-08-18.
        #expect(MediaBytes.display(6_678_702_698_462) == "6.7 TB")
    }

    // MARK: Shape

    @Test func terabytesAlwaysKeepOneDecimal() {
        #expect(MediaBytes.display(6_700_000_000_000) == "6.7 TB")
        #expect(MediaBytes.display(15_000_000_000_000) == "15.0 TB")
        #expect(MediaBytes.display(150_000_000_000_000) == "150.0 TB")
    }

    @Test func gigabytesDropDecimalAtTen() {
        #expect(MediaBytes.display(9_500_000_000) == "9.5 GB")
        #expect(MediaBytes.display(10_000_000_000) == "10 GB")
        #expect(MediaBytes.display(12_000_000_000) == "12 GB")
        #expect(MediaBytes.display(150_400_000_000) == "150 GB")
    }

    /// 9.96 GB rounds to 10 → must read "10 GB", not "10.0 GB".
    @Test func decimalDecisionUsesTheRoundedValue() {
        #expect(MediaBytes.display(9_960_000_000) == "10 GB")
        #expect(MediaBytes.display(9_940_000_000) == "9.9 GB")
    }

    @Test func megabytesAndKilobytesFollowTheSameRule() {
        #expect(MediaBytes.display(2_000_000) == "2.0 MB")
        #expect(MediaBytes.display(12_345_678) == "12 MB")
        #expect(MediaBytes.display(1_500) == "1.5 KB")
        #expect(MediaBytes.display(12_345) == "12 KB")
    }

    @Test func bytesBelowOneKilobyteAreWholeBytes() {
        #expect(MediaBytes.display(0) == "0 B")
        #expect(MediaBytes.display(1) == "1 B")
        #expect(MediaBytes.display(999) == "999 B")
    }

    // MARK: Boundaries

    /// A figure that would ROUND to 1000 promotes to the next unit —
    /// "1.0 TB", never "1000 GB".
    @Test func roundingToOneThousandPromotesTheUnit() {
        #expect(MediaBytes.display(999_950_000_000) == "1.0 TB")
        #expect(MediaBytes.display(999_500_000) == "1.0 GB")
        #expect(MediaBytes.display(999_999) == "1.0 MB")
        // Just below the promotion threshold stays put.
        #expect(MediaBytes.display(999_400_000_000) == "999 GB")
    }

    @Test func exactUnitBoundaries() {
        #expect(MediaBytes.display(999) == "999 B")
        #expect(MediaBytes.display(1_000) == "1.0 KB")
        #expect(MediaBytes.display(999_999_999) == "1.0 GB")
        #expect(MediaBytes.display(1_000_000_000_000_000) == "1.0 PB")
    }

    @Test func negativeKeepsSignAndSurvivesInt64Min() {
        #expect(MediaBytes.display(-2_500_000_000) == "-2.5 GB")
        #expect(MediaBytes.display(Int64.min).hasPrefix("-"))
        #expect(MediaBytes.display(Int64.min).hasSuffix("PB"))
        #expect(MediaBytes.display(Int64.max).hasSuffix("PB"))
    }

    @Test func optionalNilIsADash() {
        let none: Int64? = nil
        #expect(MediaBytes.display(none) == "—")
        let some: Int64? = 2_000_000_000
        #expect(MediaBytes.display(some) == "2.0 GB")
    }

    /// Every user-facing formatter that used to be private now routes
    /// here — pin the two that were base-1024 and visible in the same
    /// window (footer vs volume table) so they can never disagree again.
    @Test func footerAndVolumeTableAgree() {
        let bytes: Int64 = 2_640_000_000_000
        #expect(CatalogStorageTotals.displaySize(bytes) == MediaBytes.display(bytes))
        #expect(Formatting.humanSize(bytes) == MediaBytes.display(bytes))
    }
}
