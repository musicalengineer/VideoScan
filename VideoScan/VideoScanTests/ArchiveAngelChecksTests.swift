// ArchiveAngelChecksTests.swift
// Angel Checks (docs/archive_angel_wise_design.md §4): the background
// Verify Audio loop — one at a time, parked behind the person and other
// jobs, budgeted, once per record per launch, one log line per check —
// driven here with a fake job, a fake clock and counting closures. No
// ffmpeg, no catalog, no disk.

import Combine
import Foundation
import Testing
@testable import VideoScan

/// A Verify Audio stand-in whose state the test flips.
@MainActor
private final class FakeCheckJob: @MainActor MediaFileOperationJob {
    let id = UUID()
    let kind: MediaFileOperationKind = .verifyAudio
    let title: String
    var subtitle = ""
    var fraction: Double = 0
    var isIndeterminate = true
    let startedAt = Date()
    var finishedAt: Date?
    @Published var settable: MediaFileOperationState = .running
    var state: MediaFileOperationState { settable }
    init(title: String) { self.title = title }
    func cancel() { settable = .cancelled }
    func finish(_ s: MediaFileOperationState) { settable = s; finishedAt = Date() }
}

/// The world one test builds: ranked ids, facts, verdicts, the jobs
/// started, the log, and the knobs the loop consults.
@MainActor
private final class World {
    var ranked: [UUID] = []
    var facts: [UUID: ArchiveAngelCheckFacts] = [:]
    var verdicts: [UUID: (status: String, note: String)] = [:]
    var missingPaths: Set<String> = []
    var busy = false
    var readOnly = false
    var lastInteraction: CFAbsoluteTime?
    var clock: CFAbsoluteTime = 1_000_000
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var refuseStart = false
    var factsCalls = 0
    var started: [FakeCheckJob] = []
    var startedIDs: [UUID] = []
    var log: [String] = []

    func add(_ name: String, verified: Bool = false, audio: Bool = true, mounted: Bool = true,
             master: Bool = false, verdict: (String, String) = ("ok", "")) -> UUID {
        let id = UUID()
        ranked.append(id)
        facts[id] = ArchiveAngelCheckFacts(id: id, filename: name, fullPath: "/Volumes/T/\(name)",
                                           audioNotVerified: !verified, hasAudioTrack: audio,
                                           volumeMounted: mounted, onMasterArchive: master)
        verdicts[id] = verdict
        return id
    }

    func configuration() -> ArchiveAngelChecks.Configuration {
        let missing = missingPaths
        var cfg = ArchiveAngelChecks.Configuration(
            ranked: { [unowned self] in self.ranked },
            facts: { [unowned self] id in self.factsCalls += 1; return self.facts[id] },
            start: { [unowned self] id in
                if self.refuseStart { return nil }
                let job = FakeCheckJob(title: self.facts[id]?.filename ?? "?")
                self.started.append(job)
                self.startedIDs.append(id)
                return job
            },
            verdict: { [unowned self] id in self.verdicts[id] },
            isExternallyBusy: { [unowned self] in self.busy })
        cfg.fileExists = { path in !missing.contains(path) }
        cfg.lastInteraction = { [unowned self] in self.lastInteraction }
        cfg.isReadOnly = { [unowned self] in self.readOnly }
        cfg.now = { [now = self.now] in now }
        cfg.clock = { [unowned self] in self.clock }
        cfg.log = { [unowned self] line in self.log.append(line) }
        cfg.parkPollSeconds = 0.01
        cfg.debounceSeconds = 0
        cfg.jobPollMilliseconds = 5
        cfg.quietSeconds = 120
        return cfg
    }
}

private func settle(_ n: Int = 20) async {
    for _ in 0..<n { try? await Task.sleep(nanoseconds: 5_000_000) }
}

@Suite("Angel Checks — the pure pieces")
struct ArchiveAngelChecksPureTests {

    @Test("the queue reads facts for at most `lookahead` ids of a 100k ranked list, in rank order, skipping the checked and the ineligible")
    func queueIsBoundedByLookahead() {
        let ids = (0..<100_000).map { _ in UUID() }
        var calls = 0
        let checked: Set<UUID> = [ids[1]]
        let queue = ArchiveAngelChecks.queue(ranked: ids, lookahead: 20, checked: checked) { id in
            calls += 1
            let i = ids.firstIndex(of: id)!
            return ArchiveAngelCheckFacts(id: id, filename: "f\(i)", fullPath: "/Volumes/T/f\(i)",
                                          audioNotVerified: i != 2, hasAudioTrack: i != 3,
                                          volumeMounted: i != 4, onMasterArchive: i == 5)
        }
        #expect(calls == 19, "20 ids minus the one already checked")
        #expect(queue.map(\.filename) == (0..<20).filter { ![1, 2, 3, 4, 5].contains($0) }.map { "f\($0)" })
        #expect(ArchiveAngelChecks.queue(ranked: ids, lookahead: 0, checked: []) { _ in nil }.isEmpty)
    }

