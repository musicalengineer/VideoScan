// ImportToSQLiteJob.swift
// Catalog ▸ "Import to SQLite (Dry Run)…" / "Import to SQLite…" as a Media
// File Operation (Rick 2026-10-17, docs/design/catalog_sqlite_migration_2026_10_16.md
// §10c "app wiring"). One sentence: from the Catalog menu, import the
// verified catalog into SQLite — first as a dry run that proves the
// reconciliation line and commits nothing — while the JSON catalog stays
// read-only for the whole run.
//
// What the job does, in order:
//   1. PRE-FLIGHT (ImportToSQLitePreflight, before any work): unsaved
//      catalog changes · another MFO job running · the Verify Catalog
//      report older than the catalog's generation · an audit marker with
//      no per-row results · catalog.sqlite already there (commit mode).
//      Each refusal is a line in the row; nothing is written.
//   2. HOLD the JSON store's writes (CatalogStore.holdWrites, MOPS-16): one
//      writer — the importer reads and hashes catalog.json; a save landing
//      underneath would be refused by its gate anyway, but the hold says
//      so BEFORE the bytes move. Released when the importer returns; the
//      saves it refused become one catch-up save.
//   3. The Core importer (CatalogImporter) in the chosen mode. Its sink
//      lines come through the one sink below; its outcome becomes the
//      row's one-line summary — the reconciliation line, prefixed
//      "DRY RUN — nothing written —" for a dry run — and the dry-run
//      marker beside the catalog is stamped when a dry run passes.
//
// Stop: the importer asks `stopRequested` before the target opens and at
// each phase boundary of its one transaction; a raised flag rolls the
// transaction back — outcome `stopped`, never `imported`. Pause is NOT
// offered (one transaction; the row's help says so).
//
// Progress is by PHASE, not by row: the importer's row pass is one loop
// inside the transaction and reports once ("rows N: main M · quarantine
// Q"); a per-row "4,120 of 13,793" would need a progress line inside that
// loop (CatalogImporter+Rows), deliberately not touched while the importer
// is under review. The row reads "Checking the gate…" → "Importing rows
// (N)…" → "rows N · main M · quarantine Q — sidecars…" → "comparing…" →
// the outcome.
//
// Memory: the importer's own budget (its header; ≈ one decoded catalog at a
// time) plus at most 200 quarantine sample rows and the pre-flight's two
// small reads (the report, the audit marker — read and dropped off-main).
// Nothing here grows with the number of rows.
//
// (For Rick: `Task.detached` ≈ handing a value to a worker thread and
// awaiting its result; the importer is an actor — a class with its own
// lock — and the sink closure it calls hops back to the UI thread.)

import Combine
import Foundation
import SwiftUI
import VideoScanCore
import os

private let importLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "importToSQLite")

@MainActor
final class ImportToSQLiteJob: @MainActor MediaFileOperationJob, MediaFileOperationOwnDetail {

    /// The row's phase — what the subtitle and the detail say.
    enum Phase: Equatable {
        case preflight, gate, rows, sidecars, comparing, done
    }

    static func title(for mode: CatalogImporter.Mode) -> String {
        mode == .dryRun ? "Import to SQLite (dry run)" : "Import to SQLite"
    }

    static let dryRunPrefix = "DRY RUN — nothing written — "
    static let noPauseWords = "No Pause: the import is one transaction. Stop rolls it back; nothing is kept."

    let id = UUID()
    let kind: MediaFileOperationKind = .importToSQLite
    let startedAt = Date()
    let mode: CatalogImporter.Mode
    private weak var model: VideoScanModel?
    /// Titles of the other MFO jobs active when this one was made (pre-flight).
    private let runningJobs: [String]
    /// What the app knows for the importer's gate (open Delete Duplicates
    /// plans, Archive Angel batches). Injected so a test passes an empty one.
    private let gateEnvironment: @Sendable () async -> CatalogImporter.Environment

    @Published private(set) var phase: Phase = .preflight
    @Published private(set) var refusals: [String] = []
    @Published private(set) var misses: [String] = []
    @Published private(set) var reconciliation: ImportReconciliation?
    /// The first 200 quarantined rows with their words (the detail view).
    @Published private(set) var quarantineSample: [CatalogImporter.QuarantineSample] = []
    /// Where the database landed (commit mode, imported).
    @Published private(set) var databaseURL: URL?
    @Published private(set) var state: MediaFileOperationState = .running {
        didSet { if !state.isActive, finishedAt == nil { finishedAt = Date() } }
    }
    @Published private(set) var finishedAt: Date?
    @Published private(set) var subtitleText = "Preparing…"
    @Published private(set) var fractionValue: Double = 0
    private(set) var wasRefused = false
    /// Internal so tests can `await job.task?.value`.
    private(set) var task: Task<Void, Never>?
    private let stopFlag = ImportStopFlag()
    /// TEST SEAM: every importer line, as the main actor absorbs it.
    var onImporterLineForTesting: ((String) -> Void)?

