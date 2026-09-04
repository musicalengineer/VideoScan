// HallieTurnExecutor+Conversation.swift
// Per-conversation memory and the model-free step that runs BEFORE any
// translation: help / small talk / reset, capability answers, follow-ups on
// the last answer, cumulative refinements, and local family-tree shapes.
// Shared by the app coordinator and the shell so both clients behave
// identically. Nothing here calls a model.

import Foundation
import VideoScanCore

extension HallieTurnExecutor {

    /// What one conversation remembers between turns. A value type: the app
    /// keeps one per chat window, the shell one per session; tests build it.
    struct ConversationMemory: Sendable, Equatable {
        struct ResultSet: Sendable, Equatable {
            let ast: ArchivistQueryAST
            /// The citations as displayed for the CURRENT page, in order.
            let citations: [Citation]
            /// Total citations shown so far across pages.
            let shownCount: Int
            let totalMatchCount: Int
        }

        /// The last answered result set (nil until a list answer lands).
        private(set) var lastResultSet: ResultSet?
        /// The last list actually SHOWN, kept when a later refinement or
        /// fresh list question found nothing (cs015: "narrow that to
        /// winter" → nothing → "ok show me the second one" still means the
        /// second Middlefield item). Cleared only by reset.
        private(set) var lastShownList: ResultSet?
        /// The list query the last archive answer still carries — a list's
        /// own AST, the count it counted, the person an age was about, the
        /// whole catalog for a catalog-wide count — so "and the newest?"
        /// has something to sort (2026-09-02).
        private(set) var lastRefinable: RefinableQuery?
        /// Where the last ARCHIVE answer came from, for "where did that
        /// come from?" / "how sure are you?" (HallieProvenanceFollowUp).
        /// Kept across follow-ups so the question can be asked after
        /// "play the first one" too.
        private(set) var lastProvenance: HallieProvenanceFollowUp.Provenance?
        /// The last executed AST, list or not — the thing "and in the 90s?"
        /// refines.
        private(set) var lastAST: ArchivistQueryAST?
        /// The cumulative refinement chain behind `lastAST` ("rick + guitar +
        /// westford · around 2005"); the base chain for a fresh question.
        private(set) var lastChain: ArchivistFollowUpResolver.Chain?
        /// Convenience context for callers: people and years of the last AST.
        private(set) var lastPeople: [String] = []
        private(set) var lastYears: ClosedRange<Int>?
        /// The ONE person the last archive answer was about, by the name
        /// the answer settled on — "Nathaniel Parker Sr" after a which-one
        /// chip, not the "nathaniel parker" that was typed (live 2026-08-27:
        /// "are there any photos of him" looked up a person named "Him").
        /// Taken from the answer's `catalogPersonName` when it has one,
        /// else from a single-person AST. Kept across follow-ups; replaced
        /// by the next answer about someone; cleared by reset.
        private(set) var lastSubject: String?
        /// The photo the previous answer showed, so "this photo is …" can
        /// caption or correct it (2026-08-26). Cleared by the next archive
        /// answer that shows no photo; follow-ups and tellings keep it.
        private(set) var lastPhotoAttachment: HalliePhotoAttachment?
        /// The last SUBSTANTIVE exchange — the original ask, how it was
        /// read, what was answered, and any which-one candidates offered —
        /// for a repair turn ("that's wrong", "you gave me people from the
        /// 1300s"). A which-one keeps the ORIGINAL question (the intent's),
        /// not the chip reply; declines that ran nothing (translator
        /// failures, follow-up refusals) and repairs themselves leave it in
        /// place so a second complaint still points at the same ask.
        private(set) var lastExchange: Exchange?
        /// The file a `record` turn could not settle ("New Hampshire.mov",
        /// "the selected video") — set when a record turn is declined
        /// (not found / ambiguous / nothing selected), which also empties
        /// the playable memory, so "play it" right after names the gap
        /// instead of playing an older list's item (codex #976 item 2).
        /// Cleared by the next answer that leaves something to play.
        private(set) var lastRecordDecline: RecordDecline?

        enum RecordDecline: Sendable, Equatable {
            /// A file named in the question that was not found or fit
            /// several records.
            case file(String)
            /// "this video" with nothing selected.
            case selection
        }

        struct Exchange: Sendable, Equatable {
            let question: String
            let ast: ArchivistQueryAST?
            let route: Route
            let outcome: Outcome
            let answer: String
            /// The which-one offers, when the answer asked which; else [].
            let candidates: [Candidate]
            /// The answer's own query description — how a deterministic
            /// list answer (a birthplace trail) remembers its page, so
            /// "show more" can continue it (2026-09-02).
            let queryDescription: String?
        }

        init() {}

        /// Forget everything ("start over").
        mutating func reset() {
            self = ConversationMemory()
        }

        /// Record an executed turn. Follow-up media actions, help, small
        /// talk and ordinary capability answers carry no AST and leave
        /// memory untouched; a roster answer is retained only to scope a
        /// later name pronoun. A reset clears it; a refined or paged query
        /// replaces it like any other.
        mutating func record(intent: Intent?, result: Result, question: String? = nil) {
            if result.route == .reset {
                reset()
                return
            }
            recordExchange(intent: intent, result: result, question: question)
            switch result.route {
            case .presence, .cross, .aggregate, .temporal, .graph, .telling, .record:
                lastProvenance = HallieProvenanceFollowUp.Provenance(result: result)
            default:
                break
            }
            let shownPhoto = result.attachments.lazy.compactMap { attachment -> HalliePhotoAttachment? in
                if case .photo(let photo) = attachment { return photo }
                return nil
            }.first
            switch (shownPhoto, result.route) {
            case (let photo?, _):
                lastPhotoAttachment = photo
            case (nil, .presence), (nil, .cross), (nil, .aggregate), (nil, .temporal), (nil, .graph),
                 (nil, .record):
                lastPhotoAttachment = nil
            default:
                break
            }
            // A resolved subject outranks the typed name: the answer knows
            // WHICH Nathaniel Parker it just described. Local answers with
            // no intent (the deterministic photo / description routes) count
            // too — they name their person the same way.
            if let name = result.catalogPersonName, result.outcome == .answered
                || result.route == .graph {
                lastSubject = name
                // A local answer (no intent) about ONE person replaces the
                // older AST's people too, or "photos of him" after "videos
                // of Rick and Donna" → "photo of Nathaniel Parker Sr" would
                // still see the stale pair (codex #716).
                if intent == nil { lastPeople = [name] }
            }
            // A non-list answer that names its list (a count, an age).
            if let refinable = result.refinableQuery, result.outcome == .answered {
                lastRefinable = refinable
            }
            guard let intent else { return }
            let ast = intent.ast
            lastAST = ast
            lastChain = intent.refinementChain
                ?? (intent.citationOffset > 0 ? lastChain : nil)
                ?? ArchivistFollowUpResolver.Chain.base(for: ast)
            (lastPeople, lastYears) = Self.context(of: ast)
            if result.catalogPersonName == nil, lastPeople.count == 1,
               !HalliePronounContinuity.isThirdPersonPronoun(lastPeople[0]) {
                lastSubject = lastPeople[0]
            } else if result.catalogPersonName == nil, lastPeople.count > 1 {
                lastSubject = nil
            }
            switch result.route {
            case .presence, .cross, .aggregate:
                if result.outcome == .answered {
                    lastResultSet = ResultSet(
                        ast: ast,
                        citations: result.citations,
                        shownCount: intent.citationOffset + result.citations.count,
                        totalMatchCount: result.matchCount ?? result.citations.count)
                    if !result.citations.isEmpty { lastShownList = lastResultSet }
                    lastRecordDecline = nil
                    if let ordered = intent.dateOrder {
                        // "and the newest?" keeps the scope it sorted, so
                        // "and the oldest?" sorts the same thing.
                        lastRefinable = ordered.scope
                    } else if result.refinableQuery == nil {
                        lastRefinable = result.route == .aggregate ? nil : .list(ast, anyOfPeople: false)
                    }
                } else if intent.citationOffset == 0 {
                    // A fresh list question with no evidence: there is no
                    // "one of them" any more. A REFINEMENT that found
                    // nothing keeps the list it was narrowing (cs015).
                    lastResultSet = nil
                    if intent.refinementChain == nil { lastShownList = nil }
                    if result.refinableQuery == nil, result.route != .aggregate {
                        lastRefinable = nil
                    }
                }
            case .graph:
                if result.refinableQuery == nil { lastRefinable = nil }
            case .record:
                recordRecordTurn(ast: ast, result: result)
            case .temporal, .unsupportedEvent, .followUp, .capability,
                 .help, .smalltalk, .conversation, .telling, .reset:
                break
            }
        }

