// ValidateCatalogJob.swift
// Catalog ▸ "Validate Catalog…" — ONE verb (Rick 2026-10-20): check every
// file on disk, then check the catalog agrees with itself, as ONE Media File
// Operation. One sentence: Validate Catalog runs the existing disk audit
// (CatalogAuditJob) and, only when that audit COMPLETED and its record
// beside the catalog is this run's, the existing Verify Catalog
// (VerifyCatalogJob) — so Verify's tier 0 never judges an old picture of
// the disk.
//
// Why one verb: "Verify Catalog" used to be its own menu item. Its tier 0
// reads the audit's stamps and record, so Verify alone (after a week with
// no audit, or after a stopped one) graded the catalog against a stale disk
// picture and said nothing about it.
//
// Shape (Import to SQLite's composition, through the shared
// CatalogPhaseDriver): the two phase jobs are made here, run in order, and
// are NOT added to the center — the row is this job's. Neither engine is
// changed: the audit marks / stamps / saves exactly as before (codex
// r1–r6, 10/16); Verify reads the catalog in use and writes only
// integrity-latest.json (and its dated copy) beside it.
//
//   1. FILES — CatalogAuditJob with the model's run marker (never nil: tier
//      0 reads the record the marker writes). 0–80 % of the bar.
//   GATE — the audit's terminal state through ImportPhaseVerdict (finished =
//      go on; stopped / failed / refused = stop here, Verify never made);
//      then catalog-audit.json, read back, must be THIS run's completed
//      record (`auditRecordProblem`). A stale record — an older run, a
//      stopped or failed one, an unreadable file — stops the job too.
//   2. CATALOG — VerifyCatalogJob over the catalog in use. 80–100 %.
//
// Logging: ONE START and ONE OUTCOME line of this job through its sink
// (`validateCatalogNote`: console + catalog.log, videoscan.log as
// "[validate-catalog]", the unified log). The phase jobs keep their own
// lines ("Audit catalog: …", "Verify catalog: …") unchanged — the nightly's
// greps and the codex-pinned formats stay as they are.
//
// Stop is forwarded to the phase in flight (the audit finishes its chunk and
// saves what it marked; Verify ends after its tier); a Stop between the
// phases starts no Verify. Pause / Resume are forwarded the same way.
//
// Memory: the audit's budget, then Verify's (their headers; one at a time),
// plus one read of catalog-audit.json (≈ 1 MB at 10k rows). Nothing here
// grows with the rows.
//
// (For Rick: `weak var model` ≈ a non-owning pointer that becomes nil when
// the model goes away; `@Published` ≈ a field whose setter notifies the
// observing views, like a Qt property with a NOTIFY signal.)

import Combine
import Foundation
import SwiftUI
import os

private let validateCatalogLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "validateCatalog")

@MainActor
final class ValidateCatalogJob: @MainActor MediaFileOperationJob, MediaFileOperationOwnDetail {

    /// Which step the row is on.
    enum Phase: Equatable {
        case files, catalog, done
    }

    static let title = "Validate Catalog"

    let id = UUID()
    let kind: MediaFileOperationKind = .validateCatalog
    let startedAt = Date()
    private weak var model: VideoScanModel?
    private let marker: CatalogAuditRunMarker
    private let driver = CatalogPhaseDriver()
    private var stopRequested = false

    /// TEST SEAMS (nil in production): point the phase jobs at a sandbox
    /// (lane roots, no shared events store) before each starts.
    var configureAuditForTesting: ((CatalogAuditJob) -> Void)?
    var configureVerifyForTesting: ((VerifyCatalogJob) -> Void)?

    @Published private(set) var phase: Phase = .files
    /// How the run ended (nil while it runs) — the detail view's words.
    @Published private(set) var ending: ValidateCatalogEnding?
    @Published private(set) var state: MediaFileOperationState = .running {
        didSet { if !state.isActive, finishedAt == nil { finishedAt = Date() } }
    }
    @Published private(set) var finishedAt: Date?
    @Published private(set) var subtitleText = "Preparing…"
    @Published private(set) var fractionValue: Double = 0
    private(set) var wasRefused = false
    /// Internal so tests (and the CLI) can `await job.task?.value`.
    private(set) var task: Task<Void, Never>?
    /// The two phase jobs (internal so tests and the detail view read them).
    /// `verifyJob` stays nil unless the audit completed.
    @Published private(set) var auditJob: CatalogAuditJob?
    @Published private(set) var verifyJob: VerifyCatalogJob?

