// RollCallMixTests.swift
// The Roll Call MIX (Rick 2026-10-04: "it always picks the same people …
// every 3rd time a random selection"): a seeded shuffle replaces priority
// order in step 2. Same seed → same list; different seeds → different
// people; balance and privacy unchanged. Synthetic people only.

import Foundation
import Testing
@testable import VideoScanCore

private func person(_ n: Int, line: TreeWalk.Line = .first, portrait: Bool = false) -> RollCall.Person {
    RollCall.Person(id: "@I\(n)@", name: "Person\(n) Testperson", birthDate: String(1700 + n),
                    deathDate: String(1760 + n), birthPlace: "Town, Samplecounty, Ireland",
                    generation: 3, line: line, hasPortrait: portrait)
}

@Suite("RollCall mix")
struct RollCallMixTests {

    /// 300 people; the first 12 have portraits, so the usual picks are
    /// always those 12 first.
    private let people: [RollCall.Person] = (0..<150).map { person($0, line: .first, portrait: $0 < 6) }
        + (150..<300).map { person($0, line: .second, portrait: $0 < 156) }

    private func ids(_ seed: UInt64?) -> Set<String> {
        Set(RollCall.build(people, options: .init(limit: 20, shuffleSeed: seed)) { _ in .deceased }.map(\.id))
    }

    @Test func sameSeedSameList() {
        #expect(ids(42) == ids(42))
    }

    @Test func differentSeedsPickDifferentPeople() {
        #expect(ids(1) != ids(2))
        #expect(ids(1) != ids(nil), "the mix is not the usual picks")
    }

    @Test func withoutASeedTheUsualPicksAreUnchanged() {
        let list = RollCall.build(people, options: .init(limit: 20)) { _ in .deceased }
        #expect(list.filter(\.hasPortrait).count == 12, "portraits still chosen first")
    }

    @Test func theMixKeepsTheLinesBalanced() {
        let list = RollCall.build(people, options: .init(limit: 20, shuffleSeed: 7)) { _ in .deceased }
        #expect(list.filter { $0.line == .first }.count == 10)
        #expect(list.filter { $0.line == .second }.count == 10)
    }

    @Test func theMixStillLeavesOutTheLiving() {
        let list = RollCall.build(people, options: .init(limit: 40, shuffleSeed: 9)) { p in
            p.id.hasSuffix("7@") ? .livingPrivate : .deceased
        }
        #expect(!list.contains { $0.id.hasSuffix("7@") })
    }

    @Test func seededGeneratorIsDeterministic() {
        var a = SeededGenerator(seed: 123), b = SeededGenerator(seed: 123)
        #expect((0..<5).map { _ in a.next() } == (0..<5).map { _ in b.next() })
    }
}
