// DailyFileCheckTests.swift — Validate Catalog runs itself daily (Rick
// 2026-11-07), the 7-day backstop on the Files line, and the 7-day reminder
// clocks on the catalog backup and on sync.
//
//   LOGIC     — the policy table: the 03:30 slot and its boundaries, the away
//               window's 11:00 end, the 24 h launch / idle catch-up, one
//               unattended start per slot, busy → skip; the reminder clocks'
//               7-day boundaries
//   WRITER (rule 8) — through the scheduler's real `tick()`: it does not
//               start during a write hold or a running scan; no double start;
//               a relaunch catches up; a run Stopped leaves a partial outcome
//               (the real Validate job and marker on a sandbox catalog), the
//               Files line yellow, and the scheduler does not restart it
//   ISOLATION — a finished check dated in the future proves nothing; the
//               snapshot not landed yet → the scheduler judges nothing
//   TRUTH     — a stale completed record on disk (fresh mtime) never shows
//               green: the Files line and the Catalog indicator read the
//               record's own finish date
//   SENSOR    — one engine (startValidateCatalog, no job built here); the app
//               attaches the scheduler on the master only, never on a test host
//   Scale and the media matrix do not apply: the scheduler reads two dates
//   and a few flags, never a record or a file's bytes.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private let day: TimeInterval = 86_400
private let hour: TimeInterval = 3_600

/// A fixed Gregorian calendar in New York, so 03:30 is 03:30 on every host.
private let nyc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/New_York") ?? .current
    return c
}()

/// 2026-11-07 at hh:mm, New York.
private func at(_ h: Int, _ m: Int = 0, dayOffset: Int = 0) -> Date {
    let base = nyc.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: h, minute: m)) ?? Date()
    return nyc.date(byAdding: .day, value: dayOffset, to: base) ?? base
}

private func inputs(_ now: Date, last: Date?, busy: String? = nil, idle: TimeInterval = 0, launch: Bool = false,
                    started: Date? = nil) -> DailyFileCheckPolicy.Inputs {
    DailyFileCheckPolicy.Inputs(now: now, lastFinished: last, busy: busy, idleSeconds: idle, launchLookOwed: launch, lastStarted: started)
}

private func decide(_ i: DailyFileCheckPolicy.Inputs) -> DailyFileCheckPolicy.Decision {
    DailyFileCheckPolicy.decide(i, calendar: nyc)
}

// MARK: - The rule

@Suite("Daily file check — the policy")
struct DailyFileCheckPolicyTests {

    @Test("the slot is the most recent 03:30: 03:29 belongs to yesterday's, 03:30 is today's")
    func theSlot() {
        #expect(DailyFileCheckPolicy.slot(atOrBefore: at(3, 29), calendar: nyc) == at(3, 30, dayOffset: -1))
        #expect(DailyFileCheckPolicy.slot(atOrBefore: at(3, 30), calendar: nyc) == at(3, 30))
        #expect(DailyFileCheckPolicy.slot(atOrBefore: at(23, 59), calendar: nyc) == at(3, 30))
        #expect(!DailyFileCheckPolicy.inAwayWindow(at(3, 29), calendar: nyc))
        #expect(DailyFileCheckPolicy.inAwayWindow(at(3, 30), calendar: nyc))
        #expect(DailyFileCheckPolicy.inAwayWindow(at(10, 59), calendar: nyc))
        #expect(!DailyFileCheckPolicy.inAwayWindow(at(11, 0), calendar: nyc), "Rick's day starts at 11:00")
        #expect(!DailyFileCheckPolicy.inAwayWindow(at(2, 0), calendar: nyc), "never during the Ultra's 02:00 nightly")
    }

    @Test("in the away window: last finished before today's slot → start (03:30); finished this slot → wait")
    func theAwayWindow() {
        #expect(decide(inputs(at(3, 30), last: at(4, 0, dayOffset: -1))) == .start(.slot))
        #expect(decide(inputs(at(8, 0), last: at(4, 0, dayOffset: -1))) == .start(.slot), "a slot missed (Mac asleep) is taken until 11:00")
        #expect(decide(inputs(at(8, 0), last: nil)) == .start(.slot))
        #expect(decide(inputs(at(4, 10), last: at(4, 0))) == .wait, "already finished this slot")
        #expect(decide(inputs(at(3, 29), last: at(4, 0, dayOffset: -1))) == .wait, "23 h 29 min old at 03:29: not yet")
    }

