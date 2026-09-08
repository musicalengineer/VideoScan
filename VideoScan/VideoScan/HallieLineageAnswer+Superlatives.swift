// HallieLineageAnswer+Superlatives.swift
// "who was the oldest / youngest / longest-lived …" — the superlative
// answers over a scope of the tree.
// Moved out of HallieLineageQuestion.swift unchanged on 2026-09-07 night
// (codex #1182 item 2: result construction only). The section read no
// private member of its neighbours; nothing is widened.

import Foundation
import VideoScanCore

extension HallieLineageAnswer {
    // MARK: Superlatives

    /// First four-digit run in a raw GEDCOM date ("12 JUN 1888" → 1888).
    static func year(in raw: String?) -> Int? {
        guard let raw, let m = raw.firstMatch(of: /(\d{4})/) else { return nil }
        return Int(m.1)
    }

    static func scopePhrase(_ scope: HallieLineageQuestion.SuperlativeScope, person: GedcomFamilyGraph.Person?) -> String {
        switch scope {
        case .wholeTree: return "the family tree"
        case .surname(let s): return "the \(s.capitalized) family"
        case .ancestorsOf: return "\(HallieLineageQuestion.possessive(person?.name ?? "your")) ancestors"
        }
    }

    static func superlative(_ kind: HallieLineageQuestion.SuperlativeKind,
                            scope: HallieLineageQuestion.SuperlativeScope,
                            graph: GedcomFamilyGraph,
                            context: HallieTurnExecutor.Context) -> Result {
        // The people to rank, plus (for an ancestor scope) how many
        // generations up each one sits.
        var pool: [GedcomFamilyGraph.Person] = []
        var generationOf: [String: Int] = [:]
        var anchor: GedcomFamilyGraph.Person? = nil
        var basisNote: String? = nil
        var scopeLabel = ""
        switch scope {
        case .wholeTree:
            pool = Array(graph.people.values)
        case .surname(let typed):
            let resolved = resolvedSurname(typed, graph: graph)
            pool = graph.people(withSurname: resolved)
            guard !pool.isEmpty else {
                return Result(route: .graph, outcome: .declined,
                              prose: "I don’t find anyone named \(typed.capitalized) in the family tree.",
                              basisLine: ArchivistBiographyPolicy.gedcomBasis,
                              queryDescription: "superlative: \(kind) surname=\(typed)", citations: [], catalogPersonName: nil)
            }
        case .ancestorsOf(let typed):
            switch resolve(typed, context: context, graph: graph) {
            case .failure(let r):
                return r ?? Result(route: .graph, outcome: .declined,
                                   prose: "I don’t find \(typed ?? "you") in the family tree.",
                                   basisLine: ArchivistBiographyPolicy.gedcomBasis,
                                   queryDescription: "superlative: \(kind) ancestors of \(typed ?? "owner")",
                                   citations: [], catalogPersonName: nil)
            case .success(let p, let note):
                anchor = p
                basisNote = note
                for gen in graph.ancestorLine(of: p, line: .both, generations: 60) {
                    for a in gen.people { pool.append(a); generationOf[a.id] = gen.generation }
                }
                guard !pool.isEmpty else {
                    return Result(route: .graph, outcome: .declined,
                                  prose: "The family tree records no parents for \(p.name), so there are no ancestors to rank.",
                                  basisLine: ArchivistBiographyPolicy.gedcomBasis + (note.map { " " + $0 } ?? ""),
                                  queryDescription: "superlative: \(kind) ancestors of \(p.name)",
                                  citations: [], catalogPersonName: p.name,
                                  offeredActions: [.openFamilyTreePerson(personID: p.id, personName: p.name)])
                }
            }
        }
        scopeLabel = scopePhrase(scope, person: anchor)

        // The ranking key per kind; nil = the record lacks the fact and
        // is not ranked. `higherIsBetter` picks max vs min.
        let key: (GedcomFamilyGraph.Person) -> Int?
        let higherIsBetter: Bool
        let fact: String            // what the key measures, for the prose
        let describeKey: (Int) -> String
        switch kind {
        case .earliestBorn:
            key = { $0.birthYear }; higherIsBetter = false; fact = "earliest birth year"
            describeKey = { "born \($0)" }
        case .latestBorn:
            key = { $0.birthYear }; higherIsBetter = true; fact = "latest birth year"
            describeKey = { "born \($0)" }
        case .longestLived:
            key = { p in
                guard let b = p.birthYear, let d = p.deathYear, d >= b else { return nil }
                return d - b
            }
            higherIsBetter = true; fact = "longest recorded life"
            describeKey = { "about \($0) years" }
        case .latestDied:
            key = { $0.deathYear }; higherIsBetter = true; fact = "most recent death"
            describeKey = { "died \($0)" }
        case .earliestMarried:
            key = { graph.marriages(of: $0).compactMap { Self.year(in: $0.date) }.min() }
            higherIsBetter = false; fact = "earliest recorded marriage"
            describeKey = { "married \($0)" }
        case .mostChildren:
            key = { let n = graph.relatives(.children, of: $0).count; return n > 0 ? n : nil }
            higherIsBetter = true; fact = "most recorded children"
            describeKey = { "\($0) child\($0 == 1 ? "" : "ren")" }
        case .deepestAncestor:
            key = { generationOf[$0.id] }; higherIsBetter = true; fact = "deepest recorded ancestor"
            describeKey = { "\($0) generations back" }
        case .firstBornIn(let place):
            let token = GedcomFamilyGraph.normalizedPlaceToken(place)
            key = { p in
                guard let where_ = p.birthPlace, GedcomFamilyGraph.place(where_, mentions: token) else { return nil }
                return p.birthYear
            }
            higherIsBetter = false; fact = "earliest birth in \(place)"
            describeKey = { "born \($0)" }
        }
        let ranked = pool.compactMap { p -> (GedcomFamilyGraph.Person, Int)? in
            key(p).map { (p, $0) }
        }
        guard let best = (higherIsBetter ? ranked.map(\.1).max() : ranked.map(\.1).min()) else {
            let what: String
            switch kind {
            case .firstBornIn(let place): what = "a birthplace in \(place)"
            case .longestLived: what = "both a birth and a death year"
            case .earliestMarried: what = "a marriage date"
            case .mostChildren: what = "any children"
            case .latestDied: what = "a death year"
            default: what = "a birth year"
            }
            return Result(route: .graph, outcome: .declined,
                          prose: "Nobody in \(scopeLabel) has \(what) recorded, so I can’t rank them by that.",
                          basisLine: ArchivistBiographyPolicy.gedcomBasis + " Looked at \(pool.count) people." + (basisNote.map { " " + $0 } ?? ""),
                          queryDescription: "superlative: \(kind) scope=\(scope)", citations: [], catalogPersonName: nil)
        }
        var winners: [GedcomFamilyGraph.Person] = []
        for (person, value) in ranked where value == best { winners.append(person) }
        winners.sort { a, b in a.name == b.name ? a.id < b.id : a.name < b.name }
        let shown: [GedcomFamilyGraph.Person] = Array(winners.prefix(3))
        func bio(_ p: GedcomFamilyGraph.Person) -> String {
            ArchivistBiographyPolicy.biography(personID: p.id, in: graph).text
        }
        var sentences: [String] = []
        let keyText = describeKey(best)
        if shown.count == 1 {
            sentences.append("The \(fact) in \(scopeLabel) is \(keyText): \(bio(shown[0]))")
        } else {
            let bios: String = shown.map(bio).joined(separator: " ")
            let more: String = winners.count > shown.count ? " And \(winners.count - shown.count) more." : ""
            sentences.append("\(winners.count) people share the \(fact) in \(scopeLabel) (\(keyText)): " + bios + more)
        }
        if case .firstBornIn = kind, let place = shown[0].birthPlace {
            sentences.append("The record says \(place).")
        }
        let assets = FamilyAssetConfigurationCenter.shared.snapshot().makeStore()
        var attachments: [HallieAttachment] = []
        if let url = assets.photoURLs(for: shown[0]).first {
            attachments.append(.photo(HalliePhotoAttachment(personName: shown[0].name, fileURL: url)))
        }
        let names: String = shown.map { $0.name }.joined(separator: ", ")
        let basis: String = ArchivistBiographyPolicy.gedcomBasis
            + " Ranked \(ranked.count) of \(pool.count) people in \(scopeLabel) that record the fact."
            + (basisNote.map { " " + $0 } ?? "")
        let chips: [HallieTurnExecutor.OfferedAction] = shown.map {
            HallieTurnExecutor.OfferedAction.openFamilyTreePerson(personID: $0.id, personName: $0.name)
        }
        return Result(
            route: .graph, outcome: .answered,
            prose: sentences.joined(separator: " "),
            basisLine: basis,
            queryDescription: "superlative: \(kind) scope=\(scope) → \(names)",
            citations: [], catalogPersonName: shown[0].name,
            offeredActions: chips,
            attachments: attachments)
    }

    /// `lead` in front of another answer's prose; everything else (route,
    /// chips, attachments, basis) is the other answer's.
    static func prefixing(_ lead: String, to r: Result) -> Result {
        Result(route: r.route, outcome: r.outcome, prose: lead + " " + r.prose,
               basisLine: r.basisLine, queryDescription: r.queryDescription,
               citations: r.citations, knowledgeCitations: r.knowledgeCitations,
               catalogPersonName: r.catalogPersonName, clarification: r.clarification,
               matchCount: r.matchCount, mediaAction: r.mediaAction,
               offeredActions: r.offeredActions, answerPlan: r.answerPlan,
               composedBy: r.composedBy, transcriptText: r.transcriptText,
               attachments: r.attachments,
               performsFirstOfferedAction: r.performsFirstOfferedAction,
               immediateOfferedAction: r.immediateOfferedAction)
    }
}
