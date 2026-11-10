// ProvenanceEstimateStore.swift — machine-ESTIMATED provenance: the ONE
// engine for Estimate Provenance…, Confirm Provenance and Provenance Not
// Right. Ruling: DECISIONS 2026-11-10 ("shown as PROVISIONAL … Rick may
// confirm a reviewed list in one action"); design docs/design/provenance.md
// §C2; the rule and the words are Core's ProvenanceResolver (pure).
//
// One sentence: a rule reads what the catalog already holds about each
// archived video, records what it takes the file to be as INFERRED rows with
// their evidence, and shows that as an estimate until Rick confirms it — or
// says it is not right, after which the rule never proposes it again.
//
// Shape: a feature store behind a seam (rule 12, #337) — the model holds ONE
// (`VideoScanModel.provenanceEstimates`, like `publicMarks`); nothing here
// extends the model. Three verbs, each one code path (rule 4):
//            A content the rule examined and no longer proposes, whose
//            earlier estimate still stands, gets a WITHDRAWAL row (inferred
//            role `unknown`, with why) — the table is append-only, so taking
//            an estimate back is a row too.
//   run      the Estimate job's engine. Facts are projected from the records
//            once (main actor), resolved OFF the main actor, and landed in
//            chunks through the committer's side-table door
//            (`commitSideTables(via: .provenanceEstimates)`) by Core's one
//            assertions door. Idempotent: a standing identical row is
//            offered with its own time, so the door answers `.duplicate`; a
//            value Rick rejected is offered afresh, so the table's veto
//            trigger answers and the run REPORTS it (never retried).
//   confirm  Rick's action only. For each selected content with a
//            provisional estimate: `confirmed` rows by 'rick' for role,
//            carrier and capture setup AND the role itself, in ONE
//            transaction per content — through ProvenanceRoleStore.set (the
//            one writer of `provenance_roles`), which carries this store's
//            rows `alongside`. A compare-and-swap: the caller hands in each
//            estimate exactly as it was SHOWN, and inside the transaction
//            role, carrier and setup are compared with what the table holds;
//            a difference refuses that content ("the estimate changed — look
//            again") and corrects what is shown. All or nothing per content;
//            a content with no provisional estimate is skipped and counted.
//   reject   Rick's "Not Right": one `rejected` row by 'rick' for the
//            estimated role value.
// No name and no date is ever written (rule 3: archived means fixed) — the
// three fields are `role`, `carrier`, `captureSetup`; the capture month is
// READ at display time from the record's embedded creation date and the tape
// year from the year folder the archive filed the copy under.
//
// Truth: catalog.sqlite is the truth; `byDigest` is a read-only projection
// (what ProvenanceResolver.estimate says of each content's rows), loaded when
// catalog.sqlite becomes the authority and corrected from each transaction's
// own read-back. It is DISPLAY ONLY (the tape glyph, the menu's counts):
// every verb decides inside its transaction, from the table. "Confirmed" is
// shown only when Rick's confirmed rows are stored; an unattached or unloaded
// store shows nothing.
//
// Memory: one ProvenanceEstimate (~250 B with its strings) per content that
// HAS an estimate — bounded by the content count; worst case 100k ≈ 25 MB,
// today tens. A run holds one ProvenanceFact (~400 B) per archived video and
// one proposal (~600 B) per classified content while it runs, then frees them.
//
// (For Rick: a write-through cache in front of an append-only event table —
// std::unordered_map<digest, estimate> rebuilt from SQL; the three mutators
// are blocking calls into the one writer thread.)

import Combine
import Foundation
import VideoScanCore

/// The words (pure; tests read them).
enum ProvenanceEstimateWords {
    static let estimateTitle = "Estimate Provenance…"
    static let jobTitle = "Estimate Provenance"
    static let estimateHelp = "Read what the catalog already knows about each archived video and mark the ones that look like "
        + "capture masters of a tape as ESTIMATED. Nothing is confirmed, no name or date changes, and no media is read. "
        + "You confirm or reject each estimate yourself."
    static let confirmTitle = "Confirm Provenance"
    static func confirmTitle(_ count: Int) -> String { count > 1 ? "Confirm Provenance for \(count)" : confirmTitle }
    static let notRightTitle = "Provenance Not Right"
    static let confirmHelp = "Record that the estimated provenance is right: the role, the carrier and the capture setup become yours. "
        + "Every byte-identical copy shares it."
    static let notRightHelp = "Record that this estimate is wrong. It disappears and is never proposed again."
    static let nothingToConfirmHelp = "Nothing selected has an estimated provenance waiting for you."
    static let notRightNeedsOneHelp = "Select one file with an estimated provenance."
    static func writeRefusalHelp(_ why: String) -> String { "Provenance cannot be changed now: \(why)." }
    static let refusedTitle = "The provenance was not changed"
    static let glyphLabelEstimated = "Estimated capture master"
    static let glyphLabelConfirmed = "Capture master, confirmed"

