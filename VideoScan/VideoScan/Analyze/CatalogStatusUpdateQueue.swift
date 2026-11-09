// CatalogStatusUpdateQueue.swift
// "Update everything stale" (Rick 2026-10-16, Catalog Status freshness
// §2 / §2.1): the yellow kinds started ONE AT A TIME through the existing
// runner. Nothing new runs — each kind's Run now is the same entry point
// the row's button uses; the center's own conflict rule (one audit / one
// hash run / one sound run at a time) still applies underneath. This is the
// chain's ONE definition (CLAUDE.md rule 4): the band's button and the
// Catalog Status window's both call `enqueue`.
//
// ORDER (GH #441, Rick 2026-11-06: "a user, looking at the catalog, sees
// red, thinks the DB is screwed up … the order in which we do things should
// be more natural"): `plan` runs every step that GATHERS evidence or
// REBUILDS what the catalog check judges (full hashes, sound prints,
// duplicate groups, likeness, captions, A/V pairs, signatures, dates) FIRST,
// in registry order, and the catalog check (Validate Catalog: the files on
// disk, then tiers 0–6) ONCE, LAST — added when it was not stale, so the
// colour an Update leaves describes the catalog the Update left. On 11/06 the
// check ran second, found 262 sampled-hash groups whose members now carried
// different whole-file digests, turned Catalog red, and Detect Duplicates
// fixed every one a second later; the red stood until the next check.
// While the queue is active the Catalog indicator reads grey "Checking…"
// (CatalogFreshnessSnapshot.observeUpdate); the last step's verdict colours it.
//
// Shape: a tiny main-actor state machine with a 1 s poll. The loop starts
// the next kind when the current one is no longer running (the runner's
// isRunning — the same flags the panel samples). A `graceSeconds` window
// after each start lets an engine whose flag flips a beat later (the dossier
// queue) be seen as running before the poll moves on. Model-owned so it
// outlives the panel window. Memory: two arrays of at most 13 enum values.
//
// LOGGING (rule 5): ONE START line naming the steps in order, ONE OUTCOME
// line when the queue drains (what ran, whether the check ran last), both
// through the runner's sink (console + catalog.log + videoscan.log); each
// step writes its own START / OUTCOME as it always did.
//
// (For Rick: `Task { while … { try? await Task.sleep } }` ≈ a worker
// thread with a sleep loop, except it runs on the main actor between
// sleeps, so the state needs no mutex. `any CatalogUpdateStepRunning` ≈ a
// pointer to an abstract base class — the app hands the real AnalyzeRunner,
// a test hands a scripted one.)

import Combine
import Foundation

/// What the queue needs from whoever runs a step: start it, say whether it
/// is still running, and write a line to the one log sink.
@MainActor
protocol CatalogUpdateStepRunning {
    /// Start the step; false when it was refused (busy, unavailable) — it
    /// did not start, and the refusal was logged by the engine.
    @discardableResult
    func runNow(_ cycler: AnalyzeCycler, volume: String?, source: String) -> Bool
    func isRunning(_ cycler: AnalyzeCycler) -> Bool
    func note(_ line: String)
    /// Land every pending catalog write (the debounced save) through the one
    /// commit door and return its acknowledgment — called before the
    /// catalog check, so the check judges what the earlier steps wrote.
    func flushCatalog() -> Bool
    /// After a started step ends: did it actually run? An engine may refuse
    /// inside its own task after `runNow` returned (Validate Catalog on a
    /// read-only catalog) — Codex sweep 11/09 re-review F5.
    func stepRan(_ cycler: AnalyzeCycler) -> Bool
}

extension AnalyzeRunner: CatalogUpdateStepRunning {
    func note(_ line: String) {
        model.log(line)
        appLog.write(line)
    }

    func flushCatalog() -> Bool { model.saveCatalogNow() }

    func stepRan(_ cycler: AnalyzeCycler) -> Bool {
        guard cycler == .integrity else { return true }
        // No evidence is not proof: fail closed (closing pass C3).
        guard let job = refusal.lastValidate else { return false }
        return !job.wasRefused
    }
}

@MainActor
final class CatalogStatusUpdateQueue: ObservableObject {

    /// Kinds still waiting, in start order.
    @Published private(set) var pending: [AnalyzeCycler] = []
    /// The kind started last and not yet seen finished.
    @Published private(set) var current: AnalyzeCycler?

    var graceSeconds: TimeInterval = 2
    var pollMilliseconds = 1_000

