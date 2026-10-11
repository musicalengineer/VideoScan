//
//  SmartctlReport.swift
//  VideoScan
//
//  The smartctl `-a -j` document as a typed, tolerant Codable model — the
//  fields Drive Health reads and the decisions it makes from them. Split
//  out of DriveHealthProbe.parseSmartctlJSON (2026-10-10), which had grown
//  into a 130-line dictionary walk; each nested struct below is one JSON
//  object named as smartctl names it, so the schema is visible and each
//  decision (`overallStatus`, `mediaTech(refining:)`, `rawValue(id:)`) is a
//  small named member a test can hit on its own.
//
//  Tolerant by design: smartctl omits whatever a drive does not report, a
//  USB bridge returns almost nothing, and one odd field must never cost the
//  whole snapshot. Every field is `@Field` (absent / null / wrong type →
//  nil); only input that is not a JSON object fails the decode.
//

import Foundation

struct SmartctlReport: Decodable {

    /// A field that decodes as nil instead of throwing when the key is
    /// absent, null, or of the wrong type.
    /// (For Rick: a property wrapper is a tiny template standing in front
    /// of the member — `std::optional<T>` with its own deserializer.)
    @propertyWrapper
    struct Field<Value: Decodable>: Decodable {
        var wrappedValue: Value?
        init(wrappedValue: Value? = nil) { self.wrappedValue = wrappedValue }
        init(from decoder: Decoder) throws {
            wrappedValue = try? Value(from: decoder)
        }
    }

    @Field var modelName: String?
    @Field var serialNumber: String?
    @Field var firmwareVersion: String?
    @Field var userCapacity: UserCapacity?
    /// 0 = solid state, > 0 = rpm. Absent on NVMe and on most bridges.
    @Field var rotationRate: Int?
    @Field var smartStatus: SmartStatus?
    @Field var powerOnTime: PowerOnTime?
    @Field var temperature: Temperature?
    @Field var ataSmartAttributes: ATASmartAttributes?
    @Field var nvmeSmartHealthInformationLog: NVMeHealthLog?

    struct UserCapacity: Decodable {
        @Field var bytes: Int64?
    }

    /// HDD/SATA reports `passed`; NVMe adds (or only has) a status word
    /// where any non-zero bit means failure.
    struct SmartStatus: Decodable {
        @Field var passed: Bool?
        @Field var nvme: NVMeStatus?
        struct NVMeStatus: Decodable {
            @Field var value: Int?
        }
    }

    struct PowerOnTime: Decodable {
        @Field var hours: Int?
    }

    struct Temperature: Decodable {
        @Field var current: Int?
    }

    /// The ATA SMART attribute table, looked up by attribute id.
    struct ATASmartAttributes: Decodable {
        @Field var table: [Attribute]?

        struct Attribute: Decodable {
            @Field var id: Int?
            @Field var raw: Raw?
            struct Raw: Decodable {
                @Field var value: Int?
            }
        }

        // The four attribute ids the recommendation reads (ATA8-ACS names).
        static let reallocatedSectorCount = 5
        static let reallocatedEventCount = 196
        static let currentPendingSectorCount = 197
        static let offlineUncorrectableCount = 198

        /// Raw value of attribute `id`. The LAST row carrying the id wins —
        /// and a last row without a raw value reads as nil — exactly as the
        /// original table walk assigned.
        func rawValue(id: Int) -> Int? {
            table?.last { $0.id == id }?.raw?.value
        }
    }

    /// NVMe keeps hours, temperature and wear inside its SMART log.
    struct NVMeHealthLog: Decodable {
        @Field var powerOnHours: Int?
        @Field var temperature: Int?
        @Field var availableSpare: Int?
        @Field var percentageUsed: Int?
        @Field var mediaErrors: Int?
        /// In 512 000-byte units per the NVMe spec.
        @Field var dataUnitsWritten: Int64?
    }

    // MARK: Decode

    /// nil only when the text is not a JSON object at all; a sparse report
    /// decodes to a report full of nils.
    init?(json: String) {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let data = json.data(using: .utf8),
              let report = try? decoder.decode(SmartctlReport.self, from: data) else { return nil }
        self = report
    }

    // MARK: Decisions

    var overallStatus: SmartOverall {
        guard let smartStatus else { return .unknown }
        if let passed = smartStatus.passed { return passed ? .passed : .failingNow }
        if let value = smartStatus.nvme?.value { return value == 0 ? .passed : .failingNow }
        return .unknown
    }

    /// The caller's diskutil hint, refined by what the drive itself says:
    /// an NVMe log is conclusive; a rotation rate of 0 means solid state
    /// (keeping an NVMe hint), anything faster means spinning platters.
    func mediaTech(refining hint: DetectedMediaTech) -> DetectedMediaTech {
        if nvmeSmartHealthInformationLog != nil { return .nvme }
        switch rotationRate {
        case 0?:                        return hint == .nvme ? .nvme : .ssd
        case let rpm? where rpm > 0:    return .hdd
        default:                        return hint
        }
    }

    /// Top-level first; NVMe carries both inside the SMART log.
    var powerOnHours: Int? { powerOnTime?.hours ?? nvmeSmartHealthInformationLog?.powerOnHours }
    var temperatureCelsius: Int? { temperature?.current ?? nvmeSmartHealthInformationLog?.temperature }

    var dataWrittenBytes: Int64? {
        nvmeSmartHealthInformationLog?.dataUnitsWritten.map { $0 &* 512_000 }
    }

    /// Non-zero exit with parseable JSON: a soft warning so the UI can say
    /// "we had to work around something". smartctl's exit status is a
    /// bitmask; bit 6 (64, "error-log entry") is benign on Apple's NVMe, so
    /// that bit alone stays silent.
    static func partialDataWarning(exitCode: Int32) -> String? {
        guard (exitCode & ~64) != 0 else { return nil }
        return "smartctl reported a non-fatal hiccup while reading this drive (exit \(exitCode)). Data below may be partial."
    }
}

extension KeyedDecodingContainer {
    /// Lets the synthesized decoder treat an ABSENT key as nil for a
    /// `@Field` member (it would otherwise throw `keyNotFound`).
    func decode<V>(_ type: SmartctlReport.Field<V>.Type, forKey key: Key) throws -> SmartctlReport.Field<V> {
        try decodeIfPresent(type, forKey: key) ?? SmartctlReport.Field()
    }
}
