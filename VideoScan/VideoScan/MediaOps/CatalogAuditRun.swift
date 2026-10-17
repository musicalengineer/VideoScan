// CatalogAuditRun.swift
// "When did the catalog's presence last get checked, and how did it go?"
// (Rick 2026-10-16, Catalog Status freshness §2/§6).
//
// The audit keeps NO per-record stamp. What it keeps is one small marker,
// `catalog-audit.json` beside catalog.json (FullHashBackfillResume's
// pattern), written when a run starts and rewritten at each acknowledged
// checkpoint and at the end: when it started, when it finished, the counts,
// the outcome word and whether it was partial. The File Presence row of
// the Catalog Status panel reads it for its date and colour.
//
// PER-ROW RESULTS (2026-10-17; SQLite plan v3 §10a D′, codex step-B F6):
// the marker also RECORDS what the run decided for every row it asked —
// `rows`, one `CatalogAuditRowResult` per row — so the importer and Fix
// Links can read the audit's answer instead of re-implementing the
// fd-bound walk. Recording only: the job appends a row AFTER the apply
// step has decided (the decision sources, CatalogAuditPlan.swift and
// VideoScanModel+CatalogAudit.swift, do not know this type exists), the
// rows ride in the SAME atomic publish as the counts, and the counts
// always EQUAL the per-row tallies (the strict reader refuses the rows
// part when they do not). Present rows are the bulk, so they carry only
// {id, result}; every other row carries the detail words the console line
// and the detail list already print, and the where-seen stamp when the
// first pass read one.
//
// THE CATALOG GENERATION (2026-10-17; importer N1, bug 2 of Rick's first
// dry run): at the finish the marker records `catalogGeneration`, the
// catalog's generation after the run's own last acknowledged save (or the
// one it started from, when it saved nothing). The importer requires it to
// equal the generation Verify Catalog checked. Additive: an older marker
// without the key reads with nil.
//
// Per catalog (the marker lives in the catalog's folder), so a test
// catalog in a scratch directory never sees the real one. A missing,
// damaged or newer-schema marker is read-only noise: `lastRun` is nil, no
// line is written, nothing starts and no record is touched. A marker
// whose ROWS part is poisoned (a result word from the future, a duplicate
// id, tallies that disagree with the counts, ids not in this catalog)
// still reads: the counts stand, the rows are refused with words.
//
// The only file this type writes is that marker, through AtomicFilePublish
// — never beside media. (MOPS-14.)
//
// Memory, worst case at 100k rows asked: the rows (~100 B each present,
// ~250 B with detail words) ≈ 10–25 MB, the id index ≈ 4 MB, and the
// encoded bytes (≈ 10 MB) for the moment of each publish. Rick's catalog
// (10.8k rows) is a tenth of that. Nothing grows with file size.

import Combine
import Foundation
import VideoScanCore

/// One row's answer, as the run recorded it. The result vocabulary is
/// `CatalogAuditResult` (the same words the counts are keyed by); the
/// detail is the apply step's own words. Present rows carry neither.
/// (For Rick: a plain-old-data struct; `Codable` ≈ the serializer is
/// generated from the fields, with `nil` fields left out of the JSON.)
struct CatalogAuditRowResult: Codable, Sendable, Equatable {
    let id: UUID
    let result: CatalogAuditResult
    /// The words the detail list and the console line print for this row;
    /// nil for a present row.
    let detail: String?
    /// Where the first pass found the file, when the apply stamped the row
    /// with it; nil for a present row (its stamp is on the catalog row,
    /// `VideoRecord.auditSeenOn`, which is the authoritative one) and for a
    /// row stamped only by the second look at the mark.
    let seenOn: AuditSeenOn?

    /// A result word this version of the app does not know — the strict
    /// reader turns it into a refusal of the rows part, with the word.
    struct UnknownResultWord: Error, Equatable {
        let word: String
    }

    init(id: UUID, result: CatalogAuditResult, detail: String? = nil, seenOn: AuditSeenOn? = nil) {
        self.id = id
        self.result = result
        self.detail = detail
        self.seenOn = seenOn
    }

    private enum CodingKeys: String, CodingKey { case id, result, detail, seenOn }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let word = try c.decode(String.self, forKey: .result)
        guard let result = CatalogAuditResult(rawValue: word) else { throw UnknownResultWord(word: word) }
        self.init(id: try c.decode(UUID.self, forKey: .id), result: result,
                  detail: try c.decodeIfPresent(String.self, forKey: .detail),
                  seenOn: try c.decodeIfPresent(AuditSeenOn.self, forKey: .seenOn))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(result.rawValue, forKey: .result)
        try c.encodeIfPresent(detail, forKey: .detail)
        try c.encodeIfPresent(seenOn, forKey: .seenOn)
    }
}

