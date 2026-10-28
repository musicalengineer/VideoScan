// CatalogDiskFullTests.swift
// The disk fills while a commit runs (2026-10-18). catalog.sqlite lives on
// a small throwaway disk image (hdiutil, mounted under the test's temp
// folder, never browsable), a ballast file eats the free space, and the
// app's commit path (CatalogCommit through GRDBCatalogRepository, production
// durability) is asked to write every record. Dimensions:
//   TRUTH      the commit is REFUSED — never .committed — with words that
//              name the disk; the database still holds the old state and the
//              old generation; integrity_check is ok.
//   RETRY      the edits the caller still holds (the app keeps its records
//              in memory; a refused commit leaves its baseline unadvanced)
//              commit once space is back, and a reload shows them: nothing
//              lost. Two depths of full are tried, because WHERE the write
//              fails decides what the store must do:
//                - full: the high-water's temp file cannot be created, so
//                  phase 1 refuses before COMMIT;
//                - nearly full: phase 1 fits but the WAL frames do not, so
//                  SQLite says SQLITE_FULL at COMMIT, after the high-water
//                  was raised.
//   ISOLATION  the image is created, attached and detached by the test; the
//              catalog never touches a real volume.
//   MEDIA      N/A.
//
// For Rick: hdiutil is the same tool Disk Utility uses; `-nobrowse` keeps the
// volume out of Finder. ENOSPC is errno 28; SQLITE_FULL is result code 13.

import Foundation
import GRDB
import Testing
@testable import VideoScanCore

@Suite("Catalog disk full — the commit refuses cleanly, the edits are retained and land on retry", .serialized)
struct CatalogDiskFullTests {

    enum Depth: String, CaseIterable, Sendable, CustomStringConvertible {
        /// No free block at all.
        case full
        /// About 48 KB free: room for the high-water files, not for the WAL.
        case nearlyFull
        var description: String { rawValue }
        var leaveFreeBytes: Int { self == .full ? 0 : 48 * 1024 }
    }