    var title: String { Self.title }
    var subtitle: String { subtitleText }
    var fraction: Double { fractionValue }
    var isIndeterminate: Bool { false }
    var canPause: Bool { state == .running && driver.canPause }
    var isPaused: Bool { driver.isPaused }
    var detailView: AnyView { AnyView(ValidateCatalogDetailView(job: self)) }

    init(model: VideoScanModel, marker: CatalogAuditRunMarker) {
        self.model = model
        self.marker = marker
    }

    // MARK: Lifecycle

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
    }

    func refuseToStart(reason: String) {
        guard task == nil, state.isActive else { return }
        wasRefused = true
        let end = ValidateCatalogEnding.couldNotStart(reason)
        ending = end
        apply(end.outcome(refused: true))
        task = Task {}
    }

    /// Stop: forwarded to the phase in flight; no later phase starts.
    func cancel() {
        guard state.isActive else { return }
        state = .cancelling
        stopRequested = true
        driver.cancel()
        subtitleText = "Stopping…"
    }

    func pause() {
        guard state == .running else { return }
        driver.pause()
        objectWillChange.send()
    }

    func resume() {
        driver.resume()
        objectWillChange.send()
    }

    // MARK: Run

    private func run() async {
        guard let model else {
            apply(ValidateCatalogEnding.couldNotStart("the catalog went away before the job could start").outcome(refused: false))
            return
        }
        model.validateCatalogNote("START — " + Self.startWords)
        let mirror = driver.mirror { [weak self] subtitle, fraction in self?.copyPhaseProgress(subtitle, fraction) }
        let end = await runPhases(model: model)
        mirror.cancel()
        phase = .done
        ending = end
        let outcome = end.outcome(refused: wasRefused)
        model.validateCatalogNote(outcome.logLine)
        apply(outcome)
    }

    static let startWords = "step 1 of 2 checks every file on disk (one stat per row; gone → Missing, back → live); "
        + "step 2 checks the catalog agrees with itself (tiers 0–6, the report beside the catalog) — "
        + "only after a complete step 1. Nothing on media is opened, moved or deleted."

    /// The two phases and the gate between them.
    private func runPhases(model: VideoScanModel) async -> ValidateCatalogEnding {
        let audit = CatalogAuditJob(model: model, marker: marker)
        configureAuditForTesting?(audit)
        auditJob = audit
        let audited = ImportPhaseVerdict.of(await runPhase(audit, .files, span: 0...0.8), step: "the file check")
        wasRefused = audit.wasRefused
        guard audited == .proceed else { return .filesNotChecked(audited) }
        let files = audit.subtitle
        if stopRequested { return .stoppedBetween(files: files) }
        if let problem = Self.auditRecordProblem(readAuditRecord(), auditStartedAt: audit.startedAt, written: marker.lastRun) {
            return .auditRecordNotThisRun(problem, files: files)
        }
        // Import's second-boundary rule (ImportToSQLiteTiming, QA P3-c): the
        // report's start is a whole second after the file check's end, so
        // any reader that orders the two by their ISO-8601 seconds (Import's
        // gate does) sees the report as AFTER the audit it stands on.
        let ready = await ImportToSQLiteTiming.waitForVerifyStart(auditFinishedAt: audit.finishedAt ?? Date(), now: { Date() },
                                                                  sleep: { try? await Task.sleep(for: .seconds($0)) })
        if stopRequested { return .stoppedBetween(files: files) }
        guard ready else {
            return .auditRecordNotThisRun("the wall clock kept stepping back — the catalog check could not start a whole second after the file check ended",
                                          files: files)
        }
        let verify = VerifyCatalogJob(model: model)
        configureVerifyForTesting?(verify)
        verifyJob = verify
        let checked = ImportPhaseVerdict.of(await runPhase(verify, .catalog, span: 0.8...1), step: "the catalog check")
        guard checked == .proceed else { return .catalogNotChecked(checked, files: files) }
        return .validated(files: files, catalog: verify.subtitle)
    }

    private func runPhase(_ child: any ImportPhaseJob, _ next: Phase, span: ClosedRange<Double>) async -> MediaFileOperationState {
        phase = next
        subtitleText = Self.lead(next) + "…"
        fractionValue = span.lowerBound
        return await driver.run(child, span: span, stopRequested: stopRequested)
    }

    private func copyPhaseProgress(_ subtitle: String, _ fraction: Double) {
        guard state == .running else { return }
        subtitleText = Self.lead(phase) + " — " + subtitle
        fractionValue = fraction
    }

    /// The row's lead words per step.
    nonisolated static func lead(_ phase: Phase) -> String {
        switch phase {
        case .files: return "Step 1 of 2 · checking files on disk"
        case .catalog: return "Step 2 of 2 · checking the catalog agrees with itself"
        case .done: return "Validate Catalog"
        }
    }

    /// catalog-audit.json as the audit just left it, read back from where
    /// its marker writes it — the same file Verify's tier 0 reads. One
    /// small read on the main actor, as the marker's own `attach` does.
    private func readAuditRecord() -> CatalogAuditRunRecord? {
        guard let folder = marker.fileURL?.deletingLastPathComponent() else { return nil }
        return CatalogFreshnessFactsReader.auditRecord(in: folder)
    }

    /// PURE: nil when `record` is THIS run's completed audit; otherwise
    /// why Verify must not run. The record's dates are ISO-8601 whole
    /// seconds (truncated), so "this run" = started no earlier than the
    /// whole second the audit job was made in.
    /// `now` bounds it from above (QA P3-b: a record dated in the future —
    /// a copied marker, a clock that stepped back — is no proof of this
    /// run); `written` is the record the run's marker holds in memory, and
    /// the file must be that one (same start, to the whole second).
    nonisolated static func auditRecordProblem(_ record: CatalogAuditRunRecord?, auditStartedAt: Date, now: Date = Date(),
                                               written: CatalogAuditRunRecord? = nil) -> String? {
        guard let record else {
            return "the file check's record beside the catalog (\(CatalogFreshnessFactsReader.auditMarkerFileName)) could not be read back"
        }
        guard record.startedAt.timeIntervalSince1970 >= auditStartedAt.timeIntervalSince1970.rounded(.down) else {
            return "the file check's record beside the catalog is an older run's, not this one's"
        }
        guard record.startedAt <= now, (record.finishedAt ?? now) <= now else {
            return "the file check's record beside the catalog is dated after now — not this run's"
        }
        if let written, abs(record.startedAt.timeIntervalSince(written.startedAt)) >= 1 {
            return "the file check's record beside the catalog is not the one this run wrote"
        }
        guard record.outcome == .completed, record.finishedAt != nil else {
            return "the file check's record beside the catalog says \(record.outcome.rawValue), not completed"
        }
        return nil
    }

    // MARK: Finish

    private func apply(_ outcome: ValidateCatalogOutcome) {
        state = outcome.state
        subtitleText = outcome.rowWords
        if case .finished = outcome.state { fractionValue = 1 }
        if case .failed(let message) = outcome.state {
            validateCatalogLog.warning("validate catalog failed: \(message, privacy: .public)")
        }
    }
}