    /// "Master · VHS · ClearClick into OBS" — the log's words for one estimate.
    static func summary(_ estimate: ProvenanceEstimate) -> String {
        var parts = [estimate.role.title]
        if let carrier = estimate.carrier { parts.append(carrier) }
        if let id = estimate.captureSetupID { parts.append(CaptureSetup.known(id)?.using ?? id) }
        return parts.joined(separator: " · ")
    }
}

/// The catalog side of the store: reads through the repository, writes
/// through the session's committer (the one door). Mirrors
/// PublicMarkCatalogBacking.
@MainActor
final class ProvenanceEstimateCatalogBacking {

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
            return committer.commitSideTables(what, via: .provenanceEstimates, body)
        })
    }

    func write(_ what: String, _ body: (any CatalogTransaction) throws -> Void) -> String? { commit(what, body) }
}

/// The door answered something a well-formed row never gets: the chunk rolls back.
private struct ProvenanceRowNotLanded: Error, CustomStringConvertible {
    let digest: String
    let field: String
    let landing: CatalogRow.ProvenanceAssertionLanding
    var description: String {
        "the catalog would not take \(field) for content \(digest.prefix(12))… (\(landing))"
    }
}

/// The table no longer says what the menu showed: nothing is written.
private struct ProvenanceEstimateChanged: Error, CustomStringConvertible {
    let digest: String
    var description: String {
        "the estimate changed for content \(digest.prefix(12))… — look again, then confirm"
    }
}

@MainActor
final class ProvenanceEstimateStore: ObservableObject {

    /// What one Estimate run did. Contents, not rows.
    struct Tally: Equatable {
        /// Archived videos whose facts were read.
        var examined = 0
        /// Contents that got new estimate rows.
        var estimated = 0
        /// Contents whose standing estimate already says the same.
        var already = 0
        /// Contents whose role Rick rejected: the trigger ignored it.
        var vetoed = 0
        /// Qualifying captures clearly shorter than a NAME-RELATED capture in their folder (maybe a trim) — not classified.
        var shorter = 0
        /// Contents catalog.sqlite does not hold yet (their row is still being saved).
        var notStored = 0
        /// Files some clause of the rule failed for.
        var notQualifying = 0
        /// Byte-identical files of a qualifying content beyond the first.
        var byteCopies = 0
        /// Earlier estimates the rule no longer makes, taken back this run.
        /// (They are among `shorter` / `notQualifying`, not a count of their own.)
        var withdrawn = 0

        /// Every examined file is in exactly one of these: a finished run's sum is `examined`.
        var accounted: Int { estimated + already + vetoed + shorter + notStored + notQualifying + byteCopies }
    }

    enum RunOutcome: Equatable {
        case finished(Tally)
        case stopped(Tally)
        case refused(String)
    }

    enum ConfirmOutcome: Equatable {
        /// `skipped`: selected contents with no provisional estimate to confirm.
        case confirmed(contents: Int, skipped: Int)
        case refused(String)
    }

    enum RejectOutcome: Equatable {
        case rejected(ProvenanceRole)
        /// No provisional estimate stands for it (by the table).
        case nothingToReject
        case refused(String)
    }

    /// Contents landed per transaction: the main actor is held for one chunk
    /// (≈ 8 statements per content), then yields.
    nonisolated static let chunkSize = 100

    /// Bumped after every load and every commit — what the tape glyph observes.
    @Published private(set) var revision = 0
    /// DISPLAY ONLY: what stands per content, by `content.digest`.
    private(set) var byDigest: [String: ProvenanceEstimate] = [:]
    private(set) var backing: ProvenanceEstimateCatalogBacking?
    /// The one writer of `provenance_roles` (Confirm goes through it).
    private(set) weak var roles: ProvenanceRoleStore?
    /// Archived records' facts, projected on the main actor when a run starts.
    private var facts: () -> [ProvenanceFact] = { [] }
    /// The file name the ARCHIVE has for a content (what Rick sees in the
    /// Archive tab), by digest — O(1); nil when the archive holds none.
    private var archiveName: (String) -> String? = { _ in nil }
    /// The one log sink (the model's console + catalog.log + videoscan.log).
    var note: (String) -> Void = { _ in }
    /// Bumped by every commit and every `attach`; a load snapshot is stamped
    /// with it when its read starts, and discarded if it moved.
    private(set) var commitEpoch = 0

    // MARK: Attach / load

