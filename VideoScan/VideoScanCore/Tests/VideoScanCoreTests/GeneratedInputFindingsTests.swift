// GeneratedInputFindingsTests.swift
// Pins for the bugs the generated-input sweeps found on 2026-10-01 — each
// the MINIMAL input the shrinker reached, with the seed that first found it
// (replay: `SeededGenerator(seed:)` + the property's generator). These are
// RED until the production fix lands; each then stays as a sensor.
//
// The sweeps that found them: PlaceClassificationPropertyTests,
// GedcomDatePropertyTests, GedcomParserPropertyTests (this target).

import Foundation
import Testing
@testable import VideoScanCore

@Suite("Found by generated inputs (2026-10-01)")
struct GeneratedInputFindingsTests {

    // F1 — FamilyTreeResearchLinks.regions: a US place written with an old
    // state abbreviation ("Conn", "Penna.", "Ind.", "N. H."), or a postal
    // code that is not its own comma part ("Scotland CT"), is not seen as
    // American, so the town / county name sends the person to the British
    // or Irish archives. Same class as the morning's "Derry, NH" bug.
    // FamilyTreeResearchLinks.swift:162-163 (isUS) and :109-111 (usMarkers).
    @Test("F1: US places in old abbreviations are never sent to British-Isles archives", arguments: [
        "Kent, Conn",            // seed 0xa65fce3cfad8d485 → [england]
        "New London, Conn.",     // seed 0x2b4472e2c147b77a → [england]  ("London")
        "Scotland, Conn",        // seed 0x4a7bfbb6ee65b481 → [scotland]
        "Ireland, Ind.",         // seed 0xe91dfe5acf7f6f96 → [ireland]
        "Antrim, N. H.",         // seed 0x19086aca215412d4 → [ireland]
        "Londonderry, N. H.",    // seed 0x99f47ecc755171a3 → [ireland]
        "Somerset, Penna.",      // seed 0xb67df599c0c7d58c → [england]
        "Scotland CT",           // seed 0xd8b0f5af5b21cfd3 → [scotland]
        "Edinburgh IN",          // per-reader sweep → [scotland]
    ])
    func researchLinksOldAbbreviations(place: String) {
        #expect(FamilyTreeResearchLinks.regions(ofPlace: place) == [.unitedStates])
    }

    // F2 — FamilyTreeResearchLinks.regions: "Boston" is a bare US marker,
    // so the original Boston, in Lincolnshire, also gets US archives.
    // FamilyTreeResearchLinks.swift:110.
    @Test("F2: Boston, Lincolnshire, England is England only")   // seed 0xb051c8e4cb781006
    func researchLinksEnglishBoston() {
        #expect(FamilyTreeResearchLinks.regions(ofPlace: "Boston, Lincolnshire, England") == [.england])
    }

    // F3 — "New South Wales" without "Australia" is read as Wales by four
    // of the five readers: the region / classifier fall back to the LAST
    // TOKEN ("Wales"), and the unit resolver's phrase scan finds "wales"
    // (its New-World-prefix rule knows "New", not "New South").
    // BirthplaceClassifier+Region.swift:97-107, BirthplaceClassifier.swift:111,
    // BirthplaceUnitResolver.swift:290-315. The card flies the Welsh flag.
    @Test("F3: New South Wales is never Wales", arguments: [
        "New South Wales",              // seed 0x120949b2c5e5fb2c
        "Sydney, New South Wales",
        "Goulburn, Colony of New South Wales",
    ])
    func newSouthWales(place: String) {
        #expect(BirthplaceClassifier.region(place) != .wales)
        #expect(BirthplaceClassifier.classify(place).country != BirthplaceClassifier.unitedKingdom)
        #expect(LifeAndTimes.region(ofPlace: place) != .wales)
        #expect(BirthplaceUnitResolver.resolve(place)?.country != .wales)
    }

    // F4 — No commas: a two-letter dotted state ("Va.", "Pa.", "Ky.") is
    // taken for a sentence-ending period, so the state is lost — the
    // resolver shades only the US outline and research links see nothing.
    // BirthplaceClassifier.isAbbreviation (BirthplaceClassifier.swift:178-184)
    // does not accept the capitalised two-letter forms `usAbbreviation` does.
    // The worst of the class: the town to the left of the lost state then
    // decides — "Wales Ma. U.S.A." (Wales, Massachusetts) is WALES to Life
    // & Times, "Norway Me. US" (Norway, Maine) is "elsewhere".
    @Test("F4: a dotted two-letter state survives a no-comma place", arguments: [
        ("Portsmouth Va. US", "Virginia"),   // seed 0x32692726bfccecbf
        ("Wales Ma. U.S.A.", "Massachusetts"),
        ("Norway Me. US", "Maine"),
        ("Poland Me. USA", "Maine"),
    ])
    func dottedTwoLetterStateNoCommas(place: String, state: String) {
        #expect(BirthplaceUnitResolver.resolve(place)?.unitKey == FamilyMapKey.unitKey(country: .unitedStates, name: state))
        let region = BirthplaceClassifier.region(place)
        #expect(region == .restOfUS || region == .newEngland, "region = \(region)")
        #expect(LifeAndTimes.region(ofPlace: place) == .unitedStates)
    }

    // F5 — Life & Times: "Down, Ireland" (County Down) is not Northern
    // Ireland — the marker list has "co down" / "county down" but not the
    // bare county, which the map resolver reads as nir-down.
    // LifeAndTimesRegion.swift:132-137.
    @Test("F5: Down, Ireland is Northern Ireland")   // seed 0x33ded5efb916d3c8
    func countyDown() {
        #expect(LifeAndTimes.region(ofPlace: "Down, Ireland") == .northernIreland)
    }

