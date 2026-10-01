// HallieAncestorStatisticsAnswer.swift
// The prose for statistics over the family's ancestor lines (GH #214, #200).
// Plan → phrase, deterministically: VideoScanCore's TreeLineStatistics does
// the arithmetic, this file only says it — and it is not allowed to drop a
// denominator, because every figure arrives with one.
//
//   "how many of our ancestors were born in New England vs Old England?"
//   → "Of our 13,406 recorded ancestors (your side 7,012, Donna's side
//      6,488; 94 are on both), 11,920 have a birthplace I can place. New
//      England: 2,140 (your side 1,500, Donna's side 680). Old England: …
//      1,486 have no birthplace I can place, so they aren't counted either
//      way."
//
// "Our" = the owner and the owner's partner (the tree's spouse, or the
// merged tree's other home person — the Family Tree walk's second start).
// No model is involved and none may add a fact.

import Foundation
import VideoScanCore

extension HallieLineageAnswer {

    // MARK: - Whose ancestors

    /// The one or two people whose lines are counted, and how to say them.
    struct AncestorSides {
        let people: [GedcomFamilyGraph.Person]
        /// The owner's record, when it is one of `people`.
        let ownerID: String?
        /// Basis-line notes (how "our" was read, owner pin notes).
        let notes: [String]

        var isOurs: Bool { people.count > 1 }

        /// "your" for the owner, "Donna's" for anyone else.
        func possessive(_ i: Int) -> String {
            people[i].id == ownerID ? "your"
                : HallieLineageQuestion.possessive(FamilyTreeLiveModel.firstGivenName(people[i]))
        }
        /// "your side" / "Donna's side".
        func side(_ i: Int) -> String { possessive(i) + " side" }
        /// "our" / "your" / "Donna Hudson's" — whose ancestors, collectively.
        var whose: String {
            if isOurs { return "our" }
            return people[0].id == ownerID ? "your" : HallieLineageQuestion.possessive(people[0].name)
        }
    }

    enum AncestorSidesOutcome {
        case ok(AncestorSides)
        case stop(Result)
    }

    /// Resolve "ours" / the owner / a named person through the same chain
    /// every lineage route uses. A typed name that IS the owner ("Rick's
    /// ancestors" said by Rick) is the owner alone.
    static func ancestorSides(_ who: HallieAncestorStatisticsQuestion.Who,
                              context: HallieTurnExecutor.Context,
                              graph: GedcomFamilyGraph,
                              ask: String) -> AncestorSidesOutcome {
        let ownerResolved = resolve(nil, context: context, graph: graph)
        var ownerID: String?
        var notes: [String] = []
        if case .success(let owner, let note) = ownerResolved {
            ownerID = owner.id
            if let note { notes.append(note) }
        }
        func ownerDecline(_ r: Result?) -> AncestorSidesOutcome {
            .stop(r ?? Result(
                route: .graph, outcome: .declined,
                prose: "I can’t tell whose ancestors to count — set the owner in Settings ▸ Archivist and ask again.",
                basisLine: ArchivistBiographyPolicy.gedcomBasis + " No owner record could be pinned; nothing was counted.",
                queryDescription: "\(ask): owner unresolved",
                citations: [], catalogPersonName: nil))
        }
        switch who {
        case .ours:
            guard case .success(let owner, _) = ownerResolved else {
                if case .failure(let r) = ownerResolved { return ownerDecline(r) }
                return ownerDecline(nil)
            }
            let partner = ancestorPartner(of: owner, graph: graph)
            notes.append(partner.note)
            return .ok(AncestorSides(people: [owner] + (partner.person.map { [$0] } ?? []),
                                     ownerID: owner.id, notes: notes))
        case .owner:
            guard case .success(let owner, _) = ownerResolved else {
                if case .failure(let r) = ownerResolved { return ownerDecline(r) }
                return ownerDecline(nil)
            }
            return .ok(AncestorSides(people: [owner], ownerID: owner.id, notes: notes))
        case .person(let typed):
            switch resolve(typed, context: context, graph: graph) {
            case .failure(let r):
                return .stop(r ?? Result(
                    route: .graph, outcome: .declined,
                    prose: "I don’t find \(typed) in the family tree, so I can’t count their ancestors.",
                    basisLine: ArchivistBiographyPolicy.gedcomBasis + " Nothing was counted.",
                    queryDescription: "\(ask): resolve \(typed)",
                    citations: [], catalogPersonName: nil))
            case .success(let person, let note):
                if let note { notes.append(note) }
                return .ok(AncestorSides(people: [person], ownerID: ownerID, notes: notes))
            }
        }
    }