    func attach(_ backing: ProvenanceEstimateCatalogBacking, roles: ProvenanceRoleStore, facts: @escaping () -> [ProvenanceFact],
                archiveName: @escaping (String) -> String? = { _ in nil }) {
        self.backing = backing
        self.roles = roles
        self.facts = facts
        self.archiveName = archiveName
        byDigest = [:]
        commitEpoch &+= 1          // a load begun on the old backing is stale
        revision &+= 1
    }

    /// Read what stands for every content off the main actor (one streamed
    /// query, one subject's rows in flight) and replace the projection.
    /// nil = read; else the words (the projection is left as it was).
    @discardableResult
    func load() async -> String? {
        do {
            for _ in 0..<3 {
                guard let backing else { return "the catalog is not open" }
                let epoch = commitEpoch
                let found = try await backing.repository.read { reader -> [String: ProvenanceEstimate] in
                    var out: [String: ProvenanceEstimate] = [:]
                    try reader.forEachProvenanceAssertionSubject(subjectKind: ProvenanceAssertionSubject.content,
                                                                 fields: ProvenanceEstimateRule.fields) { subject, rows in
                        if let estimate = ProvenanceResolver.estimate(fromRowsOfOneSubject: rows) { out[subject] = estimate }
                    }
                    return out
                }
                if apply(found, takenAt: epoch) { return nil }
            }
            note("provenance estimates were changing while they were read — the glyph follows each change as it commits")
            return nil
        } catch {
            let words = String(describing: error)
            note("provenance estimates could not be read from catalog.sqlite (\(words)) — none is shown")
            return words
        }
    }

    /// Replace the projection with a whole-table snapshot taken at `epoch`.
    /// false — and nothing changes — when a commit or an attach happened
    /// after the snapshot's read began.
    @discardableResult
    func apply(_ estimates: [String: ProvenanceEstimate], takenAt epoch: Int) -> Bool {
        guard epoch == commitEpoch else { return false }
        byDigest = estimates
        revision &+= 1
        return true
    }

    // MARK: Reading (display; O(1))

    /// What the projection holds for `digest`; nil digest or no estimate = nil.
    func estimate(of digest: String?) -> ProvenanceEstimate? {
        guard let digest else { return nil }
        return byDigest[digest.lowercased()]
    }

    /// What may be SHOWN for `digest`: the estimate, unless Rick's own role
    /// (Provenance ▸ Set Role) says something else — his typed value wins
    /// (ProvenanceResolver.visible, the one rule every surface uses).
    func shown(of digest: String?, roles: ProvenanceRoleStore?) -> ProvenanceEstimate? {
        guard let digest, let estimate = estimate(of: digest) else { return nil }
        return ProvenanceResolver.visible(estimate, rickRole: roles?.role(of: digest) ?? .unknown)
    }

    /// How many of `digests` show a provisional (unconfirmed) estimate.
    func provisionalCount(in digests: Set<String>, roles: ProvenanceRoleStore?) -> Int {
        digests.reduce(0) { $0 + ((shown(of: $1, roles: roles).map { !$0.isConfirmed } ?? false) ? 1 : 0) }
    }

    /// The name an ALTERNATE capture may point at: its master's file name in
    /// the archive — only while that master's own estimate still stands as a
    /// master (not rejected by Rick, not overruled by his Set Role). nil
    /// drops the pointer; the original file name is never substituted.
    func masterName(of estimate: ProvenanceEstimate, roles: ProvenanceRoleStore?) -> String? {
        guard estimate.role == .alternateCapture, let master = estimate.masterDigest,
              shown(of: master, roles: roles)?.role == .master else { return nil }
        return archiveName(master.lowercased())
    }

    /// The File Journey's event for `record`; nil when nothing is shown.
    func journey(for record: VideoRecord, roles: ProvenanceRoleStore?) -> JourneyProvenance? {
        guard let estimate = shown(of: CatalogCommit.digest(of: record), roles: roles),
              let sentence = ProvenanceResolver.shortLine(estimate, captured: record.embeddedCreationDate,
                                                          masterName: masterName(of: estimate, roles: roles)) else { return nil }
        return JourneyProvenance(sentence: sentence, captured: record.embeddedCreationDate)
    }

    /// What catalog.sqlite holds for one content NOW (the Inspector's truth).
    /// Every case names the content it was read for.
    enum CurrentReading: Equatable {
        case none(digest: String)
        case estimate(digest: String, ProvenanceEstimate)
        case unavailable(digest: String, why: String)

        var digest: String {
            switch self {
            case .none(let digest), .estimate(let digest, _), .unavailable(let digest, _): return digest
            }
        }
    }

