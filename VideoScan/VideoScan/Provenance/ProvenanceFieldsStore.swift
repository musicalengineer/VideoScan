// ProvenanceFieldsStore.swift — the three provenance fields Rick types
// (digitization date, tape, source), DECISIONS 2026-11-27 "Provenance fields
// live in provenance_assertions; no schema change". The rule and the words
// are Core's ProvenanceFields (pure); this is the app's one engine for them.
//
// Shape: a feature store behind a seam (rule 12, #337) — the model holds ONE
// (`VideoScanModel.provenanceFields`, like `provenanceEstimates`); nothing
// here extends the model. One writer verb (rule 4):
//   save   Rick's typed values for ONE content: inside one transaction the
//          content's rows are read, what stands is folded (Core `current`),
//          and only the fields that differ are appended — confirmed /
//          corrected / rejected (a clear) — through Core's one assertions
//          door, via the committer's side-table door
//          (`commitSideTables(via: .provenanceFields)`). Then the rows are
//          read back in the same transaction. Any refusal of any row rolls
//          the whole save back: an archived content's digitization date
//          (rule 3 — the door's `isNameOrDate`; only Update… changes an
//          archived date), a content catalog.sqlite does not hold yet.
// Every field is optional; nothing typed = unknown, never guessed.
//
// Truth (rule 1): the Inspector reads `readCurrent` — the content's rows from
// catalog.sqlite, every time the selection or `revision` changes. `byDigest`
// is a projection for the Catalog search and the review list's first paint,
// loaded when catalog.sqlite becomes the authority and corrected from each
// save's own read-back.
//
// Search: each content's words ("digitized 2024-07", "tape …", "source …")
// reach the Catalog search index as a layer of its own beside the machine
// era's (CatalogSearchIndex.ObservationSource.provenance), per record path —
// joined on the main actor (one pass over `records`, a hash probe each, only
// when some content has a value), debounced after catalog edits.
//
// Logging: START / OUTCOME / REFUSED through the one sink. The typed VALUES
// are not logged (a tape label may name a person); the fields and the
// content's digest prefix are.
//
// Memory: one ProvenanceFieldValues (~150 B) per content with a value —
// 100k ≈ 15 MB worst case; the search layer ≈ 100 B per record path.
//
// (For Rick: a write-through cache in front of an append-only event table —
// std::unordered_map<digest, values> rebuilt from SQL; `save` is a blocking
// call into the one writer thread.)

import Combine
import Foundation
import VideoScanCore

/// The words (pure; tests read them).
enum ProvenanceFieldsWords {
    static let noDigest = "This file has no full SHA-256 yet, so its provenance cannot be kept — run Content Analysis ▸ Full Hashes first."
    static let inspectorNoDigest = "Digitized, tape, source: kept once this file has a full SHA-256 (Content Analysis ▸ Full Hashes)"
    static let archivedDate = "This file is archived: its digitization date is changed only through Update…. Nothing was saved."
    static let archivedDateHelp = "Archived means fixed: a digitization date on archived content is changed only through Update…."
    static let notStoredYet = "this file's row is still being saved to catalog.sqlite — try again in a moment"
    static let editButton = "Edit Provenance…"
    static let editHelp = "Enter the digitization date, the tape label and where it came from. Every field is optional."
    static let digitizedPlaceholder = "unknown — e.g. 2024, 2024-07 or 2024-07-04"
    static let tapePlaceholder = "unknown — the label on the tape"
    static let sourcePlaceholder = "unknown — where it came from"
    static let saveButton = "Save"
    static let skipButton = "Skip"
}

/// The catalog side of the store: reads through the repository, writes
/// through the session's committer (the one door). Mirrors
/// ProvenanceEstimateCatalogBacking.
@MainActor
final class ProvenanceFieldsCatalogBacking {

    typealias Commit = (_ what: String, _ body: (any CatalogTransaction) throws -> Void) -> String?

    let repository: any CatalogRepository
    private let commit: Commit
    let writeRefusal: () -> String?

    init(repository: any CatalogRepository, writeRefusal: @escaping () -> String?, commit: @escaping Commit) {
        self.repository = repository
        self.writeRefusal = writeRefusal
        self.commit = commit
    }