    @Test("ineligible reasons, in the order a person would hear them")
    func ineligible() {
        func f(verified: Bool = false, audio: Bool = true, mounted: Bool = true, master: Bool = false) -> String? {
            ArchiveAngelCheckFacts(id: UUID(), filename: "x", fullPath: "/x", audioNotVerified: !verified,
                                   hasAudioTrack: audio, volumeMounted: mounted, onMasterArchive: master).ineligibleReason
        }
        #expect(f() == nil)
        #expect(f(audio: false) == "no sound track")
        #expect(f(verified: true) == "sound already checked")
        #expect(f(master: true) == "in the Master Archive")
        #expect(f(mounted: false) == "drive not connected")
    }

    @Test("a settled job + the record's verdict → the log word")
    func outcomes() {
        typealias O = ArchiveAngelCheckOutcome
        #expect(ArchiveAngelChecks.outcome(of: .finished(summary: ""), verdict: ("ok", "")) == O.ok(note: ""))
        #expect(ArchiveAngelChecks.outcome(of: .finished(summary: ""), verdict: ("ok", "mono")) == O.ok(note: "mono"))
        #expect(ArchiveAngelChecks.outcome(of: .finished(summary: ""), verdict: ("damaged", "Damaged audio — invalid codec"))
                == O.damaged(note: "Damaged audio — invalid codec"))
        #expect(ArchiveAngelChecks.outcome(of: .finished(summary: ""), verdict: ("", "")) == O.failed(reason: "no verdict was recorded"))
        #expect(ArchiveAngelChecks.outcome(of: .finished(summary: ""), verdict: nil) == O.failed(reason: "the record left the catalog"))
        #expect(ArchiveAngelChecks.outcome(of: .failed(message: "Could not check"), verdict: ("ok", "")) == O.failed(reason: "Could not check"))
        #expect(ArchiveAngelChecks.outcome(of: .cancelled, verdict: ("ok", "")) == O.skipped(reason: "cancelled"))
        #expect(O.ok(note: "mono").logFragment == "ok (mono)")
        #expect(O.damaged(note: "x").logFragment == "damaged (x)")
        #expect(O.skipped(reason: "file not found").logFragment == "skipped (file not found)")
    }

    @Test("stalled = rows that still need a check and are not being checked")
    func stalled() {
        var a = ArchiveAngelRowFacts(id: UUID(), filename: "a.mov", fullPath: "/a", kind: .ready)
        a.audio = .notVerified
        var b = a; b.id = UUID(); b.isBeingChecked = true
        var c = a; c.id = UUID(); c.audio = .verifiedOK; c.audioVerifyStatus = "ok"
        let rows = ArchiveAngelListRowBuilder.rows([a, b, c])
        #expect(ArchiveAngelStalled.count(rows: rows, checking: []) == 1, "b's facts already say checking")
        #expect(ArchiveAngelStalled.count(rows: rows, checking: [a.id]) == 0)
    }
}

@Suite("Angel Checks — the loop", .serialized)
@MainActor
struct ArchiveAngelChecksLoopTests {