    @Test("outside the window: over 24 h old catches up at launch or after 15 min idle; 24 h or less, or busy-at-the-keyboard, waits")
    func theCatchUp() {
        let afternoon = at(14, 0)
        #expect(decide(inputs(afternoon, last: afternoon.addingTimeInterval(-23 * hour), launch: true)) == .wait)
        #expect(decide(inputs(afternoon, last: afternoon.addingTimeInterval(-day), launch: true)) == .wait, "exactly 24 h is not over")
        #expect(decide(inputs(afternoon, last: afternoon.addingTimeInterval(-(day + 60)), launch: true)) == .start(.launch))
        #expect(decide(inputs(afternoon, last: nil, launch: true)) == .start(.launch), "never finished = overdue")
        #expect(decide(inputs(afternoon, last: afternoon.addingTimeInterval(-3 * day), idle: 15 * 60)) == .start(.idle))
        #expect(decide(inputs(afternoon, last: afternoon.addingTimeInterval(-3 * day), idle: 15 * 60 - 1)) == .wait,
                "Rick is at the keyboard and the launch look is spent")
    }

    @Test("one unattended start per slot: started since 03:30 → wait, even when the check did not finish (Rick stopped it)")
    func oneStartPerSlot() {
        #expect(decide(inputs(at(5, 0), last: nil, launch: true, started: at(3, 31))) == .wait)
        #expect(decide(inputs(at(15, 0), last: nil, idle: day, started: at(3, 31))) == .wait)
        // The next slot is a new day.
        #expect(decide(inputs(at(3, 30, dayOffset: 1), last: nil, started: at(3, 31))) == .start(.slot))
    }

    @Test("due but busy (write hold, scan, Update, another check, a viewer) → skip with the words; nothing due → wait even when busy")
    func busySkips() {
        #expect(decide(inputs(at(3, 30), last: nil, busy: "a scan is running")) == .skip(.slot, "a scan is running"))
        #expect(decide(inputs(at(14, 0), last: nil, busy: "x", launch: true)) == .skip(.launch, "x"))
        #expect(decide(inputs(at(14, 0), last: at(13, 0), busy: "x", launch: true)) == .wait)
        let reason = DailyFileCheckScheduler.busyReason
        #expect(reason(false, nil, nil, false, false, nil) == nil)
        #expect(reason(true, nil, nil, false, false, nil) == "this Mac is a read-only viewer of the catalog")
        #expect(reason(false, "no catalog.sqlite", nil, false, false, nil) == "no catalog.sqlite")
        #expect(reason(false, nil, "Import to SQLite", false, false, nil) == "a catalog write hold is on (Import to SQLite)")
        #expect(reason(false, nil, nil, true, false, nil) == "a scan is running")
        #expect(reason(false, nil, nil, false, true, nil)?.hasPrefix("Update everything stale is running") == true)
        #expect(reason(false, nil, nil, false, false, "Validate Catalog") == "Validate Catalog is already running")
    }

    @Test("ISOLATION: a finished check dated after now (a copied record, a clock stepped back) proves nothing — due")
    func futureDatedProvesNothing() {
        #expect(decide(inputs(at(4, 0), last: at(9, 0))) == .start(.slot))
        #expect(decide(inputs(at(14, 0), last: at(14, 0, dayOffset: 2), launch: true)) == .start(.launch))
        #expect(decide(inputs(at(14, 0), last: at(14, 4), launch: true)) == .wait, "a few minutes of clock skew is tolerated")
    }

    @Test("the last finished check is the OLDER of the two steps' dates, and only when both finished .ok")
    func lastFinishedFromTheRows() {
        func row(_ outcome: FreshnessRow.Outcome, _ date: Date?) -> FreshnessRow {
            FreshnessRow(kind: "k", title: "t", eligible: 1, covered: 1, offline: 0, lastCompleted: date, lastOutcome: outcome)
        }
        let a = at(4, 0), b = at(4, 20)
        #expect(DailyFileCheckPolicy.lastFinished(files: row(.ok, a), integrity: row(.ok, b)) == a)
        #expect(DailyFileCheckPolicy.lastFinished(files: row(.ok, b), integrity: row(.ok, a)) == a)
        #expect(DailyFileCheckPolicy.lastFinished(files: row(.partial, b), integrity: row(.ok, b)) == nil, "a stopped file check is no finished check")
        #expect(DailyFileCheckPolicy.lastFinished(files: row(.ok, b), integrity: row(.failed, b)) == nil)
        #expect(DailyFileCheckPolicy.lastFinished(files: row(.ok, b), integrity: row(.neverRan, nil)) == nil)
        #expect(DailyFileCheckPolicy.lastFinished(files: nil, integrity: row(.ok, b)) == nil)
    }
}

