// HeldBackStore.swift — GH #339: the feature store behind "Held back at
// import" (rule 12: state behind a seam; the model holds ONE, `heldBack`,
// like `provenanceRoles` — nothing here extends the model).
//
// One sentence (Rick's): "show me what the import held back and where those
// files are now; when a moved copy is proven, let me carry my tag, date and
// place onto it."
//
// Owns: the open count (Catalog Status), the classified list (the sheet), the
// offers Find Moved Copies proved, and the ONE writer — `carry`.
//
// THE CARRY (data-risk: it writes Rick's curated values):
//   1. refuse before mutating: no catalog, a read-only / viewer session, a
//      job's write hold, a blocked or reopening store → nothing changes;
//   2. per selected offer, re-checked NOW: the live record is still live and
//      at the proven path, the file's stamp is still the one the proof read
//      (else "changed since it was checked"), it has its files row (a full
//      SHA-256); the fields are judged again against the record as it is now
//      — an edit Rick made a second ago (inside the 2 s debounce) is seen and
//      never overwritten; a date never goes onto an archived record;
//   3. the records' new values are committed through the commit door under
//      the `import carry` writer (`CatalogCommitter.commitCarried`) — only if
//      that commit stored every row …
//   4. … the held-back rows are closed in ONE side-table transaction
//      (`resolveHeldBack`: `personDecided`, the file, a note naming the
//      proof and the values). If (4) is refused after (3) stored, the values
//      are on the live files and the rows stay open; the next look offers
//      them as "already on the live file" and closing them is one click.
// Outcomes (each tested): carried(n, closed) · refused(words) — nothing
// written · notSaved(words) — values in memory, rows open, the store's words.
//
// Logging: START / one line per pair / OUTCOME through `note` (the model's
// console + catalog.log + videoscan.log), with rows before · after · where
// the difference went (CLAUDE.md §10.1).
//
// Memory: entries ≈ 1 KB each (2,110 today ≈ 2 MB; bounded by the table,
// which only grows by a rescan's rows); offers ≈ 1 KB each; the live index
// is built per load / plan and dropped (≈ 20 MB at 100k records, transient).
//
// (For Rick: a controller object owning a cached query result and one
// transactional mutator; the closures are its injected dependencies — a
// C++ class taking std::function members in its constructor.)

import Combine
import Foundation
import VideoScanCore

/// The catalog side: reads through the repository, writes through the
/// session's committer (the one door). Mirrors ProvenanceRoleCatalogBacking.
@MainActor
final class HeldBackCatalogBacking {
    let repository: any CatalogRepository
    let writeRefusal: () -> String?
    /// Commit these records now (import carry). nil = all stored.
    let commitRecords: (Set<UUID>) -> String?
    /// One side-table transaction. nil = committed.
    let commitSide: (_ what: String, _ body: (any CatalogTransaction) throws -> Void) -> String?

    init(repository: any CatalogRepository, writeRefusal: @escaping () -> String?,
         commitRecords: @escaping (Set<UUID>) -> String?,
         commitSide: @escaping (_ what: String, _ body: (any CatalogTransaction) throws -> Void) -> String?) {
        self.repository = repository
        self.writeRefusal = writeRefusal
        self.commitRecords = commitRecords
        self.commitSide = commitSide
    }

    convenience init(committer: CatalogCommitter) {
        // Each answer is `String?` with nil = yes; `committer?.x ?? "closed"`
        // would read a writable session's nil as "closed" — hence the guards.
        self.init(repository: committer.repository,
                  writeRefusal: { [weak committer] in
                      guard let committer else { return "the catalog is closed" }
                      return committer.sideTableWriteRefusal
                  },
                  commitRecords: { [weak committer] ids in
                      guard let committer else { return "the catalog is closed" }
                      return committer.commitCarried(ids: ids)
                  },
                  commitSide: { [weak committer] what, body in
                      guard let committer else { return "the catalog is closed" }
                      return committer.commitSideTables(what, via: .heldBack, body)
                  })
    }
}

@MainActor
final class HeldBackStore: ObservableObject {

    enum ListState: Equatable {
        case idle
        case loading
        case loaded(at: Date)
        case failed(String)
    }

    enum CarryOutcome: Equatable {
        /// `carried` pairs written; `closed` held-back rows resolved;
        /// `skipped` pairs left (each named in the log and `lastCarryLines`).
        case carried(carried: Int, closed: Int, skipped: Int)
        case refused(String)
        case notSaved(String)
    }