    /// One index probe, off the main actor.
    func readCurrent(digest: String) async -> CurrentReading {
        let key = digest.lowercased()
        guard let backing else { return .unavailable(digest: key, why: "the catalog is not open") }
        do {
            let rows = try await backing.repository.read {
                try $0.provenanceAssertions(subjectKind: ProvenanceAssertionSubject.content, subjectID: key)
            }
            guard let estimate = ProvenanceResolver.estimate(fromRowsOfOneSubject: rows) else { return .none(digest: key) }
            return .estimate(digest: key, estimate)
        } catch {
            return .unavailable(digest: key, why: String(describing: error))
        }
    }

    /// Why a write would be refused now; nil = it would be taken.
    var writeRefusal: String? {
        guard let backing else { return "the catalog is not open for writing in this session" }
        return backing.writeRefusal()
    }

    // MARK: Facts (pure)

    /// The facts of the archived videos among `records` (O(records), once per
    /// run, never in a view body). A record with no whole-file SHA-256 or no
    /// original path has nothing the rule can read and is left out.
    static func facts(records: [VideoRecord], isArchived: (VideoRecord) -> Bool) -> [ProvenanceFact] {
        var out: [ProvenanceFact] = []
        for record in records {
            guard record.streamTypeRaw.hasPrefix("Video"), isArchived(record),
                  let digest = CatalogCommit.digest(of: record), let original = record.originalFullPath else { continue }
            out.append(ProvenanceFact(digest: digest, originalPath: original, filename: record.filename, container: record.container,
                                      videoCodec: record.videoCodec,
                                      durationSeconds: record.durationSeconds, embeddedCreatedAt: record.embeddedCreationDate,
                                      resolution: record.resolution, bitDepth: record.bitDepth, frameRate: record.frameRate,
                                      originEncoder: record.originEncoder))
        }
        return out
    }

    // MARK: Verb 1 — Estimate (the job's engine)

    static func startLine(examined: Int) -> String {
        "START estimate provenance — \(examined) archived video\(examined == 1 ? "" : "s") to examine (rule \(ProvenanceEstimateRule.ruleName), \(ProvenanceEstimateRule.signer))"
    }

    /// "12 archived videos examined, 3 estimated, 0 already estimated, 1 vetoed" + every other
    /// non-zero count, so the numbers after "examined" add up to it; then the withdrawals.
    static func summary(_ t: Tally) -> String {
        var text = "\(t.examined) archived video\(t.examined == 1 ? "" : "s") examined, \(t.estimated) estimated, "
            + "\(t.already) already estimated, \(t.vetoed) vetoed"
        if t.shorter > 0 { text += ", \(t.shorter) left unclassified (shorter than a capture of the same name in its folder)" }
        if t.notQualifying > 0 { text += ", \(t.notQualifying) not a capture this rule knows" }
        if t.byteCopies > 0 { text += ", \(t.byteCopies) byte cop\(t.byteCopies == 1 ? "y" : "ies") of those" }
        if t.notStored > 0 { text += ", \(t.notStored) not in catalog.sqlite yet (run again)" }
        if t.withdrawn > 0 { text += "; \(t.withdrawn) earlier estimate\(t.withdrawn == 1 ? "" : "s") withdrawn" }
        return text
    }

    /// Run the rule over the archived videos and land what it proposes.
    /// `checkpoint` is awaited between chunks (it waits out a pause) and
    /// returns true to stop; `progress` hears (contents done, contents to do).
    func run(now: Date = Date(), checkpoint: () async -> Bool = { false },
             progress: (Int, Int) -> Void = { _, _ in }) async -> RunOutcome {
        guard let backing else { return refuseRun("the catalog is not open for writing in this session") }
        if let why = backing.writeRefusal() { return refuseRun(why) }
        let facts = self.facts()
        note(Self.startLine(examined: facts.count))
        let resolved = await Task.detached(priority: .userInitiated) { ProvenanceResolver.resolve(facts) }.value
        var tally = Tally(examined: resolved.examined, shorter: resolved.shorterUnclassified,
                          notQualifying: resolved.notQualifying, byteCopies: resolved.byteCopies)
        // Estimates to take back: contents this run EXAMINED and does not
        // propose, whose rule-signed role still stands in the table. (A
        // content the run did not examine is left alone — refuse rather than
        // guess.) Read before anything is written; decided again in the transaction.
        let withdrawals: [(digest: String, why: String)]
        do {
            withdrawals = try await Self.withdrawals(resolved: resolved, facts: facts, repository: backing.repository)
        } catch {
            return refuseRun("the standing estimates could not be read (\(error))")
        }
        let seconds = Int64(now.timeIntervalSince1970.rounded(.down))
        let total = resolved.proposals.count + withdrawals.count
        var done = 0
        var said = 0
        progress(0, total)
        while done < total {
            if await checkpoint() {
                note("OUTCOME estimate provenance — stopped at \(done) of \(total): " + Self.summary(tally))
                return .stopped(tally)
            }
            let propose = Array(resolved.proposals.dropFirst(done).prefix(Self.chunkSize))
            let withdraw = propose.isEmpty
                ? Array(withdrawals.dropFirst(done - resolved.proposals.count).prefix(Self.chunkSize)) : []
            var landed: [Landed] = []
            let refusal = backing.write("estimate provenance: \(propose.count) content(s), \(withdraw.count) withdrawn") { tx in
                landed = try propose.map { try Self.land($0, at: seconds, in: tx) }
                    + withdraw.map { try Self.landWithdrawal($0.digest, why: $0.why, at: seconds, in: tx) }
            }
            if let refusal {
                note("REFUSED estimate provenance — \(refusal). \(Self.summary(tally)) before that; this chunk was not written.")
                return .refused(refusal)
            }
            adopt(landed, into: &tally, said: &said)
            done += propose.count + withdraw.count
            progress(done, total)
            await Task.yield()
        }
        if tally.estimated > 20 { note("  … and \(tally.estimated - 20) more estimated") }
        note("OUTCOME estimate provenance — " + Self.summary(tally) + ". Estimates are provisional until you confirm them.")
        return .finished(tally)
    }