    @Test("a commit on a full disk is refused with the disk's words; the old state stays; the same edits land after space returns",
          .timeLimit(.minutes(3)), arguments: Depth.allCases)
    func diskFullCommitRefusesAndRetries(_ depth: Depth) async throws {
        let scene = try ImporterScene.make(healthyRows: 200)
        defer { scene.remove() }
        let imported = await scene.run()
        _ = try #require(imported.outcome.reconciliation, Comment(rawValue: "\(imported.outcome)"))

        let volume = try DiskImageVolume.attach(megabytes: 32, under: scene.directory)
        defer { volume.detach() }
        let database = try volume.copyCatalog(from: scene.databaseFolder)

        // 1. A healthy commit on the image: the baseline every check compares with.
        var session = try await CommitSession.open(database)
        _ = try await session.commitNotes("before-full")
        let before = await session.generation
        let noted = try Self.noteCount(database, "before-full")
        try #require(noted > 0, "the baseline commit stored no notes")

        // 2. Fill the disk, edit, commit.
        let ballast = try volume.fill(leavingFree: depth.leaveFreeBytes)
        let refused = await session.commitNotesOutcome("during-full")
        guard case .refused(let words, _) = refused else {
            Issue.record("\(depth): a commit on a full disk was not refused: \(refused)")
            return
        }
        print("[disk-full] \(depth): refused — \(words)")
        #expect(Self.namesTheDisk(words), "\(depth): the refusal does not say the disk is full: \(words)")
        #expect(await session.generation == before, "\(depth): the session's generation moved on a refused commit")
        #expect(try Self.storedGeneration(database) == before, "\(depth): the database's generation moved")
        #expect(try Self.noteCount(database, "before-full") == noted, "\(depth): a refused commit changed what is stored")
        #expect(try Self.noteCount(database, "during-full") == 0, "\(depth): part of a refused commit is stored")

        // 3. Space comes back — the volume REPORTS it (see returnSpace). The
        //    caller still holds its edited records.
        try await volume.returnSpace(ballast)
        var retried = await session.commitNotesOutcome("during-full", reuseEdits: true)
        var reopenedAs: CatalogOpenOutcome = .readWrite
        if case .refused(let reason, _) = retried {
            // The session refuses after a failure it cannot account for; the
            // app's answer is to reopen the catalog. Say what that took.
            print("[disk-full] \(depth): retry in the same session refused — \(reason)")
            await session.close()
            session = try await CommitSession.open(database, requireReadWrite: false)
            reopenedAs = session.opened
            print("[disk-full] \(depth): reopened → \(reopenedAs)")
            if case .readOnly = reopenedAs {
                let witness = CatalogHighWater.read(besideDatabaseAt: database)
                if case .value(let mark) = witness {
                    let adopted = await session.repository.adopt(toHighWater: mark)
                    print("[disk-full] \(depth): adopt → \(adopted)")
                }
            }
            retried = await session.commitNotesOutcome("during-full", reuseEdits: false)
        }
        guard case .committed = retried else {
            Issue.record("\(depth): the edits could not be committed once space returned: \(retried)")
            await session.close()
            return
        }
        await session.close()
        #expect(try Self.noteCount(database, "during-full") == noted, "\(depth): the retried edits did not all land")
        #expect(try Self.noteCount(database, "before-full") == 0, "\(depth): old notes survived the retry")
        #expect(try CatalogHardKillTests.integrityCheck(database) == ["ok"], "\(depth)")
        // The contract this test exists to pin: a disk that filled and was
        // freed is NOT a restore. A catalog that comes back read-only and
        // asks a person to adopt "an older copy" over a full disk is wrong
        // words for what happened, even though nothing was lost.
        //
        // KNOWN (found by this test, 2026-10-18): at `.nearlyFull` phase 1
        // raises catalog.highwater(.log) to g+1, then COMMIT fails with
        // SQLITE_FULL. The session then refuses its own retry with "another
        // writer published generation g+1" and the reopen is read-only with
        // the restoredBelowHighWater "older copy" words until adopted. The
        // witnesses cannot simply be lowered (F8r3: never lowered), so the
        // fix is a design decision for the store, not a test change. When it
        // lands this known issue stops reproducing and the test fails —
        // remove the wrapper then.
        if depth == .nearlyFull {
            withKnownIssue("SQLITE_FULL at COMMIT after phase 1 leaves the catalog read-only as if restored (GRDBCatalogRepository WritePlan)") {
                #expect(reopenedAs == .readWrite,
                        "\(depth): after a disk-full refusal the catalog reopened \(reopenedAs) — a person must adopt it")
            }
        } else {
            #expect(reopenedAs == .readWrite,
                    "\(depth): after a disk-full refusal the catalog reopened \(reopenedAs) — a person must adopt it")
        }
    }

    // MARK: - Regression: the ballast must not outlive its unlink

    /// Gauntlet run 1, M5 Ultra, Release, 7370a559 (2026-10-27): `full` failed
    /// its retry with ENOSPC creating `.catalog.highwater.<uuid>.vspublish.tmp`
    /// although the ballast had been removed. Mechanism (proved with a probe):
    /// the ballast fd was opened without O_CLOEXEC, so any child process the
    /// test PROCESS spawned while the fill ran — other suites run in parallel
    /// and spawn hdiutil, ffprobe, hard-kill children — inherited it. An
    /// unlinked file whose blocks are still referenced by an open descriptor
    /// keeps them: statfs read 0 free until that child exited.
    /// C++ analogy: an fd without FD_CLOEXEC is a handle every later fork/exec
    /// copies, like a shared_ptr you did not mean to hand out.
    @Test("REGRESSION: a child process started while the ballast is written does not keep its space — removing the ballast returns the space while the child still runs",
          .timeLimit(.minutes(1)))
    func ballastIsNotInheritedByChildren() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("diskfull-inherit-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let volume = try DiskImageVolume.attach(megabytes: 32, under: folder)
        defer { volume.detach() }

        // The gauntlet's shape made explicit: a child is born while the fill's fd is open.
        var child: pid_t = 0
        let ballast = try volume.fill(leavingFree: 0, whileOpen: { child = try Self.spawnSleeper() })
        defer { Self.reap(child) }
        try #require(child > 0, "the sleeper was not spawned")
        try #require(kill(child, 0) == 0, "the sleeper exited before the check — the test would prove nothing")

        // Short deadline: the child sleeps far longer, so only a ballast it does
        // not hold can come back in time.
        try await volume.returnSpace(ballast, within: .seconds(5))
        #expect(kill(child, 0) == 0, "the space came back only because the child had exited")
    }

    /// A child that outlives every deadline in the test (reaped by `reap`).
    static func spawnSleeper() throws -> pid_t {
        let words: [String] = ["/bin/sleep", "120"]
        let argv = words.map { strdup($0) }
        defer { argv.forEach { free($0) } }
        var cArgs = argv + [nil]
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, "/bin/sleep", nil, nil, &cArgs, environ)
        guard spawned == 0 else { throw FixtureFailure(words: "posix_spawn sleep: \(String(cString: strerror(spawned)))") }
        return pid
    }

    /// Stop and reap this test's own sleeper (never another process).
    static func reap(_ pid: pid_t) {
        guard pid > 0 else { return }
        kill(pid, SIGKILL)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
    }

    /// "database or disk is full" (SQLITE_FULL) or "No space left on device" (ENOSPC).
    static func namesTheDisk(_ words: String) -> Bool {
        let lower = words.lowercased()
        return lower.contains("disk is full") || lower.contains("no space left")
            || lower.contains("sqlite_full") || lower.contains("enospc")
    }

    static func storedGeneration(_ url: URL) throws -> Int {
        try readOnly(url) { db in try Int.fetchOne(db, sql: "SELECT generation FROM generations WHERE id = 1") ?? -1 }
    }

    /// How many contents' display notes (`user_notes.text`) read `note`.
    static func noteCount(_ url: URL, _ note: String) throws -> Int {
        try readOnly(url) { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM user_notes WHERE text = ?", arguments: [note]) ?? 0
        }
    }

    static func readOnly<T>(_ url: URL, _ body: (Database) throws -> T) throws -> T {
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        defer { try? queue.close() }
        return try queue.read(body)
    }
}