    /// Open rows (Catalog Status). nil until read; read at attach and after a carry.
    @Published private(set) var openCount: Int?
    @Published private(set) var entries: [HeldBackEntry] = [] {
        didSet { sections = HeldBackClassifier.grouped(entries).map { HeldBackSection(group: $0.group, entries: $0.entries) } }
    }
    /// The list's groups, computed once per change (never in a view body).
    @Published private(set) var sections: [HeldBackSection] = []
    @Published private(set) var listState: ListState = .idle
    /// Proven pairs from the last Find Moved Copies run.
    @Published private(set) var offers: [HeldBackOffer] = []
    /// The last carry's per-pair lines (the sheet shows them under the button).
    @Published private(set) var lastCarryLines: [String] = []

    private(set) var backing: HeldBackCatalogBacking?
    /// The session's records (the model's `records`).
    var records: () -> [VideoRecord] = { [] }
    var recordForID: (UUID) -> VideoRecord? = { _ in nil }
    var isDateReadOnly: (VideoRecord) -> Bool = { _ in true }
    /// After values changed on records: search index, ledger lines (the
    /// model's `noteCatalogMutated` + `noteUserDateEdited` / `…PlaceEdited`).
    var didCarry: (_ record: VideoRecord, _ date: Bool, _ place: Bool) -> Void = { _, _, _ in }
    /// The one log sink.
    var note: (String) -> Void = { _ in }
    var disk: HeldBackDisk = .live

    // MARK: Attach / read

    func attach(_ backing: HeldBackCatalogBacking) {
        self.backing = backing
        entries = []
        offers = []
        listState = .idle
        openCount = nil
    }

    /// One indexed count off the main actor. nil = read; else the words.
    @discardableResult
    func refreshCount() async -> String? {
        guard let backing else { return "the catalog is not open" }
        do {
            openCount = try await backing.repository.read { try $0.heldBackOpenCount() }
            return nil
        } catch {
            let words = String(describing: error)
            note("held-back rows could not be counted (\(words)) — Catalog Status shows none")
            return words
        }
    }

    /// Read every row, project the live records (main actor, one pass), then
    /// stat and classify OFF the main actor (a sleeping drive never blocks the UI).
    func loadList() async {
        guard let backing else { listState = .failed("the catalog is not open in this session"); return }
        listState = .loading
        do {
            let rows = try await backing.repository.read { reader -> [CatalogRow.HeldBackRow] in
                var out: [CatalogRow.HeldBackRow] = []
                try reader.heldBackRows { out.append($0) }
                return out
            }
            let live = HeldBackLiveIndex.project(records(), dateReadOnly: isDateReadOnly)
            let disk = self.disk
            let classified = await Task.detached(priority: .userInitiated) {
                HeldBackClassifier.classify(rows, live: live, disk: disk)
            }.value
            entries = classified
            openCount = classified.filter { !$0.isResolved }.count
            listState = .loaded(at: Date())
            let counts = HeldBackClassifier.grouped(classified).map { "\($0.group.rawValue) \($0.entries.count)" }.joined(separator: " · ")
            note("held back at import: \(classified.count) row(s) read — \(counts)")
        } catch {
            let words = String(describing: error)
            listState = .failed(words)
            note("held back at import: the rows could not be read (\(words))")
        }
    }

    /// Find Moved Copies' plan from the loaded list and the live records now.
    func jobPlan() -> HeldBackJobPlan {
        HeldBackJobPlan.make(entries: entries, live: HeldBackLiveIndex.project(records(), dateReadOnly: isDateReadOnly))
    }

    /// The job hands its proven pairs over (replacing the last run's).
    func setOffers(_ offers: [HeldBackOffer]) {
        self.offers = offers
    }

    // MARK: The one writer

    /// Why a carry would be refused now; nil = it would be attempted.
    var writeRefusal: String? {
        guard let backing else { return "the catalog is not open for writing in this session" }
        return backing.writeRefusal()
    }

