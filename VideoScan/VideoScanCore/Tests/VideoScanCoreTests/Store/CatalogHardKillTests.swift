// CatalogHardKillTests.swift
// A REAL crash, not a simulated one (2026-10-18). The store's own crash
// tests throw from `injectCrashBeforeCommit`, which rolls back inside one
// living process by construction. Here a second process — the test-only
// `catalog-crash-helper` executable — opens catalog.sqlite through the real
// GRDBCatalogRepository with the PRODUCTION durability and commits every
// record in a loop through CatalogCommit (the app's commit path); this test
// SIGKILLs it at a random moment and then reopens the file through the real
// open path. Dimensions:
//   TRUTH      after every kill: the catalog opens (read-write, or read-only
//              with the restoredBelowHighWater words — never refused, never
//              corrupt); integrity_check is ok; the generation is the last
//              one the child reported committed or the one after it (never
//              lower: a reported commit is durable); EVERY record's notes
//              say the same generation, the newest committed save — the old
//              state or the new one, never a mix; the high-water sidecar and
//              its log agree with the generation (equal when read-write; one
//              above when a kill fell between phase 1 and COMMIT, which is
//              exactly the read-only case, and adopting it restores writes).
//   SCALE      24 kills × a 217-record catalog, every commit rewriting all
//              of them; the whole suite is well under a minute.
//   ISOLATION  one temp folder per run; the child gets only that path.
//   MEDIA      N/A.
// The delays are drawn from a seeded generator and the seed is printed, so a
// failing run can be replayed: VIDEOSCAN_KILL_SEED=<seed> swift test --filter CatalogHardKill.
//
// For Rick: `Process` is posix_spawn with pipes; `kill(pid, SIGKILL)` is the
// same call `kill -9` makes. Swift Testing's `#expect` ≈ gtest EXPECT_*,
// `#require` ≈ ASSERT_* (stops the test).

import Foundation
import GRDB
import Testing
@testable import VideoScanCore

@Suite("Catalog hard kill — SIGKILL a committing process, reopen, prove a committed prefix", .serialized)
struct CatalogHardKillTests {

    static let kills = 24
    static let healthyRows = 200

    @Test("24 random SIGKILLs mid-commit: opens, integrity ok, old-or-new state never a mix, high-water consistent",
          .timeLimit(.minutes(5)))
    func randomKillsLeaveACommittedPrefix() async throws {
        let helper = try #require(HardKillChild.helperURL(),
                                  "catalog-crash-helper was not built beside the test bundle (swift build builds every target)")
        let scene = try ImporterScene.make(healthyRows: Self.healthyRows)
        defer { scene.remove() }
        let imported = await scene.run()
        _ = try #require(imported.outcome.reconciliation, Comment(rawValue: "\(imported.outcome)"))

        var rng = KillDelayGenerator(seed: HardKillChild.seed())
        print("[hard-kill] seed \(rng.seed) — replay with VIDEOSCAN_KILL_SEED=\(rng.seed)")
        var tally = KillTally()
        var landedPerCommit: Int?
        var notedRecords: Int?

        for kill in 1...Self.kills {
            let child = try HardKillChild.start(helper, database: scene.databaseURL,
                                                output: scene.directory.appendingPathComponent("child-\(kill).log"))
            let firstCommit = try await child.waitForFirstCommit(seconds: 60)
            if landedPerCommit == nil { landedPerCommit = firstCommit.landed }
            #expect(firstCommit.landed == landedPerCommit, "kill \(kill): every commit lands the same rows")
            let delayMilliseconds = UInt64.random(in: 0...250, using: &rng)
            try await Task.sleep(nanoseconds: delayMilliseconds * 1_000_000)
            let reported = try child.killNow()

            let verdict = try await KillVerdict.reopen(scene.databaseURL, reported: reported, kill: kill)
            tally.add(verdict.kind)
            // Every record of a content that landed shows the note (copies
            // share curated notes), so the count is fixed by the first kill
            // and may exceed the rows the commit itself reports as landed.
            if notedRecords == nil { notedRecords = verdict.notes.count }
            #expect(verdict.notes.count >= (landedPerCommit ?? 0),
                    "kill \(kill): \(verdict.notes.count) noted records, \(landedPerCommit ?? 0) landed per commit")
            #expect(verdict.notes.count == notedRecords,
                    "kill \(kill): \(verdict.notes.count) records carry a crash-gen note, \(notedRecords ?? 0) after the first kill")
            #expect(Set(verdict.notes).count == 1, "kill \(kill): a MIX of generations in one catalog: \(Set(verdict.notes).sorted())")
            #expect(verdict.notes.first == "crash-gen \(verdict.lastSave)",
                    "kill \(kill): notes say \(verdict.notes.first ?? "nothing"), the newest save is \(verdict.lastSave)")
            #expect(try Self.integrityCheck(scene.databaseURL) == ["ok"], "kill \(kill)")
        }
        print("[hard-kill] \(Self.kills) kills (\(landedPerCommit ?? 0) rows landed per commit, \(notedRecords ?? 0) records noted): \(tally)")
        #expect(tally.total == Self.kills)
    }

    /// A plain read-only connection after the store has closed: the engine's
    /// own check, separate from the one `open` runs.
    static func integrityCheck(_ url: URL) throws -> [String] {
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        defer { try? queue.close() }
        return try queue.read { db in try String.fetchAll(db, sql: "PRAGMA integrity_check") }
    }
}

