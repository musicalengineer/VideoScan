// ProvenanceRoleStore.swift — Provenance ▸ Set Role: the ONE engine.
// Policy: docs/guides/provenance_roles.md; schema v1.12 `provenance_roles`
// (Core CatalogProvenanceRoleRows.swift); rulings 2026-10-26.
//
// One sentence (Rick's): "say what this file is — Master, Camera Original,
// … — and have every copy of it say the same, for good."
//
// Shape: a feature store behind a seam (rule 12, #337) — the model holds ONE
// (`VideoScanModel.provenanceRoles`, like `footageLikeness`); nothing here
// extends the model. Every write goes through the session's ONE writer, the
// CatalogCommitter's side-table door (`commitSideTables(via:
// .provenanceRoles)`): one synchronous transaction on the main actor, the
// same refusals as every person's change (read-only / viewer session, a
// job's write hold, a blocked or reopening catalog). No SQL from the UI.
//
// Truth: catalog.sqlite is the truth; `byDigest` is a read-only projection
// of the CURRENT row per content, loaded when catalog.sqlite becomes the
// authority and refreshed from the transaction's own read-back after every
// commit. The Inspector does not trust it — it reads the store
// (`readCurrent`) for the selected content every time the revision moves.
// A key this build cannot read is shown as Unknown and said once.
//
// Outcomes of a set (each tested, none reported as success unless written):
//   .set(changed:unchanged:)  rows appended for `changed` contents; contents
//                             already in that role are left (no duplicate row);
//   .refused(words)           nothing written — no catalog, a read-only or
//                             viewer session, a hold, a blocked store, a
//                             content the catalog does not hold yet.
//
// Memory: one ProvenanceRoleReading (~200 B with its strings) per content
// that HAS a role — bounded by the content count; worst case 100k contents
// ≈ 20 MB, today a handful. Replaced whole on `load`, never grows without a
// commit behind it.
//
// (For Rick: a write-through cache in front of an append-only table — the
// map is a std::unordered_map<digest, row> rebuilt from SQL, and the only
// mutator is a blocking call into the one writer thread.)

import Combine
import Foundation
import VideoScanCore

/// The words Provenance ▸ Set Role shows and logs (pure; tests read them).
enum ProvenanceRoleWords {
    static let menuTitle = "Provenance"
    static let findTitle = "Find"
    static let setRoleTitle = "Set Role"
    /// Only Rick sets a role (policy rule 5; the only writer is a person's
    /// click in this menu) — the table records no other decider.
    static let decider = "Rick"

    static let noDigestHelp = "A role belongs to a file's content, identified by its full SHA-256. "
        + "This file has none yet — choose Catalog ▸ Fill In Full Hashes first."
    static func someWithoutDigestHelp(_ missing: Int, of total: Int) -> String {
        "\(missing) of the \(total) selected files have no full SHA-256 yet, so no role can be set for the selection. "
            + "Choose Catalog ▸ Fill In Full Hashes first, or select only hashed files."
    }
    static let setRoleHelp = "Say what this content is. Byte-identical copies share the role; only you set it."

    // The Master confirm.
    static func masterQuestion(contents: Int) -> String {
        contents == 1 ? "Mark this file as the Master?" : "Mark these \(contents) files as Masters?"
    }
    static let masterExplanation = "A Master is the first faithful transfer of the original tape, film or card, untouched. "
        + "Every byte-identical copy shares the role."
    static let sourceMissingCheckbox = "Source not in the catalog (this is the only surviving version)"
    static let masterConfirmButton = "Mark as Master"
    static let cancelButton = "Cancel"
    static let refusedTitle = "The role was not set"

    /// "Role: Master — set by Rick, Oct 26" / "Role: Unknown".
    static func inspectorLine(_ reading: CatalogRow.ProvenanceRoleReading?, now: Date = Date()) -> String {
        guard let reading else { return "Role: Unknown" }
        guard reading.known != nil else { return "Role: Unknown — the catalog holds a role this version cannot read" }
        return "Role: \(reading.role.title) — set by \(decider), \(shortDate(reading.decidedAt, now: now))"
    }

    static let sourceMissingLine = "Source not in the catalog — the only surviving version"
    static let noDigestLine = "Role: Unknown — needs a full SHA-256 before a role can be set"
    static func unreadableNote(_ reading: CatalogRow.ProvenanceRoleReading) -> String {
        "role row \(reading.roleID) for content \(reading.digest.prefix(12))… holds a key this version cannot read "
            + "(\"\(reading.storedRole)\") — shown as Unknown; nothing was changed"
    }

