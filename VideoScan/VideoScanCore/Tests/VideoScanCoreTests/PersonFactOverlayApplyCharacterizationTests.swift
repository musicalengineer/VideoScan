import Testing
import Foundation
@testable import VideoScanCore

// Characterization of GedcomFamilyGraph.applyingFactOverlay (2026-11-07),
// written against the CCN 33 version BEFORE it was decomposed, so the
// decomposition is held to the same answers. PersonFactOverlayApplyTests
// (PersonFactRefreshTests.swift) covers the headline behaviours; this suite
// pins the per-field edges: what a nil / empty / identical value does for
// each field, which fields drop the index and which patch it, the report's
// counts and order, and every way a marriage date is refused.
// Synthetic people only (2026-08-03 privacy policy).

enum OverlayCharacterizationFixtures {
    /// Walter (WWWW-111) has two marriages: Mae (MMMM-222, dated 1950) and
    /// Vera (VVVV-777, undated). Solo (SOLO-888) is the only spouse in his
    /// family (no partner). Twin (TWIN-999) is recorded as both HUSB and
    /// WIFE of one family (a malformed file), married to nobody.
    static let tree = """
    0 HEAD
    0 @I1@ INDI
    1 NAME Walter /Dunn/
    1 SEX M
    1 BIRT
    2 DATE 1928
    2 PLAC Boston
    1 DEAT
    2 DATE 2008
    2 PLAC Pittsfield
    1 FAMS @F1@
    1 FAMS @F2@
    1 _FSFTID WWWW-111
    0 @I2@ INDI
    1 NAME Mae /Lamb/
    1 SEX F
    1 FAMS @F1@
    1 _FSFTID MMMM-222
    0 @I3@ INDI
    1 NAME Vera /Kent/
    1 SEX F
    1 FAMS @F2@
    1 _FSFTID VVVV-777
    0 @I4@ INDI
    1 NAME Solo /Lone/
    1 SEX M
    1 FAMS @F3@
    1 _FSFTID SOLO-888
    0 @I5@ INDI
    1 NAME Twin /Same/
    1 SEX M
    1 FAMS @F4@
    1 _FSFTID TWIN-999
    0 @F1@ FAM
    1 HUSB @I1@
    1 WIFE @I2@
    1 MARR
    2 DATE 1950
    0 @F2@ FAM
    1 HUSB @I1@
    1 WIFE @I3@
    0 @F3@ FAM
    1 HUSB @I4@
    1 MARR
    2 DATE 1940
    0 @F4@ FAM
    1 HUSB @I5@
    1 WIFE @I5@
    1 MARR
    2 DATE 1930
    0 TRLR
    """

    static var graph: GedcomFamilyGraph { GedcomFamilyGraph(gedcomText: tree) }

    static func overlay(_ people: [String: [String: String?]]) -> PersonFactOverlay {
        var o = PersonFactOverlay()
        for (fsid, facts) in people {
            o.entries[fsid] = .init(familySearchID: fsid, displayName: fsid, appliedAt: Date(timeIntervalSince1970: 0),
                                    facts: facts.mapValues { .init(value: $0, before: nil) })
        }
        return o
    }
}

private typealias C = OverlayCharacterizationFixtures

struct PersonFactOverlayApplyCharacterizationTests {

    private func walter(_ g: GedcomFamilyGraph) -> GedcomFamilyGraph.Person { g.person(familySearchID: "WWWW-111")! }

    @Test func anEmptyOverlayIsTheSameGraphAndAnEmptyReport() {
        let base = C.graph
        _ = base.index
        let (graph, report) = base.applyingFactOverlay(PersonFactOverlay())
        #expect(report == PersonFactOverlayReport())
        #expect(graph.indexBox === base.indexBox)
    }

