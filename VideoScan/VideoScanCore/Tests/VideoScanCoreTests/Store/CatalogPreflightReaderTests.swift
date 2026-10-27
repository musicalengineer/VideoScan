// CatalogPreflightReaderTests.swift
// The launch preflight's catalog questions on REAL SQLite files, generated
// here (no family data): schema version, quick_check passing, quick_check
// finding damage, quick_check interrupted at its budget, and a missing file.
// In Store/ because only Store/ folders may import GRDB (CatalogStoreSensorTests).

import Foundation
import GRDB
import Testing
@testable import VideoScanCore

@Suite("CatalogPreflightReader")
struct CatalogPreflightReaderTests {

    /// A scratch folder that removes itself.
    private final class Scratch {
        let folder: URL
        init() throws {
            folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("preflight-reader-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: folder) }
        func url(_ name: String) -> URL { folder.appendingPathComponent(name) }
    }

    /// A tiny catalog-shaped file: catalog_state with a schema version, plus
    /// `rows` rows of filler in an indexed table (so quick_check has pages to walk).
    private func makeFixture(at url: URL, schemaVersion: Int?, rows: Int = 200) throws {
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            if let schemaVersion {
                try db.execute(sql: "CREATE TABLE catalog_state (singleton INTEGER PRIMARY KEY CHECK (singleton = 1), schema_version INTEGER NOT NULL)")
                try db.execute(sql: "INSERT INTO catalog_state VALUES (1, ?)", arguments: [schemaVersion])
            }
            try db.execute(sql: "CREATE TABLE filler (id INTEGER PRIMARY KEY, name TEXT, body BLOB)")
            try db.execute(sql: "CREATE INDEX filler_name ON filler(name)")
            try db.execute(sql: """
                WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < ?)
                INSERT INTO filler SELECT i, 'row-' || i, randomblob(200) FROM n
                """, arguments: [rows])
        }
        try queue.close()
    }

    @Test func readsTheSchemaVersion() throws {
        let scratch = try Scratch()
        let url = scratch.url("catalog.sqlite")
        try makeFixture(at: url, schemaVersion: 12)
        #expect(try CatalogPreflightReader.schemaVersion(at: url) == 12)
    }

    @Test func noCatalogStateTableIsNil() throws {
        let scratch = try Scratch()
        let url = scratch.url("catalog.sqlite")
        try makeFixture(at: url, schemaVersion: nil)
        #expect(try CatalogPreflightReader.schemaVersion(at: url) == nil)
    }

    @Test func expectedVersionIsTheStoresCurrentVersion() {
        #expect(CatalogPreflightReader.expectedSchemaVersion == GRDBCatalogRepository.currentSchemaVersion)
    }

    @Test func quickCheckPassesOnAHealthyFile() throws {
        let scratch = try Scratch()
        let url = scratch.url("catalog.sqlite")
        try makeFixture(at: url, schemaVersion: 12)
        let outcome = try CatalogPreflightReader.quickCheck(at: url, budget: .seconds(5))
        guard case .passed = outcome else {
            Issue.record("expected passed, got \(outcome)")
            return
        }
    }

    @Test func quickCheckLeavesTheFileUnchanged() throws {
        let scratch = try Scratch()
        let url = scratch.url("catalog.sqlite")
        try makeFixture(at: url, schemaVersion: 12)
        let before = try Data(contentsOf: url)
        _ = try CatalogPreflightReader.quickCheck(at: url, budget: .seconds(5))
        _ = try CatalogPreflightReader.schemaVersion(at: url)
        #expect(try Data(contentsOf: url) == before, "read-only: not a byte changed")
    }

    @Test func damagedFileIsNeverAPass() throws {
        // Zero out the middle of the file (index and table pages), keep the header.
        let scratch = try Scratch()
        let url = scratch.url("catalog.sqlite")
        try makeFixture(at: url, schemaVersion: 12, rows: 2_000)
        var bytes = try Data(contentsOf: url)
        let page = 4_096
        let start = page * 3
        let end = min(bytes.count - page, start + page * 20)
        try #require(end > start, "fixture has enough pages to damage")
        bytes.replaceSubrange(start..<end, with: Data(repeating: 0xA5, count: end - start))
        try bytes.write(to: url)
        // The engine may list problems, or refuse outright; either way it is
        // not a pass, and the preflight rule turns both into a non-green check.
        do {
            let outcome = try CatalogPreflightReader.quickCheck(at: url, budget: .seconds(5))
            guard case .problems(let lines, _) = outcome else {
                Issue.record("damaged file read as \(outcome)")
                return
            }
            #expect(!lines.isEmpty)
            #expect(lines.count <= CatalogPreflightReader.maxProblemLines)
        } catch {
            // "database disk image is malformed" — the rule maps this to "Couldn't check" (warn).
        }
    }

