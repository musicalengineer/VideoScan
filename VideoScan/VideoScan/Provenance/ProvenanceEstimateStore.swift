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
//            transaction — through ProvenanceRoleStore.set (the one writer of
//            `provenance_roles`), which carries this store's rows `alongside`.
//            All or nothing per role group; a content with no provisional
//            estimate is skipped and counted.
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
        "the estimate for content \(digest.prefix(12))… changed while it was being confirmed — look again, then confirm"
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
    /// (Provenance ▸ Set Role) says something else — his typed value wins.
    func shown(of digest: String?, roles: ProvenanceRoleStore?) -> ProvenanceEstimate? {
        guard let digest, let estimate = estimate(of: digest) else { return nil }
        return ProvenanceEstimateMark.visible(estimate, rickRole: roles?.role(of: digest) ?? .unknown)
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
                                      videoCodec: record.videoCodec, audioCodec: record.audioCodec,
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

    /// "12 archived videos examined, 3 estimated, 0 already estimated, 1 vetoed" (+ what was left out).
    static func summary(_ t: Tally) -> String {
        var text = "\(t.examined) archived video\(t.examined == 1 ? "" : "s") examined, \(t.estimated) estimated, "
            + "\(t.already) already estimated, \(t.vetoed) vetoed"
        if t.shorter > 0 { text += ", \(t.shorter) left unclassified (shorter than a capture of the same name in its folder)" }
        if t.notStored > 0 { text += ", \(t.notStored) not in catalog.sqlite yet (run again)" }
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
        var tally = Tally(examined: resolved.examined, shorter: resolved.shorterUnclassified)
        let seconds = Int64(now.timeIntervalSince1970.rounded(.down))
        var done = 0
        var said = 0
        progress(0, resolved.proposals.count)
        while done < resolved.proposals.count {
            if await checkpoint() {
                note("OUTCOME estimate provenance — stopped at \(done) of \(resolved.proposals.count) proposals: " + Self.summary(tally))
                return .stopped(tally)
            }
            let chunk = Array(resolved.proposals[done..<min(done + Self.chunkSize, resolved.proposals.count)])
            var landed: [Landed] = []
            let refusal = backing.write("estimate provenance: \(chunk.count) content(s)") { tx in
                landed = try chunk.map { try Self.land($0, at: seconds, in: tx) }
            }
            if let refusal {
                note("REFUSED estimate provenance — \(refusal). \(Self.summary(tally)) before that; this chunk was not written.")
                return .refused(refusal)
            }
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
                }
            }
            commitEpoch &+= 1
            revision &+= 1
            done += chunk.count
            progress(done, resolved.proposals.count)
            await Task.yield()
        }
        if tally.estimated > 20 { note("  … and \(tally.estimated - 20) more estimated") }
        note("OUTCOME estimate provenance — " + Self.summary(tally) + ". Estimates are provisional until you confirm them.")
        return .finished(tally)
    }

    private func refuseRun(_ why: String) -> RunOutcome {
        note("REFUSED estimate provenance — \(why). Nothing was written.")
        return .refused(why)
    }

    /// What landing one proposal did, with the content's read-back.
    struct Landed {
        enum Kind: Equatable { case estimated, already, vetoed, notStored }
        var digest: String
        var kind: Kind
        var proposedRole: ProvenanceRole
        var before: ProvenanceEstimate?
        var after: ProvenanceEstimate?
    }

    /// One content, inside the transaction: its rows, its three drafts
    /// through the door, its rows again. The ONLY place an inferred row is
    /// appended by the app.
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

    /// Confirm the provisional estimate of every content in `digests` that
    /// shows one. `files` = how many selected rows that is (the log's words).
    func confirm(digests: Set<String>, files: Int? = nil, now: Date = Date()) -> ConfirmOutcome {
        let keys = digests.map { $0.lowercased() }.sorted()
        let scope = "\(keys.count) content\(keys.count == 1 ? "" : "s")" + (files.map { " (\($0) file\($0 == 1 ? "" : "s"))" } ?? "")
        guard !keys.isEmpty else { return .refused("nothing selected has a full SHA-256") }
        note("START confirm provenance: \(scope)")
        guard backing != nil, let roles else { return refuseConfirm("the catalog is not open for writing in this session", scope) }
        if let why = writeRefusal ?? roles.writeRefusal { return refuseConfirm(why, scope) }
        // The PLAN comes from what is shown (the projection); the table
        // decides inside each transaction — a content whose rows no longer
        // say what was shown refuses its group, it is never written on a guess.
        struct Group: Hashable { let role: ProvenanceRole; let sourceMissing: Bool }
        var plan: [Group: [String]] = [:]
        for key in keys {
            guard let estimate = shown(of: key, roles: roles), !estimate.isConfirmed else { continue }
            // Rick's own "source not in the catalog" flag on a Master is kept as he set it.
            let flag = roles.byDigest[key]?.sourceNotInCatalog ?? false
            plan[Group(role: estimate.role, sourceMissing: flag), default: []].append(key)
        }
        let planned = plan.values.reduce(0) { $0 + $1.count }
        let skipped = keys.count - planned
        let seconds = Int64(now.timeIntervalSince1970.rounded(.down))
        var confirmed = 0
        for group in plan.keys.sorted(by: { ($0.role.rawValue, $0.sourceMissing ? 1 : 0) < ($1.role.rawValue, $1.sourceMissing ? 1 : 0) }) {
            let members = plan[group] ?? []
            var readBack: [String: ProvenanceEstimate] = [:]
            let outcome = roles.set(group.role, digests: Set(members), sourceMissing: group.sourceMissing, now: now) { tx in
                readBack = try Self.confirmRows(members, role: group.role, at: seconds, in: tx)
            }
            if case .refused(let why) = outcome {
                let rest = planned - confirmed
                note("REFUSED confirm provenance: \(scope) — \(why). \(confirmed) confirmed before that; \(rest) not confirmed, nothing of theirs was written.")
                // A refusal after an earlier role group committed is still a
                // refusal the caller must show: the words say what did land.
                return .refused(confirmed == 0 ? why : "\(confirmed) of \(planned) confirmed, then: \(why)")
            }
            for digest in members {
                byDigest[digest] = readBack[digest]
                note("  content \(digest.prefix(12))… estimated → confirmed by Rick: "
                     + (readBack[digest].map(ProvenanceEstimateWords.summary) ?? group.role.title))
            }
            confirmed += members.count
            commitEpoch &+= 1
            revision &+= 1
        }
        note("OUTCOME confirm provenance: \(scope) — \(confirmed) confirmed, \(skipped) skipped (no estimate waiting). "
             + "History is kept; to change a role later use Provenance ▸ Set Role.")
        return .confirmed(contents: confirmed, skipped: skipped)
    }

    /// Inside Set Role's transaction: for each content the table must still
    /// hold a PROVISIONAL estimate of `role`; then Rick's `confirmed` row for
    /// every field it shows. Returns each content's read-back.
    nonisolated static func confirmRows(_ digests: [String], role: ProvenanceRole, at seconds: Int64,
                                        in tx: any CatalogTransaction) throws -> [String: ProvenanceEstimate] {
        let kind = ProvenanceAssertionSubject.content
        var out: [String: ProvenanceEstimate] = [:]
        for digest in digests {
            let rows = try tx.provenanceAssertions(subjectKind: kind, subjectID: digest)
            guard let standing = ProvenanceResolver.estimate(fromRowsOfOneSubject: rows), !standing.isConfirmed,
                  standing.role == role else { throw ProvenanceEstimateChanged(digest: digest) }
            let values: [(String, String?)] = [(ProvenanceEstimateRule.roleField, standing.role.rawValue),
                                               (ProvenanceEstimateRule.carrierField, standing.carrier),
                                               (ProvenanceEstimateRule.captureSetupField, standing.captureSetupID)]
            for (field, value) in values {
                guard let value else { continue }
                let landing = try tx.appendProvenanceAssertion(decision("confirmed", digest: digest, field: field, value: value,
                                                                        at: seconds, via: ProvenanceEstimateWords.confirmTitle))
                switch landing {
                case .recorded, .duplicate: break
                default: throw ProvenanceRowNotLanded(digest: digest, field: field, landing: landing)
                }
            }
            out[digest] = ProvenanceResolver.estimate(fromRowsOfOneSubject: try tx.provenanceAssertions(subjectKind: kind, subjectID: digest))
        }
        return out
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
            let rows = try tx.provenanceAssertions(subjectKind: kind, subjectID: key)
            after = ProvenanceResolver.estimate(fromRowsOfOneSubject: rows)
            guard let standing = after, !standing.isConfirmed else { return }
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