extension CatalogAuditRowResult {
    /// What the job records for one row from what the apply step said —
    /// after the decision, never part of it. `seenOn` is the first pass's
    /// stamp; it is kept only when the apply wrote it and the row is not
    /// simply present.
    init(id: UUID, apply: CatalogAuditApply, seenOn: AuditSeenOn?) {
        let present = apply.result == .present
        self.init(id: id, result: apply.result,
                  detail: present ? nil : apply.detail,
                  seenOn: !present && apply.stamped ? seenOn : nil)
    }
}

/// Why the rows part of a marker was refused (the counts still stand).
/// (For Rick: an enum with payloads ≈ a tagged union; `words` is its
/// to-string for the console and the Catalog Status panel.)
enum CatalogAuditRowsRefusal: Equatable, Sendable {
    /// The rows part is not an array of row results.
    case unreadable(String)
    /// A result word this version does not know (a marker from the future).
    case unknownResultWord(String)
    /// The same row answered twice.
    case duplicateID(UUID)
    /// The run's counts and the per-row tallies disagree for one result.
    case countsDisagree(result: String, counts: Int, rows: Int)
    /// Rows naming ids this catalog does not have (a marker from another catalog).
    case idsNotInCatalog(Int)

    var words: String {
        switch self {
        case .unreadable(let why):
            return "the per-row results could not be read (\(why)) — the counts stand; run the audit again for per-row results"
        case .unknownResultWord(let word):
            return "the per-row results use a result word this version does not know (\"\(word)\") — the counts stand; run the audit again"
        case .duplicateID(let id):
            return "the per-row results answer row \(id.uuidString) twice — the counts stand; run the audit again"
        case .countsDisagree(let result, let counts, let rows):
            return "the per-row results disagree with the counts (\(result): counts say \(counts.formatted()), rows say \(rows.formatted())) — the counts stand; run the audit again"
        case .idsNotInCatalog(let n):
            return "\(n.formatted()) per-row result(s) name rows this catalog does not have — the counts stand; run the audit again"
        }
    }
}