    /// "Oct 26" this year, "Oct 26, 2025" otherwise.
    static func shortDate(_ seconds: Int64, now: Date = Date()) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(seconds))
        let calendar = Calendar.current
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return sameYear ? date.formatted(.dateTime.month(.abbreviated).day())
            : date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    static func roleWords(_ role: ProvenanceRole, sourceMissing: Bool) -> String {
        role == .master && sourceMissing ? "Master (source not in the catalog)" : role.title
    }
}

/// The digests a selection can be given a role by (pure; O(selection)).
struct ProvenanceRoleTargets: Equatable {
    /// Distinct whole-file digests of the selected records.
    var digests: Set<String> = []
    /// Selected records with no whole-file digest (CatalogCommit.digest(of:)).
    var missing = 0
    var total = 0

    init(records: [VideoRecord]) {
        total = records.count
        for record in records {
            if let digest = CatalogCommit.digest(of: record) { digests.insert(digest) } else { missing += 1 }
        }
    }

    /// Why the selection cannot get a role; nil = it can.
    var refusal: String? {
        if total == 0 { return nil }
        if missing == total { return ProvenanceRoleWords.noDigestHelp }
        if missing > 0 { return ProvenanceRoleWords.someWithoutDigestHelp(missing, of: total) }
        return nil
    }
}

/// The catalog side of the store: reads through the repository, writes
/// through the session's committer (the one door). Mirrors
/// IgnoredContentCatalogBacking.
@MainActor
final class ProvenanceRoleCatalogBacking {

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
            return committer.commitSideTables(what, via: .provenanceRoles, body)
        })
    }

    func write(_ what: String, _ body: (any CatalogTransaction) throws -> Void) -> String? { commit(what, body) }
}

/// A content the catalog does not hold yet: the whole change rolls back.
private struct ProvenanceRoleContentMissing: Error, CustomStringConvertible {
    let digest: String
    var description: String {
        "content \(digest.prefix(12))… is not in catalog.sqlite yet (its row is still being saved) — try again in a moment"
    }
}

@MainActor
final class ProvenanceRoleStore: ObservableObject {

    enum SetOutcome: Equatable {
        case set(changed: Int, unchanged: Int)
        case refused(String)
    }

    /// What the Inspector reads for one content, from catalog.sqlite.
    enum CurrentReading: Equatable {
        case none
        case row(CatalogRow.ProvenanceRoleReading)
        case unavailable(String)
    }

    /// Bumped after every load and every commit — the Inspector's re-read key.
    @Published private(set) var revision = 0
    private(set) var byDigest: [String: CatalogRow.ProvenanceRoleReading] = [:]
    /// Rows whose key this build cannot read (counted at load; said once each).
    private(set) var unreadable = 0
    private var saidUnreadable: Set<Int64> = []
    private(set) var backing: ProvenanceRoleCatalogBacking?
    /// The one log sink (the model's console + catalog.log + videoscan.log).
    var note: (String) -> Void = { _ in }

    // MARK: Attach / load

    func attach(_ backing: ProvenanceRoleCatalogBacking) {
        self.backing = backing
        byDigest = [:]
        unreadable = 0
        revision &+= 1
    }

    /// Read every current role off the main actor and replace the map.
    /// nil = read; else the words (the map is left as it was).
    @discardableResult
    func load() async -> String? {
        guard let backing else { return "the catalog is not open" }
        do {
            let rows = try await backing.repository.read { reader -> [CatalogRow.ProvenanceRoleReading] in
                var out: [CatalogRow.ProvenanceRoleReading] = []
                try reader.currentProvenanceRoles { out.append($0) }
                return out
            }
            byDigest = Dictionary(rows.map { ($0.digest, $0) }, uniquingKeysWith: { _, newer in newer })
            let bad = rows.filter { $0.known == nil }
            unreadable = bad.count
            for row in bad.prefix(10) { sayUnreadable(row) }
            if bad.count > 10 { note("… and \(bad.count - 10) more role row(s) this version cannot read — shown as Unknown") }
            revision &+= 1
            return nil
        } catch {
            let words = String(describing: error)
            note("roles could not be read from catalog.sqlite (\(words)) — every file shows Role: Unknown")
            return words
        }
    }

    // MARK: Reading

    /// The current role of `digest` as the map knows it (menu checkmarks).
    func role(of digest: String) -> ProvenanceRole { byDigest[digest.lowercased()]?.role ?? .unknown }

    /// The role every one of `digests` shares; nil when they differ or
    /// there are none (a multi-selection shows no checkmark then).
    func commonRole(of digests: Set<String>) -> ProvenanceRole? {
        guard let first = digests.first else { return nil }
        let role = role(of: first)
        return digests.allSatisfy { self.role(of: $0) == role } ? role : nil
    }

