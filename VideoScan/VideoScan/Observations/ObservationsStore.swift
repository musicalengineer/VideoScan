// ObservationsStore.swift — the Observations window's state and its ONE door
// (docs/design/file_dossier_view.md Part II; Rick 2026-11-06: "where can I
// query the observations and see what the models have learned?").
//
// One sentence: `ObservationsLoader.production(model:)` is the only way the
// app reads the observations — Core's ObservationsReport / ObservationsSearch
// inside this session's catalog repository `read` (the same read-only door
// FileDossierLoader and AnalysisResultsStore use; no second committer, no
// write, no schema change) — and each window owns one ObservationsStore
// that runs it off the main actor and publishes the result.
//
// Shape: a feature store behind a seam (rule 12, #337) — the WINDOW owns one;
// nothing extends VideoScanModel and the model holds nothing new. The loader
// is a value of closures a test replaces (the mockups drive it with fixtures).
//
// Truth: a result is published only for the scope and query it was read for
// (a newer request drops an older one). A failed read is shown in words and
// logged once per reason through the one sink.
//
// Reveal: one engine (rule 4) — `VideoScanModel.showInCatalog(recordID:)`,
// guarded by `canNavigateToRecord(id:)`; the dossier through
// FileDossierLoader.production (the one dossier door).
//
// Memory: one report (a few hundred rows) and one search (≤ 2,000 hits).
//
// (For Rick: a controller with constructor-injected closures;
// `Task.detached` ≈ a worker thread that does not inherit the UI thread.)

import Combine
import Foundation
import VideoScanCore

/// THE door: how the app reads the observations.
struct ObservationsLoader {
    typealias LoadReport = @Sendable (_ scope: ObservationsScope) async throws -> ObservationsReport
    typealias Search = @Sendable (_ scope: ObservationsScope, _ query: String) async throws -> ObservationsSearch

    let id = UUID()
    let loadReport: LoadReport
    let search: Search
    /// The selected hit's file in the Catalog; false when it cannot be shown.
    let reveal: @MainActor (UUID) -> Bool
    /// The file dossier's one door (nil = no dossier, tests).
    let dossiers: FileDossierLoader?
    /// The one log sink.
    let note: @MainActor (String) -> Void

    @MainActor private static var built: [ObjectIdentifier: (model: WeakModel, loader: ObservationsLoader)] = [:]

    private final class WeakModel {
        weak var model: VideoScanModel?
        init(_ model: VideoScanModel) { self.model = model }
    }

    /// One loader per model, built once; every call site gets this same value.
    @MainActor
    static func production(model: VideoScanModel) -> ObservationsLoader {
        let key = ObjectIdentifier(model)
        if let entry = built[key], entry.model.model === model { return entry.loader }
        let loader = make(model: model)
        built = built.filter { $0.value.model.model != nil }
        built[key] = (WeakModel(model), loader)
        return loader
    }

    @MainActor
    private static func make(model: VideoScanModel) -> ObservationsLoader {
        let notOpen = Refusal("catalog.sqlite is not open in this session — there is nothing to read")
        return ObservationsLoader(
            loadReport: { [weak model] scope in
                let repository = await MainActor.run { model?.catalogCutover.committer?.repository }
                guard let repository else { throw notOpen }
                try Task.checkCancellation()
                let now = Date()
                return try await repository.read { try ObservationsReport.build(reader: $0, scope: scope, now: now) }
            },
            search: { [weak model] scope, query in
                let repository = await MainActor.run { model?.catalogCutover.committer?.repository }
                guard let repository else { throw notOpen }
                try Task.checkCancellation()
                let now = Date()
                return try await repository.read { try ObservationsSearch.search(reader: $0, scope: scope, query: query, now: now) }
            },
            reveal: { [weak model] id in
                guard let model, model.canNavigateToRecord(id: id) else { return false }
                model.showInCatalog(recordID: id)
                return true
            },
            dossiers: FileDossierLoader.production(model: model),
            note: { [weak model] line in
                model?.log("Observations: " + line)
                appLog.write("[observations] " + line)
            })
    }
}

