// ArchiveAngelChecks.swift
// Angel Checks — the Archive Angel does the checking before it asks
// (docs/archive_angel_wise_design.md §4; Rick 2026-09-24: "if we already
// know we recommend 20 files and they all need audio balancing, can we do
// that for the user or are we going to make him do it?"). Measured the
// same day: 111 of the 113 recommended files had never been through Verify
// Audio, so every row said "Needs audio checked".
//
// The loop: take the top `lookahead` recommendations, keep the ones whose
// sound was never checked, whose drive is mounted, that are not in the
// Master Archive and whose file exists (stat off-main), and run the
// ORDINARY Verify Audio job on them ONE AT A TIME — a read that writes
// the verdict onto the record (audioVerifyStatus/Note/Date), nothing
// else. The verdict lands, the façade recounts, the row becomes "Ready to
// archive" or "Needs audio repair".
//
// Pacing (in code, never in policy.json — the policy says WHAT to
// recommend, not how the machine paces itself):
//   • one check at a time (the per-volume MediaVolumeGate does the rest);
//   • a check STARTS only while no scan / Angel / Promote job runs and the
//     person has been quiet for `quietSeconds` (120 s — this reads bytes,
//     so it waits longer than the 3 s scoring sweep); a running check is
//     allowed to finish;
//   • `maxPerHour` (12) in a sliding window, `maxPerLaunch` (200), and at
//     most once per record per launch (a failed verify persists nothing —
//     the existing "couldn't check is not a verdict" rule — so it is not
//     retried until relaunch).
// Every check logs ONE line (console + videoscan.log):
//   Archive Angel check: <file> — ok | damaged (<note>) | failed (<why>) | skipped (<why>)
// and every ten checks a summary line with the counts.
//
// Sibling of ArchiveAngelSweep in shape: a Configuration of closures (so
// the tests drive it with a fake job and a fake clock), a @Published
// status with `line`, enable/disable, `stop()`. Nothing here touches the
// catalog directly — the closures are filled by the façade from the seams.
//
// (For Rick: a small state machine driven by one Task at a time; the
// `Configuration` struct is the dependency-injection seam, like passing a
// struct of function pointers to a C module.)

import Combine
import Foundation
import os

private let checksLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "archiveAngelChecks")

// MARK: - What one candidate looks like to the loop

/// The facts the loop needs about one recommended record — a value
/// snapshot the façade takes on the main actor (O(1) per record).
struct ArchiveAngelCheckFacts: Sendable, Equatable {
    var id: UUID
    var filename: String
    var fullPath: String
    /// ArchiveReadiness says the sound track was never verified.
    var audioNotVerified: Bool
    /// The stream has a sound track at all (video-only files have nothing to check).
    var hasAudioTrack: Bool
    /// The drive is in the mount table (never a stat).
    var volumeMounted: Bool
    /// Inside the Master Archive — never touched by a check.
    var onMasterArchive: Bool

    /// Why this record is not a check candidate, or nil when it is.
    var ineligibleReason: String? {
        if !hasAudioTrack { return "no sound track" }
        if !audioNotVerified { return "sound already checked" }
        if onMasterArchive { return "in the Master Archive" }
        if !volumeMounted { return "drive not connected" }
        return nil
    }
}

/// How one check ended — the word in the log line.
enum ArchiveAngelCheckOutcome: Equatable, Sendable {
    case ok(note: String)
    case damaged(note: String)
    case failed(reason: String)
    case skipped(reason: String)

    var logFragment: String {
        switch self {
        case .ok(let note): return note.isEmpty ? "ok" : "ok (\(note))"
        case .damaged(let note): return "damaged (\(note))"
        case .failed(let reason): return "failed (\(reason))"
        case .skipped(let reason): return "skipped (\(reason))"
        }
    }
}

// MARK: - Status

enum ArchiveAngelChecksStatus: Equatable, Sendable {
    case disabled
    case idle
    case checking(filename: String)
    case parked(reason: String)