        /// One record: "play it" / "show it in the catalog" work on the
        /// single citation; there is no list to refine or page. A DECLINED
        /// record turn (not found / ambiguous / nothing selected) empties
        /// the playable memory — an older list must not answer "play it"
        /// (codex #976 item 2: search → missing file → "play it" played
        /// the old media) — and remembers what could not be settled.
        private mutating func recordRecordTurn(ast: ArchivistQueryAST, result: Result) {
            if result.outcome == .answered, !result.citations.isEmpty {
                lastResultSet = ResultSet(
                    ast: ast, citations: result.citations,
                    shownCount: result.citations.count,
                    totalMatchCount: result.citations.count)
                lastShownList = lastResultSet
                lastRecordDecline = nil
            } else if result.outcome == .declined {
                lastResultSet = nil
                lastShownList = nil
                if case .record(let payload) = ast, case .file(let name) = payload.reference {
                    lastRecordDecline = .file(name)
                } else {
                    lastRecordDecline = .selection
                }
            }
            lastRefinable = nil
        }

        private mutating func recordExchange(intent: Intent?, result: Result, question: String?) {
            if result.outcome == .repaired { return }
            let asked = result.clarification?.intent.originalQuestion
                ?? intent?.originalQuestion
                ?? question
            let substantive: Bool
            if result.clarification != nil || intent != nil {
                substantive = true
            } else if result.offeredActions.contains(HallieLineageAnswer.trailShowMoreAction) {
                // An answer that offers "show more" pages from THIS
                // exchange; forgetting it would leave the chip empty — a
                // paged trail joined with a capability answer took the
                // capability's route (codex #1014 item 4).
                substantive = true
            } else {
                switch result.route {
                case .presence, .cross, .aggregate, .temporal, .graph, .telling, .unsupportedEvent,
                     .record:
                    substantive = result.outcome == .answered || result.outcome == .needsClarification
                case .capability:
                    // Most capability cards are not conversational facts,
                    // but roster pronouns need to distinguish a prior roster
                    // from a prior siblings/search list.
                    substantive = result.queryDescription == "shape=roster"
                case .followUp, .help, .smalltalk, .conversation, .reset:
                    substantive = false
                }
            }
            guard substantive, let asked, !asked.isEmpty else { return }
            lastExchange = Exchange(
                question: asked,
                ast: result.clarification?.intent.ast ?? intent?.ast,
                route: result.route,
                outcome: result.outcome,
                answer: result.prose,
                candidates: result.clarification?.candidates ?? [],
                queryDescription: result.queryDescription)
        }

        /// Who a bare "he" / "she" / "they" stands for right now: the
        /// resolved subject when there is one, else the last AST's people.
        var pronounReferents: [String] {
            if let lastSubject, lastPeople.count <= 1 { return [lastSubject] }
            return lastPeople
        }

        /// The last list shown, as a follow-up snapshot, for "show me the
        /// second one" when the current result set is empty.
        var shownListSnapshot: ArchivistFollowUpResolver.Snapshot? {
            guard let shown = lastShownList, !shown.citations.isEmpty else { return nil }
            return ArchivistFollowUpResolver.Snapshot(
                ast: shown.ast,
                items: shown.citations.map {
                    ArchivistFollowUpResolver.Snapshot.Item(
                        filename: $0.filename, fullPath: $0.fullPath, years: Self.years(of: $0))
                },
                shownCount: shown.shownCount,
                totalMatchCount: shown.totalMatchCount,
                chain: nil)
        }

        var followUpSnapshot: ArchivistFollowUpResolver.Snapshot? {
            guard lastAST != nil || lastResultSet != nil else { return nil }
            let items = (lastResultSet?.citations ?? []).map { citation in
                ArchivistFollowUpResolver.Snapshot.Item(
                    filename: citation.filename,
                    fullPath: citation.fullPath,
                    years: Self.years(of: citation))
            }
            return ArchivistFollowUpResolver.Snapshot(
                ast: lastResultSet?.ast ?? lastAST,
                items: items,
                shownCount: lastResultSet?.shownCount ?? 0,
                totalMatchCount: lastResultSet?.totalMatchCount ?? 0,
                chain: lastChain)
        }

        private static func context(of ast: ArchivistQueryAST) -> ([String], ClosedRange<Int>?) {
            func years(_ start: Int?, _ end: Int?) -> ClosedRange<Int>? {
                guard let lower = start ?? end, let upper = end ?? start,
                      lower <= upper else { return nil }
                return lower...upper
            }
            switch ast {
            case .presence(let p): return (p.people ?? [], years(p.yearStart, p.yearEnd))
            case .cross(let p): return (p.people ?? [], years(p.yearStart, p.yearEnd))
            case .event(let p): return (p.people ?? [], years(p.yearStart, p.yearEnd))
            case .temporal(let p):
                if case .explicitYear(let year) = p.reference {
                    return ([p.subject], year...year)
                }
                return ([p.subject], nil)
            case .aggregate(let p): return (p.anchorPeople, nil)
            case .graph(let p): return (p.people, nil)
            // The people asked about ("is Donna in it") are the pronoun
            // referents for the next turn; the record itself is not a person.
            case .record(let p): return (p.people ?? [], nil)
            }
        }

        /// Years a citation was proven for, from its bases; falls back to
        /// standalone 4-digit runs in the path so "the one from 1994" still
        /// works when the year was not part of the question.
        static func years(of citation: Citation) -> [Int] {
            var found: [Int] = []
            for basis in citation.bases {
                switch basis {
                case .inferredDate(let year, _): found.append(year)
                case .fileDate(_, let year, _): found.append(year)
                case .pathYear(let year, _): found.append(year)
                default: break
                }
            }
            var digits = ""
            func flush() {
                if digits.count == 4, let year = Int(digits),
                   (1900...2099).contains(year) { found.append(year) }
                digits.removeAll(keepingCapacity: true)
            }
            for character in citation.fullPath {
                if character.isNumber { digits.append(character) } else { flush() }
            }
            flush()
            return Array(Set(found)).sorted()
        }
    }

    /// The Catalog row the user has selected, captured before any await
    /// (2026-09-01). `date` is nil when the record has no date signal at
    /// all; the struct itself is nil when nothing is selected — the two
    /// get different answers to "when was this filmed".
    struct SelectedRecord: Sendable, Equatable {
        let recordID: UUID
        let date: ArchivistTemporalSelectionDateSnapshot?
    }

    /// The decision taken before translation.
    enum PreTranslation: Sendable, Equatable {
        /// Nothing local applies; translate the question as typed.
        case translate(question: String, playAfterAnswer: Bool)
        /// Execute this intent (refined / paged / locally-shaped AST).
        case run(Intent)
        /// A complete answer with no translation and no evidence lookup.
        case answer(Result)
    }

