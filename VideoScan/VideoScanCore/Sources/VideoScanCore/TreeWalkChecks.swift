// TreeWalkChecks.swift (VideoScanCore)
// The walk's consistency checks. REPORT, never fix: each is a sentence a
// person can act on, with a severity, about the person first.
//
// Every date rule is PROVEN over month intervals (TreeWalkDate): "ABT 1700"
// is 1698–1702, and a rule fires only when every reading of both dates
// breaks it. A wrong answer here sends Rick to FamilySearch to "fix" a
// record that was fine.
//
// Thresholds (Rick 2026-09-27): child before the parent was 12; after the
// mother was 55 or the father 80; death before birth; age over 110; birth
// more than a year after the mother's death or nine months after the
// father's; spouses born more than 40 years apart; the same name ± 2 years
// under the same parents; someone their own ancestor.
//
// Per-person checks run in parallel chunks over the frozen snapshot
// (each chunk returns its own list; concatenated in chunk order, then
// sorted by the caller — deterministic whatever the thread schedule).

import Foundation

enum TreeWalkChecks {

    static let youngestParentYears = 12
    static let oldestMotherYears = 55
    static let oldestFatherYears = 80
    static let oldestAgeYears = 110
    static let monthsAfterMotherDeath = 12
    static let monthsAfterFatherDeath = 9
    static let spouseGapYears = 40
    static let duplicateBirthSlackYears = 2

    static func perPerson(snapshot s: TreeWalkSnapshot, graph: GedcomFamilyGraph,
                          ages: [AgeAtDeath?]) -> [TreeWalk.Check] {
        let people = graph.people
        func raw(_ o: Int, birth: Bool) -> String {
            let p = people[s.ids[o]]
            return (birth ? p?.birthDate : p?.deathDate) ?? "?"
        }
        func name(_ o: Int) -> String { s.names[o].isEmpty ? s.ids[o] : s.names[o] }
        func their(_ o: Int) -> String { s.sex[o] == "M" ? "his" : s.sex[o] == "F" ? "her" : "their" }

        let perChunk: [[TreeWalk.Check]] = TreeWalkParallel.chunks(count: s.count) { range in
            var out: [TreeWalk.Check] = []
            for o in range where s.visible[o] {
                let me = s.ids[o]
                if let b = s.birth[o], let d = s.death[o], let gap = b.provenMonthsAfter(d), gap > 0 {
                    out.append(.init(kind: .deathBeforeBirth, personIDs: [me],
                                     reason: "\(name(o)) died \(raw(o, birth: false)) but was born \(raw(o, birth: true)) — death before birth."))
                }
                if let age = ages[o], age.minYears > oldestAgeYears {
                    out.append(.init(kind: .ageOver110, personIDs: [me],
                                     reason: "\(name(o)) born \(raw(o, birth: true)), died \(raw(o, birth: false)) — at least \(age.minYears) years old."))
                }
                guard let childBirth = s.birth[o] else { continue }
                let fathers = Set(s.fathers(of: o))
                for p32 in s.parents(of: o) {
                    let p = Int(p32)
                    let isFather = fathers.contains(p32)
                    let role = isFather ? "father" : "mother"
                    if let pb = s.birth[p] {
                        // Largest possible age of the parent at the birth.
                        if let hi = childBirth.upperMonth, let lo = pb.lowerMonth, hi - lo < youngestParentYears * 12 {
                            let years = (hi - lo) / 12
                            let why = hi < lo
                                ? "\(name(o)) born \(raw(o, birth: true)), before \(their(o)) \(role) \(name(p)) (born \(raw(p, birth: true)))."
                                : "\(name(o)) born \(raw(o, birth: true)); \(their(o)) \(role) \(name(p)) (born \(raw(p, birth: true))) was at most \(years)."
                            out.append(.init(kind: .childBornBeforeParentAge12, personIDs: [me, s.ids[p]], reason: why))
                        }
                        // Smallest possible age of the parent at the birth.
                        let limit = isFather ? oldestFatherYears : oldestMotherYears
                        if let lo = childBirth.lowerMonth, let hi = pb.upperMonth, lo - hi > limit * 12 {
                            out.append(.init(kind: isFather ? .childBornAfterFather80 : .childBornAfterMother55,
                                             personIDs: [me, s.ids[p]],
                                             reason: "\(name(o)) born \(raw(o, birth: true)); \(their(o)) \(role) \(name(p)) (born \(raw(p, birth: true))) was at least \((lo - hi) / 12)."))
                        }
                    }
                    if let pd = s.death[p], let after = childBirth.provenMonthsAfter(pd) {
                        let limit = isFather ? monthsAfterFatherDeath : monthsAfterMotherDeath
                        if after > limit {
                            out.append(.init(kind: isFather ? .bornAfterFatherDeath : .bornAfterMotherDeath,
                                             personIDs: [me, s.ids[p]],
                                             reason: "\(name(o)) born \(raw(o, birth: true)), \(their(o)) \(role) \(name(p)) died \(raw(p, birth: false)) (birth after \(role)'s death)."))
                        }
                    }
                }
            }
            // Spouses: each pair once (lower ordinal reports).
            for o in range where s.visible[o] {
                guard let a = s.birth[o] else { continue }
                for w32 in s.spouses(of: o) where Int(w32) > o {
                    let w = Int(w32)
                    guard let b = s.birth[w] else { continue }
                    let gap = max(a.provenMonthsAfter(b) ?? Int.min, b.provenMonthsAfter(a) ?? Int.min)
                    if gap > spouseGapYears * 12 {
                        out.append(.init(kind: .spouseAgeGap, personIDs: [s.ids[o], s.ids[w]],
                                         reason: "\(name(o)) (born \(raw(o, birth: true))) and \(name(w)) (born \(raw(w, birth: true))) are recorded as spouses born over \(gap / 12) years apart."))
                    }
                }
            }
            return out
        }
        return perChunk.flatMap { $0 }
    }