    /// A statement that never returns on its own: only an interrupt ends it.
    /// (C++ analogy: a `while (true)` worker you can stop only through its
    /// cancellation flag — so "it stopped" PROVES the stop was delivered.)
    /// Every row passes through `preflight_safety_net`, registered by
    /// `armSafetyNet`, which fails the statement after `safetyNet` — so a
    /// lost stop is a clear test failure, never a hung test run (a blocked
    /// synchronous SQLite call ignores Swift Testing's `.timeLimit`).
    static let neverEndingStatement = """
        WITH RECURSIVE forever(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM forever)
        SELECT 'never' FROM forever WHERE preflight_safety_net(x) < 0
        """

    static let safetyNet: Duration = .seconds(20)

    /// Registers `preflight_safety_net(x)` on the reader's connection: x
    /// until `safetyNet` has passed, then an error naming the lost stop.
    static func armSafetyNet(_ db: Database) {
        let deadline = ContinuousClock.now + safetyNet
        db.add(function: DatabaseFunction("preflight_safety_net", argumentCount: 1, pure: false) { values in
            if ContinuousClock.now > deadline {
                throw DatabaseError(message: "safety net: no stop reached the statement in \(safetyNet) — the budget/cancel was lost")
            }
            return values[0]
        })
    }

    // 2026-10-21 nightly-flake hunt: these used to run the real quick_check
    // on a 60 MB file and race a 1–2 ms timer against its ~40 ms walk. On a
    // busy M4 the timer fired before the first step (SQLite drops that
    // interrupt), after the walk ended, or — in a saturated full run — not
    // for 20 s: `.passed` every time. A wall-clock race with no right answer
    // under load. Now the statement cannot end by itself, so the only way
    // out is the budget / cancel path under test.

    @Test(.timeLimit(.minutes(1)))
    func quickCheckIsInterruptedAtItsBudget() throws {
        let scratch = try Scratch()
        let url = scratch.url("catalog.sqlite")
        try makeFixture(at: url, schemaVersion: 12)
        let outcome = try CatalogPreflightReader.quickCheck(
            at: url, budget: .milliseconds(1), cancellation: PreflightCancellation(),
            statement: Self.neverEndingStatement, beforeStep: { db in Self.armSafetyNet(db) })
        #expect(outcome == .ranOutOfTime(budget: .milliseconds(1)), "\(outcome)")
    }

    @Test(.timeLimit(.minutes(1)))
    func aBudgetThatRunsOutBeforeTheFirstStepIsNotLost() throws {
        // The budget runs out after the last look and before the first step
        // (the reading thread sleeps past it right there). With the old
        // timer watchdog the interrupt landed with no statement running and
        // was dropped; this ran into the safety net.
        let scratch = try Scratch()
        let url = scratch.url("catalog.sqlite")
        try makeFixture(at: url, schemaVersion: 12)
        let outcome = try CatalogPreflightReader.quickCheck(
            at: url, budget: .milliseconds(20), cancellation: PreflightCancellation(),
            statement: Self.neverEndingStatement, beforeStep: { db in Self.armSafetyNet(db); usleep(50_000) })
        #expect(outcome == .ranOutOfTime(budget: .milliseconds(20)), "\(outcome)")
    }

    @Test func theRealQuickCheckStopsAtItsBudgetMidWalk() throws {
        // The real PRAGMA: the budget has run out by the time it starts
        // stepping, so it must stop inside its page walk — which only the
        // progress handler can see (no timer thread is involved at all, so
        // a busy Mac cannot delay the stop). A walk that ignored the budget
        // would come back `.passed`.
        let scratch = try Scratch()
        let url = scratch.url("catalog.sqlite")
        try makeFixture(at: url, schemaVersion: 12, rows: 20_000)
        let outcome = try CatalogPreflightReader.quickCheck(
            at: url, budget: .milliseconds(20), cancellation: PreflightCancellation(),
            statement: "PRAGMA quick_check(\(CatalogPreflightReader.maxProblemLines))",
            beforeStep: { _ in usleep(50_000) })
        #expect(outcome == .ranOutOfTime(budget: .milliseconds(20)), "\(outcome)")
    }

    @Test func missingFileThrows() throws {
        let scratch = try Scratch()
        let url = scratch.url("no-such.sqlite")
        #expect(throws: (any Error).self) { try CatalogPreflightReader.quickCheck(at: url, budget: .seconds(1)) }
        #expect(throws: (any Error).self) { try CatalogPreflightReader.schemaVersion(at: url) }
        #expect(!FileManager.default.fileExists(atPath: url.path), "a read-only open never creates the file")
    }

