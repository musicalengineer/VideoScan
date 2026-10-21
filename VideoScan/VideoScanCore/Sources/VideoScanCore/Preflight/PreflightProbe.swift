// PreflightProbe.swift (VideoScanCore/Preflight)
// What the launch preflight asks the machine. Every question the checklist
// needs is one method here, so a test can hand the checklist any machine
// state it likes (a full disk, 8 GB of RAM, a probe that throws) without
// touching the real Mac. `SystemPreflightProbe` answers for real.
//
// Each answer may be `nil` ("the machine wouldn't say") or may throw. The
// checklist treats both the same way: "couldn't check X" at a level that is
// never ok, so a broken probe can never read as a green light.
//
// (For Rick: a `protocol` here is an abstract interface — a C++ class of
// pure virtuals — and `Sendable` says a conforming value may be handed to
// another thread, like a type you have proved is safe to share.)

import Foundation

/// How full one volume is. Bytes are decimal-free raw counts.
public struct PreflightVolume: Sendable, Equatable {
    /// Something that names the volume uniquely on this Mac (the real probe
    /// uses its mount point). Two folders on the same volume give the same id.
    public var id: String
    /// The volume's name for the person ("Macintosh HD").
    public var name: String
    /// `volumeAvailableCapacityForImportantUsage`: what macOS will free up
    /// for a real write, purgeable space included.
    public var availableBytes: Int64
    public var totalBytes: Int64

    public init(id: String, name: String, availableBytes: Int64, totalBytes: Int64) {
        self.id = id
        self.name = name
        self.availableBytes = availableBytes
        self.totalBytes = totalBytes
    }

    /// 0…1. A volume reporting zero size reads as full, never as empty.
    public var usedFraction: Double {
        guard totalBytes > 0 else { return 1 }
        let used = Double(totalBytes - min(max(availableBytes, 0), totalBytes))
        return used / Double(totalBytes)
    }
}

/// `ProcessInfo.ThermalState`, as our own value so tests need no real Mac.
public enum PreflightThermalState: String, Sendable, CaseIterable {
    case nominal, fair, serious, critical
}

public enum PreflightPowerSource: String, Sendable {
    case mains, battery
}

/// The external tools the app shells out to.
public enum PreflightTool: String, Sendable, CaseIterable {
    case ffmpeg, ffprobe
}

/// What `PRAGMA quick_check` said, within its time budget.
public enum PreflightQuickCheckOutcome: Sendable, Equatable {
    /// "ok", in this long.
    case passed(elapsed: Duration)
    /// The engine listed problems (the first few lines, verbatim).
    case problems([String], elapsed: Duration)
    /// The budget ran out and the check was interrupted — no verdict.
    case ranOutOfTime(budget: Duration)
}

public protocol PreflightProbe: Sendable {
    /// The volume holding `url` (the file or folder need not exist yet; the
    /// probe walks up to the nearest folder that does).
    func volume(containing url: URL) throws -> PreflightVolume?
    /// Is a volume mounted at `url` (a mount point such as /Volumes/Master)?
    func isVolumeMounted(at url: URL) -> Bool

    func physicalMemoryBytes() -> UInt64?
    /// Swap in use right now, in bytes.
    func swapUsedBytes() throws -> UInt64?
    func thermalState() -> PreflightThermalState?
    func powerSource() -> PreflightPowerSource?

    func fileExists(at url: URL) -> Bool
    /// Size in bytes; nil when there is no such file.
    func fileSize(at url: URL) -> UInt64?
    /// The folder exists and this process may create files in it (or it is
    /// missing and its parent would let us create it).
    func isWritableFolder(at url: URL) -> Bool
    /// Where the app would run `tool` from, or nil when it can't find one.
    func executablePath(for tool: PreflightTool) -> String?

    /// `catalog_state.schema_version` of the catalog at `databaseURL`
    /// (read-only, cheap). nil when the file has no such row.
    func catalogSchemaVersion(at databaseURL: URL) throws -> Int?
    /// `PRAGMA quick_check` on a read-only connection, interrupted at `budget`.
    func catalogQuickCheck(at databaseURL: URL, budget: Duration) throws -> PreflightQuickCheckOutcome
}