    /// After a chunk committed: the projection follows each content's
    /// read-back, the tally counts it, the log names it.
    private func adopt(_ landed: [Landed], into tally: inout Tally, said: inout Int) {
        for item in landed {
            if let estimate = item.after { byDigest[item.digest] = estimate } else { byDigest.removeValue(forKey: item.digest) }
            switch item.kind {
            case .estimated:
                tally.estimated += 1
                if said < 20, let estimate = item.after {
                    note("  content \(item.digest.prefix(12))… \(item.before.map(ProvenanceEstimateWords.summary) ?? "no estimate") → estimated \(ProvenanceEstimateWords.summary(estimate))")
                    said += 1
                }
            case .already: tally.already += 1
            case .vetoed:
                tally.vetoed += 1
                note("  content \(item.digest.prefix(12))… VETOED — you rejected \(item.proposedRole.title) for it; not written, not proposed again")
            case .notStored: tally.notStored += 1
            case .withdrawn:
                tally.withdrawn += 1
                note("  content \(item.digest.prefix(12))… estimated \(item.proposedRole.title) → WITHDRAWN — \(item.why)")
            case .nothingToWithdraw: break
            }
        }
        commitEpoch &+= 1
        revision &+= 1
    }

    nonisolated static let withdrawnShorterWhy = "it is now clearly shorter than a capture of the same name in its folder — it may be a trim"
    nonisolated static let withdrawnNotQualifyingWhy = "the rule's clauses no longer hold for it"

    /// The contents whose standing rule-signed role this run takes back, with
    /// why: one streamed read of the role rows (a subject's rows in flight),
    /// off the main actor.
    nonisolated static func withdrawals(resolved: ProvenanceResolver.Resolution, facts: [ProvenanceFact],
                                        repository: any CatalogRepository) async throws -> [(digest: String, why: String)] {
        let live = try await repository.read { reader -> [String] in
            var out: [String] = []
            try reader.forEachProvenanceAssertionSubject(subjectKind: ProvenanceAssertionSubject.content,
                                                         fields: [ProvenanceEstimateRule.roleField]) { subject, rows in
                if ProvenanceResolver.withdrawable(rows) != nil { out.append(subject) }
            }
            return out
        }
        guard !live.isEmpty else { return [] }
        let examined = Set(facts.compactMap { ProvenanceAssertionSubject.contentID($0.digest) })
        let proposed = Set(resolved.proposals.map(\.digest))
        let shorter = Set(resolved.shorterDigests)
        return live.filter { examined.contains($0) && !proposed.contains($0) }.sorted().map {
            ($0, shorter.contains($0) ? withdrawnShorterWhy : withdrawnNotQualifyingWhy)
        }
    }

    private func refuseRun(_ why: String) -> RunOutcome {
        note("REFUSED estimate provenance — \(why). Nothing was written.")
        return .refused(why)
    }

    /// What landing one proposal did, with the content's read-back.
    struct Landed {
        enum Kind: Equatable { case estimated, already, vetoed, notStored, withdrawn, nothingToWithdraw }
        var digest: String
        var kind: Kind
        /// The role proposed — or, for a withdrawal, the role taken back.
        var proposedRole: ProvenanceRole
        var before: ProvenanceEstimate?
        var after: ProvenanceEstimate?
        var why = ""
    }

