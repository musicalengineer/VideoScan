import Foundation
import Testing
@testable import VideoScan

// Storage tab "Catalog" pane (Rick 2026-08-19): tier policy + tier totals.
// Logic + Isolation (pure); scale is covered by the two calculators this
// composes (MediaDistributionTests, VolumeDashboardTests).

@Suite("Storage tier policy")
struct StorageTierTests {
    private func tier(role: VolumeRole = .workspace, trust: VolumeTrust = .reliable,
                      media: VolumeMediaTech = .ssd, retired: Bool = false,
                      master: Bool = false, boot: Bool = false) -> StorageTier {
        StorageTier.tier(role: role, trust: trust, mediaTech: media,
                         isRetired: retired, isMasterArchive: master, isBootVolume: boot)
    }

    @Test func ladder() {
        #expect(tier(media: .raid5, master: true) == .safe)
        #expect(tier(media: .raid1) == .safe)
        #expect(tier(role: .cloud, media: .cloud) == .safe)
        #expect(tier(media: .hdd) == .hdd)
        #expect(tier(media: .network) == .hdd)
        #expect(tier(media: .ssd) == .ssd)
        #expect(tier(media: .unknown, boot: true) == .ssd)
        #expect(tier(media: .unknown) == .atRisk)
        #expect(tier(media: .raid0) == .atRisk)                 // fragile trumps new
        #expect(tier(trust: .aging, media: .raid5, master: true) == .atRisk)   // trust trumps master
        #expect(tier(media: .raid5, retired: true) == .atRisk)  // retired trumps everything
        #expect(StorageTier.safe < StorageTier.atRisk)
    }
}

@Suite("Catalog distribution — tier totals")
struct CatalogDistributionCalculatorTests {
    @Test func tierTotalsCoverEveryNonRetiredRecord() {
        let GB: Int64 = 1_073_741_824
        let rows = [
            MediaDistributionInput(fullPath: "/Volumes/FamilyArchive/a.mov", sizeBytes: 4 * GB),
            MediaDistributionInput(fullPath: "/Volumes/X9/b.mov", sizeBytes: 2 * GB),
            MediaDistributionInput(fullPath: "/Volumes/Mystery/c.mov", sizeBytes: 1 * GB),   // not in drive list
            MediaDistributionInput(fullPath: "/Volumes/OldDrive/d.mov", sizeBytes: 8 * GB),  // retired
            MediaDistributionInput(fullPath: "/Volumes/X9/gone.mov", sizeBytes: 16 * GB, isManuallyDeleted: true),
        ]
        let inputs = CatalogDistributionCalculator.Inputs(
            distribution: MediaDistributionCachedInputs(
                inputs: rows, retiredPrefixes: ["/Volumes/OldDrive"],
                reachableVolumes: ["FamilyArchive", "X9"], knownVolumes: ["FamilyArchive", "X9"]),
            dashboard: [],
            tierByDrive: ["FamilyArchive": .safe, "X9": .ssd])
        let s = CatalogDistributionCalculator.compute(inputs)
        #expect(s.totalBytes == 7 * GB)
        #expect(s.totalFiles == 3)
        #expect(s.tierBytes[.safe] == 4 * GB)
        #expect(s.tierBytes[.ssd] == 2 * GB)
        #expect(s.tierBytes[.atRisk] == 1 * GB)        // unknown drive → at risk
        #expect(s.tierBytes[.hdd] == nil)
        #expect(s.byDrive.retiredBytes == 8 * GB)
        #expect(abs(s.tierPercent(.safe, by: .size) - 57.14) < 0.1)
        let x9 = s.byDrive.slices.first { $0.name == "X9" }!
        #expect(s.tier(of: x9) == .ssd)
    }
}

@Suite("Catalog verdict phrases")
struct CatalogVerdictTests {
    private func stats(shares: [Int64], safe: Int64, risk: Int64, singleCopyPct: Int64 = 0) -> CatalogDistributionStats {
        var s = CatalogDistributionStats()
        s.byDrive.slices = shares.enumerated().map { i, b in
            MediaDistributionSlice(name: "D\(i)", bytes: b, files: 1, isOther: false, colorSlot: i, isReachable: true)
        }
        s.totalBytes = shares.reduce(0, +)
        s.driveCount = shares.count
        s.tierBytes = [.safe: safe, .atRisk: risk, .ssd: max(0, s.totalBytes - safe - risk)]
        s.copies = VolumeDashboardSeries(slices: [
            VolumeDashboardSlice(name: VolumeDashboardCalculator.copiesLabel(0), bytes: s.totalBytes * singleCopyPct / 100, files: 1, colorSlot: nil, fixedColor: .red),
            VolumeDashboardSlice(name: VolumeDashboardCalculator.copiesLabel(2), bytes: s.totalBytes * (100 - singleCopyPct) / 100, files: 1, colorSlot: nil, fixedColor: .green),
        ], totalBytes: s.totalBytes, totalFiles: 2)
        return s
    }

    @Test func phrases() {
        let concentrated = CatalogVerdict.make(stats(shares: [90, 5, 5], safe: 90, risk: 0))
        #expect(concentrated.distribution == "Most of it on one drive")
        #expect(concentrated.safety == "Mostly safe")
        #expect(concentrated.suggestion.hasPrefix("Nothing urgent"))

        let two = CatalogVerdict.make(stats(shares: [50, 35, 15], safe: 50, risk: 15))
        #expect(two.distribution == "Mostly on two drives")
        #expect(two.safety == "Partially safe")
        #expect(two.suggestion.hasPrefix("Move the"))           // risk ≥ 10 wins

        let spread = CatalogVerdict.make(stats(shares: [30, 30, 20, 20], safe: 20, risk: 0, singleCopyPct: 40))
        #expect(spread.distribution == "Well spread across 4 drives")
        #expect(spread.safety == "Mostly unprotected")
        #expect(spread.suggestion.contains("only one place"))
    }
}
