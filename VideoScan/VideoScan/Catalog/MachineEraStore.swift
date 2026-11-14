// MachineEraStore.swift — the model-owned cache of the era job's
// observations (background service step 1, item 8).
//
// One sentence: after launch, after every JournalApplier pass that committed
// a row, and (debounced) after a catalog edit, read every content's fused
// machine era from catalog.sqlite in ONE streamed query (Core's
// MachineEraResolver), then hand three readers what they need:
//   * the inspector — `shown(for:)`, an O(1) lookup by the record's digest:
//     "Machine era: 1991–1995 · 8B, unconfirmed" with the windows, frames and
//     `by` in its help (InspectorMachineEraLine);
//   * Catalog Status — the convergence count "Machine era agrees with your
//     confirmed date within 5 y: N of M (p %)", absent at M = 0;
//   * the Catalog search index — the era's decade words and years per
//     record path ("1990s", "90s", "early 90s"; DECISIONS 2026-11-01 "human
//     words"), never the range, the field, the signer or the digest.
//
// Shape: a feature store behind a seam (rule 12, #337) — the model holds ONE
// (`VideoScanModel.machineEras`, like `journalApplier`); nothing here extends
// the model. It READS only (the repository's `read`); it never writes.
//
// By ruling (DECISIONS 2026-11-01) a machine era is never shown as a date and
// never filters: it is its own line, "unconfirmed", and words in search.
//
// Threading: the read runs on the repository's reader (off the main actor);
// the per-content search words, the convergence count and the index's word
// layer are built detached; only the join with the records — one pass over
// `records`, a hash probe each, the identity rule only on a hit, and only
// when there are eras — and the publish run on the main actor, coalesced by
// a 1 s debounce and never inside a view body (measured: 100k records with
// 50k eras ≈ 0.22 s in Debug; the scale test's budget is 0.4 s). The DV camcorder-clock clause ("re-recorded film: content older
// than the carrier", DECISIONS 2026-11-01) waits: nothing in the catalog
// holds the DV recording datecode yet (dv_datecode.py tabulates it outside).
//
// Memory: `eras` ≈ 300 B per content with an era (frame times capped at 24)
// → 100k ≈ 30 MB worst case, the corpus (~15k video contents) ≈ 5 MB; the
// search terms ≈ 100 B per record path with an era.
//
// (For Rick: a read-through cache with an invalidation callback — like a
// C++ observer that re-queries the DB when the writer signals a commit.)

import Combine
import Foundation
import VideoScanCore

@MainActor
final class MachineEraStore: ObservableObject {

    typealias Load = @Sendable () async throws -> [String: [MachineEra]]

    /// What the inspector line shows (pure; tests read it).
    struct Shown: Equatable {
        var text: String
        var help: String
    }

    nonisolated static let debounce: Duration = .seconds(1)

    /// digest (content.digest's spelling) → that content's eras, newest first.
    @Published private(set) var eras: [String: [MachineEra]] = [:]
    /// nil until a refresh found M > 0 (the Status line is absent then).
    @Published private(set) var convergence: MachineEraConvergence?
    /// Completed refreshes (tests and the log).
    private(set) var refreshCount = 0
    /// The one log sink.
    var note: (String) -> Void = { _ in }
    /// Catalog Status hears every new count (nil = no line).
    var onConvergence: (MachineEraConvergence?) -> Void = { _ in }
    /// The search index hears every record path's era words (the layer is
    /// built off the main actor; the index swaps it in).
    var onSearchTerms: (CatalogSearchIndex.ObservationLayer) -> Void = { _ in }

    private var load: Load?
    private var records: () -> [VideoRecord] = { [] }
    private var pending: Task<Void, Never>?
    private var mutations: AnyCancellable?
    private var saidFailure: String?
    /// The newest refresh issued; an older one that finishes later is dropped.
    private var issued = 0

    init() {}

    /// Read from this session's catalog.sqlite; first refresh now (debounced).
    func attach(repository: any CatalogRepository, records: @escaping () -> [VideoRecord]) {
        attach(load: { try await repository.read { try MachineEraResolver.eras(in: $0) } }, records: records)
    }

