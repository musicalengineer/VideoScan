// PreflightGate.swift (VideoScanCore/Preflight)
// What a full disk is ALLOWED to stop (Rick's ruling, 2026-10-21, option b):
//   * red disk → the person keeps editing, but long MFO jobs, backups and
//     viewer-copy publishes refuse to start, saying why and how much space
//     they need;
//   * hard floor → below about 2 × (catalog.sqlite + WAL) free on the
//     catalog's disk, edits are held back too, with words, because a commit
//     itself may not fit;
//   * each operation is sized to what it needs: a job brings its own
//     estimate; a backup and a viewer publish each need about one catalog.
//
// Pure: a volume reading and sizes in, a verdict out. The app re-probes the
// volume just before the operation (one URLResourceValues read, ≈ 0.1 ms)
// and asks here.
//
// (For Rick: an enum with associated values ≈ a tagged union / std::variant;
// `switch` over it is the visitor, and the compiler proves every case is handled.)

import Foundation

/// Something that needs disk space before it starts.
public enum PreflightOperation: Sendable, Equatable {
    /// A catalog commit (any edit).
    case edit
    /// A long MFO job. `name` is the person's words for it ("Transcode");
    /// `estimatedBytes` is what it will write.
    case longJob(name: String, estimatedBytes: Int64)
    /// A catalog backup: about one catalog (catalog.sqlite + WAL).
    case backup
    /// Publishing the viewer copy: about one catalog.
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
        case .viewerPublish: return "Publishing the viewer copy"
        }
    }
}

public enum PreflightGateVerdict: Sendable, Equatable {
    case go
    /// `words` for the person; `shortBytes` is how much more free space it needs.
    case refused(words: String, detail: String, shortBytes: Int64)

    public var isGo: Bool { self == .go }
}

/// What the launch report holds back until space is freed.
public enum PreflightHold: Int, Sendable, Comparable {
    case none = 0
    /// Red disk: long jobs, backups and publishes refuse; editing goes on.
    case longOperations = 1
    /// Below the hard floor: edits are held too.
    case edits = 2

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum PreflightGate {

    /// May `operation` start? `catalogVolume` is the disk holding the catalog
    /// (nil when it couldn't be read); `destination` is where the operation
    /// writes, when that is a different disk.
    ///
    /// A disk that couldn't be read never holds EDITS (we don't stop the
    /// person on a guess) but does refuse a long operation — it would only
    /// be starting blind, and trying again costs nothing.
    public static func decide(_ operation: PreflightOperation, catalogVolume: PreflightVolume?,
                              catalogBytes: UInt64, destination: PreflightVolume? = nil,
                              thresholds: PreflightThresholds = PreflightThresholds()) -> PreflightGateVerdict {
        guard let volume = catalogVolume else {
            if operation == .edit { return .go }
            return .refused(words: "\(operation.words) can't start: VideoScan couldn't check how much free space there is — try again",
                            detail: "catalog volume unreadable", shortBytes: 0)
        }
        let editFloor = thresholds.editHoldFreeBytes(catalogBytes: catalogBytes)
        if volume.availableBytes < editFloor {
            return refusedForSpace(operation, volume: volume, short: editFloor - volume.availableBytes,
                                   rule: "below the edit floor \(PreflightWords.gigabytes(editFloor))")
        }
        guard operation != .edit else { return .go }
        let (level, _) = PreflightDiskRule.judge(volume, catalogBytes: catalogBytes, thresholds: thresholds)
        if level == .red {
            return refusedForSpace(operation, volume: volume,
                                   short: thresholds.bytesToLeaveRed(volume, catalogBytes: catalogBytes),
                                   rule: "main disk is red")
        }
        // Sized to the operation: it must fit, and on the catalog's own disk
        // it must leave the red line's worth of room behind it.
        let target = destination ?? volume
        let sameDisk = target.id == volume.id
        let reserve = sameDisk ? thresholds.diskRedFreeBytes(catalogBytes: catalogBytes) : 0
        let needed = operation.bytesNeeded(catalogBytes: catalogBytes).addingClamped(reserve)
        guard target.availableBytes >= needed else {
            return refusedForSpace(operation, volume: target, short: needed - target.availableBytes,
                                   rule: "needs \(PreflightWords.gigabytes(needed)) incl. reserve \(PreflightWords.gigabytes(reserve))")
        }
        return .go
    }

    /// What the launch report holds back, from the catalog disk alone.
    public static func hold(catalogVolume: PreflightVolume?, catalogBytes: UInt64,
                            thresholds: PreflightThresholds = PreflightThresholds()) -> PreflightHold {
        guard let volume = catalogVolume else { return .none }   // inform only; each operation re-checks
        if volume.availableBytes < thresholds.editHoldFreeBytes(catalogBytes: catalogBytes) { return .edits }
        let (level, _) = PreflightDiskRule.judge(volume, catalogBytes: catalogBytes, thresholds: thresholds)
        return level == .red ? .longOperations : .none
    }

    private static func refusedForSpace(_ operation: PreflightOperation, volume: PreflightVolume,
                                        short: Int64, rule: String) -> PreflightGateVerdict {
        let free = PreflightWords.gigabytes(volume.availableBytes)
        let more = PreflightWords.gigabytesRoundedUp(max(short, 1))
        let verb = operation == .edit ? "is on hold" : "can't start"
        return .refused(words: "\(operation.words) \(verb): \(volume.name) has only \(free) free — free at least \(more) more first",
                        detail: "\(volume.name) (\(volume.id)) free \(volume.availableBytes) bytes, short \(short) bytes: \(rule)",
                        shortBytes: short)
    }
}

extension PreflightThresholds {
    /// The hard floor: below this much free on the catalog's disk, edits
    /// are held — 2 × (catalog + WAL), and never under 1 GB.
    public func editHoldFreeBytes(catalogBytes: UInt64) -> Int64 {
        Int64(clamping: catalogBytes).multipliedClamped(by: editHoldCatalogMultiple).clampedBelow(editHoldFloorBytes)
    }

    /// How many more free bytes take `volume` out of red.
    func bytesToLeaveRed(_ volume: PreflightVolume, catalogBytes: UInt64) -> Int64 {
        let target = max(leastFreeBelowRedPercent(volume), diskRedFreeBytes(catalogBytes: catalogBytes))
        return max(0, target - volume.availableBytes)
    }

    /// The least free byte count that `PreflightVolume.usedFraction` reads as
    /// under the red percent. Starts from the closed form, then nudges with
    /// the SAME predicate the rule uses, so float rounding (1 − 0.95 is
    /// 0.05000000000000004) can't make the answer a byte off. At most a few
    /// nudges; capped so an absurd size can't loop.
    func leastFreeBelowRedPercent(_ volume: PreflightVolume) -> Int64 {
        let total = volume.totalBytes
        guard total > 0 else { return 1 }
        func isRed(_ free: Int64) -> Bool {
            PreflightVolume(id: "", name: "", availableBytes: free, totalBytes: total).usedFraction >= diskRedUsedFraction
        }
        var free = Int64((Double(total) * (1 - diskRedUsedFraction)).rounded(.down))
        for _ in 0..<64 where isRed(free) { free += 1 }
        for _ in 0..<64 where free > 0 && !isRed(free - 1) { free -= 1 }
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

    /// max(self, floor) — reads better in a chain.
    func clampedBelow(_ floor: Int64) -> Int64 { Swift.max(self, floor) }
}
