// CatalogAuthorityFlip.swift
// Which catalog the app opens at launch (cutover B1, docs/design/
// catalog_cutover_f_prime_2026_10_17.md §7 "The flip").
//
// One sentence: the app reads its records from catalog.sqlite ONLY when Rick
// has switched to it (the latch file `catalog.cutover` beside the catalog),
// the database opens, and an import finished with the comparator's word.
//
// Outcomes (each one tested, CatalogAuthorityFlipTests):
//   .noLatch       no latch → the launch REFUSES, loudly, master or viewer
//                  (Rick 2026-10-21, GH #354: no JSON fallback for old
//                  catalogs). catalog.json is never opened — not writable,
//                  not read-only; the session starts empty and read-only,
//                  and the words say the master (or migrate_data.sh) must
//                  carry catalog.sqlite and its latch. The database is not
//                  opened either. (A test host on the shared store keeps
//                  its own path: it loads nothing.) A VIEWER's authority is
//                  its synced copy (Rick 2026-10-21): with the master's
//                  snapshot and ITS latch in viewer-catalog/, there is no
//                  refusal — the launch is empty and read-only and the
//                  viewer shows the snapshot (CatalogSync's
//                  refreshViewerCatalog); with neither latch it says
//                  "nothing synced from the master yet".
//   .sqlite(url)   latch + the store opens (read-write, or read-only after a
//                  restore — never a fall-back to an older authority) + a
//                  finished, comparator-ok import;
//   .refused(why)  latch, but one of those is not true → the store's words,
//                  and catalog.json opens READ-ONLY (two writable
//                  authorities is the lost-update class the generation
//                  guard exists for).
// Only "Switch Catalog to SQLite…" (B2; retired 2026-10-20 once the switch
// was done) wrote the latch; nothing in the app writes it now, and nothing
// here writes catalog.json. B2: under `.sqlite` the
// repository stays OPEN for the session and the save funnels commit
// through it (CatalogCommitter); the Master Archive designation is read
// from `catalog_state` only — a SQLite launch reads no byte of catalog.json
// (2026-10-21, GH #353).
//
// The model's init is synchronous (it always was: catalog.json loads on
// the main thread at launch), and the store is async, so the launch waits
// for the store on a semaphore — once, at launch, with no main-actor work
// inside the awaited part (`CatalogLaunchWait`).
//
// (For Rick: `enum` with associated values ≈ a tagged union; `decide` is a
// pure function of three files on disk plus one query.)

import Foundation
import os
import VideoScanCore

private let flipLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "catalogAuthority")

enum CatalogAuthority: Equatable, Sendable {
    /// No `catalog.cutover` beside the catalog (was `.json` until GH #354).
    case noLatch
    case sqlite(URL)
    case refused(String)

    static let databaseFileName = CatalogImporter.Inputs.databaseFileName
    /// Written once, by the explicit "Switch Catalog to SQLite…" door (B2,
    /// retired 2026-10-20 after the switch); nothing in the app writes it now.
    nonisolated static let latchFileName = "catalog.cutover"

