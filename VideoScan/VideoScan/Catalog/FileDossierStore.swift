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
// Refresh: the store re-reads (debounced 1 s) when stored analysis may have
// changed — a catalog edit (.videoScanCatalogMutated) or a journal pass that
// moved the machine eras — so the view fills in as results land.
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

    let load: Load
    /// The one log sink.
    let note: @MainActor (String) -> Void
    /// Fires when stored analysis may have changed.
    let changes: AnyPublisher<Void, Never>

    /// This session's catalog.sqlite reader, resolved at each read (a reopened
    /// catalog is read, never a stale handle).
    @MainActor
    static func production(model: VideoScanModel) -> FileDossierLoader {
        let catalogEdits = NotificationCenter.default.publisher(for: .videoScanCatalogMutated).map { _ in () }
        let eras = model.machineEras.$eras.dropFirst().map { _ in () }
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
            changes: catalogEdits.merge(with: eras).eraseToAnyPublisher())
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
            changes = loader.changes
                .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
                .sink { [weak self] in MainActor.assumeIsolated { self?.reloadSoon() } }
        }
        if fileID != self.fileID { shown = fileID == nil ? .notStored : .loading }
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

    func cancel() {
        issued += 1
        task?.cancel()
        task = nil
    }

    private func reloadSoon() {
        Task { [weak self] in await self?.reload() }
    }
}
