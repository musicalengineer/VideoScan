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
// on 14k rows. Inside Import to SQLite (phase 2) the rows come instead from
// catalog.json as the import's audit saved it, decoded read-only off the
// main actor (`snapshotSource = .auditedFile(generation:)`, codex
// 2026-10-17 P2) — the report then certifies the file the importer reads.
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

    /// Where the rows come from (codex 2026-10-17 P2).
    enum SnapshotSource: Equatable {
        /// The standalone Verify Catalog: the catalog in use. Under the
        /// SQLite authority (catalog.cutover) that is catalog.sqlite, read
        /// through the database's own read path in ONE transaction — rows
        /// and generation together (GH #342); never memory, never
        /// catalog.json. Before the switch: the model's records, as always.
        case liveRecords
        /// Import to SQLite's phase 2: catalog.json exactly as its audit
        /// saved it, decoded read-only, which must carry this generation —
        /// so the report certifies the bytes the importer reads, never an
        /// edit made in memory after the audit's save.
        case auditedFile(generation: Int)
    }

    /// Set before `start()`; the standalone job never changes it.
    var snapshotSource: SnapshotSource = .liveRecords

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
    /// Under catalog.sqlite: the store's generation when tier 5 ran (the
    /// report's `catalogGeneration`; a WAL database is not byte-hashed).
    private var sqliteGenerationAtTier5: Int?

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

    /// Pause takes effect between tiers. Resume never re-snapshots: the
    /// findings describe the generation the snapshot was taken from, and
    /// tier 5 compares the file's generation with it (the report says
    /// `catalogChangedDuringRun` when a save landed in between).
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
        let snapshot: VerifyCatalogSnapshot
        switch await takeSnapshot(model: model) {
        case .success(let taken):
            snapshot = taken
        case .failure(let refusal):
            wasRefused = true
            model.verifyCatalogNote("refused — \(refusal.words). Nothing was checked.")
            finish(failed: "Refused — \(refusal.words). Nothing was checked.")
            return
        }
        let catalogURL = snapshot.catalogURL
        model.verifyCatalogNote("START — \(startClause(snapshot))")
        let previous = await Task.detached(priority: .utility) { IntegrityReportStore.read(besideCatalogAt: catalogURL) }.value
        var input = VerifyCatalogTiers.TierInput(snapshot: snapshot, previous: previous.report, constraintFindings: nil,
                                                 runID: id, now: Date())
        for tier in VerifyCatalogTiers.order {
            guard await waitOutPause() else { break }
            subtitleText = "Tier \(tier) — \(VerifyCatalogTiers.name(tier))…"
            input.now = Date()
            if tier == 5, snapshot.store == .sqlite {
                input.databaseGeneration = await databaseGenerationNow(model: model)
                if case .read(let g) = input.databaseGeneration { sqliteGenerationAtTier5 = g }
            }
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

    /// The rows this run checks, from `snapshotSource`.
    private func takeSnapshot(model: VideoScanModel) async -> Result<VerifyCatalogSnapshot, VerifyCatalogSnapshotRefusal> {
        switch snapshotSource {
        case .liveRecords:
            if let repository = model.catalogCutover.committer?.repository, let database = model.catalogCutover.databaseURL {
                return await model.verifyCatalogSnapshot(database: database, repository: repository, events: eventsForTesting)
            }
            return .success(model.verifyCatalogSnapshot(events: eventsForTesting))
        case .auditedFile(let generation):
            return await model.verifyCatalogSnapshot(auditedGeneration: generation, events: eventsForTesting)
        }
    }

    /// catalog.sqlite's generation now, for tier 5 (one small read).
    private func databaseGenerationNow(model: VideoScanModel) async -> VerifyCatalogTiers.DatabaseGenerationRead {
        guard let repository = model.catalogCutover.committer?.repository else {
            return .unreadable("the catalog store is no longer open")
        }
        do {
            return .read(try await repository.read { $0.generation })
        } catch {
            return .unreadable(String(describing: error))
        }
    }

    private func startClause(_ s: VerifyCatalogSnapshot) -> String {
        "\(s.store.fileName) at generation \(s.catalogGeneration): "
            + "\(s.rows.count.formatted()) row(s) (\(s.liveCount.formatted()) live), \(s.events.count.formatted()) confirmed event(s); "
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

    /// The hash is CERTIFIED only when the hashed file carries exactly the
    /// snapshot's generation; a different one is `catalogChangedDuringRun`
    /// (the run still completes — the findings stand for the snapshot's
    /// generation, and the words say to run again).
    private func buildReport(snapshot: VerifyCatalogSnapshot, outcome: IntegrityReport.Outcome) -> IntegrityReport {
        let now = Date()
        let hash = catalogHash
        let fileGeneration = snapshot.store == .sqlite ? sqliteGenerationAtTier5 : hash?.generation
        let changed = VerifyCatalogTiers.generationMismatch(snapshot: snapshot.catalogGeneration, file: fileGeneration) != nil
        return IntegrityReport(runID: id, startedAt: startedAt, verifiedAt: outcome == .completed ? now : nil,
                               outcome: outcome, catalogFile: snapshot.catalogFile,
                               snapshotGeneration: snapshot.catalogGeneration, catalogGeneration: fileGeneration,
                               catalogSHA256: hash?.sha256, catalogByteCount: hash?.byteCount,
                               catalogChangedDuringRun: changed,
                               catalogHashCertified: hash != nil && fileGeneration == snapshot.catalogGeneration,
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

/// Why a snapshot of the audited file could not be taken, in words.
struct VerifyCatalogSnapshotRefusal: Error, Equatable {
    let words: String
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
    /// nil = the app's confirmed events (EventsDecisionStore). The snapshot
    /// carries the generation the records derive from (the store's last
    /// loaded or durably written one) — what the findings will describe.
    func verifyCatalogSnapshot(events: [IntegrityEventFact]? = nil) -> VerifyCatalogSnapshot {
        var rows: [IntegrityRow] = []
        rows.reserveCapacity(records.count)
        for r in records { rows.append(IntegrityRow(record: r)) }
        return VerifyCatalogSnapshot(rows: rows, events: events ?? Self.confirmedEventFacts(EventsDecisionStore.shared.snapshot()),
                                     catalogFile: catalogStore.fileLocation, catalogGeneration: catalogStore.currentGeneration,
                                     mountedVolumeRoots: Self.mountedVolumeRootsNow())
    }

    /// Import to SQLite's Verify phase (codex 2026-10-17 P2): the rows of
    /// catalog.json AS THE AUDIT SAVED IT, decoded read-only off the main
    /// actor with `load()`'s own decoder (`CatalogStore.decodeCatalogFile`)
    /// — never `records`, which may already hold an edit made after that
    /// save. Refused (with words) when the file will not decode or carries
    /// another generation than the audit's. Memory: one decoded catalog
    /// for the length of the read, then the rows (as the live snapshot).
    func verifyCatalogSnapshot(auditedGeneration: Int,
                               events: [IntegrityEventFact]?) async -> Result<VerifyCatalogSnapshot, VerifyCatalogSnapshotRefusal> {
        let catalogFile = catalogStore.fileLocation
        let eventFacts = events ?? Self.confirmedEventFacts(EventsDecisionStore.shared.snapshot())
        let read = await Task.detached(priority: .userInitiated) { Self.auditedFileRows(catalogFile: catalogFile) }.value
        guard let read else {
            return .failure(VerifyCatalogSnapshotRefusal(words: "catalog.json could not be read back as the audit saved it"))
        }
        guard read.generation == auditedGeneration else {
            return .failure(VerifyCatalogSnapshotRefusal(
                words: "catalog.json is at generation \(read.generation) but the audit saved \(auditedGeneration) — something wrote it"))
        }
        return .success(VerifyCatalogSnapshot(rows: read.rows, events: eventFacts, catalogFile: catalogFile,
                                              catalogGeneration: read.generation, mountedVolumeRoots: Self.mountedVolumeRootsNow()))
    }

    /// Verify Catalog under the SQLite authority (GH #342): the rows of
    /// catalog.sqlite and its generation, read in ONE transaction through
    /// `CatalogLoad.rows` (the loader's own reader — the same purge rule,
    /// the same held rows; no display-pass write), projected off the main
    /// actor. An edit still inside the 2 s save debounce is not in the
    /// database yet, so it is not verified — the report describes the file.
    /// Refused (with words) when the store cannot be read.
    func verifyCatalogSnapshot(database: URL, repository: any CatalogRepository,
                               events: [IntegrityEventFact]?) async -> Result<VerifyCatalogSnapshot, VerifyCatalogSnapshotRefusal> {
        let eventFacts = events ?? Self.confirmedEventFacts(EventsDecisionStore.shared.snapshot())
        let read: Result<(generation: Int, rows: [IntegrityRow], likeness: [IntegrityLikenessFact]), Error> =
            await Task.detached(priority: .userInitiated) {
                do {
                    let got = try await Self.databaseRows(repository)
                    return .success((got.generation, got.rows, try await Self.databaseLikeness(repository)))
                } catch { return .failure(error) }
            }.value
        switch read {
        case .failure(let error):
            return .failure(VerifyCatalogSnapshotRefusal(words: "catalog.sqlite could not be read (\(error))"))
        case .success(let got):
            var snapshot = VerifyCatalogSnapshot(rows: got.rows, events: eventFacts, catalogFile: database.path,
                                                 catalogGeneration: got.generation, mountedVolumeRoots: Self.mountedVolumeRootsNow(),
                                                 store: .sqlite)
            snapshot.likeness = got.likeness
            return .success(snapshot)
        }
    }

    /// catalog.sqlite's footage likeness pairs (schema v1.11), each with the
    /// latest person's verdict between any two files of its contents.
    nonisolated static func databaseLikeness(_ repository: any CatalogRepository) async throws -> [IntegrityLikenessFact] {
        try await repository.read { reader in
            var out: [IntegrityLikenessFact] = []
            try reader.footageLikenessReviews { r in
                out.append(IntegrityLikenessFact(digestA: r.likeness.digestA, digestB: r.likeness.digestB,
                                                 reasons: r.likeness.reasons, strength: r.likeness.strength, verdict: r.verdict))
            }
            return out
        }
    }

    /// catalog.sqlite's rows (and its held `pending_rows`) as IntegrityRows,
    /// with the generation they were read at. A held payload that does not
    /// decode is a refusal, never skipped in silence.
    nonisolated static func databaseRows(_ repository: any CatalogRepository) async throws -> (generation: Int, rows: [IntegrityRow]) {
        let snapshot = try await CatalogLoad.rows(repository)
        let formatter = VideoRecord.makeRowDateFormatter()
        var rows: [IntegrityRow] = []
        rows.reserveCapacity(snapshot.rows.count + snapshot.pending.count)
        var seen = Set<UUID>()
        for loaded in snapshot.rows {
            let row = IntegrityRow(record: try VideoRecord(row: loaded, dateFormatter: formatter))
            seen.insert(row.id)
            rows.append(row)
        }
        for held in snapshot.pending {
            let row = IntegrityRow(record: try CatalogPendingRecord.record(held.json))
            if seen.insert(row.id).inserted { rows.append(row) }
        }
        return (snapshot.generation, rows)
    }

    /// The file's generation and its rows, projected where they were decoded.
    nonisolated static func auditedFileRows(catalogFile: String) -> (generation: Int, rows: [IntegrityRow])? {
        guard let (records, version, _, generation) = CatalogStore.decodeCatalogFile(at: URL(fileURLWithPath: catalogFile)),
              version <= CatalogSnapshot.currentVersion else { return nil }
        return (generation, records.map(IntegrityRow.init(record:)))
    }

    /// What tier 1 calls "connected": ONE readdir of /Volumes at snapshot
    /// time (each entry as "/Volumes/<name>") plus "/" — the boot disk is
    /// always connected. No stat, no mount-table walk; a leftover empty
    /// mount folder reads as connected, and the hash job says so when it
    /// gets there.
    nonisolated static func mountedVolumeRootsNow() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? []
        return Set(names.map { "/Volumes/" + $0 }).union(["/"])
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
        if let words = validateRunsItsOwn("catalog check") {
            job.refuseToStart(reason: words)
            return job
        }
        job.start()
        appLog.write(Self.startSummaryLine(verb: job.kind.logVerb, title: job.title,
                                           plan: "check the catalog's rows, stamps and relations (tiers 0–6); nothing on media is opened, no row is changed; the only file written is integrity-latest.json beside the catalog"))
        return job
    }
}