    @Test func aNameIsNeverErasedNorRewrittenToItself() {
        for value in [nil, "", "Walter Dunn"] as [String?] {
            let base = C.graph
            _ = base.index
            let (graph, report) = base.applyingFactOverlay(C.overlay(["WWWW-111": ["name": value]]))
            #expect(report.fieldsChanged == 0, "name \(String(describing: value))")
            #expect(report.peopleChanged == 0)
            #expect(walter(graph).name == "Walter Dunn")
            #expect(graph.indexBox === base.indexBox)
        }
    }

    @Test func aNilSurnameClearsItAndDropsTheIndex() {
        let base = C.graph
        _ = base.index
        #expect(walter(base).surname == "Dunn")
        let (graph, report) = base.applyingFactOverlay(C.overlay(["WWWW-111": ["surname": nil]]))
        #expect(report.fieldsChanged == 1)
        #expect(report.indexDropped)
        #expect(!graph.hasBuiltIndex)
        #expect(walter(graph).surname == nil)
    }

    @Test func aNilSexBecomesEmptyAndTheSameSexIsNoChange() {
        let base = C.graph
        _ = base.index
        let (cleared, r1) = base.applyingFactOverlay(C.overlay(["WWWW-111": ["sex": nil]]))
        #expect(r1.fieldsChanged == 1)
        #expect(r1.indexDropped)
        #expect(walter(cleared).sex == "")
        let (same, r2) = base.applyingFactOverlay(C.overlay(["WWWW-111": ["sex": "M"]]))
        #expect(r2.fieldsChanged == 0)
        #expect(walter(same).sex == "M")
    }

    @Test func anIdentityChangeOnAnUnindexedTreeReportsNoDroppedIndex() {
        let base = C.graph
        #expect(!base.hasBuiltIndex)
        let (graph, report) = base.applyingFactOverlay(C.overlay(["WWWW-111": ["name": "Walt Dunn"]]))
        #expect(report.fieldsChanged == 1)
        #expect(!report.indexDropped)
        #expect(!graph.hasBuiltIndex)
        #expect(graph.people(matching: "Walt").map(\.id) == ["@I1@"])
    }

    @Test func placesKeepTheIndexUnpatchedAndEqualToAFreshBuild() {
        let base = C.graph
        let index = base.index
        let (graph, report) = base.applyingFactOverlay(C.overlay(["WWWW-111": ["birthPlace": "Cork", "deathPlace": nil]]))
        #expect(report.fieldsChanged == 2)
        #expect(!report.indexDropped)
        #expect(graph.hasBuiltIndex)
        #expect(graph.indexBox !== base.indexBox)
        #expect(graph.index == index)
        #expect(graph.index == GedcomFamilyGraph.TreeIndex(graph: graph))
        #expect(walter(graph).birthPlace == "Cork")
        #expect(walter(graph).deathPlace == nil)
    }

    @Test func aClearedDeathDatePatchesTheLifeYearsLabel() {
        let base = C.graph
        _ = base.index
        let (graph, report) = base.applyingFactOverlay(C.overlay(["WWWW-111": ["deathDate": nil, "birthDate": "1929"]]))
        #expect(report.fieldsChanged == 2)
        #expect(!report.indexDropped)
        #expect(graph.hasBuiltIndex)
        #expect(walter(graph).deathDate == nil)
        let ordinal = Int(graph.index.ordinal(of: "@I1@")!)
        #expect(graph.index.lifeYears[ordinal] == GedcomFamilyGraph.lifeYearsLabel(birth: "1929", death: nil) ?? "")
        #expect(graph.index == GedcomFamilyGraph.TreeIndex(graph: graph))
    }

    @Test func nameAndDatesTogetherDropTheIndexAndTheRebuildIsCurrent() {
        let base = C.graph
        _ = base.index
        let (graph, report) = base.applyingFactOverlay(C.overlay(["WWWW-111": ["name": "Walt Dunn", "birthDate": "1927"]]))
        #expect(report.fieldsChanged == 2)
        #expect(report.indexDropped)
        #expect(!graph.hasBuiltIndex)
        #expect(graph.index == GedcomFamilyGraph.TreeIndex(graph: graph))
    }

