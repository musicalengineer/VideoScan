// HallieLineageAnswer+DeepAncestors.swift
// "great-great-great-grandparents" and beyond — the deep-ancestor lists.
// Moved out of HallieLineageQuestion.swift unchanged on 2026-09-07 night
// (codex #1182 item 2: result construction only). The section read no
// private member of its neighbours; nothing is widened.

import Foundation
import VideoScanCore

extension HallieLineageAnswer {
    // MARK: Deep ancestors (great × 3 and beyond)

    /// Budgets for the deep-ancestor walk (codex #707 blocker 1): the
    /// old walk kept EVERY full path, so pedigree collapse (the same
    /// couple reached along several lines) grew paths as 2^depth through
    /// the 40-great bound — a freeze or an OOM on a real tree. The walk
    /// below is a visited/predecessor BFS: one path per (person, depth),
    /// reconstructed from a predecessor map only for the people it
    /// names. These caps make even a pathological GEDCOM finish.
    static let deepAncestorMaxResults = 25
    static let deepAncestorMaxExpanded = 50_000
    static let deepAncestorTimeBudget: TimeInterval = 0.15

    /// The walk's two limits. Production always uses the caps above; tests
    /// pass a small expansion cap and a generous clock so a budget branch
    /// is reached by COUNT, never by machine speed (codex, 2026-10-29: the
    /// 0.15 s clock alone made a budget test depend on the host's load).
    struct DeepAncestorBudget: Sendable {
        var maxExpanded: Int
        var timeBudget: TimeInterval
        static let production = DeepAncestorBudget(
            maxExpanded: deepAncestorMaxExpanded, timeBudget: deepAncestorTimeBudget)
    }

    /// Every ancestor exactly `depth` generations above `person` (first
    /// hop through `side` when given, final hop filtered by `sex`), each
    /// with ONE route the tree records — the same shape the ≤ great-great
    /// kinship route answers with, so a wrong link stays visible.
    ///
    /// Walk (`DeepAncestorWalk.run`), then one of four answers: the tree
    /// ran out, the budget ran out, nobody of that sex, or the list.
    /// (Split into those steps 2026-10-29, behaviour unchanged.)
    static func deepAncestors(of person: GedcomFamilyGraph.Person,
                              depth: Int,
                              sex: String?,
                              side: ArchivistQueryAST.Graph.Side?,
                              graph: GedcomFamilyGraph,
                              basisNote: String? = nil,
                              // Defaulted so the many existing callers and
                              // tests that ask only about tree shape keep
                              // compiling; `answer` always passes the real
                              // lens (HallieVitalDates migration, 2026-09-06).
                              lens: HallieVitalDates.Lens = .treeOnly,
                              budget: DeepAncestorBudget = .production) -> Result {
        let sexFilter = (sex?.isEmpty ?? true) ? nil : sex
        let sideWord = side.map { "\($0.rawValue) " } ?? ""
        // The noun uses the depth as asked; the walk clamps it to ≥ 1.
        let noun = sideWord + GedcomFamilyGraph.generationLabel(generations: depth, sex: sexFilter ?? "")
        let depth = max(1, depth)
        let walk = DeepAncestorWalk.run(from: person, depth: depth, side: side, graph: graph, budget: budget)
        let ask = DeepAncestorAsk(
            person: person, depth: depth, side: side, noun: noun,
            base: "Basis: imported family tree (GEDCOM); ancestor walk \(depth) generations up"
                + (side.map { ", first hop through the \($0.rawValue) side" } ?? "") + "."
                + (basisNote.map { " " + $0 } ?? ""),
            query: "deep ancestor ×\(depth) \(sexFilter ?? "any"): \(person.name)")

        if let stoppedAtLevel = walk.stoppedAtLevel {
            return treeRanOut(ask, walk: walk, stoppedAtLevel: stoppedAtLevel, graph: graph)
        }
        if walk.budgetHit && walk.levels.count < depth {
            return budgetDecline(ask, walk: walk)
        }
        let atDepth = (walk.levels.last ?? []).filter { sexFilter == nil || $0.sex == sexFilter }
            .sorted { $0.name < $1.name }
        guard !atDepth.isEmpty else {
            return nobodyOfThatSex(ask, walk: walk, sexFilter: sexFilter)
        }
        return listedAncestors(ask, walk: walk, atDepth: atDepth, graph: graph, lens: lens)
    }

    /// The per-question words every deep-ancestor answer shares.
    private struct DeepAncestorAsk {
        let person: GedcomFamilyGraph.Person
        let depth: Int
        let side: ArchivistQueryAST.Graph.Side?
        let noun: String
        let base: String
        let query: String

