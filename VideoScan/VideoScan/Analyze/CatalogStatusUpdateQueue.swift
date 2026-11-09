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
}

extension AnalyzeRunner: CatalogUpdateStepRunning {
    func note(_ line: String) {
        model.log(line)
        appLog.write(line)
    }

    func flushCatalog() -> Bool { model.saveCatalogNow() }
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
    /// Why the final check did not start, when it was refused (F3, F5).
    private var checkNotRun: String?
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
        }
        guard !pending.isEmpty else {
            if !started.isEmpty || cleared || checkNotRun != nil { finish() }
            return
        }
        // A catalog check (or file audit) this queue did not start — the
        // 03:30 daily check, a menu item — is running: no step starts beside
        // it; the queue waits for it (Codex sweep 11/09 F2).
        if let elsewhere = [Self.finalCheck, AnalyzeCycler.filePresence].first(where: runner.isRunning) {
            if !saidWaiting {
                runner.note("\(Self.logPrefix) — waiting: \(elsewhere.title) is already running; the next step starts when it ends")
                saidWaiting = true
            }
            return
        }
        saidWaiting = false
        let next = pending.removeFirst()
        // The check judges what the earlier steps wrote: their debounced
        // save lands first, acknowledged, or the check does not run (F3).
        if next == Self.finalCheck, !started.isEmpty, !runner.flushCatalog() {
            checkNotRun = "the catalog could not be saved first"
            if pending.isEmpty { finish() }
            return
        }
        startedAt = now
        // A refused start did not run: never counted as started (F5).
        guard runner.runNow(next, volume: nil, source: Self.source) else {
            if next == Self.finalCheck { checkNotRun = "it was refused — see its line above" }
            if pending.isEmpty { finish() }
            return
        }
        current = next
        started.append(next)
    }

    /// The one OUTCOME line; resets the run's bookkeeping.
    private func finish() {
        defer { started = []; cleared = false; checkNotRun = nil; saidWaiting = false }
        guard let runner, !started.isEmpty || cleared || checkNotRun != nil else { return }
        let checked = started.last == Self.finalCheck
        let why = checkNotRun.map { " — \($0)" } ?? (cleared ? " (the steps left were cleared)" : "")
        let tail = checked ? "the catalog check ran last — its verdict is Catalog's colour"
                           : "the catalog check did not run\(why)"
        runner.note("\(Self.logPrefix) — OUTCOME — started \(started.count) step(s): \(Self.titles(started)); \(tail)")
    }

    private static func titles(_ kinds: [AnalyzeCycler]) -> String {
        kinds.map(\.title).joined(separator: ", ")
    }
}