    /// One withdrawal, inside the transaction: the table must STILL hold the
    /// rule's live role for the content; then one inferred `role` = `unknown`
    /// row. A second run finds that row newest and writes nothing.
    nonisolated static func landWithdrawal(_ digest: String, why: String, at seconds: Int64, in tx: any CatalogTransaction) throws -> Landed {
        let kind = ProvenanceAssertionSubject.content
        let rows = try tx.provenanceAssertions(subjectKind: kind, subjectID: digest)
        let before = ProvenanceResolver.estimate(fromRowsOfOneSubject: rows)
        guard let role = ProvenanceResolver.withdrawable(rows) else {
            return Landed(digest: digest, kind: .nothingToWithdraw, proposedRole: .unknown, before: before, after: before)
        }
        let draft = ProvenanceProposal.withdrawal(digest: digest, why: why, at: seconds)
        let landing = try tx.appendProvenanceAssertion(draft)
        guard case .recorded = landing else { throw ProvenanceRowNotLanded(digest: digest, field: draft.field, landing: landing) }
        let after = ProvenanceResolver.estimate(fromRowsOfOneSubject: try tx.provenanceAssertions(subjectKind: kind, subjectID: digest))
        return Landed(digest: digest, kind: .withdrawn, proposedRole: role, before: before, after: after, why: why)
    }

    /// One content, inside the transaction: its rows, its drafts through the
    /// door, its rows again. With `landWithdrawal`, the ONLY places an
    /// inferred row is appended by the app.
    nonisolated static func land(_ proposal: ProvenanceProposal, at seconds: Int64, in tx: any CatalogTransaction) throws -> Landed {
        let kind = ProvenanceAssertionSubject.content
        let rows = try tx.provenanceAssertions(subjectKind: kind, subjectID: proposal.digest)
        let before = ProvenanceResolver.estimate(fromRowsOfOneSubject: rows)
        var recorded = 0
        var roleVetoed = false
        for var draft in proposal.drafts(at: seconds) {
            // A standing identical row keeps its own time → `.duplicate`.
            if let standing = ProvenanceResolver.standingAt(of: draft, among: rows) { draft.at = standing }
            let landing = try tx.appendProvenanceAssertion(draft)
            switch landing {
            case .recorded: recorded += 1
            case .duplicate: break
            case .vetoed: if draft.field == ProvenanceEstimateRule.roleField { roleVetoed = true }
            case .contentMissing:
                return Landed(digest: proposal.digest, kind: .notStored, proposedRole: proposal.role, before: nil, after: nil)
            case .archivedNameOrDate, .storeRefused:
                throw ProvenanceRowNotLanded(digest: proposal.digest, field: draft.field, landing: landing)
            }
        }
        let after = ProvenanceResolver.estimate(fromRowsOfOneSubject: try tx.provenanceAssertions(subjectKind: kind, subjectID: proposal.digest))
        let what: Landed.Kind = roleVetoed ? .vetoed : (recorded > 0 ? .estimated : .already)
        return Landed(digest: proposal.digest, kind: what, proposedRole: proposal.role, before: before, after: after)
    }

    // MARK: Verb 2 — Confirm (Rick's action only)

    /// Rick's decision row for one field of one content.
    nonisolated static func decision(_ state: String, digest: String, field: String, value: String, at seconds: Int64,
                                     via: String) -> CatalogRow.ProvenanceAssertionDraft {
        // Sorted keys by hand (two fixed members): the same click gives the same bytes.
        let evidence = "{\"of\":\"\(ProvenanceEstimateRule.signer)\",\"via\":\"\(via)\"}"
        return CatalogRow.ProvenanceAssertionDraft(subjectKind: ProvenanceAssertionSubject.content, subjectID: digest, field: field,
                                                   value: value, state: state, by: ProvenanceEstimateRule.owner, at: seconds,
                                                   confidence: nil, evidenceJSON: evidence)
    }

    /// What stands for `digest` in the table as a SURFACE would show it:
    /// the one visibility rule, with Rick's current role row read in the
    /// same transaction.
    nonisolated static func visibleStanding(_ digest: String, in tx: any CatalogTransaction) throws
        -> (table: ProvenanceEstimate?, visible: ProvenanceEstimate?) {
        let rows = try tx.provenanceAssertions(subjectKind: ProvenanceAssertionSubject.content, subjectID: digest)
        guard let table = ProvenanceResolver.estimate(fromRowsOfOneSubject: rows) else { return (nil, nil) }
        let rick = try tx.currentProvenanceRoles(digests: [digest])[digest]?.role ?? .unknown
        return (table, ProvenanceResolver.visible(table, rickRole: rick))
    }