// MARK: - The scheduler (rule 8 writer tests)

@MainActor
final class FakeDailyCheckApp {
    var now = at(3, 30)
    var last: Date?? = .some(at(4, 0, dayOffset: -1))
    var busy: String?
    var idle: TimeInterval = 0
    var refuse = false
    private(set) var starts = 0
    private(set) var notes: [String] = []
    var onStart: () -> Void = {}

    var env: DailyFileCheckEnvironment {
        var e = DailyFileCheckEnvironment()
        e.now = { [unowned self] in now }
        e.lastFinished = { [unowned self] in last }
        e.busy = { [unowned self] in busy }
        e.idleSeconds = { [unowned self] in idle }
        e.start = { [unowned self] in starts += 1; onStart(); return !refuse }
        e.note = { [unowned self] in notes.append($0) }
        e.calendar = nyc
        return e
    }
}

@Suite("Daily file check — the scheduler (writer)")
@MainActor
struct DailyFileCheckSchedulerTests {

    @Test("WRITER: no start during a catalog write hold — one 'waiting' line, not one per look; starts once the hold is released")
    func notDuringAWriteHold() {
        let app = FakeDailyCheckApp()
        app.busy = DailyFileCheckScheduler.busyReason(readOnly: false, unavailable: nil, writeHold: "Import to SQLite", scanning: false,
                                                      updating: false, checker: nil)
        let s = DailyFileCheckScheduler(env: app.env)
        #expect(s.tick() == .skip(.slot, "a catalog write hold is on (Import to SQLite)"))
        app.now = app.now.addingTimeInterval(300)
        _ = s.tick()
        #expect(app.starts == 0)
        #expect(app.notes == ["due (the 03:30 daily check), waiting: a catalog write hold is on (Import to SQLite)"], "\(app.notes)")
        app.busy = nil
        app.now = app.now.addingTimeInterval(300)
        #expect(s.tick() == .start(.slot))
        #expect(app.starts == 1)
        #expect(app.notes.last?.hasPrefix("starting Validate Catalog — the 03:30 daily check; last finished check: ") == true)
    }

    @Test("WRITER: no start while a scan runs; the launch catch-up stays owed until the scan ends")
    func notDuringAScan() {
        let app = FakeDailyCheckApp()
        app.now = at(14, 0)
        app.last = .some(at(14, 0, dayOffset: -3))
        app.busy = "a scan is running"
        let s = DailyFileCheckScheduler(env: app.env)
        #expect(s.tick() == .skip(.launch, "a scan is running"))
        #expect(s.launchLookOwed, "a busy launch look is not spent")
        app.busy = nil
        app.now = at(14, 30)
        #expect(s.tick() == .start(.launch))
        #expect(app.starts == 1 && !s.launchLookOwed)
    }

    @Test("WRITER: no double start — the next looks wait while the run is active and after it ends, until the next slot")
    func noDoubleStart() {
        let app = FakeDailyCheckApp()
        let s = DailyFileCheckScheduler(env: app.env)
        #expect(s.tick() == .start(.slot))
        app.busy = "Validate Catalog is already running"
        app.now = at(3, 35)
        #expect(s.tick() == .wait)
        app.busy = nil
        app.last = .some(nil)                       // it was stopped: no finished check
        app.now = at(10, 0)
        app.idle = day
        #expect(s.tick() == .wait, "a run Rick stopped is not restarted this slot")
        app.now = at(3, 30, dayOffset: 1)
        #expect(s.tick() == .start(.slot))
        #expect(app.starts == 2)
    }

    @Test("WRITER: a relaunch catches up — a fresh scheduler with a 3-day-old check starts at its first look, in Rick's day, without idle")
    func relaunchCatchesUp() {
        let app = FakeDailyCheckApp()
        app.now = at(14, 0)
        app.last = .some(at(14, 0, dayOffset: -3))
        let first = DailyFileCheckScheduler(env: app.env)
        #expect(first.tick() == .start(.launch))
        // Quit before it finished (stopped → no finished check); relaunch.
        app.last = .some(nil)
        app.now = at(15, 0)
        let relaunched = DailyFileCheckScheduler(env: app.env)
        #expect(relaunched.tick() == .start(.launch))
        #expect(app.starts == 2)
        // A fresh check at relaunch: nothing owed, nothing started.
        app.last = .some(at(14, 50))
        let third = DailyFileCheckScheduler(env: app.env)
        #expect(third.tick() == .wait && !third.launchLookOwed)
        #expect(app.starts == 2)
    }

