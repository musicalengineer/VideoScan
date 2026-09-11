// HallieMediaActivityAskTests.swift
// GH #182 (live 2026-09-11): "show rick playing guitar" went to the
// co-occurrence lane. A known person + an activity is a presence search.

import Foundation
import Testing
@testable import VideoScan

@Suite("Hallie — media activity asks (GH #182)")
struct HallieMediaActivityAskTests {
    private let known: (String) -> Bool = { ["rick", "rick breen", "donna", "tim"].contains($0.lowercased()) }
    typealias A = HallieMediaActivityAsk

    @Test func knownPersonPlusActivityIsAPresenceSearch() {
        #expect(A.detect("show rick playing guitar", isKnownPerson: known)
                == .init(person: "Rick", keywords: ["playing", "guitar"], wantsVideo: false))
        #expect(A.detect("show rick breen playing guitar video", isKnownPerson: known)
                == .init(person: "Rick Breen", keywords: ["playing", "guitar"], wantsVideo: true))
        #expect(A.detect("Find Donna at the Cape?", isKnownPerson: known)
                == .init(person: "Donna", keywords: ["cape"], wantsVideo: false))
        #expect(A.detect("play me tim singing", isKnownPerson: known)
                == .init(person: "Tim", keywords: ["singing"], wantsVideo: false))
    }

    @Test func otherShapesAreLeftAlone() {
        #expect(A.detect("show me rick", isKnownPerson: known) == nil, "no remainder")
        #expect(A.detect("show videos of rick", isKnownPerson: known) == nil, "'of' shape belongs to the lineage detector")
        #expect(A.detect("show me rick's biography source", isKnownPerson: known) == nil, "possessive")
        #expect(A.detect("show gladiator playing", isKnownPerson: known) == nil, "unknown person")
        #expect(A.detect("show rick and donna dancing", isKnownPerson: known) == nil, "two people: a search, not this shape")
        #expect(A.detect("tell me about rick playing guitar", isKnownPerson: known) == nil, "no media lead")
        #expect(A.detect("show rick the tree", isKnownPerson: known) == nil, "no activity")
        #expect(A.detect("show rick with donna at the cape", isKnownPerson: known) == nil, "a second known person after 'with'")
        #expect(A.detect("show rick with the dog", isKnownPerson: known)
                == .init(person: "Rick", keywords: ["dog"], wantsVideo: false), "'with' + a thing is still an activity")
    }
}
