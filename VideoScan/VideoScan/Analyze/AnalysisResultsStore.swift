// AnalysisResultsStore.swift — the Content Analysis ▸ Results sheet's state
// (Rick 2026-11-04: "how can we see what it produced?"; background_service.md
// §6 view 1). What the numbers mean and where each comes from is Core's
// AnalysisResultsReport; this store only loads it, holds the selection and
// the one file list on screen, and hands a click to the existing reveal door.
//
// Shape: a feature store behind a seam (rule 12, #337) — the SHEET owns one
// (@StateObject), built by `production(model:)`; nothing here extends
// VideoScanModel and the model holds nothing new. Every outside call is a
// closure a test replaces.
//
// READ ONLY: the report is built inside the catalog repository's `read` (a
// snapshot on the store's reader — no second committer, no write); the try
// counts are read through EraAttemptStore.snapshot (never compacts). Both
// run in a detached task, off the main actor; the view body reads published
// values only (AnalysisResultsSheetSensorTests).
//
// Reveal: one engine (rule 4) — `VideoScanModel.showInCatalog(recordID:)`,
// the AngelNavigator door (focus, select, Catalog tab, main window forward),
// guarded by `canNavigateToRecord(id:)` like Hallie's and Find Master's.
//
// Logging: one line per load and per failure through the one sink
// (model.log + appLog), never per render.
//
// Cancellation: the report and list reads are held as Task handles; a newer
// request cancels the older one, and the sheet's onDisappear (Done, closing
// the window) cancels both via `cancel()`. The production closures check
// cancellation before each read (cheap); a read already inside SQLite runs
// to its end and its result is dropped.
//
// Memory: one report (a few dozen Ints per analyzer) and one file list of at
// most AnalysisResultsReport.listLimit rows (≈ 300 B each → 3 MB worst case);
// a new selection replaces the list.
//
// (For Rick: a controller with constructor-injected dependencies — closures
// instead of interfaces; `Task.detached` ≈ a worker thread that does not
// inherit the UI thread.)

import Combine
import Foundation
import VideoScanCore

@MainActor
final class AnalysisResultsStore: ObservableObject {

    typealias Outcome = AnalysisResultsReport.Outcome
    typealias LoadReport = @Sendable () async throws -> AnalysisResultsReport
    typealias LoadFiles = @Sendable (_ signer: String, _ outcome: Outcome) async throws -> AnalysisResultsReport.FileList

    @Published private(set) var report: AnalysisResultsReport?
    @Published private(set) var loading = false
    /// Why the report could not be read (the sheet says it in place of the numbers).
    @Published private(set) var failure: String?
    @Published private(set) var signer: String?
    @Published private(set) var outcome: Outcome = .eraFound
    @Published private(set) var files: AnalysisResultsReport.FileList?
    @Published private(set) var filesLoading = false
    @Published private(set) var filesFailure: String?
    /// Words under a row a click could not reveal (removed, or not in this session's catalog).
    @Published private(set) var revealProblem: String?
    /// The journal's waiting / refused line (JournalApplierWords), re-read at every load; nil = not counted yet.
    @Published private(set) var journalWords: String?

    private let loadReport: LoadReport
    private let loadFiles: LoadFiles
    private let reveal: (UUID) -> Bool
    private let note: (String) -> Void
    private let readJournalWords: () -> String?
    /// The file dossier's one door (FileDossierLoader.production) for "Show
    /// Dossier"; nil = the button is absent (tests that do not need it).
    let dossiers: FileDossierLoader?
    /// The newest list request; an older one that lands later is dropped.
    private var issued = 0
    /// The reads in flight: a newer request, Done, or the sheet closing cancels them
    /// (review 11/04: a superseded 10k-row read must not run to the end).
    private var reportTask: Task<AnalysisResultsReport, Error>?
    private var listTask: Task<AnalysisResultsReport.FileList, Error>?

    init(loadReport: @escaping LoadReport, loadFiles: @escaping LoadFiles, reveal: @escaping (UUID) -> Bool,
         note: @escaping (String) -> Void = { _ in }, journalWords: @escaping () -> String? = { nil },
         dossiers: FileDossierLoader? = nil) {
        self.loadReport = loadReport
        self.loadFiles = loadFiles
        self.reveal = reveal
        self.note = note
        self.readJournalWords = journalWords
        self.dossiers = dossiers
    }

    /// Stop every read in flight (the sheet calls it when it goes away).
    func cancel() {
        issued += 1
        reportTask?.cancel()
        listTask?.cancel()
        reportTask = nil
        listTask = nil
    }