    @Test("one at a time: a second tick starts nothing while a check runs; the next starts when it settles; each logs one line")
    func oneAtATime() async {
        let w = World()
        let a = w.add("a.mov"), b = w.add("b.mov", verdict: ("damaged", "Damaged audio — one channel silent"))
        let checks = ArchiveAngelChecks()
        checks.configure(w.configuration(), enabled: true)
        checks.tick()
        await settle()
        #expect(w.started.count == 1 && w.startedIDs == [a])
        #expect(checks.runningID == a)
        #expect(checks.status == .checking(filename: "a.mov"))
        #expect(checks.checkingIDs == [a, b], "queued and running rows both say checking")
        checks.tick()
        await settle()
        #expect(w.started.count == 1, "nothing else starts while one runs")
        w.started[0].finish(.finished(summary: "ok"))
        await settle(40)
        #expect(w.startedIDs == [a, b])
        w.started[1].finish(.finished(summary: "done"))
        await settle(40)
        #expect(checks.status == .idle)
        #expect(checks.checkingIDs.isEmpty)
        #expect(w.log.filter { $0.hasPrefix("Archive Angel check: ") } ==
                ["Archive Angel check: a.mov — ok",
                 "Archive Angel check: b.mov — damaged (Damaged audio — one channel silent)"])
        #expect(checks.counts == .init(ok: 1, damaged: 1, failed: 0, skipped: 0))
        // Once per record per launch: the same list starts nothing more.
        await checks.tickAndWait()
        #expect(w.started.count == 2)
        #expect(checks.checkedThisLaunch == [a, b])
        checks.stop()
    }

    @Test("parked while another job uses the catalog, and while the person has been active within the quiet window")
    func parks() async {
        let w = World()
        _ = w.add("a.mov")
        let checks = ArchiveAngelChecks()
        w.busy = true
        checks.configure(w.configuration(), enabled: true)
        checks.tick()
        await settle()
        #expect(checks.status == .parked(reason: "another job is using the catalog"))
        #expect(w.started.isEmpty)
        w.busy = false
        w.lastInteraction = w.clock - 10   // touched 10 s ago; quiet window is 120 s
        await settle()
        #expect(checks.status == .parked(reason: "you are working"))
        #expect(w.started.isEmpty)
        w.clock += 200
        await settle()
        #expect(w.started.count == 1, "quiet for 200 s: the check starts")
        w.started[0].finish(.finished(summary: ""))
        await settle(40)
        checks.stop()
    }

    @Test("budgets: per hour (sliding window) and per launch — and the queue is cleared so no row claims a check that is not coming")
    func budgets() async {
        let w = World()
        for i in 0..<4 { _ = w.add("t\(i).mov") }
        var cfg = w.configuration()
        cfg.maxPerHour = 2
        let checks = ArchiveAngelChecks()
        checks.configure(cfg, enabled: true)
        checks.tick()
        await settle()
        w.started[0].finish(.finished(summary: ""))
        await settle(40)
        w.started[1].finish(.finished(summary: ""))
        await settle(40)
        #expect(w.started.count == 2)
        #expect(checks.status.isParked)
        if case .parked(let r) = checks.status { #expect(r.hasPrefix("2 checks this hour")) }
        #expect(checks.checkingIDs.isEmpty, "budget spent: no row says checking")
        checks.stop()

        let w2 = World()
        for i in 0..<3 { _ = w2.add("u\(i).mov") }
        var cfg2 = w2.configuration()
        cfg2.maxPerLaunch = 1
        let c2 = ArchiveAngelChecks()
        c2.configure(cfg2, enabled: true)
        c2.tick()
        await settle()
        w2.started[0].finish(.finished(summary: ""))
        await settle(40)
        #expect(w2.started.count == 1)
        #expect(c2.status == .parked(reason: "1 checks this launch — more after a relaunch"))
        #expect(c2.checkingIDs.isEmpty)
        c2.stop()
    }

    @Test("skips: a missing file is logged and never started; a refused start is logged; neither is retried this launch")
    func skips() async {
        let w = World()
        let gone = w.add("gone.mov"), ok = w.add("here.mov")
        w.missingPaths = ["/Volumes/T/gone.mov"]
        let checks = ArchiveAngelChecks()
        checks.configure(w.configuration(), enabled: true)
        checks.tick()
        await settle()
        #expect(w.startedIDs == [ok])
        #expect(w.log.contains("Archive Angel check: gone.mov — skipped (file not found)"))
        w.started[0].finish(.finished(summary: ""))
        await settle(40)
        #expect(checks.checkedThisLaunch == [gone, ok])
        checks.stop()

        let w2 = World()
        _ = w2.add("busy.mov")
        w2.refuseStart = true
        let c2 = ArchiveAngelChecks()
        c2.configure(w2.configuration(), enabled: true)
        await c2.tickAndWait()
        #expect(w2.log.contains("Archive Angel check: busy.mov — skipped (a verify job for this file is already running)"))
        #expect(c2.counts.skipped == 1 && c2.status == .idle)
    }

    @Test("off: disabled or read-only starts nothing; a summary line every N checks")
    func offAndSummary() async {
        let w = World()
        _ = w.add("a.mov")
        let checks = ArchiveAngelChecks()
        checks.configure(w.configuration(), enabled: false)
        checks.tick()
        await settle()
        #expect(w.started.isEmpty && checks.status == .disabled)
        w.readOnly = true
        checks.setEnabled(true)
        await settle()
        #expect(w.started.isEmpty && checks.status == .idle)
        checks.stop()

        let w2 = World()
        _ = w2.add("a.mov"); _ = w2.add("b.mov")
        var cfg = w2.configuration()
        cfg.summaryEvery = 2
        let c2 = ArchiveAngelChecks()
        c2.configure(cfg, enabled: true)
        c2.tick()
        await settle()
        w2.started[0].finish(.finished(summary: ""))
        await settle(40)
        w2.started[1].finish(.failed(message: "Could not check the audio — ffprobe died"))
        await settle(40)
        #expect(w2.log.last == "Archive Angel checks: 2 so far this launch — 1 ok · 0 damaged · 1 failed · 0 skipped")
        #expect(w2.log.contains("Archive Angel check: b.mov — failed (Could not check the audio — ffprobe died)"))
        c2.stop()
    }
}
