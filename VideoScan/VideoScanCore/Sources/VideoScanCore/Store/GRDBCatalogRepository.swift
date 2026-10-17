// GRDBCatalogRepository.swift (VideoScanCore/Store)
// The SQLite plugin behind CatalogRepository, through GRDB 7 (pinned in
// Package.swift). Step C′ part 1: bookkeeping only — the data tables and
// the record methods are part 2.
//
// What this file guarantees (contract §9.2, §9.5, §e.9, F8r3):
//   - every connection runs foreign_keys=ON, synchronous=FULL, fullfsync=1
//     (macOS: FULL alone stops at the drive's cache), a busy timeout, WAL;
//   - at open: integrity_check + foreign_key_check → `.refused` with the
//     engine's words; a NEWER schema_version → `.refused`; exactly one
//     catalog_state row and one generations row;
//   - a write is ONE immediate transaction: body, then the generation CAS
//     (`changes() == 1` or `.generationMismatch`), then the external
//     high-water raised to g+1 (phase 1), then the history row, then COMMIT
//     (phase 2). A crash between the phases leaves highwater > generation,
//     which the next open reports as read-only until a person adopts;
//   - adoption is the only jump larger than +1, and the DDL's triggers —
//     not this file — are what refuse any other jump.
//
// Every statement that touches `generations`, `generation_history` or
// `catalog_state` is raw SQL (Rick, 2026-10-17) so it reads like the DDL;
// CatalogStoreSensorTests fails if a query-builder call appears here.
// `DatabasePool` is created in exactly one function (`makePool`).
//
// Durability is chosen ONCE, at construction, and the reason is in the
// enum's doc comments. `.volatileForTests` exists so the 100k-advance
// scale test measures the store, not the drive's fsync latency; no
// production code may pass it (the sensor checks that too).
//
// For Rick: `actor` ≈ a class with an implicit mutex around all members;
// `await` on its methods is "take the mutex, possibly waiting". The GRDB
// pool has its own serial writer queue underneath, so the two never nest
// the wrong way round: the actor hands the closure to the pool and
// suspends until the pool is done.

import Foundation
import GRDB
import os

private let storeLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "catalogStore")