    var line: String {
        switch self {
        case .disabled: return "Archive Angel checks are off"
        case .idle: return "Archive Angel checks: idle"
        case .checking(let f): return "Archive Angel checks: checking the sound of \(f)…"
        case .parked(let r): return "Archive Angel checks: waiting — \(r)"
        }
    }

    var isParked: Bool { if case .parked = self { return true } else { return false } }
}

// MARK: - The loop

@MainActor
final class ArchiveAngelChecks: ObservableObject {

    struct Configuration {
        /// The façade's ranked recommendations (Ready, then Needs a date,
        /// then Worth a look). Only the first `lookahead` are ever read.
        var ranked: @MainActor () -> [UUID]
        /// A snapshot of one record; nil when it left the catalog.
        var facts: @MainActor (UUID) -> ArchiveAngelCheckFacts?
        /// Does the file exist? Runs OFF the main actor (a stat on a
        /// spun-down disk can take seconds).
        var fileExists: @Sendable (String) async -> Bool = { path in
            await Task.detached(priority: .utility) { FileManager.default.fileExists(atPath: path) }.value
        }
        /// Start the Verify Audio job for one record; nil = refused.
        var start: @MainActor (UUID) -> (any MediaFileOperationJob)?
        /// The LIVE record's verdict after the job ended: (status, note)
        /// — "ok" / "damaged" / "" (nothing persisted). nil = record gone.
        var verdict: @MainActor (UUID) -> (status: String, note: String)?
        /// Scan / Angel / Promote running — never START a check.
        var isExternallyBusy: @MainActor () -> Bool
        /// ANY Media File Operations job is active (QA 2026-09-25 MAJOR-2).
        /// Before a start no check of ours is running, so an active job is
        /// someone else's — Rick's own Verify, Balance, Transcode — and a
        /// background read must not queue up beside it.
        var isAnyJobActive: @MainActor () -> Bool = { false }
        /// The person's last interaction (CFAbsoluteTime); nil = never.
        var lastInteraction: @MainActor () -> CFAbsoluteTime? = { nil }
        /// A read-only viewer never verifies (it cannot persist a verdict).
        var isReadOnly: @MainActor () -> Bool = { false }
        var lookahead = 20
        var quietSeconds: Double = 120
        var maxPerHour = 12
        var maxPerLaunch = 200
        var parkPollSeconds: Double = 5
        var debounceSeconds: Double = 2
        var jobPollMilliseconds = 500
        /// Summary line cadence.
        var summaryEvery = 10
        var now: @Sendable () -> Date = { Date() }
        var clock: @MainActor () -> CFAbsoluteTime = { CFAbsoluteTimeGetCurrent() }
        /// Console + videoscan.log — one line per check, one per ten.
        var log: @MainActor (String) -> Void = { _ in }
    }

    struct Counts: Equatable, Sendable {
        var ok = 0, damaged = 0, failed = 0, skipped = 0
        var total: Int { ok + damaged + failed + skipped }
        var line: String { "\(ok) ok · \(damaged) damaged · \(failed) failed · \(skipped) skipped" }
    }

    @Published private(set) var status: ArchiveAngelChecksStatus = .idle
    /// Queued-or-running: the rows that may say "Checking the sound…".
    /// Empty while the budget is spent (a row must not claim a check that
    /// is not coming).
    @Published private(set) var checkingIDs: Set<UUID> = []
    @Published private(set) var counts = Counts()
    /// Records this launch already checked (or skipped) — never twice.
    private(set) var checkedThisLaunch: Set<UUID> = []
    /// Checks actually STARTED this launch — what `maxPerLaunch` counts
    /// (QA MINOR-6: a skip reads nothing, so it costs nothing).
    private(set) var startedThisLaunch = 0
    /// Start times inside the sliding hour (`maxPerHour`).
    private(set) var startTimes: [Date] = []
    /// The check in flight, if any.
    private(set) var runningID: UUID?

