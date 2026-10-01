// RollCallTests.swift
// Roll Call (Rick 2026-10-01) — the credits list builder in Core: ordering,
// dedupe, the length cap and its line balance, privacy, the duration clamp,
// and a 100k scale budget. Synthetic people only (public repo).

import Foundation
import Testing
@testable import VideoScanCore

private func person(_ n: Int, born: Int? = nil, gen: Int? = nil, line: TreeWalk.Line = .first,
                    portrait: Bool = false, name: String? = nil, died: String? = nil,
                    place: String? = "Town\(0), Samplecounty, Ireland", inner: Bool = false) -> RollCall.Person {
    RollCall.Person(id: "@I\(n)@", name: name ?? "Person\(n) Testperson",
                    birthDate: born.map(String.init), deathDate: died ?? born.map { String($0 + 60) },
                    birthPlace: place, generation: gen, line: line, hasPortrait: portrait,
                    isInnerCircle: inner)
}

private let allDeceased: (RollCall.Person) -> PersonOfTheDay.Life = { _ in .deceased }

@Suite("RollCall")
struct RollCallTests {

    // MARK: Ordering

    @Test func oldestFirstIsTheDefaultAndUndatedGoLast() {
        let people = [person(1, born: 1900, gen: 1), person(2, born: 1750, gen: 4),
                      person(3, born: nil, gen: 2), person(4, born: 1820, gen: 3)]
        let list = RollCall.build(people, life: allDeceased)
        #expect(list.map(\.id) == ["@I2@", "@I4@", "@I1@", "@I3@"])
        #expect(RollCall.Options().order == .oldestFirst)
    }

    @Test func newestFirstReversesYearsButKeepsUndatedLast() {
        let people = [person(1, born: 1900), person(2, born: 1750), person(3, born: nil), person(4, born: 1820)]
        let list = RollCall.build(people, options: .init(order: .newestFirst), life: allDeceased)
        #expect(list.map(\.id) == ["@I1@", "@I4@", "@I2@", "@I3@"])
    }

    @Test func generationOrdersBothWays() {
        let people = [person(1, born: 1900, gen: 1), person(2, born: 1750, gen: 4),
                      person(3, born: 1960, gen: 0), person(4, born: 1820, gen: 3), person(5, born: 1800, gen: nil)]
        let outward = RollCall.build(people, options: .init(order: .generationOutward), life: allDeceased)
        #expect(outward.map(\.id) == ["@I3@", "@I1@", "@I4@", "@I2@", "@I5@"])
        let inward = RollCall.build(people, options: .init(order: .generationInward), life: allDeceased)
        #expect(inward.map(\.id) == ["@I2@", "@I4@", "@I1@", "@I3@", "@I5@"])
    }

    @Test func sameYearTiesAreDeterministic() {
        let people = [person(2, born: 1800, gen: 3, name: "Bea Testperson"),
                      person(1, born: 1800, gen: 3, name: "Abe Testperson"),
                      person(3, born: 1800, gen: 5, name: "Cal Testperson")]
        let a = RollCall.build(people, life: allDeceased)
        let b = RollCall.build(people.reversed(), life: allDeceased)
        #expect(a == b)
        #expect(a.map(\.name) == ["Cal Testperson", "Abe Testperson", "Bea Testperson"])
    }

    // MARK: Dedupe

    @Test func dedupeByIDAndByNameAndBirthYear() {
        let people = [person(1, born: 1800, gen: 5),
                      person(1, born: 1800, gen: 5),                                        // same id twice
                      person(2, born: 1820, gen: 4, name: "Twin Testperson"),
                      person(3, born: 1820, gen: 4, portrait: true, name: "twin  TESTPERSON"),  // same person recorded twice
                      person(4, born: nil, name: "Same Testperson"),
                      person(5, born: nil, name: "Same Testperson")]                         // undated namesakes stay two
        let list = RollCall.build(people, life: allDeceased)
        #expect(list.count == 4)
        #expect(list.filter { $0.name.lowercased().contains("twin") }.map(\.id) == ["@I3@"], "the row with a portrait wins")
        #expect(list.filter { $0.name == "Same Testperson" }.count == 2)
    }

    @Test func diacriticsFoldInTheDedupeKey() {
        let people = [person(1, born: 1850, name: "Zoë Testperson"), person(2, born: 1850, name: "Zoe Testperson")]
        #expect(RollCall.build(people, life: allDeceased).count == 1)
    }

