// HallieAggregateFallbackTests.swift
// GH #182: an aggregate/coOccurrence anchor the lane cannot resolve is not
// a dead end — a known person becomes a presence search, a known surname
// the surname tree, anything else the honest decline. Pure rules.

import Foundation
import Testing
@testable import VideoScan

@Suite("Hallie — aggregate anchor fallback (GH #182)")
struct HallieAggregateFallbackTests {
    typealias F = HallieAggregateFallback
    private let person: (String) -> Bool = { ["rick", "rick breen", "donna"].contains($0.lowercased()) }
    private let surname: (String) -> Bool = { ["breen", "latta"].contains($0.lowercased()) }

    @Test func keywordsDropAnchorsLeadsAndStopWords() {
        let k = F.keywords(question: "show rick breen playing guitar video", anchors: ["rick breen"])
        #expect(k.keywords == ["playing", "guitar"] && k.wantsVideo)
        let k2 = F.keywords(question: "what are the names of rick's sons?", anchors: ["rick"])
        #expect(k2.keywords == ["sons"] && !k2.wantsVideo)
        #expect(F.keywords(question: "show me rick", anchors: ["rick"]).keywords.isEmpty)
    }

    @Test func routes() {
        #expect(F.route(question: "show rick playing guitar", anchors: ["rick"], unresolved: ["rick"],
                        isKnownPerson: person, isKnownSurname: surname)
                == .presence(people: ["rick"], keywords: ["playing", "guitar"], wantsVideo: false))
        #expect(F.route(question: "tell me about the breen family", anchors: ["breen"], unresolved: ["breen"],
                        isKnownPerson: person, isKnownSurname: surname) == .surnameTree(surname: "breen"))
        #expect(F.route(question: "who appears with zorro", anchors: ["zorro"], unresolved: ["zorro"],
                        isKnownPerson: person, isKnownSurname: surname) == .decline)
        #expect(F.route(question: "rick and zorro", anchors: ["rick", "zorro"], unresolved: ["zorro"],
                        isKnownPerson: person, isKnownSurname: surname) == .decline, "a mixed pair still declines")
        #expect(F.route(question: "rick and donna together", anchors: ["rick", "donna"], unresolved: [],
                        isKnownPerson: person, isKnownSurname: surname) == .decline, "nothing unresolved → the lane runs")
    }
}
