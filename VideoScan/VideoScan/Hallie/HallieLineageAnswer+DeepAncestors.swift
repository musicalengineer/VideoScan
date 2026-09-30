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

    /// Every ancestor exactly `depth` generations above `person` (first
    /// hop through `side` when given, final hop filtered by `sex`), each
    /// with ONE route the tree records — the same shape the ≤ great-great
    /// kinship route answers with, so a wrong link stays visible.
    ///
    /// C++ readers: `levels[l]` is the set of people at generation l+1
    /// (insertion order kept for stable prose) and `pred[l][id]` is the
    /// id of the child they were reached through — a plain BFS
    /// predecessor map; a route is rebuilt by following it downward.
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
                              lens: HallieVitalDates.Lens = .treeOnly) -> Result {
        let sexFilter = (sex?.isEmpty ?? true) ? nil : sex
        let sideWord = side.map { "\($0.rawValue) " } ?? ""
        let noun = sideWord + GedcomFamilyGraph.generationLabel(generations: depth, sex: sexFilter ?? "")
        let depth = max(1, depth)
        func hopLabel(_ reached: GedcomFamilyGraph.Person, from previous: GedcomFamilyGraph.Person?) -> String {
            let word = reached.sex == "M" ? "father" : reached.sex == "F" ? "mother" : "parent"
            guard let previous else { return word }
            return (previous.sex == "M" ? "his " : previous.sex == "F" ? "her " : "their ") + word
        }

        // ---- Walk: one visit per (person, level); predecessor map.
        var levels: [[GedcomFamilyGraph.Person]] = []
        var pred: [[String: String]] = []
        var frontier = [person]
        var expanded = 0
        var budgetHit = false
        var stoppedAtLevel: Int? = nil
        let started = Date()
        /// The route from `person` (exclusive) up to `id` at 1-based `level`.
        func route(to id: String, level: Int) -> [GedcomFamilyGraph.Person] {
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
        walk: for level in 1...depth {
            var next: [GedcomFamilyGraph.Person] = []
            var seenHere: Set<String> = []
            var predHere: [String: String] = [:]
            for from in frontier {
                if expanded >= deepAncestorMaxExpanded
                    || Date().timeIntervalSince(started) > deepAncestorTimeBudget {
                    budgetHit = true
                    break
                }
                expanded += 1
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
                        || routeContains(parent.id, below: from.id, level: level - 1) { continue }
                    seenHere.insert(parent.id)
                    predHere[parent.id] = from.id
                    next.append(parent)
                }
            }
            if next.isEmpty && !budgetHit {
                stoppedAtLevel = level
                break walk
            }
            // The budget tripped before this level produced anyone: that
            // is the budget decline below, not "nobody recorded here".
            if next.isEmpty { break walk }
            levels.append(next)
            pred.append(predHere)
            frontier = next
            if budgetHit { break walk }
        }

        let base = "Basis: imported family tree (GEDCOM); ancestor walk \(depth) generations up"
            + (side.map { ", first hop through the \($0.rawValue) side" } ?? "") + "."
            + (basisNote.map { " " + $0 } ?? "")
        let query = "deep ancestor ×\(depth) \(sexFilter ?? "any"): \(person.name)"
        let openPerson: [HallieTurnExecutor.OfferedAction] =
            [.openFamilyTreePerson(personID: person.id, personName: person.name)]

        // ---- The tree ran out before `depth`: say exactly where.
        if let stoppedAtLevel {
            let reached = levels.last.flatMap { $0.first }.map { route(to: $0.id, level: stoppedAtLevel - 1) } ?? []
            let from = reached.last ?? person
            let reachedText = reached.enumerated().map { i, p in
                "\(hopLabel(p, from: i == 0 ? nil : reached[i - 1])) (\(p.name))"
            }.joined(separator: " → ")
            let missingWord = reached.isEmpty && side != nil
                ? (side == .maternal ? "a mother" : "a father") : "parents"
            let prose = reached.isEmpty
                ? "The family tree doesn’t record \(missingWord) for \(person.name), so I can’t reach a \(noun)."
                : "The family tree records \(HallieLineageQuestion.possessive(person.name)) \(reachedText), but no parents for \(from.name) — so I can’t reach a \(noun) (\(reached.count) of \(depth) generations recorded)."
            return Result(route: .graph, outcome: .declined, prose: prose, basisLine: base,
                          queryDescription: query, citations: [], catalogPersonName: person.name,
                          offeredActions: openPerson)
        }

        // ---- The budget ran out before the asked-for generation: honest
        // decline rather than a partial generation presented as the answer.
        if budgetHit && levels.count < depth {
            return Result(
                route: .graph, outcome: .declined,
                prose: "\(HallieLineageQuestion.possessive(person.name)) ancestry fans out too far for me to reach a \(noun) in one go — I examined \(expanded) people across \(levels.count) generation\(levels.count == 1 ? "" : "s") and stopped. Try one line (paternal or maternal) or a smaller count.",
                basisLine: base + " Walk stopped at its budget.",
                queryDescription: query, citations: [], catalogPersonName: person.name,
                offeredActions: openPerson)
        }

        // ---- Results at `depth`, one route each.
        let atDepth = (levels.last ?? []).filter { sexFilter == nil || $0.sex == sexFilter }
            .sorted { $0.name < $1.name }
        guard !atDepth.isEmpty else {
            let word = sexFilter == "M" ? "male" : sexFilter == "F" ? "female" : "at all"
            let names = (levels.last ?? []).map(\.name)
            return Result(route: .graph, outcome: .declined,
                          prose: "The tree reaches \(depth) generations above \(person.name) (\(names.joined(separator: ", "))), but records nobody \(word) there, so I can’t name a \(noun).",
                          basisLine: base + (budgetHit ? " Walk stopped at its budget; there may be more." : ""),
                          queryDescription: query, citations: [], catalogPersonName: person.name,
                          offeredActions: openPerson)
        }
        let shown = Array(atDepth.prefix(deepAncestorMaxResults))
        let paths = shown.map { route(to: $0.id, level: depth) }
        let lines = paths.map { path -> String in
            let relative = path[path.count - 1]
            var text = relative.name
            if let years = lens.yearsText(relative) { text += " (\(years))" }
            let route = ([person.name] + path.enumerated().map { i, p in
                "\(hopLabel(p, from: i == 0 ? nil : path[i - 1])) \(p.name)"
            }).joined(separator: " → ")
            return "\(text) (\(route))"
        }
        let plural = paths.count == 1 ? noun : noun + "s"
        var prose = "\(HallieLineageQuestion.possessive(person.name)) \(plural): " + lines.joined(separator: "; ") + "."
        let more = atDepth.count - shown.count
        if more > 0 {
            prose += " There are \(more) more at that generation I haven’t listed (\(atDepth.count) in all)."
        }
        if budgetHit {
            prose += " I stopped the walk at its budget (\(expanded) people examined), so there may be others."
        }
        return Result(
            route: .graph, outcome: .answered,
            prose: prose,
            basisLine: base + (budgetHit ? " Walk stopped at its budget; there may be more." : ""),
            queryDescription: query,
            citations: [], catalogPersonName: person.name,
            offeredActions: paths.prefix(3).map { .openFamilyTreePerson(personID: $0[$0.count - 1].id, personName: $0[$0.count - 1].name) })
    }
}