    /// Rick confirmed these offers (by id). Nothing is written without this
    /// call; nothing Rick already set is overwritten. See the header.
    @discardableResult
    func carry(_ ids: Set<String>, now: Date = Date()) -> CarryOutcome {
        let chosen = offers.filter { ids.contains($0.id) }.sorted { ($0.qid, $0.recordID.uuidString) < ($1.qid, $1.recordID.uuidString) }
        note("START carry from held-back rows — \(chosen.count) confirmed pair(s)")
        guard !chosen.isEmpty else { return refuse("nothing was selected") }
        guard let backing else { return refuse("the catalog is not open for writing in this session") }
        if let why = backing.writeRefusal() { return refuse(why) }

        let plan = planCarry(chosen)
        var lines = plan.skipped
        if let why = applyAndCommit(plan.writes, backing: backing) {
            for line in lines { note("  " + line) }
            lastCarryLines = lines + ["NOT SAVED — \(why)"]
            note("OUTCOME carry NOT SAVED — \(why). The values are on the records in memory and are saved with the next commit "
                 + "that can run; no held-back row was closed (\(openCount.map(String.init) ?? "?") open before · the same after).")
            return .notSaved(why)
        }
        let before = openCount
        let resolutions = Self.resolutions(plan.writes, at: Int64(now.timeIntervalSince1970.rounded(.down)))
        lines += plan.writes.map { "CARRIED \($0.offer.oldName) → \($0.offer.liveName) [\($0.offer.evidence.rawValue)]: " + Self.fieldsLine($0.fields) }
        let closed = close(resolutions, backing: backing)
        lines += closed.lines
        for line in lines { note("  " + line) }
        lastCarryLines = lines
        let carriedIDs = Set(plan.writes.map(\.offer.id))
        offers.removeAll { closed.qids.contains($0.qid) || carriedIDs.contains($0.id) }
        markResolved(closed.qids, resolutions)
        let skipped = chosen.count - plan.writes.count
        note("OUTCOME carry — \(plan.writes.count) pair(s) carried, \(closed.qids.count) held-back row(s) closed, \(skipped) skipped · "
             + "open rows \(before.map(String.init) ?? "?") before · \(openCount.map(String.init) ?? "?") after "
             + "(the difference: closed as personDecided; nothing deleted)")
        return .carried(carried: plan.writes.count, closed: closed.qids.count, skipped: skipped)
    }

    // MARK: Carry helpers

    /// One confirmed pair that passed its re-check: the live record and the
    /// fields as judged against it NOW.
    struct CarryWrite {
        let offer: HeldBackOffer
        let record: VideoRecord
        let fields: HeldBackFields
    }

    /// The pairs that pass their re-check, and one SKIPPED line per pair that does not.
    private func planCarry(_ chosen: [HeldBackOffer]) -> (writes: [CarryWrite], skipped: [String]) {
        var writes: [CarryWrite] = []
        var skipped: [String] = []
        for offer in chosen {
            switch recheck(offer) {
            case .failure(let why): skipped.append("SKIPPED \(offer.oldName) → \(offer.liveName): \(why)")
            case .success(let (record, fields)): writes.append(CarryWrite(offer: offer, record: record, fields: fields))
            }
        }
        return (writes, skipped)
    }

    /// Set the `.carry` fields on the records, then commit exactly those
    /// records through the door. nil = stored (or nothing to store).
    private func applyAndCommit(_ writes: [CarryWrite], backing: HeldBackCatalogBacking) -> String? {
        var changed: Set<UUID> = []
        var wrote: [(VideoRecord, Bool, Bool)] = []
        for w in writes where w.fields.carriesAny {
            let set = apply(w.fields, oldDateConfidence: w.offer.old.userDateConfidence,
                            oldPlaceConfidence: w.offer.old.userPlaceConfidence, to: w.record)
            changed.insert(w.record.id)
            wrote.append((w.record, set.date, set.place))
        }
        let words = changed.isEmpty ? nil : backing.commitRecords(changed)
        // The records in memory now hold the values either way (what Rick sees).
        for (record, date, place) in wrote { didCarry(record, date, place) }
        return words
    }

    /// One resolution per held-back row. Two pairs for one row: both got the
    /// values; the row is closed once (the first file in id order) and its
    /// note counts the rest. Pure.
    static func resolutions(_ writes: [CarryWrite], at seconds: Int64) -> [CatalogRow.HeldBackResolution] {
        var firstByRow: [Int64: (fileID: String, note: String, more: Int)] = [:]
        for w in writes {
            if firstByRow[w.offer.qid] != nil { firstByRow[w.offer.qid]?.more += 1; continue }
            firstByRow[w.offer.qid] = (w.record.id.uuidString, resolutionNote(w.offer, w.fields), 0)
        }
        return firstByRow.keys.sorted().compactMap { qid in
            guard let r = firstByRow[qid] else { return nil }
            let note = r.more == 0 ? r.note : r.note + "; also carried onto \(r.more) more proven cop\(r.more == 1 ? "y" : "ies")"
            return CatalogRow.HeldBackResolution(qid: qid, fileID: r.fileID, note: note, resolvedAt: seconds)
        }
    }

    /// Close the rows in ONE side-table transaction. Returns the rows closed
    /// and a line for each that was not (or for the whole refusal).
    private func close(_ resolutions: [CatalogRow.HeldBackResolution],
                       backing: HeldBackCatalogBacking) -> (qids: Set<Int64>, lines: [String]) {
        guard !resolutions.isEmpty else { return ([], []) }
        let box = HeldBackLandingBox()
        if let refusal = backing.commitSide("closed \(resolutions.count) held-back row(s) after a confirmed carry", { tx in
            box.landings = []
            for r in resolutions { box.landings.append((r.qid, try tx.resolveHeldBack(r))) }
        }) {
            return ([], ["the held-back rows were NOT closed — \(refusal); the values are saved on the live files, "
                         + "and the rows will show them as already carried"])
        }
        let landings = box.landings
        return (Set(landings.filter { $0.1 == .resolved }.map(\.0)),
                landings.filter { $0.1 != .resolved }.map { "row \($0.0) was not closed — \($0.1)" })
    }

