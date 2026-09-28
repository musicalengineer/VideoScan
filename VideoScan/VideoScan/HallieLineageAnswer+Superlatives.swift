// HallieLineageAnswer+Superlatives.swift
// "who was the oldest / youngest / longest-lived …" — the superlative
// answers over a scope of the tree.
// Moved out of HallieLineageQuestion.swift unchanged on 2026-09-07 night
// (codex #1182 item 2: result construction only). The section read no
// private member of its neighbours; nothing is widened.
//
// 2026-09-26 (live, Rick 20:46–20:49 ET): the scopes X's ancestors and
// X's descendants say what they ranked and how big it was — "among Rick's
// 6 recorded ancestors" — and every result carries the ranking it ran
// (`Result.superlative`) so the next turn can correct the scope. The
// whole-tree wording is unchanged to the byte.

import Foundation
import VideoScanCore

extension HallieLineageAnswer {
    // MARK: Superlatives

    /// First four-digit run in a raw GEDCOM date ("12 JUN 1888" → 1888).
    static func year(in raw: String?) -> Int? {
        guard let raw, let m = raw.firstMatch(of: /(\d{4})/) else { return nil }
        return Int(m.1)
    }

    /// How the scope is said, in the prose and in the basis line.
    struct ScopeWords {
        /// "in the family tree" / "among Rick Breen’s 6 recorded ancestors".
        let prose: String
        /// "14 people in the family tree" / "Rick Breen’s 6 recorded
        /// ancestors across 3 generations".
        let basis: String
    }

    static func scopePhrase(_ scope: HallieLineageQuestion.SuperlativeScope, person: GedcomFamilyGraph.Person?) -> String {
        switch scope {
        case .wholeTree: return "the family tree"
        case .surname(let s): return "the \(s.capitalized) family"
        case .ancestorsOf, .otherSideOf: return "\(HallieLineageQuestion.possessive(person?.name ?? "your")) ancestors"
        case .descendantsOf: return "\(HallieLineageQuestion.possessive(person?.name ?? "your")) descendants"
        }
    }

    /// The Context's asset lookup when one is injected (tests pass an
    /// empty or fixture one, GH #205); nil — production — is the published
    /// archive snapshot, exactly as before. Same seam as the GedcomAwareness
    /// photo answer.
    static func assetStore(for context: HallieTurnExecutor.Context) -> FamilyAssetStore {
        (context.assetConfiguration?() ?? FamilyAssetConfigurationCenter.shared.snapshot()).makeStore()
    }

    /// Which way a person scope walks.
    private enum Walk { case up, down }