    private var configuration: Configuration?
    private var enabled = false
    private var debounceTask: Task<Void, Never>?
    private var loopTask: Task<Void, Never>?
    /// The live loop's token (QA MAJOR-3). `stop()` / off clear it; a loop
    /// whose token is no longer current exits at its next await without
    /// touching any state, and its continuation never clears a newer
    /// loop's handle. (≈ a generation counter guarding a worker thread.)
    private var loopToken: UUID?
    private var rerunRequested = false

    init() {}

    // MARK: Configure / enable

    func configure(_ configuration: Configuration, enabled: Bool) {
        self.configuration = configuration
        setEnabled(enabled)
    }

    var isEnabled: Bool { enabled }

    func setEnabled(_ on: Bool) {
        enabled = on
        if !on {
            debounceTask?.cancel(); debounceTask = nil
            // A running check finishes on its own (it is an ordinary job);
            // the loop just stops picking.
            abandonLoop()
            status = .disabled
        } else if loopTask == nil {
            status = .idle
            noteRecommendationsChanged()
        }
    }

    /// Stop everything (teardown / tests). The in-flight job is left to
    /// its own lifecycle.
    func stop() {
        debounceTask?.cancel(); debounceTask = nil
        abandonLoop()
        status = enabled ? .idle : .disabled
    }

    /// End the live loop: its token goes stale (it exits at its next await
    /// and writes nothing), the rows stop claiming a check.
    private func abandonLoop() {
        loopToken = nil
        loopTask?.cancel(); loopTask = nil
        rerunRequested = false
        runningID = nil
        checkingIDs = []
    }

    /// Is the loop holding `token` still the live one?
    private func isLive(_ token: UUID) -> Bool {
        !Task.isCancelled && enabled && loopToken == token
    }

    // MARK: Triggers

