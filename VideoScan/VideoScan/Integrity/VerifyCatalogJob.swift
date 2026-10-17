// VerifyCatalogJob.swift
// "Verify Catalog…" — the Media File Operation behind the integrity process
// (Rick 2026-10-16, docs/design/integrity_first_2026_10_16.md §2.2): run the
// tiers over what the catalog records, write the dated report, feed Catalog
// Status. FIRST SLICE: tiers 0, 1, 3, 4, 5 from the stamps and the rows
// (VerifyCatalogTiers.swift); 2 and 6 say "not built yet".
//
// READ-ONLY on the catalog and on media (MOPS-15): the job snapshots the
// rows on the main actor (one O(records) pass into Sendable values, like the
// coverage snapshot), runs every tier OFF the main actor, and the only file
// it writes is the report, through AtomicFilePublish. It never writes a row,
// never saves the catalog, never opens a media file. Seconds, not minutes,
// on 14k rows.
//
// Shape = CatalogAuditJob's (START / one line per tier / OUTCOME through one
// sink; chip; detail view; Stop) without the lanes and without the marks:
//   • Stop ends after the current tier (the tier in flight finishes — its
//     numbers are honest); the tiers not reached say "stopped before this
//     tier"; the report's outcome is "stopped" and Catalog Status reads it
//     as partial.
//   • Pause takes effect between tiers.
//   • A report that cannot be written (a read-only catalog folder) is said
//     out loud, OUTCOME is still logged, and the row ends Failed — the
//     findings stay in the detail view, but Catalog Status would otherwise
//     read a stale report and nobody would know.
//   • Refused before any work: the shared catalog from a test host.
//
// Memory: the snapshot (~400 bytes per row → ~6 MB at 14k, ~40 MB at 100k,
// freed at the end), at most IntegrityReport.findingsCap findings, one 1 MiB
// buffer while the catalog file is hashed. Nothing grows with file size.
//
// (For Rick: `Task.detached` ≈ handing a value to a worker thread and
// awaiting its result; everything else in this class runs on the UI thread,
// so the counters need no mutex.)

import Combine
import Foundation
import SwiftUI
import VideoScanCore
import os

private let verifyCatalogLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "verifyCatalog")

@MainActor
final class VerifyCatalogJob: @MainActor MediaFileOperationJob, MediaFileOperationOwnDetail {

    static let title = "Verify catalog"

    let id = UUID()
    let kind: MediaFileOperationKind = .verifyCatalog
    let startedAt = Date()
    private weak var model: VideoScanModel?

    /// TEST SEAM: the events the constraints check (nil = the app's store).
    var eventsForTesting: [IntegrityEventFact]?

    @Published private(set) var tiers: [IntegrityTier] = []
    /// Findings grouped by tier, in tier order; each list is capped so the
    /// whole stays under IntegrityReport.findingsCap.
    @Published private(set) var findingsByTier: [Int: [IntegrityFinding]] = [:]
    @Published private(set) var findingsTotal = 0
    @Published private(set) var report: IntegrityReport?
    /// Why the report did not land, when it did not.
    @Published private(set) var reportProblem: String?
    @Published private(set) var reportURL: URL?

    @Published private(set) var state: MediaFileOperationState = .running {
        didSet { if !state.isActive, finishedAt == nil { finishedAt = Date() } }
    }
    @Published private(set) var finishedAt: Date?
    @Published private(set) var subtitleText = "Preparing…"
    @Published private(set) var fractionValue: Double = 0
    @Published private(set) var isPausedValue = false
    private(set) var wasRefused = false
    /// Internal so tests can `await job.task?.value`.
    private(set) var task: Task<Void, Never>?
    private var stopRequested = false
    private var keptFindings = 0
    /// Tier 5's hash of catalog.json (hashed once; the report carries it).
    private var catalogHash: CatalogFileHash?

    var title: String { Self.title }
    var subtitle: String { subtitleText }
    var fraction: Double { fractionValue }
    var isIndeterminate: Bool { false }
    var canPause: Bool { state == .running }
    var isPaused: Bool { isPausedValue }
    var detailView: AnyView { AnyView(VerifyCatalogDetailView(job: self)) }

    /// Every kept finding, tier order — the report's list.
    var findings: [IntegrityFinding] { VerifyCatalogTiers.order.flatMap { findingsByTier[$0] ?? [] } }

    init(model: VideoScanModel) {
        self.model = model
    }