// MARK: - One app-like session: records in memory, commits through CatalogCommit

struct CommitSession {
    let repository: GRDBCatalogRepository
    let opened: CatalogOpenOutcome
    let records: [VideoRecord]

    static func open(_ url: URL, requireReadWrite: Bool = true) async throws -> CommitSession {
        let repository = GRDBCatalogRepository(host: "disk-full-test", durability: .archival)
        let opened = await repository.open(at: url)
        if case .refused(let reason) = opened { throw FixtureFailure(words: "open refused: \(reason)") }
        if requireReadWrite && opened != .readWrite {
            await repository.close()
            throw FixtureFailure(words: "open: \(opened)")
        }
        let snapshot = try await CatalogLoad.read(repository)
        return CommitSession(repository: repository, opened: opened,
                             records: try snapshot.rows.map { try VideoRecord(loaded: $0) })
    }

    var generation: Int { get async { await repository.generation } }

    func commitNotes(_ note: String) async throws -> Int {
        let outcome = await commitNotesOutcome(note)
        guard case .committed(let generation, _) = outcome else { throw FixtureFailure(words: "commit: \(outcome)") }
        return generation
    }

    /// Set every record's notes (unless `reuseEdits`: the records already
    /// hold them — the retry after a refusal) and commit them all at once.
    func commitNotesOutcome(_ note: String, reuseEdits: Bool = false) async -> CatalogCommit.Outcome {
        if !reuseEdits { for record in records { record.userNotes = note } }
        let items = records.map { record -> CatalogCommit.Item in
            let snapshot = VideoRecordDTO(record)
            return CatalogCommit.Item(id: record.id, snapshot: snapshot,
                                      fingerprint: CatalogChangeDetector.fingerprint(snapshot))
        }
        return await CatalogCommit.run(CatalogCommit.Plan(door: .save, items: items), on: repository)
    }

    func close() async { await repository.close() }
}

// MARK: - A throwaway volume

struct DiskImageVolume {
    let image: URL
    let mountPoint: URL