    /// The owner's partner for "our": a spouse who is also the merged
    /// tree's other home person, else the one recorded spouse, else the
    /// other home person (the Family Tree walk's second start). With none
    /// of those, the owner's line alone — and the note says why.
    static func ancestorPartner(of owner: GedcomFamilyGraph.Person,
                                graph: GedcomFamilyGraph) -> (person: GedcomFamilyGraph.Person?, note: String) {
        let spouses = graph.relatives(.spouse, of: owner).filter { !graph.isHidden($0.id) }
        let otherRoots = graph.roots.filter { $0.id != owner.id && !graph.isHidden($0.id) }
        let ownerIsRoot = graph.roots.contains { $0.id == owner.id }
        if ownerIsRoot, let both = otherRoots.first(where: { r in spouses.contains { $0.id == r.id } }) {
            return (both, "“Our” = you and \(both.name), your spouse and the tree’s other home person.")
        }
        if spouses.count == 1 {
            return (spouses[0], "“Our” = you and \(spouses[0].name), your spouse in the tree.")
        }
        if ownerIsRoot, otherRoots.count == 1 {
            return (otherRoots[0], "“Our” = you and \(otherRoots[0].name), the tree’s other home person.")
        }
        if spouses.count > 1 {
            return (nil, "The tree records \(spouses.count) spouses for you, so “our” was counted as your line only — name one (“Donna’s ancestors”) for theirs.")
        }
        return (nil, "The tree records no spouse for you, so “our” was counted as your line only.")
    }

    // MARK: - The answer

    static func ancestorStatistics(_ ask: HallieAncestorStatisticsQuestion,
                                   context: HallieTurnExecutor.Context) -> Result {
        guard let graph = context.graph else { return noTree(context) }
        let label = "ancestor statistics"
        let sides: AncestorSides
        switch ancestorSides(ask.who, context: context, graph: graph, ask: label) {
        case .stop(let r): return r
        case .ok(let s): sides = s
        }
        guard let population = TreeLineStatistics.ancestors(of: sides.people.map(\.id), in: graph) else {
            return Result(route: .graph, outcome: .declined,
                          prose: "I can’t walk that line — the record is hidden or missing from the loaded tree.",
                          basisLine: ArchivistBiographyPolicy.gedcomBasis + " Nothing was counted.",
                          queryDescription: "\(label): population unavailable", citations: [], catalogPersonName: nil)
        }
        let chipsForSides: [HallieTurnExecutor.OfferedAction] = sides.people.map {
            .openFamilyTreePerson(personID: $0.id, personName: $0.name)
        }
        guard !population.members.isEmpty else {
            let names = HallieNameQualifier.joined(sides.people.map(\.name), conjunction: "or")
            return Result(route: .graph, outcome: .declined,
                          prose: "The family tree records no parents for \(names), so there are no ancestors to count. Get Family Tree can pull that ancestry from FamilySearch.",
                          basisLine: ArchivistBiographyPolicy.gedcomBasis + " Nothing was counted.",
                          queryDescription: "\(label): no ancestors", citations: [], catalogPersonName: nil,
                          offeredActions: chipsForSides + [.getFamilyTree])
        }
        let composed: (prose: String, people: [TreeLineStatistics.Member], what: String)
        switch ask {
        case .birthplaces(_, let places):
            composed = (birthplaceProse(TreeLineStatistics.birthplaces(population, places: places.map(\.place)),
                                        labels: places.map(\.label), sides: sides, population: population),
                        [], "birthplaces " + places.map(\.label).joined(separator: ", "))
        case .ageAtDeath:
            let report = TreeLineStatistics.ageAtDeath(population)
            composed = (ageProse(report, sides: sides, population: population, graph: graph),
                        report?.oldest ?? [], "age at death")
        case .deepestLine:
            let lines = TreeLineStatistics.deepestLines(population)
            composed = (deepestProse(lines, sides: sides, graph: graph), lines.compactMap { $0?.ancestor }, "deepest line")
        case .earliest:
            let union = TreeLineStatistics.earliest(population)
            let perSide = sides.isOurs ? population.sides.indices.map { TreeLineStatistics.earliest(population, side: $0) } : []
            composed = (earliestProse(union, perSide: perSide, sides: sides, population: population, graph: graph),
                        union.people, "earliest ancestor")
        }
        let whoText = sides.people.map(\.name).joined(separator: " and ")
        let basis = ArchivistBiographyPolicy.gedcomBasis
            + " Counted over the recorded ancestors of \(whoText) (the Family Tree walk’s lines: each person once, at their nearest generation); every figure names the population it was drawn from and what was left out."
            + (sides.notes.isEmpty ? "" : " " + sides.notes.joined(separator: " "))
        let chips: [HallieTurnExecutor.OfferedAction] = composed.people.prefix(3).map {
            .openFamilyTreePerson(personID: $0.id, personName: $0.name)
        }
        return Result(route: .graph, outcome: .answered,
                      prose: composed.prose,
                      basisLine: basis,
                      queryDescription: "\(label): \(composed.what) of \(whoText) → \(spoken(population.members.count)) ancestors",
                      citations: [], catalogPersonName: composed.people.first?.name,
                      offeredActions: chips)
    }

