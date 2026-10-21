// PreflightGate.swift (VideoScanCore/Preflight)
// What the preflight is ALLOWED to stop (Rick's rulings, 2026-10-21):
//   * a red CATALOG check — the cutover marker or the catalog file missing
//     (#354: refuse loudly), quick_check finding damage, a newer schema —
//     holds edits and everything else, with that check's words. Fail fast:
//     anything fishy about the catalog stops writing and says why (QA r1 M3);
//   * a red DISK lets the person keep editing (option b), but long MFO jobs,
//     backups and viewer-copy publishes refuse to start, saying why and how
//     much space they need — the WHOLE shortfall (QA r1 M2);
//   * the hard floor: below about 2 × (catalog.sqlite + WAL) free on the
//     catalog's disk (never under 1 GB), edits are held too, because a
//     commit itself may not fit;
//   * each operation is sized to what it needs, and on the catalog's own
//     disk it must leave the disk out of red by BOTH halves of the red line
//     — 95% used and the free-space floor (QA r1 M1).
//   * a disk that couldn't be read does NOT hold edits — inform first; a
//     failed probe is not evidence of a full disk. It does refuse a long
//     operation, which would only be starting blind (trying again is free).
//
// Pure: values in, a verdict out. `PreflightSituation` is what the gate
// knows; the launch report carries one, and before an operation the app
// swaps in a fresh disk reading (`with(catalogVolume:)`, one URLResourceValues
// read off the main actor, ≈ 7–20 ms) and asks again.
//
// (For Rick: an enum with associated values ≈ a tagged union / std::variant;
// `switch` over it is the visitor, and the compiler proves every case is handled.)

import Foundation

/// Something that needs disk space (or a sound catalog) before it starts.
public enum PreflightOperation: Sendable, Equatable {
    /// A catalog commit (any edit).
    case edit
    /// A long MFO job. `name` is the person's words for it ("Transcode");
    /// `estimatedBytes` is what it will write.
    case longJob(name: String, estimatedBytes: Int64)
    /// A catalog backup: about one catalog (catalog.sqlite + WAL).
    case backup
    /// Publishing the viewer copy for the other Macs: about one catalog.
    case viewerPublish

    /// Bytes this operation will write, for a catalog of `catalogBytes`.
    public func bytesNeeded(catalogBytes: UInt64) -> Int64 {
        switch self {
        case .edit: return 0
        case .longJob(_, let estimated): return max(0, estimated)
        case .backup, .viewerPublish: return Int64(clamping: catalogBytes)
        }
    }

    var words: String {
        switch self {
        case .edit: return "Saving changes"
        case .longJob(let name, _): return name
        case .backup: return "The catalog backup"
        case .viewerPublish: return "The copy for the other Macs"
        }
    }
}

/// Where an operation writes (QA r1 minor 1: explicit, no nil-means-something).
public enum PreflightDestination: Sendable, Equatable {
    /// The disk holding the catalog.
    case catalogDisk
    /// Another disk, as just read.
    case volume(PreflightVolume)
    /// A disk whose free space couldn't be read — long operations refuse.
    case unreadable
}

public enum PreflightGateVerdict: Sendable, Equatable {
    case go
    /// `words` for the person; `shortBytes` is how much more free space it
    /// needs (0 when space isn't the reason).
    case refused(words: String, detail: String, shortBytes: Int64)

    public var isGo: Bool { self == .go }
}

/// What the preflight holds back until it's fixed.
public enum PreflightHold: Int, Sendable, Comparable {
    case none = 0
    /// Red disk: long jobs, backups and publishes refuse; editing goes on.
    case longOperations = 1
    /// Below the hard floor, or a red catalog check: edits are held too.
    case edits = 2

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Everything the gate knows.
public struct PreflightSituation: Sendable, Equatable {
    /// The catalog's disk; nil when it couldn't be read.
    public var catalogVolume: PreflightVolume?
    /// catalog.sqlite + WAL.
    public var catalogBytes: UInt64
    /// The first red catalog check, which holds edits; nil when the catalog is sound.
    public var catalogFault: PreflightCheck?

    public init(catalogVolume: PreflightVolume?, catalogBytes: UInt64, catalogFault: PreflightCheck? = nil) {
        self.catalogVolume = catalogVolume
        self.catalogBytes = catalogBytes
        self.catalogFault = catalogFault
    }

    /// The same situation with a fresh disk reading (before an operation).
    public func with(catalogVolume volume: PreflightVolume?) -> PreflightSituation {
        var copy = self
        copy.catalogVolume = volume
        return copy
    }

