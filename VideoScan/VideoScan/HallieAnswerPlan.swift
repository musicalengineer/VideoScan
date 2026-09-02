// HallieAnswerPlan.swift
// The typed boundary between "what Hallie is allowed to say" and "how she
// says it" (docs/hallie_grounded_composition.md, docs/cyberbrain_design.md §9).
//
// Every deterministic route already knows its facts before it writes prose.
// This type captures those facts as numbered claims so an optional model
// pass can PHRASE them and a deterministic verifier can check that nothing
// else was said. The plan is produced by Swift only; a model never writes or
// edits a plan.

import Foundation
import VideoScanCore

struct HallieAnswerPlan: Sendable, Equatable {
    /// How the composer should shape the answer (sentence budget), and
    /// whether it may run at all. `.fixed` = the wording is the answer
    /// (help card, capability answers, small talk, reset, declines,
    /// clarifications) and the model is never consulted.
    enum Shape: String, Sendable, Equatable {
        case list
        case biography
        case fact
        case fixed
    }

    /// One thing Hallie may assert. `id` is the short tag the composer must
    /// attach to every sentence ("[c1]"); `evidenceIDs` are the source /
    /// citation identifiers behind it (a CyberBrain evidence ID, a GEDCOM
    /// pointer, or a catalog record ID as text) so the transcript log stays
    /// traceable end to end.
    struct Claim: Sendable, Equatable, Identifiable {
        let id: String
        let text: String
        let evidenceIDs: [String]
        /// Who vouches for this claim when it is a family member's account
        /// rather than a document ("Rick Breen"). The composer must voice
        /// such claims as attributed testimony — "According to Rick, …" —
        /// never as bare fact (Rick 2026-08-24: character and appearance
        /// belong in a biography, with the receipt).
        let attribution: String?

        init(id: String, text: String, evidenceIDs: [String] = [],
             attribution: String? = nil) {
            self.id = id
            self.text = text
            self.evidenceIDs = evidenceIDs
            self.attribution = attribution
        }
    }

    /// A number the composer may quote ("12 catalog items"). Kept apart from
    /// the claims so the prompt can list them plainly; the verifier still
    /// requires every digit run in a sentence to appear in that sentence's
    /// cited claims, so each count is also folded into a claim.
    struct Count: Sendable, Equatable {
        let label: String
        let value: Int
    }

    let route: HallieTurnExecutor.Route
    let shape: Shape
    /// The person or topic the answer is about, when there is one.
    let subject: String?
    let claims: [Claim]
    let counts: [Count]
    /// The deterministic prose the route already produces. Shown verbatim
    /// whenever composition is off, unavailable, slow, or fails verification.
    let fallbackText: String
    /// Whether the subject is living or has passed on (LifeStatus,
    /// 2026-09-01), when the route knows. The composer is told, so the
    /// model keeps the template's tense; the verifier rejects a sentence
    /// that speaks of a living subject's life as finished. Nil = the route
    /// has no subject or no verdict; nothing about tense is said or checked.
    let subjectLifeStatus: LifeStatus?

    init(
        route: HallieTurnExecutor.Route,
        shape: Shape,
        subject: String? = nil,
        claims: [Claim] = [],
        counts: [Count] = [],
        fallbackText: String,
        subjectLifeStatus: LifeStatus? = nil
    ) {
        self.route = route
        self.shape = shape
        self.subject = subject
        self.claims = claims
        self.counts = counts
        self.fallbackText = fallbackText
        self.subjectLifeStatus = subjectLifeStatus
    }

    /// Whether a model may phrase this answer at all.
    var isComposable: Bool {
        shape != .fixed && !claims.isEmpty
    }

    /// The sentence budget the verifier enforces after phrasing.
    var maxSentences: Int {
        switch shape {
        // A biography is a FIXED plan: every claim must reach the reader
        // (coverage rule, live 2026-08-29 — c3 siblings silently dropped).
        // The budget therefore never falls below the claim count, so the
        // verifier cannot be the reason a fact goes missing.
        case .biography: return max(6, claims.count)
        case .list, .fact: return 3
        case .fixed: return 0
        }
    }

    /// The claim IDs, in order, for prompt building and verification.
    var claimIDs: [String] { claims.map(\.id) }

    /// The bound on how many cited items are turned into per-item claims.
    /// The exact count is always its own claim; a long list is a prompt-size
    /// hazard and a three-sentence answer cannot mention 25 files anyway.
    static let maxItemClaims = 10

    // MARK: - Derivation from an executed Result