    /// The façade published a new recommendation summary: look again,
    /// after a short debounce (a burst of recounts is one look).
    func noteRecommendationsChanged() {
        guard enabled, let cfg = configuration else { return }
        debounceTask?.cancel()
        let delay = max(0, cfg.debounceSeconds)
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.tick()
        }
    }

    /// Pick the next candidate now (idempotent: a loop in flight is asked
    /// to look again when it finishes).
    func tick() {
        guard enabled, configuration != nil else { return }
        if loopTask != nil { rerunRequested = true; return }
        let token = UUID()
        loopToken = token
        loopTask = Task { [weak self] in
            await self?.performLoop(token)
            // Only the live loop clears the handle (QA MAJOR-3: a stale
            // continuation used to nil a NEWER loop's handle → two loops).
            guard let self, self.loopToken == token else { return }
            self.loopTask = nil
            self.loopToken = nil
            if self.rerunRequested {
                self.rerunRequested = false
                self.tick()
            }
        }
    }

    /// Awaitable form for tests: runs until the loop has nothing to do.
    func tickAndWait() async {
        tick()
        await loopTask?.value
    }

    // MARK: The loop

    /// Every await is followed by `isLive(token)`: a loop that was stopped,
    /// turned off or superseded while it waited returns WITHOUT touching
    /// state (whoever stopped it already set the status) and never starts
    /// a job (QA MAJOR-3; qwen on e11c815c).
    private func performLoop(_ token: UUID) async {
        while isLive(token), let cfg = configuration {
            guard !cfg.isReadOnly() else {
                checkingIDs = []
                status = .idle
                return
            }
            // The queue: the first `lookahead` ranked ids that qualify —
            // rebuilt on every pass, never reused across a wait.
            let queue = Self.queue(ranked: cfg.ranked(), lookahead: cfg.lookahead,
                                   checked: checkedThisLaunch, facts: cfg.facts)
            guard !queue.isEmpty else {
                checkingIDs = []
                status = .idle
                return
            }
            switch budget(cfg) {
            case .launchSpent:
                return
            case .wait(let seconds):
                // QA MINOR-5: after the hour's wait the queue is REBUILT (a
                // file verified by hand meanwhile is not read again). The
                // sleep throws on cancel, so stop()/off end it at once.
                do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) } catch { return }
                continue
            case .allowed:
                break
            }
            checkingIDs = Set(queue.map(\.id))
            guard await parkedUntilFree(cfg, token) else { return }
            // Take the first whose file is really there (stat off-main).
            let present = await firstPresent(in: queue, cfg: cfg, token: token)
            guard isLive(token) else { return }
            guard let f = present else { continue }
            guard let job = cfg.start(f.id) else {
                record(f, outcome: .skipped(reason: "a verify job for this file is already running"), cfg: cfg)
                continue
            }
            guard await run(f, job: job, cfg: cfg, token: token) else { return }
            // Loop: the recount the verdict triggered may have reordered the
            // list; the queue is rebuilt from `ranked` at the top.
        }
    }

    enum Budget: Equatable { case allowed, launchSpent, wait(seconds: Double) }

    /// Budgets — a row must not say "checking" for a check that is not
    /// coming, so the queue is cleared while a budget is spent. Per launch
    /// (checks STARTED, not skips — QA MINOR-6): done until relaunch. Per
    /// hour: the seconds until the sliding window frees.
    private func budget(_ cfg: Configuration) -> Budget {
        if startedThisLaunch >= cfg.maxPerLaunch {
            checkingIDs = []
            status = .parked(reason: "\(cfg.maxPerLaunch) checks this launch — more after a relaunch")
            return .launchSpent
        }
        let now = cfg.now()
        startTimes.removeAll { now.timeIntervalSince($0) >= 3600 }
        guard startTimes.count >= cfg.maxPerHour, let oldest = startTimes.min() else { return .allowed }
        checkingIDs = []
        let wait = max(1, 3600 - now.timeIntervalSince(oldest))
        status = .parked(reason: "\(cfg.maxPerHour) checks this hour — next in \(Int(wait / 60) + 1) min")
        return .wait(seconds: wait)
    }

    /// Why a check may not START now, or nil. Order: other jobs first
    /// (they are reading a disk), then the person.
    private static func parkReason(_ cfg: Configuration) -> String? {
        if cfg.isExternallyBusy() { return "another job is using the catalog" }
        if cfg.isAnyJobActive() { return "another file operation is running" }
        if interacting(cfg) { return "you are working" }
        return nil
    }

    /// Park while the app is busy or the person is working. False when
    /// the loop stopped meanwhile.
    private func parkedUntilFree(_ cfg: Configuration, _ token: UUID) async -> Bool {
        while let reason = Self.parkReason(cfg) {
            status = .parked(reason: reason)
            do {
                try await Task.sleep(nanoseconds: UInt64(max(0.01, cfg.parkPollSeconds) * 1_000_000_000))
            } catch { return false }
            if !isLive(token) { return false }
        }
        return true
    }

    /// The first queued file that exists on disk; the missing ones are
    /// skipped (logged, once per launch). nil when none, or when the loop
    /// stopped during a stat (the caller checks `isLive`).
    private func firstPresent(in queue: [ArchiveAngelCheckFacts], cfg: Configuration,
                              token: UUID) async -> ArchiveAngelCheckFacts? {
        for f in queue {
            let exists = await cfg.fileExists(f.fullPath)
            // The stat is detached and ignores cancellation: re-check.
            guard isLive(token) else { return nil }
            if exists { return f }
            record(f, outcome: .skipped(reason: "file not found"), cfg: cfg)
        }
        return nil
    }

    /// One check: wait for the ordinary job to settle, read the verdict,
    /// log. False when the loop stopped meanwhile (the job runs on — it is
    /// an ordinary MFO job the person can see and cancel).
    private func run(_ f: ArchiveAngelCheckFacts, job: any MediaFileOperationJob, cfg: Configuration,
                     token: UUID) async -> Bool {
        runningID = f.id
        checkedThisLaunch.insert(f.id)
        startedThisLaunch += 1
        startTimes.append(cfg.now())
        status = .checking(filename: f.filename)
        checksLog.info("check START: \(f.filename, privacy: .public)")
        while job.state.isActive {
            do {
                try await Task.sleep(nanoseconds: UInt64(max(1, cfg.jobPollMilliseconds)) * 1_000_000)
            } catch { return false }
            guard isLive(token) else { return false }
        }
        let outcome = Self.outcome(of: job.state, verdict: cfg.verdict(f.id))
        runningID = nil
        checkingIDs.remove(f.id)
        note(f, outcome: outcome, cfg: cfg)
        return true
    }

    /// A skip that costs nothing: counted once per launch, logged, no job.
    private func record(_ f: ArchiveAngelCheckFacts, outcome: ArchiveAngelCheckOutcome, cfg: Configuration) {
        checkedThisLaunch.insert(f.id)
        checkingIDs.remove(f.id)
        note(f, outcome: outcome, cfg: cfg)
    }

    private func note(_ f: ArchiveAngelCheckFacts, outcome: ArchiveAngelCheckOutcome, cfg: Configuration) {
        switch outcome {
        case .ok: counts.ok += 1
        case .damaged: counts.damaged += 1
        case .failed: counts.failed += 1
        case .skipped: counts.skipped += 1
        }
        let line = "Archive Angel check: \(f.filename) — \(outcome.logFragment)"
        checksLog.info("\(line, privacy: .public)")
        cfg.log(line)
        if cfg.summaryEvery > 0, counts.total % cfg.summaryEvery == 0 {
            cfg.log("Archive Angel checks: \(counts.total) so far this launch — \(counts.line)")
        }
    }

    // MARK: Pure pieces (table-tested)

    /// The first `lookahead` ranked ids that qualify, in rank order. Reads
    /// `facts` for at most `lookahead` ids (O(lookahead), never O(ranked)).
    nonisolated static func queue(ranked: [UUID], lookahead: Int, checked: Set<UUID>,
                                  facts: (UUID) -> ArchiveAngelCheckFacts?) -> [ArchiveAngelCheckFacts] {
        var out: [ArchiveAngelCheckFacts] = []
        for id in ranked.prefix(max(0, lookahead)) where !checked.contains(id) {
            guard let f = facts(id), f.ineligibleReason == nil else { continue }
            out.append(f)
        }
        return out
    }

    /// The log word for a settled job + what the record says now.
    nonisolated static func outcome(of state: MediaFileOperationState,
                                    verdict: (status: String, note: String)?) -> ArchiveAngelCheckOutcome {
        switch state {
        case .failed(let message): return .failed(reason: message)
        case .cancelled, .cancelling: return .skipped(reason: "cancelled")
        case .running: return .failed(reason: "the check did not settle")
        case .finished: return verdictOutcome(verdict)
        }
    }

    /// The finished job's word: what the record says now.
    nonisolated static func verdictOutcome(_ verdict: (status: String, note: String)?) -> ArchiveAngelCheckOutcome {
        guard let v = verdict else { return .failed(reason: "the record left the catalog") }
        switch v.status {
        case "ok": return .ok(note: v.note)
        case "damaged": return .damaged(note: v.note)
        default: return .failed(reason: "no verdict was recorded")
        }
    }

    private static func interacting(_ cfg: Configuration) -> Bool {
        guard let last = cfg.lastInteraction() else { return false }
        return cfg.clock() - last < cfg.quietSeconds
    }
}

// MARK: - The "working hard enough" number

/// Stalled = recommended rows on the page whose sound was never checked
/// and that the checker is not handling (docs/archive_angel_wise_design.md
/// §1 Q5, §6). Target 0. Pure, O(rows shown).
enum ArchiveAngelStalled {
    static func count(rows: [ArchiveAngelListRow], checking: Set<UUID>) -> Int {
        rows.reduce(0) { n, row in
            row.needs.contains(.audioCheck) && !checking.contains(row.id) ? n + 1 : n
        }
    }
}