    /// The catalog checks whose RED holds edits.
    public static let editHoldingChecks: Set<PreflightCheck.ID> = [
        .catalogSwitched, .catalogSchema, .catalogJournal, .catalogQuickCheck,
    ]

    /// The first red catalog check in `checks`, in checklist order.
    public static func catalogFault(in checks: [PreflightCheck]) -> PreflightCheck? {
        checks.first { $0.level == .red && editHoldingChecks.contains($0.id) }
    }
}

public enum PreflightGate {

    // MARK: Hold (what the launch report shows)

    public static func hold(_ situation: PreflightSituation,
                            thresholds: PreflightThresholds = PreflightThresholds()) -> PreflightHold {
        if situation.catalogFault != nil { return .edits }
        // Unreadable disk: inform only — a failed probe is not a full disk.
        guard let volume = situation.catalogVolume, volume.isMeasurable else { return .none }
        if volume.freeBytes < thresholds.editHoldFreeBytes(catalogBytes: situation.catalogBytes) { return .edits }
        let (level, _) = PreflightDiskRule.judge(volume, catalogBytes: situation.catalogBytes, thresholds: thresholds)
        return level == .red ? .longOperations : .none
    }

    /// Disk-only form: no catalog fault.
    public static func hold(catalogVolume: PreflightVolume?, catalogBytes: UInt64,
                            thresholds: PreflightThresholds = PreflightThresholds()) -> PreflightHold {
        hold(PreflightSituation(catalogVolume: catalogVolume, catalogBytes: catalogBytes), thresholds: thresholds)
    }

    // MARK: Decide (just before an operation)

    public static func decide(_ operation: PreflightOperation, in situation: PreflightSituation,
                              destination: PreflightDestination = .catalogDisk,
                              thresholds: PreflightThresholds = PreflightThresholds()) -> PreflightGateVerdict {
        if let fault = situation.catalogFault {
            return refusedForCatalog(operation, fault)
        }
        guard let volume = situation.catalogVolume, volume.isMeasurable else {
            // An unreadable disk never holds edits (inform first; a failed
            // probe is not evidence of a full disk) but a long operation
            // would start blind, so it refuses.
            return operation == .edit ? .go : refusedBlind(operation, "your Mac's main disk")
        }
        let catalogBytes = situation.catalogBytes
        let free = volume.freeBytes
        let editFloor = thresholds.editHoldFreeBytes(catalogBytes: catalogBytes)
        if operation == .edit {
            guard free < editFloor else { return .go }
            return refusedForSpace(operation, volume: volume, short: editFloor - free,
                                   rule: "below the edit floor \(PreflightWords.gigabytes(editFloor))")
        }
        return decideLong(operation, volume: volume, catalogBytes: catalogBytes,
                          destination: destination, thresholds: thresholds)
    }

    /// Disk-only form: no catalog fault.
    public static func decide(_ operation: PreflightOperation, catalogVolume: PreflightVolume?,
                              catalogBytes: UInt64, destination: PreflightDestination = .catalogDisk,
                              thresholds: PreflightThresholds = PreflightThresholds()) -> PreflightGateVerdict {
        decide(operation, in: PreflightSituation(catalogVolume: catalogVolume, catalogBytes: catalogBytes),
               destination: destination, thresholds: thresholds)
    }

    /// A long job, backup or publish on a readable catalog disk.
    private static func decideLong(_ operation: PreflightOperation, volume: PreflightVolume, catalogBytes: UInt64,
                                   destination: PreflightDestination,
                                   thresholds: PreflightThresholds) -> PreflightGateVerdict {
        let free = volume.freeBytes
        let outOfRed = thresholds.leastFreeOutOfRed(volume, catalogBytes: catalogBytes)
        let toLeaveRed = max(0, outOfRed - free)
        let need = operation.bytesNeeded(catalogBytes: catalogBytes)
        switch destination.resolved(against: volume) {
        case .catalogDisk:
            // Fit the job AND stay out of red afterwards: the whole shortfall.
            let needed = need.addingClamped(outOfRed)
            guard free < needed else { return .go }
            return refusedForSpace(operation, volume: volume, short: needed - free,
                                   rule: "needs \(PreflightWords.gigabytes(need)) and must leave "
                                       + "\(PreflightWords.gigabytes(outOfRed)) free to stay out of red")
        case .volume(let target):
            if toLeaveRed > 0 {
                return refusedForSpace(operation, volume: volume, short: toLeaveRed, rule: "catalog disk is red")
            }
            let short = max(0, need - target.freeBytes)
            guard short > 0 else { return .go }
            return refusedForSpace(operation, volume: target, short: short,
                                   rule: "needs \(PreflightWords.gigabytes(need)) on \(target.name)")
        case .unreadable:
            if toLeaveRed > 0 {
                return refusedForSpace(operation, volume: volume, short: toLeaveRed, rule: "catalog disk is red")
            }
            return refusedBlind(operation, "the disk it writes to")
        }
    }

