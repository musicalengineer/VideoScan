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
