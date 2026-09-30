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

    /// The fix for the rows above, pinned sentence by sentence (Claude,
    /// closing codex P2). The positive rows are the shapes the archive
    /// actually holds — the 2026-09-29 certificate event for Mary, the
    /// older "Born …" form, a pronoun opening; the negative rows are other
    /// people's births mentioned in an event about her (a daughter, twins,
    /// her father Daniel who shares her surname) and a death event that
    /// mentions her birth in passing. Ambiguous forms ("Grandma was born",
    /// an unlisted nickname) are documented false negatives, pinned so a
    /// change is deliberate.
    @Test(arguments: [
        ("Mary Christina O'Connor was born on 23 December 1904 at 34 Fullers Lane, Cork, County Cork, Ireland — recorded in the civil birth register (Cork, District No. 6, entry 11, registered January 1905).", true),
        ("Mary was born in Cork.", true),
        ("Mamie O'Connor, born 1904, Cork.", true),                     // alias, comma form
        ("Born 23 December 1904 at 34 Fullers Lane, Cork; birth certificate in the archive.", true),
        ("BIRTH registered late.", true),
        ("Her birth was registered in Yorkshire.", true),
        ("Daughter of Daniel and Ellen, she was born in Cork.", true),
        ("Ellen Ronan was born in 1882, confirmed by her birth certificate, which the family holds.", false),   // Ellen is not Mary
        ("Moved to Boston after the birth of her daughter.", false),
        ("Married in Boston after her daughter was born.", false),
        ("Her daughter Ann was born in Boston.", false),
        ("Her son John Patrick O'Connor was born at home.", false),
        ("Gave birth to twins in Boston.", false),
        ("The twins were born in Boston.", false),
        ("Daniel O'Connor was born in Cork.", false),                  // her father: same surname, not her
        ("Mary moved to Boston, where Ann was born.", false),
        ("Mary Christina O'Connor died in 1977. (The tree gives her birth as August 1903.)", false),
        ("Married Jane Osborne at Birthdale.", false),
        ("Grandma was born in Cork.", false),                          // unlisted nickname: ambiguous, unplaced
    ])
    func onlyTheSubjectsOwnBirthIsABirthEvent(_ text: String, expected: Bool) {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let mary = CyberBrainPerson(id: "person.mary", gedcomPersonID: "@I7@", canonicalName: "Mary Christina O'Connor",
                                    aliases: ["Mamie", "Mary C. O'Connor"])
        let item = CyberBrainItem(id: "event.x", kind: .event, text: text, subjectPersonIDs: [mary.id],
                                  place: "Cork, Ireland", sourceIDs: ["source.bc"], confidence: .confirmed,
                                  privacy: .family, status: .active, createdAt: now, updatedAt: now)
        #expect(FamilyMapModel.isOwnBirthEvent(item, of: mary) == expected,
                "only the subject's own birth is a birth event (the row's text is in the arguments)")
    }
}
