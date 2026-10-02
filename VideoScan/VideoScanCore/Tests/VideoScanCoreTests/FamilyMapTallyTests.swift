// FamilyMapTallyTests.swift
// Per-unit counts for the family map (GH #227 Stage 1): sums add up to
// the resolved people, the Highlight mask and the year ceiling are
// honoured with the documented nil / all-false / wrong-length semantics,
// members come nearest generation first with a deterministic tie order,
// duplicates are counted once, and 40k people tally under budget.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("FamilyMap tally")
struct FamilyMapTallyTests {

    typealias T = FamilyMapTally
    typealias L = TreeWalk.Line

    // Eight people. Ordinal 7 is a start (generation 0, line none).
    static let people = T.People(
        ids:         ["I1", "I2", "I3", "I4", "I5", "I6", "I7", "I8"],
        names:       ["Ann Breen", "Bob Breen", "Cal McGill", "Dan Breen", "Eve Smith", "Fay McGill", "Guy Breen", "Rick Breen"],
        surnames:    ["Breen", "BREEN", "McGill", "Breen", "Smith", "McGill", "Breen ", "Breen"],
        birthYears:  [1700, 1720, nil, 1800, 1650, 1750, 1690, 1960],
        generations: [3, 3, 2, 1, nil, 2, 3, 0],
        lines:       [.first, .first, .second, .both, .first, .second, .first, .none],
        unitKeys:    ["eng-yorkshire", "eng-yorkshire", "eng", "usa-massachusetts", nil, "sct-fife", "eng-yorkshire", "usa-massachusetts"]
    )
    static let all = Array(0..<8)
    static let regions: [BirthplaceClassifier.BirthRegion] = [.england, .england, .england, .newEngland, .unknown, .scotland, .england, .newEngland]

    @Test func sumsAddUpToTheResolvedPeople() throws {
        let r = try T.counts(people: Self.people, visited: Self.all)
        #expect(r.totals == T.Totals(considered: 8, resolved: 7, countryOnly: 1, unresolved: 1))
        #expect(r.counts.values.reduce(0) { $0 + $1.people } == r.totals.resolved)
        #expect(r.counts["eng-yorkshire"]?.people == 3)
        #expect(r.counts["eng"]?.people == 1)
        #expect(r.counts["usa-massachusetts"]?.people == 2)
        #expect(r.counts["sct-fife"]?.people == 1)
        #expect(r.counts.count == 4)
        #expect(r.counts["eng-yorkshire"]?.byLine == [.first: 3])
        #expect(r.counts["usa-massachusetts"]?.byLine == [.both: 1, .none: 1])
    }

    @Test func topSurnamesAreMostCommonFirstWithStableTiesAndTheCommonestSpelling() throws {
        let r = try T.counts(people: Self.people, visited: Self.all)
        let york = try #require(r.counts["eng-yorkshire"])
        #expect(york.topSurnames == [T.SurnameCount(surname: "Breen", count: 3)], "BREEN / Breen / 'Breen ' fold to one; the commonest exact spelling shows")
        #expect(york.distinctSurnames == 1)
        // A unit with a tie: two surnames × 1 → alphabetical by folded key.
        let tie = T.People(ids: ["a", "b", "c"], names: ["Z", "Y", "X"], surnames: ["Zeta", "Alpha", "Alpha"],
                           birthYears: [nil, nil, nil], generations: [1, 1, 1], lines: [.first, .first, .first],
                           unitKeys: ["eng", "eng", "eng"])
        let t = try T.counts(people: tie, visited: [0, 1, 2], surnameLimit: 1)
        #expect(t.counts["eng"]?.topSurnames == [T.SurnameCount(surname: "Alpha", count: 2)])
        #expect(t.counts["eng"]?.distinctSurnames == 2, "the limit caps the list, not the distinct count")
        let spelled = T.People(ids: ["a", "b", "c", "d"], names: ["", "", "", ""], surnames: ["McGill", "MCGILL", "McGill", "Mc Gill"],
                               birthYears: [nil, nil, nil, nil], generations: [1, 1, 1, 1], lines: [.first, .first, .first, .first],
                               unitKeys: ["eng", "eng", "eng", "eng"])
        let s = try T.counts(people: spelled, visited: [0, 1, 2, 3])
        #expect(s.counts["eng"]?.topSurnames.map(\.surname) == ["McGill", "Mc Gill"])
        #expect(s.counts["eng"]?.topSurnames.map(\.count) == [3, 1])
    }

