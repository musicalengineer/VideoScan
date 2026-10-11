//
//  DriveHealthSmartctlCharacterizationTests.swift
//  VideoScanTests
//
//  Characterization pins for DriveHealthProbe.parseSmartctlJSON, written
//  BEFORE the 2026-10-10 refactor (CCN 42 → a Codable `SmartctlReport`
//  model) so the refactor is judged against golden outputs: every field of
//  the snapshot for a SATA HDD, an Apple NVMe, a SATA SSD, a USB bridge
//  that passes nothing through, an NVMe whose only status is the
//  `nvme.value` word, and JSON with fields missing or malformed.
//
//  `probedAt` is `Date()` inside the parser, so the pins compare a
//  `Fields` value that leaves it out.
//

import XCTest
@testable import VideoScan

final class DriveHealthSmartctlCharacterizationTests: XCTestCase {

    // MARK: - Golden shape (every field but the clock)

    /// Everything the parser decides, minus `probedAt`.
    private struct Fields: Equatable {
        var modelName: String?
        var serialNumber: String?
        var firmware: String?
        var capacityBytes: Int64?
        var protocolKind: ProtocolKind
        var mediaTech: DetectedMediaTech
        var smartStatus: SmartOverall
        var powerOnHours: Int?
        var reallocatedSectors: Int?
        var pendingSectors: Int?
        var offlineUncorrectable: Int?
        var reallocatedEvents: Int?
        var temperatureCelsius: Int?
        var ssdAvailableSpare: Int?
        var ssdPercentageUsed: Int?
        var ssdMediaErrors: Int?
        var dataWrittenBytes: Int64?
        var probeWarnings: [String]

        init(_ s: DriveHealthSnapshot) {
            modelName = s.modelName; serialNumber = s.serialNumber; firmware = s.firmware
            capacityBytes = s.capacityBytes; protocolKind = s.protocolKind; mediaTech = s.mediaTech
            smartStatus = s.smartStatus; powerOnHours = s.powerOnHours
            reallocatedSectors = s.reallocatedSectors; pendingSectors = s.pendingSectors
            offlineUncorrectable = s.offlineUncorrectable; reallocatedEvents = s.reallocatedEvents
            temperatureCelsius = s.temperatureCelsius; ssdAvailableSpare = s.ssdAvailableSpare
            ssdPercentageUsed = s.ssdPercentageUsed; ssdMediaErrors = s.ssdMediaErrors
            dataWrittenBytes = s.dataWrittenBytes; probeWarnings = s.probeWarnings
        }

        init(modelName: String? = nil, serialNumber: String? = nil, firmware: String? = nil,
             capacityBytes: Int64? = nil, protocolKind: ProtocolKind, mediaTech: DetectedMediaTech,
             smartStatus: SmartOverall, powerOnHours: Int? = nil, reallocatedSectors: Int? = nil,
             pendingSectors: Int? = nil, offlineUncorrectable: Int? = nil, reallocatedEvents: Int? = nil,
             temperatureCelsius: Int? = nil, ssdAvailableSpare: Int? = nil, ssdPercentageUsed: Int? = nil,
             ssdMediaErrors: Int? = nil, dataWrittenBytes: Int64? = nil, probeWarnings: [String] = []) {
            self.modelName = modelName; self.serialNumber = serialNumber; self.firmware = firmware
            self.capacityBytes = capacityBytes; self.protocolKind = protocolKind; self.mediaTech = mediaTech
            self.smartStatus = smartStatus; self.powerOnHours = powerOnHours
            self.reallocatedSectors = reallocatedSectors; self.pendingSectors = pendingSectors
            self.offlineUncorrectable = offlineUncorrectable; self.reallocatedEvents = reallocatedEvents
            self.temperatureCelsius = temperatureCelsius; self.ssdAvailableSpare = ssdAvailableSpare
            self.ssdPercentageUsed = ssdPercentageUsed; self.ssdMediaErrors = ssdMediaErrors
            self.dataWrittenBytes = dataWrittenBytes; self.probeWarnings = probeWarnings
        }
    }

    private static let hiccup = "smartctl reported a non-fatal hiccup while reading this drive (exit %d). Data below may be partial."

    private func parse(_ json: String, protocolKind: ProtocolKind = .sata,
                       hint: DetectedMediaTech = .unknown, exitCode: Int32 = 0,
                       priorWarnings: [String] = []) -> DriveHealthSnapshot? {
        DriveHealthProbe.parseSmartctlJSON(json, mountPath: "/Volumes/T", devicePath: "/dev/disk7",
                                           protocolKind: protocolKind, mediaTechHint: hint,
                                           exitCode: exitCode, priorWarnings: priorWarnings)
    }