    /// "photo of the oldest person in the tree" (live 2026-08-26): resolve
    /// the PERSON first, then hand "photo/video of <name>" to the
    /// person-media routes — never a keyword search on the superlative
    /// words. Photos go to the portrait route with the ranking sentence in
    /// front; videos become "videos of <name>" for the presence route.
    static func superlativeMediaTurn(
        _ lineage: HallieLineageQuestion,
        media: String,
        question: String,
        playAfterAnswer: Bool,
        lineageAnswer: (HallieLineageQuestion) -> Result?
    ) -> PreTranslation {
        guard let found = lineageAnswer(lineage) else {
            return .translate(question: question, playAfterAnswer: playAfterAnswer)
        }
        guard found.outcome == .answered, let name = found.catalogPersonName else {
            return .answer(found)
        }
        if ["photo", "picture", "portrait", "image", "snapshot"].contains(media) {
            guard let photo = lineageAnswer(.personPhoto(person: name)) else { return .answer(found) }
            return .answer(HallieLineageAnswer.prefixing(found.prose, to: photo))
        }
        // A pre-photography person (WorldKnowledge) gets the honest line
        // instead of a presence search; everyone else searches by name.
        if let floor = lineageAnswer(.personVideos(person: name)) {
            return .answer(HallieLineageAnswer.prefixing(found.prose, to: floor))
        }
        return .translate(question: "videos of \(name)", playAfterAnswer: playAfterAnswer)
    }

    /// "who do you know about? tell me about Thankful Pratt" — two
    /// questions in one turn (live 2026-08-26: only the second was
    /// answered). Splits on an INNER question mark into two askable parts;
    /// nil for one question, or when either part is too short to be one.
    static func splitTwoQuestions(_ text: String) -> (first: String, second: String)? {
        let parts = text.split(separator: "?", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard parts.count == 2,
              parts.allSatisfy({ $0.split(separator: " ").count >= 2 && $0.contains(where: \.isLetter) })
        else { return nil }
        return (parts[0] + "?", parts[1])
    }

    /// Runs the model-free resolvers in order: help / small talk / reset →
    /// capability question → follow-up on the last answer → nothing. Pure
    /// given its inputs.
    ///
    /// Two questions in one turn: when the FIRST has a model-free answer,
    /// it is given; the second is answered too when it is model-free, else
    /// offered as a chip ("tap it and I’ll answer that next") — the least
    /// risky shape, since a translated second question cannot carry the
    /// first answer's prose through the model.
    static func preTranslation(
        question: String,
        playAfterAnswer: Bool,
        memory: ConversationMemory,
        isKnownPerson: (String) -> Bool,
        isInnerCircleName: ((String) -> Bool)? = nil,
        catalogStats: HallieCatalogStats? = nil,
        rosterAnswer: ((PeopleTab.RosterScope) -> Result)? = nil,
        lineageAnswer: ((HallieLineageQuestion) -> Result?)? = nil,
        relationshipsOverview: ((HallieRelationshipsOverview.Ask) -> Result)? = nil,
        researchAnswer: ((HallieResearchQuestion) -> Result)? = nil,
        selectedRecord: SelectedRecord? = nil
    ) -> PreTranslation {
        if let (first, second) = splitTwoQuestions(question),
           case .answer(let a) = preTranslationSingle(
               question: first, playAfterAnswer: playAfterAnswer, memory: memory,
               isKnownPerson: isKnownPerson, isInnerCircleName: isInnerCircleName,
               catalogStats: catalogStats,
               rosterAnswer: rosterAnswer, lineageAnswer: lineageAnswer,
               relationshipsOverview: relationshipsOverview,
               researchAnswer: researchAnswer, selectedRecord: selectedRecord),
           a.route != .reset, a.clarification == nil {
            let secondTurn = preTranslationSingle(
                question: second, playAfterAnswer: playAfterAnswer, memory: memory,
                isKnownPerson: isKnownPerson, isInnerCircleName: isInnerCircleName,
                catalogStats: catalogStats,
                rosterAnswer: rosterAnswer, lineageAnswer: lineageAnswer,
                relationshipsOverview: relationshipsOverview,
                researchAnswer: researchAnswer, selectedRecord: selectedRecord)
            if case .answer(let b) = secondTurn, b.route != .reset {
                return .answer(joinedTwoQuestionAnswer(a, b))
            }
            let label = second.prefix(1).uppercased() + second.dropFirst()
            return .answer(Result(
                route: a.route, outcome: a.outcome,
                prose: a.prose + "\n\nYou also asked “\(second)” — tap it and I’ll answer that next.",
                basisLine: a.basisLine,
                queryDescription: "two questions: \(a.queryDescription ?? "?") + deferred",
                citations: a.citations, knowledgeCitations: a.knowledgeCitations,
                catalogPersonName: a.catalogPersonName, clarification: nil,
                matchCount: a.matchCount, mediaAction: a.mediaAction,
                offeredActions: a.offeredActions + [.ask(question: second, label: String(label))],
                attachments: a.attachments,
                performsFirstOfferedAction: a.immediateOfferedAction != nil,
                immediateOfferedAction: a.immediateOfferedAction))
        }
        return preTranslationSingle(
            question: question, playAfterAnswer: playAfterAnswer, memory: memory,
            isKnownPerson: isKnownPerson, isInnerCircleName: isInnerCircleName,
            catalogStats: catalogStats,
            rosterAnswer: rosterAnswer, lineageAnswer: lineageAnswer,
            relationshipsOverview: relationshipsOverview,
            researchAnswer: researchAnswer, selectedRecord: selectedRecord)
    }

    /// Both answers' facts survive the join (codex #707 item 5: only b's
    /// citations used to be kept). Media and knowledge citations are
    /// unioned in order; the two answer plans are concatenated with b's
    /// claim tags renumbered after a's (a keeps c1…cK, b becomes cK+1…) so
    /// the transcript log and the verifier never see two different "[c1]"s.
    static func joinedTwoQuestionAnswer(_ a: Result, _ b: Result) -> Result {
        var citations = a.citations
        for c in b.citations where !citations.contains(c) { citations.append(c) }
        var knowledge = a.knowledgeCitations
        for k in b.knowledgeCitations where !knowledge.contains(where: { $0.id == k.id }) {
            knowledge.append(k)
        }
        let prose = a.prose + "\n\n" + b.prose
        // Plans: derive each side's plan the way the client would, then
        // shift b's IDs. `.fixed` (wording IS the answer) wins for the pair
        // — a half-composable answer is not composable.
        var plan: HallieAnswerPlan?
        var transcript: String?
        if a.answerPlan != nil || b.answerPlan != nil || a.transcriptText != nil || b.transcriptText != nil {
            let planA = HallieAnswerPlan.derive(from: a)
            let planB = HallieAnswerPlan.derive(from: b)
            let offset = planA.claims.count
            func flattenedClaims(
                _ source: HallieAnswerPlan, offset: Int
            ) -> [HallieAnswerPlan.Claim] {
                source.claims.map { claim in
                    HallieAnswerPlan.Claim(
                        id: shiftClaimID(claim.id, by: offset), text: claim.text,
                        evidenceIDs: claim.evidenceIDs, attribution: claim.attribution,
                        requiredPersonNames: claim.requiredPersonNames,
                        // Biography semantics belong to the source segment,
                        // not whichever answer happens to be second.
                        requiresCoverage: claim.requiresCoverage
                            || source.shape == .biography,
                        isListCountClaim: claim.isListCountClaim
                            || (source.shape == .list && claim.id == "c1"))
                }
            }
            let claimsA = flattenedClaims(planA, offset: 0)
            let shifted = flattenedClaims(planB, offset: offset)
            // Provenance survives the join. It carries no claim ID, so
            // nothing about it shifts; an assumed tree bridge said by
            // either half is still owed by the pair. Deduped, because both
            // halves of one turn usually assume the same bridge. Not
            // appended to `fallbackText` — each half's prose already ends
            // with its own aside, and `prose` is those two halves.
            var provenance: [String] = []
            for note in [planA.provenanceNote, planB.provenanceNote].compactMap({ $0 })
            where !provenance.contains(note) {
                provenance.append(note)
            }
            plan = HallieAnswerPlan(
                route: b.route,
                shape: (planA.shape == .fixed || planB.shape == .fixed) ? .fixed : planB.shape,
                subject: b.catalogPersonName ?? a.catalogPersonName,
                claims: claimsA + shifted,
                counts: planA.counts + planB.counts,
                fallbackText: prose,
                provenanceNote: provenance.isEmpty ? nil : provenance.joined())
            if a.transcriptText != nil || b.transcriptText != nil {
                transcript = (a.transcriptText ?? a.prose) + "\n\n"
                    + shiftClaimTags(in: b.transcriptText ?? b.prose, by: offset)
            }
        }
        let matchCount: Int?
        switch (a.matchCount, b.matchCount) {
        case (let x?, let y?): matchCount = x + y
        case (let x?, nil), (nil, let x?): matchCount = x
        default: matchCount = nil
        }
        // Immediate actions are explicit identities, not positions in the
        // concatenated offer array. If both clauses directly request an
        // action, the later clause wins: it is the final state the user
        // asked to see ("open People … open Archive" ends on Archive).
        let immediateAction = b.immediateOfferedAction ?? a.immediateOfferedAction
        // A paged birthplace trail keeps its "show more" through the join
        // (the continuation finds its segment inside the joined query
        // description) — unless BOTH halves are unfinished trails, when
        // "show more" would be ambiguous and neither is offered (codex
        // #1014 item 4). The same rule decides both the chip and the
        // continuation, so a chip is never offered that will not work.
        let joinedQuery = "two questions: \(a.queryDescription ?? "?") + \(b.queryDescription ?? "?")"
        var offered = a.offeredActions + b.offeredActions
        if offered.contains(HallieLineageAnswer.trailShowMoreAction),
           HallieLineageQuestion.trailContinuationSegment(in: joinedQuery) == nil {
            offered.removeAll { $0 == HallieLineageAnswer.trailShowMoreAction }
        }
        return Result(
            route: b.route, outcome: b.outcome,
            prose: prose,
            basisLine: a.basisLine + " " + b.basisLine,
            queryDescription: joinedQuery,
            citations: citations, knowledgeCitations: knowledge,
            catalogPersonName: b.catalogPersonName ?? a.catalogPersonName,
            clarification: b.clarification,
            matchCount: matchCount, mediaAction: b.mediaAction ?? a.mediaAction,
            offeredActions: offered,
            answerPlan: plan, composedBy: b.composedBy, transcriptText: transcript,
            attachments: a.attachments + b.attachments,
            performsFirstOfferedAction: immediateAction != nil,
            immediateOfferedAction: immediateAction)
    }

    /// "c3" → "c7" for offset 4; anything that is not a claim ID is returned
    /// untouched.
    static func shiftClaimID(_ id: String, by offset: Int) -> String {
        guard offset > 0, id.hasPrefix("c"), id.count > 1,
              let n = Int(id.dropFirst()) else { return id }
        return "c\(n + offset)"
    }

    /// Renumber every claim tag inside "[…]" groups: "[c1][c2, c3]" with
    /// offset 4 → "[c5][c6, c7]". Text outside brackets is untouched.
    static func shiftClaimTags(in text: String, by offset: Int) -> String {
        guard offset > 0 else { return text }
        var out = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "["),
              let close = rest[open...].firstIndex(of: "]") {
            out += rest[..<open]
            let inner = rest[rest.index(after: open)..<close]
            // Keep the original separators: split on the boundary between a
            // token and a separator by rewriting token runs in place.
            var rewritten = ""
            var token = ""
            func flush() { rewritten += shiftClaimID(token, by: offset); token = "" }
            for ch in inner {
                if ch == "," || ch == " " { flush(); rewritten.append(ch) } else { token.append(ch) }
            }
            flush()
            out += "[" + rewritten + "]"
            rest = rest[rest.index(after: close)...]
        }
        out += rest
        return out
    }

