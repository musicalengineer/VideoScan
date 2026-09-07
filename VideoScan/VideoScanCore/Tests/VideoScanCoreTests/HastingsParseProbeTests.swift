import Foundation
import Testing
@testable import VideoScanCore

/// Rick asked "what country was John Hastings born in?" four times and got
/// only the date back. Is the place lost at PARSE, or dropped by the answer?
/// His record has DEAT before BIRT and a 3 MAP / 4 LATI / 4 LONG block under
/// every PLAC — both worth pinning whatever the answer turns out to be.
@Suite("Probe — Hastings' birthplace survives the parser")
struct HastingsParseProbeTests {
    private let text = """
    0 HEAD
    0 @I1@ INDI
    1 NAME John /Hastings/ 3rd Earl of Pembroke
    1 SEX M
    1 DEAT
    2 DATE 30 December 1389
    2 PLAC Woodstock, Oxfordshire, England
    3 MAP
    4 LATI 51.8472
    4 LONG -1.354
    1 BIRT
    2 DATE 11 October 1372
    2 PLAC Kenilworth, Warwickshire, England
    3 MAP
    4 LATI 52.35
    4 LONG -1.5811
    0 TRLR
    """

    @Test func theParserKeepsBothPlaces() throws {
        let graph = GedcomFamilyGraph(gedcomText: text)
        let p = try #require(graph.people["@I1@"])
        #expect(p.birthDate == "11 October 1372")
        #expect(p.birthPlace == "Kenilworth, Warwickshire, England",
                Comment(rawValue: "birthPlace = \(p.birthPlace ?? "nil")"))
        #expect(p.deathPlace == "Woodstock, Oxfordshire, England",
                Comment(rawValue: "deathPlace = \(p.deathPlace ?? "nil")"))
    }
}
