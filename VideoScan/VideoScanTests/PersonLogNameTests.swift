// PersonLogNameTests.swift
// DECISIONS 2026-11-25 (GH #466): in ~/Library/Logs/VideoScan the deceased
// are named in full; the living by People-tab nickname or first name only,
// never by surname; unknown dates are living (2026-10-10 rule).
//
// Logic (the rule), truth (each source of a person — tree record, profile,
// bare name — gets the same verdict), isolation (poisoned inputs: blank,
// surname-only, a nickname that carries the surname, a "?" stub). Pure: no
// files, no defaults, a fixed clock. Every name here is invented.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private let tree = """
0 HEAD
0 @I1@ INDI
1 NAME Wendell Arbo /Quistgaard/
1 BIRT
2 DATE 3 MAY 1931
1 DEAT
2 DATE 9 SEP 2001
0 @I2@ INDI
1 NAME Tamsin /Quistgaard/
1 BIRT
2 DATE 12 JUN 1962
0 @I3@ INDI
1 NAME Orrin /Vellacourt/
1 BIRT
2 DATE ABT 1890
0 @I4@ INDI
1 NAME Pell /Ostrander-Kiv/
0 @I5@ INDI
1 NAME /Marrowby/
0 @I6@ INDI
1 NAME Ilse /Brandvold/
1 DEAT
2 DATE Y
0 TRLR
"""

/// 2026-11-25 12:00 UTC: a fixed "now" so the 100-year line is 1926.
private let now = Date(timeIntervalSince1970: 1_795_608_000)
private var utc: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}
private func date(_ y: Int) -> Date { utc.date(from: DateComponents(year: y, month: 6, day: 1))! }
private func person(_ id: String) -> GedcomFamilyGraph.Person { GedcomFamilyGraph(gedcomText: tree).people[id]! }

@Suite("PersonLogName — the one rule for naming a person in the log (#466)")
struct PersonLogNameTests {

    // MARK: Tree records

    @Test func deceasedTreePersonIsNamedInFull() {
        #expect(PersonLogName.of(person("@I1@"), now: now, calendar: utc) == "Wendell Arbo Quistgaard")
    }

    @Test func aRecordedDeathWithNoDateIsDeceased() {
        #expect(PersonLogName.of(person("@I6@"), now: now, calendar: utc) == "Ilse Brandvold")
    }

    @Test func bornBefore1927WithNoDeathIsNamedInFull() {
        #expect(PersonLogName.of(person("@I3@"), now: now, calendar: utc) == "Orrin Vellacourt")
    }

    @Test func livingTreePersonIsFirstNameOnlyAndNeverTheSurname() {
        let shown = PersonLogName.of(person("@I2@"), now: now, calendar: utc)
        #expect(shown == "Tamsin")
        #expect(!shown.contains("Quistgaard"))
    }

    @Test func undatedTreePersonIsTreatedAsLiving() {
        let shown = PersonLogName.of(person("@I4@"), now: now, calendar: utc)
        #expect(shown == "Pell")
        #expect(!shown.contains("Ostrander"))
        #expect(!shown.contains("Kiv"))
    }

    @Test func aLivingSurnameOnlyRecordFallsBackAndNamesNoOne() {
        #expect(PersonLogName.of(person("@I5@"), now: now, calendar: utc) == PersonLogName.livingFallback)
    }

    @Test func treeNicknameWinsForTheLiving() {
        #expect(PersonLogName.of(person("@I2@"), nickname: "Tam", now: now, calendar: utc) == "Tam")
    }

    @Test func aNicknameCarryingTheSurnameIsRefused() {
        #expect(PersonLogName.of(person("@I2@"), nickname: "Aunt Quistgaard", now: now, calendar: utc) == "Tamsin")
        // Half of a double-barrelled surname is a surname too.
        #expect(PersonLogName.of(person("@I4@"), nickname: "Kiv", now: now, calendar: utc) == "Pell")
    }

    // MARK: People-tab profiles

    @Test func livingProfileIsItsNicknameNeverItsSurname() {
        var p = POIProfile(name: "Bertrand", referencePath: "")
        p.surname = "Halloway"
        p.aliases = ["Bertie"]
        p.birthdate = date(1958)
        let shown = PersonLogName.of(profile: p, now: now, calendar: utc)
        #expect(shown == "Bertie")
        #expect(!shown.contains("Halloway"))
    }

    @Test func livingProfileWithoutNicknameIsItsFirstName() {
        // A legacy profile whose short name still holds a full name.
        let p = POIProfile(name: "Marisol Fenwright", referencePath: "")
        #expect(PersonLogName.of(profile: p, now: now, calendar: utc) == "Marisol")
    }

    @Test func aMaidenNameIsASurnameToo() {
        var p = POIProfile(name: "Odile", referencePath: "")
        p.maidenName = "Strand"
        p.aliases = ["Strand"]
        #expect(PersonLogName.of(profile: p, now: now, calendar: utc) == "Odile")
    }

    @Test func deceasedProfileIsItsFullName() {
        var p = POIProfile(name: "Gus", referencePath: "")
        p.surname = "Penhallow"
        p.aliases = ["Grampa Gus"]
        p.deathdate = date(1999)
        #expect(PersonLogName.of(profile: p, now: now, calendar: utc) == "Gus Penhallow")
    }

    @Test func profileBornBefore1927WithNoDeathIsNamedInFull() {
        var p = POIProfile(name: "Hester", referencePath: "")
        p.surname = "Calloway"
        p.birthdate = date(1920)
        #expect(PersonLogName.of(profile: p, now: now, calendar: utc) == "Hester Calloway")
    }

    @Test func profileWithUnknownDatesIsTreatedAsLiving() {
        var p = POIProfile(name: "Ansel", referencePath: "")
        p.surname = "Drummore"
        #expect(PersonLogName.of(profile: p, now: now, calendar: utc) == "Ansel")
    }

    // MARK: Bare names

    @Test func aBareNameWithNoRecordIsTreatedAsLiving() {
        let shown = PersonLogName.named("Corwin Ashgrove", now: now, calendar: utc)
        #expect(shown == "Corwin")
    }

    @Test func aBareNameWithOneMatchingRecordTakesThatRecordsVerdict() {
        #expect(PersonLogName.named("Wendell Arbo Quistgaard", matches: [person("@I1@")],
                                    now: now, calendar: utc) == "Wendell Arbo Quistgaard")
    }

    @Test func aBareNameWithSeveralMatchesIsTreatedAsLiving() {
        #expect(PersonLogName.named("Wendell Arbo Quistgaard", matches: [person("@I1@"), person("@I1@")],
                                    now: now, calendar: utc) == "Wendell")
    }

    @Test func aBareNameWithAnOldBirthYearIsNamedInFull() {
        #expect(PersonLogName.named("Linnea Ostergaard", birthYear: 1861, now: now, calendar: utc)
                == "Linnea Ostergaard")
        #expect(PersonLogName.named("Linnea Ostergaard", birthYear: 1990, now: now, calendar: utc) == "Linnea")
        #expect(PersonLogName.named("Linnea Ostergaard", birthYear: nil, now: now, calendar: utc) == "Linnea")
    }

    // MARK: Isolation (poisoned inputs)

    @Test func blankAndStubNamesNeverLeakOrCrash() {
        #expect(PersonLogName.render(fullName: "", status: .living) == PersonLogName.livingFallback)
        #expect(PersonLogName.render(fullName: "   ", status: .deceased) == PersonLogName.livingFallback)
        #expect(PersonLogName.render(fullName: "? Smallbridge", status: .living) == PersonLogName.livingFallback)
        #expect(PersonLogName.render(fullName: "Ivo  Tregarth", nickname: "  ", status: .living) == "Ivo")
    }

    @Test func surnameMatchIgnoresCaseAndDiacritics() {
        #expect(PersonLogName.render(fullName: "Zélie Morvan", nickname: "MORVAN", status: .living) == "Zélie")
        #expect(PersonLogName.render(fullName: "Zelie Morvan", nickname: "Mórvan", status: .living) == "Zelie")
    }

    @Test func theLivingVerdictIsLifeStatusesConservativeRule() {
        #expect(LifeStatus.privacyVerdict(deathRecorded: false, birthYear: 1926, now: now, calendar: utc) == .presumedDeceased)
        #expect(LifeStatus.privacyVerdict(deathRecorded: false, birthYear: 1927, now: now, calendar: utc) == .living)
        #expect(LifeStatus.privacyVerdict(deathRecorded: false, birthYear: nil, now: now, calendar: utc) == .living)
        #expect(LifeStatus.privacyVerdict(deathRecorded: true, birthYear: 1990, now: now, calendar: utc) == .deceased)
    }
}
