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
        /// The last executed AST, list or not — the thing "and in the 90s?"
        /// refines.
        private(set) var lastAST: ArchivistQueryAST?
        /// The cumulative refinement chain behind `lastAST` ("rick + guitar +
        /// westford · around 2005"); the base chain for a fresh question.
        private(set) var lastChain: ArchivistFollowUpResolver.Chain?
        /// Convenience context for callers: people and years of the last AST.
        private(set) var lastPeople: [String] = []
        private(set) var lastYears: ClosedRange<Int>?

        init() {}

        /// Forget everything ("start over").
        mutating func reset() {
            self = ConversationMemory()
        }

        /// Record an executed turn. Follow-up media actions, help, small
        /// talk and capability answers carry no AST and leave memory
        /// untouched; a reset clears it; a refined or paged query replaces
        /// it like any other.
        mutating func record(intent: Intent?, result: Result) {
            if result.route == .reset {
                reset()
                return
            }
            guard let intent else { return }
            let ast = intent.ast
            lastAST = ast
            lastChain = intent.refinementChain
                ?? (intent.citationOffset > 0 ? lastChain : nil)
                ?? ArchivistFollowUpResolver.Chain.base(for: ast)
            (lastPeople, lastYears) = Self.context(of: ast)
            switch result.route {
            case .presence, .cross, .aggregate:
                if result.outcome == .answered {
                    lastResultSet = ResultSet(
                        ast: ast,
                        citations: result.citations,
                        shownCount: intent.citationOffset + result.citations.count,
                        totalMatchCount: result.matchCount ?? result.citations.count)
                } else if intent.citationOffset == 0 {
                    // A fresh list question with no evidence: there is no
                    // "one of them" any more.
                    lastResultSet = nil
                }
            case .temporal, .graph, .unsupportedEvent, .followUp, .capability,
                 .help, .smalltalk, .reset:
                break
            }
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

    /// The decision taken before translation.
    enum PreTranslation: Sendable, Equatable {
        /// Nothing local applies; translate the question as typed.
        case translate(question: String, playAfterAnswer: Bool)
        /// Execute this intent (refined / paged / locally-shaped AST).
        case run(Intent)
        /// A complete answer with no translation and no evidence lookup.
        case answer(Result)
    }

    /// Runs the model-free resolvers in order: help / small talk / reset →
    /// capability question → follow-up on the last answer → nothing. Pure
    /// given its inputs.
    static func preTranslation(
        question: String,
        playAfterAnswer: Bool,
        memory: ConversationMemory,
        isKnownPerson: (String) -> Bool
    ) -> PreTranslation {
        // Capability first: "how do i change donna's bio" is a capability
        // question, and only then is "how do i …" a how-to for the help card.
        if let capability = ArchivistCapabilityQuestion.detect(question) {
            return .answer(capabilityResult(capability))
        }
        if let command = ArchivistConversationCommand.detect(question) {
            return .answer(commandResult(command))
        }
        let resolution = ArchivistFollowUpResolver.resolve(
            question, snapshot: memory.followUpSnapshot,
            isKnownPerson: isKnownPerson)
        switch resolution {
        case .none:
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
            let kind: MediaActionRequest.Kind
            let verbText: String
            switch verb {
            case .play: kind = .play; verbText = "Playing"
            case .reveal: kind = .reveal; verbText = "Revealing"
            case .show: kind = .show; verbText = "Showing"
            }
            let names = chosen.map { "“\($0.filename)”" }
            let which = indices.count == 1
                ? "item \(indices[0] + 1) from my last answer"
                : "\(chosen.count) items from my last answer"
            return .answer(Result(
                route: .followUp,
                outcome: .answered,
                prose: "\(verbText) \(which): " + names.joined(separator: ", ") + ".",
                basisLine: "Basis: your last answer's cited items; no new search was run.",
                queryDescription: "follow-up \(verb.rawValue) "
                    + indices.map { "#\($0 + 1)" }.joined(separator: ","),
                citations: chosen,
                catalogPersonName: nil,
                mediaAction: MediaActionRequest(kind: kind, citations: chosen)))

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
            let doing = verb.map { "\($0.rawValue) one of them" } ?? "refine it"
            return .answer(followUpDecline(
                "Ask me for something first, then I can \(doing)."))

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
        case .help:
            return Result(
                route: .help,
                outcome: .answered,
                prose: ArchivistConversationCommand.helpCard,
                basisLine: "Basis: help card; no model call, no catalog query.",
                queryDescription: "help",
                citations: [],
                catalogPersonName: nil,
                offeredActions: ArchivistConversationCommand.helpExamples.map {
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
        }
    }

    /// One label per offered action, shared by the app's chips and the shell
    /// / transcript log.
    static func offerLabel(_ action: OfferedAction) -> String {
        switch action {
        case .openFamilyTree(let name): return "Open in Family Tree: \(name)"
        case .openFamilyTreeSurname(let surname): return "Open in Family Tree: the \(surname)s"
        case .ask(_, let label): return label
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
            transcriptText: transcriptText)
    }
}
