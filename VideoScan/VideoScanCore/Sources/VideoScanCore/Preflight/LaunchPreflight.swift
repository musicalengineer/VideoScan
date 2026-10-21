// LaunchPreflight.swift (VideoScanCore/Preflight)
// The launch preflight checklist (Rick, 2026-10-21): once the catalog has
// opened, a few very quick checks tell the person about trouble BEFORE they
// start editing — a nearly full disk, a missing switch-over marker, a hot
// Mac — so the SQLite edge cases (a commit failing on a full disk at quit, a
// failed safety copy, starved RAM) are headed off instead of hit.
//
// Shape:
//   * `PreflightProbe` (PreflightProbe.swift) asks the machine; it is
//     injected, so tests can feed any machine state.
//   * `PreflightRules` (PreflightRules.swift) turns one answer into one
//     `PreflightCheck`. Pure functions, one per check; thresholds are the
//     named constants in `PreflightThresholds`.
//   * `LaunchPreflight` (this file) runs the rules in a fixed order and
//     folds them into a `PreflightReport`: the worst level wins, one
//     sentence for a banner, START/OUTCOME lines for the log sink.
//
// Rick's rulings (2026-10-21): launch runs quick_check only — the full
// integrity_check + foreign_key_check belongs to backup, Validate Catalog
// and an idle-time background run. A red disk lets the person keep editing
// but holds long jobs, backups and viewer publishes; below the hard floor
// (2 × catalog + WAL) edits are held too. `PreflightGate` (PreflightGate.swift)
// owns that decision and the per-operation space checks.
//
// Two phases, because they cost different amounts:
//   fast  — everything but quick_check. Budget < 200 ms (each probe call is
//           a stat, a sysctl or a one-row read).
//   quick — `PRAGMA quick_check`, O(database size). Measured 2026-10-21 on a
//           .backup copy of the live 275 MB catalog: quick_check ≈ 125–190 ms
//           warm (2.67 s cold), integrity_check ≈ 325–560 ms, foreign_key_check
//           ≈ 75–120 ms (warm cache,
//           M4 Max). Interrupted at `PreflightContext.quickCheckBudget`.
//
// Memory: O(number of checks) — a dozen small structs. Nothing is cached;
// quick_check runs inside SQLite's own page cache.
//
// Nothing here touches the main actor. `run` is `@concurrent`, so it runs on
// the shared thread pool even when called from SwiftUI code.
// (For Rick: `@concurrent` ≈ "always post this to a worker thread", never
// the UI thread; `Comparable` on an enum ≈ defining operator< on it.)

import Foundation

// MARK: - Results

/// How much a check matters. Ordered: the worst level wins.
public enum PreflightLevel: Int, Sendable, Comparable, CaseIterable, CustomStringConvertible {
    /// Fine. No banner, nothing to say.
    case ok = 0
    /// Worth knowing, nothing to do (the Master Archive drive is offline).
    case note = 1
    /// Do something soon (the disk is 90% full).
    case warn = 2
    /// Do something before editing (the disk is 95% full).
    case red = 3

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var description: String {
        switch self {
        case .ok: return "ok"
        case .note: return "note"
        case .warn: return "warn"
        case .red: return "red"
        }
    }

    /// Only warn and red earn a banner; notes live in Catalog Status.
    public var showsBanner: Bool { self >= .warn }
}

/// One measured number behind a check ("free bytes", "used fraction").
public struct PreflightReading: Sendable, Equatable {
    public enum Unit: String, Sendable {
        case bytes, fraction, milliseconds, count, version
    }
    public var name: String
    public var value: Double
    public var unit: Unit

    public init(_ name: String, _ value: Double, _ unit: Unit) {
        self.name = name
        self.value = value
        self.unit = unit
    }

    var logText: String {
        switch unit {
        case .bytes: return "\(name)=\(PreflightWords.gigabytes(value))"
        case .fraction: return "\(name)=\(String(format: "%.1f%%", value * 100))"
        case .milliseconds: return "\(name)=\(String(format: "%.0f ms", value))"
        case .count, .version: return "\(name)=\(Int(value))"
        }
    }
}

/// The result of one check.
public struct PreflightCheck: Sendable, Equatable, Identifiable {
    /// Which check. The raw value is stable: the log and Catalog Status key on it.
    public enum ID: String, Sendable, CaseIterable {
        case systemDisk = "system-disk"
        case tempDisk = "temp-disk"
        case memory
        case swap
        case catalogSwitched = "catalog-switched"
        case catalogSchema = "catalog-schema"
        case catalogJournal = "catalog-journal"
        case catalogQuickCheck = "catalog-quick-check"
        case tools
        case logFolder = "log-folder"
        case thermal
        case power
        case masterArchive = "master-archive"
    }