    private var runner: (any CatalogUpdateStepRunning)?
    private var startedAt = Date.distantPast
    private var loop: Task<Void, Never>?
    /// The steps started in this run, in order (the OUTCOME line).
    private var started: [AnalyzeCycler] = []
    /// True when Stop cleared steps that had not started.
    private var cleared = false
    /// What became of the LAST catalog check this run asked for — the
    /// OUTCOME's claim comes from here only (F3, F5; re-review: a later
    /// refused check is never covered by an earlier one that ran).
    private enum CheckState: Equatable { case started, ran, notRun(String) }
    private var lastCheck: CheckState?
    /// Steps that were refused (not started, not already running) — named in the OUTCOME (re-review N2).
    private var refused: [AnalyzeCycler] = []
    /// `current` is a step the queue did NOT start: it was already running
    /// when its turn came (re-review N1) — waited for, never "started".
    private var currentIsElsewhere = false
    /// The queue waited for a writer it did not start: its save must be
    /// flushed before the check too (closing pass C5).
    private var waitedOnWriter = false
    private var saidWaitingForWriter = false
    /// The "waiting for a check started elsewhere" line, said once per wait.
    private var saidWaiting = false

    static let source = "update everything stale"
    static let logPrefix = "Catalog status: update everything stale"

    init() {}

    var isActive: Bool { current != nil || !pending.isEmpty }

    // MARK: The order (pure)

    /// The catalog check (Validate Catalog: files on disk, then tiers 0–6).
    static let finalCheck = AnalyzeCycler.integrity

    /// Every kind but the check in registry order (the three evidence
    /// gatherers lead the registry), then the check.
    static let order: [AnalyzeCycler] = AnalyzeCycler.allCases.filter { $0 != finalCheck } + [finalCheck]

    /// The steps an Update runs for `kinds`: duplicates dropped, every step
    /// that feeds or rebuilds what the check judges first, and the check
    /// ONCE, LAST — added when `kinds` did not name it. Nothing asked →
    /// nothing run.
    static func plan(_ kinds: [AnalyzeCycler]) -> [AnalyzeCycler] {
        guard !kinds.isEmpty else { return [] }
        let asked = Set(kinds).union([finalCheck])
        return order.filter(asked.contains)
    }

    // MARK: Enqueue / clear

    /// Queue `kinds` in `plan` order (a kind already queued is not queued
    /// twice) and start the loop if idle. A kind in flight is not queued
    /// again — except the check: steps added while it runs change what it
    /// would judge, so it runs once more after them.
    func enqueue(_ kinds: [AnalyzeCycler], runner: any CatalogUpdateStepRunning, source: String) {
        self.runner = runner
        let wasActive = isActive
        let before = pending
        pending = Self.plan(pending + kinds.filter { $0 != current })
        guard !pending.isEmpty, pending != before else { return }
        if !wasActive {
            started = []
            cleared = false
            runner.note("\(Self.logPrefix) — START — \(pending.count) step(s), in order: \(Self.titles(pending)); "
                        + "the catalog check runs once, last (\(source))")
        } else {
            runner.note("\(Self.logPrefix) — added (\(source)); still to run, in order: \(Self.titles(pending))")
        }
        if loop == nil { loop = Task { [weak self] in await self?.run() } }
    }

    /// Drop what has not started; the kind in flight keeps running (its
    /// own row has Pause / Stop). If the check was still waiting, the
    /// OUTCOME line says it did not run.
    func clearPending() {
        guard !pending.isEmpty else { return }
        pending.removeAll()
        cleared = true
        if current == nil { finish() }
    }

    // MARK: The loop

    private func run() async {
        defer { loop = nil }
        advanceIfIdle()
        while isActive {
            try? await Task.sleep(for: .milliseconds(pollMilliseconds))
            if Task.isCancelled { return }
            advanceIfIdle()
        }
    }

    /// Start the next kind when nothing from this queue is running.
    func advanceIfIdle(now: Date = Date()) {
        guard let runner else { pending.removeAll(); current = nil; return }
        if let c = current {
            let inGrace = now.timeIntervalSince(startedAt) < graceSeconds
            guard !inGrace, !runner.isRunning(c) else { return }
            current = nil
            stepEnded(c, runner: runner)
        }
        guard !pending.isEmpty else {
            if hasSomethingToReport { finish() }
            return
        }
        guard !waitsForACheckElsewhere(runner), !checkWaitsForAWriter(runner) else { return }
        let next = pending.removeFirst()
        // The check judges what the earlier steps wrote — this queue's or a
        // writer it waited for (closing pass C5): their debounced save lands
        // first, acknowledged, or the check does not run (F3).
        if next == Self.finalCheck, !started.isEmpty || waitedOnWriter, !runner.flushCatalog() {
            notStarted(next, why: "the catalog could not be saved first")
            return
        }
        startedAt = now
        guard runner.runNow(next, volume: nil, source: Self.source) else { return startRefused(next, runner: runner) }
        current = next
        started.append(next)
        if next == Self.finalCheck { lastCheck = .started }
    }

