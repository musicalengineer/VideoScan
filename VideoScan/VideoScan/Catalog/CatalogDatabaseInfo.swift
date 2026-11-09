// CatalogDatabaseInfo.swift — Catalog ▸ Catalog Database Info… (Rick
// 2026-11-01, BACKLOG "Catalog ▸ Catalog Info"): one read-only window about
// the catalog DATABASE (not a volume — that is ⌘I "Catalog Info",
// CatalogInfoWindow.swift, untouched).
//
// Shape: a small feature store behind a seam (rule 12, #337) — nothing here
// extends VideoScanModel. Three pieces:
//   * `CatalogDatabaseInfoSources` — WHERE to read (paths, the running sync
//     role, the defaults suite), resolved on the main actor each time the
//     window reads, so a catalog opened after the window still counts;
//   * `CatalogDatabaseInfoGather.read` — the read, `@concurrent` (off the
//     main actor): stat of the three files, Core's one read-only SQLite open
//     (CatalogDatabaseInfoReader), the backup defaults, last_sync.txt, the
//     journal folder, integrity-latest.json. Nothing is taken from a field
//     the app keeps (hard rule 1): every line is read at open time;
//   * `CatalogDatabaseInfoLines.build` — pure: facts → label/value/help rows;
//     a missing source is "unknown — <why>", never a blank or a zero.
// The window (CatalogDatabaseInfoView.swift) only shows the rows.
//
// Writes: none. No committer, no repository, no write door is reachable
// from here (CatalogDatabaseInfoSensorTests pins it). The one file the read
// may create is the EMPTY -wal of a WAL-mode catalog that lost it (#386,
// create-only, as the launch preflight does); sizes are stat'ed first.
//
// Cost: O(1) in records except two `count(*)` b-tree walks (9 ms at 100k
// rows, CatalogDatabaseInfoReaderTests) and the journal count (streams the
// unapplied bytes once, 1 MB buffer — JournalApplier.count). Worst-case
// memory: the 1 MB journal buffer + SQLite's ≈ 2 MB page cache + the
// integrity report (≤ 5,000 findings, a few MB), all freed when the read
// returns; the window keeps ~14 short strings.
//
// (For Rick: `@concurrent` ≈ "always run this on the thread pool, never on
// the caller's thread"; `@MainActor final class … ObservableObject` ≈ a UI-
// thread-only view model whose `@Published` members repaint the window.)

import AppKit
import Combine
import Foundation
import VideoScanCore

// MARK: - Where to read

struct CatalogDatabaseInfoSources: Sendable, Equatable {
    /// catalog.sqlite.
    var databaseURL: URL
    /// False when the app has not opened catalog.sqlite this session (the
    /// path is then where it WOULD be); said on the path line.
    var databaseOpenThisSession: Bool
    /// catalog.json's path — every sidecar (integrity-latest.json,
    /// catalog.cutover, background/journal) lives beside it.
    var catalogFile: URL
    /// background/journal beside the catalog.
    var journalFolder: URL
    /// CatalogSync's last_sync.txt.
    var lastSyncFile: URL
    /// The running sync engine's mode (decided at launch); nil = not known.
    var sessionRole: CatalogSyncMode?
    var localHostname: String
    var masterHostname: String
    /// nil = UserDefaults.standard (tests pass their own suite).
    var defaultsSuite: String?

    /// The live app's sources, read from the model and sync engine NOW.
    /// The database is the one this role shows (CatalogAuthority.databaseURL:
    /// a viewer's is the master's synced snapshot, Codex 11/03 F1).
    @MainActor
    static func live(model: VideoScanModel, sync: CatalogSync?) -> CatalogDatabaseInfoSources {
        let catalogFile = URL(fileURLWithPath: model.catalogStore.fileLocation)
        let folder = catalogFile.deletingLastPathComponent()
        let opened = model.catalogCutover.databaseURL
        let role = sync?.mode ?? CatalogSync.launchMode()
        return CatalogDatabaseInfoSources(
            databaseURL: CatalogAuthority.databaseURL(role: role, opened: opened, catalogFile: catalogFile),
            databaseOpenThisSession: role == .viewer || opened != nil,
            catalogFile: catalogFile,
            journalFolder: folder.appendingPathComponent("background/journal", isDirectory: true),
            lastSyncFile: CatalogSyncPaths.standard().lastSyncFile,
            sessionRole: sync?.mode,
            localHostname: SystemHostnameSource().currentHostname(),
            masterHostname: CatalogSync.masterHostname(defaults: .standard),
            defaultsSuite: nil)
    }
}