    static func attach(megabytes: Int, under folder: URL) throws -> DiskImageVolume {
        let image = folder.appendingPathComponent("diskfull-\(UUID().uuidString.prefix(8)).dmg")
        let mountPoint = folder.appendingPathComponent("diskfull-mnt-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        try run(["create", "-size", "\(megabytes)m", "-fs", "HFS+", "-volname", "VSDiskFull",
                 "-type", "UDIF", "-layout", "NONE", image.path])
        try run(["attach", "-nobrowse", "-noautoopen", "-owners", "on", "-mountpoint", mountPoint.path, image.path])
        return DiskImageVolume(image: image, mountPoint: mountPoint)
    }

    func detach() {
        _ = try? Self.run(["detach", mountPoint.path, "-force"])
    }

    /// Copy the closed catalog (database + its high-water files) onto the volume.
    func copyCatalog(from folder: URL) throws -> URL {
        let target = mountPoint.appendingPathComponent("catalog", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
            try FileManager.default.copyItem(at: folder.appendingPathComponent(name),
                                             to: target.appendingPathComponent(name))
        }
        return target.appendingPathComponent("catalog.sqlite")
    }

    /// Write a ballast file until the volume has `leavingFree` bytes or fewer left.
    /// `whileOpen` runs with the ballast's descriptor open (regression test hook).
    func fill(leavingFree: Int, whileOpen: () throws -> Void = {}) throws -> URL {
        let ballast = mountPoint.appendingPathComponent("ballast.bin")
        // O_CLOEXEC: suites run in parallel in one process and spawn children
        // (hdiutil, ffprobe, hard-kill helpers). Without it a child born during
        // the fill inherits this fd and pins the ballast's blocks after the
        // unlink — the volume stays full (gauntlet 2026-10-27).
        let fd = Darwin.open(ballast.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw FixtureFailure(words: "ballast open errno \(errno)") }
        defer { Darwin.close(fd) }
        try whileOpen()
        let chunk = [UInt8](repeating: 0xA5, count: 4096)
        while freeBytes() > leavingFree {
            let written = chunk.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, min(chunk.count, max(4096, freeBytes() - leavingFree))) }
            if written <= 0 { break }   // ENOSPC: as full as it gets
        }
        fsync(fd)
        return ballast
    }

    /// Remove the ballast and return once the volume REPORTS the space back:
    /// statfs shows at least 90 % of the ballast's bytes more than before the
    /// unlink. Polls a condition with a deadline — not a sleep standing in for
    /// one. Throws, naming the free bytes, if the deadline passes: then
    /// something still holds the unlinked file's blocks (an open descriptor).
    func returnSpace(_ ballast: URL, within deadline: Duration = .seconds(30)) async throws {
        let ballastBytes = (try FileManager.default.attributesOfItem(atPath: ballast.path)[.size] as? Int) ?? 0
        let target = freeBytes() + ballastBytes / 10 * 9
        try FileManager.default.removeItem(at: ballast)
        let clock = ContinuousClock()
        let giveUp = clock.now + deadline
        while freeBytes() < target {
            guard clock.now < giveUp else {
                throw FixtureFailure(words: "space did not return within \(deadline) of removing the \(ballastBytes)-byte ballast: "
                                     + "\(freeBytes()) B free, wanted \(target) — something still holds the unlinked ballast open")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func freeBytes() -> Int {
        var info = statfs()
        guard statfs(mountPoint.path, &info) == 0 else { return 0 }
        return Int(info.f_bavail) * Int(info.f_bsize)
    }

    @discardableResult
    static func run(_ arguments: [String]) throws -> Int32 {
        // posix_spawn + waitpid, not Foundation Process (see HardKillChild).
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        let argv = (["/usr/bin/hdiutil"] + arguments + ["-quiet"]).map { strdup($0) }
        defer { argv.forEach { free($0) } }
        var cArgs = argv + [nil]
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, "/usr/bin/hdiutil", &actions, nil, &cArgs, environ)
        guard spawned == 0 else { throw FixtureFailure(words: "posix_spawn hdiutil: \(String(cString: strerror(spawned)))") }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        let code = (status >> 8) & 0xff
        guard status & 0x7f == 0, code == 0 else {
            throw FixtureFailure(words: "hdiutil \(arguments.first ?? "") exited with status \(status)")
        }
        return code
    }
}