    // MARK: - Words

    /// "our 11 recorded ancestors (your side 8, Beth's side 4; 1 is on both)"
    /// / "your 2 recorded ancestors" / "Beth Sample's 4 recorded ancestors".
    static func ancestorPopulationPhrase(_ sides: AncestorSides, _ population: TreeLineStatistics.Population) -> String {
        let n = population.members.count
        var phrase = "\(sides.whose) \(spoken(n)) recorded ancestor\(n == 1 ? "" : "s")"
        if sides.isOurs {
            var parts = population.sides.indices.map { "\(sides.side($0)) \(spoken(population.count(onSide: $0)))" }
                .joined(separator: ", ")
            let shared = population.sharedCount
            if shared > 0 { parts += "; \(spoken(shared)) \(shared == 1 ? "is" : "are") on both" }
            phrase += " (\(parts))"
        }
        return phrase
    }

    private static func perSideCounts(_ counts: [Int], _ sides: AncestorSides) -> String {
        guard sides.isOurs else { return "" }
        return " (" + counts.indices.map { "\(sides.side($0)) \(spoken(counts[$0]))" }.joined(separator: ", ") + ")"
    }

    static func birthplaceProse(_ r: TreeLineStatistics.PlaceReport, labels: [String],
                                sides: AncestorSides, population: TreeLineStatistics.Population) -> String {
        let pop = ancestorPopulationPhrase(sides, population)
        var sentences: [String] = []
        let notPlaced = r.unplaced > 0
            ? "\(spoken(r.unplaced)) \(r.unplaced == 1 ? "has" : "have") no birthplace I can place — none recorded, or a name that can’t be pinned to one place — so \(r.unplaced == 1 ? "it isn’t" : "they aren’t") counted either way."
            : "Every one of them has a birthplace I can place."
        if r.rows.count == 1 && !sides.isOurs {
            // One place, one line: the plain count first, the way the
            // whole-tree route says it ("1 of your 2 recorded ancestors …").
            let row = r.rows[0]
            sentences.append("\(spoken(row.total)) of \(pop) \(row.total == 1 ? "was" : "were") born in \(labels[0]).")
            let tail = String(notPlaced.prefix(1)).lowercased() + String(notPlaced.dropFirst())
            sentences.append("Of the \(spoken(r.considered)), \(spoken(r.placed)) \(r.placed == 1 ? "has" : "have") a birthplace I can place; " + tail)
            return sentences.joined(separator: " ")
        }
        sentences.append("Of \(pop), \(spoken(r.placed)) \(r.placed == 1 ? "has" : "have") a birthplace I can place.")
        for (i, row) in r.rows.enumerated() {
            sentences.append("\(labels[i]): \(spoken(row.total))\(perSideCounts(row.perSide, sides)).")
        }
        if r.rows.count == 2 {
            let a = r.rows[0].total, b = r.rows[1].total
            if a > 0, b > 0, a != b {
                let (more, less) = a > b ? (0, 1) : (1, 0)
                sentences.append("\(labels[more]) outnumbers \(labels[less]) \(spoken(max(a, b))) to \(spoken(min(a, b))).")
            } else if a == b, a > 0 {
                sentences.append("The two are even.")
            }
        }
        if r.elsewhere > 0 {
            sentences.append("\(spoken(r.elsewhere)) more \(r.elsewhere == 1 ? "was" : "were") born somewhere else.")
        }
        sentences.append(notPlaced)
        if sides.isOurs, population.sharedCount > 0 {
            sentences.append("Someone on both sides counts once in each total and on each side.")
        }
        return sentences.joined(separator: " ")
    }