    /// The provisional estimates `digests` SHOW right now (the menu builds
    /// this when it opens; Confirm then writes exactly these or nothing).
    func shownProvisional(in digests: Set<String>, roles: ProvenanceRoleStore?) -> [String: ProvenanceEstimate] {
        var out: [String: ProvenanceEstimate] = [:]
        for digest in digests {
            if let estimate = shown(of: digest, roles: roles), !estimate.isConfirmed { out[digest.lowercased()] = estimate }
        }
        return out
    }

    /// Confirm the provisional estimate of every content in `digests` that
    /// shows one NOW. `files` = how many selected rows that is (the log's words).
    func confirm(digests: Set<String>, files: Int? = nil, now: Date = Date()) -> ConfirmOutcome {
        confirm(shown: shownProvisional(in: digests, roles: roles), selected: digests.count, files: files, now: now)
    }

    /// Confirm exactly what was SHOWN: `shown` maps each content to the
    /// estimate as displayed when Rick chose Confirm. One transaction per
    /// content (rows + role, all or nothing); inside it the table's role,
    /// carrier and capture setup must equal what was shown, else that content
    /// is refused, nothing of it is written, and what is shown is corrected
    /// from the table. `selected` = how many contents were selected (the
    /// rest are counted as skipped).
    func confirm(shown: [String: ProvenanceEstimate], selected: Int, files: Int? = nil, now: Date = Date()) -> ConfirmOutcome {
        let scope = "\(selected) content\(selected == 1 ? "" : "s")" + (files.map { " (\($0) file\($0 == 1 ? "" : "s"))" } ?? "")
        guard selected > 0 else { return .refused("nothing selected has a full SHA-256") }
        note("START confirm provenance: \(scope)")
        guard backing != nil, let roles else { return refuseConfirm("the catalog is not open for writing in this session", scope) }
        if let why = writeRefusal ?? roles.writeRefusal { return refuseConfirm(why, scope) }
        let seconds = Int64(now.timeIntervalSince1970.rounded(.down))
        let skipped = max(0, selected - shown.count)
        var confirmed = 0
        var changed: [String] = []
        for (digest, estimate) in shown.sorted(by: { $0.key < $1.key }) where !estimate.isConfirmed {
            // Rick's own "source not in the catalog" flag on a Master is kept as he set it.
            let flag = roles.byDigest[digest]?.sourceNotInCatalog ?? false
            let fields = Self.confirmedFields(estimate).map(\.field).joined(separator: ", ")
            var table: ProvenanceEstimate?
            var wasRead = false
            var after: ProvenanceEstimate?
            let outcome = roles.set(estimate.role, digests: [digest], sourceMissing: flag, now: now,
                                    alongsideWhat: "with Rick's confirmed \(fields) rows (Confirm Provenance)") { tx in
                wasRead = false
                let standing = try Self.visibleStanding(digest, in: tx)
                table = standing.table
                wasRead = true
                after = try Self.confirmRows(digest, shown: estimate, visible: standing.visible, at: seconds, in: tx)
            }
            if case .refused(let why) = outcome {
                guard wasRead else {
                    // The session refused before the table was read (a hold, a viewer, a blocked store): the same for every content.
                    note("REFUSED confirm provenance: \(scope) — \(why). \(confirmed) confirmed before that; nothing else was written.")
                    return .refused(confirmed == 0 ? why : "\(confirmed) confirmed, then: \(why)")
                }
                // Nothing of this content was written. What is SHOWN is corrected from the table's own rows.
                if let table { byDigest[digest] = table } else { byDigest.removeValue(forKey: digest) }
                commitEpoch &+= 1
                revision &+= 1
                changed.append(digest)
                note("  content \(digest.prefix(12))… NOT confirmed — \(why). Nothing of it was written; what is shown now is what the catalog holds.")
                continue
            }
            if let after { byDigest[digest] = after } else { byDigest.removeValue(forKey: digest) }
            confirmed += 1
            commitEpoch &+= 1
            revision &+= 1
            note("  content \(digest.prefix(12))… estimated → confirmed by Rick: \(ProvenanceEstimateWords.summary(estimate)) "
                 + "(confirmed rows: \(fields); role set through Set Role)")
        }
        guard changed.isEmpty else {
            let words = "the estimate changed for \(changed.count) content\(changed.count == 1 ? "" : "s") — look again, then confirm"
                + (confirmed > 0 ? " (\(confirmed) confirmed)" : "")
            note("REFUSED confirm provenance: \(scope) — \(words).")
            return .refused(words)
        }
        note("OUTCOME confirm provenance: \(scope) — \(confirmed) confirmed, \(skipped) skipped (no estimate waiting). "
             + "History is kept; to change a role later use Provenance ▸ Set Role.")
        return .confirmed(contents: confirmed, skipped: skipped)
    }