    // MARK: Lifecycle

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
    }

    func refuseToStart(reason: String) {
        guard task == nil, state.isActive else { return }
        wasRefused = true
        finish(failed: reason)
        task = Task {}
    }

    /// Stop: the tier in flight finishes; no later tier starts.
    func cancel() {
        guard state.isActive else { return }
        state = .cancelling
        isPausedValue = false
        stopRequested = true
        subtitleText = "Stopping after the current tier…"
    }

    /// Pause takes effect between tiers.
    func pause() {
        guard state == .running, !isPausedValue else { return }
        isPausedValue = true
        subtitleText = "Paused — \(tiers.count) of \(VerifyCatalogTiers.order.count) tiers done"
    }

    func resume() {
        guard isPausedValue else { return }
        isPausedValue = false
        subtitleText = "Resuming…"
    }

    private var stopped: Bool { stopRequested || Task.isCancelled || !state.isActive || state == .cancelling }

    // MARK: Run

    private func run() async {
        guard let model else { finish(failed: "The catalog went away before the job could start"); return }
        if let why = refusal(model: model) {
            wasRefused = true
            model.verifyCatalogNote("refused — \(why). Nothing was checked.")
            finish(failed: "Refused — \(why). Nothing was checked.")
            return
        }
        let snapshot = model.verifyCatalogSnapshot(events: eventsForTesting)
        let catalogURL = snapshot.catalogURL
        model.verifyCatalogNote("START — \(startClause(snapshot))")
        let previous = await Task.detached(priority: .utility) { IntegrityReportStore.read(besideCatalogAt: catalogURL) }.value
        var input = VerifyCatalogTiers.TierInput(snapshot: snapshot, previous: previous.report, constraintFindings: nil,
                                                 runID: id, now: Date())
        for tier in VerifyCatalogTiers.order {
            guard await waitOutPause() else { break }
            subtitleText = "Tier \(tier) — \(VerifyCatalogTiers.name(tier))…"
            input.now = Date()
            let outcome = await Task.detached(priority: .userInitiated) { [input] in
                VerifyCatalogTiers.evaluate(tier, input: input)
            }.value
            if let found = outcome.constraintFindings { input.constraintFindings = found }
            if let hash = outcome.catalogHash { catalogHash = hash }
            record(outcome, model: model)
        }
        await conclude(snapshot: snapshot, model: model)
    }

    /// Why the job must not start, in words — nil when it may. A viewer
    /// Mac may verify its copy; a TEST HOST must never write a report
    /// beside the real catalog.
    private func refusal(model: VideoScanModel) -> String? {
        if TestEnvironment.isTestHost && model.catalogStore === CatalogStore.shared {
            return "the catalog in use is the shared one and this process is a test host"
        }
        return nil
    }

    private func startClause(_ s: VerifyCatalogSnapshot) -> String {
        "\(s.rows.count.formatted()) row(s) (\(s.liveCount.formatted()) live), \(s.events.count.formatted()) confirmed event(s); "
            + "tiers 0–6 from the catalog's own stamps and relations. Read-only: nothing on media is opened, "
            + "no row is changed; the only file written is \(IntegrityReportStore.latestFileName) beside the catalog."
    }

    private func waitOutPause() async -> Bool {
        while isPausedValue && !stopped { try? await Task.sleep(for: .milliseconds(200)) }
        return !stopped
    }

    // MARK: Tally

    private func record(_ outcome: VerifyCatalogTiers.TierOutcome, model: VideoScanModel) {
        var tier = outcome.tier
        tier.runID = tier.result.isNotRun ? nil : tier.runID
        tiers.append(tier)
        findingsTotal += outcome.findings.count
        let room = max(0, IntegrityReport.findingsCap - keptFindings)
        let kept = Array(outcome.findings.prefix(room))
        keptFindings += kept.count
        findingsByTier[tier.tier] = kept
        fractionValue = Double(tiers.count) / Double(VerifyCatalogTiers.order.count)
        subtitleText = "Tier \(tier.tier) \(tier.name): \(tier.result.words)"
        model.verifyCatalogNote("tier \(tier.tier) \(tier.name): \(tier.result.words) — \(tier.summary)"
            + String(format: " (%.2f s)", tier.elapsedSeconds))
    }

    // MARK: Finish

    private func conclude(snapshot: VerifyCatalogSnapshot, model: VideoScanModel) async {
        let wasStopped = stopped
        for tier in VerifyCatalogTiers.order where !tiers.contains(where: { $0.tier == tier }) {
            tiers.append(VerifyCatalogTiers.stopped(tier))
        }
        let report = buildReport(snapshot: snapshot, outcome: wasStopped ? .stopped : .completed)
        self.report = report
        let catalogURL = snapshot.catalogURL
        let written: Result<URL, Error> = await Task.detached(priority: .utility) {
            Result { try IntegrityReportStore.write(report, besideCatalogAt: catalogURL).latest }
        }.value
        switch written {
        case .success(let url):
            reportURL = url
        case .failure(let error):
            reportProblem = "report could not be written: \(error.localizedDescription)"
        }
        let line = report.outcomeLine + (reportURL.map { " · report → \($0.lastPathComponent)" } ?? "")
        if let reportProblem {
            model.verifyCatalogNote("OUTCOME failed — \(reportProblem) — \(line)")
            finish(failed: "\(reportProblem) — the findings are listed below. \(line)")
        } else if wasStopped {
            model.verifyCatalogNote("OUTCOME stopped (partial) after \(report.tiers.filter { !$0.result.isNotRun }.count) tier(s) — \(line)")
            finish(cancelled: ())
        } else {
            model.verifyCatalogNote("OUTCOME — \(line)")
            finish(success: line)
        }
    }

    private func buildReport(snapshot: VerifyCatalogSnapshot, outcome: IntegrityReport.Outcome) -> IntegrityReport {
        let now = Date()
        let hash = catalogHash
        return IntegrityReport(runID: id, startedAt: startedAt, verifiedAt: outcome == .completed ? now : nil,
                               outcome: outcome, catalogFile: snapshot.catalogFile,
                               catalogGeneration: hash?.generation, catalogSHA256: hash?.sha256, catalogByteCount: hash?.byteCount,
                               rowsTotal: snapshot.rows.count, rowsLive: snapshot.liveCount,
                               elapsedSeconds: now.timeIntervalSince(startedAt),
                               tiers: tiers.sorted { $0.tier < $1.tier }, findings: findings, findingsTotal: findingsTotal)
    }

    private func finish(success: String) {
        state = .finished(summary: success)
        subtitleText = success
        fractionValue = 1
        isPausedValue = false
    }

    /// A refusal, a lost model, or a report that would not land. A requested
    /// Stop is never repainted as Failed (Rick 2026-08-26) — except for the
    /// report write, which a person must know about (the audit's own
    /// precedence: failed > stopped).
    private func finish(failed: String) {
        if state.cancelWasRequested, reportProblem == nil { finish(cancelled: ()); return }
        state = .failed(message: failed)
        subtitleText = failed
        isPausedValue = false
        verifyCatalogLog.warning("verify catalog failed: \(failed, privacy: .public)")
    }

    private func finish(cancelled: Void) {
        state = .cancelled
        subtitleText = "Stopped (partial) — \(tiers.filter { !$0.result.isNotRun }.count) tier(s) run; the report says so"
        isPausedValue = false
    }
}