// MARK: - How it ended (pure)

/// What the row, the OUTCOME line and the CLI's exit code say.
struct ValidateCatalogOutcome: Equatable {
    let state: MediaFileOperationState
    let rowWords: String
    let logLine: String
}

/// How a Validate Catalog run ended, before the words are chosen.
/// (For Rick: an enum with associated values ≈ a C++ std::variant of small
/// structs; `switch` over it must name every case.)
enum ValidateCatalogEnding: Equatable {
    /// Both steps completed.
    case validated(files: String, catalog: String)
    /// Step 1 stopped, failed or was refused — Verify was never made.
    case filesNotChecked(ImportPhaseVerdict)
    /// Stop arrived after step 1 completed and before step 2 began.
    case stoppedBetween(files: String)
    /// Step 1 completed but its record beside the catalog is not this run's.
    case auditRecordNotThisRun(String, files: String)
    /// Step 2 stopped or could not complete.
    case catalogNotChecked(ImportPhaseVerdict, files: String)
    /// Refused before any work (another check running, an import, no model).
    case couldNotStart(String)

    static let catalogSkipped = "The catalog was NOT checked against itself — Validate Catalog checks it only right after "
        + "a complete check of the files on disk."

    var verifyRan: Bool {
        switch self {
        case .validated, .catalogNotChecked: return true
        case .filesNotChecked, .stoppedBetween, .auditRecordNotThisRun, .couldNotStart: return false
        }
    }