    /// The real thing: this session's catalog.sqlite reader, the helper's
    /// state folder beside the catalog (`background/`, as the journal), the
    /// existing reveal door, the one log sink.
    static func production(model: VideoScanModel) -> AnalysisResultsStore {
        let repository = model.catalogCutover.committer?.repository
        let stateRoot = URL(fileURLWithPath: model.catalogStore.fileLocation).deletingLastPathComponent()
            .appendingPathComponent("background", isDirectory: true)
        // The helper's journal: the second half of the planner's "answered" rule.
        let journal = ObservationJournal(directory: EraPlanner.journalDirectory(stateRoot: stateRoot))
        let notOpen = Refusal("catalog.sqlite is not open in this session — there is nothing to read")
        return AnalysisResultsStore(
            loadReport: {
                guard let repository else { throw notOpen }
                try Task.checkCancellation()
                let attempts = AnalysisResultsReport.readAttempts(stateRoot: stateRoot)
                let now = Int64(Date().timeIntervalSince1970)
                try Task.checkCancellation()
                return try await repository.read {
                    try AnalysisResultsReport.build(reader: $0, attempts: attempts, journal: journal, now: now)
                }
            },
            loadFiles: { signer, outcome in
                guard let repository else { throw notOpen }
                try Task.checkCancellation()
                // Unreadable try counts are the list's failure in words, never "No files" (review 11/04).
                let attempts = outcome == .inProgress ? try AnalysisResultsReport.readAttempts(stateRoot: stateRoot).get() : nil
                try Task.checkCancellation()
                return try await repository.read {
                    try AnalysisResultsReport.files(reader: $0, signer: signer, outcome: outcome, attempts: attempts, journal: journal)
                }
            },
            reveal: { [weak model] id in
                guard let model, model.canNavigateToRecord(id: id) else { return false }
                model.showInCatalog(recordID: id)
                return true
            },
            note: { [weak model] line in
                model?.log("Content Analysis ▸ Results: " + line)
                appLog.write("[analysis-results] " + line)
            },
            journalWords: { [weak model] in model?.journalApplier.counts.map(JournalApplierWords.statusLine) },
            dossiers: FileDossierLoader.production(model: model))
    }

    /// The analyzer on screen (the seated one first).
    var analyzer: AnalysisResultsReport.Analyzer? {
        report?.analyzers.first { $0.signer == signer } ?? report?.analyzers.first
    }

    // MARK: Loading (off the main actor)

    /// The report, then the selected outcome's list.
    func load() async {
        loading = true
        defer { loading = false }
        journalWords = readJournalWords()
        let started = ContinuousClock.now
        let load = loadReport
        reportTask?.cancel()
        let task = Task.detached(priority: .userInitiated) { try await load() }
        reportTask = task
        do {
            let built = try await task.value
            guard !task.isCancelled else { return }
            report = built
            failure = nil
            if signer == nil || !built.analyzers.contains(where: { $0.signer == signer }) { signer = built.analyzers.first?.signer }
            let took = ContinuousClock.now - started
            note("read \(built.analyzers.count) analyzer\(built.analyzers.count == 1 ? "" : "s") in "
                 + "\(took.formatted(.units(allowed: [.milliseconds])))"
                 + (built.triesProblem.map { " — tries in progress unavailable: \($0)" } ?? ""))
        } catch {
            guard !task.isCancelled else { return }
            failure = "\(error)"
            note("could not be read — \(error)")
            return
        }
        await loadList()
    }

    func select(signer: String) async {
        guard signer != self.signer else { return }
        self.signer = signer
        await loadList()
    }

    func select(outcome: Outcome) async {
        guard outcome != self.outcome || files == nil else { return }
        self.outcome = outcome
        await loadList()
    }

    private func loadList() async {
        guard let signer = analyzer?.signer else { files = nil; return }
        issued += 1
        let mine = issued
        let outcome = outcome
        let load = loadFiles
        filesLoading = true
        revealProblem = nil
        defer { if mine == issued { filesLoading = false } }
        listTask?.cancel()                         // the older read stops; its result would be dropped anyway
        let task = Task.detached(priority: .userInitiated) { try await load(signer, outcome) }
        listTask = task
        do {
            let list = try await task.value
            guard mine == issued else { return }
            files = list
            filesFailure = nil
        } catch {
            guard mine == issued else { return }
            files = nil
            filesFailure = "\(error)"
            note("the \(outcome.title) list could not be read — \(error)")
        }
    }

    // MARK: Reveal

    /// The selected row in the Catalog, through the existing door; false (and
    /// words under the list) when it cannot be shown.
    @discardableResult
    func reveal(_ row: AnalysisResultsReport.FileRow) -> Bool {
        guard let id = row.recordID, reveal(id) else {
            revealProblem = "\(row.filename) is not in this session's catalog"
                + (row.removed ? " (every copy was removed from the catalog)" : "") + " — nothing to show"
            return false
        }
        revealProblem = nil
        return true
    }
}
