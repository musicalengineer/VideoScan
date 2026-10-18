// ImportToSQLiteJob.swift
// Catalog ▸ "Import to SQLite (Dry Run)…" / "Import to SQLite…" as a Media
// File Operation (Rick 2026-10-17, docs/design/catalog_sqlite_migration_2026_10_16.md
// §10c "app wiring"; "one action verb" the same evening). One sentence:
// Import to SQLite holds every catalog save from its first step to its
// last, and inside that hold runs Audit Catalog, then Verify Catalog, then
// the import (dry run or commit), so the three steps describe one
// generation by construction.
//
// Why one verb: Rick's first real dry run passed at generation 4881 and the
// app's own background savers wrote 4882 fifty-five seconds later, so the
// real import (which demanded the dry run's generation) stayed disabled —
// and by hand, Audit → Verify → Import could never line up in a live app.
//
// What the job does, in order:
//   0. PRE-FLIGHT (ImportToSQLitePreflight, before any work): unsaved
//      catalog changes · another MFO job running · catalog.sqlite already
//      there (commit mode). Each refusal is a line in the row; nothing is
//      written.
//   THE HOLD (CatalogStore.holdWrites(reason:owner:), MOPS-16) — taken
//      here, released after phase 3. Every catalog save is held (counted,
//      caught up after) EXCEPT the acknowledged saves that present this
//      job's owner token: the audit's own stamp/mark saves.
//   1. AUDIT CATALOG — the existing CatalogAuditJob, made here and run to
//      its end (not added to the center: it is this row's phase). Its
//      saves carry the owner token. When it ends, the store's generation
//      is G — the one Verify and the importer must see.
//   2. VERIFY CATALOG — the existing VerifyCatalogJob, made only after the
//      audit's finishing second has passed (the gate's time-order rule,
//      ImportToSQLiteTiming). It snapshots generation G and certifies the
//      file at G.
//   3. IMPORT — first a check that catalog.json is still at G (the header,
//      4 KB), then the Core importer (CatalogImporter) in the chosen mode.
//      Its lines come through the one sink; its outcome is the row's
//      one-line summary — the reconciliation line, prefixed "DRY RUN —
//      nothing written —" for a dry run — and a passed dry run stamps the
//      marker beside the catalog with THIS BUILD.
//   A phase that cannot complete stops the job with its own words ("the
//   audit could not complete: …"); nothing is imported; the hold is
//   released with its catch-up save.
//
// Stop: forwarded to the phase job in flight (the audit finishes its chunk
// and saves what it marked; Verify ends after its tier), then the job ends
// Stopped; in phase 3 the importer rolls its transaction back at its next
// phase boundary — outcome `stopped`, never `imported`. Pause is NOT
// offered (one hold, one transaction; the row's help says so).
//
// Quit (codex 2026-10-17 P1): the app's quit path Stops the job, awaits its
// end (bounded, `ImportToSQLiteQuit.deadline`), then saves the held edits
// durably before it lets the process go; past the bound the hold is
// released by force and the edits are saved anyway (the import abandoned,
// its transaction never committed). The hold itself is an atomic admission
// boundary (`holdWrites` drains every save admitted before it, P2).
//
// Progress: phase 1 is 0–40 % of the bar (the audit's own fraction scaled
// in), phase 2 40–50 %, phase 3 by the importer's phase lines.
//
// Memory: the audit's and Verify's own budgets (their headers; at most one
// of them at a time), then the importer's (≈ one decoded catalog), plus at
// most 200 quarantine sample rows. Nothing here grows with the rows.
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
        case preflight, audit, verify, gate, rows, sidecars, comparing, done
    }

    /// How the three phases ended (before the row's words are chosen).
    private enum Ending {
        case importer(CatalogImporter.Outcome, runID: String, generation: Int)
        case stopped(during: Phase)
        case refused(String)
    }

    static func title(for mode: CatalogImporter.Mode) -> String {
        mode == .dryRun ? "Import to SQLite (dry run)" : "Import to SQLite"
    }

    static let dryRunPrefix = "DRY RUN — nothing written — "
    static let noPauseWords = "No Pause: the import is one hold and one transaction. Stop ends it; nothing is imported."
    static let holdReason = "Import to SQLite is auditing, verifying and importing the catalog"
    static let nothingWritten = "Nothing was written."
    static let nothingImported = "Nothing was imported."

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
    /// This job's token for the store's write hold — its audit's saves present it.
    private let holdOwner = CatalogWriteHoldOwner()

    @Published private(set) var phase: Phase = .preflight
    @Published private(set) var refusals: [String] = []
    @Published private(set) var misses: [String] = []
    @Published private(set) var reconciliation: ImportReconciliation?
    /// The first 200 quarantined rows with their words (the detail view).
    @Published private(set) var quarantineSample: [CatalogImporter.QuarantineSample] = []
    /// Where the database landed (commit mode, imported).
    @Published private(set) var databaseURL: URL?
    /// The generation the audit's own save left — what Verify and the importer saw.
    @Published private(set) var auditedGeneration: Int?
    @Published private(set) var state: MediaFileOperationState = .running {
        didSet { if !state.isActive, finishedAt == nil { finishedAt = Date() } }
    }
    @Published private(set) var finishedAt: Date?
    @Published private(set) var subtitleText = "Preparing…"
    @Published private(set) var fractionValue: Double = 0
    private(set) var wasRefused = false
    /// Internal so tests can `await job.task?.value`.
    private(set) var task: Task<Void, Never>?
    /// Phases 1 and 2 (internal so tests can read their results).
    private(set) var auditJob: CatalogAuditJob?
    private(set) var verifyJob: VerifyCatalogJob?
    /// The phase job in flight (Stop is forwarded to it) and its share of the bar.
    private var activeChild: (any ImportPhaseJob)?
    private var activeSpan: ClosedRange<Double> = 0...0
    private let stopFlag = ImportStopFlag()

    /// TEST SEAMS (nil in production): set up the phase jobs (sandbox lane
    /// roots, no shared events store); called at the start of each phase,
    /// inside the hold, before the phase's work; every importer line.
    var configureAuditForTesting: ((CatalogAuditJob) -> Void)?
    var configureVerifyForTesting: ((VerifyCatalogJob) -> Void)?
    var onPhaseForTesting: ((Phase) -> Void)?
    var onImporterLineForTesting: ((String) -> Void)?
    /// After the pre-flight, before the hold (a save admitted in that window).
    var onBeforeHoldForTesting: (() -> Void)?

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

    /// Stop: forwarded to the phase job in flight; the importer rolls back
    /// at its next phase boundary (or never opens the target). The row ends
    /// Stopped, never Done.
    func cancel() {
        guard state.isActive else { return }
        state = .cancelling
        stopFlag.raise()
        activeChild?.cancel()
        subtitleText = "Stopping — nothing will be imported…"
    }

    /// The quit path (ImportToSQLiteQuit): after Stop, wait — at most
    /// `deadline` seconds — for the run to end. The row turns terminal only
    /// after the hold is released, so true means the hold is gone.
    func waitForEnd(deadline: TimeInterval) async -> Bool {
        let until = Date().addingTimeInterval(deadline)
        while state.isActive, Date() < until {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return !state.isActive
    }

    // MARK: Run

    private func run() async {
        guard let model else { finish(failed: "The catalog went away before the job could start"); return }
        if TestEnvironment.isTestHost && model.catalogStore === CatalogStore.shared {
            refuse(["the catalog in use is the shared one and this process is a test host"], model: model, tail: Self.nothingWritten)
            return
        }
        let catalogURL = URL(fileURLWithPath: model.catalogStore.fileLocation)
        let preflight = await Self.preflight(mode: mode, catalogURL: catalogURL,
                                             hasUnsavedChanges: model.catalogStore.hasUnsavedChanges, runningJobs: runningJobs)
        let refused = preflight.refusals
        if !refused.isEmpty { refuse(refused.map(\.words), model: model, tail: Self.nothingWritten); return }
        if stopFlag.isRaised {
            model.importToSQLiteNote("OUTCOME stopped — before any work; nothing written")
            finish(cancelled: "Stopped — before any work; nothing written")
            return
        }
        onBeforeHoldForTesting?()
        // An atomic admission boundary (codex 2026-10-17 P2): returns once
        // every save admitted before it has landed; the generation the
        // START line records is read after that drain.
        await model.catalogStore.holdWrites(reason: Self.holdReason, owner: holdOwner)
        let heldAt = await Self.fileGeneration(catalogURL)
        model.importToSQLiteNote("START — \(startClause(generation: heldAt))")
        let ending = await runPhases(model: model, catalogURL: catalogURL)
        let heldSaves = model.catalogStore.releaseWriteHold()
        if heldSaves > 0 {
            model.importToSQLiteNote("\(heldSaves) catalog save(s) were held while the catalog was audited, verified and read — saving now")
            model.saveCatalogDebounced()
        }
        await conclude(ending, model: model, catalogURL: catalogURL)
    }

    /// The facts the pre-flight judges: the catalog file's own generation
    /// (its 4 KB header) and whether the target is there — off the main actor.
    nonisolated static func preflight(mode: CatalogImporter.Mode, catalogURL: URL, hasUnsavedChanges: Bool,
                                      runningJobs: [String]) async -> ImportToSQLitePreflight {
        await Task.detached(priority: .userInitiated) {
            let target = catalogURL.deletingLastPathComponent().appendingPathComponent(CatalogImporter.Inputs.databaseFileName)
            return ImportToSQLitePreflight(
                mode: mode, hasUnsavedChanges: hasUnsavedChanges, runningJobs: runningJobs,
                catalogGeneration: CatalogSnapshot.headerProbe(at: catalogURL)?.generation ?? 0,
                targetExists: FileManager.default.fileExists(atPath: target.path))
        }.value
    }

    /// catalog.json's own generation (its 4 KB header), off the main actor.
    nonisolated static func fileGeneration(_ catalogURL: URL) async -> Int {
        await Task.detached(priority: .userInitiated) {
            CatalogSnapshot.headerProbe(at: catalogURL)?.generation ?? 0
        }.value
    }

    private func startClause(generation: Int) -> String {
        let what = mode == .dryRun
            ? "DRY RUN — Audit Catalog, Verify Catalog, then the same gate, rows, sidecars and comparator, rolled back; "
                + "nothing is written beside the catalog but the audit's stamps, its marker and the Verify report"
            : "Audit Catalog, Verify Catalog, then import into \(CatalogImporter.Inputs.databaseFileName) beside the catalog"
        return "\(what) · catalog generation \(generation) at the start · every catalog save but the audit's own is held "
            + "until the end · nothing is deleted · \(Self.noPauseWords)"
    }

    // MARK: The three phases

    private func runPhases(model: VideoScanModel, catalogURL: URL) async -> Ending {
        let mirror = startMirror()
        defer { mirror.cancel() }
        if let end = await auditPhase(model: model) { return end }
        let generation = model.catalogStore.currentGeneration
        auditedGeneration = generation
        model.importToSQLiteNote("phase 1 of 3 done — the audit left the catalog at generation \(generation); "
            + "Verify Catalog and the importer must see the same")
        if let end = await verifyPhase(model: model, generation: generation, auditFinishedAt: auditJob?.finishedAt ?? Date()) {
            return end
        }
        return await importPhase(model: model, catalogURL: catalogURL, generation: generation)
    }

    /// Phase 1: the audit, its saves presenting this job's token.
    private func auditPhase(model: VideoScanModel) async -> Ending? {
        let audit = CatalogAuditJob(model: model, marker: model.catalogAuditRunMarker)
        audit.writeHoldOwner = holdOwner
        configureAuditForTesting?(audit)
        auditJob = audit
        let ended = await runPhase(audit, .audit, span: 0...0.4, model: model)
        return ending(after: .audit, .of(ended, step: "the audit"))
    }

    /// Phase 2: Verify Catalog, made only once the audit's finishing second
    /// is past (its report's start must be a later second than the audit's
    /// end; the clock is re-read after each wait). It checks catalog.json as
    /// the audit saved it at `generation` — the file the importer reads —
    /// never the in-memory rows (codex 2026-10-17 P2).
    private func verifyPhase(model: VideoScanModel, generation: Int, auditFinishedAt: Date) async -> Ending? {
        let ready = await ImportToSQLiteTiming.waitForVerifyStart(auditFinishedAt: auditFinishedAt, now: { Date() },
                                                                  sleep: { try? await Task.sleep(for: .seconds($0)) })
        if stopFlag.isRaised { return .stopped(during: .verify) }
        guard ready else {
            return .refused("the wall clock kept stepping back — Verify Catalog could not start a whole second after the audit ended")
        }
        let verify = VerifyCatalogJob(model: model)
        verify.snapshotSource = .auditedFile(generation: generation)
        configureVerifyForTesting?(verify)
        verifyJob = verify
        let ended = await runPhase(verify, .verify, span: 0.4...0.5, model: model)
        return ending(after: .verify, .of(ended, step: "Verify Catalog"))
    }

    /// Phase 3: the file must still be at the audit's generation; then the importer.
    private func importPhase(model: VideoScanModel, catalogURL: URL, generation: Int) async -> Ending {
        let onDisk = await Self.fileGeneration(catalogURL)
        guard onDisk == generation else {
            return .refused("catalog.json is at generation \(onDisk) but the audit left it at \(generation) — "
                + "something wrote it during the run")
        }
        phase = .gate
        subtitleText = "Importing — checking the gate (the report, the audit, the sidecars)…"
        fractionValue = 0.55
        model.importToSQLiteNote("phase 3 of 3 — the import, at generation \(generation)")
        onPhaseForTesting?(.gate)
        let (outcome, runID) = await runImporter(catalogURL: catalogURL)
        return .importer(outcome, runID: runID, generation: generation)
    }

    /// Run one phase job to its end and return its terminal state. A Stop
    /// that came before the job started is handed to it first.
    private func runPhase(_ child: any ImportPhaseJob, _ next: Phase, span: ClosedRange<Double>,
                          model: VideoScanModel) async -> MediaFileOperationState {
        phase = next
        activeChild = child
        activeSpan = span
        subtitleText = Self.lead(next)
        fractionValue = span.lowerBound
        model.importToSQLiteNote("phase \(next == .audit ? 1 : 2) of 3 — \(child.title)")
        onPhaseForTesting?(next)
        if stopFlag.isRaised { child.cancel() }
        child.start()
        await child.task?.value
        activeChild = nil
        return child.state
    }

    /// What a phase's verdict means for the run; nil = go on.
    private func ending(after phase: Phase, _ verdict: ImportPhaseVerdict) -> Ending? {
        switch verdict {
        case .couldNotComplete(let words): return .refused(words)
        case .stopped: return .stopped(during: phase)
        case .proceed: return stopFlag.isRaised ? .stopped(during: phase) : nil
        }
    }

    /// The row mirrors the phase job's own line and bar while it runs.
    private func startMirror() -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.copyPhaseProgress()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func copyPhaseProgress() {
        guard state == .running, let child = activeChild else { return }
        subtitleText = Self.lead(phase) + " " + child.subtitle
        fractionValue = activeSpan.lowerBound + child.fraction * (activeSpan.upperBound - activeSpan.lowerBound)
    }

    /// The row's lead words for a phase.
    nonisolated static func lead(_ phase: Phase) -> String {
        switch phase {
        case .audit: return "Checking every file…"
        case .verify: return "Verifying the catalog…"
        default: return "Importing…"
        }
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
            fractionValue = 0.6
        } else if line.hasPrefix("rows ") {
            phase = .sidecars
            subtitleText = Self.rowsSubtitle(line) + " — sidecars…"
            fractionValue = 0.85
        } else if line.hasPrefix("sidecars") {
            phase = .comparing
            subtitleText = "Comparing every row against the file again…"
            fractionValue = 0.92
        }
    }

    /// "rows 13,793: main 13,581 · quarantine 212 (…)" → "rows 13,793 · main 13,581 · quarantine 212".
    nonisolated static func rowsSubtitle(_ line: String) -> String {
        let head = line.split(separator: "(", maxSplits: 1).first.map(String.init) ?? line
        return head.replacingOccurrences(of: ": ", with: " · ").trimmingCharacters(in: .whitespaces)
    }

    // MARK: Finish

    private func conclude(_ ending: Ending, model: VideoScanModel, catalogURL: URL) async {
        switch ending {
        case .importer(let outcome, let runID, let generation):
            await conclude(outcome, runID: runID, model: model, catalogURL: catalogURL, generation: generation)
        case .stopped(let during):
            phase = .done
            let words = Self.stoppedWords(during: during)
            model.importToSQLiteNote("OUTCOME stopped — " + words)
            finish(cancelled: "Stopped — " + words)
        case .refused(let words):
            phase = .done
            refuse([words], model: model, tail: Self.nothingImported)
        }
    }

    /// The Stop words for the phase it landed in.
    nonisolated static func stoppedWords(during phase: Phase) -> String {
        switch phase {
        case .audit: return "during the audit; the stamps and marks it saved are kept; nothing was imported"
        case .verify: return "during Verify Catalog; its report says stopped; nothing was imported"
        default: return "rolled back; nothing was imported"
        }
    }

    private func conclude(_ outcome: CatalogImporter.Outcome, runID: String, model: VideoScanModel, catalogURL: URL,
                          generation: Int) async {
        phase = .done
        switch outcome {
        case .imported(let r):
            reconciliation = r
            let database = catalogURL.deletingLastPathComponent().appendingPathComponent(CatalogImporter.Inputs.databaseFileName)
            databaseURL = database
            quarantineSample = await Self.readQuarantineSample(databaseURL: database, runID: runID)
            model.importToSQLiteNote("OUTCOME imported — generation \(generation) — \(r.line)")
            finish(success: r.line)
        case .dryRunPassed(let report):
            reconciliation = report.reconciliation
            quarantineSample = report.quarantineSample
            // The marker lives beside THIS catalog: point it there first (one
            // small read), then stamp the pass with this build.
            model.importDryRunMarker.attach(catalogFile: catalogURL.path)
            model.importDryRunMarker.notePassed(ImportDryRunRecord(passedAt: Date(), catalogGeneration: generation,
                                                                   reconciliationLine: report.reconciliation.line,
                                                                   build: ImportBuildIdentity.current))
            model.importToSQLiteNote("OUTCOME dry run passed — nothing written — generation \(generation) — \(report.reconciliation.line)")
            finish(success: Self.dryRunPrefix + report.reconciliation.line)
        case .refused(let gate):
            refuse(gate.map(\.words), model: model, tail: Self.nothingImported)
        case .rolledBack(let found):
            misses = found.map(\.words)
            let words = "Rolled back — \(found.count) miss(es): " + found.prefix(3).map(\.words).joined(separator: " · ") + ". Nothing was written."
            model.importToSQLiteNote("OUTCOME rolled back — " + words)
            finish(failed: words)
        case .stopped:
            model.importToSQLiteNote("OUTCOME stopped — " + Self.stoppedWords(during: .gate))
            finish(cancelled: "Stopped — " + Self.stoppedWords(during: .gate))
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

    /// `tail`: "Nothing was written." before any work, "Nothing was
    /// imported." once the audit may have saved its stamps.
    private func refuse(_ words: [String], model: VideoScanModel, tail: String) {
        wasRefused = true
        refusals = words
        let joined = words.joined(separator: " · ")
        model.importToSQLiteNote("OUTCOME refused — \(joined). \(tail)")
        finish(failed: "Refused — \(joined). \(tail)")
    }

    private func finish(success: String) {
        state = .finished(summary: success)
        subtitleText = success
        fractionValue = 1
    }

    /// A refusal, a lost model, a rolled-back run or a store that said no.
    /// A requested Stop is never repainted as Failed (Rick 2026-08-26).
    private func finish(failed: String) {
        if state.cancelWasRequested { finish(cancelled: "Stopped — nothing was imported"); return }
        state = .failed(message: failed)
        subtitleText = failed
        importLog.warning("import to sqlite failed: \(failed, privacy: .public)")
    }

    private func finish(cancelled words: String) {
        state = .cancelled
        subtitleText = words
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
                                               ? "dry run — Audit Catalog, Verify Catalog, then the gate, one transaction, comparator, rolled back; catalog saves held until the end"
                                               : "Audit Catalog, Verify Catalog, then import into catalog.sqlite beside the catalog; catalog saves held until the end; the JSON catalog is never deleted"))
        return job
    }

    /// The Import to SQLite run still active, if any (the quit path settles it).
    var activeImportToSQLite: ImportToSQLiteJob? {
        jobs.first { $0.state.isActive && $0 is ImportToSQLiteJob } as? ImportToSQLiteJob
    }

    /// After `stopAllForQuit()`: a job whose end the quit must await before
    /// it replies — Move to Trash settling its file, or Import to SQLite
    /// letting go of the catalog's writes so the held edits can be saved.
    var mustSettleBeforeQuit: Bool { hasActivePruneApply || activeImportToSQLite != nil }

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