    /// The Inspector's truth: the current row of `digest` read from
    /// catalog.sqlite now (one index probe, off the main actor).
    func readCurrent(digest: String) async -> CurrentReading {
        guard let backing else { return .unavailable("the catalog is not open") }
        let key = digest.lowercased()
        do {
            let found = try await backing.repository.read { try $0.currentProvenanceRoles(digests: [key]) }
            guard let row = found[key] else { return .none }
            if row.known == nil { sayUnreadable(row) }
            return .row(row)
        } catch {
            return .unavailable(String(describing: error))
        }
    }

    /// Why a set would be refused now; nil = it would be written.
    var writeRefusal: String? {
        guard let backing else { return "the catalog is not open for writing in this session" }
        return backing.writeRefusal()
    }

    // MARK: The one writer

    /// Set `role` on every content in `digests` (a selection's distinct
    /// whole-file digests). `sourceMissing` counts only for `.master`.
    /// `files` = how many selected rows that is (the log's words).
    func set(_ role: ProvenanceRole, digests: Set<String>, sourceMissing: Bool = false, files: Int? = nil,
             now: Date = Date()) -> SetOutcome {
        let keys = digests.map { $0.lowercased() }.sorted()
        let flag = role == .master && sourceMissing
        let words = ProvenanceRoleWords.roleWords(role, sourceMissing: flag)
        let scope = "\(keys.count) content\(keys.count == 1 ? "" : "s")" + (files.map { " (\($0) file\($0 == 1 ? "" : "s"))" } ?? "")
        guard !keys.isEmpty else { return .refused("nothing selected has a full SHA-256") }
        note("START set role \(words) on \(scope)")
        guard let backing else { return refuse("the catalog is not open for writing in this session", words, scope) }
        if let why = backing.writeRefusal() { return refuse(why, words, scope) }
        // Contents already in this role (as the map — this session's own
        // commits — knows it) are left alone; the transaction re-checks
        // each one against the table itself.
        let todo = keys.filter { !Self.isAlready(role, flag, byDigest[$0]) }
        guard !todo.isEmpty else {
            note("OUTCOME set role \(words) on \(scope) — every one already \(words); nothing written")
            return .set(changed: 0, unchanged: keys.count)
        }
        let seconds = Int64(now.timeIntervalSince1970.rounded(.down))
        var changes: [(digest: String, from: CatalogRow.ProvenanceRoleReading?)] = []
        var after: [String: CatalogRow.ProvenanceRoleReading] = [:]
        let refusal = backing.write("set role \(words) on \(todo.count) content(s)") { tx in
            changes = []
            let before = try tx.currentProvenanceRoles(digests: todo)
            for digest in todo where !Self.isAlready(role, flag, before[digest]) {
                let decision = CatalogRow.ProvenanceRoleDecision(digest: digest, role: role, decidedAt: seconds, sourceMissing: flag)
                guard try tx.appendProvenanceRole(decision) == .recorded else { throw ProvenanceRoleContentMissing(digest: digest) }
                changes.append((digest, before[digest]))
            }
            after = try tx.currentProvenanceRoles(digests: changes.map(\.digest))   // the read-back, inside the commit
        }
        if let refusal { return refuse(refusal, words, scope) }
        for (digest, row) in after { byDigest[digest] = row }
        revision &+= 1
        for change in changes.prefix(20) {
            let from = change.from.map { ProvenanceRoleWords.roleWords($0.role, sourceMissing: $0.sourceNotInCatalog) } ?? "Unknown"
            note("  content \(change.digest.prefix(12))… \(from) → \(words)")
        }
        if changes.count > 20 { note("  … and \(changes.count - 20) more") }
        let unchanged = keys.count - changes.count
        note("OUTCOME set role \(words) on \(scope) — \(changes.count) changed, \(unchanged) already \(words). "
             + "History is kept; to undo, set the old role again.")
        return .set(changed: changes.count, unchanged: unchanged)
    }

    nonisolated static func isAlready(_ role: ProvenanceRole, _ flag: Bool, _ row: CatalogRow.ProvenanceRoleReading?) -> Bool {
        guard let row else { return role == .unknown }       // no row is Unknown already
        guard let known = row.known else { return false }   // an unreadable row is replaced by a readable one
        return known == role && row.sourceNotInCatalog == flag
    }

    private func refuse(_ why: String, _ words: String, _ scope: String) -> SetOutcome {
        note("REFUSED set role \(words) on \(scope) — \(why). Nothing was written.")
        return .refused(why)
    }

    private func sayUnreadable(_ row: CatalogRow.ProvenanceRoleReading) {
        guard saidUnreadable.insert(row.roleID).inserted else { return }
        note(ProvenanceRoleWords.unreadableNote(row))
    }
}
