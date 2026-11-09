// PublicMarkStore.swift — Make Public / Make Private: the ONE engine.
// Schema v1.15 `public_marks` (Core CatalogPublicMarkRows.swift); ruling
// 2026-11-09 (docs/DECISIONS.md "Make Public is one bit").
//
// One sentence (Rick's): "mark a video public — the whole family may watch
// it — or clear that mark; everything else is private."
//
// What this is NOT (cut, on purpose): no audiences, no guest view, no web
// filtering, no segments, nothing Hallie reads, no "make everything private"
// (Rick 2026-11-09: private is the default; a panic button belongs with the
// guest view). Today the bit is shown (the globe in the Archive tab) and
// nothing else acts on it.
//
// Shape: a feature store behind a seam (rule 12, #337) — the model holds ONE
// (`VideoScanModel.publicMarks`, like `provenanceRoles`); nothing here
// extends the model. Every write goes through the session's ONE writer, the
// CatalogCommitter's side-table door (`commitSideTables(via: .publicMarks)`):
// one synchronous transaction on the main actor, the same refusals as every
// person's change (read-only / viewer session, a job's write hold, a blocked
// or reopening catalog). No SQL from the UI.
//
// Truth: catalog.sqlite is the truth; `publicDigests` is a read-only
// projection of the contents whose CURRENT row says public, loaded when
// catalog.sqlite becomes the authority and corrected — for EVERY selected
// content — from the transaction's own read-back after every commit. It is
// DISPLAY ONLY (the globe, the menu's wording): `set` decides changed /
// unchanged inside the transaction from the table, never from the set, and a
// load snapshot whose read began before a commit or attach is discarded
// (`commitEpoch`). FAIL CLOSED: no row, a 0, an unreadable row, an unloaded
// or unattached store all read as PRIVATE.
//
// Outcomes of a set (each tested, none reported as success unless written):
//   .set(changed:unchanged:)  rows appended for `changed` contents; contents
//                             already in that state (by the table) are left —
//                             no duplicate row;
//   .refused(words)           nothing written — no catalog, a read-only or
//                             viewer session, a hold, a blocked store, a
//                             content the catalog does not hold yet.
//
// Memory: one 64-character digest per PUBLIC content — bounded by the
// content count; 100k public contents ≈ 10 MB, today none. Replaced whole on
// `load`, never grows without a commit behind it.
//
// (For Rick: a write-through cache in front of an append-only table — the
// set is a std::unordered_set<digest> rebuilt from SQL, and the only mutator
// is a blocking call into the one writer thread.)

import Combine
import Foundation
import VideoScanCore

/// The words Make Public shows and logs (pure; tests read them).
enum PublicMarkWords {
    static let makePublic = "Make Public"
    static let makePrivate = "Make Private"
    static func makePublicTitle(_ count: Int) -> String { count > 1 ? "Make \(count) Public" : makePublic }
    static func makePrivateTitle(_ count: Int) -> String { count > 1 ? "Make \(count) Private" : makePrivate }

    static let publicHelp = "Public: the whole family may watch this video. Every byte-identical copy shares the mark. "
        + "Nothing is shared yet — the family view is not built; this only records your choice."
    static let privateHelp = "Private again: only you. A video is private unless you make it public."
    static let badgeHelp = "Public — the whole family may watch this"
    static let badgeLabel = "Public"

    static let noDigestHelp = "The public mark belongs to a file's content, identified by its full SHA-256. "
        + "This file has none yet — run Content Analysis ▸ Full Hashes first."
    static func someWithoutDigestHelp(_ missing: Int, of total: Int) -> String {
        "\(missing) of the \(total) selected files have no full SHA-256 yet, so the selection cannot be marked. "
            + "Run Content Analysis ▸ Full Hashes first, or select only hashed files."
    }
    static let notArchivedHelp = "Only an archived video can be made public. Promote it to the archive first."
    static func someNotArchivedHelp(_ count: Int, of total: Int) -> String {
        "\(count) of the \(total) selected files are not archived. Only archived videos can be made public — select only archived ones."
    }
    static func writeRefusalHelp(_ why: String) -> String { "The mark cannot be changed now: \(why)." }

    static let refusedTitle = "The public mark was not changed"

    static func stateWord(_ isPublic: Bool) -> String { isPublic ? "public" : "private" }
}

/// The digests a selection can be marked by (pure; O(selection)).
struct PublicMarkTargets: Equatable {
    /// Distinct whole-file digests of the selected ARCHIVED records.
    var digests: Set<String> = []
    /// Selected records with no whole-file digest (CatalogCommit.digest(of:)).
    var missing = 0
    /// Selected records that are not archived.
    var notArchived = 0
    var total = 0

    /// `isArchived`: the archive's own predicate for one record (the caller
    /// passes the model's; O(1) each).
    init(records: [VideoRecord], isArchived: (VideoRecord) -> Bool) {
        total = records.count
        for record in records {
            guard isArchived(record) else { notArchived += 1; continue }
            if let digest = CatalogCommit.digest(of: record) { digests.insert(digest) } else { missing += 1 }
        }
    }