    /// The fields Confirm writes for an estimate, with their values.
    nonisolated static func confirmedFields(_ estimate: ProvenanceEstimate) -> [(field: String, value: String)] {
        var out = [(ProvenanceEstimateRule.roleField, estimate.role.rawValue)]
        if let carrier = estimate.carrier { out.append((ProvenanceEstimateRule.carrierField, carrier)) }
        if let setup = estimate.captureSetupID { out.append((ProvenanceEstimateRule.captureSetupField, setup)) }
        return out.map { (field: $0.0, value: $0.1) }
    }

    /// Inside Set Role's transaction — the compare-and-swap: what the table
    /// would show (`visible`) must be a PROVISIONAL estimate with the same
    /// role, carrier and capture setup as `shown`; then Rick's `confirmed`
    /// row for each. Returns the content's read-back.
    nonisolated static func confirmRows(_ digest: String, shown: ProvenanceEstimate, visible: ProvenanceEstimate?, at seconds: Int64,
                                        in tx: any CatalogTransaction) throws -> ProvenanceEstimate? {
        guard let visible, !visible.isConfirmed, visible.role == shown.role, visible.carrier == shown.carrier,
              visible.captureSetupID == shown.captureSetupID else { throw ProvenanceEstimateChanged(digest: digest) }
        for (field, value) in confirmedFields(shown) {
            let landing = try tx.appendProvenanceAssertion(decision("confirmed", digest: digest, field: field, value: value,
                                                                    at: seconds, via: ProvenanceEstimateWords.confirmTitle))
            switch landing {
            case .recorded, .duplicate: break
            default: throw ProvenanceRowNotLanded(digest: digest, field: field, landing: landing)
            }
        }
        return ProvenanceResolver.estimate(fromRowsOfOneSubject: try tx.provenanceAssertions(subjectKind: ProvenanceAssertionSubject.content,
                                                                                               subjectID: digest))
    }

    private func refuseConfirm(_ why: String, _ scope: String) -> ConfirmOutcome {
        note("REFUSED confirm provenance: \(scope) — \(why). Nothing was written.")
        return .refused(why)
    }

    // MARK: Verb 3 — Not Right (Rick's action only)

    /// Reject the provisional estimate of ONE content: a `rejected` row by
    /// 'rick' for the estimated role value. The rule's re-proposal is then
    /// ignored by the table's veto trigger, for good.
    func reject(digest: String, now: Date = Date()) -> RejectOutcome {
        let key = digest.lowercased()
        note("START provenance not right: content \(key.prefix(12))…")
        guard let backing else { return refuseReject("the catalog is not open for writing in this session", key) }
        if let why = backing.writeRefusal() { return refuseReject(why, key) }
        let seconds = Int64(now.timeIntervalSince1970.rounded(.down))
        var rejected: ProvenanceEstimate?
        var after: ProvenanceEstimate?
        let refusal = backing.write("provenance not right: content \(key.prefix(12))…") { tx in
            rejected = nil
            let kind = ProvenanceAssertionSubject.content
            let seen = try Self.visibleStanding(key, in: tx)
            after = seen.table
            guard let standing = seen.visible, !standing.isConfirmed else { return }
            let draft = Self.decision("rejected", digest: key, field: ProvenanceEstimateRule.roleField, value: standing.role.rawValue,
                                      at: seconds, via: ProvenanceEstimateWords.notRightTitle)
            let landing = try tx.appendProvenanceAssertion(draft)
            switch landing {
            case .recorded, .duplicate: break
            default: throw ProvenanceRowNotLanded(digest: key, field: draft.field, landing: landing)
            }
            rejected = standing
            after = ProvenanceResolver.estimate(fromRowsOfOneSubject: try tx.provenanceAssertions(subjectKind: kind, subjectID: key))
        }
        if let refusal { return refuseReject(refusal, key) }
        if let after { byDigest[key] = after } else { byDigest.removeValue(forKey: key) }
        commitEpoch &+= 1
        revision &+= 1
        guard let rejected else {
            note("OUTCOME provenance not right: content \(key.prefix(12))… — no estimate is waiting for it; nothing was written.")
            return .nothingToReject
        }
        note("  content \(key.prefix(12))… estimated \(ProvenanceEstimateWords.summary(rejected)) → rejected by Rick")
        note("OUTCOME provenance not right: content \(key.prefix(12))… — \(rejected.role.title) rejected; it will not be proposed again.")
        return .rejected(rejected.role)
    }

    private func refuseReject(_ why: String, _ key: String) -> RejectOutcome {
        note("REFUSED provenance not right: content \(key.prefix(12))… — \(why). Nothing was written.")
        return .refused(why)
    }
}