    public var id: ID
    public var level: PreflightLevel
    /// Plain words for the person (banner and Catalog Status).
    public var words: String
    /// Exact words for the log: paths, numbers, the rule that fired.
    public var detail: String
    public var readings: [PreflightReading]

    public init(_ id: ID, _ level: PreflightLevel, words: String, detail: String,
                readings: [PreflightReading] = []) {
        self.id = id
        self.level = level
        self.words = words
        self.detail = detail
        self.readings = readings
    }

    /// One log line: "[preflight] system-disk warn: <detail> (free=40 GB …)".
    public var logLine: String {
        let numbers = readings.isEmpty ? "" : " (" + readings.map(\.logText).joined(separator: ", ") + ")"
        return "[preflight] \(id.rawValue) \(level): \(detail)\(numbers)"
    }
}

/// Everything one preflight run found.
public struct PreflightReport: Sendable, Equatable {
    /// In the fixed order the checklist runs them.
    public var checks: [PreflightCheck]
    /// Wall time of the fast phase and of quick_check (nil when not run).
    public var fastElapsed: Duration
    public var quickCheckElapsed: Duration?
    /// What the catalog disk holds back right now (PreflightGate.hold).
    public var hold: PreflightHold

    public init(checks: [PreflightCheck], fastElapsed: Duration, quickCheckElapsed: Duration? = nil,
                hold: PreflightHold = .none) {
        self.checks = checks
        self.fastElapsed = fastElapsed
        self.quickCheckElapsed = quickCheckElapsed
        self.hold = hold
    }

    /// The worst level wins; an empty report is ok.
    public var level: PreflightLevel { checks.map(\.level).max() ?? .ok }

    public var showsBanner: Bool { level.showsBanner }

    /// The checks that need the person's attention, worst first, in checklist order within a level.
    public var problems: [PreflightCheck] {
        checks.filter { $0.level > .ok }
            .enumerated()
            .sorted { ($0.element.level, -$0.offset) > ($1.element.level, -$1.offset) }
            .map(\.element)
    }

    /// One sentence for the banner: the worst check's words, plus how many
    /// more things want a look. "All set" when nothing is wrong.
    public var summary: String {
        let shown = problems
        guard let first = shown.first else { return "All set" }
        let others = shown.dropFirst().filter { $0.level >= .warn }.count
        switch others {
        case 0: return first.words
        case 1: return first.words + " (and 1 more thing in Catalog Status)"
        default: return first.words + " (and \(others) more things in Catalog Status)"
        }
    }

    /// START is logged by the caller before `run`; these are the per-check
    /// lines (non-ok only, plus every reading on the disks) and the OUTCOME.
    public var logLines: [String] {
        let checkLines = checks.filter { $0.level > .ok || $0.id == .systemDisk || $0.id == .tempDisk }
            .map(\.logLine)
        return checkLines + [outcomeLine]
    }

    public var outcomeLine: String {
        let quick = quickCheckElapsed.map { ", quick_check \(PreflightWords.milliseconds($0))" } ?? ""
        let counts = PreflightLevel.allCases.reversed()
            .map { level in "\(checks.filter { $0.level == level }.count) \(level)" }
            .joined(separator: ", ")
        return "[preflight] OUTCOME \(level): \(summary) — \(counts); hold \(hold); fast \(PreflightWords.milliseconds(fastElapsed))\(quick)"
    }
}

// MARK: - Inputs

/// Where things are on this Mac. `standard` is the app's real layout.
public struct PreflightContext: Sendable {
    /// ~/Library/Application Support/VideoScan — the "system disk" is the
    /// volume holding this folder.
    public var supportFolder: URL
    public var databaseURL: URL
    public var temporaryFolder: URL
    public var logFolder: URL
    /// Mount point of the Master Archive drive; nil when none is set.
    public var masterArchiveVolume: URL?
    public var expectedSchemaVersion: Int
    public var quickCheckBudget: Duration
    public var thresholds: PreflightThresholds

    public init(supportFolder: URL, databaseURL: URL, temporaryFolder: URL, logFolder: URL,
                masterArchiveVolume: URL?, expectedSchemaVersion: Int,
                quickCheckBudget: Duration = PreflightThresholds.quickCheckBudget,
                thresholds: PreflightThresholds = PreflightThresholds()) {
        self.supportFolder = supportFolder
        self.databaseURL = databaseURL
        self.temporaryFolder = temporaryFolder
        self.logFolder = logFolder
        self.masterArchiveVolume = masterArchiveVolume
        self.expectedSchemaVersion = expectedSchemaVersion
        self.quickCheckBudget = quickCheckBudget
        self.thresholds = thresholds
    }