/// What the marker file holds.
struct CatalogAuditRunRecord: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable { case running, completed, stopped, failed, refused }

    var startedAt: Date
    var finishedAt: Date?
    var outcome: Outcome = .running
    /// True when the run did not ask every planned row (stopped or failed).
    var partial = false
    /// Result word → count, as `CatalogAuditResult.rawValue` (and the
    /// skipped total under "skipped").
    var counts: [String: Int] = [:]
    /// Rows the run changed and whose save was acknowledged.
    var marked = 0
    /// The catalog generation at the finish — after the run's own last
    /// acknowledged save. nil = still running, or an older marker.
    var catalogGeneration: Int?
    /// One answer per row the run ASKED, in the order answered. nil = an
    /// older marker without them, or a rows part the strict reader refused
    /// (`rowsRefusal` says why). Rows "not asked" (a drive not connected)
    /// and rows the plan skipped have no entry: they are counted in bulk.
    private(set) var rows: [CatalogAuditRowResult]?
    /// Why `rows` is nil although the marker carried a rows part. Never
    /// written to the file; set by the strict read only.
    private(set) var rowsRefusal: CatalogAuditRowsRefusal?
    /// id → position in `rows`, built once (as rows arrive, or at decode).
    private var index: [UUID: Int] = [:]

    init(startedAt: Date, finishedAt: Date? = nil, outcome: Outcome = .running, partial: Bool = false,
         counts: [String: Int] = [:], marked: Int = 0) {
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.outcome = outcome
        self.partial = partial
        self.counts = counts
        self.marked = marked
    }

    var isFinished: Bool { finishedAt != nil }

    /// True when `rows` answers for EVERY planned row that was asked: the
    /// run completed and was not partial. A stopped, failed, killed or
    /// partial run keeps its rows, but they are not a whole answer (the
    /// facts layer's partial rule) — an importer must not treat them as
    /// one.
    var hasCompleteRowResults: Bool { rows != nil && outcome == .completed && !partial }

    /// The run's answer for one row — O(1) after the index is built once.
    /// nil = not asked, not recorded, or the rows part was refused.
    func rowResult(for id: UUID) -> CatalogAuditRowResult? {
        guard let rows, let i = index[id] else { return nil }
        return rows[i]
    }

    /// Record one row's answer (the job, after the apply step decided).
    /// A second answer for the same id is dropped: the run asks each row
    /// once, and a duplicate would make the reader refuse the whole part.
    mutating func noteRow(_ row: CatalogAuditRowResult) {
        guard index[row.id] == nil else { return }
        if rows == nil { rows = [] }
        index[row.id] = rows?.count ?? 0
        rows?.append(row)
    }

    /// The poison a decode cannot see on its own: rows naming ids this
    /// catalog does not have (a marker copied from another catalog, or
    /// older than a purge). Returns the record with the rows part refused
    /// when any id is foreign; the counts stand either way.
    func checkedAgainstCatalog(ids catalogIDs: Set<UUID>) -> CatalogAuditRunRecord {
        guard let rows else { return self }
        let foreign = rows.reduce(0) { $0 + (catalogIDs.contains($1.id) ? 0 : 1) }
        guard foreign > 0 else { return self }
        var refused = self
        refused.rows = nil
        refused.index = [:]
        refused.rowsRefusal = .idsNotInCatalog(foreign)
        return refused
    }

    /// Result → how many rows carry it.
    static func tallies(_ rows: [CatalogAuditRowResult]) -> [CatalogAuditResult: Int] {
        var out: [CatalogAuditResult: Int] = [:]
        for row in rows { out[row.result, default: 0] += 1 }
        return out
    }

    /// The strict read's rules for a rows part: each id once; for every
    /// result but "not asked" (tallied in bulk, never per row) the count
    /// equals the tally. nil = the rows part is sound.
    static func refusal(rows: [CatalogAuditRowResult], counts: [String: Int]) -> CatalogAuditRowsRefusal? {
        var seen = Set<UUID>()
        for row in rows {
            if !seen.insert(row.id).inserted { return .duplicateID(row.id) }
        }
        let tallied = tallies(rows)
        for result in CatalogAuditResult.allCases where result != .notAsked {
            let fromCounts = counts[result.rawValue] ?? 0
            let fromRows = tallied[result] ?? 0
            if fromCounts != fromRows { return .countsDisagree(result: result.rawValue, counts: fromCounts, rows: fromRows) }
        }
        return nil
    }

    // MARK: Codable — the strict reader

    private enum CodingKeys: String, CodingKey { case startedAt, finishedAt, outcome, partial, counts, marked, catalogGeneration, rows }

    /// An older marker (no `rows` key) reads with rows = nil and no
    /// refusal. A rows part that cannot be read, uses an unknown word,
    /// answers a row twice or disagrees with the counts is refused with
    /// words — the counts and the outcome still read. The outcome word
    /// itself stays strict: a marker from a newer schema is nil as before.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(startedAt: try c.decode(Date.self, forKey: .startedAt),
                  finishedAt: try c.decodeIfPresent(Date.self, forKey: .finishedAt),
                  outcome: try c.decode(Outcome.self, forKey: .outcome),
                  partial: try c.decodeIfPresent(Bool.self, forKey: .partial) ?? false,
                  counts: try c.decodeIfPresent([String: Int].self, forKey: .counts) ?? [:],
                  marked: try c.decodeIfPresent(Int.self, forKey: .marked) ?? 0)
        catalogGeneration = try c.decodeIfPresent(Int.self, forKey: .catalogGeneration)
        let read = Self.readRows(c, counts: counts)
        rowsRefusal = read.refusal
        // Built once here; `refusal(rows:counts:)` already refused a
        // duplicate id, so the index is one entry per row.
        if let rows = read.rows {
            self.rows = rows
            for (i, row) in rows.enumerated() { index[row.id] = i }
        }
    }

    private static func readRows(_ c: KeyedDecodingContainer<CodingKeys>,
                                 counts: [String: Int]) -> (rows: [CatalogAuditRowResult]?, refusal: CatalogAuditRowsRefusal?) {
        do {
            guard let rows = try c.decodeIfPresent([CatalogAuditRowResult].self, forKey: .rows) else { return (nil, nil) }
            if let refusal = refusal(rows: rows, counts: counts) { return (nil, refusal) }
            return (rows, nil)
        } catch let unknown as CatalogAuditRowResult.UnknownResultWord {
            return (nil, .unknownResultWord(unknown.word))
        } catch {
            return (nil, .unreadable(error.localizedDescription))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encodeIfPresent(finishedAt, forKey: .finishedAt)
        try c.encode(outcome, forKey: .outcome)
        try c.encode(partial, forKey: .partial)
        try c.encode(counts, forKey: .counts)
        try c.encode(marked, forKey: .marked)
        try c.encodeIfPresent(catalogGeneration, forKey: .catalogGeneration)
        try c.encodeIfPresent(rows, forKey: .rows)
    }
}

