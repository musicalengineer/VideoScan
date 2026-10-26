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
//     cache), a busy timeout, WAL — and the writer is set to FULL AGAIN
//     after the pool exists, because GRDB's WAL setup lowers it (codex #141 F1);
//   - at open: integrity_check + foreign_key_check → `.refused` with the
//     engine's words; a NEWER schema_version → `.refused` — all three inside
//     the WRITER's first BEGIN IMMEDIATE (5 s busy timeout), before GRDB
//     switches the file to WAL or writes its init table, and confirmed under
//     the lock of every later open transaction that writes (#387,
//     `OpenVerdict`); a refusal deletes no file and leaves the main file's
//     bytes as found; a hot rollback journal is refused from its bytes,
//     before any connection (codex #142 F6-2); exactly one
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
import CSQLiteCloseGuard
import GRDB
import os
import SQLite3

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
    /// Test seam (codex #142 F6-1, #387): runs at open after the writer's
    /// checks passed and the pool exists, before the open's first write —
    /// the window in which another connection can change the checked file.
    private var admittedHook: Seam?

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
        // A rollback journal another program left mid-write would be played
        // back by the first read-write lock — a write — before any check can
        // refuse the file (codex #142 F6-2). Refused here, from its bytes.
        if let why = Self.hotJournal(beside: url) { return refusedToOpen(url, Self.unverifiedWords(url, why)) }
        // #387 (Rick 2026-10-26): the checks run inside the WRITER's first
        // BEGIN IMMEDIATE, before GRDB switches the file to WAL or writes its
        // init table (makePool / OpenVerdict); a refusal deletes nothing.
        let opened: Opened
        do {
            opened = try Self.openPool(at: url, durability: durability)
        } catch {
            let why = Self.words(error)
            return refusedToOpen(url, error is Refusal ? why : "could not open: \(why)")
        }
        if let hook = admittedHook {
            do { try hook() } catch {
                Self.closeRefused(opened)
                return refusedToOpen(url, Self.words(error))
            }
        }
        return await finishOpen(opened, at: url, before: before, requiringLatch: requiringLatch)
    }

    public static let readerOnlyWords = "opened for reading only by a process that is not the catalog's writer"

    /// READ-ONLY open for a process that is not the catalog's writer (the
    /// preview helper, the Hallie shell — 2026-10-19, cutover audit gap 3):
    /// SQLITE_OPEN_READONLY, no migration (an unmigrated file is refused), no
    /// high-water reconcile or raise, every write refused. The engine checks
    /// still run. The outcome is always `.readOnly` or `.refused`. The one
    /// file it may create is a missing EMPTY `-wal` (#386, `walSidecarRefusal`).
    public func openForReading(at url: URL) async -> CatalogOpenOutcome {
        guard pool == nil else { return .refused(reason: "already open at \(databaseURL?.path ?? "?")") }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return refusedToOpen(url, "could not open: no file at \(url.path)")
        }
        if let words = Self.walSidecarRefusal(url) { return refusedToOpen(url, words) }   // #386
        let before = CatalogFileIdentity.read(url)
        let opened: Opened
        do {
            opened = Opened(pool: try Self.makePool(at: url, durability: durability, readonly: true),
                            readOnlyReason: Self.readerOnlyWords, verdict: nil)
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
            // #151-1: the open is admitted — the session's own close may
            // checkpoint and tidy its WAL again, as before. The last step
            // that can throw; nothing after it refuses.
            try Self.liftCloseProtection(opened)
            pool = opened.pool
            databaseURL = url
            self.fileGuard = fileGuard
            session.begin(generation: settled.generation)
            session.noteSidecars(CatalogSidecarQuarantine.identities(besideDatabaseAt: url))
            mode = settled.mode
            storeLog.notice("catalog store OPEN \(url.lastPathComponent, privacy: .public) generation \(settled.generation, privacy: .public) → \(String(describing: settled.mode.outcome), privacy: .public)")
            return settled.mode.outcome
        } catch {
            Self.closeRefused(opened)
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
        /// The read-write pool's open verdict (#387): the checks passed in
        /// the writer's first transaction; nil for a read-only pool, whose
        /// `prepare` runs the checks itself.
        let verdict: OpenVerdict?
    }

    private static func openPool(at url: URL, durability: Durability) throws -> Opened {
        let verdict = OpenVerdict(path: SQLiteWALSidecar.resolvedPath(url))
        do {
            return Opened(pool: try makePool(at: url, durability: durability, readonly: false, verdict: verdict),
                          readOnlyReason: nil, verdict: verdict)
        } catch let error as DatabaseError
                    where FileManager.default.fileExists(atPath: url.path)
                    && (error.resultCode == .SQLITE_READONLY || error.resultCode == .SQLITE_CANTOPEN) {
            if let words = walSidecarRefusal(url) { throw Refusal(reason: words) }   // #386
            let pool = try makePool(at: url, durability: durability, readonly: true)
            let folder = url.deletingLastPathComponent().path
            return Opened(pool: pool,
                          readOnlyReason: "the folder \(folder) is not writable (\(error.message ?? "")) — opened for reading only",
                          verdict: nil)
        }
    }

    /// The ONE place a `DatabasePool` is created (CatalogStoreSensorTests
    /// pins it). Every pragma the contract names is set here, per
    /// connection, so a reader cannot drift from the writer. `verdict`
    /// (read-write only, #387): the open checks run on the WRITER connection
    /// as its first transaction, after the pragmas below and BEFORE GRDB's
    /// WAL setup — see `OpenVerdict`.
    private static func makePool(at url: URL, durability: Durability, readonly: Bool,
                                 verdict: OpenVerdict? = nil) throws -> DatabasePool {
        var configuration = Configuration()
        configuration.label = "VideoScan.catalog"
        configuration.readonly = readonly
        configuration.foreignKeysEnabled = true                       // PRAGMA foreign_keys = ON
        let synchronous = durability.synchronous
        let fullfsync = durability.fullfsync
        let busyMilliseconds = Int(busyTimeoutSeconds * 1_000)
        configuration.prepareDatabase { db in
            // #151-1: the read-write writer's VERY FIRST act, before any
            // statement that reads the schema (a malformed schema fails the
            // first such pragma, and GRDB closes the connection at once):
            // its close may neither checkpoint nor delete until the open is
            // admitted (OpenVerdict.setCloseProtection; lifted in finishOpen).
            if verdict != nil, !db.configuration.readonly { try OpenVerdict.setCloseProtection(db, on: true) }
            // The engine's own busy handler (not GRDB's `busyMode`, which
            // installs a callback the pragma cannot report back). FIRST:
            // `PRAGMA synchronous` reads the schema, so it already needs a
            // shared lock — a catalog briefly locked by another connection
            // was refused at once when this came after it (codex #144-4).
            try db.execute(sql: "PRAGMA busy_timeout = \(busyMilliseconds)")
            try db.execute(sql: "PRAGMA synchronous = \(synchronous)")
            try db.execute(sql: "PRAGMA fullfsync = \(fullfsync)")
            // codex C′ #1: a REPLACE conflict resolution deletes the row in
            // the way, and SQLite fires that row's BEFORE DELETE trigger
            // only when this is on. The DDL's no-delete triggers are the
            // second layer; this pragma is what lets them see the delete.
            try db.execute(sql: "PRAGMA recursive_triggers = ON")
            // #387: readers (and a read-only pool's writer) are read-only
            // connections; only the read-write writer reaches the verdict.
            if let verdict, !db.configuration.readonly { try verdict.reach(db) }
        }
        // journal_mode = WAL is DatabasePool's own invariant; it sets it —
        // AFTER prepareDatabase, so only a file that passed the checks is
        // switched or written (GRDB 7.11.1 DatabasePool.init → setUpWALMode).
        // A refusal from prepareDatabase: GRDB closes that writer at once
        // (SerializedDatabase closes a connection whose setUp threw) — with
        // its close protection already on.
        let pool = try DatabasePool(path: url.path, configuration: configuration)
        // codex #141 F1: GRDB 7.11.1 enables WAL on the WRITER after
        // prepareDatabase ran, and follows it with `PRAGMA synchronous =
        // NORMAL` (GRDB/Core/Database.swift, setUpWALMode — "many
        // applications choose NORMAL in WAL mode"). The readers never run
        // that step, so they said FULL while the one connection that commits
        // said NORMAL: an acknowledged commit could still be lost to a power
        // cut before the WAL was synced. Set the writer back here, on the
        // writer queue, before migration or any write (a read-only pool skips
        // GRDB's WAL step, so there is nothing to undo).
        if !readonly {
            try pool.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA synchronous = \(synchronous)")
            }
        }
        return pool
    }

    // The open checks (OpenVerdict / prepare / checkEngine / checkSchemaVersion
    // / loadGeneration) are in the "Open checks" extension below, same file.

    // MARK: - Migrations

    /// `foreignKeyChecks: .immediate` — foreign keys stay ON for the whole
    /// migration and every statement is checked as it runs; nothing is
    /// deferred to one check at the end. Part 2's data migrations MUST
    /// register the same way. GRDB's one documented exception is a
    /// migration that recreates a table (drop + create under the same
    /// name), which needs `.deferred`; if part 2 ever needs that, the
    /// registration says so beside it.
    ///
    /// `confirm` (#387): run FIRST inside each migration's own immediate
    /// transaction — the open verdict, proven still true under the lock
    /// that writes (`OpenVerdict.confirm`). GRDB runs every migration in its
    /// own transaction, so the checks' transaction cannot be the one that
    /// migrates; this carries the verdict into each of them instead.
    private static func migrator(host: String, confirm: (@Sendable (Database) throws -> Void)? = nil) -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        let now = unixNow()
        let version = CatalogBookkeepingSchema.schemaVersion
        migrator.registerMigration(CatalogBookkeepingSchema.migrationID, foreignKeyChecks: .immediate) { db in
            try confirm?(db)
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
            try confirm?(db)
            for statement in CatalogDataSchema.statements {
                try db.execute(sql: statement)
            }
        }
        // Cutover B2 (v1.7): additive — one table for the app's live writes,
        // and the version raised so an older build refuses the file.
        migrator.registerMigration(CatalogLiveWritesSchema.migrationID, foreignKeyChecks: .immediate) { db in
            try confirm?(db)
            for statement in CatalogLiveWritesSchema.statements + CatalogLiveWritesSchema.versionBump {
                try db.execute(sql: statement)
            }
        }
        // Cutover B2.1 (v1.8): additive — the holding place for new records
        // without a whole-file digest, and the version raised again.
        migrator.registerMigration(CatalogPendingRowsSchema.migrationID, foreignKeyChecks: .immediate) { db in
            try confirm?(db)
            for statement in CatalogPendingRowsSchema.statements + CatalogPendingRowsSchema.versionBump {
                try db.execute(sql: statement)
            }
        }
        // Cutover B2.2 (v1.9): additive — a purge of a held record is a
        // tombstone beside its kept payload, never a DELETE of it.
        migrator.registerMigration(CatalogCommitB22Schema.migrationID, foreignKeyChecks: .immediate) { db in
            try confirm?(db)
            for statement in CatalogCommitB22Schema.statements + CatalogCommitB22Schema.versionBump {
                try db.execute(sql: statement)
            }
        }
        // Catalog folders (v1.10): additive — `events.kind`, version 11.
        migrator.registerMigration(CatalogFolderKindSchema.migrationID, foreignKeyChecks: .immediate) { db in
            try confirm?(db)
            for statement in CatalogFolderKindSchema.statements + CatalogFolderKindSchema.versionBump {
                try db.execute(sql: statement)
            }
        }
        // Rick's decisions (v1.11): additive — `footage_likeness` and
        // `ignored_content_put_back`, version 12.
        migrator.registerMigration(CatalogDecisionTablesSchema.migrationID, foreignKeyChecks: .immediate) { db in
            try confirm?(db)
            for statement in CatalogDecisionTablesSchema.statements + CatalogDecisionTablesSchema.versionBump {
                try db.execute(sql: statement)
            }
        }
        // Provenance roles (v1.12, Rick approved 2026-10-26): additive —
        // `provenance_roles`, version 13.
        migrator.registerMigration(CatalogProvenanceRolesSchema.migrationID, foreignKeyChecks: .immediate) { db in
            try confirm?(db)
            for statement in CatalogProvenanceRolesSchema.statements + CatalogProvenanceRolesSchema.versionBump {
                try db.execute(sql: statement)
            }
        }
        return migrator
    }

    /// The `catalog_state.schema_version` a fully migrated database carries
    /// (v1 creates 7; `v3_live_writes` raises it to 8; `v4_pending_rows` to
    /// 9; `v5_b22_commit` to 10; `v6_folder_kind` to 11; `v7_decision_tables`
    /// to 12; `v8_provenance_roles` to 13). A HIGHER number is a newer
    /// build's file and is refused at open.
    static let currentSchemaVersion = CatalogProvenanceRolesSchema.schemaVersion

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
        let plan = OpenPlan(databaseURL: url, host: host, publish: durability.publish, hook: openHook, fileGuard: fileGuard,
                            verdict: opened.verdict)
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
        /// #387: the open verdict, confirmed first under this transaction's
        /// lock — the lock that publishes the writer.
        let verdict: OpenVerdict?

        func run(_ db: Database) throws -> Settled {
            var settled = Settled(generation: 0, mode: .closed)
            try db.inTransaction(.immediate) {
                try verdict?.confirm(db)
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

    /// Internal test seam. See `admittedHook`.
    func injectAdmittedHook(_ seam: Seam?) {
        admittedHook = seam
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
        // (QA r2-1), and only AFTER the writer queue drains (codex #117 F2):
        // a swap while close waits behind a writer must be seen.
        //   .same    (a latch-only stop, a file moved away and back): the
        //            normal checkpoint; if it fails the -wal stays at the
        //            path, where the right file replays it.
        //   .moved   (missing, or another inode — QA r1 F3): no checkpoint,
        //            and once the pool is closed this session's own -wal /
        //            -shm are renamed into quarantine (never deleted).
        //   .unknown (stat failed, codex #117 F1): NOTHING is moved and no
        //            checkpoint runs; the -wal stays at the path; the words say so.
        // Fold the write-ahead log into the database file BEFORE the pool
        // closes (2026-10-17): GRDB closes the writer before its readers, so
        // SQLite's own close-time checkpoint never runs (CatalogCloseCheckpointTests).
        // A read-only session has nothing of its own to fold in.
        let atPath = mode == .readWrite ? await Self.decideAtClose(pool, fileGuard, session) : .same
        if mode != .readWrite, let fileGuard { _ = session.fileStop(fileGuard) }
        if let stop = session.fileStopped {
            storeLog.error("catalog store CLOSE after the file check failed (\(String(describing: atPath), privacy: .public)): \(stop, privacy: .public)")
        }
        var poolClosed = true
        do {
            try pool.close()
        } catch {
            poolClosed = false
            storeLog.error("catalog store CLOSE: \(Self.words(error), privacy: .public)")
        }
        var notes: [String] = []
        if mode == .readWrite, let databaseURL {
            switch atPath {
            case .same: break                                    // checkpointed (or its -wal stays for the right file)
            case .moved:
                notes = poolClosed
                    ? CatalogSidecarQuarantine.quarantine(besideDatabaseAt: databaseURL, own: session.sidecars,
                                                          why: session.fileStopped ?? "catalog.sqlite moved")
                    : CatalogSidecarQuarantine.skipped(besideDatabaseAt: databaseURL, because: "the catalog's connections did not close")
            case .unknown(let why):
                notes = [CatalogSidecarQuarantine.unknownIdentityWords(databaseURL, why)]
            }
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

// MARK: - Close's decision, after the writer drains (codex #117 F2)

extension GRDBCatalogRepository {

    /// Runs ON the writer queue — after every write queued before close —
    /// so the identity read and the checkpoint see the same moment. Records
    /// the sticky stop (database or latch). Checkpoints only when the file
    /// at the path is still this session's. If the queue cannot run the
    /// closure at all, the decision is read just after that failed wait.
    static func decideAtClose(_ pool: DatabasePool, _ fileGuard: CatalogFileGuard?,
                              _ session: WriterSession) async -> CatalogFileGuard.DatabaseAtPath {
        do {
            return try await pool.writeWithoutTransaction { db -> CatalogFileGuard.DatabaseAtPath in
                let found = fileGuard?.databaseAtPath() ?? .same
                if let fileGuard { _ = session.fileStop(fileGuard) }
                if found == .same {
                    do {
                        try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
                    } catch {
                        storeLog.error("catalog store CLOSE checkpoint: \(Self.words(error), privacy: .public)")
                    }
                }
                return found
            }
        } catch {
            storeLog.error("catalog store CLOSE: the writer did not run the close step: \(Self.words(error), privacy: .public)")
            if let fileGuard { _ = session.fileStop(fileGuard) }
            return fileGuard?.databaseAtPath() ?? .same
        }
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

    /// codex #117 F3: the quit's close did not finish in time. Off the actor
    /// and without waiting for close: if catalog.sqlite at the path is
    /// CONFIRMED not this session's file (missing or another inode), rename
    /// this session's own -wal / -shm (matched by inode) into quarantine now —
    /// safe under open descriptors: a writer still running keeps writing to
    /// the renamed files, never to the path. Anything else (the same file —
    /// a latch-only stop —, an unreadable identity, a read-only or closed
    /// session) moves NOTHING.
    public nonisolated func quarantineAfterTimedOutClose() -> CatalogTimedOutClose {
        let open = gate.state
        guard let fileGuard = open.fileGuard, open.pool != nil, open.readOnlyReason == nil else { return .notOpen }
        switch fileGuard.databaseAtPath() {
        case .same:
            return .stillItsOwnFile
        case .unknown(let why):
            return .identityUnreadable(why)
        case .moved:
            let why = session.fileStop(fileGuard) ?? "catalog.sqlite moved"
            return .quarantined(lines: CatalogSidecarQuarantine.quarantine(besideDatabaseAt: fileGuard.databaseURL,
                                                                           own: session.sidecars, why: why))
        }
    }
}

// MARK: - Open checks (DDL §11) and the open verdict (#387)
//
// Moved out of the actor body (codex #141 kept the body under SwiftLint's
// 600 lines); same file, so `Refusal` and the migrator stay private. Every
// check takes a `Database`, so the SAME code runs in the read-write writer's
// first transaction (`OpenVerdict.reach`) and on a read-only pool (`prepare`).

extension GRDBCatalogRepository {

    /// The words for a file the open would have to recover before it could
    /// check it (codex #142 F6-2): nothing was opened.
    static func unverifiedWords(_ url: URL, _ why: String) -> String {
        "\(url.lastPathComponent) could not be verified before opening (\(why)) — it was not opened; nothing was written"
    }

    /// What every refusal reached by the verdict says about the file (#387).
    /// True because the checks ran before GRDB's WAL switch and init write,
    /// nothing in this file unlinks, and the writer's close protection
    /// (on before its first schema read) keeps SQLite's own close from
    /// checkpointing or deleting (see `OpenVerdict`). `path` is the RESOLVED
    /// path, so the sidecar names are the ones SQLite uses (#151-4).
    static func leftAsFoundWords(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return "VideoScan left \(name) as found: it wrote nothing to it and removed nothing beside it (SQLite's journal files \(name)-wal and \(name)-shm may now be beside it)"
    }

    /// A refusal reached by the RE-check: another connection committed to
    /// the file after the verdict, so GRDB's opening step (and any migration
    /// that finished first) had already run. Said as it is.
    static func changedDuringOpenWords(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return "another program changed \(name) while VideoScan was opening it; the re-check refused it before VideoScan wrote anything more (its writes until then: the database engine's opening step and any schema upgrade already finished), and nothing beside it was removed"
    }

    /// A rollback journal another program left mid-write, read from its
    /// bytes — no connection is made. SQLite's own "hot" test
    /// (lockingv3.html §Hot Journals) without the lock probe: the file
    /// exists, is non-empty, and the header's first byte is not zero
    /// (journal_mode=PERSIST zeroes it, TRUNCATE leaves 0 bytes). The first
    /// read-write lock would play it back — a write to the main file and a
    /// delete of the journal — before any check could refuse. A catalog in
    /// WAL mode never makes one, so this is always another program's; a
    /// journal that is live rather than hot is refused too, and the next
    /// open, after that program commits, succeeds.
    ///
    /// The journal is looked for beside the RESOLVED path — the name SQLite
    /// itself uses for a symlinked database (#151-4).
    ///
    /// Not closed (Codex #151-3, documented, issue drafted): this is an
    /// unlocked look. A rollback-mode writer that crashes in the
    /// microseconds between it and the writer's first schema read leaves a
    /// journal SQLite then plays back before the checks. It needs a foreign
    /// rollback-mode writer crashing during our open.
    static func hotJournal(beside url: URL) -> String? {
        let path = SQLiteWALSidecar.resolvedPath(url)
        guard let handle = FileHandle(forReadingAtPath: path + "-journal") else { return nil }
        defer { try? handle.close() }
        guard let first = (try? handle.read(upToCount: 1))?.first, first != 0 else { return nil }
        return "\((path as NSString).lastPathComponent)-journal is beside it: a write another program did not finish. Open it once with that program, or sqlite3, to finish the recovery"
    }

    /// The open's verdict (#387, Rick 2026-10-26: "the lock that admits the
    /// file is the lock that writes it").
    ///
    /// `reach` runs on the read-write pool's WRITER connection, from
    /// `prepareDatabase` — its first transaction, after the pragmas (so the
    /// 5 s busy timeout applies) and BEFORE GRDB 7.11.1's `setUpWALMode`
    /// (DatabasePool.init: `PRAGMA journal_mode = WAL`, then a CREATE/DROP
    /// of `grdb_issue_102` when the `-wal` is missing or empty). Inside
    /// `BEGIN IMMEDIATE` it runs integrity_check, foreign_key_check and the
    /// version check, notes `PRAGMA data_version`, and rolls back. A
    /// refusal throws out of the pool's construction, so a refused file is
    /// never switched to WAL and gets no init write.
    ///
    /// GRDB runs its own WAL setup and every migration in transactions of
    /// its own, so the checks' transaction cannot also be the writing one.
    /// The verdict is carried instead: every later open transaction that
    /// writes (each migration, the high-water reconcile) calls `confirm`
    /// first, under its own write lock. `data_version` on the same
    /// connection changes only when ANOTHER connection committed
    /// (pragma.html#pragma_data_version), so an unchanged value proves the
    /// checked file is the file being written; a changed one re-runs the
    /// checks right there, under that lock (codex #144-2).
    ///
    /// `setCloseProtection` (codex #144-1/-3, #151-1): nothing in the store
    /// unlinks a sidecar, and SQLite's own close must not either — as the
    /// last connection it would checkpoint any committed `-wal` frames into
    /// the main file and then delete (Apple's build: truncate) the `-wal`
    /// and the `-shm`. So the read-write writer's FIRST act in
    /// `prepareDatabase`, before any statement reads the schema, is
    /// SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE (through the one-function C target
    /// CSQLiteCloseGuard — sqlite3_db_config is variadic, which Swift cannot
    /// call) plus SQLITE_FCNTL_PERSIST_WAL. With NO_CKPT_ON_CLOSE the close
    /// skips the checkpoint, and SQLite deletes/truncates the WAL only after
    /// a checkpoint succeeded, so neither the main file nor a sidecar is
    /// touched; PERSIST_WAL is the second layer. Both stay on for the whole
    /// open and are lifted (`liftCloseProtection`) only when the session is
    /// about to be published. (The read-only "holder" connection of the
    /// previous round is gone: Codex #151-1 showed it came too late — a
    /// malformed schema fails the first pragma — and a failed holder left
    /// only PERSIST_WAL, which does not stop the checkpoint.)
    ///
    /// NOT closed this round (Codex #151-2, documented, issue drafted): the
    /// verdict's lock is released before GRDB's own setup writes — the WAL
    /// switch, the `grdb_issue_102` CREATE/DROP, and the migrator's
    /// `CREATE TABLE IF NOT EXISTS grdb_migrations` — none of which runs
    /// `confirm`. A foreign writer that commits an inadmissible change in
    /// that window gets those writes before the later `confirm` refuses
    /// (whose words say so: `changedDuringOpenWords`). Needs a foreign
    /// writer committing during our open.
    ///
    /// Memory: one Int.
    /// For Rick: a mutex-guarded struct the writer's setup closure and the
    /// open share — a std::shared_ptr<Verdict> two threads touch under a lock.
    final class OpenVerdict: @unchecked Sendable {
        /// The database file (GRDB keeps `Database.path` internal).
        let path: String
        private let lock = NSLock()
        /// `PRAGMA data_version` on the writer when the checks last passed.
        private var dataVersion: Int?

        init(path: String) { self.path = path }

        /// The checks, in the writer's first transaction (see above).
        func reach(_ db: Database) throws {
            do {
                var seen = 0
                try db.inTransaction(.immediate) {
                    try GRDBCatalogRepository.checkEngine(db)
                    try GRDBCatalogRepository.checkSchemaVersion(db)
                    seen = try Int.fetchOne(db, sql: "PRAGMA data_version") ?? 0
                    return .rollback   // nothing was written; nothing to keep
                }
                lock.withLock { dataVersion = seen }
            } catch let refusal as Refusal {
                throw Refusal(reason: "\(refusal.reason) — \(GRDBCatalogRepository.leftAsFoundWords(path))")
            }
        }

        /// The verdict still holds, proven inside the caller's IMMEDIATE
        /// transaction: no other connection committed since the checks, or
        /// the checks pass again now.
        func confirm(_ db: Database) throws {
            let now = try Int.fetchOne(db, sql: "PRAGMA data_version")
            if let now, now == lock.withLock({ dataVersion }) { return }
            do {
                try GRDBCatalogRepository.checkEngine(db)
                try GRDBCatalogRepository.checkSchemaVersion(db)
            } catch let refusal as Refusal {
                throw Refusal(reason: "\(refusal.reason) — \(GRDBCatalogRepository.changedDuringOpenWords(path))")
            }
            lock.withLock { dataVersion = now }
        }

        /// Close protection on the connection `db` (see above). On: the
        /// close neither checkpoints nor deletes; off: SQLite's default.
        /// Throws when NO_CKPT_ON_CLOSE does not take — the open is then
        /// refused before anything was read (fail closed).
        static func setCloseProtection(_ db: Database, on: Bool) throws {
            guard let connection = db.sqliteConnection else { throw Refusal(reason: "the catalog connection is closed") }
            var now: Int32 = -1
            let code = videoscan_sqlite3_no_ckpt_on_close(UnsafeMutableRawPointer(connection), on ? 1 : 0, &now)
            guard code == SQLITE_OK, now == (on ? 1 : 0) else {
                throw Refusal(reason: "SQLite would not \(on ? "set" : "clear") NO_CKPT_ON_CLOSE (code \(code), now \(now)) — the catalog was not opened")
            }
            var persist: Int32 = on ? 1 : 0
            _ = sqlite3_file_control(connection, "main", SQLITE_FCNTL_PERSIST_WAL, &persist)   // second layer; best effort
        }
    }

    /// Close the pool of an open that was refused. Its writer still has
    /// the close protection it got first thing (lifted only on success), so
    /// the close neither checkpoints nor deletes; a read-only pool cannot.
    private static func closeRefused(_ opened: Opened) {
        try? opened.pool.close()
    }

    /// The open is admitted: give the writer SQLite's default close back.
    private static func liftCloseProtection(_ opened: Opened) throws {
        guard opened.verdict != nil, opened.readOnlyReason == nil else { return }
        try opened.pool.writeWithoutTransaction { db in try OpenVerdict.setCloseProtection(db, on: false) }
    }

    /// The open checks and the migration. A read-write pool's checks already
    /// ran in its writer's first transaction (`OpenVerdict.reach`); each
    /// migration confirms the verdict first. A read-only pool (the reading
    /// doors, a read-only folder) runs the checks here and never migrates.
    /// Throws a `Refusal` (words for the person) or an engine error.
    private static func prepare(_ opened: Opened, host: String) async throws -> Int {
        if let verdict = opened.verdict, opened.readOnlyReason == nil {
            try migrator(host: host, confirm: { db in try verdict.confirm(db) }).migrate(opened.pool)
        } else {
            try await checkEngine(opened.pool)
            try await opened.pool.read { db in try checkSchemaVersion(db) }
            if try await !migrationsComplete(opened.pool, host: host) {
                throw Refusal(reason: "the database is read-only and its schema is not current")
            }
        }
        return try await loadGeneration(opened.pool)
    }

    private static func checkEngine(_ pool: DatabasePool) async throws {
        try await pool.read { db in try checkEngine(db) }
    }

    private static func checkEngine(_ db: Database) throws {
        let integrity = try String.fetchAll(db, sql: "PRAGMA integrity_check")
        guard integrity == ["ok"] else {
            throw Refusal(reason: "integrity_check: \(integrity.joined(separator: "; "))")
        }
        let violations = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").count
        guard violations == 0 else {
            throw Refusal(reason: "foreign_key_check: \(violations) violation(s)")
        }
    }

    private static func checkSchemaVersion(_ db: Database) throws {
        guard try db.tableExists("catalog_state") else { return }
        let found = try Int.fetchOne(db, sql: "SELECT schema_version FROM catalog_state WHERE singleton = 1")
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

    private static func migrationsComplete(_ pool: DatabasePool, host: String) async throws -> Bool {
        let migrator = migrator(host: host)
        return try await pool.read { db in try migrator.hasCompletedMigrations(db) }
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
        return try await pool.read { db in try Self.reportPragmas(db) }
    }

    /// The same pragmas on the WRITER connection (codex #141 F1: GRDB's WAL
    /// setup touches only the writer, so the reader's reading cannot stand
    /// for it). Runs on the writer queue; no transaction, nothing written.
    func writerPragmas() async throws -> [String: String] {
        guard let pool else { throw CatalogRepositoryError.notOpen }
        return try await pool.writeWithoutTransaction { db in try Self.reportPragmas(db) }
    }

    private static func reportPragmas(_ db: Database) throws -> [String: String] {
        var reported: [String: String] = [:]
        for name in ["journal_mode", "synchronous", "fullfsync", "foreign_keys", "recursive_triggers", "busy_timeout", "user_version"] {
            reported[name] = try Row.fetchOne(db, sql: "PRAGMA \(name)").map { text($0[0]) } ?? ""
        }
        return reported
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

    /// #386 (Rick 2026-10-26): before any READ-ONLY pool. Apple's SQLite
    /// refuses a read-only open of a WAL-mode file with no `-wal` beside it;
    /// `SQLiteWALSidecar` restores the empty one (create-only) when the
    /// folder takes it, and nil means "go ahead". Otherwise: the words.
    static func walSidecarRefusal(_ url: URL) -> String? {
        switch SQLiteWALSidecar.prepareForReadOnlyOpen(url) {
        case .notNeeded, .alreadyThere:
            return nil
        case .created:
            storeLog.notice("catalog store: restored the empty \(url.lastPathComponent, privacy: .public)-wal a read-write last closer removed, before a read-only open")
            return nil
        case .refused(let words):
            return words
        }
    }

    /// The words every sealed-snapshot session carries as its read-only reason.
    public static let sealedSnapshotWords = "a sealed snapshot of the master's catalog — read-only on this Mac"

    /// Open `url` for READING ONLY, with `reason` as the session's read-only
    /// words. SQLITE_OPEN_READONLY; no migration (an incomplete schema is
    /// refused); the high-water witnesses are neither read nor raised; every
    /// write is refused for the session. The same engine and schema checks
    /// as `open` (integrity_check, foreign_key_check, schema version), run
    /// on the read-only pool (it cannot write, so it has no verdict to hold).
    public func openReadOnly(at url: URL, reason: String) async -> CatalogOpenOutcome {
        guard pool == nil else {
            return .refused(reason: "already open at \(databaseURL?.path ?? "?")")
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return refusedToOpen(url, "\(url.lastPathComponent) does not exist")
        }
        if let words = Self.walSidecarRefusal(url) { return refusedToOpen(url, words) }   // #386
        let before = CatalogFileIdentity.read(url)
        let opened: Opened
        do {
            opened = Opened(pool: try Self.makePool(at: url, durability: durability, readonly: true), readOnlyReason: reason,
                            verdict: nil)
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