    // MARK: Cap and balance

    @Test func capLengthAndBalanceTheTwoLines() {
        var people = (0..<200).map { person($0, born: 1700 + $0, gen: 5, line: .first) }
        people += (200..<230).map { person($0, born: 1700 + $0, gen: 5, line: .second) }
        let list = RollCall.build(people, options: .init(limit: 24), life: allDeceased)
        #expect(list.count == 24)
        let first = list.filter { $0.line == .first }.count
        let second = list.filter { $0.line == .second }.count
        #expect(first == 12 && second == 12, "round-robin keeps the sides even: \(first)/\(second)")
    }

    @Test func portraitsAreChosenFirstWhenCapped() {
        var people = (0..<100).map { person($0, born: 1800, gen: 2) }
        people += (100..<105).map { person($0, born: 1700 + $0, gen: 9, portrait: true) }
        let list = RollCall.build(people, options: .init(limit: 8), life: allDeceased)
        #expect(list.filter(\.hasPortrait).count == 5)
    }

    @Test func zeroLimitAndEmptyInputGiveNothing() {
        #expect(RollCall.build([], life: allDeceased).isEmpty)
        #expect(RollCall.build([person(1, born: 1800)], options: .init(limit: 0), life: allDeceased).isEmpty)
        #expect(RollCall.build([person(1, name: "  ?  ")], life: allDeceased).isEmpty)
    }

    // MARK: Privacy

    @Test func livingPrivateLeftOutInnerCircleNameOnly() {
        let people = [person(1, born: 1990, gen: 1, inner: false), person(2, born: 1960, gen: 0, inner: true),
                      person(3, born: 1850, gen: 3)]
        let list = RollCall.build(people) { p in
            p.id == "@I3@" ? .deceased : (p.isInnerCircle ? .livingInnerCircle : .livingPrivate)
        }
        #expect(list.map(\.id).sorted() == ["@I2@", "@I3@"])
        let home = list.first { $0.id == "@I2@" }!
        #expect(home.isLiving && home.years == nil && home.place == nil && home.birthYear == nil)
        let old = list.first { $0.id == "@I3@" }!
        #expect(old.years == "1850–1910")
        #expect(old.place == "Town0, Ireland")
    }

    @Test func lifeIsAskedOnlyForTheRowsConsidered() {
        let people = (0..<5_000).map { person($0, born: 1700 + $0 % 300, gen: $0 % 12, line: $0 % 2 == 0 ? .first : .second) }
        var asked = 0
        let list = RollCall.build(people, options: .init(limit: 36)) { _ in asked += 1; return .deceased }
        #expect(list.count == 36)
        #expect(asked == 36)
    }

    @Test func durationIsClampedToTwentyToFortySeconds() {
        #expect(RollCall.duration(entries: 0) == 20)
        #expect(RollCall.duration(entries: 30) == 27)
        #expect(RollCall.duration(entries: 1_000) == 40)
    }
}

@Suite("RollCallScale")
struct RollCallScaleTests {
    /// Measured 2026-10-01, M4 Max, Debug (swift test): 0.34 s for 100k
    /// (dedupe + priority sort + 36 rows). Budget ≈ 4×.
    static let budget: Duration = .milliseconds(1_500)

    @Test func hundredThousandWalkedPeopleWithinBudget() {
        let lines: [TreeWalk.Line] = [.first, .second, .both, .none]
        let clock = ContinuousClock()
        let start = clock.now
        let people = (0..<100_000).map { i in
            RollCall.Person(id: "@I\(i)@", name: "Person\(i % 9_000) Testperson",
                            birthDate: "\(1600 + i % 400)", deathDate: "\(1660 + i % 400)",
                            birthPlace: i % 3 == 0 ? nil : "Town\(i % 500), Samplecounty, Ireland",
                            generation: i % 25, line: lines[i % 4], hasPortrait: i % 2_000 == 0, storyCount: i % 777 == 0 ? 1 : 0)
        }
        let list = RollCall.build(people, life: { _ in .deceased })
        let elapsed = clock.now - start
        print("[rollcall-scale] 100k → \(list.count) rows in \(elapsed) (\(TimingBudget.loadDescription()))")
        #expect(list.count == 36)
        #expect(Set(list.map(\.id)).count == 36)
        let ceiling = TimingBudget.loadAwareDebugCeiling(Self.budget)
        #expect(elapsed < ceiling, "100k roll call took \(elapsed), ceiling \(ceiling)")
    }
}
