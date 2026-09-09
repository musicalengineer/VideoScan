// ArchiveAngelSweep.swift
// Archive Angel phase 2 (docs/archive_angel_phase2_design.md): the
// background scoring sweep. Sibling of PreviewSweepService in spirit —
// configuration closures, an interaction gate, pacing, a @Published
// status — but the work item is "score one record", not "make one
// thumbnail", so it is its own small machine.
//
// Rick 2026-09-09: "the background analysis of rating which videos
// could/should be considered for archive." The sweep writes machine-tier
// evidence into ArchiveAngelEvidenceStore; nothing here decides anything.
//
// Pacing rules: 500 records per main-actor slice, then Task.yield; the
// Spotlight play-history batch for each slice runs off-main; the sweep
// PARKS (re-polls) while the user is interacting, while a scan runs, or
// while an Angel / Promote job is active. A checkpoint file (complete =
// false) is written every 5,000 records; freshness needs a complete file.

import Foundation
import Combine
import os

private let sweepLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "archiveAngelSweep")

// MARK: - Settings

/// ON by default — scoring reads catalog fields and Spotlight metadata,
/// never media bytes, so it is cheap enough to be always-on.
struct ArchiveAngelSweepSettings: Equatable {
    var enabled: Bool = true

    static let enabledKey = "archiveAngel.sweepEnabled"

    static func restored(from defaults: UserDefaults) -> ArchiveAngelSweepSettings {
        var s = ArchiveAngelSweepSettings()
        // Missing key → the ON default; only an explicit false turns it off.
        if let stored = defaults.object(forKey: enabledKey) as? Bool { s.enabled = stored }
        return s
    }

    func save(to defaults: UserDefaults) {
        defaults.set(enabled, forKey: Self.enabledKey)
    }
}

// MARK: - Status

enum ArchiveAngelSweepStatus: Equatable, Sendable {
    case disabled
    case idle
    case scheduled(reason: String)
    case scoring(done: Int, total: Int)
    case paused(reason: String)
    case done(summary: String, at: Date)

    var isRunning: Bool {
        switch self {
        case .scoring, .paused: return true
        default: return false
        }
    }

    var line: String {
        switch self {
        case .disabled: return "Archive Angel Assessment is off"
        case .idle: return "Archive Angel Assessment: idle"
        case .scheduled(let r): return "Archive Angel Assessment: scheduled (\(r))"
        case .scoring(let d, let t): return "Archive Angel Assessment: assessing \(d.formatted()) of \(t.formatted())…"
        case .paused(let r): return "Archive Angel Assessment: paused — \(r)"
        case .done(let s, _): return "Archive Angel Assessment: \(s)"
        }
    }
}

// MARK: - Sweep

@MainActor
final class ArchiveAngelSweep: ObservableObject {

    struct Configuration {
        /// Snapshot of the catalog as scorer inputs — called on the main
        /// actor at plan time (project active records; keeper policy built once).
        let candidates: @MainActor () -> [ArchiveAngelCandidate]
        /// Scan / Angel job / Promote running — PARK, never fight.
        let isExternallyBusy: @MainActor () -> Bool
        /// Spotlight reads for a slice, off-main. Injected so tests never
        /// touch the metadata server.
        var playHistory: @Sendable ([String]) async -> [String: ArchiveAngelPlayHistory.Reading]
            = { await ArchiveAngelJob.readPlayHistoryOffMain(paths: $0) }
        var weights: ArchiveAngelWeights = .standard
        var sliceSize = 500
        var checkpointEvery = 5_000
        var quietSeconds: Double = 3
        var pausePollMilliseconds = 500
        var catalogChangeDebounceSeconds: Double = 300
        var launchDelaySeconds: Double = 90
        var nightlyHour = 3
        var now: @Sendable () -> Date = { Date() }
        /// Console + file log. EXACTLY three lines per run (start,
        /// checkpoint every 5,000, finish) — never per record.
        var log: @MainActor (String) -> Void = { _ in }
    }

    @Published private(set) var status: ArchiveAngelSweepStatus = .idle
    /// Longest main-actor slice of the last run, for the scale sensor.
    @Published private(set) var longestSliceSeconds: Double = 0
    @Published private(set) var lastRunSeconds: Double = 0

    let store: ArchiveAngelEvidenceStore
    private var configuration: Configuration?
    private var enabled = false
    private var runTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var launchTask: Task<Void, Never>?
    private var nightlyTask: Task<Void, Never>?
    private var rerunRequested = false
    /// Interaction gate: the model pings this from interactive paths.
    let gate = PreviewSweepGate()

