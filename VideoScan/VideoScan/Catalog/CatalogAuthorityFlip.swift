// CatalogAuthorityFlip.swift
// Which catalog the app opens at launch (cutover B1, docs/design/
// catalog_cutover_f_prime_2026_10_17.md §7 "The flip").
//
// One sentence: the app reads its records from catalog.sqlite ONLY when Rick
// has switched to it (the latch file `catalog.cutover` beside the catalog),
// the database opens, and an import finished with the comparator's word;
// otherwise it reads catalog.json exactly as today.
//
// Outcomes (each one tested, CatalogAuthorityFlipTests):
//   .json          no latch → today's path, byte for byte (the database is
//                  not even opened, so an imported catalog.sqlite on Rick's
//                  Mac is inert until the later "Switch to SQLite" door);
//   .sqlite(url)   latch + the store opens (read-write, or read-only after a
//                  restore — never a fall-back to an older authority) + a
//                  finished, comparator-ok import;
//   .refused(why)  latch, but one of those is not true → the store's words,
//                  and catalog.json opens READ-ONLY (two writable
//                  authorities is the lost-update class the generation
//                  guard exists for).
// Only "Switch Catalog to SQLite…" (CatalogSwitchToSQLite.swift, B2) writes
// the latch; nothing here writes catalog.json. B2: under `.sqlite` the
// repository stays OPEN for the session and the save funnels commit
// through it (CatalogCommitter); the Master Archive designation is read
// from `catalog_state` (catalog.json's only while the store has none yet —
// the first commit moves it in).
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
    case json
    case sqlite(URL)
    case refused(String)

    static let databaseFileName = CatalogImporter.Inputs.databaseFileName
    /// Written ONLY by the explicit "Switch Catalog to SQLite…" door (B2).
    static let latchFileName = "catalog.cutover"

    /// The launch rule. Reads; writes nothing but what `open` itself does
    /// to an existing database (its schema check and high-water witness).
    static func decide(folder: URL) async -> CatalogAuthority {
        let latch = folder.appendingPathComponent(latchFileName)
        guard FileManager.default.fileExists(atPath: latch.path) else { return .json }
        let db = folder.appendingPathComponent(databaseFileName)
        guard FileManager.default.fileExists(atPath: db.path) else {
            return .refused("the catalog was switched to SQLite (\(latchFileName)) but \(databaseFileName) is not beside it")
        }
        let repository = GRDBCatalogRepository()
        if case .refused(let reason) = await repository.open(at: db) {
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
            return .refused("\(databaseFileName) holds no finished import checked by the comparator — run Import to SQLite again")
        }
        return .sqlite(db)
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

    static func read(_ url: URL) async -> Result<SQLiteLaunchRead, CatalogLoad.Failure> {
        let repository = GRDBCatalogRepository()
        let opened = await repository.open(at: url)
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

    /// What `init` restores. `.json` is `catalogStore.load()` unchanged.
    func loadCatalogAtLaunch() -> [VideoRecord] {
        // Test hosts on the shared store: today's path (it loads nothing),
        // and never a look at the real Application Support folder.
        if Self.isRunningTests && catalogStore === CatalogStore.shared { return catalogStore.load() }
        let folder = URL(fileURLWithPath: catalogStore.fileLocation).deletingLastPathComponent()
        let authority = CatalogLaunchWait.run { await CatalogAuthority.decide(folder: folder) }
        switch authority {
        case .json:
            return catalogStore.load()
        case .sqlite(let url):
            return loadFromSQLite(url)
        case .refused(let why):
            return loadJSONReadOnly(why)
        }
    }

    /// The records from catalog.sqlite; any failure falls to the JSON
    /// catalog READ-ONLY with the words. On success the repository stays
    /// open: it is the committer's for the session.
    private func loadFromSQLite(_ url: URL) -> [VideoRecord] {
        let read: Result<SQLiteLaunchRead, CatalogLoad.Failure> = CatalogLaunchWait.run { await SQLiteLaunchRead.read(url) }
        switch read {
        case .failure(let failure):
            return loadJSONReadOnly(failure.words)
        case .success(let launch):
            do {
                let result = try SQLiteCatalogLoader.build(launch.snapshot)
                adoptSQLiteAuthority(launch, url: url, records: result.records)
                catalogAuthorityNote("OUTCOME loaded \(result.summary)")
                return result.records
            } catch {
                CatalogLaunchWait.run { await launch.repository.close() }
                return loadJSONReadOnly("a row could not become a record: \(error)")
            }
        }
    }

    /// SQLite is the authority: catalog.json is frozen (read-only, never
    /// written again); the save funnels commit through `CatalogCommitter`
    /// into the open repository. The designation comes from catalog_state;
    /// while the store has none, catalog.json's is kept and the first commit
    /// moves it in. The baseline is taken NOW, before the launch-time
    /// migrations run, and one commit is scheduled so what they change lands.
    private func adoptSQLiteAuthority(_ launch: SQLiteLaunchRead, url: URL, records: [VideoRecord]) {
        _ = catalogStore.load()
        catalogStore.isReadOnly = true
        if let stored = CatalogCommitter.designation(fromJSON: launch.designationJSON) {
            catalogStore.masterArchive = stored
        }
        let committer = CatalogCommitter(repository: launch.repository, storedDesignationJSON: launch.designationJSON,
                                         input: { [weak self] in self?.catalogCommitInput() ?? CatalogCommitter.Input(
                                             records: [], designation: nil, clearAuthorized: false, holdReason: nil) },
                                         sink: { [weak self] line in self?.catalogAuthorityNote(line) })
        committer.adoptBaseline(records)
        committer.onCopiesUpdated = { [weak self] in self?.noteCatalogMutated() }
        if case .readOnly(let reason) = launch.opened {
            committer.block("read-only: \(reason)")
            isReadOnly = true
            catalogAuthorityNote("catalog.sqlite opened READ-ONLY — \(reason). Nothing will be saved this session.")
        } else {
            isReadOnly = false
            committer.scheduleCommit()
            catalogAuthorityNote("catalog.json is frozen (read-only); every save now commits to \(url.lastPathComponent)")
        }
        catalogCutover.install(committer, databaseURL: url)
    }

    /// What the committer reads at the moment of a commit.
    func catalogCommitInput() -> CatalogCommitter.Input {
        CatalogCommitter.Input(records: records, designation: masterArchive,
                               clearAuthorized: catalogStore.designationClearAuthorized, holdReason: catalogStore.writeHold)
    }

    private func loadJSONReadOnly(_ why: String) -> [VideoRecord] {
        let records = catalogStore.load()
        catalogStore.isReadOnly = true
        isReadOnly = true
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