        var openPerson: [HallieTurnExecutor.OfferedAction] {
            [.openFamilyTreePerson(personID: person.id, personName: person.name)]
        }
    }

    /// The bounded BFS: one visit per (person, level), with a predecessor
    /// map instead of full paths. C++ readers: `levels[l]` is the set of
    /// people at generation l+1 (insertion order kept for stable prose) and
    /// `pred[l][id]` is the id of the child they were reached through — a
    /// plain BFS predecessor map; a route is rebuilt by following it
    /// downward. A value type returned by `run`, like a struct returned by
    /// value; `route` / `routeContains` are const member functions.
    ///
    /// Worst-case memory: `budget.maxExpanded` (50,000 in production) expansions,
    /// each adding at most its parents once per level — a few hundred
    /// thousand (String, String) entries and Person copies at most.
    private struct DeepAncestorWalk {
        var levels: [[GedcomFamilyGraph.Person]] = []
        var pred: [[String: String]] = []
        var expanded = 0
        var budgetHit = false
        var stoppedAtLevel: Int?

        static func run(from person: GedcomFamilyGraph.Person,
                        depth: Int,
                        side: ArchivistQueryAST.Graph.Side?,
                        graph: GedcomFamilyGraph,
                        budget: DeepAncestorBudget) -> DeepAncestorWalk {
            var walk = DeepAncestorWalk()
            var frontier = [person]
            let started = Date()
            for level in 1...depth {
                var next: [GedcomFamilyGraph.Person] = []
                var seenHere: Set<String> = []
                var predHere: [String: String] = [:]
                for from in frontier {
                    if walk.expanded >= budget.maxExpanded
                        || Date().timeIntervalSince(started) > budget.timeBudget {
                        walk.budgetHit = true
                        break
                    }
                    walk.expanded += 1
                    let parents: [GedcomFamilyGraph.Person]
                    if level == 1, let side {
                        parents = graph.relatives(side == .maternal ? .mother : .father, of: from)
                    } else {
                        parents = graph.relatives(.parents, of: from)
                    }
                    for parent in parents where !seenHere.contains(parent.id) {
                        // A malformed GEDCOM can make someone their own
                        // ancestor; the route check keeps the walk acyclic.
                        if parent.id == person.id
                            || walk.routeContains(parent.id, below: from.id, level: level - 1) { continue }
                        seenHere.insert(parent.id)
                        predHere[parent.id] = from.id
                        next.append(parent)
                    }
                }
                if next.isEmpty && !walk.budgetHit {
                    walk.stoppedAtLevel = level
                    break
                }
                // The budget tripped before this level produced anyone: that
                // is the budget decline, not "nobody recorded here".
                if next.isEmpty { break }
                walk.levels.append(next)
                walk.pred.append(predHere)
                frontier = next
                if walk.budgetHit { break }
            }
            return walk
        }

        /// The route from the walk's start (exclusive) up to `id` at
        /// 1-based `level`.
        func route(to id: String, level: Int, graph: GedcomFamilyGraph) -> [GedcomFamilyGraph.Person] {
            var out: [GedcomFamilyGraph.Person] = []
            var cur = id
            for l in stride(from: level, through: 1, by: -1) {
                guard let p = graph.people[cur] else { break }
                out.append(p)
                guard let below = pred[l - 1][cur] else { break }
                cur = below
            }
            return out.reversed()
        }

        /// True when `id` already sits on the recorded route below `from`
        /// (which is at 1-based `level`). Ids only — no Person is copied.
        /// This runs once per parent of every expanded person, so on a
        /// 16k-person pedigree it is the walk's hot loop (2026-08-28: the
        /// Person-copying `route(to:)` here cost ~180k struct copies and
        /// put the walk on the wrong side of its own time budget in Debug).
        func routeContains(_ id: String, below from: String, level: Int) -> Bool {
            var cur = from
            var l = level
            while l >= 1 {
                if cur == id { return true }
                guard let next = pred[l - 1][cur] else { return false }
                cur = next
                l -= 1
            }
            return false
        }
    }

    /// "father" / "his mother" / "their parent" for one hop of a route.
    private static func deepHopLabel(_ reached: GedcomFamilyGraph.Person,
                                     from previous: GedcomFamilyGraph.Person?) -> String {
        let word = reached.sex == "M" ? "father" : reached.sex == "F" ? "mother" : "parent"
        guard let previous else { return word }
        return (previous.sex == "M" ? "his " : previous.sex == "F" ? "her " : "their ") + word
    }