    convenience init(committer: CatalogCommitter) {
        self.init(repository: committer.repository, writeRefusal: { [weak committer] in
            guard let committer else { return "the catalog is closed" }
            return committer.sideTableWriteRefusal
        }, commit: { [weak committer] what, body in
            guard let committer else { return "the catalog is closed" }
            return committer.commitSideTables(what, via: .provenanceFields, body)
        })
    }

    func write(_ what: String, _ body: (any CatalogTransaction) throws -> Void) -> String? { commit(what, body) }
}

/// A row the door would not take: the whole save rolls back with these words.
private struct ProvenanceFieldNotLanded: Error, CustomStringConvertible {
    let description: String
}

@MainActor
final class ProvenanceFieldsStore: ObservableObject {

    enum SaveOutcome: Equatable {
        /// `changed` = fields whose value changed (rows appended).
        case saved(changed: Int)
        case unchanged
        case refused(String)
    }

    /// What the Inspector shows for one content, read from catalog.sqlite;
    /// every case names the content it was read for.
    enum Reading: Equatable {
        case values(digest: String, ProvenanceFieldValues)
        case unavailable(digest: String, why: String)

        var digest: String {
            switch self {
            case .values(let d, _), .unavailable(let d, _): return d
            }
        }
    }

    nonisolated static let debounce: Duration = .seconds(1)

    /// Bumped after every load and every save — the Inspector's re-read key.
    @Published private(set) var revision = 0
    private(set) var byDigest: [String: ProvenanceFieldValues] = [:]
    private(set) var backing: ProvenanceFieldsCatalogBacking?
    /// The one log sink.
    var note: (String) -> Void = { _ in }
    /// The search index hears every record path's words (its own layer).
    var onSearchTerms: (CatalogSearchIndex.ObservationLayer) -> Void = { _ in }
    private var records: () -> [VideoRecord] = { [] }
    private var mutations: AnyCancellable?
    private var pendingJoin: Task<Void, Never>?
    /// Bumped by every save and attach: a load snapshot begun before is stale.
    private var epoch = 0

    // MARK: Attach / load