    var title: String { Self.title(for: mode) }
    var subtitle: String { subtitleText }
    var fraction: Double { fractionValue }
    var isIndeterminate: Bool { false }
    var detailView: AnyView { AnyView(ImportToSQLiteDetailView(job: self)) }

    init(model: VideoScanModel, mode: CatalogImporter.Mode, runningJobs: [String],
         gateEnvironment: @escaping @Sendable () async -> CatalogImporter.Environment) {
        self.model = model
        self.mode = mode
        self.runningJobs = runningJobs
        self.gateEnvironment = gateEnvironment
    }

    // MARK: Lifecycle

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
    }

    func refuseToStart(reason: String) {
        guard task == nil, state.isActive else { return }
        wasRefused = true
        refusals = [reason]
        finish(failed: reason)
        task = Task {}
    }

    /// Stop: the importer rolls back at its next phase boundary (or never
    /// opens the target); the row ends Stopped, never Done.
    func cancel() {
        guard state.isActive else { return }
        state = .cancelling
        stopFlag.raise()
        subtitleText = "Stopping — the import rolls back at its next step…"
    }

    // MARK: Run

    private func run() async {
        guard let model else { finish(failed: "The catalog went away before the job could start"); return }
        if TestEnvironment.isTestHost && model.catalogStore === CatalogStore.shared {
            refuse(["the catalog in use is the shared one and this process is a test host"], model: model)
            return
        }
        let catalogURL = URL(fileURLWithPath: model.catalogStore.fileLocation)
        let preflight = await Self.preflight(mode: mode, catalogURL: catalogURL,
                                             hasUnsavedChanges: model.catalogStore.hasUnsavedChanges, runningJobs: runningJobs)
        let refused = preflight.refusals
        if !refused.isEmpty { refuse(refused.map(\.words), model: model); return }
        if stopFlag.isRaised {
            model.importToSQLiteNote("OUTCOME stopped — before any work; nothing written")
            finish(cancelled: ())
            return
        }
        model.catalogStore.holdWrites(reason: Self.holdReason)
        model.importToSQLiteNote("START — \(startClause(generation: preflight.catalogGeneration, catalogURL: catalogURL))")
        phase = .gate
        subtitleText = "Checking the gate (the report, the audit, the sidecars)…"
        fractionValue = 0.1
        let (outcome, runID) = await runImporter(catalogURL: catalogURL)
        let heldSaves = model.catalogStore.releaseWriteHold()
        if heldSaves > 0 {
            model.importToSQLiteNote("\(heldSaves) catalog save(s) were held while the catalog was being read — saving now")
            model.saveCatalogDebounced()
        }
        await conclude(outcome, runID: runID, model: model, catalogURL: catalogURL, generation: preflight.catalogGeneration)
    }

    static let holdReason = "Import to SQLite is reading the catalog"

    /// The facts the pre-flight judges: two small reads off the main actor
    /// (the report's header, the audit marker) and the catalog file's own
    /// generation (its 4 KB header).
    nonisolated static func preflight(mode: CatalogImporter.Mode, catalogURL: URL, hasUnsavedChanges: Bool,
                                      runningJobs: [String]) async -> ImportToSQLitePreflight {
        await Task.detached(priority: .userInitiated) {
            let folder = catalogURL.deletingLastPathComponent()
            let target = folder.appendingPathComponent(CatalogImporter.Inputs.databaseFileName)
            return ImportToSQLitePreflight(
                mode: mode, hasUnsavedChanges: hasUnsavedChanges, runningJobs: runningJobs,
                catalogGeneration: CatalogSnapshot.headerProbe(at: catalogURL)?.generation ?? 0,
                report: reportFacts(folder.appendingPathComponent(CatalogImporter.Inputs.integrityFileName)),
                audit: auditFacts(folder.appendingPathComponent(CatalogImporter.Inputs.auditFileName)),
                targetExists: FileManager.default.fileExists(atPath: target.path))
        }.value
    }

    /// The report as the importer's gate will read it (the Core mirror).
    nonisolated private static func reportFacts(_ url: URL) -> ImportToSQLitePreflight.Report {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url) else { return .unreadable("the file could not be read") }
        guard let report = try? IntegrityReportJSON.decode(data) else { return .unreadable("not readable as an integrity report") }
        return .generation(report.snapshotGeneration)
    }

    /// The audit marker as the importer's gate will read it.
    nonisolated private static func auditFacts(_ url: URL) -> ImportToSQLitePreflight.Audit {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url) else { return .unreadable("the file could not be read") }
        guard let marker = try? AuditMarkerJSON.decode(data) else { return .unreadable("not readable as an audit marker") }
        return .rows(marker.rows != nil)
    }

    private func startClause(generation: Int, catalogURL: URL) -> String {
        let what = mode == .dryRun
            ? "DRY RUN — the same gate, rows, sidecars and comparator, then rolled back; nothing is written beside the catalog"
            : "import into \(CatalogImporter.Inputs.databaseFileName) beside the catalog"
        return "\(what) · catalog generation \(generation) · the JSON catalog is read-only for the run (saves are held) · "
            + "nothing is deleted · \(Self.noPauseWords)"
    }

    /// The importer, with the sink hopping every line back to the main
    /// actor. Returns the outcome and the run id (the quarantine rows of a
    /// real import are read back by it).
    private func runImporter(catalogURL: URL) async -> (CatalogImporter.Outcome, String) {
        let inputs = CatalogImporter.Inputs.beside(catalogURL: catalogURL, databaseFolder: catalogURL.deletingLastPathComponent())
        let environment = await gateEnvironment()
        let flag = stopFlag
        let importer = CatalogImporter(repository: GRDBCatalogRepository()) { [weak self] line in
            Task { @MainActor [weak self] in self?.absorb(line) }
        }
        let outcome = await importer.run(inputs, environment: environment, mode: mode, stopRequested: { flag.isRaised })
        return (outcome, await importer.lastRunID ?? "")
    }

    /// One importer line: forwarded to the sink and read for the phase.
    private func absorb(_ line: String) {
        model?.importToSQLiteNote("importer: " + line)
        onImporterLineForTesting?(line)
        guard state == .running else { return }
        if line.hasPrefix("START import") {
            phase = .rows
            subtitleText = "Importing rows (one transaction)…"
            fractionValue = 0.25
        } else if line.hasPrefix("rows ") {
            phase = .sidecars
            subtitleText = Self.rowsSubtitle(line) + " — sidecars…"
            fractionValue = 0.7
        } else if line.hasPrefix("sidecars") {
            phase = .comparing
            subtitleText = "Comparing every row against the file again…"
            fractionValue = 0.85
        }
    }

    /// "rows 13,793: main 13,581 · quarantine 212 (…)" → "rows 13,793 · main 13,581 · quarantine 212".
    nonisolated static func rowsSubtitle(_ line: String) -> String {
        let head = line.split(separator: "(", maxSplits: 1).first.map(String.init) ?? line
        return head.replacingOccurrences(of: ": ", with: " · ").trimmingCharacters(in: .whitespaces)
    }

    // MARK: Finish

    private func conclude(_ outcome: CatalogImporter.Outcome, runID: String, model: VideoScanModel, catalogURL: URL,
                          generation: Int) async {
        phase = .done
        switch outcome {
        case .imported(let r):
            reconciliation = r
            let database = catalogURL.deletingLastPathComponent().appendingPathComponent(CatalogImporter.Inputs.databaseFileName)
            databaseURL = database
            quarantineSample = await Self.readQuarantineSample(databaseURL: database, runID: runID)
            model.importToSQLiteNote("OUTCOME imported — \(r.line)")
            finish(success: r.line)
        case .dryRunPassed(let report):
            reconciliation = report.reconciliation
            quarantineSample = report.quarantineSample
            // The marker lives beside THIS catalog: point it there first (one
            // small read), then stamp the pass — launch order never matters.
            model.importDryRunMarker.attach(catalogFile: catalogURL.path)
            model.importDryRunMarker.notePassed(ImportDryRunRecord(passedAt: Date(), catalogGeneration: generation,
                                                                   reconciliationLine: report.reconciliation.line))
            model.importToSQLiteNote("OUTCOME dry run passed — nothing written — \(report.reconciliation.line)")
            finish(success: Self.dryRunPrefix + report.reconciliation.line)
        case .refused(let gate):
            refuse(gate.map(\.words), model: model)
        case .rolledBack(let found):
            misses = found.map(\.words)
            let words = "Rolled back — \(found.count) miss(es): " + found.prefix(3).map(\.words).joined(separator: " · ") + ". Nothing was written."
            model.importToSQLiteNote("OUTCOME rolled back — " + words)
            finish(failed: words)
        case .stopped:
            model.importToSQLiteNote("OUTCOME stopped — rolled back; nothing written")
            finish(cancelled: ())
        case .failed(let words):
            model.importToSQLiteNote("OUTCOME failed — " + words)
            finish(failed: words)
        }
    }

    /// After a real import: the first `quarantineSampleCap` quarantine rows
    /// of the run, read back through the seam (a reader of its own, closed
    /// before returning). A reader that will not open leaves the list
    /// empty — the detail says so.
    nonisolated static func readQuarantineSample(databaseURL: URL, runID: String) async -> [CatalogImporter.QuarantineSample] {
        let reader = GRDBCatalogRepository()
        let opened = await reader.open(at: databaseURL)
        guard opened == .readWrite || { if case .readOnly = opened { return true } else { return false } }() else { return [] }
        let sample = (try? await reader.read { r -> [CatalogImporter.QuarantineSample] in
            var out: [CatalogImporter.QuarantineSample] = []
            try r.quarantineEntries(run: runID) { entry in
                guard out.count < CatalogImporter.quarantineSampleCap else { return }
                out.append(CatalogImporter.QuarantineSample(ordinal: entry.ordinal, jsonRowID: entry.jsonRowID,
                                                            reasonCode: entry.reasonCode.rawValue, words: entry.words))
            }
            return out
        }) ?? []
        await reader.close()
        return sample
    }

    private func refuse(_ words: [String], model: VideoScanModel) {
        wasRefused = true
        refusals = words
        let line = "Refused — " + words.joined(separator: " · ") + ". Nothing was written."
        model.importToSQLiteNote("OUTCOME refused — " + words.joined(separator: " · ") + ". Nothing was written.")
        finish(failed: line)
    }

    private func finish(success: String) {
        state = .finished(summary: success)
        subtitleText = success
        fractionValue = 1
    }

    /// A refusal, a lost model, a rolled-back run or a store that said no.
    /// A requested Stop is never repainted as Failed (Rick 2026-08-26).
    private func finish(failed: String) {
        if state.cancelWasRequested { finish(cancelled: ()); return }
        state = .failed(message: failed)
        subtitleText = failed
        importLog.warning("import to sqlite failed: \(failed, privacy: .public)")
    }

    private func finish(cancelled: Void) {
        state = .cancelled
        subtitleText = "Stopped — rolled back; nothing written"
    }
}