    /// The latch beside `folder` names catalog.sqlite the authority. A side
    /// store there (folders, the ignore list) that is NOT attached to a
    /// writable committer refuses every write with `sideStoreRefusal` —
    /// never its JSON file (codex #113 P1-4: a launch that fell back or was
    /// refused used to leave those doors writing JSON). One stat; read at
    /// each write so no launch path can forget it.
    nonisolated static func latchNamesSQLite(in folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(latchFileName).path)
    }

    /// The words a refused side-store write says.
    nonisolated static func sideStoreRefusal(_ what: String, file: String) -> String {
        "catalog.sqlite is the catalog's authority but this session is not attached to it — \(what) refused; "
            + "\(file) is never written (reopen the catalog, or relaunch)"
    }

    /// The launch rule. Reads; writes nothing but what `open` itself does
    /// to an existing database (its schema check and high-water witness).
    /// `readOnly` (codex cycle #112): a viewer — or any session whose role is
    /// read-only — opens catalog.sqlite with `openReadOnly`: no migration, no
    /// high-water witness, nothing written.
    static func decide(folder: URL, readOnly: Bool = false) async -> CatalogAuthority {
        let latch = folder.appendingPathComponent(latchFileName)
        guard FileManager.default.fileExists(atPath: latch.path) else { return .noLatch }
        let db = folder.appendingPathComponent(databaseFileName)
        guard FileManager.default.fileExists(atPath: db.path) else {
            return .refused("the catalog was switched to SQLite (\(latchFileName)) but \(databaseFileName) is not beside it")
        }
        let repository = GRDBCatalogRepository()
        if case .refused(let reason) = await open(repository, at: db, readOnly: readOnly) {
            await repository.close()
            return .refused("\(databaseFileName) would not open: \(reason)")
        }
        let finished: Int
        do {
            finished = try await repository.read { try $0.finishedImports() }
        } catch {
            await repository.close()
            return .refused("\(databaseFileName) could not be read: \(error)")
        }
        await repository.close()
        guard finished > 0 else {
            return .refused("\(databaseFileName) holds no finished import checked by the comparator")
        }
        return .sqlite(db)
    }

    /// The read-only reason a viewer's own catalog.sqlite opens with.
    static let viewerReadOnlyWords = "this Mac is a viewer — catalog.sqlite opened read-only; only the master writes the catalog"

    /// The launch's one open: read-write (`open`, which may migrate and
    /// raise the high-water) or, for a read-only session, `openReadOnly`.
    static func open(_ repository: GRDBCatalogRepository, at url: URL, readOnly: Bool) async -> CatalogOpenOutcome {
        readOnly ? await repository.openReadOnly(at: url, reason: viewerReadOnlyWords) : await repository.open(at: url)
    }

    /// The words a launch with no latch shows (GH #354), in the one sink.
    static func noLatchWords(folder: URL) -> String {
        "No catalog — \(latchFileName) is not beside the catalog in \(folder.path), so this Mac was never switched to "
            + "\(databaseFileName). catalog.json is not opened (not even read-only): the master (or migrate_data.sh) "
            + "must carry \(databaseFileName) and its \(latchFileName). Nothing will be saved this session."
    }

    /// A viewer with neither latch (its own, nor viewer-catalog/'s).
    static func viewerNothingSyncedWords(folder: URL) -> String {
        "viewer: nothing synced from the master yet — no \(latchFileName) in \(folder.path) nor in "
            + "\(CatalogViewerSnapshot.directoryName)/. catalog.json is not opened; the catalog appears read-only "
            + "after the first sync from the master."
    }

    /// The words a refusal shows (console, catalog.log, videoscan.log).
    static func readOnlyWords(_ why: String) -> String {
        "SQLite catalog refused — \(why). catalog.json is open READ-ONLY: nothing will be saved this session."
    }
}

/// The launch's read of catalog.sqlite: open, display pass + snapshot, the
/// designation — and the repository, left OPEN for the session's commits.
struct SQLiteLaunchRead: Sendable {
    let repository: GRDBCatalogRepository
    let opened: CatalogOpenOutcome
    let snapshot: CatalogLoad.Snapshot
    let designationJSON: String?

    static func read(_ url: URL, readOnly: Bool = false) async -> Result<SQLiteLaunchRead, CatalogLoad.Failure> {
        let repository = GRDBCatalogRepository()
        let opened = await CatalogAuthority.open(repository, at: url, readOnly: readOnly)
        if case .refused(let reason) = opened {
            await repository.close()
            return .failure(.readFailed("\(CatalogAuthority.databaseFileName) would not open: \(reason)"))
        }
        do {
            let snapshot = try await CatalogLoad.read(repository)
            let designation = try await repository.read { try $0.masterArchiveJSON() }
            return .success(SQLiteLaunchRead(repository: repository, opened: opened, snapshot: snapshot, designationJSON: designation))
        } catch let failure as CatalogLoad.Failure {
            await repository.close()
            return .failure(failure)
        } catch {
            await repository.close()
            return .failure(.readFailed(String(describing: error)))
        }
    }
}

/// Waits, at launch only, for async store work from the synchronous model
/// init. The work runs on the cooperative pool and never touches the main
/// actor, so blocking the main thread for it cannot deadlock.
/// (For Rick: a future.get() — a semaphore the worker signals.)
enum CatalogLaunchWait {

    private final class Box<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T?
        var value: T? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    static func run<T: Sendable>(_ work: @escaping @Sendable () async -> T) -> T {
        let box = Box<T>()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await work()
            done.signal()
        }
        done.wait()
        guard let value = box.value else { preconditionFailure("CatalogLaunchWait: the work signalled without a value") }
        return value
    }
}

// MARK: - The model's launch seam

extension VideoScanModel {

