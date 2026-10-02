// NightlyReview20261002Tests.swift
// Sensors for two claims the nightly local-model review (team-channel #1832)
// made on 2026-10-02 and that were checked against main and REFUTED. Each
// test is the reviewer's own concrete case; it passes on main, and stays so
// a later change cannot make the claim true.

import Testing
@testable import VideoScanCore

@Suite("Nightly review 2026-10-02 — refuted claims, pinned")
struct NightlyReview20261002Tests {

    // Claim on a5808183: `verbatimValue` splits with
    // omittingEmptySubsequences: true, so "1 CONC  compositor" loses the
    // chunk's leading space. It does not: split stops after maxSplits (2)
    // and returns the rest of the line untouched, double space included.
    // (C++: like strtok twice, then keeping the raw remainder pointer.)
    @Test("a CONC chunk's own leading space is kept")
    func concLeadingSpaceKept() {
        #expect(GedcomFamilyGraph.verbatimValue("1 CONC  compositor") == " compositor")
        #expect(GedcomFamilyGraph.verbatimValue("2 CONC  compositor\r") == " compositor")
        #expect(GedcomFamilyGraph.verbatimValue("  1 NOTE worked as a ") == "worked as a ")
        let graph = GedcomFamilyGraph(gedcomText:
            "0 HEAD\n1 NOTE worked as a\n2 CONC  compositor\n0 @I1@ INDI\n1 NAME Ansel /Fenlane/\n0 TRLR\n")
        #expect(graph.headNote == "worked as a compositor")
    }

    // Claim on 7d0200a5: `.ireland.covers(.ireland)` is false, so a person
    // recorded in the Republic drops out of an Irish-line filter. `covers`
    // returns true for self == place before the switch.
    @Test("Ireland covers itself and Northern Ireland")
    func irelandCoversItself() {
        typealias Region = LifeAndTimes.Region
        #expect(Region.ireland.covers(.ireland))
        #expect(Region.ireland.covers(.northernIreland))
        #expect(!Region.ireland.covers(.england))
    }
}