@MainActor
final class ObservationsStore: ObservableObject {

    @Published private(set) var scope: ObservationsScope
    @Published private(set) var report: ObservationsReport?
    @Published private(set) var loading = false
    @Published private(set) var failure: String?
    @Published private(set) var search: ObservationsSearch?
    @Published private(set) var searching = false
    @Published private(set) var searchFailure: String?
    /// Words under the hits when a click could not reveal the file.
    @Published private(set) var revealProblem: String?
    /// Completed reads (tests).
    private(set) var reads = 0

    let loader: ObservationsLoader
    private var reportTask: Task<ObservationsReport, Error>?
    private var searchTask: Task<ObservationsSearch, Error>?
    private var issued = 0
    private var searchIssued = 0
    private var said: Set<String> = []

    init(scope: ObservationsScope, loader: ObservationsLoader) {
        self.scope = scope
        self.loader = loader
    }

    /// Read the report for the scope (a newer request drops an older one).
    func load() async {
        issued += 1
        let mine = issued
        reportTask?.cancel()
        loading = true
        let scope = scope
        let load = loader.loadReport
        let started = ContinuousClock.now
        let task = Task.detached(priority: .userInitiated) { try await load(scope) }
        reportTask = task
        do {
            let built = try await task.value
            guard mine == issued else { return }
            report = built
            failure = nil
            loading = false
            reads += 1
            let took = ContinuousClock.now - started
            loader.note("read \(scope.words): \(built.files.formatted()) files, \(built.analyzed.formatted()) analyzed, in \(took.formatted(.units(allowed: [.milliseconds])))")
        } catch {
            guard mine == issued, !(error is CancellationError) else { return }
            loading = false
            failure = "\(error)"
            if said.insert(failure ?? "").inserted { loader.note("could not be read for \(scope.words) — \(error)") }
        }
    }

    /// A new scope: re-read, and re-run the search on it.
    func set(scope: ObservationsScope) async {
        guard scope != self.scope else { return }
        self.scope = scope
        search = nil
        await load()
    }

    /// Search the observations in scope; an empty or too-short query clears the hits.
    func search(_ query: String) async {
        searchIssued += 1
        let mine = searchIssued
        searchTask?.cancel()
        revealProblem = nil
        guard ObservationsSearch.normalized(query) != nil else {
            search = nil
            searching = false
            searchFailure = nil
            return
        }
        searching = true
        let scope = scope
        let run = loader.search
        let task = Task.detached(priority: .userInitiated) { try await run(scope, query) }
        searchTask = task
        do {
            let found = try await task.value
            guard mine == searchIssued else { return }
            search = found
            searchFailure = nil
            searching = false
            loader.note("searched \"\(query)\" in \(scope.words): \(found.hits.count.formatted()) hit\(found.hits.count == 1 ? "" : "s")\(found.truncated ? " (capped)" : "")")
        } catch {
            guard mine == searchIssued, !(error is CancellationError) else { return }
            searching = false
            searchFailure = "\(error)"
        }
    }

    /// The hit's file in the Catalog, through the existing door; words under the list when it cannot be shown.
    @discardableResult
    func reveal(_ hit: ObservationsSearch.Hit) -> Bool {
        guard let id = hit.recordID, loader.reveal(id) else {
            revealProblem = "\(hit.filename) is not in this session's catalog" + (hit.removed ? " (every copy was removed from the catalog)" : "") + " — nothing to show"
            return false
        }
        revealProblem = nil
        return true
    }

    /// The window went away: stop every read in flight.
    func cancel() {
        issued += 1
        searchIssued += 1
        reportTask?.cancel()
        searchTask?.cancel()
        reportTask = nil
        searchTask = nil
    }
}