    /// What `init` restores: catalog.sqlite's records, or nothing (a launch
    /// with no latch refuses — GH #354).
    func loadCatalogAtLaunch() -> [VideoRecord] {
        // Test hosts on the shared store: today's path (it loads nothing),
        // and never a look at the real Application Support folder.
        if Self.isRunningTests && catalogStore === CatalogStore.shared { return catalogStore.load() }
        let folder = URL(fileURLWithPath: catalogStore.fileLocation).deletingLastPathComponent()
        // Codex cycle #112: the role is known BEFORE the store opens, so a
        // viewer never opens its catalog.sqlite read-write (the window's
        // applyReadOnlyMode later sets the same fact again).
        let viewer = launchesAsViewer()
        if viewer { updateReadOnlyFacts { $0.viewerRole = true } }
        let authority = CatalogLaunchWait.run { await CatalogAuthority.decide(folder: folder, readOnly: viewer) }
        switch authority {
        case .noLatch:
            return viewer ? viewerLaunchWithoutOwnLatch(folder) : refuseLaunchWithoutLatch(folder)
        case .sqlite(let url):
            return loadFromSQLite(url, readOnly: viewer)
        case .refused(let why):
            return loadJSONReadOnly(why)
        }
    }

    /// Is this launch a viewer's? Production: CatalogSync's hostname rule.
    /// Test hosts: the role fact a test applied before launching, so a test
    /// run on a viewer laptop (M5 / M1) behaves like one on the master.
    private func launchesAsViewer() -> Bool {
        if Self.isRunningTests { return readOnlyFacts.viewerRole }
        return CatalogSync.launchMode() == .viewer
    }

    /// The records from catalog.sqlite; any failure falls to the JSON
    /// catalog READ-ONLY with the words. On success the repository stays
    /// open: it is the committer's for the session.
    private func loadFromSQLite(_ url: URL, readOnly: Bool) -> [VideoRecord] {
        let read: Result<SQLiteLaunchRead, CatalogLoad.Failure> = CatalogLaunchWait.run { await SQLiteLaunchRead.read(url, readOnly: readOnly) }
        switch read {
        case .failure(let failure):
            return loadJSONReadOnly(failure.words)
        case .success(let launch):
            do {
                let result = try SQLiteCatalogLoader.build(launch.snapshot)
                adoptSQLiteAuthority(launch, url: url, records: result.records, held: result.heldIDs)
                catalogAuthorityNote("OUTCOME loaded \(result.summary)")
                return result.records
            } catch {
                CatalogLaunchWait.run { await launch.repository.close() }
                return loadJSONReadOnly("a row could not become a record: \(error)")
            }
        }
    }

    /// SQLite is the authority: catalog.json is frozen (read-only, never
    /// written again — and never read: this launch does not open it, nor
    /// rewrite catalog.json.prev or the generation sidecar); the save
    /// funnels commit through `CatalogCommitter` into the open repository.
    /// The designation comes from catalog_state ONLY. (Until 2026-10-21 a
    /// JSON load here supplied catalog.json's designation whenever
    /// catalog_state held none — which brought a CLEARED designation back
    /// at every relaunch, GH #353.) The baseline is taken NOW, before the
    /// launch-time migrations run, and one commit is scheduled so what they
    /// change lands. `held` (B2.1): records from `pending_rows` — still
    /// changed, and Fill In Full Hashes is queued for them.
    private func adoptSQLiteAuthority(_ launch: SQLiteLaunchRead, url: URL, records: [VideoRecord], held: Set<UUID>) {
        updateReadOnlyFacts { $0.jsonFrozenByLaunch = true }
        if let stored = CatalogCommitter.designation(fromJSON: launch.designationJSON) {
            catalogStore.masterArchive = stored
        }
        let committer = CatalogCommitter(repository: launch.repository, storedDesignationJSON: launch.designationJSON,
                                         input: { [weak self] in self?.catalogCommitInput() ?? CatalogCommitter.Input(
                                             records: [], designation: nil, clearAuthorized: false, holdReason: nil, holdOwner: nil) },
                                         sink: { [weak self] line in self?.catalogAuthorityNote(line) })
        committer.adoptBaseline(records, held: held)
        committer.onCopiesUpdated = { [weak self] in self?.noteCatalogMutated() }
        // B2.3: the marker veto answers only for this session's live records.
        committer.owns = { [weak self] record in self?.record(forID: record.id) === record }
        committer.onWritableAgain = { [weak self] in
            // Adopt lifts the launch's session fact only; a viewer stays a viewer.
            self?.updateReadOnlyFacts { $0.sessionReadOnlyByLaunch = false }
            self?.catalogCutover.noteWritable()
        }
        var readOnlyReason: String?
        if case .readOnly(let reason) = launch.opened {
            readOnlyReason = reason
            committer.block("read-only: \(reason)")
            updateReadOnlyFacts { $0.sessionReadOnlyByLaunch = true }
            catalogAuthorityNote("catalog.sqlite opened READ-ONLY — \(reason). Nothing will be saved this session"
                                 + (reason.hasPrefix("restoredBelowHighWater") ? " unless you choose Catalog ▸ Adopt This SQLite Catalog…." : "."))
        } else {
            updateReadOnlyFacts { $0.sessionReadOnlyByLaunch = false }
            // Codex cycle #112: the launch-migration commit only when this
            // session may write (admission refuses it anyway; say so here).
            if readOnlyFacts.modelReadOnly {
                catalogAuthorityNote("catalog.sqlite opened, but this session is read-only — no launch commit is scheduled")
            } else {
                committer.scheduleCommit()
            }
            catalogAuthorityNote("catalog.json is frozen (read-only); every save now commits to \(url.lastPathComponent)")
        }
        catalogCutover.install(committer, databaseURL: url, readOnlyReason: readOnlyReason)
        catalogCutover.requestDigests(held)
        // Rick's decisions in catalog.sqlite (schema v1.11): the footage
        // likeness the inspector shows, and the ignore list (its one-time
        // import of ignored-content.json, then every change through this
        // committer). Per-model stores — safe under a test host too.
        Task { [weak self] in
            guard let self, let why = await self.footageLikeness.load(from: committer.repository) else { return }
            self.catalogAuthorityNote("footage likeness could not be read from catalog.sqlite (\(why)) — the inspector shows none")
        }
        attachIgnoredContentToCatalog(committer)
        // Catalog folders live in catalog.sqlite (2026-10-19): the one store
        // writes through this committer from now on; its first load imports
        // events-decisions.json once. Not under a test host — a sandbox
        // model must never re-point the app's shared store.
        if !Self.isRunningTests {
            EventsDecisionStore.shared.note = { [weak self] line in self?.eventsNote(line) }
            EventsDecisionStore.shared.attachCatalog(EventsCatalogBacking(committer: committer))
            Task { await EventsDecisionStore.shared.load() }
        }
    }