// MARK: - Model half (the snapshot and the one sink)

extension VideoScanModel {

    /// The one sink: console + catalog.log, videoscan.log, the unified log.
    func verifyCatalogNote(_ line: String) {
        log("Verify catalog: " + line)
        appLog.write("[verify-catalog] " + line)
        verifyCatalogLog.notice("\(line, privacy: .public)")
    }

    /// ONE O(records) pass on the main actor into Sendable values. `events`
    /// nil = the app's confirmed events (EventsDecisionStore).
    func verifyCatalogSnapshot(events: [IntegrityEventFact]? = nil) -> VerifyCatalogSnapshot {
        var rows: [IntegrityRow] = []
        rows.reserveCapacity(records.count)
        for r in records { rows.append(IntegrityRow(record: r)) }
        return VerifyCatalogSnapshot(rows: rows, events: events ?? Self.confirmedEventFacts(EventsDecisionStore.shared.snapshot()),
                                     catalogFile: catalogStore.fileLocation)
    }

    /// Confirmed, un-merged events with their accepted members' content keys.
    nonisolated static func confirmedEventFacts(_ snapshot: EventsDecisionSnapshot) -> [IntegrityEventFact] {
        snapshot.liveEvents.map { e in
            IntegrityEventFact(id: e.id, name: e.name, memberKeys: snapshot.members(of: e.id).map(\.contentKey).sorted())
        }
    }
}

// MARK: - Start

extension MediaFileOperationsCenter {
    /// Start "Verify Catalog" over the whole catalog. One run at a time —
    /// a second request is refused (nothing started).
    @discardableResult
    func startVerifyCatalog(model: VideoScanModel) -> VerifyCatalogJob {
        let job = VerifyCatalogJob(model: model)
        let busy = jobs.contains { $0.state.isActive && $0 is VerifyCatalogJob }
        guard add(job) else { return job }
        if busy {
            job.refuseToStart(reason: "Verify Catalog is already running — wait for it to finish (or stop it). Nothing was started.")
            return job
        }
        job.start()
        appLog.write(Self.startSummaryLine(verb: job.kind.logVerb, title: job.title,
                                           plan: "check the catalog's rows, stamps and relations (tiers 0–6); nothing on media is opened, no row is changed; the only file written is integrity-latest.json beside the catalog"))
        return job
    }
}