/// The Stop flag the importer's `stopRequested` reads from the store's
/// queue while the job raises it on the main actor. (For Rick: an atomic
/// bool behind a lock.)
final class ImportStopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    var isRaised: Bool { lock.withLock { raised } }
    func raise() { lock.withLock { raised = true } }
}

// MARK: - Model half (the one sink)

extension VideoScanModel {

    /// The one sink: console + catalog.log, videoscan.log, the unified log.
    func importToSQLiteNote(_ line: String) {
        log("Import to SQLite: " + line)
        appLog.write("[import-sqlite] " + line)
        importLog.notice("\(line, privacy: .public)")
    }
}

// MARK: - Start

extension MediaFileOperationsCenter {

    /// Start Import to SQLite in `mode`. Any other active job refuses it
    /// (one writer; the pre-flight says which) — a second import too.
    @discardableResult
    func startImportToSQLite(model: VideoScanModel, mode: CatalogImporter.Mode) -> ImportToSQLiteJob {
        let running = jobs.filter { $0.state.isActive }.map(\.title)
        let job = ImportToSQLiteJob(model: model, mode: mode, runningJobs: running,
                                    gateEnvironment: Self.importGateEnvironment(model: model))
        guard add(job) else { return job }
        job.start()
        appLog.write(Self.startSummaryLine(verb: job.kind.logVerb, title: job.title,
                                           plan: mode == .dryRun
                                               ? "dry run — gate, one transaction, comparator, then rolled back; nothing written; the JSON catalog is read-only for the run"
                                               : "import the verified JSON catalog into catalog.sqlite beside it; the JSON catalog is read-only for the run and is never deleted"))
        return job
    }

    /// What the importer's gate asks the app: open Delete Duplicates plans
    /// and Archive Angel batches (both read from their small plan files,
    /// off the main actor).
    private static func importGateEnvironment(model: VideoScanModel) -> @Sendable () async -> CatalogImporter.Environment {
        let plansRoot = DeleteDuplicatesPlanStore.defaultRoot
        let bufferRoot = model.archiveAngel.environment.bufferRoot
        return {
            await Task.detached(priority: .utility) {
                let plans = DeleteDuplicatesPlanStore.unfinishedPlans(root: plansRoot, log: { _ in }).map { $0.id.uuidString }
                let batches: [String]
                switch ArchiveAngelPlanStore.inFlightRecordIDsFresh(bufferRoot: bufferRoot) {
                case .ids(let ids): batches = ids.isEmpty ? [] : ["Archive Angel batches holding \(ids.count) row(s)"]
                case .uncertain(let why): batches = ["Archive Angel buffer: \(why)"]
                }
                return CatalogImporter.Environment(openDeleteDuplicatesPlans: plans, openAngelBatches: batches)
            }.value
        }
    }
}