// MARK: - What was read

struct CatalogFileSizes: Sendable, Equatable {
    var database: Int64
    /// nil = no -wal beside it.
    var wal: Int64?
    /// nil = no -shm beside it.
    var shm: Int64?
    var total: Int64 { database + (wal ?? 0) + (shm ?? 0) }
}

struct CatalogBackupFacts: Sendable, Equatable {
    /// `VideoScan.lastBackupAt`; nil = never on this Mac.
    var at: Date?
    /// `VideoScan.lastBackupPath`.
    var path: String?
    /// Whether something is at `path` now (stat at open time); nil = no path.
    var pathExists: Bool?
}

struct CatalogIntegrityVerdict: Sendable, Equatable {
    /// The strict read of integrity-latest.json, as Catalog Status takes it.
    var facts: IntegrityReportFacts
    /// The report's own dates (nil when there is no readable report).
    var startedAt: Date?
    var verifiedAt: Date?
    var outcome: IntegrityReport.Outcome?
    /// The read said "missing" (no file).
    var missing: Bool
}

struct CatalogDatabaseInfoSnapshot: Sendable, Equatable {
    var sources: CatalogDatabaseInfoSources
    var readAt: Date
    var database: CatalogDatabaseFacts
    var sizes: CatalogDatabaseReading<CatalogFileSizes>
    var backup: CatalogBackupFacts
    var lastSync: CatalogDatabaseReading<Date>
    var journal: CatalogDatabaseReading<JournalApplier.Counts>
    var integrity: CatalogIntegrityVerdict
}

enum CatalogDatabaseInfoGather {

    /// Every fact, read now, off the main actor. Never throws.
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func read(_ sources: CatalogDatabaseInfoSources, now: Date = Date()) async -> CatalogDatabaseInfoSnapshot {
        readNow(sources, now: now)
    }

    /// The same read, synchronous (tests; the async door above is the app's).
    nonisolated static func readNow(_ sources: CatalogDatabaseInfoSources, now: Date = Date()) -> CatalogDatabaseInfoSnapshot {
        // Sizes FIRST: the read-only open may restore a missing -wal (#386).
        let sizes = fileSizes(sources.databaseURL)
        return CatalogDatabaseInfoSnapshot(
            sources: sources, readAt: now,
            database: CatalogDatabaseInfoReader.read(at: sources.databaseURL),
            sizes: sizes,
            backup: backup(suite: sources.defaultsSuite),
            lastSync: lastSync(sources.lastSyncFile),
            journal: journal(sources.journalFolder),
            integrity: integrity(catalogFile: sources.catalogFile))
    }

    nonisolated static func fileSizes(_ database: URL) -> CatalogDatabaseReading<CatalogFileSizes> {
        func size(_ path: String) -> Int64? {
            (try? FileManager.default.attributesOfItem(atPath: path))?[.size].flatMap { ($0 as? NSNumber)?.int64Value }
        }
        guard let main = size(database.path) else { return .unknown("no file at \(database.path)") }
        return .known(CatalogFileSizes(database: main, wal: size(database.path + "-wal"), shm: size(database.path + "-shm")))
    }

    nonisolated static func backup(suite: String?) -> CatalogBackupFacts {
        let defaults = suite.flatMap { UserDefaults(suiteName: $0) } ?? .standard
        let t = defaults.double(forKey: "VideoScan.lastBackupAt")
        let path = defaults.string(forKey: "VideoScan.lastBackupPath")
        return CatalogBackupFacts(at: t > 0 ? Date(timeIntervalSince1970: t) : nil, path: path,
                                  pathExists: path.map { FileManager.default.fileExists(atPath: $0) })
    }

    nonisolated static func lastSync(_ file: URL) -> CatalogDatabaseReading<Date> {
        guard FileManager.default.fileExists(atPath: file.path) else {
            return .unknown("no \(file.lastPathComponent) — this Mac has not pulled a catalog from the master")
        }
        guard let date = CatalogSync.readLastSyncTimestamp(at: file) else {
            return .unknown("\(file.lastPathComponent) can't be read as a date")
        }
        return .known(date)
    }