    /// The plan for an executed result. Routes that build a plan themselves
    /// (presence/cross lists, CyberBrain biographies) carry it on the
    /// Result; every other answered route is planned deterministically from
    /// its own templated prose, one sentence per claim, so the composer can
    /// only re-say what the template already said. Fixed-text routes and
    /// every non-answer are `.fixed`.
    static func derive(from result: HallieTurnExecutor.Result) -> HallieAnswerPlan {
        if let plan = result.answerPlan { return plan }
        let fixed = HallieAnswerPlan(
            route: result.route, shape: .fixed, fallbackText: result.prose)
        switch result.route {
        case .capability, .help, .smalltalk, .conversation, .telling, .reset,
             .followUp, .unsupportedEvent:
            return fixed
        case .presence, .cross, .temporal, .aggregate, .graph, .record:
            break
        }
        guard result.outcome == .answered, result.clarification == nil else {
            return fixed
        }
        let sentences = HallieCompositionVerifier.splitSentences(result.prose)
        guard !sentences.isEmpty else { return fixed }
        let claims = sentences.enumerated().map { index, sentence in
            Claim(id: "c\(index + 1)", text: sentence,
                  evidenceIDs: result.knowledgeCitations.map(\.id))
        }
        let shape: Shape
        switch result.route {
        case .presence, .cross, .aggregate: shape = .list
        case .graph: shape = result.knowledgeCitations.isEmpty ? .fact : .biography
        case .temporal, .record: shape = .fact
        default: shape = .fact
        }
        return HallieAnswerPlan(
            route: result.route,
            shape: shape,
            subject: result.catalogPersonName,
            claims: claims,
            counts: result.matchCount.map { [Count(label: "matching catalog items", value: $0)] } ?? [],
            fallbackText: result.prose,
            subjectLifeStatus: result.subjectLifeStatus)
    }

    // MARK: - Route-specific builders (called by the executor)

    /// Presence / cross list plan: the count sentence is claim c1; each cited
    /// item (bounded) is a claim naming the file and why it matched.
    static func presenceList(
        route: HallieTurnExecutor.Route,
        prose: String,
        totalMatchCount: Int,
        shownCount: Int,
        citations: [HallieTurnExecutor.Citation]
    ) -> HallieAnswerPlan {
        var claims = [Claim(id: "c1", text: prose)]
        // Facts the reader actually cares about, derived from the SAME
        // citations already approved — a span and the people in them. Without
        // these the composer can only re-say "I found 21 catalog items
        // matching that", because that is the only claim it has (Rick's eval,
        // 2026-08-21: "make her sound like she knows this family").
        if let span = yearSpan(of: citations) {
            claims.append(Claim(
                id: "c\(claims.count + 1)",
                text: span.lower == span.upper
                    ? "These are from \(span.lower)."
                    : "These run from \(span.lower) to \(span.upper).",
                evidenceIDs: citations.map(\.recordID.uuidString)))
        }
        for name in confirmedPeople(in: citations).prefix(maxPeopleClaims) {
            claims.append(Claim(
                id: "c\(claims.count + 1)",
                text: "\(name.name) is confirmed in \(name.count) of them.",
                evidenceIDs: citations.map(\.recordID.uuidString)))
        }
        for (index, citation) in citations.prefix(maxItemClaims).enumerated() {
            let at = citation.playbackSeconds.map { String(format: " at %.1fs", $0) } ?? ""
            let why = citation.bases.map(\.summary).joined(separator: "; ")
            // A sentence, not a label: "Item 1: …" taught the model to say
            // "Two examples are Item 1 and Item 2" (overnight cycle 3).
            let ordinal = ["One", "Another", "A third", "A fourth", "A fifth",
                           "A sixth", "A seventh", "An eighth"][min(index, 7)]
            claims.append(Claim(
                id: "c\(claims.count + 1)",
                text: "\(ordinal) of them is \(citation.filename)\(at)"
                    + (why.isEmpty ? "." : " — \(why)."),
                evidenceIDs: [citation.recordID.uuidString]))
        }
        return HallieAnswerPlan(
            route: route,
            shape: .list,
            claims: claims,
            counts: [
                Count(label: "matching catalog items", value: totalMatchCount),
                Count(label: "items listed here", value: shownCount),
            ],
            fallbackText: prose)
    }

    /// At most this many "X is confirmed in N of them" claims.
    static let maxPeopleClaims = 2

    /// Earliest/latest year vouched for by the citations' OWN date evidence.
    /// Only dated bases count — a span must be as citable as any other fact.
    static func yearSpan(of citations: [HallieTurnExecutor.Citation]) -> (lower: Int, upper: Int)? {
        var years: [Int] = []
        for citation in citations {
            for basis in citation.bases {
                switch basis {
                case .inferredDate(let year, _), .fileDate(_, let year, _), .pathYear(let year, _):
                    years.append(year)
                default: continue
                }
            }
        }
        guard let lower = years.min(), let upper = years.max() else { return nil }
        return (lower, upper)
    }

    /// Human-confirmed person tags across the citations, most-cited first.
    /// Machine detections are deliberately excluded — a confirmed tag is the
    /// only person evidence this plan will state as fact.
    static func confirmedPeople(
        in citations: [HallieTurnExecutor.Citation]
    ) -> [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for citation in citations {
            var seen: Set<String> = []
            for basis in citation.bases {
                if case .humanPersonTag(_, let taggedName, _) = basis,
                   seen.insert(taggedName.lowercased()).inserted {
                    counts[taggedName, default: 0] += 1
                }
            }
        }
        return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .map { (name: $0.key, count: $0.value) }
    }

