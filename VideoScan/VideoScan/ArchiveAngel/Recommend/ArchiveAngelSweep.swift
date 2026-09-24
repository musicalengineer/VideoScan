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
//
// Cadence (Rick 2026-09-10: "3am is just arbitrary … as long as the
// assessment is not taking up too much compute, we can do it 24/7 until
// all files assessed"): a full pass over ~12k records takes under 2 s, so
// the sweep runs at launch, one minute after any catalog change or record
// edit, and every 15 minutes while the app is up — always parked behind
// the user and any job. A rules-version bump re-scores at once.

import Foundation
import Combine
import os

private let sweepLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "archiveAngelSweep")

// MARK: - Settings
//
// "Assess Continuously" (archiveAngel.sweepEnabled, ON by default) moved to
// ArchiveAngelSettings with the Angel's other preferences (S2) — same key.

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
        /// The attention store's `revision` + `lastEventAt`, read on the
        /// main actor right BEFORE the candidate snapshot (the projection
        /// bakes attention into each candidate, so whatever this returns
        /// is what the scores are built on). Stamped into the evidence
        /// file so the Angel's pick can refuse evidence scored under an
        /// older state than the store holds now (codex 2026-09-20 #5).
        /// Default = "no attention store" (tests of the sweep alone).
        var attentionState: @MainActor () -> (revision: Int, lastEventAt: Date?) = { (0, nil) }
        /// Spotlight reads for a slice, off-main. Injected so tests never
        /// touch the metadata server.
        var playHistory: @Sendable ([String]) async -> [String: ArchiveAngelPlayHistory.Reading]
            = { await ArchiveAngelJob.readPlayHistoryOffMain(paths: $0) }
        /// The recommendation policy the run scores AND classifies with
        /// (the façade's; S3b). `weights` is kept as a view onto it.
        var policy: AngelRecommendationPolicy = .builtIn
        /// Awaited at the start of every run, BEFORE `policy` is read (codex
        /// #1643: the façade loads policy.json off the main actor; a run
        /// requested meanwhile waits for it, then reads the loaded rules
        /// through `setPolicy`). Default: nothing to wait for.
        var policyReady: @MainActor () async -> Void = {}
        var weights: ArchiveAngelWeights {
            get { policy.weights }
            set { policy.weights = newValue }
        }
        var sliceSize = 500
        var checkpointEvery = 5_000
        var quietSeconds: Double = 3
        var pausePollMilliseconds = 500
        /// One minute after the last catalog change or record edit (a star,
        /// a person, a date) the grades catch up. A scan parks the sweep
        /// anyway, so its stream of appends costs one run when it ends.
        var catalogChangeDebounceSeconds: Double = 60
        var launchDelaySeconds: Double = 90
        /// Re-score this often while the app is up, even with no signal —
        /// Spotlight play counts and volume reachability change underneath.
        var periodicSeconds: Double = 900
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
    private var periodicTask: Task<Void, Never>?
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

    /// The façade's policy finished loading (off-main): later runs score
    /// with it. A run already past its snapshot keeps the rules it began
    /// with — a batch never sees the rules change mid-way.
    func setPolicy(_ policy: AngelRecommendationPolicy) {
        configuration?.policy = policy
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        if !on {
            cancelScheduled()
            runTask?.cancel()
            status = .disabled
        } else if !status.isRunning {
            status = .idle
            schedulePeriodic()
        }
    }

    func noteInteraction() { gate.noteInteraction() }

    // MARK: Triggers

    /// Launch: score after a short delay so the catalog and the UI settle
    /// first. `delay` overrides the configured one (a missing or old-rules
    /// sidecar wants the grades back quickly).
    func scheduleLaunchRun(delay override: Double? = nil) {
        guard enabled, let cfg = configuration else { return }
        launchTask?.cancel()
        status = .scheduled(reason: "launch")
        let delay = override ?? cfg.launchDelaySeconds
        launchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.run(reason: "launch")
        }
    }

    /// Catalog changed or a record was edited: debounced (1 min) so a
    /// burst of writes is one rescore, after it settles.
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
        periodicTask?.cancel(); periodicTask = nil
    }

    private func schedulePeriodic() {
        guard let cfg = configuration else { return }
        periodicTask?.cancel()
        let every = max(0.05, cfg.periodicSeconds)   // floor is for tests; production is 15 min
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(every * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.run(reason: "periodic")
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
        guard let first = configuration else { return }
        // The policy may still be loading (off-main, at launch): wait, then
        // read the configuration again — it now carries the loaded rules.
        await first.policyReady()
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

        // Snapshot (one main-actor pass; the projection is the cost). The
        // attention state is read FIRST: it is the state the projection
        // will bake into the candidates, and it is what the evidence file
        // is stamped with — never the state at the finish line.
        let snapshotStart = clock.now
        let attention = cfg.attentionState()
        var all = cfg.candidates()
        let policy = cfg.policy
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
        var nextCheckpointSave = max(1, cfg.checkpointEvery)

        while index < total {
            if Task.isCancelled { status = enabled ? .idle : .disabled; return }
            // Park mid-run too — a scan or an Angel job may start while we score.
            while cfg.isExternallyBusy() || userIsInteracting(cfg) {
                status = .paused(reason: cfg.isExternallyBusy() ? "another job is using the catalog" : "you are working")
                try? await Task.sleep(nanoseconds: UInt64(cfg.pausePollMilliseconds) * 1_000_000)
                if Task.isCancelled { status = enabled ? .idle : .disabled; return }
            }
            let end = min(total, index + sliceSize)

            // Floor pass (main actor, cheap) → indices that need play history.
            let t0 = clock.now
            var pending: [Int] = []
            pending.reserveCapacity(end - index)
            let now = cfg.now()
            for i in index..<end {
                let c = all[i]
                // codex #1643 A2: the safety floors in their OWN pass, kept
                // apart from the first floor in policy order (the reason
                // shown), so no optional floor can mask one.
                // (When the first floor hit IS a safety floor it is also the
                // first safety floor — they keep their relative order — so
                // the separate pass runs only when it could differ.)
                let hit = ArchiveAngelScorer.floorHit(c, policy: policy, now: now)
                let safety = hit.flatMap { AngelPolicyDefaults.safetyFloorIDs.contains($0.rule.id) ? $0.rejection : nil }
                    ?? ArchiveAngelScorer.safetyHit(c, now: now)
                if let hit {
                    var rec = ArchiveAngelEvidenceRecord(score: 0, lines: [], rejection: hit.rejection,
                                                         useCount: 0, lastUsed: nil, computedAt: now,
                                                         timesProposed: c.attention.timesProposed,
                                                         familySkips: c.familySkips, bands: policy.grades,
                                                         excludedBy: Self.excludedBy(hit))
                    rec.safetyRejection = safety
                    records[c.id] = rec
                } else if let safety {
                    // Unreachable under a validated policy (every safety
                    // floor is in `floors`, intact) — a hand-built one
                    // without them still never recommends the file.
                    var rec = ArchiveAngelEvidenceRecord(score: 0, lines: [], rejection: safety,
                                                         useCount: 0, lastUsed: nil, computedAt: now,
                                                         timesProposed: c.attention.timesProposed,
                                                         familySkips: c.familySkips, bands: policy.grades)
                    rec.safetyRejection = safety
                    records[c.id] = rec
                } else {
                    pending.append(i)
                }
            }
            noteSlice(clock.now - t0)

            // Spotlight for the eligible ones, off-main.
            let readings = pending.isEmpty ? [:] : await cfg.playHistory(pending.map { all[$0].fullPath })

            let t1 = clock.now
            for i in pending {
                // Written back so the classifier sees the same plays.
                if let r = readings[all[i].fullPath] { all[i].useCount = r.useCount; all[i].lastUsed = r.lastUsed }
                let c = all[i]
                switch ArchiveAngelScorer.verdict(c, policy: policy, now: now) {
                case .eligible(let score, let lines):
                    eligible += 1
                    let rec = ArchiveAngelEvidenceRecord(score: score, lines: lines, rejection: nil,
                                                         useCount: c.useCount, lastUsed: c.lastUsed, computedAt: now,
                                                         timesProposed: c.attention.timesProposed,
                                                         familySkips: c.familySkips, bands: policy.grades)
                    records[c.id] = rec
                    sweepLog.debug("\(c.filename, privacy: .public): \(rec.summary(), privacy: .public)")
                case .rejected(let rejection):
                    records[c.id] = .init(score: 0, lines: [], rejection: rejection,
                                          useCount: c.useCount, lastUsed: c.lastUsed, computedAt: now,
                                          timesProposed: c.attention.timesProposed,
                                          familySkips: c.familySkips, bands: policy.grades)
                    sweepLog.debug("\(c.filename, privacy: .public): excluded — \(rejection.rawValue, privacy: .public)")
                }
            }
            noteSlice(clock.now - t1)

            sinceCheckpoint += end - index
            index = end
            status = .scoring(done: index, total: total)

            if sinceCheckpoint >= cfg.checkpointEvery, index < total {
                sinceCheckpoint = 0
                cfg.log("Archive Angel Assessment: \(index.formatted()) of \(total.formatted())")
            }
            // The partial file is written on a DOUBLING schedule (first at
            // `checkpointEvery`, then each time the scored count has doubled),
            // not at every log line. Each checkpoint re-encodes every record
            // scored so far, so a fixed 5,000 cadence made a 100k sweep
            // encode ~1.05M records — measured 2026-09-23 on the M5 Pro: ~70%
            // of the sweep's samples in JSONEncoder (Release 5.7 s, Debug
            // 7.7 s). Doubling bounds the total to under 2× the final file
            // (O(n), was O(n²/checkpointEvery)). A partial file is never
            // fresh and never resumed from — it only keeps grades visible
            // after a mid-sweep quit — so at most half the progress so far
            // is unsaved, the price of a linear sweep. The log contract (one
            // line per `checkpointEvery`) is unchanged.
            if index >= nextCheckpointSave, index < total {
                nextCheckpointSave = index * 2
                let checkpoint = ArchiveAngelEvidenceFile(computedAt: now, complete: false,
                                                          considered: index, eligible: eligible, records: records,
                                                          attentionRevision: attention.revision,
                                                          attentionLastEventAt: attention.lastEventAt,
                                                          policyFingerprint: store.policyFingerprint)
                _ = await ArchiveAngelEvidenceStore.saveOffMain(checkpoint, to: store.fileURL)
            }
            await Task.yield()
        }

        // Consolidation S3b: ONE classification over the whole set (copies
        // need every record at once), off the main actor — the inputs are
        // values. Every record gets its class, reasons, year and copies.
        let classifyStart = clock.now
        let classified = await Self.classifyOffMain(all, evidence: records, rules: policy.recommend, now: cfg.now())
        if Task.isCancelled { status = enabled ? .idle : .disabled; return }
        let classifySeconds = Self.seconds(clock.now - classifyStart)
        // Written back in main-actor slices (the same pacing as scoring).
        var from = 0
        while from < classified.verdicts.count {
            let t = clock.now
            let to = min(classified.verdicts.count, from + sliceSize)
            for i in from..<to {
                let v = classified.verdicts[i]
                let id = all[i].id
                guard var rec = records[id] else { continue }
                rec.recommendation = v.kind
                rec.reasons = v.reasons.isEmpty ? nil : v.reasons
                rec.year = v.year
                rec.copies = v.copies > 1 ? v.copies : nil
                rec.copyKey = v.copyKey
                records[id] = rec
            }
            noteSlice(clock.now - t)
            from = to
            await Task.yield()
        }

        let finishedAt = cfg.now()
        let file = ArchiveAngelEvidenceFile(computedAt: finishedAt, complete: true,
                                            considered: total, eligible: eligible, records: records,
                                            attentionRevision: attention.revision,
                                            attentionLastEventAt: attention.lastEventAt,
                                            policyFingerprint: store.policyFingerprint)
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
        cfg.log("Archive Angel Assessment: done: \(bands) · " + Self.classLine(classified.counts)
                + " (classified in \(String(format: "%.2f", classifySeconds)) s)"
                + " in \(String(format: "%.1f", lastRunSeconds)) s"
                + (saved ? "" : " (evidence NOT saved)"))
        // Once, on the first run after a rules change: what the old
        // surfaces said → what the one classifier says now.
        if let old = store.olderRules {
            store.olderRules = nil
            let legacy = await Self.classifyOffMain(all.filter { !$0.isOnMasterArchive && !$0.hasArchivedDuplicate },
                                                    evidence: [:], rules: .legacyNudge, now: finishedAt)
            cfg.log(Self.migrationLine(fromVersion: old.rulesVersion, oldGrades: old.grades,
                                       legacyCounts: legacy.counts, newCounts: classified.counts))
        }
        sweepLog.info("assessment \(reason, privacy: .public): \(summary, privacy: .public) in \(self.lastRunSeconds, privacy: .public)s")
    }

    // MARK: Classification helpers

    /// The classifier, off the main actor (inputs and result are values).
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func classifyOffMain(_ candidates: [ArchiveAngelCandidate],
                                            evidence: [UUID: ArchiveAngelEvidenceRecord],
                                            rules: AngelRecommendRules,
                                            now: Date) async -> ArchiveAngelRecommendations.Result {
        ArchiveAngelRecommendations.classify(candidates, evidence: evidence, rules: rules, now: now)
    }

    /// A policy floor's own words for the evidence (built-in floors: nil —
    /// their reason text is the rejection itself).
    nonisolated static func excludedBy(_ hit: (rejection: ArchiveAngelRejection, rule: AngelRule)) -> String? {
        hit.rule.resolvedKind == .match ? hit.rule.displayLine : nil
    }

    nonisolated static func classLine(_ counts: [ArchiveAngelRecommendationClass: Int]) -> String {
        let order: [ArchiveAngelRecommendationClass] = [.ready, .needsDate, .worthALook, .notNow, .excluded, .anotherCopy]
        return order.map { "\($0.label.lowercased()) \((counts[$0] ?? 0).formatted())" }.joined(separator: " · ")
    }

    /// "Archive Angel: recommendation rules v10 → v11 — before: nudge 589
    /// ready + 123 need a date, Angel A 1 · B 106; now: ready 42 · …"
    nonisolated static func migrationLine(fromVersion: Int, oldGrades: [ArchiveAngelGrade: Int],
                                          legacyCounts: [ArchiveAngelRecommendationClass: Int],
                                          newCounts: [ArchiveAngelRecommendationClass: Int]) -> String {
        let grades = ArchiveAngelGrade.allCases.map { "\($0.rawValue) \((oldGrades[$0] ?? 0).formatted())" }
            .joined(separator: " · ")
        return "Archive Angel: recommendation rules v\(fromVersion) → v\(ArchiveAngelScorer.rulesVersion) — before: "
            + "the nudge's rules \((legacyCounts[.ready] ?? 0).formatted()) ready + \((legacyCounts[.needsDate] ?? 0).formatted()) need a date, "
            + "the Angel's grades \(grades); now (one set of numbers): " + classLine(newCounts)
    }

    nonisolated static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
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