    /// The real layout: Application Support/VideoScan/catalog.sqlite,
    /// ~/Library/Logs/VideoScan, the process temp folder, and the schema
    /// version this build's store migrates to.
    public static func standard(masterArchiveVolume: URL?, fileManager: FileManager = .default) -> PreflightContext {
        let database = SQLiteCatalogReader.defaultDatabaseURL(fileManager: fileManager)
        let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        return PreflightContext(
            supportFolder: database.deletingLastPathComponent(),
            databaseURL: database,
            temporaryFolder: fileManager.temporaryDirectory,
            logFolder: library.appendingPathComponent("Logs", isDirectory: true)
                .appendingPathComponent("VideoScan", isDirectory: true),
            masterArchiveVolume: masterArchiveVolume,
            expectedSchemaVersion: CatalogPreflightReader.expectedSchemaVersion)
    }

    var latchURL: URL {
        databaseURL.deletingLastPathComponent().appendingPathComponent(SQLiteCatalogReader.latchFileName)
    }

    var walURL: URL {
        URL(fileURLWithPath: databaseURL.path + "-wal")
    }
}

// MARK: - The run

public enum LaunchPreflight {

    /// The fast phase: every check but quick_check, in checklist order.
    /// Synchronous and cheap (< 200 ms); call it from `run`, or directly
    /// before an MFO job starts (the disk checks are the first two).
    public static func fastChecks(_ context: PreflightContext, probe: some PreflightProbe) -> [PreflightCheck] {
        let rules = PreflightRules(context: context, probe: probe)
        return head(rules) + tail(rules)
    }

    /// Disks, memory and the catalog: quick_check, when it runs, goes right after these.
    private static func head<P: PreflightProbe>(_ rules: PreflightRules<P>) -> [PreflightCheck] {
        rules.diskChecks() + [rules.memory(), rules.swap()] + rules.catalogChecks()
    }

    private static func tail<P: PreflightProbe>(_ rules: PreflightRules<P>) -> [PreflightCheck] {
        [rules.tools(), rules.logFolder(), rules.thermal(), rules.power(), rules.masterArchive()]
    }

    /// The quick_check phase alone.
    public static func quickCheck(_ context: PreflightContext, probe: some PreflightProbe) -> PreflightCheck {
        PreflightRules(context: context, probe: probe).quickCheck()
    }

    /// The whole checklist, off the main actor. `includeQuickCheck: false`
    /// gives the fast phase only (the 10-minute re-check).
    @concurrent
    public static func run(_ context: PreflightContext, probe: some PreflightProbe,
                           includeQuickCheck: Bool = true) async -> PreflightReport {
        let clock = ContinuousClock()
        let start = clock.now
        let rules = PreflightRules(context: context, probe: probe)   // reads the catalog disk once
        let front = head(rules)
        let back = tail(rules)
        let hold = PreflightGate.hold(catalogVolume: rules.systemVolume(), catalogBytes: rules.catalogBytes(),
                                      thresholds: context.thresholds)
        let fastElapsed = clock.now - start
        guard includeQuickCheck else {
            return PreflightReport(checks: front + back, fastElapsed: fastElapsed, hold: hold)
        }
        let quickStart = clock.now
        let quick = rules.quickCheck()
        let quickElapsed = clock.now - quickStart
        return PreflightReport(checks: front + [quick] + back, fastElapsed: fastElapsed,
                               quickCheckElapsed: quickElapsed, hold: hold)
    }

    /// The START line, logged by the caller just before `run`.
    public static func startLine(_ context: PreflightContext, includeQuickCheck: Bool = true) -> String {
        "[preflight] START catalog \(context.databaseURL.path)"
            + (includeQuickCheck ? ", quick_check budget \(PreflightWords.milliseconds(context.quickCheckBudget))" : ", fast checks only")
    }
}

// MARK: - Number words

enum PreflightWords {
    /// Decimal gigabytes, as Finder shows them: "42 GB", "0.3 GB".
    static func gigabytes(_ bytes: Double) -> String {
        let gb = bytes / 1e9
        return gb >= 10 || gb == 0 ? String(format: "%.0f GB", gb) : String(format: "%.1f GB", gb)
    }

    static func gigabytes<T: BinaryInteger>(_ bytes: T) -> String { gigabytes(Double(bytes)) }

    /// "Free at least 3 GB more": rounded UP so freeing the stated amount is enough.
    static func gigabytesRoundedUp(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1e9
        return gb >= 10 ? String(format: "%.0f GB", gb.rounded(.up))
                        : String(format: "%.1f GB", (gb * 10).rounded(.up) / 10)
    }

    static func percent(_ fraction: Double) -> String {
        // Floor, so 94.9% never reads as "95% full" next to a warn-only banner.
        // The epsilon keeps a 0.95 that multiplies out to 94.999… at "95%".
        "\(Int((fraction * 100 + 1e-9).rounded(.down)))%"
    }

    static func milliseconds(_ duration: Duration) -> String {
        String(format: "%.0f ms", TimingBudget.seconds(duration) * 1_000)
    }
}
