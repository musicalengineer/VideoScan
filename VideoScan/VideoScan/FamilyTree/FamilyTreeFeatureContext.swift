// FamilyTreeFeatureContext.swift
// The app-side facts Person of the Day and Roll Call both need about the
// installed tree, gathered ONCE off the main actor (2026-10-01):
//   • who the home people are and the inner circle (the home people, their
//     spouses and their children — the only living people either feature
//     may name, and then without private details);
//   • each person's line / generation from the walk's decorations.json
//     ("Rick's great-grandmother");
//   • the portrait hint (one listing of the archive's People/ folder —
//     FamilyPortraitHints) and the family-notes count (CyberBrain items
//     visible to the FAMILY — the same `.family` ceiling as the map,
//     because the card and the credits are family-facing);
//   • the life rule: Core's cheap date rule first, then the app's full
//     LifeStatus (which walks descendants) only for the people Core asks
//     about — Core asks lazily, best-ranked first.
//
// NOTHING HERE WRITES: not the tree, not CyberBrain, not the archive.
//
// (For Rick: `struct … Sendable` ≈ an immutable value the compiler has
// checked can be handed to a worker thread; every method here is a plain
// function over that value, safe off the UI thread.)

import Foundation
import VideoScanCore

struct FamilyTreeFeatureContext: Sendable {
    let graph: GedcomFamilyGraph
    /// The walk's decorations by person id (empty when not walked yet).
    let decorations: [String: TreeWalk.Decoration]
    /// How the two lines are named ("Rick", "Donna").
    let displayNames: [String]
    let knowledge: FamilyTreeNotesResolver?
    let hints: FamilyPortraitHints
    let innerCircle: Set<String>
    let now: Date

    /// Build off-main. `starts` are the home people (owner first).
    init(graph: GedcomFamilyGraph, decorations: [String: TreeWalk.Decoration], displayNames: [String],
         knowledge: FamilyTreeNotesResolver?, hints: FamilyPortraitHints, starts: [String], now: Date) {
        self.graph = graph
        self.decorations = decorations
        self.displayNames = displayNames
        self.knowledge = knowledge
        self.hints = hints
        self.innerCircle = Self.innerCircle(graph: graph, starts: starts)
        self.now = now
    }

    /// The home people, their spouses and their children.
    static func innerCircle(graph: GedcomFamilyGraph, starts: [String]) -> Set<String> {
        var out = Set<String>()
        for id in starts {
            guard let p = graph.people[id] else { continue }
            out.insert(id)
            for m in graph.marriages(of: p) { if let s = m.spouse { out.insert(s.id) } }
            for c in graph.relatives(.children, of: p) { out.insert(c.id) }
        }
        return out
    }

    /// Family notes about a person that the family may see.
    func storyCount(_ id: String) -> Int {
        guard let knowledge else { return 0 }
        var n = 0
        for person in knowledge.cyberBrainPeople(forGedcomID: id) {
            n += knowledge.index.allActiveItems(for: person.id)
                .filter { $0.privacy.isVisible(at: FamilyMapModel.privacyCeiling) }.count
        }
        return n
    }

    /// The nearer of the two generations above a home person, > 0.
    func generation(_ id: String) -> Int? {
        guard let d = decorations[id] else { return nil }
        return [d.generationFromFirst, d.generationFromSecond].compactMap { $0 }.filter { $0 > 0 }.min()
    }

    /// "Rick's great-grandmother" — the nearer line; nil when not an ancestor.
    func relation(_ id: String) -> String? {
        guard let d = decorations[id] else { return nil }
        var best: (gen: Int, who: Int)?
        if let g = d.generationFromFirst, g > 0 { best = (g, 0) }
        if let g = d.generationFromSecond, g > 0, best == nil || g < best!.gen { best = (g, 1) }
        guard let best, let label = d.relationLabel(generations: best.gen) else { return nil }
        let who = displayNames.indices.contains(best.who) ? displayNames[best.who] : nil
        return who.map { "\($0)'s \(label)" } ?? label
    }

    func line(_ id: String) -> TreeWalk.Line { decorations[id]?.line ?? .none }

    /// The life rule (see the header). `livingPrivate` is the safe answer
    /// for anyone the tree cannot place.
    func life(id: String, quick: PersonOfTheDay.Life) -> PersonOfTheDay.Life {
        if quick == .deceased { return .deceased }
        guard let person = graph.people[id] else { return .livingPrivate }
        if LifeStatus.of(person, in: graph, now: now) != .living { return .deceased }
        return innerCircle.contains(id) ? .livingInnerCircle : .livingPrivate
    }

    /// Every visible person as a Person-of-the-Day candidate. O(people);
    /// ~1 s at 39k in Debug, off-main.
    func candidates() -> [PersonOfTheDay.Candidate] {
        let hidden = graph.suppressedPersonIDs
        var out: [PersonOfTheDay.Candidate] = []
        out.reserveCapacity(graph.people.count)
        // Sorted ids: the candidate order is irrelevant to the pick (the
        // shuffle is keyed on the id), but a stable order keeps logs and
        // tests reproducible.
        for id in graph.people.keys.sorted() where !hidden.contains(id) {
            guard let p = graph.people[id] else { continue }
            out.append(PersonOfTheDay.Candidate(
                id: id, name: p.name, sex: p.sex, birthDate: p.birthDate, deathDate: p.deathDate,
                birthPlace: p.birthPlace, deathPlace: p.deathPlace,
                marriageDates: graph.marriages(of: p).compactMap(\.date),
                line: line(id), generation: generation(id), relation: relation(id),
                hasPortrait: hints.mayHavePortrait(p), storyCount: storyCount(id),
                isInnerCircle: innerCircle.contains(id)))
        }
        return out
    }

    /// The walked people (ordinals of a walk result) as Roll Call rows.
    func rollCallPeople(result: TreeWalk.Result, visited: [Int]) -> [RollCall.Person] {
        var out: [RollCall.Person] = []
        out.reserveCapacity(visited.count)
        for o in visited where o >= 0 && o < result.ids.count {
            let id = result.ids[o]
            guard let p = graph.people[id] else { continue }
            let d = result.decorations[o]
            let gen = [d.generationFromFirst, d.generationFromSecond].compactMap { $0 }.min()
            out.append(RollCall.Person(
                id: id, name: p.name, birthDate: p.birthDate, deathDate: p.deathDate, birthPlace: p.birthPlace,
                generation: gen, line: d.line, hasPortrait: hints.mayHavePortrait(p),
                storyCount: storyCount(id), isInnerCircle: innerCircle.contains(id)))
        }
        return out
    }
}