public actor GRDBCatalogRepository: CatalogRepository {

    // MARK: - Configuration

    public enum Durability: Sendable {
        /// Production. `synchronous=FULL` + `fullfsync=1` on every
        /// connection, and the high-water file is F_FULLFSYNC'd before its
        /// rename. A commit returns only after the drive has it. This is
        /// the only setting the app may use: the catalog is curated data.
        case archival
        /// Test suites ONLY. `synchronous=NORMAL`, no fullfsync, the
        /// high-water is rename-only. Survives a process crash, not a
        /// power loss — fine for a temp directory that is deleted after
        /// the test, wrong for anything Rick typed.
        case volatileForTests

        var synchronous: String { self == .archival ? "FULL" : "NORMAL" }
        var fullfsync: Int { self == .archival ? 1 : 0 }
        var publish: AtomicFilePublish.Durability { self == .archival ? .fullFsync : .fast }
    }

    /// How long a writer waits for SQLite's lock before giving up. Two
    /// processes on one catalog are governed by the writer/viewer policy;
    /// this is only the courtesy wait for a checkpoint in flight.
    public static let busyTimeoutSeconds: TimeInterval = 5

    /// `Host.current().localizedName` — the Mac's name as the person sees
    /// it in Sharing, which is what the JSON catalog's `savedFromHost`
    /// carries too. Not `ProcessInfo.hostName`, which may block on DNS.
    public static var defaultHost: String { Host.current().localizedName ?? "unknown" }

    // MARK: - State

    private enum Mode: Equatable {
        case closed
        case readWrite
        case readOnly(reason: String)

        var outcome: CatalogOpenOutcome {
            switch self {
            case .closed: return .refused(reason: "not open")
            case .readWrite: return .readWrite
            case .readOnly(let reason): return .readOnly(reason: reason)
            }
        }
    }

    /// A check that said no. Thrown inside `open` / `verify` and turned
    /// into the outcome's words; never escapes this file.
    private struct Refusal: Error {
        let reason: String
    }

    public let host: String
    private let durability: Durability
    private var pool: DatabasePool?
    private var databaseURL: URL?
    private var mode: Mode = .closed
    private var committedGeneration = 0
    /// Test seam: runs after phase 1 (high-water raised) and before COMMIT.
    /// A throw here is "the process died between the phases".
    private var crashBeforeCommit: (@Sendable () throws -> Void)?

    public init(host: String = GRDBCatalogRepository.defaultHost,
                durability: Durability = .archival) {
        self.host = host
        self.durability = durability
    }

    public var generation: Int { committedGeneration }

    // MARK: - Open

    public func open(at url: URL) async -> CatalogOpenOutcome {
        guard pool == nil else {
            return .refused(reason: "already open at \(databaseURL?.path ?? "?")")
        }
        let opened: Opened
        do {
            opened = try Self.openPool(at: url, durability: durability)
        } catch {
            return refusedToOpen(url, "could not open: \(Self.words(error))")
        }
        do {
            let loaded = try await Self.prepare(opened, host: host)
            let readOnlyReason = opened.readOnlyReason ?? Self.folderNotWritableReason(for: url)
            let newMode = readOnlyReason.map { Mode.readOnly(reason: $0) }
                ?? Self.reconcileHighWater(generation: loaded, at: url, durability: durability)
            pool = opened.pool
            databaseURL = url
            committedGeneration = loaded
            mode = newMode
            storeLog.notice("catalog store OPEN \(url.lastPathComponent, privacy: .public) generation \(loaded, privacy: .public) → \(String(describing: newMode.outcome), privacy: .public)")
            return newMode.outcome
        } catch {
            try? opened.pool.close()
            return refusedToOpen(url, Self.words(error))
        }
    }

    private func refusedToOpen(_ url: URL, _ reason: String) -> CatalogOpenOutcome {
        storeLog.error("catalog store OPEN REFUSED \(url.lastPathComponent, privacy: .public): \(reason, privacy: .public)")
        return .refused(reason: reason)
    }

    /// Every write publishes a new high-water file beside the database, so
    /// a folder that cannot take a new file cannot take a write — say so at
    /// open, before anything is attempted (refuse before mutating).
    private static func folderNotWritableReason(for url: URL) -> String? {
        let folder = url.deletingLastPathComponent().path
        guard !FileManager.default.isWritableFile(atPath: folder) else { return nil }
        return "the folder \(folder) is not writable — opened for reading only"
    }

    private struct Opened {
        let pool: DatabasePool
        /// Non-nil when the folder refused a read-write open and the file
        /// was opened read-only instead (a sealed copy, a read-only volume).
        let readOnlyReason: String?
    }

    private static func openPool(at url: URL, durability: Durability) throws -> Opened {
        do {
            return Opened(pool: try makePool(at: url, durability: durability, readonly: false),
                          readOnlyReason: nil)
        } catch let error as DatabaseError
                    where FileManager.default.fileExists(atPath: url.path)
                    && (error.resultCode == .SQLITE_READONLY || error.resultCode == .SQLITE_CANTOPEN) {
            let pool = try makePool(at: url, durability: durability, readonly: true)
            let folder = url.deletingLastPathComponent().path
            return Opened(pool: pool,
                          readOnlyReason: "the folder \(folder) is not writable (\(error.message ?? "")) — opened for reading only")
        }
    }

    /// The ONE place a `DatabasePool` is created (CatalogStoreSensorTests
    /// pins it). Every pragma the contract names is set here, per
    /// connection, so a reader cannot drift from the writer.
    private static func makePool(at url: URL, durability: Durability, readonly: Bool) throws -> DatabasePool {
        var configuration = Configuration()
        configuration.label = "VideoScan.catalog"
        configuration.readonly = readonly
        configuration.foreignKeysEnabled = true                       // PRAGMA foreign_keys = ON
        let synchronous = durability.synchronous
        let fullfsync = durability.fullfsync
        let busyMilliseconds = Int(busyTimeoutSeconds * 1_000)
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = \(synchronous)")
            try db.execute(sql: "PRAGMA fullfsync = \(fullfsync)")
            // The engine's own busy handler (not GRDB's `busyMode`, which
            // installs a callback the pragma cannot report back).
            try db.execute(sql: "PRAGMA busy_timeout = \(busyMilliseconds)")
        }
        // journal_mode = WAL is DatabasePool's own invariant; it sets it.
        return try DatabasePool(path: url.path, configuration: configuration)
    }

    /// The open checks, in the order the DDL's §11 lists them. Throws a
    /// `Refusal` (words for the person) or an engine error.
    private static func prepare(_ opened: Opened, host: String) async throws -> Int {
        try await checkEngine(opened.pool)
        try await checkSchemaVersion(opened.pool)
        if opened.readOnlyReason == nil {
            try migrator(host: host).migrate(opened.pool)
        } else if try await !migrationsComplete(opened.pool, host: host) {
            throw Refusal(reason: "the database is read-only and its schema is not current")
        }
        return try await loadGeneration(opened.pool)
    }

    private static func checkEngine(_ pool: DatabasePool) async throws {
        let (integrity, violations) = try await pool.read { db in
            (try String.fetchAll(db, sql: "PRAGMA integrity_check"),
             try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").count)
        }
        guard integrity == ["ok"] else {
            throw Refusal(reason: "integrity_check: \(integrity.joined(separator: "; "))")
        }
        guard violations == 0 else {
            throw Refusal(reason: "foreign_key_check: \(violations) violation(s)")
        }
    }

    private static func checkSchemaVersion(_ pool: DatabasePool) async throws {
        let found = try await pool.read { db -> Int? in
            guard try db.tableExists("catalog_state") else { return nil }
            return try Int.fetchOne(db, sql: "SELECT schema_version FROM catalog_state WHERE singleton = 1")
        }
        if let found, found > CatalogBookkeepingSchema.schemaVersion {
            throw Refusal(reason: "schema version \(found) is newer than this build understands (\(CatalogBookkeepingSchema.schemaVersion)) — open it with a newer VideoScan")
        }
    }

    private static func loadGeneration(_ pool: DatabasePool) async throws -> Int {
        try await pool.read { db in
            let states = try Int.fetchOne(db, sql: "SELECT count(*) FROM catalog_state") ?? 0
            let counters = try Int.fetchOne(db, sql: "SELECT count(*) FROM generations") ?? 0
            guard states == 1, counters == 1 else {
                throw Refusal(reason: "expected one catalog_state row and one generations row, found \(states) and \(counters)")
            }
            return try Int.fetchOne(db, sql: "SELECT generation FROM generations WHERE id = 1") ?? 0
        }
    }

    // MARK: - Migrations

    /// `foreignKeyChecks: .immediate` — foreign keys stay ON for the whole
    /// migration and every statement is checked as it runs; nothing is
    /// deferred to one check at the end. Part 2's data migrations MUST
    /// register the same way. GRDB's one documented exception is a
    /// migration that recreates a table (drop + create under the same
    /// name), which needs `.deferred`; if part 2 ever needs that, the
    /// registration says so beside it.
    private static func migrator(host: String) -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        let now = unixNow()
        let version = CatalogBookkeepingSchema.schemaVersion
        migrator.registerMigration(CatalogBookkeepingSchema.migrationID, foreignKeyChecks: .immediate) { db in
            for statement in CatalogBookkeepingSchema.statements {
                try db.execute(sql: statement)
            }
            try db.execute(sql: "PRAGMA user_version = \(version)")
            try db.execute(sql: "INSERT INTO catalog_state (singleton, schema_version) VALUES (1, ?)",
                           arguments: [version])
            try db.execute(sql: "INSERT INTO generations (id, generation, saved_at, saved_from_host) VALUES (1, 0, ?, ?)",
                           arguments: [now, host])
            try db.execute(sql: "INSERT INTO generation_history (generation, committed_at, host, writer, files_live, files_total) VALUES (0, ?, ?, ?, 0, 0)",
                           arguments: [now, host, CatalogWriter.create.rawValue])
        }
        return migrator
    }

    private static func migrationsComplete(_ pool: DatabasePool, host: String) async throws -> Bool {
        let migrator = migrator(host: host)
        return try await pool.read { db in try migrator.hasCompletedMigrations(db) }
    }

    // MARK: - High-water at open

    /// DDL §11: `highwater > generation` ⇒ read-only with words;
    /// `highwater < generation` ⇒ the file was rolled back, raise it (never
    /// the reverse); missing ⇒ recreate from the database generation (the
    /// ledger's newest `generationHighWater` line is the app's to consult —
    /// part 2); unreadable ⇒ read-only until a person decides.
    private static func reconcileHighWater(generation: Int, at url: URL, durability: Durability) -> Mode {
        switch CatalogHighWater.read(besideDatabaseAt: url) {
        case .value(let highWater) where highWater > generation:
            return .readOnly(reason: restoredBelowHighWaterWords(generation: generation, highWater: highWater))
        case .value(let highWater) where highWater < generation:
            storeLog.notice("catalog store: \(CatalogHighWater.fileName, privacy: .public) read \(highWater, privacy: .public) below generation \(generation, privacy: .public) — raised to the generation")
            return publishHighWater(generation, at: url, durability: durability)
        case .value:
            return .readWrite
        case .missing:
            storeLog.notice("catalog store: no \(CatalogHighWater.fileName, privacy: .public) — recreated at generation \(generation, privacy: .public)")
            return publishHighWater(generation, at: url, durability: durability)
        case .unreadable(let words):
            return .readOnly(reason: "\(words) — writing is disabled until a person adopts a high-water explicitly, or removes the file so it is recreated from the database")
        }
    }

    private static func publishHighWater(_ generation: Int, at url: URL, durability: Durability) -> Mode {
        do {
            try CatalogHighWater.write(generation, besideDatabaseAt: url, durability: durability.publish)
            return .readWrite
        } catch {
            return .readOnly(reason: "\(CatalogHighWater.fileName) could not be written (\(words(error))) — the catalog opened for reading only")
        }
    }

    private static func restoredBelowHighWaterWords(generation: Int, highWater: Int) -> String {
        "restoredBelowHighWater: this catalog is at generation \(generation) but this Mac already wrote generation \(highWater) — it is an older copy (a restore, or a crash between a high-water write and its commit). Open the newer copy, or adopt this one explicitly to write to it again."
    }

    // MARK: - Write (one transaction, CAS, two-phase high-water)

    public func write(as door: CatalogWriter,
                      _ body: @Sendable (any CatalogTransaction) throws -> Void) async -> CatalogWriteOutcome {
        guard let pool, let databaseURL else { return .refused(reason: "not open") }
        if case .readOnly(let reason) = mode { return .refused(reason: "read-only: \(reason)") }
        let plan = WritePlan(expected: committedGeneration, door: door, host: host, databaseURL: databaseURL,
                             publish: durability.publish, crashBeforeCommit: crashBeforeCommit)
        let outcome: CatalogWriteOutcome
        do {
            outcome = try await pool.writeWithoutTransaction { db in try plan.run(db, body) }
        } catch {
            outcome = .refused(reason: "write rolled back: \(Self.words(error))")
        }
        if case .committed(let generation) = outcome {
            committedGeneration = generation
            storeLog.debug("catalog store commit generation \(generation, privacy: .public) via \(door.rawValue, privacy: .public)")
        }
        return outcome
    }

    /// Everything one write needs, captured by value so the closure the
    /// pool runs touches no actor state. For Rick: a plain struct of
    /// `let`s handed to another thread — the Swift way to say "no shared
    /// mutable state crosses here" (`Sendable`).
    private struct WritePlan: Sendable {
        let expected: Int
        let door: CatalogWriter
        let host: String
        let databaseURL: URL
        let publish: AtomicFilePublish.Durability
        let crashBeforeCommit: (@Sendable () throws -> Void)?

        func run(_ db: Database,
                 _ body: @Sendable (any CatalogTransaction) throws -> Void) throws -> CatalogWriteOutcome {
            var outcome: CatalogWriteOutcome = .refused(reason: "the transaction did not run")
            try db.inTransaction(.immediate) {
                outcome = try steps(db, body)
                if case .committed = outcome { return .commit }
                return .rollback
            }
            return outcome
        }

        private func steps(_ db: Database,
                           _ body: @Sendable (any CatalogTransaction) throws -> Void) throws -> CatalogWriteOutcome {
            let next = expected + 1
            let now = unixNow()
            try body(GRDBTransaction(generation: next, db: db))
            // The CAS, against the counter itself. `changes()` is 1 only when
            // the database still read `expected`; the trigger then sees +1.
            try db.execute(sql: "UPDATE generations SET generation = generation + 1, saved_at = ?, saved_from_host = ? WHERE id = 1 AND generation = ?",
                           arguments: [now, host, expected])
            guard db.changesCount == 1 else {
                let found = try Int.fetchOne(db, sql: "SELECT generation FROM generations WHERE id = 1") ?? -1
                return .generationMismatch(expected: expected, found: found)
            }
            // Phase 1 (F8r3): the external mark says `next` BEFORE the commit.
            if let problem = raiseHighWater(to: next) {
                return .refused(reason: problem)
            }
            // files_live / files_total: 0 until part 2 has a `files` table to count.
            try db.execute(sql: "INSERT INTO generation_history (generation, committed_at, host, writer, files_live, files_total, kind, from_generation) VALUES (?, ?, ?, ?, 0, 0, 'commit', NULL)",
                           arguments: [next, now, host, door.rawValue])
            try crashBeforeCommit?()
            return .committed(generation: next)                   // phase 2 is the COMMIT that follows
        }

        /// Never lowers the mark. The write lock is held, so the only way
        /// the file can read above `next` is a mark this session never
        /// learned about — refuse, nothing has committed.
        private func raiseHighWater(to next: Int) -> String? {
            switch CatalogHighWater.read(besideDatabaseAt: databaseURL) {
            case .value(let current) where current > next:
                return "\(CatalogHighWater.fileName) reads \(current), above the generation this write would reach (\(next)) — reopen the catalog"
            case .unreadable(let words):
                return "\(words) — reopen the catalog"
            case .value, .missing:
                break
            }
            do {
                try CatalogHighWater.write(next, besideDatabaseAt: databaseURL, durability: publish)
                return nil
            } catch {
                return "\(CatalogHighWater.fileName) could not be written: \(GRDBCatalogRepository.words(error))"
            }
        }
    }

    /// Internal test seam. See `crashBeforeCommit`.
    func injectCrashBeforeCommit(_ seam: (@Sendable () throws -> Void)?) {
        crashBeforeCommit = seam
    }

    // MARK: - Read

    public func read<T: Sendable>(_ body: @Sendable (any CatalogReader) throws -> T) async throws -> T {
        guard let pool else { throw CatalogRepositoryError.notOpen }
        return try await pool.read { db in
            let generation = try Int.fetchOne(db, sql: "SELECT generation FROM generations WHERE id = 1") ?? 0
            return try body(GRDBReader(generation: generation, db: db))
        }
    }

    /// The pragmas as the engine reports them on a reader connection
    /// (internal: the pragma test queries them back).
    func pragmas() async throws -> [String: String] {
        guard let pool else { throw CatalogRepositoryError.notOpen }
        return try await pool.read { db in
            var reported: [String: String] = [:]
            for name in ["journal_mode", "synchronous", "fullfsync", "foreign_keys", "busy_timeout", "user_version"] {
                reported[name] = try Row.fetchOne(db, sql: "PRAGMA \(name)").map { Self.text($0[0]) } ?? ""
            }
            return reported
        }
    }

    private static func text(_ value: DatabaseValue) -> String {
        switch value.storage {
        case .int64(let number): return String(number)
        case .string(let string): return string
        case .double(let number): return String(number)
        case .blob, .null: return ""
        }
    }

    // MARK: - Verify

    public func verify() async -> CatalogVerifyOutcome {
        guard let pool, let databaseURL else { return .problems(["not open"]) }
        var problems: [String] = []
        var generation = committedGeneration
        do {
            try await Self.checkEngine(pool)
            let bookkeeping = try await pool.read { db in try Self.bookkeepingProblems(db) }
            generation = bookkeeping.generation
            problems += bookkeeping.problems
        } catch {
            problems.append(Self.words(error))
        }
        let highWater: Int
        switch CatalogHighWater.read(besideDatabaseAt: databaseURL) {
        case .value(let value):
            highWater = value
            if value < generation { problems.append("\(CatalogHighWater.fileName) reads \(value), below generation \(generation)") }
            if value > generation { problems.append(Self.restoredBelowHighWaterWords(generation: generation, highWater: value)) }
        case .missing:
            highWater = generation
            problems.append("\(CatalogHighWater.fileName) is missing")
        case .unreadable(let words):
            highWater = generation
            problems.append(words)
        }
        return problems.isEmpty ? .ok(generation: generation, highWater: highWater) : .problems(problems)
    }

    private static func bookkeepingProblems(_ db: Database) throws -> (generation: Int, problems: [String]) {
        var problems: [String] = []
        let states = try Int.fetchOne(db, sql: "SELECT count(*) FROM catalog_state") ?? 0
        if states != 1 { problems.append("catalog_state has \(states) rows, not 1") }
        let version = try Int.fetchOne(db, sql: "SELECT schema_version FROM catalog_state WHERE singleton = 1") ?? -1
        if version != CatalogBookkeepingSchema.schemaVersion { problems.append("schema_version is \(version), expected \(CatalogBookkeepingSchema.schemaVersion)") }
        let counters = try Int.fetchOne(db, sql: "SELECT count(*) FROM generations") ?? 0
        if counters != 1 { problems.append("generations has \(counters) rows, not 1") }
        let generation = try Int.fetchOne(db, sql: "SELECT generation FROM generations WHERE id = 1") ?? -1
        let newest = try Int.fetchOne(db, sql: "SELECT max(generation) FROM generation_history") ?? -1
        if newest != generation { problems.append("generation_history ends at \(newest), the counter reads \(generation)") }
        return (generation, problems)
    }

    // MARK: - Adopt

    public func adopt(toHighWater highWater: Int) async -> CatalogAdoptOutcome {
        guard let pool, let databaseURL else { return .refused(reason: "not open") }
        let from = committedGeneration
        guard highWater > from else {
            return .refused(reason: "nothing to adopt: generation \(from) is not below \(highWater)")
        }
        if let problem = Self.confirmHighWater(highWater, at: databaseURL, durability: durability) {
            return .refused(reason: problem)
        }
        let host = host
        let now = unixNow()
        do {
            let jumped = try await pool.writeWithoutTransaction { db in
                try Self.runAdoption(db, from: from, to: highWater, host: host, now: now)
            }
            guard jumped else { return .refused(reason: "the database no longer reads generation \(from)") }
        } catch {
            return .refused(reason: "adoption rolled back: \(Self.words(error))")
        }
        committedGeneration = highWater
        mode = .readWrite
        storeLog.notice("catalog store ADOPT generation \(from, privacy: .public) → \(highWater, privacy: .public) (\(CatalogHighWater.fileName, privacy: .public)) — writes enabled")
        return .adopted(from: from, to: highWater)
    }

    /// The person's number must be the file's number; when the file is
    /// missing or unreadable, the person's number becomes the file's.
    private static func confirmHighWater(_ highWater: Int, at url: URL, durability: Durability) -> String? {
        switch CatalogHighWater.read(besideDatabaseAt: url) {
        case .value(let current) where current != highWater:
            return "\(CatalogHighWater.fileName) reads \(current), not \(highWater) — adopt the value it holds"
        case .value:
            return nil
        case .missing, .unreadable:
            do {
                try CatalogHighWater.write(highWater, besideDatabaseAt: url, durability: durability.publish)
                return nil
            } catch {
                return "\(CatalogHighWater.fileName) could not be written: \(words(error))"
            }
        }
    }

    /// F8r3 verbatim: the adopt row first (while the counter still reads
    /// `from`), then the jump, in one immediate transaction.
    private static func runAdoption(_ db: Database, from: Int, to: Int, host: String, now: Int) throws -> Bool {
        var jumped = false
        try db.inTransaction(.immediate) {
            try db.execute(sql: "INSERT INTO generation_history (generation, committed_at, host, writer, files_live, files_total, kind, from_generation) VALUES (?, ?, ?, 'adopt', 0, 0, 'adopt', ?)",
                           arguments: [to, now, host, from])
            try db.execute(sql: "UPDATE generations SET generation = ?, adopted_at = ?, adopted_from = ?, saved_at = ?, saved_from_host = ? WHERE id = 1 AND ? > generation",
                           arguments: [to, now, from, now, host, to])
            jumped = db.changesCount == 1
            return jumped ? .commit : .rollback
        }
        return jumped
    }

    // MARK: - Close

    public func close() async {
        guard let pool else { return }
        do {
            try pool.close()
        } catch {
            storeLog.error("catalog store CLOSE: \(Self.words(error), privacy: .public)")
        }
        self.pool = nil
        databaseURL = nil
        mode = .closed
    }

    // MARK: - Words

    private static func words(_ error: Error) -> String {
        if let refusal = error as? Refusal { return refusal.reason }
        if let engine = error as? DatabaseError { return engine.description }
        return String(describing: error)
    }
}

/// Unix seconds, the DDL's timestamp unit (whole seconds, like the JSON
/// catalog's `.iso8601` dates).
private func unixNow() -> Int {
    Int(Date().timeIntervalSince1970)
}

// MARK: - The handles a body sees (part 2 grows them)

struct GRDBReader: CatalogReader {
    let generation: Int
    let db: Database
}

struct GRDBTransaction: CatalogTransaction {
    let generation: Int
    let db: Database
}