    nonisolated static func journal(_ folder: URL) -> CatalogDatabaseReading<JournalApplier.Counts> {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
            return .unknown("no background/journal folder beside the catalog — the background helper has not written here")
        }
        return .known(JournalApplier.count(ObservationJournal(directory: folder)))
    }

    /// The same strict read Catalog Status trusts (CatalogFreshnessFactsReader.integrityFacts).
    nonisolated static func integrity(catalogFile: URL) -> CatalogIntegrityVerdict {
        let read = IntegrityReportStore.read(besideCatalogAt: catalogFile)
        let switchedAt = CatalogFreshnessFactsReader.cutoverSwitchedAt(in: catalogFile.deletingLastPathComponent())
        let report = read.report
        return CatalogIntegrityVerdict(facts: IntegrityReportFacts.from(read, switchedAt: switchedAt),
                                       startedAt: report?.startedAt, verifiedAt: report?.verifiedAt,
                                       outcome: report?.outcome, missing: read == .missing)
    }
}

// MARK: - The rows (pure)

struct CatalogDatabaseInfoLine: Sendable, Equatable, Identifiable {
    var label: String
    var value: String
    /// Where the value came from (the row's tooltip).
    var source: String
    /// False when the value is "unknown — …".
    var known: Bool
    var id: String { label }
}

enum CatalogDatabaseInfoLines {

    static let unknownPrefix = "unknown — "

    nonisolated static func build(_ s: CatalogDatabaseInfoSnapshot,
                                  date: (Date) -> String = { $0.formatted(date: .abbreviated, time: .shortened) })
        -> [CatalogDatabaseInfoLine] {
        let db = s.database
        var rows: [CatalogDatabaseInfoLine] = []
        func add(_ label: String, _ reading: CatalogDatabaseReading<String>, _ source: String) {
            switch reading {
            case .known(let v): rows.append(CatalogDatabaseInfoLine(label: label, value: v, source: source, known: true))
            case .unknown(let why): rows.append(CatalogDatabaseInfoLine(label: label, value: unknownPrefix + why, source: source, known: false))
            }
        }
        add("Schema", schema(db), "PRAGMA user_version and catalog_state.schema_version, read from the file now")
        add("Schema layout", layout(db.schemaLayout),
            "sqlite_master's tables against the tables this build's migrations create (no integrity check here — that is Validate Catalog)")
        add("Database", .known(databasePath(s.sources)),
            "the catalog.sqlite this session shows (a viewer's is the master's synced copy), or where it would be")
        add("Size", map(s.sizes) { sizes($0) }, "stat of catalog.sqlite, -wal and -shm, now")
        add("Generation", map(db.generation) { $0.formatted() }, "generations.generation, read from the file now")
        add("Contents", map(db.contents) { $0.formatted() }, "count of content rows (one per whole-file SHA-256)")
        add("Live files", map(db.liveFiles) { $0.formatted() }, "count of files rows with no removal marker")
        add("Records", map(db.records) { "\($0.formatted()) (live and removed; rows are never deleted)" }, "count of every files row")
        add("Last commit", map(db.lastCommit) { c in
                "\(date(c.committedAt)) · generation \(c.generation.formatted()) · via \(c.writer)\(c.kind == "adopt" ? " (adoption)" : "") · \(c.host)"
            }, "from the store: generation_history's newest row (committed_at, writer = the commit door, host)")
        add("Last backup the app made", backup(s.backup, date: date, now: s.readAt),
            "VideoScan.lastBackupAt / lastBackupPath in this Mac's defaults (written by Back Up Catalog…); the path is checked now")
        add("This Mac's role", role(s.sources), "the sync engine's mode, decided at launch from this Mac's name and CatalogSyncMasterHostname")
        add("Last sync", lastSync(s, date: date), "last_sync.txt, written by a viewer's successful pull")
        add("Background journal", map(s.journal) { "\($0.waiting.formatted()) line\($0.waiting == 1 ? "" : "s") waiting · \($0.refused.formatted()) refused" },
            "counted now from background/journal: lines past each file's applied cursor, and refused.jsonl")
        add("Last Validate Catalog", validate(s.integrity, date: date),
            "integrity-latest.json beside the catalog — the same report Catalog Status reads")
        return rows
    }