    /// What the committer reads at the moment of a commit.
    func catalogCommitInput() -> CatalogCommitter.Input {
        CatalogCommitter.Input(records: records, designation: masterArchive,
                               clearAuthorized: catalogStore.designationClearAuthorized, holdReason: catalogStore.writeHold,
                               holdOwner: catalogStore.writeHoldOwner, readOnlyReason: readOnlyFacts.readOnlyWords)
    }

    /// GH #354 (Rick 2026-10-21): no latch → no catalog. catalog.json is
    /// never opened; the session is empty and read-only (the JSON store too,
    /// so no save can create a catalog.json), and the words say what is
    /// missing. Viewer or master alike — the role logic is untouched.
    private func refuseLaunchWithoutLatch(_ folder: URL) -> [VideoRecord] {
        freezeLaunchWithoutCatalog()
        catalogAuthorityNote("OUTCOME " + CatalogAuthority.noLatchWords(folder: folder))
        return []
    }

    /// A viewer with no latch of its own: its authority is the synced copy
    /// (viewer-catalog/catalog.sqlite + viewer-catalog/catalog.cutover).
    /// Present → no refusal; the launch is empty and read-only and CatalogSync
    /// shows the snapshot. Absent → "nothing synced from the master yet".
    /// catalog.json is never opened on either branch.
    private func viewerLaunchWithoutOwnLatch(_ folder: URL) -> [VideoRecord] {
        freezeLaunchWithoutCatalog()
        if FileManager.default.fileExists(atPath: CatalogViewerSnapshot.latchURL(in: folder).path) { return [] }
        catalogAuthorityNote("OUTCOME " + CatalogAuthority.viewerNothingSyncedWords(folder: folder))
        return []
    }

    /// No catalog opened at launch: nothing may be saved, and the JSON store
    /// refuses every write (no save can create catalog.json).
    private func freezeLaunchWithoutCatalog() {
        updateReadOnlyFacts {
            $0.jsonFrozenByLaunch = true
            $0.sessionReadOnlyByLaunch = true
        }
    }

    private func loadJSONReadOnly(_ why: String) -> [VideoRecord] {
        let records = catalogStore.load()
        updateReadOnlyFacts {
            $0.jsonFrozenByLaunch = true
            $0.sessionReadOnlyByLaunch = true
        }
        catalogAuthorityNote("OUTCOME " + CatalogAuthority.readOnlyWords(why))
        return records
    }

    /// The one sink: console + catalog.log, videoscan.log, the unified log.
    func catalogAuthorityNote(_ line: String) {
        log("Catalog store: " + line)
        appLog.write("[catalog-store] " + line)
        flipLog.notice("\(line, privacy: .public)")
    }
}
