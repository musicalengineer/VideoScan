// GH #227: references to another person's birth are not the subject's
// birthplace. Exercise the real family-note lookup with synthetic archives,
// both explicit GEDCOM links and name matching; no files or global stores.

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@Suite("FamilyMap note birthplace adversarial regressions")
struct FamilyMapNotesAdversarialTests {
    struct NoteCase: Sendable {
        let text: String
        let place: String
        let privacy: CyberBrainItem.Privacy
        let expectedBirthplace: String?
    }

    // Like parameterized C++ tests: each note row runs with each link form.
    // #expect records the mismatch while #require enforces fixture linkage.
    @Test(arguments: [
        NoteCase(text: "Moved to Boston after the birth of her daughter.",
                 place: "Boston, Massachusetts", privacy: .family, expectedBirthplace: nil),
        NoteCase(text: "Married in Boston after her daughter was born.",
                 place: "Boston, Massachusetts", privacy: .family, expectedBirthplace: nil),
        NoteCase(text: "Born in Cork.",
                 place: "Cork, Ireland", privacy: .private, expectedBirthplace: nil),
        NoteCase(text: "Born in Cork.",
                 place: "Cork, Ireland", privacy: .family, expectedBirthplace: "Cork, Ireland"),
    ], [true, false])
    func onlyThePersonsOwnVisibleBirthPlacesThem(_ row: NoteCase, linkedByGEDCOM: Bool) throws {
        let graph = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        1 _VS_MERGED Y
        1 _VS_ROOT @I7@
        0 @I7@ INDI
        1 NAME Mary Christina /O'Connor/
        1 SEX F
        0 TRLR
        """)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let item = CyberBrainItem(
            id: "event.mary.synthetic", kind: .event, text: row.text,
            subjectPersonIDs: ["person.mary"], place: row.place,
            sourceIDs: ["source.synthetic"], confidence: .confirmed,
            privacy: row.privacy, status: .active,
            createdAt: now, updatedAt: now)
        let archive = CyberBrainArchive(
            archiveID: "test.map.adversarial.notes", displayName: "Synthetic Family Notes",
            people: [CyberBrainPerson(
                id: "person.mary", gedcomPersonID: linkedByGEDCOM ? "@I7@" : nil,
                canonicalName: "Mary Christina O'Connor", lifeEvents: [item])],
            sources: [CyberBrainSource(
                id: "source.synthetic", type: .officialRecord, title: "Synthetic event record")])
        let knowledge = FamilyTreeNotesResolver(index: try CyberBrainIndex(archive: archive), graph: graph)
        let attached = try #require(knowledge.cyberBrainPeople(forGedcomID: "@I7@").first,
                                   "the fixture must attach by the requested link form")
        #expect(attached.id == "person.mary")
        #expect(knowledge.cyberBrainPeople(forGedcomID: "@I7@").count == 1)

        let birthplace = FamilyMapModel.familyBirthPlace(gedcomID: "@I7@", in: knowledge)
        #expect(birthplace == row.expectedBirthplace,
                "only the person's own visible birth should supply a birthplace")
        #expect(knowledge.index.archive == archive, "birthplace lookup must leave family notes unchanged")
    }
}