    @Test func cancelledBeforeStartNeverOpensTheFile() throws {
        let scratch = try Scratch()
        let url = scratch.url("catalog.sqlite")
        try makeFixture(at: url, schemaVersion: 12)
        let token = PreflightCancellation()
        token.cancel()
        #expect(try CatalogPreflightReader.quickCheck(at: url, budget: .seconds(5), cancellation: token) == .cancelled)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancelDuringQuickCheckInterruptsItAndSaysCancelled() throws {
        // The cancel comes from another thread while the statement runs (or
        // is about to) — the quit path's shape. The budget is far away, so
        // ranOutOfTime would mean the cancel was lost.
        let scratch = try Scratch()
        let url = scratch.url("catalog.sqlite")
        try makeFixture(at: url, schemaVersion: 12)
        let token = PreflightCancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(2)) { token.cancel() }
        let outcome = try CatalogPreflightReader.quickCheck(
            at: url, budget: .seconds(600), cancellation: token,
            statement: Self.neverEndingStatement, beforeStep: { db in Self.armSafetyNet(db) })
        #expect(outcome == .cancelled, "\(outcome)")
    }

    @Test(.timeLimit(.minutes(1)))
    func aCancelLandingJustBeforeTheFirstStepIsNotLost() throws {
        // The exact window QA r2 left open: after the last isCancelled look,
        // before the first step. SQLite drops a one-shot interrupt here
        // (qaR2_interruptWithNoStatementRunningIsDropped); the remembered
        // stop must still end the statement. Before the progress-handler
        // stop this ran into the safety net.
        let scratch = try Scratch()
        let url = scratch.url("catalog.sqlite")
        try makeFixture(at: url, schemaVersion: 12)
        let token = PreflightCancellation()
        let outcome = try CatalogPreflightReader.quickCheck(
            at: url, budget: .seconds(600), cancellation: token,
            statement: Self.neverEndingStatement, beforeStep: { db in Self.armSafetyNet(db); token.cancel() })
        #expect(outcome == .cancelled, "\(outcome)")
    }

    @Test func theRealQuickCheckHonoursAnInterruptMidWalk() throws {
        // The real PRAGMA on a file with pages to walk. The cancel fires from
        // GRDB's statement trace, which runs inside sqlite3_step — so the
        // statement IS running — and quick_check's page walk must notice.
        // Causality, not timing: no timer anywhere.
        let scratch = try Scratch()
        let url = scratch.url("catalog.sqlite")
        try makeFixture(at: url, schemaVersion: 12, rows: 20_000)
        let token = PreflightCancellation()
        let outcome = try CatalogPreflightReader.quickCheck(
            at: url, budget: .seconds(600), cancellation: token,
            statement: "PRAGMA quick_check(\(CatalogPreflightReader.maxProblemLines))",
            beforeStep: { db in db.trace(options: .statement) { _ in token.cancel() } })
        #expect(outcome == .cancelled, "\(outcome)")
        // The same file with no cancel passes, so `.cancelled` above was the
        // interrupt and not a check that fails anyway.
        let clean = try CatalogPreflightReader.quickCheck(at: url, budget: .seconds(600))
        guard case .passed = clean else {
            Issue.record("the fixture does not pass quick_check: \(clean)")
            return
        }
    }

    @Test func lateWatchdogsAndCancelsAfterCloseAreHarmless() throws {
        // QA r1 minor 3: an interrupt racing close. Budgets of 0–2 ms on a
        // small file make the budget run out around the end of the check; a
        // cancel lands after return. Nothing may crash or hang.
        let scratch = try Scratch()
        let url = scratch.url("catalog.sqlite")
        try makeFixture(at: url, schemaVersion: 12, rows: 2_000)
        for round in 0..<60 {
            let token = PreflightCancellation()
            let outcome = try CatalogPreflightReader.quickCheck(at: url, budget: .milliseconds(round % 3), cancellation: token)
            token.cancel()
            switch outcome {
            case .passed, .ranOutOfTime: break
            case .problems, .cancelled: Issue.record("round \(round): \(outcome)")
            }
        }
    }

    /// The real probe for every question about the CATALOG (the file, its
    /// size, the folders, the tools, the schema, and the real
    /// `PRAGMA quick_check` through CatalogPreflightReader) and a fine
    /// machine for the questions about the HOST (disk free, RAM, swap,
    /// thermal state, power). GH #385: with the host's real answers the
    /// end-to-end test measured the Mac, not the reader. The M1 (a laptop)
    /// and the M4 (agent builds running, system disk 95 % used, 2026-10-26)
    /// both answered `.longOperations`. The hold rules have their own unit
    /// tests (PreflightGateTests, LaunchPreflightTests' FakePreflightProbe).
    struct RealCatalogFineMachineProbe: PreflightProbe {
        let real = SystemPreflightProbe()