    private var hasSomethingToReport: Bool { !started.isEmpty || cleared || lastCheck != nil || !refused.isEmpty }

    /// What the end of a step proves: for the catalog check, ask the engine
    /// whether it actually ran — it may refuse inside its own task after
    /// runNow returned (re-review F5). A step the queue only waited for
    /// (already running elsewhere) proves nothing about this run.
    private func stepEnded(_ c: AnalyzeCycler, runner: any CatalogUpdateStepRunning) {
        if c == Self.finalCheck, !currentIsElsewhere, lastCheck == .started {
            lastCheck = runner.stepRan(c) ? .ran : .notRun("it was refused — see its line above")
        }
        currentIsElsewhere = false
    }

    /// The barrier against a catalog check (or file audit) this queue did
    /// not start — the 03:30 daily check, a menu item: no step starts beside
    /// it (Codex sweep 11/09 F2). Said once per wait.
    private func waitsForACheckElsewhere(_ runner: any CatalogUpdateStepRunning) -> Bool {
        guard let elsewhere = [Self.finalCheck, AnalyzeCycler.filePresence].first(where: runner.isRunning) else {
            saidWaiting = false
            return false
        }
        if !saidWaiting {
            runner.note("\(Self.logPrefix) — waiting: \(elsewhere.title) is already running; the next step starts when it ends")
            saidWaiting = true
        }
        return true
    }

    /// The check never starts beside a writer running elsewhere, whether or
    /// not this Update asked for it (closing pass C4: a running kind is not
    /// "stale", so it is not in the plan). Said once per wait.
    private func checkWaitsForAWriter(_ runner: any CatalogUpdateStepRunning) -> Bool {
        guard pending.first == Self.finalCheck,
              let writer = AnalyzeCycler.allCases.first(where: { $0 != Self.finalCheck && runner.isRunning($0) }) else {
            saidWaitingForWriter = false
            return false
        }
        waitedOnWriter = true
        if !saidWaitingForWriter {
            runner.note("\(Self.logPrefix) — waiting: \(writer.title) is running; the catalog check starts when it ends")
            saidWaitingForWriter = true
        }
        return true
    }

    /// runNow refused. Already running (started from the panel): its run is
    /// still the barrier — wait for it, never counted as started (re-review
    /// N1, #441's order). Otherwise it did not run (F5) and is named (N2).
    private func startRefused(_ next: AnalyzeCycler, runner: any CatalogUpdateStepRunning) {
        if runner.isRunning(next) {
            current = next
            currentIsElsewhere = true
            waitedOnWriter = true
            runner.note("\(Self.logPrefix) — \(next.title) is already running; waiting for it before the next step")
            return
        }
        refused.append(next)
        notStarted(next, why: "it was refused — see its line above")
    }

    /// A step that will not run: the check's claim records why; the run
    /// ends when nothing is left.
    private func notStarted(_ next: AnalyzeCycler, why: String) {
        if next == Self.finalCheck { lastCheck = .notRun(why) }
        if pending.isEmpty { finish() }
    }

    /// The one OUTCOME line; resets the run's bookkeeping.
    private func finish() {
        defer { started = []; cleared = false; lastCheck = nil; refused = []; saidWaiting = false; currentIsElsewhere = false; waitedOnWriter = false; saidWaitingForWriter = false }
        guard let runner, hasSomethingToReport else { return }
        // "Ran last" only on evidence: the last check asked for started,
        // ended, and the engine says it ran — and nothing started after it.
        let ranLast = lastCheck == .ran && started.last == Self.finalCheck
        let why: String
        if case .notRun(let reason) = lastCheck { why = " — \(reason)" } else { why = cleared ? " (the steps left were cleared)" : "" }
        let tail = ranLast ? "the catalog check ran last — its verdict is Catalog's colour"
                           : "the catalog check did not run\(why)"
        let refusedWords = refused.isEmpty ? "" : "; refused (not started): \(Self.titles(refused))"
        runner.note("\(Self.logPrefix) — OUTCOME — started \(started.count) step(s): \(Self.titles(started))\(refusedWords); \(tail)")
    }

    private static func titles(_ kinds: [AnalyzeCycler]) -> String {
        kinds.map(\.title).joined(separator: ", ")
    }
}