    /// Why the selection cannot be marked; nil = it can. ALL or nothing: a
    /// selection holding one file that cannot be marked is refused whole, so
    /// "Make 5 Public" never quietly marks 4.
    var refusal: String? {
        if total == 0 { return nil }
        if notArchived == total { return PublicMarkWords.notArchivedHelp }
        if notArchived > 0 { return PublicMarkWords.someNotArchivedHelp(notArchived, of: total) }
        if missing == total { return PublicMarkWords.noDigestHelp }
        if missing > 0 { return PublicMarkWords.someWithoutDigestHelp(missing, of: total) }
        return nil
    }
}

/// The catalog side of the store: reads through the repository, writes
/// through the session's committer (the one door). Mirrors
/// ProvenanceRoleCatalogBacking.
@MainActor
final class PublicMarkCatalogBacking {

    /// One synchronous write of `body` under a few words; nil = committed.
    typealias Commit = (_ what: String, _ body: (any CatalogTransaction) throws -> Void) -> String?

    let repository: any CatalogRepository
    private let commit: Commit
    /// Why a write cannot be taken right now (nil = it can).
    let writeRefusal: () -> String?

    init(repository: any CatalogRepository, writeRefusal: @escaping () -> String?, commit: @escaping Commit) {
        self.repository = repository
        self.writeRefusal = writeRefusal
        self.commit = commit
    }

    /// The session's committer: its repository, its refusal, its door.
    convenience init(committer: CatalogCommitter) {
        self.init(repository: committer.repository, writeRefusal: { [weak committer] in
            guard let committer else { return "the catalog is closed" }
            return committer.sideTableWriteRefusal
        }, commit: { [weak committer] what, body in
            guard let committer else { return "the catalog is closed" }
            return committer.commitSideTables(what, via: .publicMarks, body)
        })
    }

    func write(_ what: String, _ body: (any CatalogTransaction) throws -> Void) -> String? { commit(what, body) }
}

/// A content the catalog does not hold yet: the whole change rolls back.
private struct PublicMarkContentMissing: Error, CustomStringConvertible {
    let digest: String
    var description: String {
        "content \(digest.prefix(12))… is not in catalog.sqlite yet (its row is still being saved) — try again in a moment"
    }
}

@MainActor
final class PublicMarkStore: ObservableObject {

    enum SetOutcome: Equatable {
        case set(changed: Int, unchanged: Int)
        case refused(String)
    }

    /// Bumped after every load and every commit — what the globe observes.
    @Published private(set) var revision = 0
    /// DISPLAY ONLY: the contents whose current row says public.
    private(set) var publicDigests: Set<String> = []
    /// Current rows whose flag this build cannot read (counted at load; said once each). Private.
    private(set) var unreadable = 0
    private var saidUnreadable: Set<Int64> = []
    private(set) var backing: PublicMarkCatalogBacking?
    /// The one log sink (the model's console + catalog.log + videoscan.log).
    var note: (String) -> Void = { _ in }

    // MARK: Attach / load

    func attach(_ backing: PublicMarkCatalogBacking) {
        self.backing = backing
        publicDigests = []
        unreadable = 0
        commitEpoch &+= 1          // a load begun on the old backing is stale
        revision &+= 1
    }

    /// Read every current mark off the main actor and replace the set.
    /// nil = read; else the words (the set is left as it was).
    @discardableResult
    func load() async -> String? {
        // A commit (or attach) during the read makes the snapshot stale:
        // read again, a few times; the committed entries stay meanwhile.
        do {
            for _ in 0..<3 {
                guard let backing else { return "the catalog is not open" }
                let epoch = commitEpoch
                let rows = try await backing.repository.read { reader -> [CatalogRow.PublicMarkReading] in
                    var out: [CatalogRow.PublicMarkReading] = []
                    try reader.currentPublicMarks { out.append($0) }
                    return out
                }
                if apply(rows, takenAt: epoch) { return nil }
            }
            note("public marks were changing while they were read — the globe follows each change as it commits")
            return nil
        } catch {
            let words = String(describing: error)
            note("public marks could not be read from catalog.sqlite (\(words)) — every video shows as private")
            return words
        }
    }

    /// Bumped by every commit (`set`) and every `attach`; a load snapshot is
    /// stamped with it when its read starts.
    private(set) var commitEpoch = 0

    /// Replace the set with a whole-table snapshot taken at `epoch`.
    /// Returns false — and changes nothing — when a commit or an attach
    /// happened after the snapshot's read began: an older snapshot never
    /// replaces newer committed state.
    @discardableResult
    func apply(_ rows: [CatalogRow.PublicMarkReading], takenAt epoch: Int) -> Bool {
        guard epoch == commitEpoch else { return false }
        publicDigests = Set(rows.lazy.filter(\.isPublic).map(\.digest))
        let bad = rows.filter { !$0.readable }
        unreadable = bad.count
        for row in bad.prefix(10) { sayUnreadable(row) }
        if bad.count > 10 { note("… and \(bad.count - 10) more public-mark row(s) this version cannot read — shown as private") }
        revision &+= 1
        return true
    }

