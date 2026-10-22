// GRDBCatalogRepository.swift (VideoScanCore/Store)
// The SQLite plugin behind CatalogRepository, through GRDB 7 (pinned in
// Package.swift). Step C′ part 1: the bookkeeping; part 2a adds the data
// tables (CatalogDataSchema, migration `v2_data`); part 2b adds the record
// doors (+Writes) and readings (+Reads) and fills `files_live` /
// `files_total` on every commit. The codex C′ pass of 2026-10-17 (docs/reviews/codex/
// codex-review-sqlite-store-parts-1-2a-step-c-2026-10-17.md) hardened the
// generation bookkeeping; each change is marked `codex C′ #N` below.
//
// What this file guarantees (contract §9.2, §9.5, §e.9, F8r3):
//   - every connection runs foreign_keys=ON, recursive_triggers=ON (so a
//     REPLACE's implicit delete reaches the delete triggers, codex C′ #1),
//     synchronous=FULL, fullfsync=1 (macOS: FULL alone stops at the drive's
//     cache), a busy timeout, WAL;
//   - at open: integrity_check + foreign_key_check → `.refused` with the
//     engine's words; a NEWER schema_version → `.refused`; exactly one
//     catalog_state row and one generations row; then the high-water
//     reconciliation INSIDE one immediate transaction (codex C′ #4) against
//     THREE witnesses — the sidecar `catalog.highwater`, the append-only
//     `catalog.highwater.log` (codex C′ #3) and generation_history — any of
//     them above the generation ⇒ `.readOnly` (`restoredBelowHighWater`)
//     until a person adopts; a sidecar below the generation is raised by
//     compare-and-raise, never lowered;
//   - a write is ONE immediate transaction: body, then the generation CAS
//     (`changes() == 1` or `.generationMismatch`), then phase 1 — the
//     sidecar must read EXACTLY this session's generation g (codex C′ #5),
//     it is raised to g+1 and the log gains a line — then the history row,
//     then COMMIT (phase 2). A crash between the phases leaves the
//     witnesses above the generation, which the next open reports as
//     read-only; a session that finds the mark moved from under it refuses
//     every later write until it is reopened;
//   - the session's CAS expectation lives in a box the serialized write
//     reads and updates (codex C′ #6): two writes queued on one repository
//     commit g+1 then g+2, while a stale SECOND repository still gets
//     `.generationMismatch`;
//   - adoption is the only jump larger than +1, and the DDL's triggers —
//     not this file — are what refuse any other jump;
//   - GH #359: the database file's device + inode (and the latch's, when it
//     was there at open) are recorded at open and compared before every
//     commit transaction, before phase 1 and just before COMMIT; a file
//     replaced, moved or removed refuses the write BEFORE it writes, in
//     words, and every later write of the session (CatalogFileGuard.swift).
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
// suspends until the pool is done. While it is suspended another call may
// enter the actor — which is why the write's expectation is NOT actor
// state but a locked box the serialized closure owns.

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

    private enum Mode: Equatable, Sendable {
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

    /// A test seam: a synchronous closure run at one named point. A throw
    /// is "the process died here".
    typealias Seam = @Sendable () throws -> Void

    public let host: String
    private let durability: Durability
    private var pool: DatabasePool? { didSet { publishGate() } }
    private var databaseURL: URL? { didSet { publishGate() } }
    private var mode: Mode = .closed { didSet { publishGate() } }
    /// GH #359: the identities recorded at open, checked before each commit.
    private var fileGuard: CatalogFileGuard? { didSet { publishGate() } }
    /// QA r2-2: what the last close said (quarantine START / OUTCOME).
    let closeNotes = CatalogCloseNotes()
    /// The generation this session last loaded or committed, and whether
    /// a reopen is owed — read and updated inside the serialized write.
    private let session = WriterSession()
    /// What `writeBlocking` reads OFF the actor (cutover B2.2): the four
    /// properties around it, mirrored under a lock every time one changes.
    private let gate = WriteGate()
    /// Test seam: runs after phase 1 (high-water raised) and before COMMIT.
    private var crashBeforeCommit: Seam? { didSet { publishGate() } }
    /// Test seam: runs at open between reading the witnesses and publishing.
    private var openHook: Seam?

    public init(host: String = GRDBCatalogRepository.defaultHost,
                durability: Durability = .archival) {
        self.host = host
        self.durability = durability
    }

    public var generation: Int { session.generation }

    // MARK: - Open

    public func open(at url: URL) async -> CatalogOpenOutcome {
        await open(at: url, requiringLatch: false)
    }

    /// `requiringLatch` (QA r1 D): the app's launch and Reopen — no
    /// catalog.cutover beside `url`, no open, nothing written (#354 words).
    /// Bare stores, the importer and tests open without it.
    public func open(at url: URL, requiringLatch: Bool) async -> CatalogOpenOutcome {
        guard pool == nil else {
            return .refused(reason: "already open at \(databaseURL?.path ?? "?")")
        }
        if requiringLatch, CatalogFileIdentity.read(url.deletingLastPathComponent().appendingPathComponent(CatalogFileGuard.latchFileName)) == .missing {
            return refusedToOpen(url, Self.noLatchWords(folder: url.deletingLastPathComponent()))
        }
        // GH #359: the file as it was BEFORE the pool opened it (missing for
        // a new catalog), so a swap during the open itself is caught.
        let before = CatalogFileIdentity.read(url)
        let opened: Opened
        do {
            opened = try Self.openPool(at: url, durability: durability)
        } catch {
            return refusedToOpen(url, "could not open: \(Self.words(error))")
        }
        return await finishOpen(opened, at: url, before: before, requiringLatch: requiringLatch)
    }

    public static let readerOnlyWords = "opened for reading only by a process that is not the catalog's writer"

    /// READ-ONLY open for a process that is not the catalog's writer (the
    /// preview helper, the Hallie shell — 2026-10-19, cutover audit gap 3):
    /// SQLITE_OPEN_READONLY, no migration (an unmigrated file is refused), no
    /// high-water reconcile or raise, every write refused. The engine checks
    /// still run. The outcome is always `.readOnly` or `.refused`.
    public func openForReading(at url: URL) async -> CatalogOpenOutcome {
        guard pool == nil else { return .refused(reason: "already open at \(databaseURL?.path ?? "?")") }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return refusedToOpen(url, "could not open: no file at \(url.path)")
        }
        let before = CatalogFileIdentity.read(url)
        let opened: Opened
        do {
            opened = Opened(pool: try Self.makePool(at: url, durability: durability, readonly: true),
                            readOnlyReason: Self.readerOnlyWords)
        } catch {
            return refusedToOpen(url, "could not open: \(Self.words(error))")
        }
        return await finishOpen(opened, at: url, before: before)
    }

    /// The open checks, the settle, and publishing the session (both doors).
    /// GH #359: the identities are recorded once the pool has the file, the
    /// settle's high-water raise checks them, and they are checked again
    /// before the session is published.
    private func finishOpen(_ opened: Opened, at url: URL, before: CatalogFileIdentity.Reading,
                            requiringLatch: Bool = false) async -> CatalogOpenOutcome {
        do {
            let fileGuard = try CatalogFileGuard.record(databaseAt: url, before: before)
            if requiringLatch, fileGuard.latch == nil { throw Refusal(reason: Self.noLatchWords(folder: url.deletingLastPathComponent())) }
            let loaded = try await Self.prepare(opened, host: host)
            let settled = try await settle(opened, loaded: loaded, at: url, fileGuard: fileGuard)
            if let words = fileGuard.violation() { throw Refusal(reason: words) }
            pool = opened.pool
            databaseURL = url
            self.fileGuard = fileGuard
            session.begin(generation: settled.generation)
            session.noteSidecars(CatalogSidecarQuarantine.identities(besideDatabaseAt: url))
            mode = settled.mode
            storeLog.notice("catalog store OPEN \(url.lastPathComponent, privacy: .public) generation \(settled.generation, privacy: .public) → \(String(describing: settled.mode.outcome), privacy: .public)")
            return settled.mode.outcome
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
            // codex C′ #1: a REPLACE conflict resolution deletes the row in
            // the way, and SQLite fires that row's BEFORE DELETE trigger
            // only when this is on. The DDL's no-delete triggers are the
            // second layer; this pragma is what lets them see the delete.
            try db.execute(sql: "PRAGMA recursive_triggers = ON")
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
        if let found, found > currentSchemaVersion {
            throw Refusal(reason: "schema version \(found) is newer than this build understands (\(currentSchemaVersion)) — open it with a newer VideoScan")
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
        // Part 2a: the data tables (DDL §2 onward), same rule — foreign
        // keys stay ON, every statement checked as it runs. Registered
        // AFTER v1_bookkeeping: GRDB runs migrations in registration order,
        // so a database a part-1 build created gets exactly this one added.
        migrator.registerMigration(CatalogDataSchema.migrationID, foreignKeyChecks: .immediate) { db in
            for statement in CatalogDataSchema.statements {
                try db.execute(sql: statement)
            }
        }
        // Cutover B2 (v1.7): additive — one table for the app's live writes,
        // and the version raised so an older build refuses the file.
        migrator.registerMigration(CatalogLiveWritesSchema.migrationID, foreignKeyChecks: .immediate) { db in
            for statement in CatalogLiveWritesSchema.statements + CatalogLiveWritesSchema.versionBump {
                try db.execute(sql: statement)
            }
        }
        // Cutover B2.1 (v1.8): additive — the holding place for new records
        // without a whole-file digest, and the version raised again.
        migrator.registerMigration(CatalogPendingRowsSchema.migrationID, foreignKeyChecks: .immediate) { db in
            for statement in CatalogPendingRowsSchema.statements + CatalogPendingRowsSchema.versionBump {
                try db.execute(sql: statement)
            }
        }
        // Cutover B2.2 (v1.9): additive — a purge of a held record is a
        // tombstone beside its kept payload, never a DELETE of it.
        migrator.registerMigration(CatalogCommitB22Schema.migrationID, foreignKeyChecks: .immediate) { db in
            for statement in CatalogCommitB22Schema.statements + CatalogCommitB22Schema.versionBump {
                try db.execute(sql: statement)
            }
        }
        // Catalog folders (v1.10): additive — `events.kind`, version 11.
        migrator.registerMigration(CatalogFolderKindSchema.migrationID, foreignKeyChecks: .immediate) { db in
            for statement in CatalogFolderKindSchema.statements + CatalogFolderKindSchema.versionBump {
                try db.execute(sql: statement)
            }
        }
        // Rick's decisions (v1.11): additive — `footage_likeness` and
        // `ignored_content_put_back`, version 12.
        migrator.registerMigration(CatalogDecisionTablesSchema.migrationID, foreignKeyChecks: .immediate) { db in
            for statement in CatalogDecisionTablesSchema.statements + CatalogDecisionTablesSchema.versionBump {
                try db.execute(sql: statement)
            }
        }
        return migrator
    }

    /// The `catalog_state.schema_version` a fully migrated database carries
    /// (v1 creates 7; `v3_live_writes` raises it to 8; `v4_pending_rows` to
    /// 9; `v5_b22_commit` to 10; `v6_folder_kind` to 11; `v7_decision_tables`
    /// to 12). A HIGHER number is a newer build's file and is refused at open.
    static let currentSchemaVersion = CatalogDecisionTablesSchema.schemaVersion

    private static func migrationsComplete(_ pool: DatabasePool, host: String) async throws -> Bool {
        let migrator = migrator(host: host)
        return try await pool.read { db in try migrator.hasCompletedMigrations(db) }
    }

    // MARK: - High-water at open (DDL §11)

    private struct Settled: Sendable {
        let generation: Int
        let mode: Mode
    }

    /// A read-only open (a sealed file, a read-only folder) keeps the
    /// generation it loaded; a read-write open reconciles the witnesses
    /// under the writer lock.
    private func settle(_ opened: Opened, loaded: Int, at url: URL, fileGuard: CatalogFileGuard) async throws -> Settled {
        if let reason = opened.readOnlyReason ?? Self.folderNotWritableReason(for: url) {
            return Settled(generation: loaded, mode: .readOnly(reason: reason))
        }
        let plan = OpenPlan(databaseURL: url, host: host, publish: durability.publish, hook: openHook, fileGuard: fileGuard)
        return try await opened.pool.writeWithoutTransaction { db in try plan.run(db) }
    }

    /// Reconciliation at open, INSIDE one immediate transaction (codex C′
    /// #4). The writer lock keeps every other writer's phase 1 out from
    /// between this read and this publish; the publish re-reads the
    /// sidecar first and never writes below what it finds. `hook` is the
    /// test seam that sits in that window.
    private struct OpenPlan: Sendable {
        let databaseURL: URL
        let host: String
        let publish: AtomicFilePublish.Durability
        let hook: Seam?
        let fileGuard: CatalogFileGuard

        func run(_ db: Database) throws -> Settled {
            var settled = Settled(generation: 0, mode: .closed)
            try db.inTransaction(.immediate) {
                settled = try reconcile(db)
                return .commit
            }
            return settled
        }

        private func reconcile(_ db: Database) throws -> Settled {
            let generation = try Int.fetchOne(db, sql: "SELECT generation FROM generations WHERE id = 1") ?? 0
            let witnesses = try HighWaterWitnesses.read(db, besideDatabaseAt: databaseURL)
            try hook?()
            return Settled(generation: generation, mode: mode(for: witnesses, generation: generation))
        }

        /// `highest > generation` ⇒ read-only with words naming the witness;
        /// a poisoned witness ⇒ read-only until a person decides; the sidecar
        /// missing or below ⇒ raised (never the reverse); equal ⇒ read-write.
        private func mode(for witnesses: HighWaterWitnesses, generation: Int) -> Mode {
            if let words = witnesses.unreadable {
                return .readOnly(reason: GRDBCatalogRepository.poisonedWitnessWords(words))
            }
            if witnesses.highest > generation {
                return .readOnly(reason: GRDBCatalogRepository.restoredBelowHighWaterWords(generation: generation, witnesses: witnesses))
            }
            if witnesses.sidecar == .value(generation) { return .readWrite }
            return raise(to: generation)
        }

        /// Compare-and-raise: re-read the sidecar immediately before writing
        /// it, and never write below what it now holds. The log gains the
        /// same line so both witnesses agree.
        private func raise(to generation: Int) -> Mode {
            let current = CatalogHighWater.read(besideDatabaseAt: databaseURL)
            if case .value(let value) = current, value >= generation {
                guard value > generation else { return .readWrite }
                return .readOnly(reason: GRDBCatalogRepository.restoredBelowHighWaterWords(
                    generation: generation, highest: value, witness: "\(CatalogHighWater.fileName) now reads \(value), published while this catalog was opening"))
            }
            if case .unreadable(let words) = current {
                return .readOnly(reason: GRDBCatalogRepository.poisonedWitnessWords(words))
            }
            // GH #359: never raise the witnesses beside a file that is not
            // the one this open checked (the open is then refused).
            if let words = fileGuard.violation() { return .readOnly(reason: words) }
            storeLog.notice("catalog store: \(CatalogHighWater.fileName, privacy: .public) \(current == .missing ? "missing" : "below the generation", privacy: .public) — raised to generation \(generation, privacy: .public)")
            do {
                try CatalogHighWater.write(generation, besideDatabaseAt: databaseURL, durability: publish)
                try CatalogHighWaterLedger.append(generation, host: host, besideDatabaseAt: databaseURL, durability: publish)
                return .readWrite
            } catch {
                return .readOnly(reason: "the high-water could not be written (\(GRDBCatalogRepository.words(error))) — the catalog opened for reading only")
            }
        }
    }

    private static func poisonedWitnessWords(_ words: String) -> String {
        "\(words) — writing is disabled until a person adopts a high-water explicitly, or removes the file so it is recreated from the database"
    }

    private static func restoredBelowHighWaterWords(generation: Int, witnesses: HighWaterWitnesses) -> String {
        restoredBelowHighWaterWords(generation: generation, highest: witnesses.highest, witness: witnesses.testimony)
    }

    private static func restoredBelowHighWaterWords(generation: Int, highest: Int, witness: String) -> String {
        "restoredBelowHighWater: this catalog is at generation \(generation) but this Mac already wrote generation \(highest) — \(witness). It is an older copy (a restore, or a crash between a high-water write and its commit). Open the newer copy, or adopt this one explicitly to write to it again."
    }

    /// Internal test seam. See `openHook`.
    func injectOpenHook(_ seam: Seam?) {
        openHook = seam
    }

    // MARK: - Write (one transaction, CAS, two-phase high-water)

    public func write(as door: CatalogWriter,
                      _ body: @Sendable (any CatalogTransaction) throws -> Void) async -> CatalogWriteOutcome {
        guard let pool, let databaseURL, let fileGuard else { return .refused(reason: "not open") }
        if let words = session.fileStopped { return .refused(reason: words) }   // #359: the stop speaks first
        if case .readOnly(let reason) = mode { return .refused(reason: "read-only: \(reason)") }
        let plan = WritePlan(session: session, door: door, host: host, databaseURL: databaseURL,
                             publish: durability.publish, crashBeforeCommit: crashBeforeCommit, fileGuard: fileGuard)
        let outcome: CatalogWriteOutcome
        do {
            outcome = try await pool.writeWithoutTransaction { db in try plan.run(db, body) }
        } catch {
            outcome = .refused(reason: session.fileStop(fileGuard) ?? "write rolled back: \(Self.words(error))")
        }
        Self.noteCommit(outcome, door: door)
        return outcome
    }

    /// The same transaction as `write`, on the calling thread (cutover
    /// B2.2 — the app's CatalogCommitter, from the main actor, only). It
    /// reads the open state from the gate, not the actor, so it never
    /// hops; GRDB's writer queue serializes it with every async `write`
    /// (the session box keeps the CAS expectation right either way). A
    /// pool closed under it throws, and that is a `.refused`.
    public nonisolated func writeBlocking(as door: CatalogWriter,
                                          _ body: (any CatalogTransaction) throws -> Void) -> CatalogWriteOutcome {
        let open = gate.state
        guard let pool = open.pool, let databaseURL = open.databaseURL, let fileGuard = open.fileGuard else { return .refused(reason: "not open") }
        if let words = session.fileStopped { return .refused(reason: words) }   // #359: the stop speaks first
        if let reason = open.readOnlyReason { return .refused(reason: "read-only: \(reason)") }
        let plan = WritePlan(session: session, door: door, host: host, databaseURL: databaseURL,
                             publish: durability.publish, crashBeforeCommit: open.crashBeforeCommit, fileGuard: fileGuard)
        let outcome: CatalogWriteOutcome
        do {
            outcome = try pool.writeWithoutTransaction { db in try plan.run(db, body) }
        } catch {
            outcome = .refused(reason: session.fileStop(fileGuard) ?? "write rolled back: \(Self.words(error))")
        }
        Self.noteCommit(outcome, door: door)
        return outcome
    }

    /// A sealed copy of the open catalog.sqlite at `target` (`VACUUM INTO`:
    /// one self-contained file, no WAL), on the calling thread — the
    /// pre-change safety copy a door takes before it removes records once
    /// catalog.sqlite is the authority (cutover B2.3, regression F3; the
    /// JSON catalog's `catalog.<prefix>.<stamp>.json` twin). Runs on the
    /// writer queue (VACUUM cannot run inside a read transaction), so it
    /// sees every committed generation and no commit lands half-way through
    /// it. Refuses an existing target. nil = written; else the words.
    /// QA r1 F2 (#359): after a file-stop the copy would be of the MOVED-ASIDE
    /// file, labelled as the catalog — refused in the stop's words, checked
    /// first and again on the writer queue just before VACUUM INTO.
    public nonisolated func sealedCopyBlocking(to target: URL) -> String? {
        guard let pool = gate.state.pool else { return "catalog.sqlite is not open" }
        if let words = fileStopWords { return words }
        guard !FileManager.default.fileExists(atPath: target.path) else { return "\(target.lastPathComponent) already exists" }
        do {
            return try pool.writeWithoutTransaction { db -> String? in
                if let words = fileStopWords { return words }
                try db.execute(sql: "VACUUM INTO ?", arguments: [target.path])
                return nil
            }
        } catch {
            return fileStopWords ?? "VACUUM INTO \(target.lastPathComponent) failed: \(Self.words(error))"
        }
    }

    private static func noteCommit(_ outcome: CatalogWriteOutcome, door: CatalogWriter) {
        if case .committed(let generation) = outcome {
            storeLog.debug("catalog store commit generation \(generation, privacy: .public) via \(door.rawValue, privacy: .public)")
        }
    }

    private func publishGate() {
        var readOnlyReason: String?
        if case .readOnly(let reason) = mode { readOnlyReason = reason }
        gate.set(WriteGate.State(pool: mode == .closed ? nil : pool, databaseURL: databaseURL,
                                 readOnlyReason: readOnlyReason, crashBeforeCommit: crashBeforeCommit,
                                 fileGuard: fileGuard))
    }

    /// Everything one write needs, captured by value so the closure the
    /// pool runs touches no actor state. For Rick: a plain struct of
    /// `let`s handed to another thread — the Swift way to say "no shared
    /// mutable state crosses here" (`Sendable`). The one shared thing, the
    /// session box, has its own lock.
    private struct WritePlan: Sendable {
        let session: WriterSession
        let door: CatalogWriter
        let host: String
        let databaseURL: URL
        let publish: AtomicFilePublish.Durability
        let crashBeforeCommit: Seam?
        let fileGuard: CatalogFileGuard

        func run(_ db: Database,
                 _ body: (any CatalogTransaction) throws -> Void) throws -> CatalogWriteOutcome {
            // GH #359, check 1 of 3: before BEGIN — a refused write takes no
            // lock and writes no frame. On the writer queue, so no other
            // write of this repository runs between this check and BEGIN.
            if let words = session.fileStop(fileGuard) { return .refused(reason: words) }
            if let reason = session.needsReopen {
                return .refused(reason: "reopen the catalog: \(reason)")
            }
            // codex C′ #6: read HERE, on the writer, after every earlier
            // write on this repository has committed and updated the box.
            let expected = session.generation
            var outcome: CatalogWriteOutcome = .refused(reason: "the transaction did not run")
            try db.inTransaction(.immediate) {
                outcome = try steps(db, expected: expected, body)
                if case .committed = outcome { return .commit }
                return .rollback
            }
            if case .committed(let generation) = outcome { session.commit(generation); session.noteSidecarsOnce(fileGuard) }
            return outcome
        }

        private func steps(_ db: Database, expected: Int,
                           _ body: (any CatalogTransaction) throws -> Void) throws -> CatalogWriteOutcome {
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
            // GH #359, check 2 of 3: before phase 1 — no witness is raised
            // beside a file that is not the one this session opened.
            if let words = session.fileStop(fileGuard) { return .refused(reason: words) }
            // Phase 1 (F8r3): the external mark says `next` BEFORE the commit.
            if let problem = publishMark(expected: expected, next: next) {
                return .refused(reason: problem)
            }
            // Part 2b: the history row carries what `files` holds at this commit.
            let filesLive = try Int.fetchOne(db, sql: "SELECT count(*) FROM files WHERE removal_state IS NULL") ?? 0
            let filesTotal = try Int.fetchOne(db, sql: "SELECT count(*) FROM files") ?? 0
            try db.execute(sql: "INSERT INTO generation_history (generation, committed_at, host, writer, files_live, files_total, kind, from_generation) VALUES (?, ?, ?, ?, ?, ?, 'commit', NULL)",
                           arguments: [next, now, host, door.rawValue, filesLive, filesTotal])
            try crashBeforeCommit?()
            // GH #359, check 3 of 3: just before COMMIT (phase 1's fsync is a
            // real window). A refusal here rolls back; the witnesses already
            // read `next`, so the next open is read-only — the crash-between-
            // phases case, which refuses rather than guesses.
            if let words = session.fileStop(fileGuard) { return .refused(reason: words) }
            return .committed(generation: next)                   // phase 2 is the COMMIT that follows
        }

        /// Phase 1 (F8r3, codex C′ #5). The witnesses must read EXACTLY this
        /// session's generation; anything else is a mark this session did
        /// not write — another writer's, or this session's own from a write
        /// that died after publishing — and only a reopen (which runs the
        /// restore check) may resolve it. Nothing has committed either way.
        private func publishMark(expected: Int, next: Int) -> String? {
            if let stale = staleMarkWords(expected: expected) {
                session.flagReopen(stale)
                return "\(stale) — reopen the catalog"
            }
            do {
                try CatalogHighWater.write(next, besideDatabaseAt: databaseURL, durability: publish)
            } catch {
                return "\(CatalogHighWater.fileName) could not be written: \(GRDBCatalogRepository.words(error))"
            }
            do {
                try CatalogHighWaterLedger.append(next, host: host, besideDatabaseAt: databaseURL, durability: publish)
                return nil
            } catch {
                // The sidecar already reads `next`: this session's mark is out of step with its generation.
                let reason = "\(CatalogHighWaterLedger.fileName) could not be appended (\(GRDBCatalogRepository.words(error))) after \(CatalogHighWater.fileName) was raised to \(next)"
                session.flagReopen(reason)
                return "\(reason) — reopen the catalog"
            }
        }

        private func staleMarkWords(expected: Int) -> String? {
            switch CatalogHighWater.read(besideDatabaseAt: databaseURL) {
            case .value(let current) where current > expected:
                return "another writer published generation \(current)"
            case .value(let current) where current < expected:
                return "\(CatalogHighWater.fileName) reads \(current), below this session's generation \(expected)"
            case .missing:
                return "\(CatalogHighWater.fileName) is missing"
            case .unreadable(let words):
                return words
            case .value:
                break
            }
            switch CatalogHighWaterLedger.read(besideDatabaseAt: databaseURL) {
            case .value(let last) where last > expected:
                return "\(CatalogHighWaterLedger.fileName) last recorded generation \(last), above this session's \(expected)"
            case .unreadable(let words):
                return words
            case .value, .missing:
                return nil
            }
        }
    }

    /// Internal test seam. See `crashBeforeCommit`.
    func injectCrashBeforeCommit(_ seam: Seam?) {
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

    // MARK: - Verify

    public func verify() async -> CatalogVerifyOutcome {
        guard let pool, let databaseURL else { return .problems(["not open"]) }
        var problems: [String] = []
        var generation = session.generation
        var highWater = generation
        do {
            try await Self.checkEngine(pool)
            let (bookkeeping, witnesses) = try await pool.read { db in
                (try Self.bookkeepingProblems(db), try HighWaterWitnesses.read(db, besideDatabaseAt: databaseURL))
            }
            generation = bookkeeping.generation
            problems += bookkeeping.problems
            problems += Self.witnessProblems(witnesses, generation: generation)
            highWater = max(witnesses.highest, generation)
        } catch {
            problems.append(Self.words(error))
        }
        return problems.isEmpty ? .ok(generation: generation, highWater: highWater) : .problems(problems)
    }

    private static func bookkeepingProblems(_ db: Database) throws -> (generation: Int, problems: [String]) {
        var problems: [String] = []
        let states = try Int.fetchOne(db, sql: "SELECT count(*) FROM catalog_state") ?? 0
        if states != 1 { problems.append("catalog_state has \(states) rows, not 1") }
        let version = try Int.fetchOne(db, sql: "SELECT schema_version FROM catalog_state WHERE singleton = 1") ?? -1
        if version != currentSchemaVersion { problems.append("schema_version is \(version), expected \(currentSchemaVersion)") }
        let counters = try Int.fetchOne(db, sql: "SELECT count(*) FROM generations") ?? 0
        if counters != 1 { problems.append("generations has \(counters) rows, not 1") }
        let generation = try Int.fetchOne(db, sql: "SELECT generation FROM generations WHERE id = 1") ?? -1
        let newest = try Int.fetchOne(db, sql: "SELECT max(generation) FROM generation_history") ?? -1
        if newest != generation { problems.append("generation_history ends at \(newest), the counter reads \(generation)") }
        return (generation, problems)
    }

    /// The same three witnesses open consults, as findings for a person.
    private static func witnessProblems(_ witnesses: HighWaterWitnesses, generation: Int) -> [String] {
        var problems: [String] = []
        switch witnesses.sidecar {
        case .value(let value) where value < generation:
            problems.append("\(CatalogHighWater.fileName) reads \(value), below generation \(generation)")
        case .missing:
            problems.append("\(CatalogHighWater.fileName) is missing")
        case .unreadable(let words):
            problems.append(words)
        case .value:
            break
        }
        switch witnesses.log {
        case .missing:
            problems.append("\(CatalogHighWaterLedger.fileName) is missing")
        case .unreadable(let words):
            problems.append(words)
        case .value:
            break
        }
        if witnesses.highest > generation {
            problems.append(restoredBelowHighWaterWords(generation: generation, witnesses: witnesses))
        }
        return problems
    }

    // MARK: - Adopt

    public func adopt(toHighWater highWater: Int) async -> CatalogAdoptOutcome {
        guard let pool, let databaseURL, let fileGuard else { return .refused(reason: "not open") }
        // GH #359: an adopt writes the witnesses and the database — never
        // beside, or into, a file that is not the one this session opened.
        if let words = session.fileStop(fileGuard) { return .refused(reason: words) }
        let from = session.generation
        guard highWater > from else {
            return .refused(reason: "nothing to adopt: generation \(from) is not below \(highWater)")
        }
        let witnesses: HighWaterWitnesses
        do {
            witnesses = try await pool.read { db in try HighWaterWitnesses.read(db, besideDatabaseAt: databaseURL) }
        } catch {
            return .refused(reason: Self.words(error))
        }
        if let problem = Self.confirmAdoptable(highWater, witnesses: witnesses)
            ?? session.fileStop(fileGuard)
            ?? Self.raiseWitnesses(to: highWater, witnesses: witnesses, at: databaseURL, host: host, durability: durability.publish) {
            return .refused(reason: problem)
        }
        let host = host
        let now = unixNow()
        let session = session
        do {
            // QA r1 F1 (#359): BEGIN IMMEDIATE may wait for another writer;
            // the file is checked again after it and just before COMMIT.
            let jumped = try await pool.writeWithoutTransaction { db in
                try Self.runAdoption(db, from: from, to: highWater, host: host, now: now) { session.fileStop(fileGuard) }
            }
            switch jumped {
            case .jumped: break
            case .notJumped: return .refused(reason: "the database no longer reads generation \(from)")
            case .stopped(let words): return .refused(reason: words)
            }
        } catch {
            return .refused(reason: session.fileStop(fileGuard) ?? "adoption rolled back: \(Self.words(error))")
        }
        session.reset(generation: highWater)
        mode = .readWrite
        storeLog.notice("catalog store ADOPT generation \(from, privacy: .public) → \(highWater, privacy: .public) (\(CatalogHighWater.fileName, privacy: .public), \(CatalogHighWaterLedger.fileName, privacy: .public)) — writes enabled")
        return .adopted(from: from, to: highWater)
    }


    // MARK: - Close

    public func close() async {
        guard let pool else { return }
        // GH #359 — decided by the DATABASE AT THE PATH, not by the stop
        // (QA r2-1). Still the session's inode (a latch-only stop, a file
        // moved away and back): the normal checkpoint, and if it fails the
        // -wal stays at the path, where the right file replays it. Missing or
        // another file (QA r1 F3): no checkpoint (Apple SQLite refuses or
        // skips it), and once the pool is closed this session's own -wal /
        // -shm are renamed into quarantine (CatalogSidecarQuarantine — never
        // deleted), so the replacement never replays them. The lines are kept
        // for the app's sink (`lastCloseNotes`, QA r2-2).
        let stop = fileGuard.flatMap { session.fileStop($0) }
        let databaseMoved = fileGuard.map { CatalogFileIdentity.read($0.databaseURL) != .file($0.database) } ?? false
        if let stop {
            storeLog.error("catalog store CLOSE after the file check failed (\(databaseMoved ? "catalog.sqlite is not this session's file — no checkpoint" : "catalog.sqlite is still this session's file — checkpointed as usual", privacy: .public)): \(stop, privacy: .public)")
        }
        // Fold the write-ahead log into the database file BEFORE the pool
        // closes (2026-10-17): GRDB closes the writer before its readers, so
        // SQLite's own close-time checkpoint never runs, and every commit
        // stays in catalog.sqlite-wal. A backup or off-site copy of
        // catalog.sqlite alone would then hold no tables at all (pinned by
        // CatalogCloseCheckpointTests). TRUNCATE leaves a zero-length -wal.
        // A read-only session has nothing of its own to fold in.
        if mode == .readWrite && !databaseMoved {
            do {
                try await pool.writeWithoutTransaction { try $0.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
            } catch {
                storeLog.error("catalog store CLOSE checkpoint: \(Self.words(error), privacy: .public)")
            }
        }
        var poolClosed = true
        do {
            try pool.close()
        } catch {
            poolClosed = false
            storeLog.error("catalog store CLOSE: \(Self.words(error), privacy: .public)")
        }
        var notes: [String] = []
        if mode == .readWrite, databaseMoved, let databaseURL {
            notes = poolClosed
                ? CatalogSidecarQuarantine.quarantine(besideDatabaseAt: databaseURL, own: session.sidecars, why: stop ?? "catalog.sqlite moved")
                : CatalogSidecarQuarantine.skipped(besideDatabaseAt: databaseURL, because: "the catalog's connections did not close")
        }
        closeNotes.set(notes)
        self.pool = nil
        databaseURL = nil
        fileGuard = nil
        mode = .closed
    }

    // MARK: - Words

    private static func words(_ error: Error) -> String {
        if let refusal = error as? Refusal { return refusal.reason }
        if let failure = error as? CatalogFileGuard.GuardFailure { return failure.words }
        if let engine = error as? DatabaseError { return engine.description }
        return String(describing: error)
    }
}

// MARK: - Adopt helpers
//
// Moved out of the actor body unchanged except runAdoption's file check
// (GH #359 QA r1 F1) — same file, so the actor still calls them privately.

extension GRDBCatalogRepository {

    /// The person's number must be what the witnesses hold: never below the
    /// highest readable one, and exactly it while every witness is readable.
    /// With a witness missing or poisoned, the person's number becomes the
    /// mark — it can only be ABOVE every readable witness, which restricts
    /// older copies further and loses nothing.
    private static func confirmAdoptable(_ highWater: Int, witnesses: HighWaterWitnesses) -> String? {
        let required = witnesses.highest
        guard highWater < required || (highWater > required && witnesses.unreadable == nil && witnesses.sidecarValue != nil) else { return nil }
        return "\(witnesses.loudest) reads \(required), not \(highWater) — adopt the value it holds"
    }

    /// Both files say `highWater` BEFORE the database jumps (F8r3's order:
    /// the witnesses first; a failure after this leaves them above the
    /// generation, which the next open reports as read-only again).
    private static func raiseWitnesses(to highWater: Int, witnesses: HighWaterWitnesses, at url: URL,
                                       host: String, durability: AtomicFilePublish.Durability) -> String? {
        do {
            if witnesses.sidecarValue != highWater {
                try CatalogHighWater.write(highWater, besideDatabaseAt: url, durability: durability)
            }
            if witnesses.logValue != highWater {
                try CatalogHighWaterLedger.append(highWater, host: host, besideDatabaseAt: url, durability: durability)
            }
            return nil
        } catch {
            return "the high-water could not be written: \(words(error))"
        }
    }

    /// F8r3 verbatim: the adopt row first (while the counter still reads
    /// `from`), then the jump, in one immediate transaction.
    private enum Adoption { case jumped, notJumped, stopped(String) }

    /// `stop` (GH #359, QA r1 F1): the file check, run after BEGIN and again
    /// just before COMMIT; non-nil rolls the adoption back.
    private static func runAdoption(_ db: Database, from: Int, to: Int, host: String, now: Int,
                                    stop: () -> String?) throws -> Adoption {
        var result = Adoption.notJumped
        try db.inTransaction(.immediate) {
            if let words = stop() { result = .stopped(words); return .rollback }
            try db.execute(sql: "INSERT INTO generation_history (generation, committed_at, host, writer, files_live, files_total, kind, from_generation) VALUES (?, ?, ?, 'adopt', 0, 0, 'adopt', ?)",
                           arguments: [to, now, host, from])
            try db.execute(sql: "UPDATE generations SET generation = ?, adopted_at = ?, adopted_from = ?, saved_at = ?, saved_from_host = ? WHERE id = 1 AND ? > generation",
                           arguments: [to, now, from, now, host, to])
            guard db.changesCount == 1 else { return .rollback }
            if let words = stop() { result = .stopped(words); return .rollback }
            result = .jumped
            return .commit
        }
        return result
    }
}

// MARK: - The file stop, off the actor (GH #359)

extension GRDBCatalogRepository {
    /// Sticky until the next open; checked afresh while a guard is set
    /// (one or two `stat` calls, on the calling thread).
    public nonisolated var fileStopWords: String? {
        if let fileGuard = gate.state.fileGuard { return session.fileStop(fileGuard) }
        return session.fileStopped
    }
}

// MARK: - Pragmas (tests)
//
// Moved out of the actor body unchanged (GH #359 kept the body under
// SwiftLint's 600 lines); same file, so it still reads the private pool.

extension GRDBCatalogRepository {

    /// The pragmas as the engine reports them on a reader connection
    /// (internal: the pragma test queries them back).
    func pragmas() async throws -> [String: String] {
        guard let pool else { throw CatalogRepositoryError.notOpen }
        return try await pool.read { db in
            var reported: [String: String] = [:]
            for name in ["journal_mode", "synchronous", "fullfsync", "foreign_keys", "recursive_triggers", "busy_timeout", "user_version"] {
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
}

// MARK: - Read-only opens (viewer Macs, 2026-10-19)
//
// Two doors that never write, beside `open` (which may migrate and raise the
// high-water): `openReadOnly` for this Mac's own catalog.sqlite when the
// session is read-only (a viewer — codex cycle #112), and
// `openSealedSnapshot` for the master's sealed copy a viewer receives
// (CatalogSync phase 2). In an extension in this file so they share the
// actor's private state without widening it.

extension GRDBCatalogRepository {

    /// The words every sealed-snapshot session carries as its read-only reason.
    public static let sealedSnapshotWords = "a sealed snapshot of the master's catalog — read-only on this Mac"

    /// Open `url` for READING ONLY, with `reason` as the session's read-only
    /// words. SQLITE_OPEN_READONLY; no migration (an incomplete schema is
    /// refused); the high-water witnesses are neither read nor raised; every
    /// write is refused for the session. The same engine and schema checks
    /// as `open` (integrity_check, foreign_key_check, schema version).
    public func openReadOnly(at url: URL, reason: String) async -> CatalogOpenOutcome {
        guard pool == nil else {
            return .refused(reason: "already open at \(databaseURL?.path ?? "?")")
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return refusedToOpen(url, "\(url.lastPathComponent) does not exist")
        }
        let before = CatalogFileIdentity.read(url)
        let opened: Opened
        do {
            opened = Opened(pool: try Self.makePool(at: url, durability: durability, readonly: true), readOnlyReason: reason)
        } catch {
            return refusedToOpen(url, "could not open: \(Self.words(error))")
        }
        do {
            let fileGuard = try CatalogFileGuard.record(databaseAt: url, before: before)
            let loaded = try await Self.prepare(opened, host: host)
            pool = opened.pool
            databaseURL = url
            self.fileGuard = fileGuard
            session.begin(generation: loaded)
            mode = .readOnly(reason: reason)
            storeLog.notice("catalog store OPEN READ-ONLY \(url.lastPathComponent, privacy: .public) generation \(loaded, privacy: .public) — \(reason, privacy: .public)")
            return .readOnly(reason: reason)
        } catch {
            try? opened.pool.close()
            return refusedToOpen(url, Self.words(error))
        }
    }

    /// Open a sealed snapshot (a finished `VACUUM INTO` copy) read-only —
    /// the viewer Macs' door (CatalogSync phase 2). Refused before any
    /// connection is made unless the file is a rollback-journal SQLite file
    /// with nothing beside it (`VACUUM INTO` output always is): a read-only
    /// open of a WAL file can still create `-shm` beside it. (For Rick: a
    /// rollback-journal read takes only fcntl shared locks — no file is
    /// created, so the synced folder stays byte-identical.)
    public func openSealedSnapshot(at url: URL) async -> CatalogOpenOutcome {
        if let why = Self.sealedSnapshotRefusal(url) { return refusedToOpen(url, why) }
        return await openReadOnly(at: url, reason: Self.sealedSnapshotWords)
    }

    /// Why `url` is not a sealed snapshot this Mac may open read-only, or
    /// nil when it is. Reads the first 100 bytes only (the SQLite header):
    /// the magic string, then the read / write format versions at offsets
    /// 18 and 19 — 1 = rollback journal, 2 = WAL.
    public static func sealedSnapshotRefusal(_ url: URL) -> String? {
        let fm = FileManager.default
        for suffix in ["-wal", "-journal", "-shm"] where fm.fileExists(atPath: url.path + suffix) {
            return "\(url.lastPathComponent)\(suffix) is beside it — not a sealed snapshot"
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return "\(url.lastPathComponent) could not be read"
        }
        defer { try? handle.close() }
        let header = (try? handle.read(upToCount: 100)) ?? Data()
        guard header.count == 100, header.prefix(16) == Data("SQLite format 3\u{0}".utf8) else {
            return "\(url.lastPathComponent) is not an SQLite database"
        }
        guard header[18] == 1, header[19] == 1 else {
            return "\(url.lastPathComponent) is in write-ahead-log mode (format \(header[18])/\(header[19])) — not a sealed snapshot"
        }
        return nil
    }
}

// MARK: - The write gate (cutover B2.2)

/// The open state `writeBlocking` needs, mirrored off the actor: the pool,
/// the database URL, the read-only words and the crash seam. Set by the
/// actor whenever one of them changes; read once per blocking write. For
/// Rick: a mutex-guarded copy of five member variables (GH #359 added the
/// file guard).
final class WriteGate: @unchecked Sendable {
    struct State {
        var pool: DatabasePool?
        var databaseURL: URL?
        var readOnlyReason: String?
        var crashBeforeCommit: GRDBCatalogRepository.Seam?
        var fileGuard: CatalogFileGuard?
    }

    private let lock = NSLock()
    private var current = State()

    var state: State { lock.withLock { current } }

    func set(_ state: State) {
        lock.withLock { current = state }
    }
}

// MARK: - The session box (codex C′ #6)

/// What a session knows between writes: the generation it last loaded or
/// committed (the CAS expectation) and whether a reopen is owed. A class
/// with a lock rather than actor state because the pool's writer closure
/// reads and updates it OFF the actor, in the serialized section: codex
/// C′ #6 showed two `write` calls both capturing the actor's number before
/// either had committed. For Rick: a mutex around an int and a string.
final class WriterSession: @unchecked Sendable {
    private let lock = NSLock()
    private var committed = 0
    private var reopenReason: String?
    private var fileStopWords: String?
    private var sidecarIdentities: [String: CatalogFileIdentity] = [:]

    var generation: Int { lock.withLock { committed } }
    var needsReopen: String? { lock.withLock { reopenReason } }
    /// GH #359: the file check failed once — every later write of this
    /// session is refused with these words, even if the file comes back.
    var fileStopped: String? { lock.withLock { fileStopWords } }
    /// QA r1 F3: this session's own -wal / -shm, by suffix, as first seen.
    var sidecars: [String: CatalogFileIdentity] { lock.withLock { sidecarIdentities } }

    /// A NEW session (every open): nothing carried over.
    func begin(generation: Int) {
        lock.withLock {
            committed = generation
            reopenReason = nil
            fileStopWords = nil
            sidecarIdentities = [:]
        }
    }

    /// The same session at a new generation (adopt). A sticky file-stop is
    /// NOT cleared (QA r1 F1): only a new open starts clean.
    func reset(generation: Int) {
        lock.withLock {
            committed = generation
            reopenReason = nil
        }
    }

    /// Record the -wal / -shm the first time each is seen (never replaced:
    /// a later file at that path is not this session's).
    func noteSidecars(_ found: [String: CatalogFileIdentity]) {
        lock.withLock { sidecarIdentities.merge(found) { first, _ in first } }
    }

    /// Both sidecars already recorded (the per-commit note is then free).
    var sidecarsComplete: Bool { lock.withLock { sidecarIdentities.count == CatalogSidecarQuarantine.suffixes.count } }

    func stopForFile(_ words: String) {
        lock.withLock { if fileStopWords == nil { fileStopWords = words } }
    }

    func commit(_ generation: Int) {
        lock.withLock { committed = generation }
    }

    func flagReopen(_ reason: String) {
        lock.withLock { reopenReason = reason }
    }
}

// MARK: - The three witnesses (codex C′ #3)

/// The three places a generation this Mac intended to write can be found:
/// the sidecar (one integer, replaced per write), the append-only log (one
/// line per publication), and the database's own history (restored with
/// it, so it only catches a counter rewound inside the file). The highest
/// is the effective high-water (DDL §11). Open, verify and adopt all read
/// the same struct, so the three cannot disagree about what "restored" means.
struct HighWaterWitnesses: Sendable, Equatable {
    let sidecar: CatalogHighWater.Reading
    let log: CatalogHighWaterLedger.Reading
    let historyNewest: Int

    static func read(_ db: Database, besideDatabaseAt url: URL) throws -> HighWaterWitnesses {
        HighWaterWitnesses(sidecar: CatalogHighWater.read(besideDatabaseAt: url),
                           log: CatalogHighWaterLedger.read(besideDatabaseAt: url),
                           historyNewest: try Int.fetchOne(db, sql: "SELECT max(generation) FROM generation_history") ?? 0)
    }

    var sidecarValue: Int? {
        if case .value(let value) = sidecar { return value }
        return nil
    }

    var logValue: Int? {
        if case .value(let value) = log { return value }
        return nil
    }

    var highest: Int { max(sidecarValue ?? 0, logValue ?? 0, historyNewest) }

    /// The first poisoned witness's words (the sidecar's first: it is the
    /// one a person repairs by hand), or nil when both files are sound.
    var unreadable: String? {
        if case .unreadable(let words) = sidecar { return words }
        if case .unreadable(let words) = log { return words }
        return nil
    }

    private var readings: [(name: String, value: Int?)] {
        [(CatalogHighWater.fileName, sidecarValue), (CatalogHighWaterLedger.fileName, logValue), ("generation_history", historyNewest)]
    }

    /// The witness(es) that hold the highest value, by name.
    var loudest: String {
        readings.filter { $0.value == highest }.map(\.name).joined(separator: " and ")
    }

    /// "catalog.highwater.log recorded it (catalog.highwater 5, catalog.highwater.log 10, generation_history 5)"
    var testimony: String {
        let all = readings.map { "\($0.name) \($0.value.map(String.init) ?? "unreadable or missing")" }.joined(separator: ", ")
        return "\(loudest) recorded it (\(all))"
    }
}

/// Unix seconds, the DDL's timestamp unit (whole seconds, like the JSON
/// catalog's `.iso8601` dates).
private func unixNow() -> Int {
    Int(Date().timeIntervalSince1970)
}

// MARK: - The handles a body sees. Part 2b: the record doors live in
// GRDBCatalogRepository+Writes.swift (transaction) and the readings in
// GRDBCatalogRepository+Reads.swift (both handles, via GRDBRecordHandle).

struct GRDBReader: CatalogReader {
    let generation: Int
    let db: Database
}

struct GRDBTransaction: CatalogTransaction {
    let generation: Int
    let db: Database
}