    static func ageProse(_ report: TreeLineStatistics.AgeReport?, sides: AncestorSides,
                         population: TreeLineStatistics.Population, graph: GedcomFamilyGraph) -> String {
        let pop = ancestorPopulationPhrase(sides, population)
        guard let r = report, r.usable > 0 else {
            return "None of \(pop) has birth and death dates close enough to work out an age at death, so I can’t give an average."
                + leftOutSentence(report)
        }
        var s = "Across the \(spoken(r.usable)) of \(pop) whose birth and death dates pin an age within \(TreeLineStatistics.maxAgeSpread) years, "
            + "the average age at death is \(spoken(r.mean)) and the median \(spoken(r.median))"
        if sides.isOurs {
            let parts = r.perSide.indices.map { i -> String in
                let side = r.perSide[i]
                return side.usable == 0 ? "\(sides.side(i)) none to measure"
                    : "\(sides.side(i)) \(spoken(side.mean)) over \(spoken(side.usable))"
            }
            s += " (" + parts.joined(separator: ", ") + ")"
        }
        s += "."
        if let first = r.oldest.first, let age = first.ageAtDeath, let person = graph.people[first.id] {
            let others = r.oldestTies - 1
            // The dates prove a range: "96" when exact, "96 or 97" for a
            // year-only pair, "about 70–74" when wider.
            let ageWords = age.isExact ? "\(age.minYears)"
                : age.maxYears - age.minYears == 1 ? "\(age.minYears) or \(age.maxYears)"
                : "about \(age.minYears)–\(age.maxYears)"
            s += " The longest proven life is \(first.name)\(HalliePersonVitals.parenthetical(person, places: false)), who died at \(ageWords)"
                + (others > 0 ? " — \(spoken(others)) more reached the same age." : ".")
        }
        return s + leftOutSentence(r)
    }

    /// " Left out: 3 with no birth or death date, 1 whose dates are too
    /// vague, and 1 recorded age over 110 (likely a transcription error)."
    private static func leftOutSentence(_ r: TreeLineStatistics.AgeReport?) -> String {
        guard let r else { return "" }
        var parts: [String] = []
        if r.missingDates > 0 { parts.append("\(spoken(r.missingDates)) with no birth or death date") }
        if r.tooVague > 0 { parts.append("\(spoken(r.tooVague)) whose dates are too vague to pin an age") }
        if r.implausible > 0 {
            parts.append("\(spoken(r.implausible)) recorded age\(r.implausible == 1 ? "" : "s") over \(TreeLineStatistics.maxPlausibleAge) or below zero (likely transcription errors)")
        }
        guard !parts.isEmpty else { return "" }
        return " Left out: " + HallieNameQualifier.joined(parts, conjunction: "and") + "."
    }

