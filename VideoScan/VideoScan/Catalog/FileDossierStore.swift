// FileDossierStore.swift — the file dossier view's state and its ONE door
// (docs/design/file_dossier_view.md, phase 1; Rick approved 2026-11-05).
//
// One sentence: `FileDossierLoader.production(model:)` is the only way the
// app reads a file's dossier — Core's FileDossier.read inside this session's
// catalog repository `read` (the same read-only door MachineEraStore and
// AnalysisResultsStore use; no second committer, no write, no schema change)
// — and each FileDossierView owns one FileDossierStore that runs it off the
// main actor and publishes the result. The three call sites (the inspector,
// the Dossier window's completed rows, the Results sheet) all go through it
// (rule 4; FileDossierSensorTests pins it).
//
// Shape: a feature store behind a seam (rule 12, #337) — the VIEW owns one
// (@StateObject); nothing extends VideoScanModel and the model holds nothing
// new. The loader is a value of closures a test replaces.
//
// Truth: a result is published only for the file it was read for (a newer
// request drops an older one), so one file's dossier is never shown beside
// another's. A failed read is shown in words and logged once per reason;
// a missing row ("no whole-file hash yet") is its own state, never an empty
// dossier.
//
// Refresh: the store re-reads when stored analysis may have changed — a
// journal pass that moved the machine eras (already committed: read now), or
// an edit through any save funnel (`.videoScanCatalogMutated`,
// `catalogMutationRevision`, bumped by the dossier writeback too). An edit
// reaches catalog.sqlite only after the committer's debounce
// (CatalogCommitter.debounce, 2 s), so `afterCommit` SAMPLES those signals
// (throttle, latest) and reads one sample later: an edit at t shows by
// t + 3 s, and a steady stream of commits (a batch Analyze run) still
// refreshes an open dossier every 3 s — a debounce would starve it (review
// 11/05). The store throttles its own reads to one a second.
//
// One loader per model (review 11/05): `production(model:)` memoizes, so a
// parent's body asks for it freely and gets the same loader — same id, same
// publishers — and FileDossierView is Equatable on (file, loader).
//
// Logging: one line per failure (deduplicated) and per slow read (> 250 ms)
// through the one sink; a normal read is ~2 ms (Core's scale test) and is
// not logged — selection changes in the inspector would flood the log.
//
// Memory: one FileDossier per open view (one file's captions, OCR and
// transcript — ≤ a few hundred KB for a 2-hour tape).
//
// (For Rick: a controller with constructor-injected closures, as
// AnalysisResultsStore; `Task.detached` ≈ a worker thread that does not
// inherit the UI thread.)

import Combine
import Foundation
import VideoScanCore

/// THE door: how the app reads one file's dossier.
struct FileDossierLoader {
    typealias Load = @Sendable (_ fileID: UUID) async throws -> FileDossier?

    /// Identity for FileDossierView's equality (closures have none).
    let id = UUID()
    let load: Load
    /// The one log sink.
    let note: @MainActor (String) -> Void
    /// Fires when stored analysis may have changed.
    let changes: AnyPublisher<Void, Never>

    /// The sampling period for edits: the committer's debounce (2 s) plus 1 s.
    /// A literal because CatalogCommitter is main-actor isolated; a test pins
    /// it to `CatalogCommitter.debounce + 1 s`.
    nonisolated static let commitSample: Duration = .seconds(3)