        func volume(containing url: URL) throws -> PreflightVolume? {
            PreflightVolume(id: "/", name: "Macintosh HD", availableBytes: 500 * PreflightThresholds.gigabyte,
                            totalBytes: 1_000 * PreflightThresholds.gigabyte)
        }
        func isVolumeMounted(at url: URL) -> Bool { real.isVolumeMounted(at: url) }
        func physicalMemoryBytes() -> UInt64? { 64 * PreflightThresholds.gibibyte }
        func swapUsedBytes() throws -> UInt64? { 0 }
        func thermalState() -> PreflightThermalState? { .nominal }
        func powerSource() -> PreflightPowerSource? { .mains }
        func fileExists(at url: URL) -> Bool { real.fileExists(at: url) }
        func fileSize(at url: URL) -> UInt64? { real.fileSize(at: url) }
        func isWritableFolder(at url: URL) -> Bool { real.isWritableFolder(at: url) }
        func executablePath(for tool: PreflightTool) -> String? { real.executablePath(for: tool) }
        func catalogSchemaVersion(at databaseURL: URL) throws -> Int? {
            try real.catalogSchemaVersion(at: databaseURL)
        }
        func catalogQuickCheck(at databaseURL: URL, budget: Duration,
                               cancellation: PreflightCancellation) throws -> PreflightQuickCheckOutcome {
            try real.catalogQuickCheck(at: databaseURL, budget: budget, cancellation: cancellation)
        }
    }

    private func endToEndContext(_ scratch: Scratch, _ url: URL) throws -> PreflightContext {
        try Data("test".utf8).write(to: scratch.url(SQLiteCatalogReader.latchFileName))
        return PreflightContext(supportFolder: scratch.folder, databaseURL: url,
                                temporaryFolder: scratch.folder, logFolder: scratch.folder,
                                masterArchiveVolume: nil,
                                expectedSchemaVersion: CatalogPreflightReader.expectedSchemaVersion)
    }

    @Test func theRealProbeRunsQuickCheckThroughThisReader() async throws {
        // End to end: a generated catalog + marker, the real probe's catalog
        // questions (quick_check through this reader), the whole run, on a
        // machine pinned to "fine" so the host's own disk, load and power
        // cannot decide the hold (GH #385).
        let scratch = try Scratch()
        let url = scratch.url("catalog.sqlite")
        try makeFixture(at: url, schemaVersion: CatalogPreflightReader.expectedSchemaVersion)
        let report = try await LaunchPreflight.run(try endToEndContext(scratch, url),
                                                   probe: RealCatalogFineMachineProbe())
        let byID = Dictionary(uniqueKeysWithValues: report.checks.map { ($0.id, $0) })
        #expect(byID[.catalogSwitched]?.level == .ok)
        #expect(byID[.catalogSchema]?.level == .ok, "\(byID[.catalogSchema]?.logLine ?? "")")
        #expect(byID[.catalogJournal]?.level == .ok)
        #expect(byID[.catalogQuickCheck]?.level == .ok, "\(byID[.catalogQuickCheck]?.logLine ?? "")")
        #expect(report.quickCheckElapsed != nil)
        #expect(report.hold == .none, "\(report.checks.map(\.logLine))")
    }

    /// The pinned machine hides nothing about the CATALOG: a damaged file
    /// through the same probe is still caught by the real quick_check.
    @Test func thePinnedMachineStillRunsTheRealQuickCheck() async throws {
        let scratch = try Scratch()
        let url = scratch.url("catalog.sqlite")
        try makeFixture(at: url, schemaVersion: CatalogPreflightReader.expectedSchemaVersion, rows: 2_000)
        var bytes = try Data(contentsOf: url)
        let page = 4_096, start = page * 3
        let end = min(bytes.count - page, start + page * 20)
        try #require(end > start, "fixture has enough pages to damage")
        bytes.replaceSubrange(start..<end, with: Data(repeating: 0xA5, count: end - start))
        try bytes.write(to: url)
        let report = try await LaunchPreflight.run(try endToEndContext(scratch, url),
                                                   probe: RealCatalogFineMachineProbe())
        let quick = report.checks.first { $0.id == .catalogQuickCheck }
        #expect(quick != nil && quick?.level != .ok, "\(quick?.logLine ?? "no quick_check row")")
    }
}