    /// Plain text for the clipboard: "Label: value", one per line.
    nonisolated static func plainText(_ rows: [CatalogDatabaseInfoLine], readAt: Date?) -> String {
        var out = ["Catalog Database"]
        if let readAt { out.append("Read at \(readAt.formatted(date: .abbreviated, time: .standard))") }
        out += rows.map { "\($0.label): \($0.value)" }
        return out.joined(separator: "\n")
    }

    // MARK: Words

    nonisolated static func schema(_ db: CatalogDatabaseFacts) -> CatalogDatabaseReading<String> {
        let expected = CatalogDatabaseInfoReader.expectedSchemaVersion
        switch (db.schemaVersion, db.userVersion) {
        case (.known(let state), .known(let pragma)):
            var words = "Schema \(state)"
            if pragma != state { words += " — PRAGMA user_version says \(pragma); the two disagree" }
            if state != expected { words += " — this build expects \(expected)" }
            return .known(words)
        case (.known(let state), .unknown(let why)):
            return .known("Schema \(state) — PRAGMA user_version unknown (\(why))")
        case (.unknown(let why), .known(let pragma)):
            return .unknown("\(why); PRAGMA user_version says \(pragma)")
        case (.unknown(let why), .unknown):
            return .unknown(why)
        }
    }

    nonisolated static func layout(_ r: CatalogDatabaseReading<CatalogSchemaLayout>) -> CatalogDatabaseReading<String> {
        map(r) { l in
            let tables = "\(l.tableCount) table\(l.tableCount == 1 ? "" : "s")"
            if l.matches { return "\(tables) · matches this build" }
            var parts: [String] = []
            if !l.extra.isEmpty { parts.append("not in this build: " + l.extra.joined(separator: ", ")) }
            if !l.missing.isEmpty { parts.append("missing: " + l.missing.joined(separator: ", ")) }
            return "\(tables) · differs from this build — " + parts.joined(separator: " · ")
        }
    }