    /// The tree ran out before `depth`: say exactly where.
    private static func treeRanOut(_ ask: DeepAncestorAsk, walk: DeepAncestorWalk,
                                   stoppedAtLevel: Int, graph: GedcomFamilyGraph) -> Result {
        let person = ask.person
        let reached = walk.levels.last.flatMap { $0.first }
            .map { walk.route(to: $0.id, level: stoppedAtLevel - 1, graph: graph) } ?? []
        let from = reached.last ?? person
        let reachedText = reached.enumerated().map { i, p in
            "\(deepHopLabel(p, from: i == 0 ? nil : reached[i - 1])) (\(p.name))"
        }.joined(separator: " → ")
        let missingWord = reached.isEmpty && ask.side != nil
            ? (ask.side == .maternal ? "a mother" : "a father") : "parents"
        let prose = reached.isEmpty
            ? "The family tree doesn’t record \(missingWord) for \(person.name), so I can’t reach a \(ask.noun)."
            : "The family tree records \(HallieLineageQuestion.possessive(person.name)) \(reachedText), but no parents for \(from.name) — so I can’t reach a \(ask.noun) (\(reached.count) of \(ask.depth) generations recorded)."
        return Result(route: .graph, outcome: .declined, prose: prose, basisLine: ask.base,
                      queryDescription: ask.query, citations: [], catalogPersonName: person.name,
                      offeredActions: ask.openPerson)
    }

    /// The budget ran out before the asked-for generation: honest decline
    /// rather than a partial generation presented as the answer.
    private static func budgetDecline(_ ask: DeepAncestorAsk, walk: DeepAncestorWalk) -> Result {
        let generations = walk.levels.count
        return Result(
            route: .graph, outcome: .declined,
            prose: "\(HallieLineageQuestion.possessive(ask.person.name)) ancestry fans out too far for me to reach a \(ask.noun) in one go — I examined \(walk.expanded) people across \(generations) generation\(generations == 1 ? "" : "s") and stopped. Try one line (paternal or maternal) or a smaller count.",
            basisLine: ask.base + " Walk stopped at its budget.",
            queryDescription: ask.query, citations: [], catalogPersonName: ask.person.name,
            offeredActions: ask.openPerson)
    }

    /// The tree reaches `depth` but nobody there has the asked sex.
    private static func nobodyOfThatSex(_ ask: DeepAncestorAsk, walk: DeepAncestorWalk, sexFilter: String?) -> Result {
        let word = sexFilter == "M" ? "male" : sexFilter == "F" ? "female" : "at all"
        let names = (walk.levels.last ?? []).map(\.name)
        return Result(route: .graph, outcome: .declined,
                      prose: "The tree reaches \(ask.depth) generations above \(ask.person.name) (\(names.joined(separator: ", "))), but records nobody \(word) there, so I can’t name a \(ask.noun).",
                      basisLine: ask.base + (walk.budgetHit ? " Walk stopped at its budget; there may be more." : ""),
                      queryDescription: ask.query, citations: [], catalogPersonName: ask.person.name,
                      offeredActions: ask.openPerson)
    }

    /// Results at `depth`, one route each, at most `deepAncestorMaxResults`.
    private static func listedAncestors(_ ask: DeepAncestorAsk, walk: DeepAncestorWalk,
                                        atDepth: [GedcomFamilyGraph.Person],
                                        graph: GedcomFamilyGraph,
                                        lens: HallieVitalDates.Lens) -> Result {
        let person = ask.person
        let shown = Array(atDepth.prefix(deepAncestorMaxResults))
        let paths = shown.map { walk.route(to: $0.id, level: ask.depth, graph: graph) }
        let lines = paths.map { path -> String in
            let relative = path[path.count - 1]
            var text = relative.name
            if let years = lens.yearsText(relative) { text += " (\(years))" }
            let route = ([person.name] + path.enumerated().map { i, p in
                "\(deepHopLabel(p, from: i == 0 ? nil : path[i - 1])) \(p.name)"
            }).joined(separator: " → ")
            return "\(text) (\(route))"
        }
        let plural = paths.count == 1 ? ask.noun : ask.noun + "s"
        var prose = "\(HallieLineageQuestion.possessive(person.name)) \(plural): " + lines.joined(separator: "; ") + "."
        let more = atDepth.count - shown.count
        if more > 0 {
            prose += " There are \(more) more at that generation I haven’t listed (\(atDepth.count) in all)."
        }
        if walk.budgetHit {
            prose += " I stopped the walk at its budget (\(walk.expanded) people examined), so there may be others."
        }
        return Result(
            route: .graph, outcome: .answered,
            prose: prose,
            basisLine: ask.base + (walk.budgetHit ? " Walk stopped at its budget; there may be more." : ""),
            queryDescription: ask.query,
            citations: [], catalogPersonName: person.name,
            offeredActions: paths.prefix(3).map { .openFamilyTreePerson(personID: $0[$0.count - 1].id, personName: $0[$0.count - 1].name) })
    }
}