    // MARK: Words

    private static func refusedForCatalog(_ operation: PreflightOperation, _ fault: PreflightCheck) -> PreflightGateVerdict {
        let words = operation == .edit ? fault.words : "\(operation.words) can't start: \(fault.words)"
        return .refused(words: words, detail: "catalog check \(fault.id.rawValue) is red: \(fault.detail)", shortBytes: 0)
    }

    private static func refusedBlind(_ operation: PreflightOperation, _ which: String) -> PreflightGateVerdict {
        .refused(words: "\(operation.words) can't start: VideoScan couldn't check how much free space \(which) has — try again",
                 detail: "volume unreadable (\(which))", shortBytes: 0)
    }

    private static func refusedForSpace(_ operation: PreflightOperation, volume: PreflightVolume,
                                        short: Int64, rule: String) -> PreflightGateVerdict {
        let free = PreflightWords.gigabytes(volume.freeBytes)
        let more = PreflightWords.gigabytesRoundedUp(max(short, 1))
        let verb = operation == .edit ? "is on hold" : "can't start"
        return .refused(words: "\(operation.words) \(verb): \(volume.name) has only \(free) free — free at least \(more) more first",
                        detail: "\(volume.name) (\(volume.id)) free \(volume.freeBytes) bytes, short \(short) bytes: \(rule)",
                        shortBytes: short)
    }
}

extension PreflightDestination {
    /// `.volume` naming the catalog's own disk (or one with no size) is
    /// folded into `.catalogDisk` / `.unreadable`.
    func resolved(against catalogVolume: PreflightVolume) -> PreflightDestination {
        switch self {
        case .volume(let target) where target.id == catalogVolume.id: return .catalogDisk
        case .volume(let target) where !target.isMeasurable: return .unreadable
        default: return self
        }
    }
}

extension PreflightThresholds {
    /// The hard floor: below this much free on the catalog's disk, edits
    /// are held — 2 × (catalog + WAL), and never under 1 GB.
    public func editHoldFreeBytes(catalogBytes: UInt64) -> Int64 {
        max(editHoldFloorBytes, Int64(clamping: catalogBytes).multipliedClamped(by: editHoldCatalogMultiple))
    }

    /// The least free byte count that keeps `volume` out of red by BOTH
    /// halves of the red line: under 95% used, and at or above the
    /// free-space floor. Always ≥ the edit floor.
    public func leastFreeOutOfRed(_ volume: PreflightVolume, catalogBytes: UInt64) -> Int64 {
        max(leastFreeBelowRedPercent(volume), diskRedFreeBytes(catalogBytes: catalogBytes))
    }

    /// The least free byte count that `PreflightVolume.usedFraction` reads as
    /// under the red percent. Starts from the closed form, then nudges with
    /// the SAME predicate the rule uses, so float rounding (1 − 0.95 is
    /// 0.05000000000000004) can't make the answer a byte off. A handful of
    /// nudges at most; capped so an absurd size can't loop.
    func leastFreeBelowRedPercent(_ volume: PreflightVolume) -> Int64 {
        let total = volume.totalBytes
        guard total > 0 else { return 1 }
        func isRed(_ free: Int64) -> Bool {
            PreflightVolume(id: "", name: "", availableBytes: free, totalBytes: total).usedFraction >= diskRedUsedFraction
        }
        var free = Int64((Double(total) * (1 - diskRedUsedFraction)).rounded(.down))
        var nudges = 0
        while isRed(free), free < total, nudges < 64 { free += 1; nudges += 1 }
        while free > 0, !isRed(free - 1), nudges < 128 { free -= 1; nudges += 1 }
        return free
    }
}

extension Int64 {
    func multipliedClamped(by other: Int64) -> Int64 {
        let (value, overflow) = multipliedReportingOverflow(by: other)
        return overflow ? .max : value
    }

    func addingClamped(_ other: Int64) -> Int64 {
        let (value, overflow) = addingReportingOverflow(other)
        return overflow ? .max : value
    }
}