    /// Edits → reads that land after the edit is committed: one sample per
    /// period (throttle, latest) — so a steady stream still gets through —
    /// each read one period later, after the committer's debounce.
    static func afterCommit(_ edits: AnyPublisher<Void, Never>, period: Duration = commitSample) -> AnyPublisher<Void, Never> {
        let stride = DispatchQueue.SchedulerTimeType.Stride.seconds(TimingBudget.seconds(period))
        return edits.throttle(for: stride, scheduler: DispatchQueue.main, latest: true)
            .delay(for: stride, scheduler: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    /// One loader per model, built once (the publishers too); every call site
    /// gets this same value. Weak: a closed model's entry is replaced.
    @MainActor private static var built: [ObjectIdentifier: (model: WeakModel, loader: FileDossierLoader)] = [:]

    private final class WeakModel {
        weak var model: VideoScanModel?
        init(_ model: VideoScanModel) { self.model = model }
    }

    /// This session's catalog.sqlite reader, resolved at each read (a reopened
    /// catalog is read, never a stale handle).
    @MainActor
    static func production(model: VideoScanModel) -> FileDossierLoader {
        let key = ObjectIdentifier(model)
        if let entry = built[key], entry.model.model === model { return entry.loader }
        let loader = make(model: model)
        built = built.filter { $0.value.model.model != nil }
        built[key] = (WeakModel(model), loader)
        return loader
    }

    @MainActor
    private static func make(model: VideoScanModel) -> FileDossierLoader {
        let catalogEdits = NotificationCenter.default.publisher(for: .videoScanCatalogMutated).map { _ in () }
        let revisions = model.$catalogMutationRevision.dropFirst().map { _ in () }
        let eras = model.machineEras.$eras.dropFirst().map { _ in () }
        let committed = afterCommit(catalogEdits.merge(with: revisions).eraseToAnyPublisher())
        return FileDossierLoader(
            load: { [weak model] fileID in
                let repository = await MainActor.run { model?.catalogCutover.committer?.repository }
                guard let repository else { throw Refusal("catalog.sqlite is not open in this session — there is nothing to read") }
                try Task.checkCancellation()
                let now = Date()
                return try await repository.read { try FileDossier.read(reader: $0, fileID: fileID.uuidString, now: now) }
            },
            note: { [weak model] line in
                model?.log("File dossier: " + line)
                appLog.write("[file-dossier] " + line)
            },
            changes: committed.merge(with: eras).eraseToAnyPublisher())
    }
}

@MainActor
final class FileDossierStore: ObservableObject {

    enum Shown: Equatable {
        case idle
        case loading
        case loaded(FileDossier)
        /// No catalog row for this file id (a file waiting for its whole-file hash, or not in this catalog).
        case notStored
        case failed(String)
    }

    nonisolated static let slowRead: Duration = .milliseconds(250)

    @Published private(set) var shown: Shown = .idle
    private(set) var fileID: UUID?
    /// Completed reads (tests).
    private(set) var reads = 0

    private var loader: FileDossierLoader?
    private var issued = 0
    private var task: Task<FileDossier?, Error>?
    private var changes: AnyCancellable?
    private var said: Set<String> = []

    init() {}

    /// Show `fileID`'s dossier (nil = the file has no catalog id). Called from
    /// the view's `.task(id:)`, so a new selection cancels the old read.
    func show(fileID: UUID?, loader: FileDossierLoader) async {
        self.loader = loader
        if changes == nil {
            // Throttle, latest (review 11/05): a steady stream still reads, at most once a second.
            changes = loader.changes
                .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
                .sink { [weak self] in MainActor.assumeIsolated { self?.reloadSoon() } }
        }
        guard let fileID else {
            // No catalog id: say so, and stop any read begun for the previous file.
            cancelRead()
            self.fileID = nil
            shown = .notStored
            return
        }
        if fileID != self.fileID { shown = .loading }
        self.fileID = fileID
        await reload()
    }

    /// Re-read the shown file (a refresh keeps the old lines until the new ones land).
    func reload() async {
        guard let loader, let fileID else { return }
        issued += 1
        let mine = issued
        task?.cancel()
        let load = loader.load
        let started = ContinuousClock.now
        let read = Task.detached(priority: .userInitiated) { try await load(fileID) }
        task = read
        do {
            let dossier = try await read.value
            guard mine == issued, fileID == self.fileID else { return }      // a newer request owns the publish
            reads += 1
            shown = dossier.map(Shown.loaded) ?? .notStored
            let took = ContinuousClock.now - started
            if took > Self.slowRead {
                loader.note("\(dossier?.filename ?? fileID.uuidString) read in \(took.formatted(.units(allowed: [.milliseconds]))) (slow)")
            }
        } catch {
            guard mine == issued, fileID == self.fileID, !(error is CancellationError) else { return }
            let why = "\(error)"
            shown = .failed(why)
            if said.insert(why).inserted { loader.note("could not be read for \(fileID.uuidString) — \(why)") }
        }
    }

    /// The view went away: stop the read in flight and the change subscription
    /// (re-made by the next `show`).
    func cancel() {
        cancelRead()
        changes = nil
    }

    /// Whether the change subscription is live (tests).
    var isListening: Bool { changes != nil }

    private func cancelRead() {
        issued += 1
        task?.cancel()
        task = nil
    }

    private func reloadSoon() {
        Task { [weak self] in await self?.reload() }
    }
}