    /// The seam (tests inject a load).
    func attach(load: @escaping Load, records: @escaping () -> [VideoRecord]) {
        detach()
        self.load = load
        self.records = records
        // Rick's date edits change the convergence count and the "disagrees"
        // wording — re-read, debounced, after any catalog edit.
        mutations = NotificationCenter.default.publisher(for: .videoScanCatalogMutated)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.scheduleRefresh() } }
        scheduleRefresh()
    }

    func detach() {
        pending?.cancel()
        pending = nil
        mutations = nil
        load = nil
        records = { [] }
    }

    /// Coalesce: one refresh `after` the last request.
    func scheduleRefresh(after delay: Duration = MachineEraStore.debounce) {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            if Task.isCancelled { return }
            await self?.refresh()
        }
    }

    /// The scheduled refresh, for tests to await.
    var pendingRefresh: Task<Void, Never>? { pending }

    /// One query, one join, one publish. false = the read failed (the old cache stays).
    @discardableResult
    func refresh() async -> Bool {
        guard let load else { return false }
        issued += 1
        let mine = issued
        let loaded: [String: [MachineEra]]
        do {
            loaded = try await load()
            guard mine == issued else { return false }      // a newer refresh owns the publish
        } catch {
            let why = "\(error)"
            if saidFailure != why {
                saidFailure = why
                note("machine eras could not be read from catalog.sqlite (\(why)) — the inspector and Catalog Status show none new")
            }
            return false
        }
        saidFailure = nil
        // The words per content are built off the main actor; the main actor
        // only probes and maps paths.
        let words = await Task.detached(priority: .utility) { Self.termsByDigest(loaded) }.value
        guard mine == issued else { return false }
        let joined = Self.join(records: records(), eras: loaded, terms: words)
        let years = joined.rickYears
        let byPath = joined.terms
        let (counted, layer) = await Task.detached(priority: .utility) {
            (MachineEraResolver.convergence(eras: loaded, rickYears: years), CatalogSearchIndex.ObservationLayer(byPath))
        }.value
        guard mine == issued else { return false }
        let first = refreshCount == 0
        refreshCount += 1
        eras = loaded
        if counted != convergence || first {
            convergence = counted
            onConvergence(counted)
        }
        onSearchTerms(layer)
        return true
    }

    /// One pass over the records (main actor; only when there are eras):
    /// Rick's confirmed year per digest that has an era, and each record
    /// path's search terms. O(records) dictionary probes — the 100k scale
    /// test times it.
    static func join(records: [VideoRecord], eras: [String: [MachineEra]], terms byDigest: [String: CatalogSearchIndex.ObservationTerms])
        -> (rickYears: [String: Int], terms: [String: CatalogSearchIndex.ObservationTerms]) {
        guard !eras.isEmpty else { return ([:], [:]) }
        var years: [String: Int] = [:]
        var terms: [String: CatalogSearchIndex.ObservationTerms] = [:]
        for rec in records {
            // Cheap probe first (the fixities' own digests, one hash lookup);
            // only a hit pays for the identity rule (CatalogCommit.digest).
            guard mayHaveEra(rec, eras), let digest = CatalogCommit.digest(of: rec), eras[digest] != nil else { continue }
            if rec.userDate != nil, pfRecordHasConfirmedDate(rec), let year = MachineEraResolver.rickYear(rec.userDate) { years[digest] = year }
            if let words = byDigest[digest] { terms[rec.fullPath] = words }
        }
        return (years, terms)
    }

    /// Each content's search terms from its newest era (pure; runs detached).
    nonisolated static func termsByDigest(_ eras: [String: [MachineEra]]) -> [String: CatalogSearchIndex.ObservationTerms] {
        eras.compactMapValues { list in
            list.first.map { CatalogSearchIndex.ObservationTerms(words: MachineEraResolver.searchWords(era: $0),
                                                                 years: MachineEraResolver.searchYears(era: $0)) }
        }
    }

    /// Exact prefilter for `CatalogCommit.digest(of:)`: that digest is
    /// always one of the two fixities' digests (lowercased), so a record
    /// whose fixity digests are both absent from `eras` cannot have an era.
    /// ContentFixity lowercases at init; an archive digest is lowercased here
    /// only when it holds an uppercase hex letter.
    static func mayHaveEra(_ rec: VideoRecord, _ eras: [String: [MachineEra]]) -> Bool {
        if let d = rec.contentFixity?.digest, eras[d] != nil { return true }
        guard let a = rec.archiveFixity?.digest else { return false }
        if eras[a] != nil { return true }
        return a.utf8.contains { (65...70).contains($0) } && eras[a.lowercased()] != nil
    }

    // MARK: The inspector's line

    /// The line for `record` — O(1); nil when the content has no fused era.
    func shown(for record: VideoRecord) -> Shown? {
        guard let digest = CatalogCommit.digest(of: record), let list = eras[digest] else { return nil }
        return Self.shown(list, userDate: pfRecordHasConfirmedDate(record) ? record.userDate : nil)
    }

    /// The File Journey's event for `record` — O(1); nil when the content
    /// has no fused era (the journey then says nothing about an era).
    func journey(for record: VideoRecord) -> JourneyMachineEra? {
        guard let digest = CatalogCommit.digest(of: record), let era = eras[digest]?.first else { return nil }
        let year = pfRecordHasConfirmedDate(record) ? MachineEraResolver.rickYear(record.userDate) : nil
        return JourneyMachineEra(sentence: MachineEraResolver.journeySentence(era: era, rickYear: year),
                                 observed: Date(timeIntervalSince1970: TimeInterval(era.at)))
    }

    /// Pure: the newest era's line; Rick's year (when he has one) decides
    /// "disagrees with your date"; the help names windows, frames, the `by`.
    static func shown(_ eras: [MachineEra], userDate: String?) -> Shown? {
        guard let era = eras.first else { return nil }
        return Shown(text: MachineEraResolver.inspectorLine(era: era, rickYear: MachineEraResolver.rickYear(userDate)),
                     help: MachineEraResolver.inspectorHelp(era: era, others: Array(eras.dropFirst())))
    }
}