    enum MediaAskPronoun: Equatable {
        case subject(String)
        case ask(Result)
    }

    /// The person a pronoun in a photo / video ask stands for. Singular
    /// ("him", "her", "his", …) → the conversation's one current subject;
    /// plural ("them", "their", …) → a polite no, one person at a time.
    /// No subject in memory → "who do you mean?" (never a lookup of "Him").
    static func mediaAskPronounSubject(
        _ pronoun: String, memory: ConversationMemory,
        ask: String = "media ask",
        pluralProse: String = "I can look for pictures of one person at a time — who do you mean?"
    ) -> MediaAskPronoun {
        let key = pronoun.lowercased()
        if HalliePronounContinuity.plural.contains(key) {
            return .ask(Result(
                route: .graph, outcome: .declined,
                prose: pluralProse,
                basisLine: "Basis: a plural pronoun names no one person; nothing was looked up.",
                queryDescription: "\(ask): pronoun \(key) (plural)",
                citations: [], catalogPersonName: nil))
        }
        let referents = memory.pronounReferents.filter {
            !$0.isEmpty && !HalliePronounContinuity.isThirdPersonPronoun($0)
        }
        guard referents.count == 1 else {
            return .ask(Result(
                route: .graph, outcome: .declined,
                prose: HalliePronounContinuity.whoDoYouMean(key),
                basisLine: "Basis: no one person from the last answer to stand for “\(key)”; nothing was looked up.",
                queryDescription: "\(ask): pronoun \(key) (no subject)",
                citations: [], catalogPersonName: nil))
        }
        return .subject(referents[0])
    }

