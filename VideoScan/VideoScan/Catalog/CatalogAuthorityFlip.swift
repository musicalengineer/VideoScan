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
// Nothing in this batch writes the latch; nothing here writes catalog.json.
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
    /// Written ONLY by the explicit "Switch to SQLite" door (a later batch).
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
    /// catalog READ-ONLY with the words.
    private func loadFromSQLite(_ url: URL) -> [VideoRecord] {
        let read: Result<CatalogLoad.Snapshot, CatalogLoad.Failure> = CatalogLaunchWait.run {
            let repository = GRDBCatalogRepository()
            if case .refused(let reason) = await repository.open(at: url) {
                await repository.close()
                return .failure(.readFailed("\(CatalogAuthority.databaseFileName) would not open: \(reason)"))
            }
            do {
                let snapshot = try await CatalogLoad.read(repository)
                await repository.close()
                return .success(snapshot)
            } catch let failure as CatalogLoad.Failure {
                await repository.close()
                return .failure(failure)
            } catch {
                await repository.close()
                return .failure(.readFailed(String(describing: error)))
            }
        }
        switch read {
        case .failure(let failure):
            return loadJSONReadOnly(failure.words)
        case .success(let snapshot):
            do {
                let result = try SQLiteCatalogLoader.build(snapshot)
                adoptSQLiteAuthority()
                catalogAuthorityNote("OUTCOME loaded \(result.summary)")
                return result.records
            } catch {
                return loadJSONReadOnly("a row could not become a record: \(error)")
            }
        }
    }

    /// SQLite is the authority: catalog.json is read for the Master Archive
    /// designation it still carries (it moves into the store with the write
    /// side, B2) and is never written again. Until the write side lands the
    /// session saves nothing, and says so — which is why only B2's "Switch to
    /// SQLite" door may write the latch.
    private func adoptSQLiteAuthority() {
        _ = catalogStore.load()
        catalogStore.isReadOnly = true
        isReadOnly = true
        catalogAuthorityNote("catalog.json is frozen (read-only); edits are not saved until the SQLite write side is installed")
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