    private func fixture(_ name: String, file: String = #filePath) throws -> String {
        let url = URL(fileURLWithPath: file).deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Real captures, every field

    func test_goldenFields_seagateIronWolfHDD() throws {
        let snap = try XCTUnwrap(parse(try fixture("smartctl_hdd_seagate_ironwolf.json"),
                                       protocolKind: .sata, hint: .hdd))
        XCTAssertEqual(snap.id, "/dev/disk7")
        XCTAssertEqual(snap.mountPath, "/Volumes/T")
        XCTAssertEqual(Fields(snap), Fields(
            modelName: "ST8000NE0021-2EN112", serialNumber: "REDACTED-HDD-001", firmware: "EN02",
            capacityBytes: 8_001_563_222_016, protocolKind: .sata, mediaTech: .hdd, smartStatus: .passed,
            powerOnHours: 95, reallocatedSectors: 0, pendingSectors: 0, offlineUncorrectable: 0,
            reallocatedEvents: nil,     // id 196 is not in this drive's table
            temperatureCelsius: 33))
    }

    func test_goldenFields_appleNVMe_exit4() throws {
        let snap = try XCTUnwrap(parse(try fixture("smartctl_nvme_apple.json"),
                                       protocolKind: .nvmeInternal, hint: .nvme, exitCode: 4,
                                       priorWarnings: ["earlier"]))
        XCTAssertEqual(Fields(snap), Fields(
            modelName: "APPLE SSD AP1024Z", serialNumber: "REDACTED-NVME-001", firmware: "2973.120",
            capacityBytes: nil, protocolKind: .nvmeInternal, mediaTech: .nvme, smartStatus: .passed,
            powerOnHours: 527, temperatureCelsius: 27,
            ssdAvailableSpare: 100, ssdPercentageUsed: 2, ssdMediaErrors: 0,
            dataWrittenBytes: 53_242_864 * 512_000,
            probeWarnings: ["earlier", String(format: Self.hiccup, 4)]))
    }

    // MARK: - Synthetic shapes

    private let sataSSD = """
    {"model_name":"Samsung SSD 870 EVO 2TB","serial_number":"S","firmware_version":"SVT02B6Q",
     "user_capacity":{"blocks":3907029168,"bytes":2000398934016},
     "rotation_rate":0,"smart_status":{"passed":true},
     "power_on_time":{"hours":12000},"temperature":{"current":31},
     "ata_smart_attributes":{"table":[
        {"id":5,"name":"Reallocated_Sector_Ct","raw":{"value":3,"string":"3"}},
        {"id":196,"name":"Reallocated_Event_Count","raw":{"value":7,"string":"7"}},
        {"id":197,"name":"Current_Pending_Sector","raw":{"value":1,"string":"1"}},
        {"id":198,"name":"Offline_Uncorrectable","raw":{"value":2,"string":"2"}},
        {"id":199,"name":"UDMA_CRC_Error_Count","raw":{"value":9,"string":"9"}},
        {"name":"no id here","raw":{"value":99}},
        {"id":9,"name":"Power_On_Hours"}
     ]}}
    """

    func test_sataSSD_rotationZeroRefinesUnknownHintToSSD_andReadsAllFourAttributes() throws {
        let snap = try XCTUnwrap(parse(sataSSD, protocolKind: .usb, hint: .unknown))
        XCTAssertEqual(Fields(snap), Fields(
            modelName: "Samsung SSD 870 EVO 2TB", serialNumber: "S", firmware: "SVT02B6Q",
            capacityBytes: 2_000_398_934_016, protocolKind: .usb, mediaTech: .ssd, smartStatus: .passed,
            powerOnHours: 12000, reallocatedSectors: 3, pendingSectors: 1, offlineUncorrectable: 2,
            reallocatedEvents: 7, temperatureCelsius: 31))
    }

    func test_rotationZero_keepsAnNVMeHint_butTurnsHDDHintIntoSSD() throws {
        XCTAssertEqual(try XCTUnwrap(parse(sataSSD, hint: .nvme)).mediaTech, .nvme)
        XCTAssertEqual(try XCTUnwrap(parse(sataSSD, hint: .hdd)).mediaTech, .ssd)
        XCTAssertEqual(try XCTUnwrap(parse(sataSSD, hint: .ssd)).mediaTech, .ssd)
    }

    func test_positiveRotation_isHDD_whateverTheHint() throws {
        let json = #"{"rotation_rate":5400}"#
        XCTAssertEqual(try XCTUnwrap(parse(json, hint: .ssd)).mediaTech, .hdd)
        XCTAssertEqual(try XCTUnwrap(parse(json, hint: .nvme)).mediaTech, .hdd)
    }

    func test_nvmeLog_overridesAnyHint_evenWithRotationRate() throws {
        let json = #"{"rotation_rate":7200,"nvme_smart_health_information_log":{"percentage_used":5}}"#
        let snap = try XCTUnwrap(parse(json, hint: .hdd))
        XCTAssertEqual(snap.mediaTech, .nvme)
        XCTAssertEqual(snap.ssdPercentageUsed, 5)
        XCTAssertNil(snap.ssdAvailableSpare)
        XCTAssertNil(snap.dataWrittenBytes)
    }

    func test_nvmeOnlyStatusWord_failsWhenNonZero_passesWhenZero() throws {
        let failing = #"{"smart_status":{"nvme":{"value":4}}}"#
        XCTAssertEqual(try XCTUnwrap(parse(failing)).smartStatus, .failingNow)
        let fine = #"{"smart_status":{"nvme":{"value":0}}}"#
        XCTAssertEqual(try XCTUnwrap(parse(fine)).smartStatus, .passed)
        // `passed` wins over the nvme word when both are present.
        let both = #"{"smart_status":{"passed":false,"nvme":{"value":0}}}"#
        XCTAssertEqual(try XCTUnwrap(parse(both)).smartStatus, .failingNow)
        // An empty smart_status is unknown, and so is no smart_status at all.
        XCTAssertEqual(try XCTUnwrap(parse(#"{"smart_status":{}}"#)).smartStatus, .unknown)
        XCTAssertEqual(try XCTUnwrap(parse(#"{}"#)).smartStatus, .unknown)
    }

    func test_powerOnHoursAndTemperature_preferTopLevel_thenNVMeLog() throws {
        let topLevel = #"{"power_on_time":{"hours":10},"temperature":{"current":40},"nvme_smart_health_information_log":{"power_on_hours":20,"temperature":50}}"#
        let a = try XCTUnwrap(parse(topLevel))
        XCTAssertEqual(a.powerOnHours, 10)
        XCTAssertEqual(a.temperatureCelsius, 40)
        let logOnly = #"{"nvme_smart_health_information_log":{"power_on_hours":20,"temperature":50}}"#
        let b = try XCTUnwrap(parse(logOnly))
        XCTAssertEqual(b.powerOnHours, 20)
        XCTAssertEqual(b.temperatureCelsius, 50)
    }

    func test_usbBridge_passesNothingThrough_yieldsSkeletonWithHintsKept() throws {
        // What smartctl prints for a bridge that answers the identify but no SMART.
        let json = #"{"json_format_version":[1,0],"smartctl":{"version":[7,5],"exit_status":0},"device":{"name":"/dev/disk7","type":"scsi"}}"#
        let snap = try XCTUnwrap(parse(json, protocolKind: .usb, hint: .hdd, priorWarnings: ["w1", "w2"]))
        XCTAssertEqual(Fields(snap), Fields(protocolKind: .usb, mediaTech: .hdd, smartStatus: .unknown,
                                            probeWarnings: ["w1", "w2"]))
    }

    func test_exitCode_bit64AloneIsSilent_anyOtherBitWarns_priorWarningsComeFirst() throws {
        let json = #"{"smart_status":{"passed":true}}"#
        XCTAssertEqual(try XCTUnwrap(parse(json, exitCode: 64, priorWarnings: ["p"])).probeWarnings, ["p"])
        XCTAssertEqual(try XCTUnwrap(parse(json, exitCode: 0)).probeWarnings, [])
        XCTAssertEqual(try XCTUnwrap(parse(json, exitCode: 65, priorWarnings: ["p"])).probeWarnings,
                       ["p", String(format: Self.hiccup, 65)])
        XCTAssertEqual(try XCTUnwrap(parse(json, exitCode: 2)).probeWarnings, [String(format: Self.hiccup, 2)])
    }

    func test_dataUnitsWritten_isScaledBy512000() throws {
        let json = #"{"nvme_smart_health_information_log":{"data_units_written":10}}"#
        XCTAssertEqual(try XCTUnwrap(parse(json)).dataWrittenBytes, 5_120_000)
    }

    func test_invalidOrNonObjectJSON_returnsNil() {
        XCTAssertNil(parse("not json at all"))
        XCTAssertNil(parse(""))
        XCTAssertNil(parse("[1,2,3]"), "a JSON array is not a smartctl report")
        XCTAssertNil(parse("\"a string\""))
    }

    func test_missingOrWrongTypedFields_areIgnored_notFatal() throws {
        // user_capacity without bytes; smart_status with a string instead of
        // a bool; an attribute whose raw block lacks a value.
        let json = #"{"model_name":"X","user_capacity":{"blocks":5},"smart_status":{"passed":"yes"},"ata_smart_attributes":{"table":[{"id":5,"raw":{"string":"3"}}]}}"#
        let snap = try XCTUnwrap(parse(json, hint: .hdd))
        XCTAssertEqual(snap.modelName, "X")
        XCTAssertNil(snap.capacityBytes)
        XCTAssertEqual(snap.smartStatus, .unknown)
        XCTAssertNil(snap.reallocatedSectors, "id 5 present but raw.value missing reads as nil")
        XCTAssertEqual(snap.mediaTech, .hdd, "no rotation_rate — the hint stands")
    }

    func test_laterDuplicateAttributeIDWins() throws {
        let json = #"{"ata_smart_attributes":{"table":[{"id":197,"raw":{"value":1}},{"id":197,"raw":{"value":8}}]}}"#
        XCTAssertEqual(try XCTUnwrap(parse(json)).pendingSectors, 8)
    }
}