    /// The local family-tree shapes, as one step of `preTranslationSingle`.
    /// Nil = the shape was not really ours; the question continues as typed.
    private static func lineageTurn(
        _ detected: HallieLineageQuestion,
        question: String,
        playAfterAnswer: Bool,
        memory: ConversationMemory,
        lineageAnswer: ((HallieLineageQuestion) -> Result?)?
    ) -> PreTranslation? {
        var lineage = detected
        // "are there any photos of him" right after a biography (live
        // 2026-08-27): the photo / video shapes run BEFORE the
        // translator's pronoun rewrite, so "him" reached the tree as a
        // name. A pronoun object is resolved here through the same
        // memory subject the rest of the executor uses; with nothing to
        // stand for, Hallie asks who — she never looks up "Him".
        if let object = lineage.mediaAskPerson,
           HalliePronounContinuity.isThirdPersonPronoun(object) {
            // "center on them": the tree centers on one person; the shared
            // plural line talks about pictures, so say it for the tree.
            if case .centerTree = lineage, HalliePronounContinuity.plural.contains(object.lowercased()) {
                return .answer(Result(
                    route: .graph, outcome: .declined,
                    prose: "I can center the tree on one person at a time — who do you mean?",
                    basisLine: "Basis: a plural pronoun names no one person; nothing was looked up.",
                    queryDescription: "lineage: center tree on pronoun \(object.lowercased()) (plural)",
                    citations: [], catalogPersonName: nil))
            }
            switch mediaAskPronounSubject(object, memory: memory) {
            case .subject(let name):
                lineage = lineage.replacingMediaAskPerson(with: name)
            case .ask(let result):
                return .answer(result)
            }
        }
        // A multi-hop kinship phrase ("X's great great grandpa on his
        // paternal side") is not answered by the lineage code: it is a
        // ready-made graph intent, run by the ordinary kinship route so
        // it keeps the chips, People-tab fallback and told knowledge.
        if case .kinship(var person, let relation, let side) = lineage {
            // "and her husband?" (eval 2026-09-01): the possessor is a
            // pronoun; it stands for the last answer's ONE subject, the
            // same way "photos of him" does. Martha stays the subject
            // after "did she have kids" — a kinship answer about X's
            // relatives leaves X in memory, not the relatives.
            if let pronoun = person, HalliePronounContinuity.isThirdPersonPronoun(pronoun) {
                switch mediaAskPronounSubject(
                    pronoun, memory: memory, ask: "kinship ask",
                    pluralProse: "I can look up one person's family at a time — who do you mean?") {
                case .subject(let name): person = name
                case .ask(let result): return .answer(result)
                }
            }
            return .run(Intent(
                originalQuestion: question,
                ast: .graph(.init(people: [person ?? "me"], operation: .kinship,
                                  relation: relation, side: side)),
                playAfterAnswer: playAfterAnswer))
        }
        // "read out her maternal line birthplaces" (2026-09-02): the
        // possessor is a pronoun standing for the last answer's subject —
        // the same rule as the kinship ask above.
        if case .birthplaceTrail(let pronoun?, let line, let stop, let ask) = lineage,
           HalliePronounContinuity.isThirdPersonPronoun(pronoun) {
            switch mediaAskPronounSubject(
                pronoun, memory: memory, ask: "birthplace trail",
                pluralProse: "I can trace one person's line at a time — who do you mean?") {
            case .subject(let name):
                lineage = .birthplaceTrail(person: name, line: line, stop: stop, ask: ask)
            case .ask(let result):
                return .answer(result)
            }
        }
        // "tell me about rick's family tree, his brothers, sisters, parents,
        // and grandparents" (live miss #16): the person card, by the
        // ordinary family-tree route (owner chain, People-tab bridge,
        // chips), never the translator.
        if case .personTree(let person) = lineage {
            return .run(Intent(
                originalQuestion: question,
                ast: .graph(.init(people: [person ?? "me"], operation: .familyTree)),
                playAfterAnswer: playAfterAnswer))
        }
        if case .superlative(_, _, let media?) = lineage, let lineageAnswer {
            return superlativeMediaTurn(
                lineage, media: media, question: question,
                playAfterAnswer: playAfterAnswer, lineageAnswer: lineageAnswer)
        }
        // "find our nearest common ancestor" (live miss #9): "our" = the
        // owner and whoever the conversation is about right now; the
        // answer falls back to the owner's spouse when nobody is.
        if case .commonAncestor(nil, nil) = lineage,
           let focus = memory.pronounReferents.first(where: { !HalliePronounContinuity.isThirdPersonPronoun($0) && !$0.isEmpty }) {
            lineage = .commonAncestor(a: nil, b: focus)
        }
        if let lineageAnswer, let answer = lineageAnswer(lineage) {
            // A common-ancestor ask stopped by "Which Donna do you mean?"
            // runs as an intent instead, so the executor's which-one chips
            // resume THIS ask for the chosen namesake (2026-08-29).
            // "Between you and whom?" carries no chips and stays local.
            if case .commonAncestor(let a, let b) = lineage,
               answer.outcome == .needsClarification, answer.clarification != nil {
                return .run(Intent(
                    originalQuestion: question,
                    ast: .graph(.init(people: [a ?? "me", b ?? "me"], operation: .commonAncestor)),
                    playAfterAnswer: playAfterAnswer))
            }
            return .answer(answer)
        }
        // A photo ask the lineage answer declined to settle (several
        // namesakes): run it as a photo intent so the executor can offer
        // the which-one chips and finish the PHOTO ask after the tap
        // (live 2026-08-27: "are there are photos of Nathaniel Parker").
        if lineageAnswer != nil, case .personPhoto(let person) = lineage {
            return .run(Intent(
                originalQuestion: question,
                ast: .presence(.init(people: [person], mediaKind: .photo)),
                playAfterAnswer: playAfterAnswer))
        }
        return nil
    }

    private static func preTranslationSingle(
        question: String,
        playAfterAnswer: Bool,
        memory: ConversationMemory,
        isKnownPerson: (String) -> Bool,
        isInnerCircleName: ((String) -> Bool)? = nil,
        catalogStats: HallieCatalogStats?,
        rosterAnswer: ((PeopleTab.RosterScope) -> Result)?,
        lineageAnswer: ((HallieLineageQuestion) -> Result?)?,
        relationshipsOverview: ((HallieRelationshipsOverview.Ask) -> Result)? = nil,
        researchAnswer: ((HallieResearchQuestion) -> Result)? = nil,
        selectedRecord: SelectedRecord? = nil
    ) -> PreTranslation {
        // A turn ABOUT the previous answer ("that's wrong", "you presented
        // me a list of people born hundreds of years ago") is repaired from
        // memory — never translated into a search (live miss #4, 2026-08-28).
        // With nothing to repair the same words route as a fresh question.
        if let exchange = memory.lastExchange, HallieRepairTurn.isRepair(question) {
            return .answer(HallieRepairTurn.answer(question, exchange: exchange))
        }
        // "when was this filmed" / "how old is this tape" with a Catalog row
        // selected (2026-09-01): the record's own resolved date, no model.
        // With nothing selected the words go on to the translator and the
        // temporal route asks for a selection, as before.
        if let selectedRecord, let ask = ArchivistSelectionDateQuestion.detect(question) {
            return .answer(ArchivistSelectionDateQuestion.answer(ask, selection: selectedRecord.date))
        }
        // Capability first (codex #976 item 5): "how do i change donna's
        // bio" / "what can you do with it" are questions about Hallie, not
        // about a video that happens to be selected — and only then is
        // "how do i …" a how-to for the help card, small talk, or reset.
        if let capability = ArchivistCapabilityQuestion.detect(question) {
            return .answer(capabilityResult(capability))
        }
        if let command = ArchivistConversationCommand.detect(question) {
            return .answer(commandResult(command))
        }
        // "who is in New Hampshire.mov" / "does it have my name in it" /
        // "tell me about this video" (2026-09-02): ONE record, answered
        // from its own fields by the record route — never a catalog-wide
        // sweep. The client resolves the reference (selection or named
        // file) when it captures the context. The record recogniser runs
        // BEFORE the knowledge lanes (codex #987 item 4, the order before
        // 4f74d809): a file named in the question is a record question
        // whatever else the sentence says — "who is in Breen surname
        // origin.mov" is about that file, not about the Breen surname.
        if let record = ArchivistRecordQuestion.detect(question) {
            return .run(Intent(
                originalQuestion: question,
                ast: .record(record),
                playAfterAnswer: playAfterAnswer))
        }
        // An advice / creative / definition request that carries no hard
        // archive cue skips the FAMILY lanes and goes on to be answered as
        // general knowledge. Narrow on purpose: it runs after capability,
        // help/small-talk/reset, the weather aside and the record
        // recogniser, so it cannot steal any of them, and it claims only a
        // sentence that already reads as a request for advice.
        //
        // Observed 2026-09-03: "Help me think of three questions to ask my
        // grandmother." was answered by the kinship lane with the names of
        // Rick's two grandmothers — a family fact nobody asked for, in
        // place of the advice that was asked for.
        //
        // `.translate` is the right result rather than a new PreTranslation
        // case: both clients already consult the same router before they
        // call the model, so a question routed here reaches the general
        // lane without a second, divergent decision.
        let generalAdvice: Bool
        if let isInnerCircleName {
            generalAdvice = HallieGeneralKnowledgeLane.claimsBeforeFamilyLanes(
                question, isKnownPerson: isKnownPerson,
                isInnerCircleName: isInnerCircleName).isGeneral
        } else {
            // No curated inner circle: the WIDE oracle judges lone words
            // too, which over-routes to grounded rather than under-routing
            // to free composition.
            generalAdvice = HallieGeneralKnowledgeLane.claimsBeforeFamilyLanes(
                question, isKnownPerson: isKnownPerson).isGeneral
        }
        if generalAdvice {
            return .translate(question: question, playAfterAnswer: playAfterAnswer)
        }
        if let turn = knowledgeLaneTurn(
            question: question, playAfterAnswer: playAfterAnswer, memory: memory,
            isKnownPerson: isKnownPerson, lineageAnswer: lineageAnswer) {
            return turn
        }
        if let turn = catalogLaneTurn(
            question: question, memory: memory, catalogStats: catalogStats,
            rosterAnswer: rosterAnswer, relationshipsOverview: relationshipsOverview,
            researchAnswer: researchAnswer) {
            return turn
        }
        return followUpTurn(
            question: question, playAfterAnswer: playAfterAnswer,
            memory: memory, isKnownPerson: isKnownPerson)
    }

