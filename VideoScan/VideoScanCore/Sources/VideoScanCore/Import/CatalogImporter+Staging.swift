// CatalogImporter+Staging.swift
// Codex 2026-10-17 P1 (docs/reviews/codex/codex-review-import-quit-path-hold-drain-2026-10-17.md):
// "force-release is not a rollback or COMMIT fence". The fence, by
// construction: a COMMIT run never writes `catalog.sqlite`. It writes a
// STAGING set in its own folder beside the target —
//     <folder>/catalog.sqlite.importing-<runID>/
//         catalog.sqlite  catalog.sqlite-wal  catalog.sqlite-shm
//         catalog.highwater  catalog.highwater.log
// — and PUBLISHES it onto <folder> only when the run is `.imported`, the
// repository is CLOSED, the staged set reopens `.readWrite` and verifies
// ok, and the publish permit (the app's Stop flag) says yes. Anything else —
// stopped, rolled back, refused, failed, a quit that gave up waiting, a
// process that died — leaves only the staging folder; catalog.sqlite never
// appears. The next import moves leftovers aside (MOVE, never delete) into
// one dated folder before it starts.
//
// Why a FOLDER, not a sibling file `catalog.sqlite.importing-<runID>`: the
// two high-water witnesses are named by FOLDER (`CatalogHighWater.url(
// besideDatabaseAt:)` = the database's folder + a fixed name), so a staged
// database in the same folder would raise — and on a stopped run, leave
// raised — the target's own witnesses. A staging folder gives the staged
// database witnesses of its own without any change to Store/. Same volume,
// so every move is one rename(2).
//
// Publish order (and why): the companions first — catalog.highwater,
// catalog.highwater.log, catalog.sqlite-wal, catalog.sqlite-shm — and the
// DATABASE LAST. `catalog.sqlite` existing is the one signal everything
// keys on (the app's pre-flight, CatalogAuthorityFlip, the next import's
// refusal), so the moment it appears the whole set is already beside it. A
// crash between the renames leaves companions beside NO database — orphans
// the next import recognises (no catalog.sqlite) and moves aside. Every
// rename is RENAME_EXCL (never replaces), and all five target names are
// checked absent before the first one (refuse before mutating).
//
// The WAL travels WITH the database (measured 2026-10-17: after the
// repository's close, a 3-row import is a 4 KB catalog.sqlite + a 745 KB
// catalog.sqlite-wal). GRDB's DatabasePool.close closes the writer before
// its read-only readers, so no connection is ever "last and writable" and
// SQLite never folds the WAL in on close. Database + WAL is the consistent
// pair once every connection is closed; -shm is a rebuildable index (the
// first opener re-initialises it). Folding the WAL in at close is a Store/
// change and is recommended separately.
//
// (For Rick: think of a two-phase install — build the whole tree in a temp
// directory on the same disk, then rename(2) it into place, last file
// being the one readers look for; a Stop that arrives first means the
// install never happens.)

import Darwin
import Foundation

enum ImportStaging {

    static let stagingPrefix = "catalog.sqlite.importing-"
    static let asidePrefix = "catalog.sqlite.import-aside-"

    /// The staged database for `runID`: `<folder>/catalog.sqlite.importing-<runID>/catalog.sqlite`.
    static func database(target: URL, runID: String) -> URL {
        target.deletingLastPathComponent()
            .appendingPathComponent(stagingPrefix + runID, isDirectory: true)
            .appendingPathComponent(target.lastPathComponent)
    }

    /// The names one published set occupies, in publish order: the
    /// companions first, the database LAST.
    static func setNames(database name: String) -> [String] {
        [CatalogHighWater.fileName, CatalogHighWaterLedger.fileName, name + "-wal", name + "-shm", name]
    }

    /// Names that must be in a staged set before it may publish.
    static func requiredNames(database name: String) -> [String] {
        [CatalogHighWater.fileName, CatalogHighWaterLedger.fileName, name]
    }

    struct Failure: Error {
        let words: String
    }

    // MARK: - Before the run (commit mode)