    @Test func theReportCountsPeopleAndFieldsAndListsMissingIDsSorted() {
        let (graph, report) = C.graph.applyingFactOverlay(C.overlay([
            "ZZZZ-000": ["birthDate": "1900"],
            "WWWW-111": ["birthPlace": "Cork", "deathPlace": "Lee", "parents": "@I9@"],
            "MMMM-222": ["birthDate": "1931"],
            "AAAA-000": ["name": "Nobody"],
            "VVVV-777": ["sex": "F"],                     // already F: no change
        ]))
        #expect(report.missingFamilySearchIDs == ["AAAA-000", "ZZZZ-000"])
        #expect(report.peopleChanged == 2)
        #expect(report.fieldsChanged == 3)
        #expect(graph.people.count == 5)
    }

    @Test func aMarriageDateChangesOnlyTheFamilyWithThatSpouse() {
        let base = C.graph
        _ = base.index
        let (graph, report) = base.applyingFactOverlay(C.overlay(["WWWW-111": [
            "marriageDate:VVVV-777": "1960", "marriageDate:MMMM-222": nil]]))
        #expect(report.fieldsChanged == 2)
        #expect(report.peopleChanged == 1)
        #expect(!report.indexDropped)
        #expect(graph.familyTable["@F1@"]!.marriageDate == nil)
        #expect(graph.familyTable["@F2@"]!.marriageDate == "1960")
        #expect(graph.index == GedcomFamilyGraph.TreeIndex(graph: graph))
    }

    @Test func aMarriageDateFromTheWifeSideFindsTheSameFamily() {
        let (graph, report) = C.graph.applyingFactOverlay(C.overlay(["MMMM-222": ["marriageDate:WWWW-111": "1951"]]))
        #expect(report.fieldsChanged == 1)
        #expect(graph.familyTable["@F1@"]!.marriageDate == "1951")
    }

    @Test func refusedMarriageDatesChangeNothing() {
        let (graph, report) = C.graph.applyingFactOverlay(C.overlay([
            "WWWW-111": ["marriageDate:MMMM-222": "1950",      // identical
                         "marriageDate:SOLO-888": "1970"],     // not his spouse
            "SOLO-888": ["marriageDate:WWWW-111": "1941"],     // his family has no partner
            "TWIN-999": ["marriageDate:TWIN-999": "1931"],     // both HUSB and WIFE
        ]))
        #expect(report.fieldsChanged == 0)
        #expect(report.peopleChanged == 0)
        #expect(graph.familyTable["@F1@"]!.marriageDate == "1950")
        #expect(graph.familyTable["@F3@"]!.marriageDate == "1940")
        #expect(graph.familyTable["@F4@"]!.marriageDate == "1930")
    }

    @Test func eachEntrySeesTheFamiliesEarlierEntriesChanged() {
        // Entries apply in FamilySearch ID order (MMMM before WWWW): Mae's
        // entry sets 1951, so Walter's identical 1951 is no second change.
        let (graph, report) = C.graph.applyingFactOverlay(C.overlay([
            "MMMM-222": ["marriageDate:WWWW-111": "1951"],
            "WWWW-111": ["marriageDate:MMMM-222": "1951"],
        ]))
        #expect(report.fieldsChanged == 1)
        #expect(report.peopleChanged == 1)
        #expect(graph.familyTable["@F1@"]!.marriageDate == "1951")
    }
}

/// The named steps applyingFactOverlay is built from, one at a time.
struct PersonFactOverlayApplyStepTests {