    private enum Recheck { case success((VideoRecord, HeldBackFields)), failure(String) }

    /// The offer judged against the catalog and the disk as they are NOW.
    private func recheck(_ offer: HeldBackOffer) -> Recheck {
        guard let record = recordForID(offer.recordID), record.removal == nil else {
            return .failure("the live file is no longer in the catalog")
        }
        guard record.fullPath == offer.livePath else { return .failure("the live file moved since it was checked — run Find Moved Copies again") }
        guard FileIdentityStamp.capture(path: record.fullPath) == offer.stamp else {
            return .failure("the live file changed (or its drive was reconnected) since it was checked — run Find Moved Copies again")
        }
        let live = HeldBackLive(record, dateReadOnly: isDateReadOnly(record))
        guard live.digest != nil else { return .failure(HeldBackWords.needsFullHash) }
        let fields = HeldBackFields.evaluate(old: offer.old, live: live)
        guard fields.carriesAny || fields.allAlready else { return .failure(HeldBackWords.onlyConflicts) }
        return .success((record, fields))
    }

    /// Write the `.carry` fields onto `record`. Returns which of date / place changed.
    private func apply(_ fields: HeldBackFields, oldDateConfidence: String?, oldPlaceConfidence: String?,
                       to record: VideoRecord) -> (date: Bool, place: Bool) {
        if case .carry(let raw)? = fields.tag, let tag = MediaDisposition(rawValue: raw) { record.mediaDisposition = tag }
        var date = false, place = false
        if case .carry(let value)? = fields.date, !isDateReadOnly(record) {
            record.userDate = value
            record.userDateConfidence = Self.confidence(oldDateConfidence, known: UserDateConfidence.known.rawValue,
                                                        estimated: UserDateConfidence.estimated.rawValue)
            date = true
        }
        if case .carry(let value)? = fields.place {
            record.userPlace = value
            record.userPlaceConfidence = Self.confidence(oldPlaceConfidence, known: UserPlaceConfidence.known.rawValue,
                                                         estimated: UserPlaceConfidence.estimated.rawValue)
            place = true
        }
        return (date, place)
    }

    /// The old row's confidence when it is one this app writes; else estimated.
    private static func confidence(_ old: String?, known: String, estimated: String) -> String {
        old == known ? known : estimated
    }

    static func fieldsLine(_ f: HeldBackFields) -> String {
        [HeldBackWords.field("tag", f.tag), HeldBackWords.field("date", f.date), HeldBackWords.field("place", f.place)]
            .compactMap { $0 }.joined(separator: "; ")
    }

    /// What `resolution_note` says: the origin, the proof, the values.
    static func resolutionNote(_ offer: HeldBackOffer, _ f: HeldBackFields) -> String {
        "carried from the October import row (qid \(offer.qid)) onto a moved copy proven by \(offer.evidence.rawValue); "
            + "Rick confirmed. " + fieldsLine(f)
    }

    private func markResolved(_ qids: Set<Int64>, _ resolutions: [CatalogRow.HeldBackResolution]) {
        guard !qids.isEmpty else { return }
        let notes = Dictionary(uniqueKeysWithValues: resolutions.map { ($0.qid, $0.note) })
        for i in entries.indices where qids.contains(entries[i].qid) {
            entries[i].whereNow = .resolved(note: notes[entries[i].qid] ?? "resolved")
        }
        if let open = openCount { openCount = max(0, open - qids.count) }
    }

    private func refuse(_ why: String) -> CarryOutcome {
        note("REFUSED carry from held-back rows — \(why). Nothing was written.")
        lastCarryLines = ["Not carried — \(why). Nothing was written."]
        return .refused(why)
    }
}

struct HeldBackSection: Identifiable, Equatable {
    let group: HeldBackGroup
    let entries: [HeldBackEntry]
    var id: String { group.rawValue }
}

extension HeldBackEntry {
    var isResolved: Bool { if case .resolved = whereNow { return true } else { return false } }
}

/// The resolve door's answers, read after the write returns (the body runs
/// on the store's queue). (For Rick: a mutex-guarded out-parameter.)
final class HeldBackLandingBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [(Int64, CatalogRow.HeldBackLanding)] = []
    var landings: [(Int64, CatalogRow.HeldBackLanding)] {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
