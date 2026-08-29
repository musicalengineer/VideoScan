import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

// Family Tree inspector genealogy block (feature/family-tree-info-pane,
// 2026-08-28). Dimensions per the feature-test checklist:
//   Logic — the Born/Died formatting matrix below
//   Model — selecting a person exposes the lines + marriages + FS ID
// No records iteration, no media, no global state.

@Suite("Family tree life summary — formatting matrix")
struct FamilyTreeLifeSummaryTests {

    @Test func plainYearsWithPlacesAndAge() {
        let life = FamilyTreeLifeSummary(
            birthDate: "1615", deathDate: "1690",
            birthPlace: "Plymouth, Massachusetts",
            deathPlace: "Sudbury, Massachusetts Bay Colony")
        #expect(life.lines == [
            "Born 1615 (Plymouth, Massachusetts)",
            "Died 1690, age 75 (Sudbury, Massachusetts Bay Colony)"
        ])
    }

    @Test func fullDatesReduceToYears() {
        let life = FamilyTreeLifeSummary(birthDate: "4 March 1959", deathDate: "12 DEC 2008")
        #expect(life.lines == ["Born 1959", "Died 2008, age 49"])
    }

    @Test func qualifiersAreKeptAndMakeTheAgeApproximate() {
        #expect(FamilyTreeLifeSummary(birthDate: "ABT 1520", deathDate: "1590").lines
                == ["Born about 1520", "Died 1590, age ~70"])
        #expect(FamilyTreeLifeSummary(birthDate: "before 13 January 1633", deathDate: nil).lines
                == ["Born before 1633"])
        #expect(FamilyTreeLifeSummary(birthDate: "1650", deathDate: "after 1717").lines
                == ["Born 1650", "Died after 1717, age ~67"])
        #expect(FamilyTreeLifeSummary(birthDate: "BET 1700 AND 1710", deathDate: "1780").lines
                == ["Born between 1700 and 1710", "Died 1780, age ~80"])
    }

    @Test func missingDeathShowsOnlyBornAndNeverLiving() {
        let life = FamilyTreeLifeSummary(birthDate: "1 JAN 1900", deathDate: nil,
                                         birthPlace: "Cork, Ireland")
        #expect(life.lines == ["Born 1900 (Cork, Ireland)"])
        #expect(!life.lines.joined().localizedCaseInsensitiveContains("living"))
    }

    @Test func missingBirthShowsOnlyDiedWithoutAge() {
        #expect(FamilyTreeLifeSummary(birthDate: nil, deathDate: "1970").lines == ["Died 1970"])
    }

    @Test func ageOmittedWhenOutOfRange() {
        // Death before birth — a data error; say the years, not "age -5".
        #expect(FamilyTreeLifeSummary(birthDate: "1700", deathDate: "1695").lines
                == ["Born 1700", "Died 1695"])
        // 120 — beyond the plausible ceiling.
        #expect(FamilyTreeLifeSummary(birthDate: "1600", deathDate: "1720").lines
                == ["Born 1600", "Died 1720"])
        // 115 is the inclusive ceiling.
        #expect(FamilyTreeLifeSummary(birthDate: "1600", deathDate: "1715").lines
                == ["Born 1600", "Died 1715, age 115"])
        // 0 is fine (infant).
        #expect(FamilyTreeLifeSummary(birthDate: "1800", deathDate: "1800").lines
                == ["Born 1800", "Died 1800, age 0"])
    }

    @Test func placeAbsentAndPlaceOnly() {
        #expect(FamilyTreeLifeSummary(birthDate: "1929", deathDate: "2008",
                                      birthPlace: "", deathPlace: "   ").lines
                == ["Born 1929", "Died 2008, age 79"])
        #expect(FamilyTreeLifeSummary(birthDate: nil, deathDate: nil,
                                      birthPlace: "Boston, Suffolk, Massachusetts, United States").lines
                == ["Born in Boston, Suffolk, Massachusetts, United States"])
    }

    @Test func nothingRecordedIsEmpty() {
        #expect(FamilyTreeLifeSummary(birthDate: nil, deathDate: nil).lines.isEmpty)
    }

    @Test func dateWithoutAYearIsShownAsRecorded() {
        #expect(FamilyTreeLifeSummary(birthDate: "BEF 1 MAY", deathDate: nil).lines
                == ["Born bef 1 may"])
    }

    @Test func marriageYearKeepsQualifier() {
        #expect(FamilyTreeMarriage(id: "x", spouse: nil, marriageDate: "ABT 1890").marriedYear == "about 1890")
        #expect(FamilyTreeMarriage(id: "x", spouse: nil, marriageDate: "14 JUN 1952").marriedYear == "1952")
        #expect(FamilyTreeMarriage(id: "x", spouse: nil, marriageDate: nil).marriedYear == nil)
    }
}

// MARK: - Model

@Suite("Family tree model — genealogy block")
@MainActor
struct FamilyTreeLifeSummaryModelTests {

    private static let gedcom = """
    0 HEAD
    0 @I1@ INDI
    1 NAME John /Breen/
    1 SEX M
    1 BIRT
    2 DATE 1 JAN 1900
    2 PLAC Cork, Ireland
    1 DEAT
    2 DATE 1970
    2 PLAC Boston, Suffolk, Massachusetts, United States
    1 FAMS @F1@
    1 _FSFTID KWC1-ABC
    0 @I2@ INDI
    1 NAME Mary /Lamb/
    1 SEX F
    1 BIRT
    2 DATE ABT 1902
    1 FAMS @F1@
    0 @I3@ INDI
    1 NAME Kate /Breen/
    1 SEX F
    1 FAMC @F1@
    0 @F1@ FAM
    1 HUSB @I1@
    1 WIFE @I2@
    1 CHIL @I3@
    1 MARR
    2 DATE 14 JUN 1925
    """

    private func liveModel() -> FamilyTreeLiveModel {
        let model = FamilyTreeLiveModel(
            originalsDirectory: URL(fileURLWithPath: "/nonexistent/never-read"))
        model.install(graph: GedcomFamilyGraph(gedcomText: Self.gedcom))
        return model
    }

    @Test func selectingAPersonExposesTheSummaryLines() {
        let model = liveModel()
        model.select("@I1@")
        #expect(model.selectedLife?.lines == [
            "Born 1900 (Cork, Ireland)",
            "Died 1970, age 70 (Boston, Suffolk, Massachusetts, United States)"
        ])
        #expect(model.selectedMarriages.map { $0.spouse?.name } == ["Mary Lamb"])
        #expect(model.selectedMarriages.map(\.marriedYear) == ["1925"])
        #expect(model.selectedRelatives.children.map(\.name) == ["Kate Breen"])
    }

    @Test func familySearchIDFollowsTheSelection() {
        let model = liveModel()
        model.select("@I1@")
        let idForJohn = model.selectedFamilySearchID
        model.select("@I2@")
        #expect(model.selectedFamilySearchID == nil)
        #expect(model.selectedLife?.lines == ["Born about 1902"])
        // Whatever tag the parser honours for the FS ID, John's must not
        // leak onto Mary — and if the parser does read _FSFTID, it's his.
        #expect(idForJohn == "KWC1-ABC")
    }

    @Test func deselectingClearsTheBlock() {
        let model = liveModel()
        model.select("@I1@")
        model.select("@ZZZ@")   // ignored: still John
        #expect(model.selectedLife != nil)
    }
}
