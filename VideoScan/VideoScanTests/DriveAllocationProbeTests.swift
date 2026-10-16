// DriveAllocationProbeTests.swift
// The pure halves of the Storage tab's allocation table (Rick 2026-10-15):
// which whole disk a volume sits on, the unit's name, % free, the row name.
// No diskutil here — `facts(for:)` is the one system call and is not tested.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Storage — media allocation table (pure)")
struct DriveAllocationProbeTests {

    @Test("an APFS volume's whole disk is its physical store, not its virtual disk")
    func apfsPhysicalStore() {
        let plist: [String: Any] = ["DeviceIdentifier": "disk7s1",
                                    "APFSPhysicalStores": [["APFSPhysicalStore": "disk4s2"]]]
        #expect(DriveAllocationProbe.wholeDisk(fromVolumeInfo: plist) == "disk4")
    }

    @Test("codex 10/15 F1: a container over two physical stores (Fusion) is not one unit — unknown")
    func multiStoreIsNotOnePhysicalUnit() {
        let plist: [String: Any] = ["DeviceIdentifier": "disk7s1",
                                    "APFSPhysicalStores": [["APFSPhysicalStore": "disk4s2"], ["APFSPhysicalStore": "disk5s2"]]]
        #expect(DriveAllocationProbe.wholeDisk(fromVolumeInfo: plist) == nil)
    }

    @Test("codex 10/15 F2: an APFS volume with an empty or malformed store list never falls back to its virtual disk")
    func emptyAPFSStoresNeverUseVirtualDisk() {
        #expect(DriveAllocationProbe.wholeDisk(fromVolumeInfo: ["DeviceIdentifier": "disk7s1", "APFSPhysicalStores": [[String: Any]]()]) == nil)
        #expect(DriveAllocationProbe.wholeDisk(fromVolumeInfo: ["DeviceIdentifier": "disk7s1", "APFSPhysicalStores": [["Nope": "disk4s2"]]]) == nil)
        #expect(DriveAllocationProbe.wholeDisk(fromVolumeInfo: ["DeviceIdentifier": "disk7s1", "APFSPhysicalStores": "disk4s2"]) == nil)
    }

    @Test("codex 10/15 F3: a reachable answer replaces an unreachable one even when its filesystem query failed")
    func reachableFallbackReplacesOfflineFallback() async {
        let path = "/Volumes/test_missing_\(UUID().uuidString)"
        let requests: [DriveAllocationProbe.Request] = [
            .init(label: "FamilyArchive", path: path, mediaTech: .hdd, isReachable: false, capacityTB: 1),
            .init(label: "FamilyArchive", path: path, mediaTech: .ssd, isReachable: true, capacityTB: 8),
        ]
        let facts = await DriveAllocationProbe.facts(for: requests)
        #expect(facts["FamilyArchive"]?.capacityBytes == 8_000_000_000_000)
        #expect(facts["FamilyArchive"]?.typeLabel == VolumeMediaTech.ssd.rawValue)
        // …and an unreachable answer after a reachable one never replaces it.
        let back = await DriveAllocationProbe.facts(for: Array(requests.reversed()))
        #expect(back["FamilyArchive"]?.capacityBytes == 8_000_000_000_000)
    }

    @Test("a plain (HFS / exFAT) volume's whole disk is its own device identifier without the slice")
    func plainVolume() {
        #expect(DriveAllocationProbe.wholeDisk(fromVolumeInfo: ["DeviceIdentifier": "disk5s2"]) == "disk5")
        #expect(DriveAllocationProbe.wholeDisk(fromVolumeInfo: [:]) == nil)
        #expect(DriveAllocationProbe.wholeDisk(fromVolumeInfo: ["APFSPhysicalStores": [[String: Any]]()]) == nil, "an APFS key with no store fails closed")
    }

    @Test("the unit's name drops diskutil's ' Media' suffix and extra spaces")
    func unitName() {
        #expect(DriveAllocationProbe.unitName(fromMediaName: "Promise Pegasus3 R4 Media") == "Promise Pegasus3 R4")
        #expect(DriveAllocationProbe.unitName(fromMediaName: "LaCie  d2 Professional Media ") == "LaCie d2 Professional")
        #expect(DriveAllocationProbe.unitName(fromMediaName: "APPLE SSD AP2048Z") == "APPLE SSD AP2048Z")
        #expect(DriveAllocationProbe.unitName(fromMediaName: "  ") == nil && DriveAllocationProbe.unitName(fromMediaName: nil) == nil)
    }

    @Test("% free is free over capacity; nothing without both")
    func freePercent() {
        var f = DriveAllocationFacts(typeLabel: "HDD", unitName: nil, wholeDisk: nil, capacityBytes: 8_000, freeBytes: 2_000)
        #expect(f.freePercent == 25)
        f.freeBytes = nil
        #expect(f.freePercent == nil)
        f = DriveAllocationFacts(typeLabel: "HDD", unitName: nil, wholeDisk: nil, capacityBytes: 0, freeBytes: 1)
        #expect(f.freePercent == nil)
    }

    @Test("the row name carries the physical unit in parentheses; the home folder reads as this Mac")
    func rowName() {
        let fa = MediaDistributionSlice(name: "FamilyArchive", bytes: 10, files: 1, isOther: false, colorSlot: 0, isReachable: true)
        let pegasus = DriveAllocationFacts(typeLabel: "RAID-5", unitName: "Promise Pegasus3 R4", wholeDisk: "disk4",
                                           capacityBytes: nil, freeBytes: nil)
        #expect(CatalogDistributionPane.rowName(fa, facts: pegasus, host: "RicksM4") == "FamilyArchive (Promise Pegasus3 R4)")
        #expect(CatalogDistributionPane.rowName(fa, facts: nil, host: "RicksM4") == "FamilyArchive (—)", "codex 10/15 F4: an unknown unit is shown as unknown")
        let home = MediaDistributionSlice(name: MediaDistributionCalculator.homeName, bytes: 10, files: 1, isOther: false, colorSlot: 1, isReachable: true)
        #expect(CatalogDistributionPane.rowName(home, facts: nil, host: "RicksM4") == "RicksM4 (system) (—)")
        #expect(!CatalogDistributionPane.hostDisplayName.contains("."))
    }
}