    @Test func membersComeNearestGenerationFirstThenSurnameNameId() throws {
        let r = try T.counts(people: Self.people, visited: Self.all)
        let york = try #require(r.counts["eng-yorkshire"])
        #expect(york.members.map(\.id) == ["I1", "I2", "I7"], "all generation 3: by name Ann, Bob, Guy")
        #expect(york.members.first == T.Member(id: "I1", name: "Ann Breen", birthYear: 1700, generation: 3, line: .first))
        let mass = try #require(r.counts["usa-massachusetts"])
        #expect(mass.members.map(\.id) == ["I8", "I4"], "generation 0 before 1")
        // Unknown generation last; surname before name; id breaks the last tie.
        let p = T.People(ids: ["x3", "x1", "x2", "x4", "x0"], names: ["Same", "Same", "Same", "Same", "Aaa"],
                         surnames: ["B", "A", "A", "A", "B"], birthYears: [nil, nil, nil, nil, nil],
                         generations: [2, 2, 2, nil, 2], lines: [.first, .first, .first, .first, .first],
                         unitKeys: ["eng", "eng", "eng", "eng", "eng"])
        let m = try #require(try T.counts(people: p, visited: [0, 1, 2, 3, 4]).counts["eng"]).members
        #expect(m.map(\.id) == ["x1", "x2", "x0", "x3", "x4"])
        // Reversed visit order gives the same answer.
        let m2 = try #require(try T.counts(people: p, visited: [4, 3, 2, 1, 0]).counts["eng"]).members
        #expect(m2 == m)
    }