// MARK: - The child process

/// One running `catalog-crash-helper commit-loop`, spawned with
/// posix_spawn and its stdout/stderr sent to a file in the scene folder.
/// (Not Foundation `Process` + `Pipe`: after a SIGKILL its readability
/// handler spins on EOF and `waitUntilExit` waits on a run loop a Swift
/// concurrency thread does not run — measured 2026-10-18, a 10-minute hang.
/// A file and `waitpid(2)` have no such corner.)
final class HardKillChild: @unchecked Sendable {
    struct Commit { let generation: Int; let landed: Int }

    let pid: pid_t
    let output: URL
    private var reaped = false

    private init(pid: pid_t, output: URL) {
        self.pid = pid
        self.output = output
    }

    /// The helper sits beside the test bundle in SwiftPM's products folder
    /// (`.build/out/Products/<Config>/` or `.build/<triple>/<config>/`).
    /// `Bundle(for:)` finds the bundle this class was loaded from — the
    /// `.xctest` — under XCTest and Swift Testing alike.
    static func helperURL() -> URL? {
        let fm = FileManager.default
        let bundles = [Bundle(for: HardKillChild.self)] + Bundle.allBundles
        for bundle in bundles where bundle.bundlePath.hasSuffix(".xctest") {
            let candidate = bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("catalog-crash-helper")
            if fm.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    static func seed() -> UInt64 {
        if let text = ProcessInfo.processInfo.environment["VIDEOSCAN_KILL_SEED"], let value = UInt64(text) { return value }
        return UInt64.random(in: 1...UInt64(UInt32.max))
    }

    static func start(_ helper: URL, database: URL, output: URL) throws -> HardKillChild {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, output.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO)
        let argv = [helper.path, "commit-loop", database.path].map { strdup($0) }
        defer { argv.forEach { free($0) } }
        var cArgs = argv + [nil]
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, helper.path, &actions, nil, &cArgs, environ)
        guard rc == 0 else { throw FixtureFailure(words: "posix_spawn: \(String(cString: strerror(rc)))") }
        return HardKillChild(pid: pid, output: output)
    }