    static func superlative(_ kind: HallieLineageQuestion.SuperlativeKind,
                            scope: HallieLineageQuestion.SuperlativeScope,
                            graph: GedcomFamilyGraph,
                            context: HallieTurnExecutor.Context) -> Result {
        typealias Ask = HallieLineageQuestion.SuperlativeAsk
        let spoken: (Int) -> String = { Self.spoken($0) }
        // The people to rank, plus (for an ancestor scope) how many
        // generations up each one sits.
        var pool: [GedcomFamilyGraph.Person] = []
        var generationOf: [String: Int] = [:]
        var anchor: GedcomFamilyGraph.Person? = nil
        var walk: Walk? = nil
        var basisNote: String? = nil
        /// The scope as RUN — a corrected "other side" becomes the
        /// ancestors it resolved to, so the payload names a real person.
        var ran = scope
        var words: ScopeWords
        switch scope {
        case .wholeTree:
            // The ruled view (codex #1710 (3)): a record Rick hid never wins.
            pool = graph.visiblePeople
            words = ScopeWords(prose: "in the family tree", basis: "\(pool.count) people in the family tree")
        case .surname(let typed):
            let resolved = resolvedSurname(typed, graph: graph)
            pool = graph.people(withSurname: resolved)
            guard !pool.isEmpty else {
                return Result(route: .graph, outcome: .declined,
                              prose: "I don’t find anyone named \(typed.capitalized) in the family tree.",
                              basisLine: ArchivistBiographyPolicy.gedcomBasis,
                              queryDescription: "superlative: \(kind) surname=\(typed)", citations: [], catalogPersonName: nil,
                              superlative: Ask(kind: kind, scope: scope))
            }
            let label = scopePhrase(scope, person: nil)
            words = ScopeWords(prose: "in \(label)", basis: "\(pool.count) people in \(label)")
        case .ancestorsOf(let typed):
            switch resolve(typed, context: context, graph: graph) {
            case .failure(let r):
                return attaching(Ask(kind: kind, scope: scope), to: r ?? Result(
                    route: .graph, outcome: .declined,
                    prose: "I don’t find \(typed ?? "you") in the family tree.",
                    basisLine: ArchivistBiographyPolicy.gedcomBasis,
                    queryDescription: "superlative: \(kind) ancestors of \(typed ?? "owner")",
                    citations: [], catalogPersonName: nil))
            case .success(let p, let note):
                anchor = p; basisNote = note; walk = .up
            }
            words = ScopeWords(prose: "", basis: "")   // filled after the walk
        case .descendantsOf(let typed):
            switch resolve(typed, context: context, graph: graph) {
            case .failure(let r):
                return attaching(Ask(kind: kind, scope: scope), to: r ?? Result(
                    route: .graph, outcome: .declined,
                    prose: "I don’t find \(typed ?? "you") in the family tree.",
                    basisLine: ArchivistBiographyPolicy.gedcomBasis,
                    queryDescription: "superlative: \(kind) descendants of \(typed ?? "owner")",
                    citations: [], catalogPersonName: nil))
            case .success(let p, let note):
                anchor = p; basisNote = note; walk = .down
            }
            words = ScopeWords(prose: "", basis: "")
        case .otherSideOf(let typed):
            // "that is donna's line" → the owner's ancestors; "that is my
            // line" → the spouse's. Nobody else's side has an "other".
            let owner: GedcomFamilyGraph.Person
            switch resolve(nil, context: context, graph: graph) {
            case .failure(let r):
                return attaching(Ask(kind: kind, scope: scope), to: r ?? Result(
                    route: .graph, outcome: .declined,
                    prose: "I can’t tell whose side is the other one — set the owner in Settings ▸ Archivist and ask again.",
                    basisLine: ArchivistBiographyPolicy.gedcomBasis + " No owner record could be pinned; nothing was ranked.",
                    queryDescription: "superlative: \(kind) other side, owner unresolved",
                    citations: [], catalogPersonName: nil))
            case .success(let o, _):
                owner = o
            }
            let named: GedcomFamilyGraph.Person
            switch resolve(typed, context: context, graph: graph) {
            case .failure(let r):
                return attaching(Ask(kind: kind, scope: scope), to: r ?? Result(
                    route: .graph, outcome: .declined,
                    prose: "I don’t find \(typed ?? "you") in the family tree.",
                    basisLine: ArchivistBiographyPolicy.gedcomBasis,
                    queryDescription: "superlative: \(kind) other side of \(typed ?? "owner")",
                    citations: [], catalogPersonName: nil))
            case .success(let p, _):
                named = p
            }
            let target: GedcomFamilyGraph.Person
            if named.id == owner.id {
                let spouses = graph.relatives(.spouse, of: owner)
                guard spouses.count == 1 else {
                    let how = spouses.isEmpty ? "records no spouse for \(owner.name)" : "records \(spouses.count) spouses for \(owner.name)"
                    return Result(route: .graph, outcome: .needsClarification,
                                  prose: "Whose side did you mean? The family tree \(how), so I can’t tell which side is the other one — name the person and I’ll rank their ancestors.",
                                  basisLine: ArchivistBiographyPolicy.gedcomBasis + " Nothing was ranked.",
                                  queryDescription: "superlative: \(kind) other side of the owner (no single spouse)",
                                  citations: [], catalogPersonName: nil,
                                  superlative: Ask(kind: kind, scope: scope))
                }
                target = spouses[0]
            } else {
                target = owner
            }
            anchor = target; walk = .up
            ran = .ancestorsOf(target.name)
            basisNote = "“\(typed.map { HallieLineageQuestion.possessive($0) } ?? "my")” side set aside; ranked the other side of the family — \(HallieLineageQuestion.possessive(target.name)) ancestors."
            words = ScopeWords(prose: "", basis: "")
        }

        // The person scopes: walk, count, and say so.
        var generations = 0
        if let anchor, let walk {
            switch walk {
            case .up:
                let line = graph.ancestorLine(of: anchor, line: .both, generations: 60)
                for gen in line {
                    for a in gen.people { pool.append(a); generationOf[a.id] = gen.generation }
                }
                generations = line.count
                guard !pool.isEmpty else {
                    return Result(route: .graph, outcome: .declined,
                                  prose: "The family tree records no parents for \(anchor.name), so there are no ancestors to rank.",
                                  basisLine: ArchivistBiographyPolicy.gedcomBasis + (basisNote.map { " " + $0 } ?? ""),
                                  queryDescription: "superlative: \(kind) ancestors of \(anchor.name)",
                                  citations: [], catalogPersonName: anchor.name,
                                  offeredActions: [.openFamilyTreePerson(personID: anchor.id, personName: anchor.name)],
                                  superlative: Ask(kind: kind, scope: ran))
                }
            case .down:
                func collect(_ node: GedcomFamilyGraph.DescendantNode, depth: Int) {
                    for child in node.children {
                        pool.append(child.person)
                        generationOf[child.person.id] = depth
                        generations = max(generations, depth)
                        collect(child, depth: depth + 1)
                    }
                }
                collect(graph.descendants(of: anchor, depth: 60), depth: 1)
                guard !pool.isEmpty else {
                    return Result(route: .graph, outcome: .declined,
                                  prose: "The family tree records no children for \(anchor.name), so there are no descendants to rank.",
                                  basisLine: ArchivistBiographyPolicy.gedcomBasis + (basisNote.map { " " + $0 } ?? ""),
                                  queryDescription: "superlative: \(kind) descendants of \(anchor.name)",
                                  citations: [], catalogPersonName: anchor.name,
                                  offeredActions: [.openFamilyTreePerson(personID: anchor.id, personName: anchor.name)],
                                  superlative: Ask(kind: kind, scope: ran))
                }
            }
            let noun = walk == .up ? "ancestor" : "descendant"
            let counted = "\(HallieLineageQuestion.possessive(anchor.name)) \(spoken(pool.count)) recorded \(noun)\(pool.count == 1 ? "" : "s")"
            words = ScopeWords(
                prose: "among \(counted)",
                basis: "\(counted) across \(generations) generation\(generations == 1 ? "" : "s")")
        }

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
                          prose: "Nobody \(words.prose) has \(what) recorded, so I can’t rank them by that.",
                          basisLine: ArchivistBiographyPolicy.gedcomBasis + " Looked at \(pool.count) people." + (basisNote.map { " " + $0 } ?? ""),
                          queryDescription: "superlative: \(kind) scope=\(ran)", citations: [], catalogPersonName: nil,
                          superlative: Ask(kind: kind, scope: ran))
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
            sentences.append("The \(fact) \(words.prose) is \(keyText): \(bio(shown[0]))")
        } else {
            let bios: String = shown.map(bio).joined(separator: " ")
            let more: String = winners.count > shown.count ? " And \(winners.count - shown.count) more." : ""
            sentences.append("\(winners.count) people share the \(fact) \(words.prose) (\(keyText)): " + bios + more)
        }
        if case .firstBornIn = kind, let place = shown[0].birthPlace {
            sentences.append("The record says \(place).")
        }
        let assets = assetStore(for: context)
        var attachments: [HallieAttachment] = []
        if let url = assets.photoURLs(for: shown[0]).first {
            attachments.append(.photo(HalliePhotoAttachment(personName: shown[0].name, fileURL: url)))
        }
        let names: String = shown.map { $0.name }.joined(separator: ", ")
        let basis: String = ArchivistBiographyPolicy.gedcomBasis
            + " Ranked \(ranked.count) of \(words.basis) that record the fact."
            + (basisNote.map { " " + $0 } ?? "")
        let chips: [HallieTurnExecutor.OfferedAction] = shown.map {
            HallieTurnExecutor.OfferedAction.openFamilyTreePerson(personID: $0.id, personName: $0.name)
        }
        return Result(
            route: .graph, outcome: .answered,
            prose: sentences.joined(separator: " "),
            basisLine: basis,
            queryDescription: "superlative: \(kind) scope=\(ran) → \(names)",
            citations: [], catalogPersonName: shown[0].name,
            offeredActions: chips,
            attachments: attachments,
            superlative: Ask(kind: kind, scope: ran))
    }

    /// The resolver's own answer (a which-one, "I don't find …") carrying
    /// the ranking it interrupted, so "I meant Rick Breen Jr" right after
    /// still knows what to rank.
    static func attaching(_ ask: HallieLineageQuestion.SuperlativeAsk, to r: Result) -> Result {
        Result(route: r.route, outcome: r.outcome, prose: r.prose,
               basisLine: r.basisLine, queryDescription: r.queryDescription,
               citations: r.citations, knowledgeCitations: r.knowledgeCitations,
               catalogPersonName: r.catalogPersonName, clarification: r.clarification,
               matchCount: r.matchCount, mediaAction: r.mediaAction,
               offeredActions: r.offeredActions, answerPlan: r.answerPlan,
               composedBy: r.composedBy, transcriptText: r.transcriptText,
               attachments: r.attachments,
               performsFirstOfferedAction: r.performsFirstOfferedAction,
               immediateOfferedAction: r.immediateOfferedAction,
               subjectLifeStatus: r.subjectLifeStatus,
               refinableQuery: r.refinableQuery,
               retryOffer: r.retryOffer,
               mode: r.mode,
               modeForce: r.modeForce,
               superlative: ask)
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
               immediateOfferedAction: r.immediateOfferedAction,
               subjectLifeStatus: r.subjectLifeStatus,
               refinableQuery: r.refinableQuery,
               retryOffer: r.retryOffer,
               mode: r.mode,
               modeForce: r.modeForce,
               superlative: r.superlative)
    }
}