    /// The model-free lanes that read the family knowledge: surname
    /// history, a property of a known person, lineage shapes. Nil when
    /// none of them claims the question. Capability, help/small-talk/reset
    /// and the record recogniser all run before this in
    /// `preTranslationSingle` (codex #976 item 5, codex #987 item 4).
    private static func knowledgeLaneTurn(
        question: String,
        playAfterAnswer: Bool,
        memory: ConversationMemory,
        isKnownPerson: (String) -> Bool,
        lineageAnswer: ((HallieLineageQuestion) -> Result?)?
    ) -> PreTranslation? {
        // An explicit app-navigation command outranks lineage and roster
        // questions. The recogniser requires "tab" or "window", so ordinary
        // asks such as "show Donna in the archive" never land here.
        if let destination = HallieAppNavigation.detect(question) {
            return .answer(HallieAppNavigation.answer(destination))
        }
        // Public surname history is not an archive assertion. Keep this
        // narrow and sourced so a question such as "Breen surname origin"
        // does not become either an invented family-tree fact or a catalog
        // search for a person named Breen.
        if let surnameAnswer = HallieSurnameReference.answer(question) {
            return .answer(surnameAnswer)
        }
        // "what is Dad's name and his birthdate?" (live miss #19): a
        // PROPERTY of a known person whose canonical name is itself a
        // kinship word was read as "father of Dad". A possessive subject the
        // context knows + a property word is a biography ask about THAT
        // person; "Rick's dad" (relation word as object) is untouched.
        if let subject = HalliePropertyAsk.detect(question),
           subject == "me" || isKnownPerson(subject) {
            return .run(Intent(
                originalQuestion: question,
                ast: .graph(.init(people: [subject], operation: .biography)),
                playAfterAnswer: playAfterAnswer))
        }
        // Lineage shapes the translator has no vocabulary for ("maternal
        // line back 5 generations", "the Latta family tree", "trace the
        // family back to Ireland", "what is GEDCOM") — answered from the
        // graph with a card attached (2026-08-22). A nil answer means the
        // shape was not really ours (e.g. "family tree for Donna" is a
        // person, not a surname) and the question continues as typed.
        // "show more" right after a birthplace trail that ran past a page
        // (2026-09-02): the next page of the SAME walk, from memory. Any
        // other "show more" goes on to the follow-up lane as before.
        if let lineageAnswer, ArchivistFollowUpResolver.isPagingPhrase(question),
           let page = HallieLineageQuestion.birthplaceTrailContinuation(
               queryDescription: memory.lastExchange?.queryDescription),
           let answer = lineageAnswer(page) {
            return .answer(answer)
        }
        if let lineage = HallieLineageQuestion.detect(question),
           let turn = lineageTurn(lineage, question: question, playAfterAnswer: playAfterAnswer,
                                  memory: memory, lineageAnswer: lineageAnswer) {
            return turn
        }
        return nil
    }

    /// The model-free lanes answered from the catalog's own summaries:
    /// the relationships overview, research findings, the roster,
    /// provenance of the last answer, catalog-wide counts. Nil when none
    /// claims the question.
    private static func catalogLaneTurn(
        question: String,
        memory: ConversationMemory,
        catalogStats: HallieCatalogStats?,
        rosterAnswer: ((PeopleTab.RosterScope) -> Result)?,
        relationshipsOverview: ((HallieRelationshipsOverview.Ask) -> Result)?,
        researchAnswer: ((HallieResearchQuestion) -> Result)?
    ) -> PreTranslation? {
        // "how am I related to the people in the People tab?" — one subject
        // against the whole tab, from the kinship engine (live miss #12).
        // Ahead of the roster, which would otherwise catch "tell … people tab".
        if let relationshipsOverview, let ask = HallieRelationshipsOverview.detect(question) {
            return .answer(relationshipsOverview(ask))
        }
        // "what do we know about David Latta from research" — the confirmed
        // Research Person findings only, cited (2026-08-29). Ahead of the
        // roster and the translator: "research" is not a search term.
        if let researchAnswer, let ask = HallieResearchQuestion.detect(question) {
            return .answer(researchAnswer(ask))
        }
        // "who do you know?" is the wider knowledge summary; "people in
        // the catalog" is the People-tab roster only. Both are answered
        // locally, and the explicit scope prevents catalog wording from
        // leaking tree-only or family-told names.
        if let rosterAnswer, let scope = PeopleTab.rosterScope(for: question, memory: memory) {
            return .answer(rosterAnswer(scope))
        }
        // "Where did that come from?" — answered from the last answer's own
        // trail, never by the model.
        if let kind = HallieProvenanceFollowUp.detect(question) {
            return .answer(HallieProvenanceFollowUp.answer(kind, provenance: memory.lastProvenance))
        }
        // "how many are archived" / "how much footage altogether": the
        // client hands in the catalog snapshot only when the question is
        // catalog-wide (HallieCatalogStats.detect), so this is O(1) here.
        if let stats = catalogStats, let question = HallieCatalogStats.detect(question) {
            return .answer(HallieCatalogStats.answer(question, stats: stats))
        }
        return nil
    }