    /// Who is NOT on the map, and why (follow-up round 1, codex #1782 stage
    /// 2 F2 + F3): the unresolved are listed nearest generation first with
    /// the text that was recorded; a recorded-but-off-the-map place
    /// (Berlin) is told apart from no place at all; and every member
    /// carries the recorded text so the panel can say "recorded as
    /// Massachusetts Bay Colony".
    @Test func theUnplacedAreListedNearestFirstWithTheirRecordedTextAndTheReason() throws {
        let people = T.People(
            ids: ["a", "b", "c", "d", "e", "f"],
            names: ["Ann", "Bob", "Cal", "Dan", "Eve", "Fay"],
            surnames: ["Breen", "Breen", "Latta", "Latta", "Smith", "Smith"],
            birthYears: [1700, 1900, nil, 1850, 1650, 1750],
            generations: [3, 1, nil, 2, 1, 2],
            lines: [.first, .first, .second, .second, .first, .second],
            unitKeys: ["usa-massachusetts", nil, nil, "sct", nil, nil],
            recordedPlaces: ["Shrewsbury, Massachusetts Bay Colony", "Berlin, Germany", nil, "Lothian, Scotland", "   ", "Europe"])
        let r = try T.counts(people: people, visited: [0, 1, 2, 3, 4, 5])
        #expect(r.totals == T.Totals(considered: 6, resolved: 2, countryOnly: 1, unresolved: 4, unsupported: 2),
                "Berlin and Europe were recorded; Cal's nil and Eve's blank were not")
        #expect(r.totals.noRecordedPlace == 2)
        // Nearest generation first (1: Bob, Eve by surname; 2: Fay; unknown last: Cal).
        #expect(r.unplaced.map(\.id) == ["b", "e", "f", "c"])
        #expect(r.unplaced.first == T.Member(id: "b", name: "Bob", birthYear: 1900, generation: 1, line: .first,
                                             recordedPlace: "Berlin, Germany"))
        #expect(r.unplaced[1].recordedPlace == "   ", "carried verbatim; the tally only judged it blank")
        #expect(r.unplaced[3].recordedPlace == nil)
        // Members keep the recorded text too — the colonial tooltip.
        #expect(r.counts["usa-massachusetts"]?.members.first?.recordedPlace == "Shrewsbury, Massachusetts Bay Colony")
        #expect(r.counts["sct"]?.members.first?.recordedPlace == "Lothian, Scotland")
        // The limit caps the list, never the totals.
        let capped = try T.counts(people: people, visited: [0, 1, 2, 3, 4, 5], unplacedLimit: 2)
        #expect(capped.unplaced.map(\.id) == ["b", "e"])
        #expect(capped.totals.unresolved == 4)
        #expect(try T.counts(people: people, visited: [0, 1, 2, 3, 4, 5], unplacedLimit: 0).unplaced.isEmpty)
        // The mask and the ceiling apply to the unplaced as to everyone.
        let masked = try T.counts(people: people, visited: [0, 1, 2, 3, 4, 5], mask: [true, false, true, true, true, true])
        #expect(masked.unplaced.map(\.id) == ["e", "f", "c"])
        #expect(masked.totals.unsupported == 1)
        let early = try T.counts(people: people, visited: [0, 1, 2, 3, 4, 5], yearCeiling: 1700)
        #expect(early.unplaced.map(\.id) == ["e"], "1650 only; Cal has no year")
        // Without a recordedPlaces column nothing was recorded: all "no place".
        let bare = try T.counts(people: Self.people, visited: Self.all)
        #expect(bare.totals.unsupported == 0 && bare.unplaced.map(\.id) == ["I5"])
        #expect(bare.unplaced.first?.recordedPlace == nil)
        #expect(T.Result.empty.unplaced.isEmpty)
    }

    @Test func memberLimitCapsTheListButNotTheCount() throws {
        let r = try T.counts(people: Self.people, visited: Self.all, memberLimit: 2)
        let york = try #require(r.counts["eng-yorkshire"])
        #expect(york.people == 3)
        #expect(york.members.map(\.id) == ["I1", "I2"])
        let zero = try T.counts(people: Self.people, visited: Self.all, memberLimit: 0)
        #expect(zero.counts["eng-yorkshire"]?.members.isEmpty == true)
        #expect(zero.counts["eng-yorkshire"]?.people == 3)
    }

    // MARK: Mask semantics

    @Test func nilMaskCountsEveryoneAndAllFalseCountsNobody() throws {
        let everyone = try T.counts(people: Self.people, visited: Self.all, mask: nil)
        #expect(everyone.totals.considered == 8)
        let nobody = try T.counts(people: Self.people, visited: Self.all, mask: Array(repeating: false, count: 8))
        #expect(nobody.totals == T.Totals(considered: 0, resolved: 0, countryOnly: 0, unresolved: 0))
        #expect(nobody.counts.isEmpty)
        #expect(nobody == T.Result.empty)
    }

    @Test func aMaskOfTheWrongLengthIsRefused() {
        #expect(throws: T.TallyError.maskLengthMismatch(mask: 3, visited: 8)) {
            try T.counts(people: Self.people, visited: Self.all, mask: [true, true, true])
        }
        #expect(throws: T.TallyError.maskLengthMismatch(mask: 9, visited: 8)) {
            try T.counts(people: Self.people, visited: Self.all, mask: Array(repeating: true, count: 9))
        }
    }

    @Test func columnsOfTheWrongLengthAreRefused() {
        let bad = T.People(ids: ["a", "b"], names: ["A", "B"], surnames: ["A"], birthYears: [nil, nil],
                           generations: [0, 0], lines: [.first, .first], unitKeys: ["eng", "eng"])
        #expect(throws: T.TallyError.columnLengthMismatch(column: "surnames", count: 1, expected: 2)) {
            try T.counts(people: bad, visited: [0, 1])
        }
        let badKeys = T.People(ids: ["a", "b"], names: ["A", "B"], surnames: ["A", "B"], surnameKeys: ["a"],
                               birthYears: [nil, nil], generations: [0, 0], lines: [.first, .first], unitKeys: ["eng", "eng"])
        #expect(throws: T.TallyError.columnLengthMismatch(column: "surnameKeys", count: 1, expected: 2)) {
            try T.counts(people: badKeys, visited: [0, 1])
        }
        let badPlaces = T.People(ids: ["a", "b"], names: ["A", "B"], surnames: ["A", "B"], birthYears: [nil, nil],
                                 generations: [0, 0], lines: [.first, .first], unitKeys: ["eng", "eng"],
                                 recordedPlaces: ["England"])
        #expect(throws: T.TallyError.columnLengthMismatch(column: "recordedPlaces", count: 1, expected: 2)) {
            try T.counts(people: badPlaces, visited: [0, 1])
        }
    }

    /// The Highlight mask, exactly as the app builds it: OR within a group,
    /// AND across — the map filters as the fan highlights.
    @Test func theHighlightMaskFiltersTheMapAsItHighlightsTheFan() throws {
        let keys = TreeWalkHighlight.surnameKeys(Self.people.surnames)
        func tally(_ s: TreeWalkHighlight.Selection) throws -> T.Result {
            let mask = TreeWalkHighlight.mask(visited: Self.all, selection: s, surnameKeys: keys, regions: Self.regions)
            return try T.counts(people: Self.people, visited: Self.all, mask: mask)
        }
        let breen = try tally(.init(surnames: ["breen"]))
        #expect(breen.totals.considered == 5, "surname only: I1 I2 I4 I7 I8")
        #expect(breen.counts["eng-yorkshire"]?.people == 3)
        #expect(breen.counts["usa-massachusetts"]?.people == 2)
        #expect(breen.counts["sct-fife"] == nil)
        let scots = try tally(.init(regions: [BirthplaceClassifier.BirthRegion.scotland.rawValue]))
        #expect(scots.totals.considered == 1, "region only")
        #expect(scots.counts.keys.sorted() == ["sct-fife"])
        let both = try tally(.init(surnames: ["mcgill", "smith"], regions: [BirthplaceClassifier.BirthRegion.england.rawValue]))
        #expect(both.totals.considered == 1, "OR within surnames, AND with the region: only Cal McGill in England")
        #expect(both.counts.keys.sorted() == ["eng"])
        #expect(both.totals.countryOnly == 1)
    }

    // MARK: Year ceiling

    @Test func yearCeilingKeepsBirthsUpToTheYearAndDropsUnknownYears() throws {
        let none = try T.counts(people: Self.people, visited: Self.all, yearCeiling: nil)
        #expect(none.totals.considered == 8, "no ceiling: unknown years count")
        let early = try T.counts(people: Self.people, visited: Self.all, yearCeiling: 1700)
        #expect(early.totals.considered == 3, "1700, 1650, 1690 — not 1720, and not the unknown year")
        #expect(early.counts["eng-yorkshire"]?.people == 2)
        #expect(early.counts["eng"] == nil, "Cal McGill has no birth year")
        let late = try T.counts(people: Self.people, visited: Self.all, yearCeiling: 3000)
        #expect(late.totals.considered == 7, "a ceiling drops the unknown year even when it excludes no one else")
        let masked = try T.counts(people: Self.people, visited: Self.all,
                                  mask: [false, true, true, true, true, true, true, true], yearCeiling: 1700)
        #expect(masked.totals.considered == 2, "mask and ceiling compose: 1650 and 1690 remain")
    }

    // MARK: Visited hygiene

    @Test func duplicateAndOutOfRangeOrdinalsAreCountedOnceOrSkipped() throws {
        let r = try T.counts(people: Self.people, visited: [0, 0, 0, 1, 99, -1, 1])
        #expect(r.totals.considered == 2)
        #expect(r.counts["eng-yorkshire"]?.people == 2)
        #expect(r.counts["eng-yorkshire"]?.members.count == 2)
        let masked = try T.counts(people: Self.people, visited: [0, 0], mask: [false, true])
        #expect(masked.totals.considered == 1, "the second listing is the one the mask lets through")
        let empty = try T.counts(people: Self.people, visited: [])
        #expect(empty == T.Result.empty)
    }

    // MARK: Scale

    /// 40k people over ~120 units (Zipf-ish: a few big counties, a long
    /// tail), with the full member ordering and surname ranking in the
    /// measured path. Budget 50 ms (Debug, load-aware).
    @Test func fortyThousandPeopleUnderBudget() throws {
        let n = 40_000
        let keys: [String?] = (0..<n).map { i in
            if i % 25 == 0 { return nil }
            if i % 7 == 0 { return "eng" }
            return "eng-u\(i % 120 == 0 ? 0 : (i * 7919) % 120)"
        }
        let surnames = (0..<n).map { "Surname\($0 % 3_000)" }
        // The app folds surnames once per walk (Highlight); the tally takes them.
        let people = T.People(
            ids: (0..<n).map { "I\($0)" },
            names: (0..<n).map { "Person \($0 % 977)" },
            surnames: surnames,
            surnameKeys: TreeWalkHighlight.surnameKeys(surnames),
            birthYears: (0..<n).map { $0 % 11 == 0 ? nil : 1500 + $0 % 400 },
            generations: (0..<n).map { $0 % 13 == 0 ? nil : $0 % 20 },
            lines: (0..<n).map { L.allCases[$0 % 4] },
            unitKeys: keys)
        let visited = Array(0..<n)
        let mask: [Bool] = (0..<n).map { $0 % 3 != 0 }
        var plain: T.Result?
        var filtered: T.Result?
        // Thread CPU time (GH #208): the pass is synchronous and single-threaded.
        var wall: Duration = .zero
        let loadBefore = TimingBudget.sampleLoad()
        let cpu = TimingBudget.measureThreadCPUTime {
            wall = ContinuousClock().measure {
                plain = try? T.counts(people: people, visited: visited)
                filtered = try? T.counts(people: people, visited: visited, mask: mask, yearCeiling: 1800)
            }
        }
        print("[family-map] tally 40k ×2: cpu \(cpu), wall \(wall) (\(TimingBudget.loadDescription()))")
        expectWithinTimingBudget("two 40k family-map tallies (CPU)", measured: cpu,
                                 budget: .milliseconds(50) * 2,   // two tallies measured
                                 loadBefore: loadBefore)
        let r = try #require(plain)
        #expect(r.totals.considered == n)
        #expect(r.totals.unresolved == n / 25)
        #expect(r.counts.values.reduce(0) { $0 + $1.people } == r.totals.resolved)
        #expect(r.counts["eng"]?.members.count == 200)
        #expect(r.counts["eng"]?.topSurnames.count == 10)
        let f = try #require(filtered)
        #expect(f.totals.considered < r.totals.considered)
    }
}
