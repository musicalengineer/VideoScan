// HallieTurnExecutor+Event.swift
// The `event` shape, executed (2026-09-20). Rick, evening: "getting a lot of
// these: 'Event queries are not supported yet; I did not run a broader
// search.'" — for "show me videos of donna down the cape in the 90s", "show
// me Donna down the cape in the early 90s" (three times), "show me videos of
// donna down the cape" and even "show me ellen ronan". The local translator
// over-applies its "event: what happened at an event" rule to any
// person + place + era ask, and the executor's answer was a hard-coded
// refusal in every mode. These are the app's core catalog questions.
//
// `ArchivistQueryAST.Event` carries exactly the fields `Cross` does —
// people, years, media kind, visible keywords, spoken transcript terms —
// and `cross` has run on the presence executor since 2026-08-17. So an
// event is the same merge: spoken terms become keyword constraints (every
// keyword must be proven by SOME field, the basis names which), and the
// answer has the same shape, citations, offered actions and relaxed
// facets ("Donna in Westford" with nobody placed there still offers
// Donna's videos). The basis line says the shape was read as an event.
//
// The only decline is an event with nothing to search for — no people, no
// words, no years — and that one asks for the specifics instead of saying
// "not supported". Nothing here depends on the translator being nudged
// toward `presence`; the nudge (OllamaQueryTranslator.astSystemPrompt) is a
// courtesy, this is the guarantee.

import Foundation

extension HallieTurnExecutor {
    /// The presence query an event payload is: keywords + transcript terms
    /// merged, blanks dropped, empty lists nil. Pure; the tests build the
    /// presence AST by hand and expect the same catalog hits.
    static func presenceQuery(forEvent payload: ArchivistQueryAST.Event) -> ArchivistQueryAST.Presence {
        func trimmed(_ list: [String]?) -> [String]? {
            let kept = (list ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return kept.isEmpty ? nil : kept
        }
        let words = (trimmed(payload.keywords) ?? []) + (trimmed(payload.transcript) ?? [])
        return ArchivistQueryAST.Presence(
            people: trimmed(payload.people),
            yearStart: payload.yearStart,
            yearEnd: payload.yearEnd,
            mediaKind: payload.mediaKind,
            keywords: words.isEmpty ? nil : words)
    }

    /// True when the event names someone, something or some time to look
    /// for. A media kind alone ("videos") is not a search.
    static func eventIsActionable(_ payload: ArchivistQueryAST.Event) -> Bool {
        let presence = presenceQuery(forEvent: payload)
        return presence.people != nil || presence.keywords != nil
            || presence.yearStart != nil || presence.yearEnd != nil
    }

    /// "read as an event question; searched the catalog for Donna with
    /// “cape”, “90s” in 1990–1999" — the basis note for an executed event.
    static func eventBasisNote(_ payload: ArchivistQueryAST.Event) -> String {
        let presence = presenceQuery(forEvent: payload)
        var target: [String] = []
        if let people = presence.people {
            target.append(people.joined(separator: " and "))
        }
        if let words = presence.keywords {
            let quoted = words.map { "“\($0)”" }.joined(separator: ", ")
            target.append(target.isEmpty ? quoted : "with " + quoted)
        }
        switch (presence.yearStart, presence.yearEnd) {
        case (let start?, let end?) where start == end: target.append("in \(start)")
        case (let start?, let end?): target.append("in \(start)–\(end)")
        case (let start?, nil): target.append("from \(start)")
        case (nil, let end?): target.append("up to \(end)")
        case (nil, nil): break
        }
        return "read as an event question; searched the catalog for " + target.joined(separator: " ")
    }

    static func executeEvent(
        _ payload: ArchivistQueryAST.Event,
        request: Request,
        context: Context,
        dependencies: Dependencies
    ) async throws -> Result {
        guard eventIsActionable(payload) else {
            return Result(
                route: .event,
                outcome: .declined,
                prose: "I read that as a question about an event, but I need something to look for. "
                    + "Who or what should I look for, and roughly when?",
                basisLine: "Basis: the translator returned an event with no people, words or years; "
                    + "no catalog query was performed.",
                queryDescription: "shape=event (nothing to search for)",
                citations: [],
                catalogPersonName: nil)
        }
        let result = try await executePresenceLike(
            presenceQuery(forEvent: payload), route: .event, request: request,
            context: context, dependencies: dependencies)
        return result.prefixingBasis(eventBasisNote(payload))
    }
}