    /// Same normalised name, same parents, births within ± 2 years. Flag
    /// only — twins or a child renamed after a sibling who died are real.
    static func duplicates(snapshot s: TreeWalkSnapshot) -> [TreeWalk.Check] {
        var groups: [String: [Int]] = [:]
        for o in 0..<s.count where s.visible[o] && s.birth[o] != nil {
            let parents = s.parents(of: o).sorted()
            guard !parents.isEmpty else { continue }
            let name = FamilyTreeVerification.normalized(s.names[o])
            guard !name.isEmpty else { continue }
            groups[parents.map(String.init).joined(separator: ",") + "|" + name, default: []].append(o)
        }
        var out: [TreeWalk.Check] = []
        for key in groups.keys.sorted() {
            guard let group = groups[key], group.count > 1 else { continue }
            for i in group.indices {
                for j in group.index(after: i)..<group.endIndex {
                    let a = group[i], b = group[j]
                    guard let ya = s.birth[a]?.year, let yb = s.birth[b]?.year,
                          abs(ya - yb) <= duplicateBirthSlackYears else { continue }
                    out.append(.init(kind: .likelyDuplicate, personIDs: [s.ids[a], s.ids[b]],
                                     reason: "\(s.names[a]) (\(s.ids[a]), b. \(ya)) and \(s.names[b]) (\(s.ids[b]), b. \(yb)) share a name and both parents — possibly one person recorded twice."))
                }
            }
        }
        return out
    }

    /// One check per cyclic component, every member listed.
    static func cycles(snapshot s: TreeWalkSnapshot, components c: TreeWalkGraph.Components) -> [TreeWalk.Check] {
        var out: [TreeWalk.Check] = []
        for (i, members) in c.members.enumerated() where c.cyclic[i] {
            let names = members.map { s.names[Int($0)].isEmpty ? s.ids[Int($0)] : s.names[Int($0)] }
            let reason = members.count == 1
                ? "\(names[0]) is recorded as their own parent."
                : "\(members.count) people are each other's ancestors — a loop in the tree among \(names.joined(separator: ", "))."
            out.append(.init(kind: .ancestorCycle, personIDs: members.map { s.ids[Int($0)] }, reason: reason))
        }
        return out
    }
}
