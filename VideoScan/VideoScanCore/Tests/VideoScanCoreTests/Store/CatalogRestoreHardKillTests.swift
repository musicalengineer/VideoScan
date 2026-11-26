// CatalogRestoreHardKillTests.swift
// GH #343 — a REAL crash in the middle of Restore from Backup…, not a
// simulated one. The test-only `catalog-crash-helper restore-once` opens a
// catalog with the PRODUCTION durability and restores a sealed backup INTO
// it one page per step (sleeping between steps so the window is wide); this
// test SIGKILLs it at a random moment — before the first page, mid-copy, at
// the commit, during the close's checkpoint, or after it finished — and
// reopens the file through the real open path. After EVERY kill:
//   TRUTH      integrity_check is ok; the catalog is either the live one
//              (opens read-write at the live generation, every record says
//              "live") or the backup (opens read-only "restoredBelowHighWater"
//              at the backup's generation, every record says "backed up") —
//              never a mix, never refused, never an old file with a newer
//              -wal replayed onto it; the high-water witnesses still read the
//              live generation either way (a restore never touches them).
//   SCALE      12 kills × a 200-record catalog; well under a minute.
//   ISOLATION  a fresh copy of the template folder per kill.
// Seeded delays; replay with VIDEOSCAN_KILL_SEED=<seed> (CatalogHardKillTests).

import Foundation
import GRDB
import Testing
@testable import VideoScanCore

@Suite("Catalog restore hard kill — SIGKILL mid-restore, reopen: the live catalog or the backup, never a mix", .serialized)
struct CatalogRestoreHardKillTests {

    static let kills = 12
    static let stepDelayMicros: UInt32 = 2_000

    @Test("12 random SIGKILLs during a restore: opens, integrity ok, all-live or all-backup, witnesses untouched",
          .timeLimit(.minutes(5)))
    func randomKillsLeaveLiveOrBackup() async throws {
        let helper = try #require(HardKillChild.helperURL(), "catalog-crash-helper was not built beside the test bundle")
        let scene = try await RestoreScene.make(healthyRows: 200); defer { scene.remove() }
        let repository = try await scene.open()
        let backedUp = try await RestoreScene.setNotes("backed up", on: repository)
        let backup = try scene.seal(repository, "backup.sqlite")
        let live = try await RestoreScene.setNotes("live", on: repository)
        await repository.close()
        let templateNames = try FileManager.default.contentsOfDirectory(atPath: scene.folder.path)
            .filter { !$0.hasSuffix("-wal") && !$0.hasSuffix("-shm") }

        var rng = KillDelayGenerator(seed: HardKillChild.seed())
        print("[restore-hard-kill] seed \(rng.seed) — replay with VIDEOSCAN_KILL_SEED=\(rng.seed)")
        var outcomes: [String: Int] = [:]
        for kill in 1...Self.kills {
            let folder = scene.importer.directory.appendingPathComponent("kill-\(kill)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for name in templateNames {
                try FileManager.default.copyItem(at: scene.folder.appendingPathComponent(name), to: folder.appendingPathComponent(name))
            }
            let database = folder.appendingPathComponent("catalog.sqlite")
            let child = try HardKillChild.start(helper, arguments: ["restore-once", database.path, backup.path, "\(backedUp)",
                                                                   "\(Self.stepDelayMicros)"],
                                                output: folder.appendingPathComponent("child.log"))
            try await Self.waitFor(child) { $0.hasPrefix("STEP") || $0.hasPrefix("RESTORED") }
            if kill == Self.kills {
                // The last one dies only after the restore returned: the
                // finished case is always covered, whatever the seed.
                try await Self.waitFor(child) { $0.hasPrefix("RESTORED") }
            } else {
                // Up to ~1.3× the copy's length, so some kills land after it ended.
                let total = Self.totalSteps(child) ?? 200
                let delay = rng.next() % UInt64(Double(total) * Double(Self.stepDelayMicros) * 1.3 / 1_000 + 1)
                try await Task.sleep(nanoseconds: delay * 1_000_000)
            }
            Self.killAndReap(child)
            let landed = try await Self.verify(database, live: live, backedUp: backedUp, kill: kill, child: child)
            outcomes[landed, default: 0] += 1
        }
        print("[restore-hard-kill] \(outcomes)")
        #expect(outcomes.values.reduce(0, +) == Self.kills)
        #expect(outcomes["backup", default: 0] >= 1, "the restored case was reached (the last kill waits for it)")
    }

    private static func waitFor(_ child: HardKillChild, _ wanted: (String) -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if child.lines.contains(where: wanted) { return }
            if child.lines.contains(where: { $0.hasPrefix("OPEN") }) {
                killAndReap(child)
                throw FixtureFailure(words: "the helper could not open: \(child.lines.joined(separator: " | "))")
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        killAndReap(child)
        throw FixtureFailure(words: "the helper never said what was waited for: \(child.lines.suffix(3).joined(separator: " | "))")
    }

    private static func totalSteps(_ child: HardKillChild) -> Int? {
        child.lines.lazy.compactMap { line -> Int? in
            let fields = line.split(separator: " ")
            return fields.count == 3 && fields[0] == "STEP" ? Int(fields[2]) : nil
        }.first
    }

    /// SIGKILL (a no-op if it already exited) and reap.
    private static func killAndReap(_ child: HardKillChild) {
        kill(child.pid, SIGKILL)
        var status: Int32 = 0
        var waited: pid_t
        repeat { waited = waitpid(child.pid, &status, 0) } while waited == -1 && errno == EINTR
    }

    /// Reopen through the real open path; return which catalog it is.
    private static func verify(_ url: URL, live: Int, backedUp: Int, kill: Int, child: HardKillChild) async throws -> String {
        let where_ = "kill \(kill) (child said: \(child.lines.suffix(2).joined(separator: " | ")))"
        #expect(try CatalogHardKillTests.integrityCheck(url) == ["ok"], Comment(rawValue: where_))
        #expect(CatalogHighWater.read(besideDatabaseAt: url) == .value(live), Comment(rawValue: "\(where_): sidecar moved"))
        #expect(CatalogHighWaterLedger.read(besideDatabaseAt: url) == .value(live), Comment(rawValue: "\(where_): log moved"))
        let repository = GRDBCatalogRepository(host: "restore-hard-kill", durability: .archival)
        let opened = await repository.open(at: url)
        let generation = await repository.generation
        await repository.close()
        let notes = try await RestoreScene.notes(at: url)
        switch opened {
        case .readWrite:
            #expect(generation == live, Comment(rawValue: "\(where_): read-write at \(generation)"))
            #expect(notes == ["live"], Comment(rawValue: "\(where_): read-write but the notes are \(notes)"))
            return "live"
        case .readOnly(let reason):
            #expect(reason.hasPrefix("restoredBelowHighWater"), Comment(rawValue: "\(where_): \(reason)"))
            #expect(generation == backedUp, Comment(rawValue: "\(where_): read-only at \(generation)"))
            #expect(notes == ["backed up"], Comment(rawValue: "\(where_): restored but the notes are \(notes)"))
            return "backup"
        case .refused(let reason):
            Issue.record("\(where_): the catalog REFUSED to open: \(reason)")
            return "refused"
        }
    }
}
