// FamilyTreeIdentityRulingTests.swift
// The Family Tree honouring Rick's rulings about who is who (2026-09-17:
// "Mary Christina O'Connor was a hard won battle of investigation, she is my
// grandma, this is verified, the other Mary should be ignored by the app").
//
// The rulings live beside the GEDCOM as data. These cases pin the two things
// that must be true of them in the app: a record he called a duplicate is
// kept out of the way, and NOTHING ELSE is — least of all someone he simply
// has not identified yet.

import Testing
import Foundation
@testable import VideoScan
@testable import VideoScanCore

@Suite("Family tree identity rulings", .serialized)
struct FamilyTreeIdentityRulingTests {

    private func scratch() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rulings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Two Mary O'Connor records under one set of parents, exactly as the
    /// live tree has them, plus an unrelated person who must be unaffected.
    private func treeDirectory() throws -> URL {
        let dir = try scratch()
        let gedcom = """
        0 HEAD
        0 @F6@ FAM
        1 CHIL @I5@
        1 CHIL @I7@
        0 @I7@ INDI
        1 NAME Mary Christina /O'Connor/
        1 SEX F
        1 BIRT
        2 DATE 23 December 1904
        1 FAMC @F6@
        1 _FSFTID G89Q-34N
        0 @I5@ INDI
        1 NAME Mary /O'Connor/
        1 SEX F
        1 BIRT
        2 DATE 1905
        1 FAMC @F6@
        1 _FSFTID GNZ5-428
        0 @I9@ INDI
        1 NAME Peter /Ronan/
        1 SEX M
        1 _FSFTID PFWT-42W
        0 TRLR
        """
        try gedcom.write(to: dir.appendingPathComponent("tree.ged"),
                         atomically: true, encoding: .utf8)
        return dir
    }

    @MainActor
    private func model(_ dir: URL) -> FamilyTreeLiveModel {
        FamilyTreeLiveModel(originalsDirectory: dir, bookmarksDirectory: dir)
    }

    // MARK: The ruling is honoured