    /// CyberBrain biography plan: the approved AnswerPlan claims become
    /// c1…cN (evidence IDs preserved); uncertainty statements follow as
    /// their own claims so a disputed account can be voiced but not resolved.
    static func biography(
        _ plan: CyberBrainAnswerPlan,
        fallbackText: String,
        subjectLifeStatus: LifeStatus? = nil
    ) -> HallieAnswerPlan {
        var claims: [Claim] = []
        let attributionBySource = Dictionary(uniqueKeysWithValues:
            plan.sourceCitations.compactMap { citation in
                citation.attribution.map { (citation.id, $0) }
            })
        for claim in plan.claims {
            // A family member's not-yet-document-verified account keeps its
            // teller's name so the composer can voice it as testimony.
            let attribution = claim.confidence == .confirmed ? nil
                : claim.evidenceIDs.compactMap { attributionBySource[$0] }.first
            claims.append(Claim(
                id: "c\(claims.count + 1)",
                text: claim.text,
                evidenceIDs: claim.evidenceIDs,
                attribution: attribution))
        }
        for statement in plan.uncertaintyStatements {
            claims.append(Claim(id: "c\(claims.count + 1)", text: statement))
        }
        return HallieAnswerPlan(
            route: .graph,
            shape: .biography,
            subject: plan.subject,
            claims: claims,
            counts: [Count(label: "supporting sources", value: plan.sourceCitations.count)],
            fallbackText: fallbackText,
            subjectLifeStatus: subjectLifeStatus)
    }
}

// MARK: - Subject naming + life dates (live 2026-08-26)
//
// A biography or kinship answer must open by naming its subject in full and
// must not lose the subject's life dates to the verifier. Both rules are
// decided on plan text only; the model's wording is never consulted for
// facts. (C++ reader: these are const member helpers on a value type — no
// state, no side effects.)

extension HallieAnswerPlan {

    /// Whether `sentence` contains the full subject name as a contiguous run
    /// of tokens ("Richard Harding Breen Sr." matches "richard harding breen
    /// sr"; "Mc Gill" does not match "McGill"; a bare "Breen" never matches
    /// a two-word subject).
    static func names(_ subject: String, in sentence: String) -> Bool {
        let want = HallieCompositionVerifier.tokens(of: subject)
        guard !want.isEmpty else { return false }
        let have = HallieCompositionVerifier.tokens(of: sentence)
        guard have.count >= want.count else { return false }
        for start in 0...(have.count - want.count)
        where Array(have[start..<(start + want.count)]) == want {
            return true
        }
        return false
    }

    /// Words that mark a claim as being about when someone lived.
    private static let lifeDateWords: Set<String> = [
        "born", "birth", "birthdate", "birthday", "died", "death", "passed",
        "lived", "buried", "b", "d",
    ]

    /// Claims that state the subject's birth or death: they carry a
    /// four-digit year and life-date vocabulary. Attributed testimony is
    /// excluded — only documented facts may be re-inserted as bare fact.
    var lifeDatesClaims: [Claim] {
        claims.filter { claim in
            guard claim.attribution == nil else { return false }
            let tokens = HallieCompositionVerifier.tokens(of: claim.text)
            let hasYear = tokens.contains { $0.count == 4 && $0.allSatisfy(\.isNumber) }
            return hasYear && tokens.contains { Self.lifeDateWords.contains($0) }
        }
    }

    /// The deterministic sentence that names the subject in full: the first
    /// life-dates claim naming them, else any claim naming them, else the
    /// template's own first sentence (a biography's "Here is what the family
    /// archive currently supports about NAME."). Returns nil when the plan
    /// has no subject or nothing in it names the subject.
    var subjectLeadSentence: (text: String, claimIDs: [String])? {
        guard let subject, !subject.isEmpty else { return nil }
        if let claim = lifeDatesClaims.first(where: { Self.names(subject, in: $0.text) })
            ?? claims.first(where: { $0.attribution == nil && Self.names(subject, in: $0.text) }) {
            return (claim.text, [claim.id])
        }
        if let first = HallieCompositionVerifier.splitSentences(fallbackText).first,
           Self.names(subject, in: first) {
            return (first, [])
        }
        return nil
    }

    /// The claim IDs a dropped or kept sentence cites, described for a log
    /// line: "c1 (life dates)" when it is the subject's dates claim.
    func describeClaimIDs(_ ids: [String]) -> String {
        guard !ids.isEmpty else { return "untagged" }
        let dates = Set(lifeDatesClaims.map(\.id))
        return ids.map { dates.contains($0) ? "\($0) (life dates)" : $0 }
            .joined(separator: ",")
    }
}