    static func deepestProse(_ lines: [TreeLineStatistics.DeepestLine?], sides: AncestorSides,
                             graph: GedcomFamilyGraph) -> String {
        var sentences: [String] = []
        var deepest = 0
        for (i, line) in lines.enumerated() {
            let whose = sides.possessive(i)
            let cap = whose.prefix(1).uppercased() + whose.dropFirst()
            guard let line else {
                sentences.append("\(cap) side records no parents, so there is no line to measure.")
                continue
            }
            deepest = max(deepest, line.generations)
            let a = line.ancestor
            let person = graph.people[a.id]
            let vitals = person.map { HalliePersonVitals.parenthetical($0, places: false) } ?? ""
            let relation = GedcomFamilyGraph.generationLabel(generations: line.generations, sex: a.sex)
            var sentence = "\(cap) deepest recorded line goes back \(spoken(line.generations)) generation\(line.generations == 1 ? "" : "s"), to \(a.name)\(vitals) — \(whose) \(relation)"
            let between = line.line.dropFirst().dropLast().compactMap { graph.people[$0]?.name }
            if !between.isEmpty {
                let shown = between.count <= 4 ? between.joined(separator: " → ")
                    : between.prefix(2).joined(separator: " → ") + " → … → " + between.suffix(2).joined(separator: " → ")
                sentence += ", through \(shown)"
            }
            sentence += "."
            if line.atDepth > 1 {
                sentence += " \(spoken(line.atDepth - 1)) other ancestor\(line.atDepth == 2 ? " sits" : "s sit") that far back too."
            }
            sentences.append(sentence)
        }
        if deepest >= 10 {
            sentences.append("Lines this deep are only as good as the compiled tree they came from — take the far end with a grain of salt.")
        }
        return sentences.joined(separator: " ")
    }

    static func earliestProse(_ e: TreeLineStatistics.Earliest, perSide: [TreeLineStatistics.Earliest],
                              sides: AncestorSides, population: TreeLineStatistics.Population,
                              graph: GedcomFamilyGraph) -> String {
        let pop = ancestorPopulationPhrase(sides, population)
        guard let year = e.year, let first = e.people.first else {
            return "None of \(pop) has a recorded birth year, so I can’t say who was born earliest."
        }
        func born(_ m: TreeLineStatistics.Member) -> String {
            switch m.birthPrecision {
            case .approximate?: return "born about \(m.birthYear ?? year)"
            case .bounded?: return "born around \(m.birthYear ?? year) (the record gives a range)"
            default: return "born \(m.birthYear ?? year)"
            }
        }
        /// "your 3rd-great-grandmother" / "on both sides: …".
        func relation(_ m: TreeLineStatistics.Member) -> String {
            let on = m.generations.indices.compactMap { i -> String? in
                guard let g = m.generations[i] else { return nil }
                return "\(sides.possessive(i)) \(GedcomFamilyGraph.generationLabel(generations: g, sex: m.sex))"
            }
            return HallieNameQualifier.joined(on, conjunction: "and")
        }
        var sentences: [String] = []
        if e.people.count == 1 {
            sentences.append("The earliest recorded birth among \(pop) is \(first.name), \(born(first)) — \(relation(first)).")
        } else {
            let names = e.people.map { "\($0.name) (\(relation($0)))" }
            let more = e.ties > e.people.count ? ", and \(spoken(e.ties - e.people.count)) more" : ""
            sentences.append("\(spoken(e.ties)) of \(pop) share the earliest recorded birth year, \(year): "
                + HallieNameQualifier.joined(names, conjunction: "and") + more + ".")
        }
        let undated = e.considered - e.dated
        sentences.append(undated > 0
            ? "\(spoken(e.dated)) of the \(spoken(e.considered)) have a birth year; the other \(spoken(undated)) can’t be ranked."
            : "All \(spoken(e.considered)) have a birth year.")
        if sides.isOurs {
            // The other side's own earliest, when it is someone else.
            for (i, side) in perSide.enumerated() {
                guard let m = side.people.first, m.id != first.id, !first.isOn(side: i) else { continue }
                sentences.append("On \(sides.side(i)) the earliest is \(m.name), \(born(m)).")
            }
        }
        if year < 1500 {
            sentences.append("Births this early come from compiled trees, not original records — take it with a grain of salt.")
        }
        return sentences.joined(separator: " ")
    }
}