    /// The follow-up resolver's verdict turned into a turn: a media action
    /// on the last answer, paging, a date-ordered re-run, a refinement,
    /// or — when nothing was claimed — the translator.
    private static func followUpTurn(
        question: String,
        playAfterAnswer: Bool,
        memory: ConversationMemory,
        isKnownPerson: (String) -> Bool
    ) -> PreTranslation {
        let resolution = ArchivistFollowUpResolver.resolve(
            question, snapshot: memory.followUpSnapshot,
            isKnownPerson: isKnownPerson)
        switch resolution {
        case .none:
            // "when did they get married" after "who did Rick marry": the
            // pronoun stands for the last answer's people; say so to the
            // translator instead of letting it guess (HalliePronounContinuity).
            if let rewrite = HalliePronounContinuity.rewrite(question, lastPeople: memory.pronounReferents) {
                return .translate(question: rewrite.question, playAfterAnswer: playAfterAnswer)
            }
            return .translate(question: question, playAfterAnswer: playAfterAnswer)

        case .searchThenPlay(let remainder):
            return .translate(question: remainder, playAfterAnswer: true)

        case .mediaAction(let verb, let indices):
            let citations = memory.lastResultSet?.citations ?? []
            let chosen = indices.compactMap { citations.indices.contains($0) ? citations[$0] : nil }
            guard !chosen.isEmpty else {
                return .answer(followUpDecline(
                    "Ask me for something first, then I can \(verb.rawValue) one of them."))
            }
            return .answer(mediaActionAnswer(
                verb: verb, indices: indices, chosen: chosen, source: "my last answer"))

        case .dateOrdered(let order, let ordinal, let verb):
            return dateOrderedTurn(
                order: order, ordinal: ordinal, verb: verb,
                question: question, playAfterAnswer: playAfterAnswer, memory: memory)

        case .nextPage:
            guard let last = memory.lastResultSet else {
                return .answer(followUpDecline(
                    "Ask me for something first, then I can show you more of it."))
            }
            return .run(Intent(
                originalQuestion: question,
                ast: last.ast,
                playAfterAnswer: false,
                citationOffset: last.shownCount,
                refinementNote: "continuing your last question (items \(last.shownCount + 1) on)"))

        case .refine(let ast, let chain, let whatChanged):
            return .run(Intent(
                originalQuestion: question,
                ast: ast,
                playAfterAnswer: playAfterAnswer,
                citationOffset: 0,
                refinementNote: "refining: \(chain.description)",
                refinementChain: chain,
                refinementChange: whatChanged))

        case .localQuery(let ast):
            return .run(Intent(
                originalQuestion: question, ast: ast,
                playAfterAnswer: playAfterAnswer))

        case .declineNoPriorResult(let verb):
            return declineNoPriorResultTurn(
                verb: verb, question: question, playAfterAnswer: playAfterAnswer,
                memory: memory, isKnownPerson: isKnownPerson)

        case .declineOutOfRange(let requested, let available):
            return .answer(followUpDecline(
                "My last answer listed \(available) item\(available == 1 ? "" : "s"), "
                + "so there is no number \(requested)."))

        case .declineNoMatchingItem(let what):
            return .answer(followUpDecline(
                "None of the items in my last answer is from \(what)."))

        case .declineNothingMore(let total):
            return .answer(followUpDecline(
                "That's all of them — I've already shown all \(total)."))

        case .declineNotRefinable(let reason):
            return .answer(followUpDecline(
                "I can't refine my last answer that way — \(reason). Ask it as a new question and I'll look it up."))

        case .declineUninterpretable(let fragment):
            return .answer(followUpDecline(
                "I couldn't tell how “\(fragment)” narrows down my last answer. "
                + "You can add a person (“with Donna”), a place or topic (“in Westford”, "
                + "“playing guitar”), or a time (“around 2005”, “in the 90s”) — or say "
                + "“help” to see what I can do.",
                offeredActions: [
                    .ask(question: "help", label: "Show me what I can ask"),
                    .ask(question: "start over", label: "Start over"),
                ]))
        }
    }

    /// "and the newest?": the last question, re-run sorted by date. A
    /// list, a count, and an age all leave one behind (memory).
    private static func dateOrderedTurn(
        order: ArchivistFollowUpResolver.DateOrder,
        ordinal: Int,
        verb: ArchivistFollowUpResolver.MediaVerb?,
        question: String,
        playAfterAnswer: Bool,
        memory: ConversationMemory
    ) -> PreTranslation {
        guard let scope = memory.lastRefinable else {
            return .answer(followUpDecline(
                "Ask me for something first — a search or a count — and then I can pick the "
                + (order == .newestFirst ? "newest" : "oldest") + " of it."))
        }
        let ast: ArchivistQueryAST
        switch scope {
        case .list(let last, _): ast = last
        case .wholeCatalog: ast = .presence(.init(mediaKind: nil))
        }
        let request = DateOrderRequest(
            order: order == .newestFirst ? .newestFirst : .oldestFirst,
            ordinal: ordinal, scope: scope)
        return .run(Intent(
            originalQuestion: question, ast: ast,
            playAfterAnswer: playAfterAnswer || verb == .play,
            refinementNote: "the last question sorted by date (\(order == .newestFirst ? "newest" : "oldest") first)",
            dateOrder: request))
    }

    /// "ok show me the second one" when the current result set is empty:
    /// the last list actually shown (a refinement that found nothing does
    /// not take the older list away), else the count or age the last
    /// answer still carries, re-run in date order; after a record turn
    /// that could not settle its file, an honest "nothing to play".
    private static func declineNoPriorResultTurn(
        verb: ArchivistFollowUpResolver.MediaVerb?,
        question: String,
        playAfterAnswer: Bool,
        memory: ConversationMemory,
        isKnownPerson: (String) -> Bool
    ) -> PreTranslation {
        if let verb {
            if let shown = memory.shownListSnapshot,
               case .mediaAction(let v, let indices) = ArchivistFollowUpResolver.resolve(
                   question, snapshot: shown, isKnownPerson: isKnownPerson),
               let citations = memory.lastShownList?.citations {
                let chosen = indices.compactMap { citations.indices.contains($0) ? citations[$0] : nil }
                if !chosen.isEmpty {
                    return .answer(mediaActionAnswer(
                        verb: v, indices: indices, chosen: chosen,
                        source: "the last list I showed you"))
                }
            }
            if let scope = memory.lastRefinable {
                let position = ArchivistFollowUpResolver.requestedPosition(in: question)
                let ast: ArchivistQueryAST
                switch scope {
                case .list(let last, _): ast = last
                case .wholeCatalog: ast = .presence(.init(mediaKind: nil))
                }
                let order: DateOrderRequest.Order = position.wantsLast ? .newestFirst : .oldestFirst
                return .run(Intent(
                    originalQuestion: question, ast: ast,
                    playAfterAnswer: playAfterAnswer || verb == .play,
                    refinementNote: "the last question sorted by date (\(order == .newestFirst ? "newest" : "oldest") first)",
                    dateOrder: DateOrderRequest(
                        order: order, ordinal: position.wantsLast ? 1 : (position.ordinal ?? 1),
                        scope: scope)))
            }
            // The record turn just before this could not settle its file,
            // and it emptied the playable memory on purpose (codex #976
            // item 2): say what is missing rather than reach further back.
            switch memory.lastRecordDecline {
            case .file(let name)?:
                return .answer(followUpDecline(
                    "Nothing to \(verb.rawValue) — I couldn't settle which file “\(name)” is. "
                    + "Name the file exactly as it appears in the Catalog, or select one there, "
                    + "and ask me again."))
            case .selection?:
                return .answer(followUpDecline(
                    "Nothing to \(verb.rawValue) — nothing was selected for my last answer. "
                    + "Name the file, or select one in the Catalog, and ask me again."))
            case nil:
                break
            }
        }
        let doing = verb.map { "\($0.rawValue) one of them" } ?? "refine it"
        return .answer(followUpDecline(
            "Ask me for something first, then I can \(doing)."))
    }

    /// "Playing item 2 from my last answer: “x.mov”." — the media-action
    /// answer, shared by the current result set and the last-shown fallback.
    private static func mediaActionAnswer(
        verb: ArchivistFollowUpResolver.MediaVerb,
        indices: [Int],
        chosen: [Citation],
        source: String
    ) -> Result {
        let kind: MediaActionRequest.Kind
        let verbText: String
        switch verb {
        case .play: kind = .play; verbText = "Playing"
        case .reveal: kind = .reveal; verbText = "Revealing"
        case .show: kind = .show; verbText = "Showing"
        }
        let names = chosen.map { "“\($0.filename)”" }
        let which = indices.count == 1
            ? "item \(indices[0] + 1) from \(source)"
            : "\(chosen.count) items from \(source)"
        return Result(
            route: .followUp,
            outcome: .answered,
            prose: "\(verbText) \(which): " + names.joined(separator: ", ") + ".",
            basisLine: source == "my last answer"
                ? "Basis: your last answer's cited items; no new search was run."
                : "Basis: the last list shown (the answer after it had nothing to show); no new search was run.",
            queryDescription: "follow-up \(verb.rawValue) "
                + indices.map { "#\($0 + 1)" }.joined(separator: ","),
            citations: chosen,
            catalogPersonName: nil,
            mediaAction: MediaActionRequest(kind: kind, citations: chosen))
    }

