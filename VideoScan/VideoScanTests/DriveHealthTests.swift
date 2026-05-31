//
//  DriveHealthTests.swift
//  VideoScanTests
//
//  Pure-Swift tests for DriveHealth. The probe's `parseSmartctlJSON`,
//  `parseSystemProfilerNVMe`, and recommendation heuristic are
//  nonisolated statics and pure functions, so we exercise them without
//  spawning subprocesses. JSON fixtures live alongside this file under
//  `Fixtures/smartctl_*.json` and were captured from Rick's machine,
//  with serial numbers redacted.
//

import XCTest
@testable import VideoScan

final class DriveHealthTests: XCTestCase {

    // MARK: - Fixture loading

    private func fixturesDir(from filePath: String = #filePath) -> URL {
        URL(fileURLWithPath: filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
    }

    private func loadFixture(_ name: String) throws -> String {
        let url = fixturesDir().appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Parser tests

    func test_driveHealthProbe_parsesSmartctlJsonForHDD() throws {
        let json = try loadFixture("smartctl_hdd_seagate_ironwolf.json")
        let snapshot = DriveHealthProbe.parseSmartctlJSON(
            json,
            mountPath: "/Volumes/LaCieWorkspace",
            devicePath: "/dev/disk4",
            protocolKind: .sata,
            mediaTechHint: .hdd,
            exitCode: 0,
            priorWarnings: []
        )
        XCTAssertNotNil(snapshot)
        guard let snap = snapshot else { return }
        XCTAssertEqual(snap.modelName, "ST8000NE0021-2EN112")
        XCTAssertEqual(snap.serialNumber, "REDACTED-HDD-001")
        XCTAssertEqual(snap.firmware, "EN02")
        XCTAssertEqual(snap.capacityBytes, 8_001_563_222_016)
        XCTAssertEqual(snap.mediaTech, .hdd, "rotation_rate > 0 → HDD")
        XCTAssertEqual(snap.smartStatus, .passed)
        XCTAssertEqual(snap.powerOnHours, 95)
        XCTAssertEqual(snap.temperatureCelsius, 33)
        // Reallocated/pending/offline_uncorrectable attributes should
        // have parsed even if their raw values are zero on a healthy
        // drive.
        XCTAssertNotNil(snap.reallocatedSectors,
                        "Should have found id 5 in the SMART attribute table.")
        XCTAssertEqual(snap.reallocatedSectors, 0)
    }

    func test_driveHealthProbe_parsesSmartctlJsonForNvme() throws {
        let json = try loadFixture("smartctl_nvme_apple.json")
        let snapshot = DriveHealthProbe.parseSmartctlJSON(
            json,
            mountPath: "/",
            devicePath: "/dev/disk0",
            protocolKind: .nvmeInternal,
            mediaTechHint: .nvme,
            // exit_status 4 is the "couldn't read error log" partial,
            // still has parseable JSON.
            exitCode: 4,
            priorWarnings: []
        )
        XCTAssertNotNil(snapshot)
        guard let snap = snapshot else { return }
        XCTAssertEqual(snap.modelName, "APPLE SSD AP1024Z")
        XCTAssertEqual(snap.serialNumber, "REDACTED-NVME-001")
        XCTAssertEqual(snap.mediaTech, .nvme)
        XCTAssertEqual(snap.smartStatus, .passed)
        XCTAssertEqual(snap.ssdAvailableSpare, 100)
        XCTAssertEqual(snap.ssdPercentageUsed, 2)
        XCTAssertEqual(snap.ssdMediaErrors, 0)
        XCTAssertEqual(snap.powerOnHours, 527)
        XCTAssertEqual(snap.temperatureCelsius, 27)
        // exit_status 4 should produce a soft warning about partial
        // data (the bit-6 carve-out is for log read errors only; 4 is
        // something else).
        XCTAssertTrue(snap.probeWarnings.contains { $0.contains("hiccup") || $0.contains("partial") },
                      "Non-trivial non-zero exit should surface a warning.")
    }

    func test_driveHealthProbe_handlesNonZeroExitGracefully_returnsSnapshotWithWarning() {
        // Garbage stdout — parser fails entirely. The probe path
        // synthesizes a snapshot with a warning; we simulate that
        // path through the friendly-failure helper.
        let warning = DriveHealthProbe.friendlySmartctlFailure(
            exitCode: 2,
            stderr: "",
            protocolKind: .sata
        )
        XCTAssertFalse(warning.lowercased().contains("exit_status"),
                       "Friendly warning must not leak smartctl jargon.")
        XCTAssertTrue(warning.contains("Drive") || warning.contains("drive"))
    }

    func test_driveHealthProbe_handlesMissingSmartSupport_returnsSnapshotWithWarning() {
        let warning = DriveHealthProbe.friendlySmartctlFailure(
            exitCode: 1,
            stderr: "",
            protocolKind: .usb
        )
        XCTAssertTrue(warning.contains("USB"),
                      "USB bridge case should mention USB specifically.")
        XCTAssertFalse(warning.contains("SMART attribute"),
                       "No SMART-attribute jargon.")
    }

    // MARK: - Recommendation heuristic

    private func makeHDD(realloc: Int? = nil,
                         pending: Int? = nil,
                         offline: Int? = nil,
                         powerOnHours: Int? = nil,
                         smart: SmartOverall = .passed) -> DriveHealthSnapshot {
        DriveHealthSnapshot(
            mountPath: "/Volumes/Test",
            devicePath: "/dev/disk9",
            protocolKind: .sata,
            mediaTech: .hdd,
            smartStatus: smart,
            powerOnHours: powerOnHours,
            reallocatedSectors: realloc,
            pendingSectors: pending,
            offlineUncorrectable: offline
        )
    }

    private func makeNVMe(spare: Int? = nil,
                          used: Int? = nil,
                          smart: SmartOverall = .passed) -> DriveHealthSnapshot {
        DriveHealthSnapshot(
            mountPath: "/",
            devicePath: "/dev/disk0",
            protocolKind: .nvmeInternal,
            mediaTech: .nvme,
            smartStatus: smart,
            ssdAvailableSpare: spare,
            ssdPercentageUsed: used
        )
    }

    func test_recommendation_retireNowWhenReallocatedOver100() {
        let snap = makeHDD(realloc: 127)
        if case .retireNow = snap.recommendation {
            // good
        } else {
            XCTFail("Expected .retireNow; got \(snap.recommendation)")
        }
    }

    func test_recommendation_retireNowWhenSmartFailing() {
        let snap = makeHDD(smart: .failingNow)
        if case .retireNow = snap.recommendation { /* ok */ } else {
            XCTFail("SMART failure must always be retireNow.")
        }
    }

    func test_recommendation_planToRetireWhenReallocatedNonZero() {
        let snap = makeHDD(realloc: 4)
        if case .planToRetire = snap.recommendation { /* ok */ } else {
            XCTFail("Expected .planToRetire for small remap count.")
        }
    }

    func test_recommendation_watchWhenOverSixYears() {
        // 6.5 years × 8760 = ~56_940 hours
        let snap = makeHDD(realloc: 0, powerOnHours: 56_940)
        if case .watch = snap.recommendation { /* ok */ } else {
            XCTFail("Expected .watch for >6 year HDD; got \(snap.recommendation)")
        }
    }

    func test_recommendation_healthyByDefault() {
        let snap = makeHDD(realloc: 0, powerOnHours: 1000)
        if case .healthy = snap.recommendation { /* ok */ } else {
            XCTFail("Expected .healthy default.")
        }
    }

    func test_recommendation_nvmeRetireWhenSpareLow() {
        let snap = makeNVMe(spare: 5, used: 50)
        if case .retireNow = snap.recommendation { /* ok */ } else {
            XCTFail("Low spare must be retireNow.")
        }
    }

    func test_recommendation_nvmeWatchWhenUsedAboveSeventy() {
        let snap = makeNVMe(spare: 95, used: 72)
        if case .watch = snap.recommendation { /* ok */ } else {
            XCTFail("70%+ write-life used should be .watch.")
        }
    }

    // MARK: - Friendly tone guard

    func test_friendlyTone_recommendationReasonsAreInPlainEnglish() {
        let cases: [DriveHealthRecommendation] = [
            makeHDD(realloc: 200).recommendation,
            makeHDD(realloc: 2).recommendation,
            makeHDD(realloc: 0, powerOnHours: 60_000).recommendation,
            makeHDD(smart: .failingNow).recommendation,
            makeNVMe(spare: 5, used: 50).recommendation,
            makeNVMe(spare: 95, used: 75).recommendation,
            makeNVMe(spare: 95, used: 10).recommendation
        ]
        // Reject jargon that suggests we leaked the underlying SMART
        // mechanics into the recommendation text.
        let jargonTerms = [
            "SMART attribute", "reallocated_sector_ct",
            "id 5", "id 197", "id 198", "threshold", "raw value"
        ]
        for rec in cases {
            let reason = rec.reasonText
            XCTAssertFalse(reason.isEmpty, "Reason should not be empty.")
            for term in jargonTerms {
                XCTAssertFalse(reason.localizedCaseInsensitiveContains(term),
                               "Friendly reason leaked jargon '\(term)': \(reason)")
            }
        }
    }

    // MARK: - Suggested trust mapping

    func test_suggestedTrust_retireNowMapsToUnreliable() {
        let rec = DriveHealthRecommendation.retireNow(reason: "x")
        XCTAssertEqual(rec.suggestedTrust(currentTrust: .reliable), .unreliable)
        XCTAssertNil(rec.suggestedTrust(currentTrust: .unreliable),
                     "Already unreliable — no nag.")
    }

    func test_suggestedTrust_healthyMapsToReliable() {
        let rec = DriveHealthRecommendation.healthy(reason: "x")
        XCTAssertEqual(rec.suggestedTrust(currentTrust: .unknown), .reliable)
        XCTAssertNil(rec.suggestedTrust(currentTrust: .reliable))
    }

    // MARK: - Device path resolution helpers

    func test_stripSliceSuffix_returnsPhysicalDeviceNode() {
        XCTAssertEqual(DriveHealthProbe.stripSliceSuffix(from: "disk5s1"), "disk5")
        XCTAssertEqual(DriveHealthProbe.stripSliceSuffix(from: "disk0s3s2"), "disk0")
        XCTAssertEqual(DriveHealthProbe.stripSliceSuffix(from: "disk12"), "disk12")
        XCTAssertEqual(DriveHealthProbe.stripSliceSuffix(from: "weird"), "weird",
                       "Non-disk identifiers pass through unchanged.")
    }

    func test_parseProtocol_recognizesCommonStrings() {
        XCTAssertEqual(DriveHealthProbe.parseProtocol("USB"), .usb)
        XCTAssertEqual(DriveHealthProbe.parseProtocol("SATA"), .sata)
        XCTAssertEqual(DriveHealthProbe.parseProtocol("Thunderbolt"), .thunderbolt)
        XCTAssertEqual(DriveHealthProbe.parseProtocol("Apple Fabric"), .nvmeInternal)
        XCTAssertEqual(DriveHealthProbe.parseProtocol(nil), .unknown)
    }
}