    /// Commit mode, before the staged store opens: an existing target
    /// refuses (non-empty → `targetNotEmpty`; empty → words), leftovers are
    /// moved aside, the staging folder is made. nil = go on.
    static func prepare(target: URL, staging: URL, repository: any CatalogRepository,
                        sink: CatalogImporter.Sink) async -> CatalogImporter.Outcome? {
        if FileManager.default.fileExists(atPath: target.path) {
            return await existingTargetOutcome(target, repository: repository)
        }
        do {
            let moved = try moveLeftoversAside(besideTarget: target, now: Date())
            if let line = moved { sink(line) }
            try FileManager.default.createDirectory(at: staging.deletingLastPathComponent(), withIntermediateDirectories: false)
        } catch let failure as Failure {
            return .failed(failure.words)
        } catch {
            return .failed("the target folder \(target.deletingLastPathComponent().path) could not take the staging folder: "
                + error.localizedDescription)
        }
        return nil
    }

    /// The target is already there: say what it holds; never touch it.
    private static func existingTargetOutcome(_ target: URL, repository: any CatalogRepository) async -> CatalogImporter.Outcome {
        let name = target.lastPathComponent
        guard await repository.open(at: target) == .readWrite else {
            return .failed("\(name) already exists beside the catalog and does not open for writing — move it aside first; nothing was written")
        }
        let counts = try? await repository.read { try $0.recordCounts() }
        await repository.close()
        if let counts, !counts.isEmpty { return .refused([.targetNotEmpty(counts)]) }
        return .failed("\(name) already exists beside the catalog (empty) — move it aside first; nothing was written")
    }

    /// Leftovers of earlier runs: every `catalog.sqlite.importing-*` entry,
    /// and — only when no database is beside them — the companions of an
    /// interrupted publish. All MOVED (RENAME_EXCL) into ONE new dated
    /// folder; nothing is deleted. Returns the sink line, or nil when there
    /// was nothing to move.
    static func moveLeftoversAside(besideTarget target: URL, now: Date) throws -> String? {
        let folder = target.deletingLastPathComponent()
        let names = try leftoverNames(in: folder, database: target.lastPathComponent)
        guard !names.isEmpty else { return nil }
        let aside = try makeAsideFolder(in: folder, now: now)
        for name in names {
            try renameExclusive(folder.appendingPathComponent(name), to: aside.appendingPathComponent(name))
        }
        return "moved aside \(names.count) leftover(s) of an earlier import into \(aside.lastPathComponent): "
            + names.joined(separator: ", ") + " — kept, nothing deleted"
    }

    private static func leftoverNames(in folder: URL, database: String) throws -> [String] {
        let entries: [String]
        do {
            entries = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        } catch {
            throw Failure(words: "the target folder \(folder.path) could not be listed: \(error.localizedDescription)")
        }
        let staged = entries.filter { $0.hasPrefix(stagingPrefix) }
        let orphans = setNames(database: database).dropLast().filter { entries.contains($0) }
        return (staged + orphans).sorted()
    }

    private static func makeAsideFolder(in folder: URL, now: Date) throws -> URL {
        let stamp = Self.stamp(now)
        for attempt in 0..<100 {
            let name = asidePrefix + stamp + (attempt == 0 ? "" : "-\(attempt + 1)")
            let url = folder.appendingPathComponent(name, isDirectory: true)
            if Darwin.mkdir(url.path, 0o755) == 0 { return url }
            guard errno == EEXIST else {
                throw Failure(words: "the aside folder \(name) could not be made: \(String(cString: strerror(errno)))")
            }
        }
        throw Failure(words: "no free aside folder name for \(stamp)")
    }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    // MARK: - After the run (commit mode)

    /// The run is over and the repository is closed. `.imported` publishes
    /// (verified, permitted) or becomes `.stopped` / `.failed`; every other
    /// outcome leaves the staging folder as it is.
    static func land(_ outcome: CatalogImporter.Outcome, staging: URL, target: URL, repository: any CatalogRepository,
                     permit: CatalogImporter.PublishPermit, sink: CatalogImporter.Sink) async -> CatalogImporter.Outcome {
        let folder = staging.deletingLastPathComponent()
        guard case .imported = outcome else {
            sink("the staged database at \(folder.lastPathComponent) was not published (\(Self.kind(outcome))); "
                + "\(target.lastPathComponent) untouched; the next import moves it aside")
            return outcome
        }
        if let problem = await verifyStaged(staging, repository: repository) {
            sink("the staged database at \(folder.path) was NOT published: \(problem); kept for a person to look at")
            return .failed("the staged import did not verify (\(problem)) — \(target.lastPathComponent) untouched; staging kept at \(folder.path)")
        }
        guard permit() else {
            sink("Stop arrived after the commit — the staged database at \(folder.lastPathComponent) was NOT published; "
                + "\(target.lastPathComponent) untouched; the next import moves it aside")
            return .stopped
        }
        do {
            try publish(staging: staging, target: target)
        } catch let failure as Failure {
            sink("publish FAILED: \(failure.words)")
            return .failed(failure.words)
        } catch {
            return .failed("publish failed: \(error.localizedDescription)")
        }
        sink("published \(setNames(database: target.lastPathComponent).joined(separator: ", ")) from \(folder.lastPathComponent) "
            + "into \(target.deletingLastPathComponent().path) (the database last)")
        return outcome
    }

