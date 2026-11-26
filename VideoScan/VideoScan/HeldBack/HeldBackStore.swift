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
// THE CARRY (data-risk: it writes Rick's curated values). Two steps, both
// on the main actor:
//   previewCarry(ids) — what WOULD be written now, nothing written. The
//     confirmation shows exactly this (Codex #385 #2), Confirmed Junk warning
//     included. Per offer, re-checked NOW: the record is live and at the
//     proven path; it still stores the whole-file SHA-256 the proof bound to
//     (#1); the file's stamp is the one the proof read; the fields are judged
//     against the CONTENT — the record and every copy of its digest (tag,
//     date and place are stored per content) — so a value Rick set on any
//     copy is never overwritten, and no date goes on while ANY copy is
//     archived (#3). The content's STORED conflicts are read from
//     catalog.sqlite first (`previewCarryNow`; Codex #389 P1): a field whose
//     display row says the copies disagree (conflict = 1) loads EMPTY on
//     every copy, so memory alone would call it "nothing set" — it is shown
//     as "copies of this file disagree (1980 / 1992) — resolve it in the
//     Inspector first", never carried, and its row stays open. A content
//     whose conflicts could not be read is not carried at all (fail closed).
//     Then the whole selection is judged together: rows
//     offering different values for one content carry neither (#4).
//   carry(preview) —
//   1. refuse before mutating: no catalog, a read-only / viewer session, a
//      job's write hold, a blocked or reopening store → nothing changes;
//      the stored conflicts are read again (the one await — everything
//      after it runs on the main actor without a suspension, so nothing
//      the commit door writes can interleave with the judgement);
//   2. the preview is computed again; if it differs from what Rick confirmed
//      the carry returns `.reconfirm(new)` and writes nothing (the sheet
//      shows the new one);
//   3. Rick's own unsaved edits on the destinations are committed FIRST
//      under the ordinary save door (`flushRecords`) — so a value he typed
//      inside the 2 s debounce is durable, and attributed to him, before
//      anything is judged durable (#5); refused → nothing written;
//   4. the `.carry` fields are set and committed through the commit door
//      under the `import carry` writer (`CatalogCommitter.commitCarried`) —
//      only if that commit stored every row …
//   5. … the held-back rows are closed in ONE side-table transaction, also
//      written as `import carry` (#9), and each row closes only when the
//      STORE's own row for each destination has the proven digest and shows
//      every value the row claims (carried or already there) — read in that
//      same transaction (#5). If (5) is refused after (4) stored, the values
//      are on the live files and the rows stay open (their pairs stay
//      offered, #10); the next look offers them as "already on the live
//      file" and closing them is one click.
// Outcomes (each tested): carried(n, closed, skipped) · refused(words) —
// nothing written · reconfirm(preview) — nothing written · notSaved(words)
// — values in memory, rows open, the store's words.
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
    /// Commit Rick's pending edits on these records now (the ordinary save
    /// door — his values, his attribution). nil = durable.
    let flushRecords: (Set<UUID>) -> String?
    /// Commit these records now (import carry). nil = all stored.
    let commitRecords: (Set<UUID>) -> String?
    /// One side-table transaction. nil = committed.
    let commitSide: (_ what: String, _ body: (any CatalogTransaction) throws -> Void) -> String?

    init(repository: any CatalogRepository, writeRefusal: @escaping () -> String?,
         flushRecords: @escaping (Set<UUID>) -> String?,
         commitRecords: @escaping (Set<UUID>) -> String?,
         commitSide: @escaping (_ what: String, _ body: (any CatalogTransaction) throws -> Void) -> String?) {
        self.repository = repository
        self.writeRefusal = writeRefusal
        self.flushRecords = flushRecords
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
                  flushRecords: { [weak committer] ids in
                      guard let committer else { return "the catalog is closed" }
                      return committer.commitPending(ids: ids)
                  },
                  commitRecords: { [weak committer] ids in
                      guard let committer else { return "the catalog is closed" }
                      return committer.commitCarried(ids: ids)
                  },
                  commitSide: { [weak committer] what, body in
                      guard let committer else { return "the catalog is closed" }
                      return committer.commitSideTables(what, via: .heldBack, as: .importCarry, body)
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
        /// What would be written changed since Rick confirmed: nothing was
        /// written; this is what would be written now (show it again).
        case reconfirm(HeldBackCarryPreview)
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
    /// Codex #389 P1: per destination digest, the curated fields the store
    /// holds with `conflict = 1` (absent = none). Read from catalog.sqlite by
    /// `refreshStoredConflicts`; bounded by the offers (≈ 100 B each).
    private(set) var storedConflicts: [String: CatalogRow.HeldBackStoredConflicts] = [:]
    /// The digests `storedConflicts` answers for (a digest never read is not
    /// judged: its pairs are not carried).
    private(set) var conflictsRead: Set<String> = []

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
        storedConflicts = [:]
        conflictsRead = []
        listState = .idle
        openCount = nil
    }

    /// Codex #389 P1: read the stored conflicts of these digests NOW (one
    /// read, off the main actor). nil = read; else the words (the digests
    /// stay unread, so their pairs are not carried).
    @discardableResult
    func refreshStoredConflicts(_ digests: Set<String>) async -> String? {
        let keys = Set(digests.map { $0.lowercased() })
        guard !keys.isEmpty else { return nil }
        guard let backing else { return "the catalog is not open" }
        do {
            let read = try await backing.repository.read { try $0.heldBackStoredConflicts(digests: Array(keys)) }
            for key in keys { storedConflicts[key] = read[key] }
            conflictsRead.formUnion(keys)
            return nil
        } catch {
            conflictsRead.subtract(keys)
            let words = String(describing: error)
            note("held back at import: could not read whether copies of \(keys.count) file(s) disagree (\(words)) — those pairs are not carried")
            return words
        }
    }

    private func stored(_ digest: String?) -> CatalogRow.HeldBackStoredConflicts {
        digest.flatMap { storedConflicts[$0.lowercased()] } ?? .init()
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

    /// The job hands its proven pairs over (replacing the last run's); each
    /// is judged against the content as it is now (its copies included).
    func setOffers(_ offers: [HeldBackOffer]) {
        self.offers = offers
        rejudgeOffers()
        let digests = Set(offers.compactMap(\.destinationDigest))
        Task { [weak self] in
            guard let self, await self.refreshStoredConflicts(digests) == nil else { return }
            self.rejudgeOffers()
        }
    }

    /// Every offer's fields judged again against the live records now (one
    /// projection; after a job hands over and after a carry — never in a view).
    private func rejudgeOffers() {
        guard !offers.isEmpty else { return }
        let index = HeldBackLiveIndex.project(records(), dateReadOnly: isDateReadOnly)
        offers = offers.map { o in
            guard let live = index.byID[o.recordID] else {
                var gone = o
                gone.blocked = "the live file is no longer in the catalog"
                return gone
            }
            return o.rejudged(live: live, copies: index.copies(of: live), stored: stored(o.destinationDigest))
        }
    }

    // MARK: The one writer

    /// Why a carry would be refused now; nil = it would be attempted.
    var writeRefusal: String? {
        guard let backing else { return "the catalog is not open for writing in this session" }
        return backing.writeRefusal()
    }

    /// The stored conflicts read now, then the preview: what the
    /// confirmation shows (Carry Selected…).
    func previewCarryNow(_ ids: Set<String>) async -> HeldBackCarryPreview {
        await refreshStoredConflicts(Set(offers.filter { ids.contains($0.id) }.compactMap(\.destinationDigest)))
        return previewCarry(ids)
    }

    /// What a carry of these offers would write NOW, judged with the stored
    /// conflicts last read (`previewCarryNow` reads them first). Writes
    /// nothing; the confirmation shows it, and `carry` refuses anything else.
    func previewCarry(_ ids: Set<String>) -> HeldBackCarryPreview {
        let chosen = offers.filter { ids.contains($0.id) }.sorted { ($0.qid, $0.recordID.uuidString) < ($1.qid, $1.recordID.uuidString) }
        let copies = copiesByDigest(Set(chosen.compactMap(\.destinationDigest)))
        var items: [HeldBackCarryPreview.Item] = []
        var judged: [(index: Int, key: String, fields: HeldBackFields)] = []
        for offer in chosen {
            var item = HeldBackCarryPreview.Item(offer)
            switch recheck(offer, copies: copies[offer.destinationDigest ?? ""] ?? []) {
            case .failure(let why): item.skipped = why
            case .success(let fields):
                item.fields = fields
                judged.append((items.count, offer.destinationDigest ?? "", fields))
            }
            items.append(item)
        }
        let resolved = HeldBackBatch.resolve(judged.map { ($0.key, $0.fields) })
        for (j, entry) in judged.enumerated() {
            let fields = resolved[j]
            items[entry.index].fields = fields
            if !fields.carriesAny && !fields.allAlready {
                items[entry.index].skipped = HeldBackWords.nothingCarried(fields)
            }
        }
        return HeldBackCarryPreview(ids: ids, items: items)
    }

    /// Rick confirmed `preview` (the one the confirmation showed). Nothing is
    /// written without this call, nothing is written if what would be
    /// written changed, and nothing Rick already set is overwritten.
    @discardableResult
    func carry(_ preview: HeldBackCarryPreview, now: Date = Date()) async -> CarryOutcome {
        note("START carry from held-back rows — \(preview.items.count) confirmed pair(s)")
        guard !preview.ids.isEmpty else { return refuse("nothing was selected") }
        guard let backing else { return refuse("the catalog is not open for writing in this session") }
        if let why = backing.writeRefusal() { return refuse(why) }
        // Codex #389 P1: the stored conflicts, read again now. The ONLY
        // suspension: from here to the commit nothing else runs on the main actor.
        let digests = Set(offers.filter { preview.ids.contains($0.id) }.compactMap(\.destinationDigest))
        if let why = await refreshStoredConflicts(digests) {
            return refuse("could not read whether copies of the chosen files disagree (\(why))")
        }
        if let why = backing.writeRefusal() { return refuse(why) }
        let current = previewCarry(preview.ids)
        guard current == preview else {
            note("REFUSED carry from held-back rows — what would be written changed since it was confirmed; shown again. Nothing was written.")
            lastCarryLines = ["Not carried yet — what would be written changed since you looked; review it and confirm again. Nothing was written."]
            return .reconfirm(current)
        }
        let resolving = current.items.filter { $0.skipped == nil }
        var lines = current.items.compactMap { i in i.skipped.map { "SKIPPED \(i.oldName) → \(i.liveName): \($0)" } }
        let destinations = Set(resolving.map(\.recordID))
        if !destinations.isEmpty, let why = backing.flushRecords(destinations) {
            return refuse("your own unsaved edits on \(destinations.count == 1 ? "that file" : "those files") could not be saved first (\(why))")
        }
        let before = openCount
        if let why = applyAndCommit(resolving, backing: backing) {
            for line in lines { note("  " + line) }
            lastCarryLines = lines + ["NOT SAVED — \(why)"]
            note("OUTCOME carry NOT SAVED — \(why). The values are on the records in memory and are saved with the next commit "
                 + "that can run; no held-back row was closed (\(before.map(String.init) ?? "?") open before · the same after).")
            return .notSaved(why)
        }
        lines += resolving.map { "CARRIED \($0.oldName) → \($0.liveName) [\($0.evidence.label)]: " + Self.fieldsLine($0.fields) }
        let closings = Self.closings(resolving, at: Int64(now.timeIntervalSince1970.rounded(.down)))
        let closed = close(closings, backing: backing)
        lines += closed.lines
        for line in lines { note("  " + line) }
        lastCarryLines = lines
        offers.removeAll { closed.qids.contains($0.qid) }
        markResolved(closed.qids, closings.map(\.resolution))
        rejudgeOffers()
        let skipped = current.items.count - resolving.count
        note("OUTCOME carry — \(resolving.count) pair(s) carried, \(closed.qids.count) held-back row(s) closed, \(skipped) skipped · "
             + "open rows \(before.map(String.init) ?? "?") before · \(openCount.map(String.init) ?? "?") after "
             + "(the difference: closed as personDecided; nothing deleted)")
        return .carried(carried: resolving.count, closed: closed.qids.count, skipped: skipped)
    }

    // MARK: Carry helpers

    /// Every record (removed ones too) of each digest — one pass.
    private func copiesByDigest(_ digests: Set<String>) -> [String: [VideoRecord]] {
        guard !digests.isEmpty else { return [:] }
        var out: [String: [VideoRecord]] = [:]
        for r in records() {
            if let d = CatalogCommit.digest(of: r), digests.contains(d) { out[d, default: []].append(r) }
        }
        return out
    }

    /// Set the `.carry` fields on the records, then commit exactly those
    /// records through the door. nil = stored (or nothing to store).
    private func applyAndCommit(_ items: [HeldBackCarryPreview.Item], backing: HeldBackCatalogBacking) -> String? {
        var changed: Set<UUID> = []
        var wrote: [(VideoRecord, Bool, Bool)] = []
        for item in items where item.fields.carriesAny {
            guard let record = recordForID(item.recordID) else { continue }
            let set = apply(item.fields, oldDateConfidence: item.oldDateConfidence,
                            oldPlaceConfidence: item.oldPlaceConfidence, to: record)
            changed.insert(record.id)
            wrote.append((record, set.date, set.place))
        }
        let words = changed.isEmpty ? nil : backing.commitRecords(changed)
        // The records in memory now hold the values either way (what Rick sees).
        for (record, date, place) in wrote { didCarry(record, date, place) }
        return words
    }

    /// One held-back row to close, and what the store must show first.
    struct Closing {
        struct Check: Equatable {
            let fileID: String
            let digest: String
            let fields: HeldBackFields
        }
        let resolution: CatalogRow.HeldBackResolution
        let checks: [Check]
    }

    /// One closing per held-back row whose every resolving pair closes it
    /// (no batch conflict). Two pairs for one row: both got the values; the
    /// row is closed once (the first file in id order), its note counts the
    /// rest, and the store must show the values on every one. Pure.
    static func closings(_ items: [HeldBackCarryPreview.Item], at seconds: Int64) -> [Closing] {
        let byRow = Dictionary(grouping: items, by: \.qid)
        return byRow.keys.sorted().compactMap { qid in
            guard let pairs = byRow[qid], let first = pairs.first, pairs.allSatisfy(\.closesRow) else { return nil }
            let more = pairs.count - 1
            let note = resolutionNote(first) + (more == 0 ? "" : "; also carried onto \(more) more cop\(more == 1 ? "y" : "ies")")
            let checks = pairs.compactMap { p in
                p.destinationDigest.map { Closing.Check(fileID: p.recordID.uuidString, digest: $0, fields: p.fields) }
            }
            guard checks.count == pairs.count else { return nil }
            return Closing(resolution: CatalogRow.HeldBackResolution(qid: qid, fileID: first.recordID.uuidString, note: note, resolvedAt: seconds),
                           checks: checks)
        }
    }

    /// Why the store's row does not (yet) show what `check` claims; nil = it does.
    nonisolated static func notDurable(_ check: Closing.Check, stored: CatalogLoadedRow?) -> String? {
        guard let stored else { return "its catalog row is not stored yet" }
        guard stored.file.contentDigest?.lowercased() == check.digest.lowercased() else {
            return "the stored row no longer records the checked content"
        }
        func value(_ f: HeldBackFieldOffer?) -> String? {
            switch f {
            case .carry(let v)?, .already(let v)?: return v
            default: return nil
            }
        }
        if let v = value(check.fields.tag), stored.shown.mediaDisposition != v { return "the store does not show tag \(v)" }
        if let v = value(check.fields.date), stored.shown.userDate?.value != v { return "the store does not show date \(v)" }
        if let v = value(check.fields.place), stored.shown.userPlace?.place != v { return "the store does not show place \(v)" }
        return nil
    }

    /// Close the rows in ONE side-table transaction, each only after the
    /// store's own rows show its values (read in the same transaction).
    /// Returns the rows closed and a line for each that was not (or for the
    /// whole refusal).
    private func close(_ closings: [Closing], backing: HeldBackCatalogBacking) -> (qids: Set<Int64>, lines: [String]) {
        guard !closings.isEmpty else { return ([], []) }
        let box = HeldBackLandingBox()
        if let refusal = backing.commitSide("closed \(closings.count) held-back row(s) after a confirmed carry", { tx in
            box.landings = []
            for c in closings {
                var why: String?
                for check in c.checks where why == nil {
                    why = Self.notDurable(check, stored: try tx.storedRow(id: check.fileID))
                }
                if let why {
                    box.landings.append((c.resolution.qid, .notDurable(why)))
                } else {
                    box.landings.append((c.resolution.qid, .landed(try tx.resolveHeldBack(c.resolution))))
                }
            }
        }) {
            return ([], ["the held-back rows were NOT closed — \(refusal); the values are saved on the live files, "
                         + "and the rows will show them as already carried"])
        }
        let landings = box.landings
        return (Set(landings.filter { $0.1 == .landed(.resolved) }.map(\.0)),
                landings.filter { $0.1 != .landed(.resolved) }.map { "row \($0.0) was NOT closed — \($0.1.words)" })
    }

    private enum Recheck { case success(HeldBackFields), failure(String) }

    /// The offer judged against the catalog and the disk as they are NOW.
    /// `copies`: every record (removed too) storing the proven digest.
    private func recheck(_ offer: HeldBackOffer, copies: [VideoRecord]) -> Recheck {
        guard let record = recordForID(offer.recordID), record.removal == nil else {
            return .failure("the live file is no longer in the catalog")
        }
        guard record.fullPath == offer.livePath else { return .failure("the live file moved since it was checked — run Find Moved Copies again") }
        guard let proven = offer.destinationDigest else { return .failure(HeldBackWords.needsFullHash) }
        guard CatalogCommit.digest(of: record) == proven else { return .failure(HeldBackWords.identityChanged) }
        guard FileIdentityStamp.capture(path: record.fullPath) == offer.stamp else {
            return .failure("the live file changed (or its drive was reconnected) since it was checked — run Find Moved Copies again")
        }
        guard conflictsRead.contains(proven.lowercased()) else { return .failure(HeldBackWords.conflictsUnread) }
        let readOnly = isDateReadOnly(record) || copies.contains { isDateReadOnly($0) }
        let live = HeldBackLive(record, dateReadOnly: readOnly)
        let others = copies.filter { $0.id != record.id && $0.removal == nil }.map { HeldBackLive($0, dateReadOnly: readOnly) }
        return .success(HeldBackFields.evaluate(old: offer.old, live: live, copies: others, stored: stored(proven)))
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

    nonisolated static func fieldsLine(_ f: HeldBackFields) -> String {
        [HeldBackWords.field("tag", f.tag), HeldBackWords.field("date", f.date), HeldBackWords.field("place", f.place)]
            .compactMap { $0 }.joined(separator: "; ")
    }

    /// What `resolution_note` says: the origin, the evidence (in its own
    /// words — a sampled match is "likely", never "proven"), the values.
    static func resolutionNote(_ offer: HeldBackOffer, _ f: HeldBackFields) -> String {
        resolutionNote(qid: offer.qid, evidence: offer.evidence, f)
    }

    static func resolutionNote(_ item: HeldBackCarryPreview.Item) -> String {
        resolutionNote(qid: item.qid, evidence: item.evidence, item.fields)
    }

    private static func resolutionNote(qid: Int64, evidence: HeldBackEvidence, _ f: HeldBackFields) -> String {
        "carried from the October import row (qid \(qid)) onto a moved copy — \(evidence.label); Rick confirmed. " + fieldsLine(f)
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

/// What the closing transaction did with one row.
enum HeldBackCloseLanding: Equatable, Sendable {
    case landed(CatalogRow.HeldBackLanding)
    /// The store's row did not show the values yet: the row was left open.
    case notDurable(String)

    var words: String {
        switch self {
        case .landed(let l): return "\(l)"
        case .notDurable(let why): return why
        }
    }
}

/// The resolve door's answers, read after the write returns (the body runs
/// on the store's queue). (For Rick: a mutex-guarded out-parameter.)
final class HeldBackLandingBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [(Int64, HeldBackCloseLanding)] = []
    var landings: [(Int64, HeldBackCloseLanding)] {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// What a carry WOULD write now (Codex #385 #2): the confirmation shows it,
/// and `HeldBackStore.carry` writes only when it is still exactly this.
struct HeldBackCarryPreview: Equatable, Sendable {
    struct Item: Equatable, Sendable, Identifiable {
        var offerID: String
        var qid: Int64
        var recordID: UUID
        var oldName: String
        var liveName: String
        var evidence: HeldBackEvidence
        var destinationDigest: String?
        var oldDateConfidence: String?
        var oldPlaceConfidence: String?
        /// The fields as judged now, the whole selection considered.
        var fields: HeldBackFields
        /// Why this pair is left (nil = it is carried / its row closed).
        var skipped: String?
        var id: String { offerID }

        init(_ o: HeldBackOffer) {
            offerID = o.id
            qid = o.qid
            recordID = o.recordID
            oldName = o.oldName
            liveName = o.liveName
            evidence = o.evidence
            destinationDigest = o.destinationDigest
            oldDateConfidence = o.old.userDateConfidence
            oldPlaceConfidence = o.old.userPlaceConfidence
            fields = o.fields
        }

        /// Its held-back row may close (every value landed or was already there,
        /// or Rick's own differing value is kept) — never with a batch
        /// conflict, never while the copies disagree on a field it carries.
        var closesRow: Bool { skipped == nil && !fields.hasBatchConflict && !fields.hasStoredConflict }
        var setsConfirmedJunk: Bool { skipped == nil && fields.setsConfirmedJunk }
    }

    var ids: Set<String>
    var items: [Item]

    /// The distinct live files something would be carried onto or closed against.
    var destinationCount: Int { Set(items.filter { $0.skipped == nil }.map(\.recordID)).count }
}