    // F6 — The classifier does not know "Eng." (the region table does), so
    // "Leeds, Yorkshire, Eng." has no country and no continent for the
    // tree walk's stop rules. BirthplaceClassifier.swift:251.
    @Test("F6: '…, Eng.' is the United Kingdom")   // seed 0x82a9d1a527b2dac4
    func classifierEngAbbreviation() {
        #expect(BirthplaceClassifier.classify("Lancashire, Eng.").country == BirthplaceClassifier.unitedKingdom)
    }

    // F7 — Age at death goes NEGATIVE for a birth and death in the same
    // year when either is year-only: "1838"–"1838" speaks "-1–0" in the
    // tree walk and in the averages. TreeWalkDate.swift:112-114 (no clamp
    // at 0 on the shortest-life bound).
    @Test("F7: age at death is never negative", arguments: [
        ("1838", "1838"),          // seed 0xfc21699ca6bd46e9
        ("8 JUN 1992", "1992"),    // seed 0xacd65f826ffaca4e
        ("1763", "NOV 1763"),      // seed 0xda312197d2818cf3
    ])
    func ageAtDeathNotNegative(birth: String, death: String) {
        let age = AgeAtDeath.between(birth: TreeWalkDate.parse(birth), death: TreeWalkDate.parse(death))
        #expect((age?.minYears ?? 0) >= 0, "spoken \(age?.spoken ?? "nil")")
    }

    // F8 — TreeWalkDate invents a day of the month from a dual year: "OCT
    // 1930/31" → day 31, precision .day. TreeWalkDate.swift:60 takes any
    // ≤ 2-digit token as the day.
    @Test("F8: a dual year is not a day of the month", arguments: ["OCT 1930/31", "NOV 1100/01", "@#DJULIAN@ MAR 1519/20"])
    func dualYearIsNotADay(date: String) {   // seeds 0x207e32e7118966, 0x7ad13f96d3c694fd, 0x1ffe916308054bcd
        let d = TreeWalkDate.parse(date)
        #expect(d?.day == nil)
        #expect(d?.precision == .month)
    }

    // F9 — Life & Times: a birth whose interval OPENS in the event's start
    // year ("FROM 1929", "AFTER 14 JAN 1775") is spoken "was no more than 0
    // when … began, if born by then". The born-around test is strict `>`;
    // it needs `>=`. LivedThrough.swift:390.
    @Test("F9: no 'no more than 0' age", arguments: [
        ("FROM 1929", "Deceased"),             // seed 0xd1be86c407e33bf5 — the Great Depression
        ("AFTER 14 JAN 1775", "AFT 1795"),     // seed 0xdd3651a73e4684e4 — the American Revolution
    ])
    func noHedgedZeroInLivedThrough(birth: String, death: String) {
        let s = LifeAndTimes.Subject(id: "@I1@", name: "Ansel Fenlane", sex: "M", birthDate: birth, deathDate: death,
                                     birthPlace: "Lyon, France", deathPlace: "Boston, Suffolk, Massachusetts, USA")
        let lines = LifeAndTimes.facts(for: s, options: LifeAndTimes.Options(currentYear: 2026))?.storyLines ?? []
        #expect(!lines.contains { $0.contains("no more than 0") }, "\(lines)")
    }

    // F10 — Service leads: a birth with no lower bound ("BEF 1947", "TO
    // 1868") is spoken "was at least 0 when the United States entered the
    // Second World War" — QualifiedAge.at clamps a negative proven-minimum
    // to 0 and the sentence still speaks it. ServiceAge.swift:260 with
    // LivedThrough.swift:142 / :152.
    @Test("F10: no 'at least 0' service age", arguments: [
        ("bef 1947", "ABT 2012", "Middlesex County Virginia USA"),   // seed 0x4d0ace39afcc04c7
        ("TO 1868", "1930", "Boston, Suffolk, Massachusetts, USA"),  // seed 0xbc9aa36156e3e5b6
    ])
    func noHedgedZeroInService(birth: String, death: String, place: String) {
        let s = LifeAndTimes.Subject(id: "@I1@", name: "Ansel Fenlane", sex: "M", birthDate: birth, deathDate: death,
                                     birthPlace: place)
        let lines = LifeAndTimes.facts(for: s, options: LifeAndTimes.Options(currentYear: 2026))?.storyLines ?? []
        #expect(!lines.contains { $0.contains("at least 0 ") }, "\(lines)")
    }

    // F11 — The GEDCOM writer's NOTE (HEAD provenance, military notes) does
    // not read back when a line begins or ends with a space: the parser
    // trims every line, and the writer only protects CONC cut points.
    // GedcomFamilyGraph+Writer.swift:126-150 / GedcomFamilyGraph.swift:486.
    // Low impact today (the provenance sentence is generated text).
    @Test("F11: a NOTE line's edge spaces survive the writer", arguments: ["s ", " \n\nt", "first line \nsecond"])
    func writerNoteEdgeSpaces(note: String) {   // seeds 0x800e7a1adbbcba8a, 0x3c8436e9568c80d6
        let graph = GedcomFamilyGraph(gedcomText: "0 HEAD\n0 @I1@ INDI\n1 NAME Ansel /Fenlane/\n0 TRLR\n")
        let back = GedcomFamilyGraph(gedcomText: graph.gedcomText(provenance: note, now: Date(timeIntervalSince1970: 0)))
        #expect(back.headNote == note)
    }
}