    var lines: [String] {
        let text = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    var commits: [Commit] {
        lines.compactMap { line in
            let fields = line.split(separator: " ")
            guard fields.count == 4, fields[0] == "COMMITTED", fields[2] == "landed",
                  let generation = Int(fields[1]), let landed = Int(fields[3]) else { return nil }
            return Commit(generation: generation, landed: landed)
        }
    }

    func waitForFirstCommit(seconds: Double) async throws -> Commit {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let first = commits.first { return first }
            var status: Int32 = 0
            if waitpid(pid, &status, WNOHANG) == pid {
                reaped = true
                throw FixtureFailure(words: "the helper exited (status \(status)) before committing: \(lines.joined(separator: " | "))")
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        _ = try? killNow()
        throw FixtureFailure(words: "no commit within \(seconds) s: \(lines.joined(separator: " | "))")
    }

    /// SIGKILL, reap, and return the last generation the child reported as
    /// committed. The child must have died of the signal — an exit of its
    /// own (a refused commit) is a failure of the run, not a kill.
    func killNow() throws -> Int {
        guard !reaped else { throw FixtureFailure(words: "the helper had already exited") }
        kill(pid, SIGKILL)
        var status: Int32 = 0
        var waited: pid_t
        repeat { waited = waitpid(pid, &status, 0) } while waited == -1 && errno == EINTR
        reaped = true
        // WIFSIGNALED / WTERMSIG, spelled out (the C macros do not import).
        let signaled = (status & 0x7f) != 0 && (status & 0x7f) != 0x7f
        guard waited == pid, signaled, status & 0x7f == SIGKILL else {
            throw FixtureFailure(words: "the helper was not killed (wait \(waited), status \(status)): \(lines.suffix(3).joined(separator: " | "))")
        }
        guard let last = commits.last?.generation else { throw FixtureFailure(words: "no commit reported") }
        return last
    }
}

// MARK: - What one kill left behind

struct KillVerdict {
    enum Kind: Hashable { case oldState, newState, betweenPhases }

    let kind: Kind
    /// Every record note that starts with "crash-gen ".
    let notes: [String]
    /// The generation of the newest `save` commit in generation_history.
    let lastSave: Int

    /// Reopen through the real open path and check everything a crash may
    /// not break. Leaves the catalog closed and writable for the next child.
    static func reopen(_ url: URL, reported: Int, kill: Int) async throws -> KillVerdict {
        let repository = GRDBCatalogRepository(host: "hard-kill-test", durability: .archival)
        let opened = await repository.open(at: url)
        if case .refused(let reason) = opened {
            await repository.close()
            throw FixtureFailure(words: "kill \(kill): the catalog REFUSED to open: \(reason)")
        }
        let generation = await repository.generation
        let sidecar = CatalogHighWater.read(besideDatabaseAt: url)
        let log = CatalogHighWaterLedger.read(besideDatabaseAt: url)
        #expect(generation == reported || generation == reported + 1,
                "kill \(kill): generation \(generation) after the child reported \(reported) committed")

        let kind: Kind
        switch opened {
        case .readWrite:
            #expect(sidecar == .value(generation), "kill \(kill): read-write but \(CatalogHighWater.fileName) is \(sidecar)")
            #expect(log == .value(generation), "kill \(kill): read-write but \(CatalogHighWaterLedger.fileName) is \(log)")
            kind = generation == reported ? .oldState : .newState
        case .readOnly(let reason):
            #expect(reason.hasPrefix("restoredBelowHighWater"), "kill \(kill): read-only for another reason: \(reason)")
            #expect(sidecar == .value(generation + 1), "kill \(kill): read-only, sidecar \(sidecar), generation \(generation)")
            #expect(log == .value(generation) || log == .value(generation + 1), "kill \(kill): log \(log), generation \(generation)")
            // A person's act in the app; here it proves the read-only state
            // is the recoverable one the contract names (F8r3).
            let adopted = await repository.adopt(toHighWater: generation + 1)
            #expect(adopted == .adopted(from: generation, to: generation + 1), "kill \(kill): \(adopted)")
            kind = .betweenPhases
        case .refused:
            kind = .oldState   // unreachable: thrown above
        }

        let verified = await repository.verify()
        if case .problems(let problems) = verified {
            Issue.record("kill \(kill): verify found \(problems)")
        }
        let notes: [String]
        do {
            let snapshot = try await CatalogLoad.read(repository)
            notes = try snapshot.rows.compactMap { row in
                let note = try VideoRecord(loaded: row).userNotes ?? ""
                return note.hasPrefix("crash-gen ") ? note : nil
            }
        } catch {
            await repository.close()
            throw error
        }
        await repository.close()
        let lastSave = try Self.lastSave(url)
        return KillVerdict(kind: kind, notes: notes, lastSave: lastSave)
    }

    static func lastSave(_ url: URL) throws -> Int {
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        defer { try? queue.close() }
        return try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT max(generation) FROM generation_history WHERE kind = 'commit' AND writer = 'save'") ?? -1
        }
    }
}

struct KillTally: CustomStringConvertible {
    private var counts: [KillVerdict.Kind: Int] = [:]
    mutating func add(_ kind: KillVerdict.Kind) { counts[kind, default: 0] += 1 }
    var total: Int { counts.values.reduce(0, +) }
    var description: String {
        "\(counts[.oldState, default: 0]) old state (in-flight commit lost), "
            + "\(counts[.newState, default: 0]) new state (in-flight commit landed), "
            + "\(counts[.betweenPhases, default: 0]) between high-water and COMMIT (read-only → adopted)"
    }
}

/// SplitMix64 — a tiny seeded generator so a failing kill pattern replays.
struct KillDelayGenerator: RandomNumberGenerator {
    let seed: UInt64
    private var state: UInt64
    init(seed: UInt64) { self.seed = seed; state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