    @Test func eachFieldNamesItsIndexEffect() {
        let table: [(PersonRefreshField, OverlayIndexEffect)] = [
            (.name, .rebuild), (.surname, .rebuild), (.sex, .rebuild),
            (.birthDate, .patchLifeYears), (.deathDate, .patchLifeYears),
            (.birthPlace, .unindexed), (.deathPlace, .unindexed),
            (.marriageDate(spouseFamilySearchID: "MMMM-222"), .unindexed),
        ]
        for (field, effect) in table { #expect(field.overlayIndexEffect == effect, "\(field.key)") }
    }

    @Test func assignOverlayFactSetsOnlyWhatDiffers() {
        var person = C.graph.person(familySearchID: "WWWW-111")!
        // (field, value, changed?) applied in order to the same person.
        let steps: [(PersonRefreshField, String?, Bool)] = [
            (.name, nil, false), (.name, "", false), (.name, "Walter Dunn", false), (.name, "Walt Dunn", true),
            (.sex, nil, true), (.sex, "", false),
            (.birthPlace, nil, true), (.birthPlace, nil, false),
            (.deathDate, "2009", true),
            (.marriageDate(spouseFamilySearchID: "MMMM-222"), "1999", false),
        ]
        for (n, (field, value, expected)) in steps.enumerated() {
            let changed = person.assignOverlayFact(field, value)
            #expect(changed == expected, "step \(n): \(field.key)")
        }
        #expect(person.name == "Walt Dunn")
        #expect(person.sex == "")
        #expect(person.birthPlace == nil)
        #expect(person.deathDate == "2009")
    }

    @Test func partnerLookupRefusesBothNeitherAndMissing() {
        let g = C.graph
        let edit = GedcomFamilyGraph.FactOverlayEdit(people: g.people, families: g.familyTable)
        #expect(edit.partnerFamilySearchID(inFamily: "@F1@", of: "@I1@") == "MMMM-222")
        #expect(edit.partnerFamilySearchID(inFamily: "@F1@", of: "@I2@") == "WWWW-111")
        #expect(edit.partnerFamilySearchID(inFamily: "@F1@", of: "@I3@") == nil)   // neither
        #expect(edit.partnerFamilySearchID(inFamily: "@F3@", of: "@I4@") == nil)   // no partner
        #expect(edit.partnerFamilySearchID(inFamily: "@F4@", of: "@I5@") == nil)   // both
        #expect(edit.partnerFamilySearchID(inFamily: "@F9@", of: "@I1@") == nil)   // unknown family
    }

    @Test func applyRecordsTheIndexEffectOfWhatChanged() {
        let g = C.graph
        var edit = GedcomFamilyGraph.FactOverlayEdit(people: g.people, families: g.familyTable)
        let changed = edit.apply(["birthDate": .init(value: "1927", before: nil),
                                  "deathPlace": .init(value: "Lee", before: nil),
                                  "FAMC": .init(value: "@F9@", before: nil)], toPersonID: "@I1@")
        #expect(changed == 2)
        #expect(edit.lifeYearsChanged == ["@I1@"])
        #expect(!edit.indexStale)
        #expect(edit.people["@I1@"]!.birthDate == "1927")
        let sameSex = edit.apply(["sex": .init(value: "F", before: nil)], toPersonID: "@I2@")
        #expect(sameSex == 0)
        let newSurname = edit.apply(["surname": .init(value: "Lambe", before: nil)], toPersonID: "@I2@")
        #expect(newSurname == 1)
        #expect(edit.indexStale)
        #expect(edit.lifeYearsChanged == ["@I1@"])
    }

    @Test func indexPatchingLifeYearsIsNilUnbuiltSameWhenNothingMovedAndPatchedOtherwise() {
        let unbuilt = C.graph
        #expect(unbuilt.indexPatchingLifeYears(of: ["@I1@"], in: unbuilt.people) == nil)
        let base = C.graph
        let index = base.index
        #expect(base.indexPatchingLifeYears(of: [], in: base.people) == index)
        #expect(base.indexPatchingLifeYears(of: ["@NOBODY@"], in: base.people) == index)
        var people = base.people
        people["@I1@"]!.deathDate = nil
        let patched = base.indexPatchingLifeYears(of: ["@I1@"], in: people)!
        let ordinal = Int(index.ordinal(of: "@I1@")!)
        #expect(patched.lifeYears[ordinal] == GedcomFamilyGraph.lifeYearsLabel(birth: "1928", death: nil) ?? "")
        #expect(patched.ids == index.ids)
    }
}
