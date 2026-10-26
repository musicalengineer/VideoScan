// CatalogAuthorityFlip.swift
// Which catalog the app opens at launch (cutover B1, docs/design/
// catalog_cutover_f_prime_2026_10_17.md §7 "The flip").
//
// One sentence: the app reads its records from catalog.sqlite ONLY when Rick
// has switched to it (the latch file `catalog.cutover` beside the catalog),
// the database opens, and an import finished with the comparator's word.
//
// Outcomes (each one tested, CatalogAuthorityFlipTests):
//   .noLatch       no latch → the launch REFUSES, loudly (Rick 2026-10-21,
//                  GH #354: no JSON fallback for old catalogs). catalog.json
//                  is never opened — not writable, not read-only; the
//                  session starts empty and read-only, and the words say the
//                  master (or migrate_data.sh) must carry catalog.sqlite and
//                  its latch. The database is not opened either. (A test
//                  host on the shared store keeps its own path: it loads
//                  nothing.)
//   .sqlite(url)   latch + the store opens (read-write, or read-only after a
//                  restore — never a fall-back to an older authority) + a
//                  finished, comparator-ok import;
//   .refused(why)  latch, but one of those is not true → the store's words;
//                  the launch refuses the same way: empty, read-only,
//                  catalog.json never opened (QA r1 F1, 2026-10-21 — it used
//                  to open catalog.json read-only, and that load rotated
//                  catalog.json.prev and wrote the generation sidecar).
//
// A VIEWER never runs `decide` (QA r1 F2, 2026-10-21): it never opens its own
// top-level catalog.sqlite. Its only catalog is the master's synced snapshot
// in viewer-catalog/ (CatalogViewerSnapshot): with that snapshot's latch the
// launch is empty and read-only with no refusal line and CatalogSync's
// refreshViewerCatalog shows the snapshot; without it the words say
// "nothing synced from the master yet". No committer is installed on a
// viewer (VideoScanModel+ViewerCatalog.swift's header).
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
        readOnly ? await repository.openReadOnly(at: url, reason: viewerReadOnlyWords) : await repository.open(at: url, requiringLatch: true)
    }

    /// The words a launch with no latch shows (GH #354), in the one sink.
    static func noLatchWords(folder: URL) -> String {
        GRDBCatalogRepository.noLatchWords(folder: folder)    // one place: the store refuses an open with these too (#359 D)
    }

    /// A viewer with no synced snapshot latch in viewer-catalog/.
    static func viewerNothingSyncedWords(folder: URL) -> String {
        "viewer: nothing synced from the master yet — no \(latchFileName) in "
            + "\(folder.appendingPathComponent(CatalogViewerSnapshot.directoryName).path). catalog.json is not opened; "
            + "the catalog appears read-only after the first sync from the master."
    }

    /// The words a refused launch shows (console, catalog.log, videoscan.log).
    static func readOnlyWords(_ why: String) -> String {
        "SQLite catalog refused — \(why). No catalog is open (catalog.json is not opened): nothing will be saved this session."
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
        // The role is known BEFORE anything opens (codex cycle #112). A viewer
        // never opens its own catalog.sqlite (QA r1 F2): its catalog is the
        // synced snapshot, shown by CatalogSync.
        if launchesAsViewer() {
            updateReadOnlyFacts { $0.viewerRole = true }
            return viewerLaunch(folder)
        }
        let authority = CatalogLaunchWait.run { await CatalogAuthority.decide(folder: folder) }
        switch authority {
        case .noLatch:
            return refuseLaunchWithoutLatch(folder)
        case .sqlite(let url):
            return loadFromSQLite(url)
        case .refused(let why):
            return refuseSQLiteLaunch(why)
        }
    }

    /// Is this launch a viewer's? Production: CatalogSync's hostname rule.
    /// Test hosts: the role fact a test applied before launching, so a test
    /// run on a viewer laptop (M5 / M1) behaves like one on the master.
    private func launchesAsViewer() -> Bool {
        if Self.isRunningTests { return readOnlyFacts.viewerRole }
        return CatalogSync.launchMode() == .viewer
    }

    /// The records from catalog.sqlite; any failure refuses the launch with
    /// the words (never catalog.json). On success the repository stays
    /// open: it is the committer's for the session. Only a master gets here.
    private func loadFromSQLite(_ url: URL) -> [VideoRecord] {
        let read: Result<SQLiteLaunchRead, CatalogLoad.Failure> = CatalogLaunchWait.run { await SQLiteLaunchRead.read(url) }
        switch read {
        case .failure(let failure):
            return refuseSQLiteLaunch(failure.words)
        case .success(let launch):
            do {
                let result = try SQLiteCatalogLoader.build(launch.snapshot)
                adoptSQLiteAuthority(launch, url: url, records: result.records, held: result.heldIDs)
                catalogAuthorityNote("OUTCOME loaded \(result.summary)")
                return result.records
            } catch {
                CatalogLaunchWait.run { await launch.repository.close() }
                return refuseSQLiteLaunch("a row could not become a record: \(error)")
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
        } else {
            // QA r1 F4: visible, never silent (catalog.json's is never used — GH #353).
            catalogAuthorityNote("catalog.sqlite carries no Master Archive designation — none is set this session; "
                                 + "designate it on the Archive tab if this Mac should have one")
        }
        let committer = CatalogCommitter(repository: launch.repository, storedDesignationJSON: launch.designationJSON,
                                         input: { [weak self] in self?.catalogCommitInput() ?? CatalogCommitter.Input(
                                             records: [], designation: nil, clearAuthorized: false, holdReason: nil, holdOwner: nil) },
                                         sink: { [weak self] line in self?.catalogAuthorityNote(line) })
        committer.adoptBaseline(records, held: held, generation: launch.snapshot.generation)
        committer.onCopiesUpdated = { [weak self] in self?.noteCatalogMutated() }
        committer.onRecordsReconciled = { [weak self] fresh in self?.showReconciledRecords(fresh) }   // codex #141 F2
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

    /// Codex #141 F2: Catalog ▸ Reopen rebuilt these records from a catalog
    /// another writer changed — each takes the place of the record with its
    /// id. The array is swapped ONCE (one `didSet`: the indexes un-latch, the
    /// counts and snapshots follow), then every `pairedWith` that pointed at
    /// a replaced instance is re-pointed to the one now in the array. The old
    /// instances are detached: the marker veto's `owns` says no to them.
    /// (For Rick: the same `records[i] = decoded` swap a rescan does; a
    /// pointer fix-up pass after it.)
    func showReconciledRecords(_ fresh: [VideoRecord]) {
        guard !fresh.isEmpty else { return }
        let byID = Dictionary(fresh.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var replaced: [ObjectIdentifier: VideoRecord] = [:]
        var next = records
        for index in next.indices {
            guard let replacement = byID[next[index].id] else { continue }
            replaced[ObjectIdentifier(next[index])] = replacement
            next[index] = replacement
        }
        for record in next {
            if let partner = record.pairedWith, let moved = replaced[ObjectIdentifier(partner)] { record.pairedWith = moved }
        }
        records = next
    }

    /// The catalog's generation for a synchronous stamp: catalog.sqlite's as
    /// this session knows it when a committer is installed (QA r1 F3),
    /// else the JSON store's (a test sandbox that never ran the launch).
    var catalogGenerationForStamp: Int {
        catalogCutover.committer?.knownGeneration ?? catalogStore.currentGeneration
    }

    /// The same, read from catalog.sqlite itself when a committer is
    /// installed (the audit marker's stamp, QA r1 F3).
    func catalogGenerationNow() async -> Int {
        guard let committer = catalogCutover.committer else { return catalogStore.currentGeneration }
        return await committer.generationNow()
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
        let words = CatalogAuthority.noLatchWords(folder: folder)
        freezeLaunchWithoutCatalog(words)
        catalogAuthorityNote("OUTCOME " + words)
        return []
    }

    /// A viewer's launch: its authority is the synced copy
    /// (viewer-catalog/catalog.sqlite + viewer-catalog/catalog.cutover); its
    /// own top-level catalog.sqlite and latch are never looked at (QA r1 F2).
    /// Present → no refusal; the launch is empty and read-only and CatalogSync
    /// shows the snapshot. Absent → "nothing synced from the master yet".
    /// catalog.json is never opened on either branch.
    private func viewerLaunch(_ folder: URL) -> [VideoRecord] {
        freezeLaunchWithoutCatalog(nil)
        if FileManager.default.fileExists(atPath: CatalogViewerSnapshot.latchURL(in: folder).path) { return [] }
        catalogAuthorityNote("OUTCOME " + CatalogAuthority.viewerNothingSyncedWords(folder: folder))
        return []
    }

    /// No catalog opened at launch: nothing may be saved, and the JSON store
    /// refuses every write (no save can create catalog.json).
    private func freezeLaunchWithoutCatalog(_ words: String?) {
        updateReadOnlyFacts {
            $0.jsonFrozenByLaunch = true
            $0.sessionReadOnlyByLaunch = true
            $0.launchRefusalWords = words
        }
    }

    /// Why a door that needs the catalog cannot run in this session — nil
    /// when catalog.sqlite is open (a committer is installed) or when this
    /// is a test sandbox that never ran the launch (QA r1 F5).
    var catalogUnavailableWords: String? {
        guard catalogCutover.committer == nil else { return nil }
        if readOnlyFacts.viewerRole { return "this Mac is a viewer — validate on the master" }
        return readOnlyFacts.launchRefusalWords
    }

    /// A master whose catalog.sqlite was refused (QA r1 F1): no catalog is
    /// opened — catalog.json neither read nor written — the session is empty
    /// and read-only, and the words say why SQLite refused.
    private func refuseSQLiteLaunch(_ why: String) -> [VideoRecord] {
        let words = CatalogAuthority.readOnlyWords(why)
        freezeLaunchWithoutCatalog(words)
        catalogAuthorityNote("OUTCOME " + words)
        return []
    }

    /// The one sink: console + catalog.log, videoscan.log, the unified log.
    func catalogAuthorityNote(_ line: String) {
        log("Catalog store: " + line)
        appLog.write("[catalog-store] " + line)
        flipLog.notice("\(line, privacy: .public)")
    }
}
