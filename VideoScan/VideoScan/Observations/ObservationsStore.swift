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
// Truth: a result is published only for the request (scope, query) it was
// read for, and only while that request is still the current one — the rule
// lives in ONE place, `LatestWins` below, which the Frames store uses too. A
// newer request cancels the one it replaces; a new scope drops the old
// scope's report and hits at once. A failed read is shown in words and
// logged through the one sink (a failed load once per reason).
//
// Reveal: one engine (rule 4) — `VideoScanModel.showInCatalog(recordID:)`,
// guarded by `canNavigateToRecord(id:)`; the dossier through
// FileDossierLoader.production (the one dossier door).
//
// Memory (worst case): one report (a few hundred rows) and one search
// (≤ 2,000 hits); `LatestWins` names each in `value` and in `.loaded` — the
// same copy-on-write buffers, not a second copy.
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

/// Latest wins: the state of ONE kind of request (a load, a search) where only the newest answer may be shown.
///
/// The request is named by its `key` (scope, or scope + words). `begin` cancels the request it replaces and
/// hands back a ticket; `finish` publishes a result only if its ticket is still the current one — so an answer
/// read for an older key can never appear under a newer one, and "is something in flight" is a fact about the
/// current ticket, not a flag someone must remember to clear. `reset` (the field was cleared, the scope
/// changed, the window closed) cancels and returns to `.idle`.
///
/// `value` is the newest answer for the CURRENT key: it stays on screen while the same request is re-run
/// (Refresh) and is dropped the moment the key changes.
///
/// (For Rick: a generation-tagged future — the tag is the task handle itself, compared on completion — in
/// place of three bools and a counter. A struct, so assigning through the owner's `@Published` repaints.)
struct LatestWins<Key: Equatable, Value: Sendable> {
    enum Phase {
        case idle
        case loading
        case loaded(Value)
        case failed(any Error)
    }

    typealias Ticket = Task<Value, any Error>

    private(set) var key: Key?
    private(set) var phase: Phase = .idle
    private(set) var value: Value?
    private var current: Ticket?

    var isLoading: Bool { if case .loading = phase { true } else { false } }
    var failure: (any Error)? { if case .failed(let error) = phase { error } else { nil } }

    /// Start `work` for `key` off the caller's actor; whatever was in flight is cancelled and can no longer publish.
    mutating func begin(_ key: Key, _ work: @escaping @Sendable () async throws -> Value) -> Ticket {
        current?.cancel()
        if key != self.key { value = nil }
        self.key = key
        phase = .loading
        let ticket = Task.detached(priority: .userInitiated) { try await work() }
        current = ticket
        return ticket
    }

    /// Publish `result` if `ticket` is still the current request. False: superseded, reset or cancelled — nothing to say.
    mutating func finish(_ ticket: Ticket, _ result: Result<Value, any Error>) -> Bool {
        guard ticket == current else { return false }
        current = nil
        switch result {
        case .success(let found):
            value = found
            phase = .loaded(found)
            return true
        case .failure(let error) where error is CancellationError:
            phase = value.map(Phase.loaded) ?? .idle    // the work gave up on its own: not a failure to show
            return false
        case .failure(let error):
            phase = .failed(error)
            return true
        }
    }

    /// Nothing asked: cancel what is in flight and forget the key and its answer.
    mutating func reset() {
        current?.cancel()
        self = LatestWins()
    }
}

@MainActor
final class ObservationsStore: ObservableObject {

    /// One search request: the words, and the scope they are asked of.
    struct SearchRequest: Equatable, Sendable {
        let scope: ObservationsScope
        let query: String
    }

    @Published private(set) var scope: ObservationsScope
    @Published private var reportRun = LatestWins<ObservationsScope, ObservationsReport>()
    @Published private var searchRun = LatestWins<SearchRequest, ObservationsSearch>()
    /// Words under the hits when a click could not reveal the file.
    @Published private(set) var revealProblem: String?
    /// Completed reads (tests).
    private(set) var reads = 0

    let loader: ObservationsLoader
    private var said: Set<String> = []

    init(scope: ObservationsScope, loader: ObservationsLoader) {
        self.scope = scope
        self.loader = loader
    }

    // What the view reads — each one a reading of the request's phase, never a flag of its own.
    var report: ObservationsReport? { reportRun.value }
    var loading: Bool { reportRun.isLoading }
    var failure: String? { reportRun.failure.map { "\($0)" } }
    var search: ObservationsSearch? { searchRun.value }
    var searching: Bool { searchRun.isLoading }
    var searchFailure: String? { searchRun.failure.map { "\($0)" } }

    /// Read the report for the scope (a newer request cancels an older one).
    func load() async {
        let scope = scope
        let load = loader.loadReport
        let started = ContinuousClock.now
        let ticket = reportRun.begin(scope) { try await load(scope) }
        let result = await ticket.result
        guard reportRun.finish(ticket, result) else { return }
        switch result {
        case .success(let built):
            reads += 1
            let took = ContinuousClock.now - started
            loader.note("read \(scope.words): \(built.files.formatted()) files, \(built.analyzed.formatted()) analyzed, in \(took.formatted(.units(allowed: [.milliseconds])))")
        case .failure(let error):
            if said.insert("\(error)").inserted { loader.note("could not be read for \(scope.words) — \(error)") }
        }
    }

    /// A new scope: the old scope's report and hits go at once (a search still in flight for it is cancelled
    /// and can no longer publish), then the report is read for the new one. The hits are not re-asked.
    func set(scope: ObservationsScope) async {
        guard scope != self.scope else { return }
        self.scope = scope
        searchRun.reset()
        await load()
    }

    /// Search the observations in scope; an empty or too-short query ends any search and clears the hits.
    func search(_ query: String) async {
        revealProblem = nil
        guard ObservationsSearch.normalized(query) != nil else {
            searchRun.reset()
            return
        }
        let request = SearchRequest(scope: scope, query: query)
        let run = loader.search
        let ticket = searchRun.begin(request) { try await run(request.scope, request.query) }
        let result = await ticket.result
        guard searchRun.finish(ticket, result) else { return }
        switch result {
        case .success(let found):
            loader.note("searched \"\(query)\" in \(request.scope.words): \(found.hits.count.formatted()) hit\(found.hits.count == 1 ? "" : "s")\(found.truncated ? " (capped)" : "")")
        case .failure(let error):
            loader.note("the search for \"\(query)\" in \(request.scope.words) could not be read — \(error)")
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
        reportRun.reset()
        searchRun.reset()
    }
}