    func outcome(refused: Bool) -> ValidateCatalogOutcome {
        switch self {
        case .validated(let files, let catalog):
            return .done("files: \(files) · catalog: \(catalog)")
        case .filesNotChecked(let verdict):
            return Self.ended(verdict, stopped: "while checking files on disk; the marks it saved are kept",
                              then: Self.catalogSkipped, refused: refused)
        case .stoppedBetween(let files):
            return .stopped("after checking files on disk — " + Self.sentence(files) + " " + Self.catalogSkipped)
        case .auditRecordNotThisRun(let why, let files):
            return .failed(Self.sentence(why) + " Files: " + Self.sentence(files) + " " + Self.catalogSkipped, refused: false)
        case .catalogNotChecked(let verdict, let files):
            return Self.ended(verdict, stopped: "while checking the catalog agrees with itself; its report says stopped (partial)",
                              then: "Files: " + Self.sentence(files), refused: false)
        case .couldNotStart(let why):
            return .failed(Self.sentence(why) + " Nothing was checked.", refused: refused)
        }
    }

    /// A phase that did not go on: Stop → stopped; anything else → failed
    /// with the phase's own words.
    private static func ended(_ verdict: ImportPhaseVerdict, stopped: String, then tail: String,
                              refused: Bool) -> ValidateCatalogOutcome {
        switch verdict {
        case .stopped: return .stopped(sentence(stopped) + " " + tail)
        case .couldNotComplete(let words): return .failed(sentence(words) + " " + tail, refused: refused)
        case .proceed: return .failed("the step ended without saying how. " + tail, refused: refused)
        }
    }

    /// `words` ending in exactly one full stop (the phase jobs' own words
    /// often end in one already).
    static func sentence(_ words: String) -> String {
        let trimmed = words.trimmingCharacters(in: .whitespaces)
        return trimmed.hasSuffix(".") ? trimmed : trimmed + "."
    }
}

extension ValidateCatalogOutcome {
    static func done(_ words: String) -> Self {
        Self(state: .finished(summary: "Validated — " + words), rowWords: "Validated — " + words,
             logLine: "OUTCOME validated — " + words)
    }

    static func stopped(_ words: String) -> Self {
        Self(state: .cancelled, rowWords: "Stopped " + words, logLine: "OUTCOME stopped — " + words)
    }

    static func failed(_ words: String, refused: Bool) -> Self {
        let lead = refused ? "Refused" : "Failed"
        return Self(state: .failed(message: "\(lead) — " + words), rowWords: "\(lead) — " + words,
                    logLine: "OUTCOME \(lead.lowercased()) — " + words)
    }
}

// MARK: - Model half (the one sink)

extension VideoScanModel {

    /// The one sink: console + catalog.log, videoscan.log, the unified log.
    func validateCatalogNote(_ line: String) {
        log("Validate Catalog: " + line)
        appLog.write("[validate-catalog] " + line)
        validateCatalogLog.notice("\(line, privacy: .public)")
    }
}

// MARK: - Start

extension MediaFileOperationsCenter {

    /// Start "Validate Catalog" over the whole catalog. Refused (nothing
    /// started) while another Validate, or a bare audit or Verify, is
    /// active — one checker of the catalog at a time.
    @discardableResult
    func startValidateCatalog(model: VideoScanModel, marker: CatalogAuditRunMarker) -> ValidateCatalogJob {
        let job = ValidateCatalogJob(model: model, marker: marker)
        let busy = jobs.first { $0.state.isActive && ($0 is ValidateCatalogJob || $0 is CatalogAuditJob || $0 is VerifyCatalogJob) }
        guard add(job) else { return job }
        if let busy {
            job.refuseToStart(reason: "\(busy.title) is already running — wait for it to finish (or stop it)")
            return job
        }
        job.start()
        appLog.write(Self.startSummaryLine(verb: job.kind.logVerb, title: job.title,
                                           plan: "check every file on disk, then check the catalog agrees with itself — the second step only after a complete first; nothing on media is opened"))
        return job
    }

    /// The refusal words for a bare audit or Verify while Validate Catalog
    /// runs (it runs its own; a second audit would write the same marker).
    func validateRunsItsOwn(_ what: String) -> String? {
        guard jobs.contains(where: { $0.state.isActive && $0 is ValidateCatalogJob }) else { return nil }
        return "Validate Catalog is running and runs its own \(what) — wait for it to finish (or stop it). Nothing was started."
    }
}