    nonisolated static func sizes(_ s: CatalogFileSizes) -> String {
        func b(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
        return "\(b(s.total)) (catalog.sqlite \(b(s.database)) · -wal \(s.wal.map(b) ?? "absent") · -shm \(s.shm.map(b) ?? "absent"))"
    }

    /// `now` = the read's time: a backup 7 days or more old says so (the
    /// 7-day reminder, CatalogReminderClock); nil = no reminder (old callers).
    nonisolated static func backup(_ b: CatalogBackupFacts, date: (Date) -> String, now: Date? = nil) -> CatalogDatabaseReading<String> {
        guard let at = b.at else { return .unknown("no backup recorded on this Mac (VideoScan.lastBackupAt is not set)") }
        let reminder = now.map { CatalogReminderClock.infoSuffix(last: at, now: $0) } ?? ""
        guard let path = b.path else { return .known("\(date(at)) — destination not recorded" + reminder) }
        return .known("\(date(at)) → \(path)" + (b.pathExists == false ? " (nothing is at that path now)" : "") + reminder)
    }

    /// The path, and what it is to this session.
    nonisolated static func databasePath(_ s: CatalogDatabaseInfoSources) -> String {
        if s.sessionRole == .viewer { return s.databaseURL.path + " (the master's synced copy, read-only)" }
        return s.databaseURL.path + (s.databaseOpenThisSession ? "" : " (not opened this session)")
    }

    nonisolated static func role(_ s: CatalogDatabaseInfoSources) -> CatalogDatabaseReading<String> {
        switch s.sessionRole {
        case .master?: return .known("Master — \(s.localHostname) writes the catalog")
        case .viewer?: return .known("Viewer — read-only; the master is \(s.masterHostname) (this Mac is \(s.localHostname))")
        case nil: return .unknown("the sync engine has not started this session")
        }
    }

    nonisolated static func lastSync(_ s: CatalogDatabaseInfoSnapshot, date: (Date) -> String) -> CatalogDatabaseReading<String> {
        if case .known(let d) = s.lastSync { return .known(date(d) + CatalogReminderClock.infoSuffix(last: d, now: s.readAt)) }
        if s.sources.sessionRole == .master {
            return .known("not applicable — the master publishes; viewers pull")
        }
        return map(s.lastSync) { date($0) }
    }

    nonisolated static func validate(_ v: CatalogIntegrityVerdict, date: (Date) -> String, now: Date = Date()) -> CatalogDatabaseReading<String> {
        let f = v.facts
        if v.missing { return .unknown("no \(IntegrityReportStore.latestFileName) beside the catalog — Validate Catalog has not run here") }
        if let problem = f.problem { return .unknown(problem) }
        if f.predatesSwitch { return .unknown("the last report was made from catalog.json, before the switch to SQLite") }
        guard let outcome = v.outcome else { return .unknown("the report could not be read") }
        var tail: [String] = []
        if f.needsDecision > 0 { tail.append("\(f.needsDecision.formatted()) need\(f.needsDecision == 1 ? "s" : "") a decision") }
        if f.unverified > 0 { tail.append("\(f.unverified.formatted()) unverified") }
        let rest = tail.isEmpty ? "" : " · " + tail.joined(separator: " · ")
        switch outcome {
        case .completed:
            let at = v.verifiedAt ?? v.startedAt ?? .distantPast
            // The report's own date, or the date its facts claim (a future tier — closing pass C2).
            let claims = [at] + [f.lastCompleted].compactMap { $0 }
            if claims.contains(where: { CatalogRealityPolicy.age(of: $0, now: now) == .future }) {
                // Codex sweep 11/09 re-review F1: never "nothing to decide" on a date that proves nothing.
                return .known("completed \(date(at)) — dated in the future; no proof (a clock change or a copied record) — run Validate Catalog again" + rest)
            }
            return .known("completed \(date(at))" + (tail.isEmpty ? " · nothing to decide" : rest))
        case .stopped:
            return .known("stopped — started \(v.startedAt.map(date) ?? "at an unknown time"); not a full check" + rest)
        case .failed:
            return .known("failed — started \(v.startedAt.map(date) ?? "at an unknown time")" + rest)
        }
    }

    private nonisolated static func map<T>(_ r: CatalogDatabaseReading<T>, _ f: (T) -> String) -> CatalogDatabaseReading<String> {
        switch r {
        case .known(let v): return .known(f(v))
        case .unknown(let why): return .unknown(why)
        }
    }
}

// MARK: - The window's store

@MainActor
final class CatalogDatabaseInfoModel: ObservableObject {
    @Published private(set) var lines: [CatalogDatabaseInfoLine] = []
    @Published private(set) var readAt: Date?
    @Published private(set) var isReading = false
    private let sources: @MainActor () -> CatalogDatabaseInfoSources
    /// The one log sink (Codex 11/03 F6): every "unknown — <why>" the window
    /// shows is logged when it appears, changes or clears — one line per
    /// refresh that changed any, never per refresh.
    private let log: (String) -> Void
    /// label → the unknown words last logged.
    private var saidUnknown: [String: String] = [:]

    init(sources: @escaping @MainActor () -> CatalogDatabaseInfoSources, log: @escaping (String) -> Void = { _ in }) {
        self.sources = sources
        self.log = log
    }

    /// Read everything again, off the main actor; publish the rows.
    func refresh() async {
        guard !isReading else { return }
        isReading = true
        let snapshot = await CatalogDatabaseInfoGather.read(sources())
        lines = CatalogDatabaseInfoLines.build(snapshot)
        readAt = snapshot.readAt
        isReading = false
        if let line = Self.unknownChanges(was: saidUnknown, now: lines, database: snapshot.sources.databaseURL.path) {
            log(line)
        }
        saidUnknown = Dictionary(uniqueKeysWithValues: lines.filter { !$0.known }.map { ($0.label, $0.value) })
    }

    /// Pure: nil when the unknown facts are the ones already said.
    nonisolated static func unknownChanges(was: [String: String], now rows: [CatalogDatabaseInfoLine], database: String) -> String? {
        let now = Dictionary(uniqueKeysWithValues: rows.filter { !$0.known }.map { ($0.label, $0.value) })
        guard now != was else { return nil }
        var parts: [String] = []
        for row in rows where !row.known && was[row.label] != row.value { parts.append("\(row.label): \(row.value)") }
        for label in was.keys.sorted() where now[label] == nil { parts.append("\(label): known again") }
        return "Catalog Database Info (\(database)) — " + parts.joined(separator: " · ")
    }

    var plainText: String { CatalogDatabaseInfoLines.plainText(lines, readAt: readAt) }

    func copyToClipboard(_ pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(plainText, forType: .string)
    }
}
