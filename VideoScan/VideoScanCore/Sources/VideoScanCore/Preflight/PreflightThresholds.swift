// PreflightThresholds.swift (VideoScanCore/Preflight)
// The checklist's numbers, and the one pure rule for how full a disk may be.
// Defaults are Rick's 2026-10-21 brief and rulings; each is a named constant
// so a change is one line and a test pins it (defaultsAreRicksNumbers).
//
// Disk sizes are decimal GB (as Finder shows them); memory and journal sizes
// are binary (as the hardware and SQLite count them). Every disk number is
// judged against bytes free RIGHT NOW (`PreflightVolume.freeBytes`) —
// purgeable space doesn't count until macOS frees it (QA r1 M4).

import Foundation

public struct PreflightThresholds: Sendable, Equatable {
    public static let gigabyte: Int64 = 1_000_000_000
    public static let gibibyte: UInt64 = 1 << 30
    public static let mebibyte: UInt64 = 1 << 20

    /// Disk: warn at ≥ 90% used …
    public static let defaultDiskWarnUsedFraction = 0.90
    /// … or under 50 GB free.
    public static let defaultDiskWarnFreeBytes: Int64 = 50 * gigabyte
    /// Disk: red at ≥ 95% used …
    public static let defaultDiskRedUsedFraction = 0.95
    /// … or under max(20 GB, 3 × (catalog.sqlite + WAL)) free: a commit,
    /// a safety copy and a VACUUM INTO each need about a catalog's worth.
    public static let defaultDiskRedFloorBytes: Int64 = 20 * gigabyte
    public static let defaultDiskRedCatalogMultiple: Int64 = 3
    /// Hard floor (Rick, 2026-10-21): below 2 × (catalog + WAL) free on the
    /// catalog's disk, edits are held — a commit may not fit …
    public static let defaultEditHoldCatalogMultiple: Int64 = 2
    /// … and never below 1 GB, so a tiny or missing catalog can't make an
    /// empty disk look editable.
    public static let defaultEditHoldFloorBytes: Int64 = 1 * gigabyte
    /// RAM: warn under 16 GB of physical memory.
    public static let defaultMemoryWarnBelowBytes: UInt64 = 16 * gibibyte
    /// Swap: note over 4 GB in use (UI slowness is often swap / MLX helpers).
    public static let defaultSwapNoteAboveBytes: UInt64 = 4 * gibibyte
    /// WAL: warn over 256 MB — the journal is not being checkpointed.
    public static let defaultJournalWarnAboveBytes: UInt64 = 256 * mebibyte
    /// quick_check is interrupted after this long. Measured 2026-10-21 on a
    /// .backup copy of the 275 MB live catalog (M4 Max, through GRDB):
    /// 125–190 ms warm, 2.67 s with a cold file cache. 5 s covers a cold
    /// launch with room to spare; it runs off the main actor, so the person
    /// never waits on it. Running out of time is a WARN (QA r1 minor 2):
    /// fail fast, never a quiet green.
    public static let quickCheckBudget: Duration = .seconds(5)

    public var diskWarnUsedFraction = defaultDiskWarnUsedFraction
    public var diskWarnFreeBytes = defaultDiskWarnFreeBytes
    public var diskRedUsedFraction = defaultDiskRedUsedFraction
    public var diskRedFloorBytes = defaultDiskRedFloorBytes
    public var diskRedCatalogMultiple = defaultDiskRedCatalogMultiple
    public var editHoldCatalogMultiple = defaultEditHoldCatalogMultiple
    public var editHoldFloorBytes = defaultEditHoldFloorBytes
    public var memoryWarnBelowBytes = defaultMemoryWarnBelowBytes
    public var swapNoteAboveBytes = defaultSwapNoteAboveBytes
    public var journalWarnAboveBytes = defaultJournalWarnAboveBytes

    public init() {}

    /// The free space below which a disk is red, for a catalog of this size.
    public func diskRedFreeBytes(catalogBytes: UInt64) -> Int64 {
        max(diskRedFloorBytes, Int64(clamping: catalogBytes).multipliedClamped(by: diskRedCatalogMultiple))
    }

    /// The level a check takes when its probe couldn't answer. Never ok.
    public static func unknownLevel(for id: PreflightCheck.ID) -> PreflightLevel {
        switch id {
        case .systemDisk, .tempDisk, .catalogSwitched, .catalogSchema, .catalogJournal, .catalogQuickCheck:
            return .warn
        case .memory, .swap, .tools, .logFolder, .thermal, .power, .masterArchive:
            return .note
        }
    }
}

// MARK: - The disk rule (pure)

/// How full a disk may be. Pure: a volume reading and a catalog size in,
/// a level and the reason out. Callers check `isMeasurable` first; a
/// volume with no size reads as 100% used here, never as empty.
public enum PreflightDiskRule {
    public enum Reason: Sendable, Equatable, CustomStringConvertible {
        case fine
        case percentFull(Double)
        case lowFree(Int64)

        public var description: String {
            switch self {
            case .fine: return "within limits"
            case .percentFull(let used): return String(format: "%.1f%% used", used * 100)
            case .lowFree(let free): return "\(PreflightWords.gigabytes(free)) free"
            }
        }
    }

    public static func judge(_ volume: PreflightVolume, catalogBytes: UInt64,
                             thresholds: PreflightThresholds) -> (PreflightLevel, Reason) {
        let used = volume.usedFraction
        let free = volume.freeBytes
        if used >= thresholds.diskRedUsedFraction { return (.red, .percentFull(used)) }
        if free < thresholds.diskRedFreeBytes(catalogBytes: catalogBytes) { return (.red, .lowFree(free)) }
        if used >= thresholds.diskWarnUsedFraction { return (.warn, .percentFull(used)) }
        if free < thresholds.diskWarnFreeBytes { return (.warn, .lowFree(free)) }
        return (.ok, .fine)
    }
}
