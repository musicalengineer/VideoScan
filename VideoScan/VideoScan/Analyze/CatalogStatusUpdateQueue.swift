// CatalogStatusUpdateQueue.swift
// "Update everything stale" (Rick 2026-10-16, Catalog Status freshness
// §2 / §2.1): the yellow kinds, in registry order (integrity rows first),
// started ONE AT A TIME through the existing runner. Nothing new runs —
// each kind's Run now is the same entry point the row's button uses; the
// center's own conflict rule (one audit / one hash run / one sound run at
// a time) still applies underneath.
//
// Shape: a tiny main-actor state machine with a 1 s poll. `enqueue` keeps
// the order it was given; the loop starts the next kind when the current
// one is no longer running (AnalyzeRunner.isRunning — the same flags the
// panel samples). A `graceSeconds` window after each start lets an engine
// whose flag flips a beat later (the dossier queue) be seen as running
// before the poll moves on. Model-owned so it outlives the panel window.
//
// (For Rick: `Task { while … { try? await Task.sleep } }` ≈ a worker
// thread with a sleep loop, except it runs on the main actor between
// sleeps, so the state needs no mutex.)

import Combine
import Foundation

@MainActor
final class CatalogStatusUpdateQueue: ObservableObject {

    /// Kinds still waiting, in start order.
    @Published private(set) var pending: [AnalyzeCycler] = []
    /// The kind started last and not yet seen finished.
    @Published private(set) var current: AnalyzeCycler?

    var graceSeconds: TimeInterval = 2
    var pollMilliseconds = 1_000

    private var runner: AnalyzeRunner?
    private var startedAt = Date.distantPast
    private var loop: Task<Void, Never>?

    init() {}

    var isActive: Bool { current != nil || !pending.isEmpty }

    /// Queue `kinds` (duplicates and already-queued kinds dropped) and
    /// start the loop if idle. The runner is kept for the loop's starts.
    func enqueue(_ kinds: [AnalyzeCycler], runner: AnalyzeRunner, source: String) {
        self.runner = runner
        for k in kinds where !pending.contains(k) && current != k { pending.append(k) }
        guard !pending.isEmpty else { return }
        runner.model.log("Catalog status: update everything stale — \(pending.map(\.title).joined(separator: ", ")) (\(source))")
        if loop == nil { loop = Task { [weak self] in await self?.run() } }
    }

    /// Drop what has not started; the kind in flight keeps running (its
    /// own row has Pause / Stop).
    func clearPending() {
        pending.removeAll()
    }

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
        guard !pending.isEmpty else { return }
        let next = pending.removeFirst()
        current = next
        startedAt = now
        runner.runNow(next, source: "update everything stale")
    }
}