@MainActor
final class CatalogAuditRunMarker: ObservableObject {

    static let fileName = "catalog-audit.json"

    /// The last run the marker knows (nil = never ran, or unreadable).
    @Published private(set) var lastRun: CatalogAuditRunRecord?
    private var current: CatalogAuditRunRecord?
    private(set) var fileURL: URL?

    init() {}

    /// Point at the catalog in use (its catalog.json path) and read what
    /// the last run left. Returns it, if readable.
    @discardableResult
    func attach(catalogFile: String) -> CatalogAuditRunRecord? {
        let url = URL(fileURLWithPath: catalogFile).deletingLastPathComponent()
            .appendingPathComponent(Self.fileName)
        fileURL = url
        lastRun = (try? Data(contentsOf: url)).flatMap { try? Self.decoder.decode(CatalogAuditRunRecord.self, from: $0) }
        return lastRun
    }

    func noteStarted(at date: Date = Date()) {
        current = CatalogAuditRunRecord(startedAt: date)
        persist()
    }

    /// One row's answer, recorded after the apply step decided it. Goes
    /// to disk with the next checkpoint, in the same publish as the counts.
    func noteRow(_ row: CatalogAuditRowResult) {
        current?.noteRow(row)
    }

    /// At each acknowledged checkpoint — so a crash still leaves "how far".
    func noteSaved(totals: CatalogAuditTotals, marked: Int) {
        guard current != nil else { return }
        current?.counts = Self.counts(totals)
        current?.marked = marked
        persist()
    }

    /// The run ended. `partial` = not every planned row was asked;
    /// `catalogGeneration` = the catalog's generation now, after the run's
    /// own last acknowledged save (nil only where no catalog is in play).
    func noteFinished(_ outcome: CatalogAuditRunRecord.Outcome, totals: CatalogAuditTotals, marked: Int,
                      partial: Bool, catalogGeneration: Int?, at date: Date = Date()) {
        guard current != nil else { return }
        current?.counts = Self.counts(totals)
        current?.marked = marked
        current?.catalogGeneration = catalogGeneration
        current?.outcome = outcome
        current?.partial = partial
        current?.finishedAt = date
        persist()
        lastRun = current
    }

    /// The marker's counts: every result with a count, plus "skipped".
    nonisolated static func counts(_ totals: CatalogAuditTotals) -> [String: Int] {
        var out: [String: Int] = [:]
        for (r, n) in totals.counts where n > 0 { out[r.rawValue] = n }
        if totals.skippedCount > 0 { out["skipped"] = totals.skippedCount }
        out["planned"] = totals.planned
        return out
    }

    /// At launch: read the marker beside this catalog and, when the last
    /// run has something to say (files gone, or a run that did not finish),
    /// write that one line through the audit's sink. Nothing starts; a
    /// missing or damaged marker says nothing.
    func announceLastRun(to model: VideoScanModel?) {
        guard let model, let last = attach(catalogFile: model.catalogStore.fileLocation),
              let line = Self.launchLine(last) else { return }
        model.catalogAuditNote(line)
    }

    /// The launch line for the last run (nil when none).
    nonisolated static func launchLine(_ r: CatalogAuditRunRecord) -> String? {
        let started = r.startedAt.formatted(date: .abbreviated, time: .shortened)
        switch r.outcome {
        case .completed:
            let gone = r.counts[CatalogAuditResult.gone.rawValue] ?? 0
            let archived = r.counts[CatalogAuditResult.goneArchived.rawValue] ?? 0
            let unseen = r.counts[CatalogAuditResult.neverSeenByAnAudit.rawValue] ?? 0
            guard gone + archived + unseen > 0 else { return nil }
            return "Audit catalog: the run of \(started) found \(gone.formatted()) file(s) gone (marked Missing)"
                + (archived > 0 ? " and \(archived.formatted()) archive copy(ies) not at their path" : "")
                + (unseen > 0 ? " and \(unseen.formatted()) file(s) not at their path that no audit had seen before (not marked — Fix Links decides)" : "")
                + " — the Catalog Status panel lists them."
        case .running:
            return "Audit catalog: the run started \(started) did not finish (quit or crash) — marks saved before that are kept; run Catalog ▸ Audit Catalog… again."
        case .stopped, .failed:
            return "Audit catalog: the run of \(started) \(r.outcome.rawValue) (partial) — run Catalog ▸ Audit Catalog… again."
        case .refused:
            return nil
        }
    }

    private func persist() {
        guard let fileURL, let current, let data = try? Self.encoder.encode(current) else { return }
        try? AtomicFilePublish.write(data, to: fileURL, durability: .fast)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