    // MARK: Reading (display)

    /// Whether `digest` is public as the projection knows it. nil digest = private.
    func isPublic(_ digest: String?) -> Bool {
        guard let digest else { return false }
        return publicDigests.contains(digest.lowercased())
    }

    /// How many of `digests` the projection shows as public.
    func publicCount(in digests: Set<String>) -> Int {
        digests.reduce(0) { $0 + (isPublic($1) ? 1 : 0) }
    }

    /// Why a set would be refused now; nil = it would be written.
    var writeRefusal: String? {
        guard let backing else { return "the catalog is not open for writing in this session" }
        return backing.writeRefusal()
    }

    // MARK: The one writer

    /// Set the bit on every content in `digests` (a selection's distinct
    /// whole-file digests). `files` = how many selected rows that is (the
    /// log's words). ALL or nothing: every selected content must be one the
    /// catalog holds, checked inside the transaction BEFORE anything is
    /// skipped or appended — in both directions (Codex #273 F2).
    func set(_ isPublic: Bool, digests: Set<String>, files: Int? = nil, now: Date = Date()) -> SetOutcome {
        let keys = digests.map { $0.lowercased() }.sorted()
        let words = PublicMarkWords.stateWord(isPublic)
        let scope = "\(keys.count) content\(keys.count == 1 ? "" : "s")" + (files.map { " (\($0) file\($0 == 1 ? "" : "s"))" } ?? "")
        guard !keys.isEmpty else { return .refused("nothing selected has a full SHA-256") }
        note("START make \(words): \(scope)")
        guard let backing else { return refuse("the catalog is not open for writing in this session", words, scope) }
        if let why = backing.writeRefusal() { return refuse(why, words, scope) }
        // The projection is DISPLAY ONLY. Which contents change is decided
        // inside the transaction, from the table, for EVERY selected digest —
        // a cleared or stale projection can never skip a change.
        let seconds = Int64(now.timeIntervalSince1970.rounded(.down))
        var changed: [String] = []
        var after: [String: CatalogRow.PublicMarkReading] = [:]
        let refusal = backing.write("make \(words): \(scope)") { tx in
            changed = []
            let held = try tx.publicMarkContentHeld(digests: keys)
            if let stranger = keys.first(where: { !held.contains($0) }) { throw PublicMarkContentMissing(digest: stranger) }
            let before = try tx.currentPublicMarks(digests: keys)
            for digest in keys where !Self.isAlready(isPublic, before[digest]) {
                let decision = CatalogRow.PublicMarkDecision(digest: digest, isPublic: isPublic, decidedAt: seconds)
                guard try tx.appendPublicMark(decision) == .recorded else { throw PublicMarkContentMissing(digest: digest) }
                changed.append(digest)
            }
            after = try tx.currentPublicMarks(digests: keys)   // the read-back of every selected content, inside the commit
        }
        if let refusal { return refuse(refusal, words, scope) }
        // Every selected content's entry now says what the table said at
        // commit, and any load snapshot taken before this commit is stale.
        for digest in keys {
            if after[digest]?.isPublic == true { publicDigests.insert(digest) } else { publicDigests.remove(digest) }
        }
        commitEpoch &+= 1
        revision &+= 1
        for digest in changed.prefix(20) {
            note("  content \(digest.prefix(12))… \(PublicMarkWords.stateWord(!isPublic)) → \(words)")
        }
        if changed.count > 20 { note("  … and \(changed.count - 20) more") }
        let unchanged = keys.count - changed.count
        note("OUTCOME make \(words): \(scope) — \(changed.count) changed, \(unchanged) already \(words); "
             + "\(publicDigests.count) public now. History is kept; to undo, make \(PublicMarkWords.stateWord(!isPublic)) again.")
        return .set(changed: changed.count, unchanged: unchanged)
    }

    /// Whether the table's current row already says `isPublic`.
    nonisolated static func isAlready(_ isPublic: Bool, _ row: CatalogRow.PublicMarkReading?) -> Bool {
        guard let row else { return !isPublic }             // no row is private already
        guard row.readable else { return false }            // an unreadable row is replaced by a readable one
        return row.isPublic == isPublic
    }

    private func refuse(_ why: String, _ words: String, _ scope: String) -> SetOutcome {
        note("REFUSED make \(words): \(scope) — \(why). Nothing was written.")
        return .refused(why)
    }

    private func sayUnreadable(_ row: CatalogRow.PublicMarkReading) {
        guard saidUnreadable.insert(row.markID).inserted else { return }
        note("public-mark row \(row.markID) for content \(row.digest.prefix(12))… holds a value this version cannot read "
             + "(\(row.storedFlag)) — shown as private; nothing was changed")
    }
}