    func attach(_ backing: ProvenanceFieldsCatalogBacking, records: @escaping () -> [VideoRecord]) {
        self.backing = backing
        self.records = records
        byDigest = [:]
        epoch &+= 1
        revision &+= 1
        // A path change (rescan, relocate) moves the search words with it.
        mutations = NotificationCenter.default.publisher(for: .videoScanCatalogMutated)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.scheduleSearchJoin() } }
    }

    /// Read every content's fields off the main actor and replace the map.
    /// nil = read; else the words (the map is left as it was).
    @discardableResult
    func load() async -> String? {
        guard let backing else { return "the catalog is not open" }
        let started = epoch
        do {
            let all = try await backing.repository.read { try ProvenanceFields.all(in: $0) }
            guard started == epoch else { return nil }      // a save landed meanwhile: its read-back is newer
            byDigest = all
            revision &+= 1
            publishSearch()
            return nil
        } catch {
            let words = String(describing: error)
            note("provenance fields could not be read from catalog.sqlite (\(words)) — every file shows unknown")
            return words
        }
    }

    // MARK: Reading

    /// What the review list paints first (the projection).
    func values(of digest: String) -> ProvenanceFieldValues {
        byDigest[digest.lowercased()] ?? ProvenanceFieldValues()
    }

    /// The Inspector's truth: the content's rows read from catalog.sqlite now.
    func readCurrent(digest: String) async -> Reading {
        let key = digest.lowercased()
        guard let backing else { return .unavailable(digest: key, why: "the catalog is not open") }
        do {
            let rows = try await backing.repository.read {
                try $0.provenanceAssertions(subjectKind: ProvenanceAssertionSubject.content, subjectID: key)
            }
            return .values(digest: key, ProvenanceFields.current(fromRowsOfOneSubject: rows))
        } catch {
            return .unavailable(digest: key, why: String(describing: error))
        }
    }

    /// Why a save would be refused now; nil = it would be written.
    var writeRefusal: String? {
        guard let backing else { return "the catalog is not open for writing in this session" }
        return backing.writeRefusal()
    }

    // MARK: The one writer

    /// Leave `typed` standing for the content `digest`. `place` says where
    /// it was entered ("review list", "manual add", "inspector") — kept in
    /// each row's evidence.
    func save(digest: String, typed: ProvenanceFieldValues, enteredIn place: String, now: Date = Date()) -> SaveOutcome {
        guard let key = ProvenanceAssertionSubject.contentID(digest) else { return .refused(ProvenanceFieldsWords.noDigest) }
        let scope = "content \(key.prefix(12))…"
        note("START save provenance fields for \(scope) (\(place))")
        guard let backing else { return refuse("the catalog is not open for writing in this session", scope) }
        if let why = backing.writeRefusal() { return refuse(why, scope) }
        let seconds = Int64(now.timeIntervalSince1970.rounded(.down))
        var changed: [String] = []
        var after = ProvenanceFieldValues()
        let refusal = backing.write("save provenance fields for \(scope)") { tx in
            changed = []
            let rows = try tx.provenanceAssertions(subjectKind: ProvenanceAssertionSubject.content, subjectID: key)
            let before = ProvenanceFields.current(fromRowsOfOneSubject: rows)
            for draft in ProvenanceFields.drafts(digest: key, before: before, after: typed, at: seconds, enteredIn: place) {
                switch try tx.appendProvenanceAssertion(draft) {
                case .recorded, .duplicate:
                    changed.append("\(ProvenanceField(rawValue: draft.field)?.label ?? draft.field) \(Self.verb(draft.state))")
                case .archivedNameOrDate: throw ProvenanceFieldNotLanded(description: ProvenanceFieldsWords.archivedDate)
                case .contentMissing: throw ProvenanceFieldNotLanded(description: ProvenanceFieldsWords.notStoredYet)
                case .vetoed: throw ProvenanceFieldNotLanded(description: "the catalog ignored the \(draft.field) row")
                case .storeRefused(let words): throw ProvenanceFieldNotLanded(description: "the catalog refused the \(draft.field) row (\(words))")
                }
            }
            after = ProvenanceFields.current(fromRowsOfOneSubject:
                try tx.provenanceAssertions(subjectKind: ProvenanceAssertionSubject.content, subjectID: key))
        }
        if let refusal { return refuse(refusal, scope) }
        epoch &+= 1
        if after.isEmpty { byDigest.removeValue(forKey: key) } else { byDigest[key] = after }
        revision &+= 1
        guard !changed.isEmpty else {
            note("OUTCOME save provenance fields for \(scope) — nothing changed")
            return .unchanged
        }
        publishSearch()
        note("OUTCOME save provenance fields for \(scope) — \(changed.joined(separator: ", ")). History is kept.")
        return .saved(changed: changed.count)
    }

    private static func verb(_ state: String) -> String {
        switch state {
        case "confirmed": return "set"
        case "corrected": return "changed"
        default: return "cleared"
        }
    }

    private func refuse(_ why: String, _ scope: String) -> SaveOutcome {
        note("REFUSED save provenance fields for \(scope) — \(why). Nothing was written.")
        return .refused(why)
    }

    // MARK: Search

    func scheduleSearchJoin(after delay: Duration = ProvenanceFieldsStore.debounce) {
        pendingJoin?.cancel()
        pendingJoin = Task { [weak self] in
            try? await Task.sleep(for: delay)
            if Task.isCancelled { return }
            self?.publishSearch()
        }
    }

    /// One pass over the records (only when some content has a value).
    func publishSearch() {
        onSearchTerms(CatalogSearchIndex.ObservationLayer(Self.join(records: records(), values: byDigest)))
    }

    /// Each record path's words, by its content's values (pure; the scale test times it).
    static func join(records: [VideoRecord], values: [String: ProvenanceFieldValues]) -> [String: CatalogSearchIndex.ObservationTerms] {
        guard !values.isEmpty else { return [:] }
        var terms: [String: CatalogSearchIndex.ObservationTerms] = [:]
        var made: [String: CatalogSearchIndex.ObservationTerms] = [:]
        for rec in records {
            // Cheap probe first (the fixities' own digests); the identity rule only on a hit.
            let hit = (rec.contentFixity.map { values[$0.digest.lowercased()] != nil } ?? false)
                || (rec.archiveFixity.map { values[$0.digest.lowercased()] != nil } ?? false)
            guard hit, let digest = CatalogCommit.digest(of: rec), let v = values[digest] else { continue }
            if let t = made[digest] {
                terms[rec.fullPath] = t
            } else {
                let t = CatalogSearchIndex.ObservationTerms(words: ProvenanceFields.searchWords(v), years: nil)
                made[digest] = t
                terms[rec.fullPath] = t
            }
        }
        return terms
    }
}