    private static func kind(_ outcome: CatalogImporter.Outcome) -> String {
        switch outcome {
        case .imported: return "imported"
        case .dryRunPassed: return "dry run"
        case .refused: return "refused"
        case .rolledBack: return "rolled back"
        case .stopped: return "stopped"
        case .failed: return "failed"
        }
    }

    /// The staged set must reopen `.readWrite` and verify ok before it may
    /// become the catalog's database. nil = good.
    private static func verifyStaged(_ staging: URL, repository: any CatalogRepository) async -> String? {
        let opened = await repository.open(at: staging)
        guard opened == .readWrite else {
            await repository.close()
            return "it reopened \(opened), not read-write"
        }
        let verified = await repository.verify()
        await repository.close()
        if case .problems(let problems) = verified { return problems.joined(separator: " · ") }
        return nil
    }

    /// Refuse before mutating (every target name absent, every required
    /// staged name present), then RENAME_EXCL each staged file into the
    /// target folder — the database LAST — and sync the folder. A rename
    /// that fails puts back what already moved; if even that fails the
    /// words name where every file is.
    static func publish(staging: URL, target: URL) throws {
        let from = staging.deletingLastPathComponent()
        let into = target.deletingLastPathComponent()
        let database = target.lastPathComponent
        let fm = FileManager.default
        if let present = setNames(database: database).first(where: { fm.fileExists(atPath: into.appendingPathComponent($0).path) }) {
            throw Failure(words: "\(present) is already beside the catalog — nothing was published; staging kept at \(from.path)")
        }
        if let missing = requiredNames(database: database).first(where: { !fm.fileExists(atPath: from.appendingPathComponent($0).path) }) {
            throw Failure(words: "the staged set has no \(missing) — nothing was published; staging kept at \(from.path)")
        }
        let names = setNames(database: database).filter { fm.fileExists(atPath: from.appendingPathComponent($0).path) }
        var moved: [String] = []
        for name in names {
            do {
                try renameExclusive(from.appendingPathComponent(name), to: into.appendingPathComponent(name))
                moved.append(name)
            } catch let failure as Failure {
                throw Failure(words: failure.words + " — " + putBack(moved, from: into, to: from))
            }
        }
        syncDirectory(into)
        _ = Darwin.rmdir(from.path)                   // only ever removes an EMPTY folder; a leftover is swept next time
    }

    /// Undo a partial publish: move `names` back into staging (no-clobber).
    private static func putBack(_ names: [String], from: URL, to: URL) -> String {
        guard !names.isEmpty else { return "nothing had moved; staging kept at \(to.path)" }
        var stuck: [String] = []
        for name in names.reversed() {
            do {
                try renameExclusive(from.appendingPathComponent(name), to: to.appendingPathComponent(name))
            } catch {
                stuck.append(name)
            }
        }
        if stuck.isEmpty { return "\(names.joined(separator: ", ")) put back; staging kept whole at \(to.path)" }
        return "MIXED STATE: \(stuck.joined(separator: ", ")) are in \(from.path) with no database beside them; "
            + "the rest are in \(to.path) — the next import moves them aside"
    }

    /// rename(2) that never replaces (RENAME_EXCL).
    static func renameExclusive(_ source: URL, to destination: URL) throws {
        guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw Failure(words: "\(source.lastPathComponent) could not be moved to \(destination.path): \(String(cString: strerror(errno)))")
        }
    }

    /// Make the renames themselves durable (the directory entries).
    private static func syncDirectory(_ url: URL) {
        let fd = Darwin.open(url.path, O_RDONLY)
        guard fd >= 0 else { return }
        if fcntl(fd, F_FULLFSYNC) != 0 { fsync(fd) }
        Darwin.close(fd)
    }
}
