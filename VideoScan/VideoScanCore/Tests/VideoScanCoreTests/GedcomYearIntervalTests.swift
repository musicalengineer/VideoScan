// GedcomYearIntervalTests.swift
// codex #721/#723: GEDCOM qualifiers are meaning, not noise. "AFT 1837"
// is not "1837". Pure.

import Testing
@testable import VideoScanCore

struct GedcomYearIntervalTests {
    typealias I = GedcomYearInterval

    @Test func qualifiersBecomeBounds() {
        #expect(I.parse("1837") == .exact(1837))
        #expect(I.parse("4 MAR 1837") == .exact(1837))
        #expect(I.parse("BEF 1838") == I(lower: nil, upper: 1837, qualifier: .before, anchor: 1838))
        #expect(I.parse("BEF 4 MAR 1838") == I(lower: nil, upper: 1838, qualifier: .before, anchor: 1838))
        #expect(I.parse("bef mar 1838")?.upper == 1838, "a month alone still means the year is possible")
        #expect(I.parse("AFT 1837") == I(lower: 1838, upper: nil, qualifier: .after, anchor: 1837))
        #expect(I.parse("AFT 12 JUN 1837") == I(lower: 1837, upper: nil, qualifier: .after, anchor: 1837))
        #expect(I.parse("ABT 1700") == I(lower: 1698, upper: 1702, qualifier: .about, anchor: 1700))
        #expect(I.parse("CAL 1700") == I(lower: 1698, upper: 1702, qualifier: .calculated, anchor: 1700))
        #expect(I.parse("EST 1700") == I(lower: 1698, upper: 1702, qualifier: .estimated, anchor: 1700))
        #expect(I.parse("INT 1700 (from age at death)")?.qualifier == .estimated)
        #expect(I.parse("BET 1930 AND 1931") == I(lower: 1930, upper: 1931, qualifier: .between))
        #expect(I.parse("BET 1931 AND 1930")?.lower == 1930, "reversed bounds are normalised")
        #expect(I.parse("FROM 1900 TO 1910") == I(lower: 1900, upper: 1910, qualifier: .range))
        #expect(I.parse("FROM 1900") == I(lower: 1900, upper: nil, qualifier: .range))
        #expect(I.parse("TO 1910") == I(lower: nil, upper: 1910, qualifier: .range))
        #expect(I.parse("@#DJULIAN@ BEF 1700")?.qualifier == .before)
        #expect(I.parse(nil) == nil)
        #expect(I.parse("unknown") == nil)
        #expect(I.parse("BEF") == nil)
        #expect(I.approximateSlack == 2)
    }

    @Test func spokenForms() {
        #expect(I.parse("1737")?.spoken == "1737")
        #expect(I.parse("BEF 1800")?.spoken == "before 1800")
        #expect(I.parse("BEF 3 JAN 1800")?.spoken == "before 1800")
        #expect(I.parse("AFT 1837")?.spoken == "after 1837")
        #expect(I.parse("ABT 1700")?.spoken == "about 1700")
        #expect(I.parse("BET 1700 AND 1710")?.spoken == "between 1700 and 1710")
        #expect(I.parse("FROM 1900")?.spoken == "1900 or later")
        #expect(I.parse("TO 1910")?.spoken == "1910 or earlier")
    }

    @Test func boundPredicates() {
        let bef = I.parse("BEF 1838")!
        let aft = I.parse("AFT 1837")!
        let abt = I.parse("ABT 1838")!
        #expect(bef.isEntirelyBefore(1838) && !bef.isEntirelyAtOrAfter(1838))
        #expect(!aft.isEntirelyBefore(1838) && aft.isEntirelyAtOrAfter(1838))
        #expect(!abt.isEntirelyBefore(1838) && !abt.isEntirelyAtOrAfter(1838))
        #expect(I.parse("BEF 1800")!.endsBefore(I.parse("AFT 1850")!))
        #expect(!I.parse("AFT 1800")!.endsBefore(I.parse("BEF 1850")!), "open ends never prove a contradiction")
    }

    @Test func personExposesIntervalsBesideTheLegacyYears() {
        let g = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I1@ INDI
        1 NAME After /Eighteen/
        1 BIRT
        2 DATE ABT 1760
        1 DEAT
        2 DATE AFT 1837
        0 TRLR
        """)
        let p = g.people["@I1@"]!
        #expect(p.deathYear == 1837, "legacy accessor unchanged (display)")
        #expect(p.deathYearInterval == I.parse("AFT 1837"))
        #expect(p.birthYearInterval == I.parse("ABT 1760"))
    }
}