    @Test @MainActor func aRecordRuledADuplicateIsHiddenAndTheVerifiedOneIsNot() throws {
        let dir = try treeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        var rulings = FamilyIdentityDecisions()
        rulings.record(.init(key: .familySearch("G89Q-34N"), verified: true,
                             note: "Rick's grandmother; confirmed by her son."))
        rulings.record(.init(key: .familySearch("GNZ5-428"),
                             duplicateOf: .familySearch("G89Q-34N")))
        try rulings.save(to: dir)

        let m = model(dir)
        #expect(m.identityDecisions.count == 2, "the rulings beside the tree were not loaded")
        #expect(m.identityDecisions.isSuppressed(.familySearch("GNZ5-428")))
        #expect(!m.identityDecisions.isSuppressed(.familySearch("G89Q-34N")),
                "the verified record must never be suppressed")
        #expect(m.identityDecisions.preferred(.familySearch("GNZ5-428"))
                == .familySearch("G89Q-34N"))
    }

    // MARK: And nothing else is

    /// The dangerous direction. Somebody Rick has not identified — Elizabeth
    /// Brashear, in the bible records and nowhere in FamilySearch — must
    /// stay fully visible. Not knowing who someone is can never hide them.
    @Test @MainActor func anUnresolvedPersonIsNeverHidden() throws {
        let dir = try treeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        var rulings = FamilyIdentityDecisions()
        rulings.record(.init(key: .local("elizabeth-brashear"), verified: false,
                             note: "In the bible records. No FamilySearch record yet."))
        rulings.record(.init(key: .familySearch("PFWT-42W"), verified: true))
        try rulings.save(to: dir)

        let m = model(dir)
        #expect(!m.identityDecisions.isSuppressed(.local("elizabeth-brashear")))
        #expect(!m.identityDecisions.isSuppressed(.familySearch("PFWT-42W")),
                "a VERIFIED record must not be confused with a suppressed one")
    }

    /// With no rulings at all — every archive before today — nothing is
    /// hidden and the tree behaves exactly as it did.
    @Test @MainActor func noRulingsMeansNothingIsHidden() throws {
        let dir = try treeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = model(dir)
        #expect(m.identityDecisions.isEmpty)
        #expect(!m.isSuppressedRecord("@I5@"))
        #expect(!m.isSuppressedRecord("@I7@"))
    }

    /// A record with no FamilySearch id can never be suppressed, whatever
    /// the file says — the ruling is keyed on an id it does not have. That
    /// is the safe direction and it is deliberate.
    @Test @MainActor func aRecordWithoutAFamilySearchIDIsNeverSuppressed() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        0 HEAD
        0 @I1@ INDI
        1 NAME Someone /Unknown/
        0 TRLR
        """.write(to: dir.appendingPathComponent("tree.ged"), atomically: true, encoding: .utf8)

        var rulings = FamilyIdentityDecisions()
        rulings.record(.init(key: .familySearch("AAAA-111"),
                             duplicateOf: .familySearch("BBBB-222")))
        try rulings.save(to: dir)

        let m = model(dir)
        #expect(!m.isSuppressedRecord("@I1@"))
    }

    /// PROOF THE OTHERS ARE NOT VACUOUS. `isSuppressedRecord` needs a loaded
    /// graph to map a person to a FamilySearch id; with no graph it answers
    /// false for everyone, and "nothing is hidden" would pass while proving
    /// nothing. This asserts the POSITIVE case, so if the graph never loads
    /// in this harness the suite says so instead of going quietly green.
    @Test @MainActor func theDuplicateIsActuallySuppressedOnceTheTreeIsLoaded() async throws {
        let dir = try treeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var rulings = FamilyIdentityDecisions()
        rulings.record(.init(key: .familySearch("GNZ5-428"),
                             duplicateOf: .familySearch("G89Q-34N")))
        try rulings.save(to: dir)

        let m = model(dir)
        await m.prepareForAppearance(revision: "test-\(UUID().uuidString)")
        try #require(m.peopleCount > 0,
                     "the tree never loaded, so the other cases here prove nothing")
        #expect(m.isSuppressedRecord("@I5@"), "the duplicate Mary is still on show")
        #expect(!m.isSuppressedRecord("@I7@"), "the verified Mary was hidden")
        #expect(!m.isSuppressedRecord("@I9@"), "an unrelated person was hidden")
    }

    // MARK: The card's small print

    /// Rick: "where the last name is currently in the person in FT view such
    /// as 'Doherty' we should have FS ID since Doherty is already in view,
    /// why list it again in small print under, put FSID?"
    @Test func theSummaryCarriesTheFamilySearchIDForTheCardsSmallPrint() throws {
        let graph = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I1@ INDI
        1 NAME Mary Jane /Doherty/
        1 _FSFTID 218L-QKH
        0 @I2@ INDI
        1 NAME Someone /Unknown/
        0 TRLR
        """)
        let withID = try #require(graph.people["@I1@"]).self
        let without = try #require(graph.people["@I2@"]).self

        #expect(FamilyTreeLiveModel.summary(withID).familySearchID == "218L-QKH",
                "the card has no id to show in place of the surname")
        // A record with no id keeps the old behaviour rather than showing
        // an empty line.
        #expect(FamilyTreeLiveModel.summary(without).familySearchID == nil)
        #expect(FamilyTreeLiveModel.summary(without).surname == "Unknown")
    }

    // MARK: Hiding from the card menu

    /// Rick's actual workflow: he finds the wrong record before he can prove
    /// which is right, so hiding must not require naming a replacement.
    @Test @MainActor func hidingARecordFromTheMenuPersistsAndTakesEffect() async throws {
        let dir = try treeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = model(dir)
        await m.prepareForAppearance(revision: "t-\(UUID().uuidString)")
        try #require(m.peopleCount > 0, "the tree never loaded")

        #expect(!m.isSuppressedRecord("@I5@"), "precondition: the duplicate is visible")
        #expect(m.setRecordHidden(true, personID: "@I5@", note: "the wrong Mary"))
        #expect(m.isSuppressedRecord("@I5@"), "hiding did not take")
        #expect(!m.isSuppressedRecord("@I7@"), "hiding one Mary hid the other")

        // It outlives the session — a fresh model reads the same file.
        let again = model(dir)
        #expect(again.identityDecisions.isSuppressed(.familySearch("GNZ5-428")),
                "the ruling did not reach disk")

        // And it is reversible.
        #expect(m.setRecordHidden(false, personID: "@I5@"))
        #expect(!m.isSuppressedRecord("@I5@"))
    }

    /// A record with no FamilySearch id cannot be hidden: there is nothing
    /// durable to key the ruling on, and one that drifted onto a namesake
    /// would be worse than the duplicate it hid.
    @Test @MainActor func aRecordWithNoIDCannotBeHidden() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        0 HEAD
        0 @I1@ INDI
        1 NAME Someone /Unknown/
        0 TRLR
        """.write(to: dir.appendingPathComponent("tree.ged"), atomically: true, encoding: .utf8)
        let m = model(dir)
        await m.prepareForAppearance(revision: "t-\(UUID().uuidString)")
        #expect(m.setRecordHidden(true, personID: "@I1@") == false,
                "a record with no id must refuse to be hidden, and say so")
        #expect(!m.isSuppressedRecord("@I1@"))
    }

    /// A damaged rulings file must not stop the tree from opening.
    @Test @MainActor func adamagedRulingsFileIsIgnoredRatherThanFatal() throws {
        let dir = try treeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("{ not json".utf8)
            .write(to: FamilyIdentityDecisions.fileURL(in: dir))
        let m = model(dir)
        #expect(m.identityDecisions.isEmpty)
        #expect(!m.isSuppressedRecord("@I5@"), "a damaged file must hide nobody")
    }
}