    @Test("ISOLATION: the freshness snapshot has not landed → judge nothing, start nothing, the launch look stays owed")
    func snapshotNotLanded() {
        let app = FakeDailyCheckApp()
        app.last = nil
        let s = DailyFileCheckScheduler(env: app.env)
        #expect(s.tick() == .wait)
        #expect(app.starts == 0 && s.launchLookOwed && app.notes.isEmpty)
    }

    @Test("LOGGING: a refused start is said, never silent")
    func refusedStartIsSaid() {
        let app = FakeDailyCheckApp()
        app.refuse = true
        let s = DailyFileCheckScheduler(env: app.env)
        _ = s.tick()
        #expect(app.notes.last == "Validate Catalog refused to start — see its row in Media File Operations")
    }

    @Test("WRITER: a run started by the scheduler and Stopped leaves a PARTIAL outcome on disk, the Files line yellow (never green), and no restart this slot")
    func aStoppedRunIsPartialNotGreen() async throws {
        let scene = try ValidateScene.make("daily_stop", rows: 3); defer { scene.cleanup() }
        let app = FakeDailyCheckApp()
        var job: ValidateCatalogJob?
        app.onStart = {
            let j = scene.job()
            job = j
            j.start()
            j.cancel()                 // Rick presses Stop on the MFO row
        }
        let s = DailyFileCheckScheduler(env: app.env)
        await TestHostDrive.identified {
            #expect(s.tick() == .start(.slot))
            await job?.task?.value
        }
        let ran = try #require(job)
        #expect(ran.state == .cancelled, Comment(rawValue: "\(ran.state) — \(ran.subtitle)"))
        // The record on disk says it did not finish.
        let catalog = scene.sandbox.model.catalogStore.fileLocation
        let facts = CatalogFreshnessFactsReader.read(catalogFile: catalog)
        let presence = CatalogAuditPresenceFacts.from(facts.audit, switchedAt: facts.switchedAt)
        #expect(presence.outcome == .partial, "a stopped run reads as partial, never a finished check (\(presence.outcome))")
        #expect(facts.audit?.outcome == .stopped, "the record beside the catalog says stopped")
        let line = CatalogStatusLinesPolicy.files(facts, missing: MissingCopyCounts(), now: Date(), date: { _ in "D" })
        #expect(line.state == .yellow, Comment(rawValue: line.words))
        #expect(line.words.contains("the last check stopped part way"), Comment(rawValue: line.words))
        // The scheduler's own reading of the same evidence: no finished check.
        let filesRow = CatalogFreshnessRows.row(.filePresence, report: AnalyzeCoverageReport(), facts: facts, running: [])
        let integrityRow = CatalogFreshnessRows.row(.integrity, report: AnalyzeCoverageReport(), facts: facts, running: [])
        app.last = .some(DailyFileCheckPolicy.lastFinished(files: filesRow, integrity: integrityRow))
        #expect(app.last == .some(nil))
        app.now = at(5, 0)
        #expect(s.tick() == .wait, "not restarted this slot")
        #expect(app.starts == 1)
    }
}

// MARK: - Truth: a stale record never shows green

@Suite("Daily file check — truth")
@MainActor
struct DailyFileCheckTruthTests {

    @Test("TRUTH: a completed, all-present record finished 7 d 01 min ago, written to disk NOW (fresh mtime) → the Files line is yellow 'older than 7 days' and Catalog is not Synced; 25 h old → green")
    func aStaleRecordNeverShowsGreen() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dfc_\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let catalog = dir.appendingPathComponent("catalog.json")
        try Data("[]".utf8).write(to: catalog)
        let now = Date()
        func write(finished: Date) throws {
            let record = CatalogAuditRunRecord(startedAt: finished.addingTimeInterval(-60), finishedAt: finished, outcome: .completed,
                                               partial: false, counts: ["planned": 3, "present": 3])
            try CatalogAuditRunMarker.encoder.encode(record).write(to: dir.appendingPathComponent(CatalogAuditRunMarker.fileName))
        }
        func filesLine() -> CatalogStatusLine {
            let facts = CatalogFreshnessFactsReader.read(catalogFile: catalog.path)
            return CatalogStatusLinesPolicy.files(facts, missing: MissingCopyCounts(), now: now, date: { _ in "D" })
        }
        try write(finished: now.addingTimeInterval(-(7 * day + 60)))
        let stale = filesLine()
        #expect(stale.state == .yellow, Comment(rawValue: stale.words))
        #expect(stale.words.contains("older than 7 days"), Comment(rawValue: stale.words))
        let fresh = CatalogStatusLine(kind: .database, state: .green, words: "Integrity check passed")
        let content = CatalogStatusLine(kind: .content, state: .green, words: "Up to date")
        #expect(CatalogStatusLines(database: fresh, files: stale, content: content).catalog.words != "Synced")
        try write(finished: now.addingTimeInterval(-25 * hour))
        let dayOld = filesLine()
        #expect(dayOld.state == .green, "24 h passing alone no longer turns the Files line yellow: \(dayOld.words)")
    }
}