    init(store: ArchiveAngelEvidenceStore) {
        self.store = store
    }

    // MARK: Configure / enable

    func configure(_ configuration: Configuration, enabled: Bool) {
        self.configuration = configuration
        setEnabled(enabled)
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        if !on {
            cancelScheduled()
            runTask?.cancel()
            status = .disabled
        } else if !status.isRunning {
            status = .idle
            scheduleNightly()
        }
    }

    func noteInteraction() { gate.noteInteraction() }

    // MARK: Triggers

    /// Launch: score after a short delay so the catalog and the UI settle first.
    func scheduleLaunchRun() {
        guard enabled, let cfg = configuration else { return }
        launchTask?.cancel()
        status = .scheduled(reason: "launch")
        let delay = cfg.launchDelaySeconds
        launchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.run(reason: "launch")
        }
    }

    /// Catalog changed: debounced (5 min) so a scan's stream of appends is
    /// one rescore, after it settles.
    func noteCatalogChanged() {
        guard enabled, let cfg = configuration else { return }
        debounceTask?.cancel()
        if !status.isRunning { status = .scheduled(reason: "catalog changed") }
        let delay = cfg.catalogChangeDebounceSeconds
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.run(reason: "catalog changed")
        }
    }

    /// Manual: "Rescore now". Runs immediately (queues a rerun if one is in flight).
    func rescoreNow() {
        guard enabled else { return }
        debounceTask?.cancel()
        launchTask?.cancel()
        run(reason: "rescore now")
    }

    /// Stop everything (app teardown / tests).
    func stop() {
        cancelScheduled()
        runTask?.cancel()
        runTask = nil
        status = enabled ? .idle : .disabled
    }

    private func cancelScheduled() {
        debounceTask?.cancel(); debounceTask = nil
        launchTask?.cancel(); launchTask = nil
        nightlyTask?.cancel(); nightlyTask = nil
    }

    private func scheduleNightly() {
        guard let cfg = configuration else { return }
        nightlyTask?.cancel()
        let hour = cfg.nightlyHour
        let now = cfg.now
        nightlyTask = Task { [weak self] in
            while !Task.isCancelled {
                let current = now()
                var comps = Calendar.current.dateComponents([.year, .month, .day], from: current)
                comps.hour = hour; comps.minute = 0; comps.second = 0
                var next = Calendar.current.date(from: comps) ?? current
                if next <= current { next = Calendar.current.date(byAdding: .day, value: 1, to: next) ?? current }
                let wait = max(60, next.timeIntervalSince(current))
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.run(reason: "nightly")
            }
        }
    }

    // MARK: The run

    /// Start a scoring run (idempotent: a run in flight queues one rerun).
    func run(reason: String) {
        guard enabled, configuration != nil else { return }
        if runTask != nil { rerunRequested = true; return }
        runTask = Task { [weak self] in
            await self?.perform(reason: reason)
            guard let self else { return }
            self.runTask = nil
            if self.rerunRequested {
                self.rerunRequested = false
                self.run(reason: "queued")
            }
        }
    }

    /// Awaitable form for tests.
    func runAndWait(reason: String) async {
        run(reason: reason)
        await runTask?.value
    }

    private func perform(reason: String) async {
        guard let cfg = configuration else { return }
        let clock = ContinuousClock()
        let started = clock.now
        longestSliceSeconds = 0

        // Park while the app is busy elsewhere (bounded: give up after ~10 min).
        var parkedPolls = 0
        while cfg.isExternallyBusy() || userIsInteracting(cfg) {
            if Task.isCancelled { status = enabled ? .idle : .disabled; return }
            status = .paused(reason: cfg.isExternallyBusy() ? "another job is using the catalog" : "you are working")
            parkedPolls += 1
            if parkedPolls > (10 * 60 * 1000) / max(1, cfg.pausePollMilliseconds) {
                status = .idle
                sweepLog.info("sweep gave up waiting (\(reason, privacy: .public))")
                return
            }
            try? await Task.sleep(nanoseconds: UInt64(cfg.pausePollMilliseconds) * 1_000_000)
        }

        // Snapshot (one main-actor pass; the projection is the cost).
        let snapshotStart = clock.now
        let all = cfg.candidates()
        noteSlice(clock.now - snapshotStart)
        let total = all.count
        status = .scoring(done: 0, total: total)
        cfg.log("Archive Angel Assessment: assessing \(total.formatted()) records (reason: \(reason))")

        var records: [UUID: ArchiveAngelEvidenceRecord] = [:]
        records.reserveCapacity(total)
        var eligible = 0
        var index = 0
        let sliceSize = max(1, cfg.sliceSize)
        var sinceCheckpoint = 0

        while index < total {
            if Task.isCancelled { status = enabled ? .idle : .disabled; return }
            // Park mid-run too — a scan or an Angel job may start while we score.
            while cfg.isExternallyBusy() || userIsInteracting(cfg) {
                status = .paused(reason: cfg.isExternallyBusy() ? "another job is using the catalog" : "you are working")
                try? await Task.sleep(nanoseconds: UInt64(cfg.pausePollMilliseconds) * 1_000_000)
                if Task.isCancelled { status = enabled ? .idle : .disabled; return }
            }
            let end = min(total, index + sliceSize)
            let slice = all[index..<end]

            // Floor pass (main actor, cheap) → paths that need play history.
            let t0 = clock.now
            var pending: [ArchiveAngelCandidate] = []
            pending.reserveCapacity(slice.count)
            let now = cfg.now()
            for c in slice {
                if let rejection = ArchiveAngelScorer.hardFloor(c, weights: cfg.weights) {
                    records[c.id] = .init(score: 0, lines: [], rejection: rejection,
                                          useCount: 0, lastUsed: nil, computedAt: now)
                } else {
                    pending.append(c)
                }
            }
            noteSlice(clock.now - t0)

            // Spotlight for the eligible ones, off-main.
            let readings = pending.isEmpty ? [:] : await cfg.playHistory(pending.map(\.fullPath))

            let t1 = clock.now
            for var c in pending {
                if let r = readings[c.fullPath] { c.useCount = r.useCount; c.lastUsed = r.lastUsed }
                switch ArchiveAngelScorer.verdict(c, weights: cfg.weights, now: now) {
                case .eligible(let score, let lines):
                    eligible += 1
                    let rec = ArchiveAngelEvidenceRecord(score: score, lines: lines, rejection: nil,
                                                         useCount: c.useCount, lastUsed: c.lastUsed, computedAt: now)
                    records[c.id] = rec
                    sweepLog.debug("\(c.filename, privacy: .public): \(rec.summary(), privacy: .public)")
                case .rejected(let rejection):
                    records[c.id] = .init(score: 0, lines: [], rejection: rejection,
                                          useCount: c.useCount, lastUsed: c.lastUsed, computedAt: now)
                    sweepLog.debug("\(c.filename, privacy: .public): excluded — \(rejection.rawValue, privacy: .public)")
                }
            }
            noteSlice(clock.now - t1)

            index = end
            sinceCheckpoint += slice.count
            status = .scoring(done: index, total: total)

            if sinceCheckpoint >= cfg.checkpointEvery, index < total {
                sinceCheckpoint = 0
                cfg.log("Archive Angel Assessment: \(index.formatted()) of \(total.formatted())")
                let checkpoint = ArchiveAngelEvidenceFile(computedAt: now, complete: false,
                                                          considered: index, eligible: eligible, records: records)
                _ = await ArchiveAngelEvidenceStore.saveOffMain(checkpoint, to: store.fileURL)
            }
            await Task.yield()
        }

        let finishedAt = cfg.now()
        let file = ArchiveAngelEvidenceFile(computedAt: finishedAt, complete: true,
                                            considered: total, eligible: eligible, records: records)
        store.replace(with: file)
        let saved = await store.save()
        lastRunSeconds = Double((clock.now - started).components.seconds)
            + Double((clock.now - started).components.attoseconds) / 1e18
        let grades = store.gradeCounts()
        let summary = "scored \(total.formatted()) · \(store.candidateCount.formatted()) candidates"
            + (saved ? "" : " · (evidence not saved)")
        status = .done(summary: summary, at: finishedAt)
        let bands = ArchiveAngelGrade.allCases.map { g -> String in
            "\(g == .x ? "excluded" : g.rawValue) \((grades[g] ?? 0).formatted())"
        }.joined(separator: " · ")
        cfg.log("Archive Angel Assessment: done: \(bands) in \(String(format: "%.1f", lastRunSeconds)) s"
                + (saved ? "" : " (evidence NOT saved)"))
        sweepLog.info("assessment \(reason, privacy: .public): \(summary, privacy: .public) in \(self.lastRunSeconds, privacy: .public)s")
    }

    private func userIsInteracting(_ cfg: Configuration) -> Bool {
        guard let last = gate.lastInteraction else { return false }
        return CFAbsoluteTimeGetCurrent() - last < cfg.quietSeconds
    }

    private func noteSlice(_ d: Duration) {
        let secs = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        if secs > longestSliceSeconds { longestSliceSeconds = secs }
    }
}
