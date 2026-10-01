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
        NoteCase(text: "Mary Christina O'Connor was born in Cork.",
                 place: "Cork, Ireland", privacy: .private, expectedBirthplace: nil),
        NoteCase(text: "Mary Christina O'Connor was born in Cork.",
                 place: "Cork, Ireland", privacy: .family, expectedBirthplace: "Cork, Ireland"),
        // #235: an opener that does not name her places nobody, even when visible.
        NoteCase(text: "Born in Cork.",
                 place: "Cork, Ireland", privacy: .family, expectedBirthplace: nil),
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

    /// One sentence of the own-birth table. A struct (not a tuple literal)
    /// so the long argument list type-checks quickly on CI's Xcode 26.3.
    struct SentenceCase: Sendable, CustomTestStringConvertible {
        let text: String
        let isOwnBirth: Bool
        var testDescription: String { (isOwnBirth ? "OWN: " : "NOT: ") + text }
    }

    /// The fix for codex's P2 rows, pinned sentence by sentence (Claude,
    /// closing codex P2 in r3, its re-check F1/F2 in r4, and F1 for good in
    /// #235). Only ONE shape is a birth now: the note opens with names that
    /// are all hers (canonical or a listed alias, at least one a given
    /// name), then "was born" / ", born" — the 2026-09-29 certificate event
    /// has that shape. The negative rows are other people's births
    /// mentioned in an event about her (a daughter, twins, her father
    /// Daniel who shares her surname, a woman who shares only her first
    /// name), a death event that mentions her birth in passing, and — since
    /// #235 — every "Born …" / "Birth …" / "She was born …" opener, which
    /// no longer says WHOSE birth it is. Those are documented false
    /// negatives, pinned so a change is deliberate.
    static let ownBirthSentences: [SentenceCase] = [
        // Positives kept from r3.
        SentenceCase(text: "Mary Christina O'Connor was born on 1 January 1900 at 1 Example Lane, Cork, County Cork, Ireland — recorded in the civil birth register (district and entry on the certificate).", isOwnBirth: true),
        SentenceCase(text: "Mary was born in Cork.", isOwnBirth: true),
        SentenceCase(text: "Mamie O'Connor, born 1904, Cork.", isOwnBirth: true),        // listed alias + surname, comma form
        SentenceCase(text: "Mary Christina O'Connor was born 1 January 1900 at 1 Example Lane, Cork; birth certificate in the archive.", isOwnBirth: true),
        // Positives added in r4 (codex re-check: canonical and listed-alias controls).
        SentenceCase(text: "Mary Christina O'Connor was born in Boston.", isOwnBirth: true),
        SentenceCase(text: "Mary C. O'Connor was born in Cork.", isOwnBirth: true),      // listed alias, with its initial
        SentenceCase(text: "Mary O'Connor was born in Cork.", isOwnBirth: true),         // every token is hers
        SentenceCase(text: "Mamie was born in Cork.", isOwnBirth: true),                 // one-word listed alias
        // Negatives kept from r3.
        SentenceCase(text: "Ellen Ronan was born in 1882, confirmed by her birth certificate, which the family holds.", isOwnBirth: false),
        SentenceCase(text: "Moved to Boston after the birth of her daughter.", isOwnBirth: false),
        SentenceCase(text: "Married in Boston after her daughter was born.", isOwnBirth: false),
        SentenceCase(text: "Her daughter Ann was born in Boston.", isOwnBirth: false),
        SentenceCase(text: "Her son John Patrick O'Connor was born at home.", isOwnBirth: false),
        SentenceCase(text: "Gave birth to twins in Boston.", isOwnBirth: false),
        SentenceCase(text: "The twins were born in Boston.", isOwnBirth: false),
        SentenceCase(text: "Daniel O'Connor was born in Cork.", isOwnBirth: false),       // her father: same surname, not her
        SentenceCase(text: "Mary moved to Boston, where Ann was born.", isOwnBirth: false),
        SentenceCase(text: "Mary Christina O'Connor died in 1977. (The tree gives her birth as August 1903.)", isOwnBirth: false),
        SentenceCase(text: "Married Jane Osborne at Birthdale.", isOwnBirth: false),
        SentenceCase(text: "Grandma was born in Cork.", isOwnBirth: false),               // unlisted nickname: ambiguous, unplaced
        // Negatives added in r4 — codex re-check F1 (opening "Birth", pronoun).
        SentenceCase(text: "Birth certificate for her daughter records Boston.", isOwnBirth: false),
        SentenceCase(text: "Ellen O'Connor moved to Boston, where she was born.", isOwnBirth: false),
        SentenceCase(text: "Birth record for Ann, filed in Boston.", isOwnBirth: false),
        SentenceCase(text: "Birth certificate of her son John, Boston.", isOwnBirth: false),
        SentenceCase(text: "Born the same year as her brother, in Boston.", isOwnBirth: false),  // ambiguous: unplaced
        SentenceCase(text: "Mary moved to Cork, where she was born.", isOwnBirth: false),        // documented FN: pronoun after a clause
        // Negatives added in r4 — codex re-check F2 (conflicting explicit identity).
        SentenceCase(text: "Mary Ellen Ronan was born in Boston.", isOwnBirth: false),    // codex: conflicting middle + surname
        SentenceCase(text: "Mary Ellen O'Connor was born in Boston.", isOwnBirth: false), // conflicting middle name only
        SentenceCase(text: "Mary Christina Ronan was born in Boston.", isOwnBirth: false), // conflicting surname only
        SentenceCase(text: "Mary E. O'Connor was born in Boston.", isOwnBirth: false),    // conflicting initial
        SentenceCase(text: "Mrs Mary O'Connor was born in Cork.", isOwnBirth: false),     // documented FN: honorific not in her names
        // #235: the openers were OWN in r3/r4; they no longer say whose birth it is.
        SentenceCase(text: "Born 1 January 1900 at 1 Example Lane, Cork; birth certificate in the archive.", isOwnBirth: false),
        SentenceCase(text: "Born in Cork.", isOwnBirth: false),
        SentenceCase(text: "BIRTH registered late.", isOwnBirth: false),
        SentenceCase(text: "Her birth was registered in Yorkshire.", isOwnBirth: false),
        SentenceCase(text: "Daughter of Daniel and Ellen, she was born in Cork.", isOwnBirth: false),
        SentenceCase(text: "She was born in Cork.", isOwnBirth: false),
        SentenceCase(text: "Birth: Cork.", isOwnBirth: false),
        SentenceCase(text: "Birth registered in Cork.", isOwnBirth: false),
        // #235: codex r4 F1 residuals (each slipped past an opener rule).
        SentenceCase(text: "Birth certificate located; for her daughter Ann, Boston.", isOwnBirth: false),
        SentenceCase(text: "Born the same year as her younger brother, in Boston.", isOwnBirth: false),
        SentenceCase(text: "Born the same year as her aunt, in Boston.", isOwnBirth: false),
        SentenceCase(text: "Born the same year as her uncle, in Boston.", isOwnBirth: false),
    ]

    @Test(arguments: FamilyMapNotesAdversarialTests.ownBirthSentences)
    func onlyTheSubjectsOwnBirthIsABirthEvent(_ row: SentenceCase) {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let mary = CyberBrainPerson(id: "person.mary", gedcomPersonID: "@I7@", canonicalName: "Mary Christina O'Connor",
                                    aliases: ["Mamie", "Mary C. O'Connor"])
        let item = CyberBrainItem(id: "event.x", kind: .event, text: row.text, subjectPersonIDs: [mary.id],
                                  place: "Cork, Ireland", sourceIDs: ["source.bc"], confidence: .confirmed,
                                  privacy: .family, status: .active, createdAt: now, updatedAt: now)
        let got = FamilyMapModel.isOwnBirthEvent(item, of: mary)
        #expect(got == row.isOwnBirth,
                "only the subject's own birth is a birth event (the row's text is in the arguments)")
    }

    /// One row of codex's r4 lookup pins: the event text and the birthplace
    /// the ACTUAL `familyBirthPlace` lookup must return for Mary.
    struct LookupCase: Sendable, CustomTestStringConvertible {
        let text: String
        let expectedBirthplace: String?
        var testDescription: String { text }
    }

    static let recheckLookupCases: [LookupCase] = [
        LookupCase(text: "Birth certificate for her daughter records Boston.", expectedBirthplace: nil),
        LookupCase(text: "Ellen O'Connor moved to Boston, where she was born.", expectedBirthplace: nil),
        LookupCase(text: "Mary Ellen Ronan was born in Boston.", expectedBirthplace: nil),
        LookupCase(text: "Mary Christina O'Connor was born in Boston.", expectedBirthplace: "Boston, Massachusetts"),
        LookupCase(text: "Mamie O'Connor, born 1904 in Boston.", expectedBirthplace: "Boston, Massachusetts"),
        // #235: codex r4 F1 residuals — each slipped past a deleted opener rule.
        LookupCase(text: "Birth certificate located; for her daughter Ann, Boston.", expectedBirthplace: nil),
        LookupCase(text: "Born the same year as her younger brother, in Boston.", expectedBirthplace: nil),
        LookupCase(text: "Born the same year as her aunt, in Boston.", expectedBirthplace: nil),
        LookupCase(text: "Born the same year as her uncle, in Boston.", expectedBirthplace: nil),
        // #235: the openers place nobody now.
        LookupCase(text: "Born in Boston.", expectedBirthplace: nil),
        LookupCase(text: "She was born in Boston.", expectedBirthplace: nil),
        LookupCase(text: "Birth certificate for Ann, Boston.", expectedBirthplace: nil),
    ]

    /// codex re-check F1/F2 through the real lookup, under both link forms:
    /// an active, confirmed, family-visible event with a Boston place must
    /// leave Mary unplaced unless it asserts HER birth; the archive is left
    /// unchanged either way.
    @Test(arguments: FamilyMapNotesAdversarialTests.recheckLookupCases, [true, false])
    func recheckSentencesThroughTheActualLookup(_ row: LookupCase, linkedByGEDCOM: Bool) throws {
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
            id: "event.mary.recheck", kind: .event, text: row.text,
            subjectPersonIDs: ["person.mary"], place: "Boston, Massachusetts",
            sourceIDs: ["source.synthetic"], confidence: .confirmed,
            privacy: .family, status: .active,
            createdAt: now, updatedAt: now)
        let gedcomLink: String? = linkedByGEDCOM ? "@I7@" : nil
        let mary = CyberBrainPerson(
            id: "person.mary", gedcomPersonID: gedcomLink,
            canonicalName: "Mary Christina O'Connor", aliases: ["Mamie"], lifeEvents: [item])
        let source = CyberBrainSource(id: "source.synthetic", type: .officialRecord, title: "Synthetic event record")
        let archive = CyberBrainArchive(
            archiveID: "test.map.adversarial.recheck", displayName: "Synthetic Family Notes",
            people: [mary], sources: [source])
        let knowledge = FamilyTreeNotesResolver(index: try CyberBrainIndex(archive: archive), graph: graph)
        let attached = try #require(knowledge.cyberBrainPeople(forGedcomID: "@I7@").first,
                                   "the fixture must attach by the requested link form")
        #expect(attached.id == "person.mary")
        #expect(knowledge.cyberBrainPeople(forGedcomID: "@I7@").count == 1)

        let birthplace = FamilyMapModel.familyBirthPlace(gedcomID: "@I7@", in: knowledge)
        #expect(birthplace == row.expectedBirthplace,
                "only an event asserting Mary's own birth may place her")
        #expect(knowledge.index.archive == archive, "birthplace lookup must leave family notes unchanged")
    }
}