    private static func followUpDecline(
        _ prose: String, offeredActions: [OfferedAction] = []
    ) -> Result {
        Result(
            route: .followUp,
            outcome: .declined,
            prose: prose,
            basisLine: "Basis: conversation memory only; no catalog query or media action was performed.",
            queryDescription: nil,
            citations: [],
            catalogPersonName: nil,
            offeredActions: offeredActions)
    }

    /// Help card / small talk / reset — deterministic, never a decline.
    static func commandResult(_ command: ArchivistConversationCommand) -> Result {
        switch command {
        case .help(let topic):
            let examples = topic.map(ArchivistConversationCommand.helpExamples) ?? ArchivistConversationCommand.helpExamples
            return Result(
                route: .help,
                outcome: .answered,
                prose: topic.map(ArchivistConversationCommand.helpSection) ?? ArchivistConversationCommand.helpCard,
                basisLine: "Basis: help card; no model call, no catalog query.",
                queryDescription: "help",
                citations: [],
                catalogPersonName: nil,
                offeredActions: examples.map {
                    .ask(question: $0.question, label: $0.label)
                })
        case .smalltalk(let kind):
            return Result(
                route: .smalltalk,
                outcome: .answered,
                prose: ArchivistConversationCommand.smalltalkReply(kind),
                basisLine: "Basis: small talk; no model call, no catalog query.",
                queryDescription: "smalltalk",
                citations: [],
                catalogPersonName: nil)
        case .reset:
            return Result(
                route: .reset,
                outcome: .answered,
                prose: ArchivistConversationCommand.resetReply,
                basisLine: "Basis: conversation memory cleared; no model call, no catalog query.",
                queryDescription: "reset",
                citations: [],
                catalogPersonName: nil,
                offeredActions: [.ask(question: "help", label: "Show me what I can ask")])
        }
    }

    /// The honest capability answer. No model call, no evidence lookup; the
    /// offered next step is a chip/line, never performed automatically.
    static func capabilityResult(_ question: ArchivistCapabilityQuestion) -> Result {
        switch question {
        case .editKnowledge(let subject):
            let offer: [OfferedAction] = subject.map {
                [.ask(question: "who is \($0)?", label: "Show what I have for \($0)")]
            } ?? []
            let tail = subject.map { " Want me to show what I currently have for \($0) instead?" }
                ?? " Ask me about someone and I'll show what I currently have."
            return Result(
                route: .capability,
                outcome: .unsupported,
                prose: "I can't edit biographies or family facts yet — Rick maintains "
                    + "the family knowledge (CyberBrain) by hand today; interviewing "
                    + "and edits through me are on the roadmap." + tail,
                basisLine: "Basis: capability answer; no model call, no catalog query, nothing was changed.",
                queryDescription: "capability edit-knowledge",
                citations: [],
                catalogPersonName: nil,
                offeredActions: offer)
        case .unsupportedMediaAction(let verb):
            return Result(
                route: .capability,
                outcome: .unsupported,
                prose: "Not yet — I can't \(verb) media files; I'm read-only. "
                    + "What I can do: find clips by person, year, place, or spoken "
                    + "words; count them; play, reveal, or show a cited one; and "
                    + "answer family-tree questions.",
                basisLine: "Basis: capability answer; no model call, no catalog query, no media action.",
                queryDescription: "capability unsupported-action \(verb)",
                citations: [],
                catalogPersonName: nil)
        case .playback:
            return Result(
                route: .capability,
                outcome: .answered,
                prose: "Yes — tell me what you'd like to see and I'll find it and play it. "
                    + "For example, say “play Donna at Christmas”, and I'll play the first match; "
                    + "or ask “show me the boys at the Cape” first and then say “play the first one”.",
                basisLine: "Basis: capability answer; no model call, no catalog query, no media action.",
                queryDescription: "capability playback",
                citations: [],
                catalogPersonName: nil,
                offeredActions: [.ask(question: "play Donna at Christmas", label: "Play Donna at Christmas")])
        case .searchHelp:
            return Result(
                route: .capability,
                outcome: .answered,
                prose: "Both. I can find things in the archive by person, year or decade, place, "
                    + "and spoken or visible words — “show me Donna in the 90s”, “videos at the Cape”, "
                    + "“where does someone say happy birthday”. And I can tell you about the family "
                    + "from the tree and what I've been told — “who is Donna's mother”, "
                    + "“tell me about Dad Breen”, “how am I related to Rick”.",
                basisLine: "Basis: capability answer; no model call, no catalog query, no media action.",
                queryDescription: "capability search-help",
                citations: [],
                catalogPersonName: nil,
                offeredActions: [.ask(question: "show me Donna in the 90s", label: "Show Donna in the 90s")])
        }
    }

    /// One label per offered action, shared by the app's chips and the shell
    /// / transcript log.
    static func offerLabel(_ action: OfferedAction) -> String {
        switch action {
        case .openFamilyTree(let name): return "Open in Family Tree: \(name)"
        case .openFamilyTreePerson(_, let name): return "Open in Family Tree: \(name)"
        case .openFamilyTreeSurname(let surname): return "Open in Family Tree: the \(surname)s"
        case .getFamilyTree: return "Get Family Tree…"
        case .ask(_, let label): return label
        case .recompileFamilyTree: return "Recompile the family tree"
        case .openPeopleTab: return "Open the People tab"
        case .openAppDestination(let destination): return "Open the \(destination.title) tab"
        case .showPossibleDuplicate: return "Show possible duplicate in Family Tree"
        }
    }

    /// Whether this AST needs presence snapshots / aggregate snapshots /
    /// identity sources loaded — the client uses it to capture only what a
    /// turn touches.
    static func needsPresenceRecords(_ ast: ArchivistQueryAST) -> Bool {
        switch route(ast) {
        case .presence, .cross: return true
        default: return false
        }
    }
}

extension HallieTurnExecutor.Result {
    /// The same result with a note in front of the basis line ("Basis: reading
    /// “ricks” as “rick’s”; …"). Used for local rewrites so they are visible.
    func prefixingBasis(_ note: String) -> HallieTurnExecutor.Result {
        var basis = basisLine
        var prefixed = false
        for prefix in ["Basis: ", "Checked: "] where basis.hasPrefix(prefix) {
            basis = prefix + note + "; " + basis.dropFirst(prefix.count)
            prefixed = true
            break
        }
        if !prefixed { basis = "Basis: " + note + "; " + basis }
        return HallieTurnExecutor.Result(
            route: route,
            outcome: outcome,
            prose: prose,
            basisLine: basis,
            queryDescription: queryDescription,
            citations: citations,
            knowledgeCitations: knowledgeCitations,
            catalogPersonName: catalogPersonName,
            clarification: clarification,
            matchCount: matchCount,
            mediaAction: mediaAction,
            offeredActions: offeredActions,
            answerPlan: answerPlan,
            composedBy: composedBy,
            transcriptText: transcriptText,
            attachments: attachments,
            performsFirstOfferedAction: performsFirstOfferedAction,
            immediateOfferedAction: immediateOfferedAction,
            refinableQuery: refinableQuery)
    }
}