// MARK: - The 7-day reminder clocks (backup, sync)

@Suite("Catalog reminder clocks — backup and sync, 7 days")
struct CatalogReminderClockTests {

    @Test("6 d 23 h 59 min → fresh; exactly 7 days and after → remind; never → remind (backup) and no sync reminder (the chip already says never)")
    func boundaries() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        #expect(CatalogReminderClock.remindAfter == 7 * day)
        #expect(CatalogReminderClock.state(last: now.addingTimeInterval(-(7 * day - 60)), now: now) == .fresh)
        #expect(CatalogReminderClock.state(last: now.addingTimeInterval(-7 * day), now: now) == .remind)
        #expect(CatalogReminderClock.state(last: now.addingTimeInterval(-40 * day), now: now) == .remind, "no orange or red step")
        #expect(CatalogReminderClock.state(last: nil, now: now) == .remind)
        // Backup.
        #expect(CatalogReminderClock.backupReminder(last: now.addingTimeInterval(-day), now: now) == nil)
        #expect(CatalogReminderClock.backupReminder(last: now.addingTimeInterval(-8 * day), now: now)?.contains("reminder") == true)
        #expect(CatalogReminderClock.backupReminder(last: nil, now: now) == "No catalog backup yet — a reminder to make one.")
        // Sync.
        #expect(CatalogReminderClock.syncReminder(last: now.addingTimeInterval(-hour), now: now) == nil)
        #expect(CatalogReminderClock.syncReminder(last: now.addingTimeInterval(-8 * day), now: now)
                == "7 days or more since the last sync — check the master is reachable")
        #expect(CatalogReminderClock.syncReminder(last: nil, now: now) == nil)
        // Catalog Database Info's rows.
        #expect(CatalogReminderClock.infoSuffix(last: now.addingTimeInterval(-day), now: now).isEmpty)
        #expect(CatalogReminderClock.infoSuffix(last: now.addingTimeInterval(-8 * day), now: now) == " — 7 days or more ago; a reminder to check it")
        let backup = CatalogBackupFacts(at: now.addingTimeInterval(-8 * day), path: "/x", pathExists: true)
        #expect(CatalogDatabaseInfoLines.backup(backup, date: { _ in "D" }, now: now) == .known("D → /x — 7 days or more ago; a reminder to check it"))
        #expect(CatalogDatabaseInfoLines.backup(backup, date: { _ in "D" }, now: now.addingTimeInterval(-7 * day)) == .known("D → /x"))
    }
}

// MARK: - Sensors

@Suite("Daily file check — sensors")
struct DailyFileCheckSensorTests {

    static func code(_ name: String) throws -> String {
        SourceTree.strippingComments(try SourceTree.appSource(named: name))
    }

    @Test("SENSOR: one engine — the scheduler starts Validate Catalog through the center's startValidateCatalog and builds no job of its own")
    func oneEngine() throws {
        let src = try Self.code("DailyFileCheck.swift")
        #expect(src.contains("center.startValidateCatalog(model: model, marker: model.catalogAuditRunMarker)"))
        #expect(!src.contains("ValidateCatalogJob("), "no second code path to the check")
        #expect(!src.contains("CatalogAuditJob(") && !src.contains("VerifyCatalogJob("))
        #expect(!src.contains("extension VideoScanModel"), "rule 12: a feature store, not a model extension")
    }

    @Test("SENSOR: the app attaches the scheduler on the master only, never on a test host; the backup pill and sync chip read the reminder clock")
    func wiredOnTheMasterOnly() throws {
        let app = try Self.code("VideoScanApp.swift")
        #expect(app.contains("if !TestEnvironment.isTestHost && catalogSync.mode == .master {\n                            dailyFileCheck.attach(.live(model: catalogModel, center: fileOpsCenter))"))
        #expect(app.components(separatedBy: "dailyFileCheck.attach(").count == 2, "one attach")
        #expect(try Self.code("CatalogView+VolumeTable.swift").contains("CatalogReminderClock.state(last: model.lastBackupAt"))
        #expect(try Self.code("CatalogInfoWindow.swift").contains("CatalogReminderClock.syncReminder(last: sync.state.lastSuccessfulSync"))
    }
}
