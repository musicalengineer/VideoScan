// FamilyKinshipTests.swift
// People-tab typed relationships (2026-08-27). Five dimensions per the
// feature-test checklist:
//   1. Logic     — schema decode (legacy/new/round-trip), inverse and
//                  composition tables, derived display strings
//   2. Scale     — 500 profiles × 5 kinships overlay build < 50 ms
//   3. Media     — n/a (no media files opened)
//   4. Isolation — every profile here is an in-memory fixture; the only
//                  file I/O is a per-test temp dir. Nothing reads or writes
//                  ~/Library/Application Support or UserDefaults.
//   5. Sensor    — the resolver cases pin the director's examples:
//                  "who is Rick's brother" → Tim (not Timothy, disambiguated
//                  by profile), "how is Timothy related to Rick" → son,
//                  "who is Donna's sister-in-law".
// The GEDCOM fixture is synthetic (2026-08-03 privacy policy).

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

struct FamilyKinshipTests {

    // MARK: Fixtures

    private static func date(_ y: Int) -> Date {
        var dc = DateComponents()
        dc.year = y; dc.month = 6; dc.day = 15; dc.hour = 12
        dc.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: dc) ?? .distantPast
    }

    private static func profile(
        _ name: String, aliases: [String] = [], sex: PersonSex? = nil,
        born: Int? = nil, kinships: [Kinship] = []
    ) -> POIProfile {
        POIProfile(name: name, referencePath: "/fixture/\(name)", aliases: aliases,
                   birthdate: born.map(date), sex: sex, kinships: kinships)
    }

    /// Rick's contemporary family, none of it in the tree:
    ///   Mary (mother) → Rick ═ Donna; Rick's siblings Tim (younger) and Ann
    ///   Tim ═ Kate; Rick's sons Matt (═ Sue) and Timothy.
    /// Tim (brother) and Timothy (son) share the "Tim" spelling on purpose.
    private static let family: [POIProfile] = [
        profile("Rick", aliases: ["Richard Breen", "Dad"], sex: .male, born: 1962),
        profile("Donna", aliases: ["Mom"], sex: .female, born: 1959, kinships: [
            Kinship(relation: .spouse, relativeTo: .profile(name: "Rick")),
        ]),
        profile("Mary", sex: .female, born: 1935, kinships: [
            Kinship(relation: .parent, relativeTo: .profile(name: "Rick")),
        ]),
        profile("Tim", aliases: ["Timmy"], sex: .male, born: 1965, kinships: [
            Kinship(relation: .sibling, relativeTo: .profile(name: "rick")),
        ]),
        profile("Ann", sex: .female, born: 1960, kinships: [
            Kinship(relation: .sibling, relativeTo: .profile(name: "Rick")),
        ]),
        profile("Kate", sex: .female, kinships: [
            Kinship(relation: .spouse, relativeTo: .profile(name: "Tim")),
        ]),
        profile("Matt", sex: .male, born: 1988, kinships: [
            Kinship(relation: .child, relativeTo: .profile(name: "Rick")),
            Kinship(relation: .child, relativeTo: .profile(name: "Donna")),
        ]),
        profile("Timothy", aliases: ["Tim"], sex: .male, born: 1990, kinships: [
            Kinship(relation: .child, relativeTo: .profile(name: "Rick")),
            Kinship(relation: .child, relativeTo: .profile(name: "Donna")),
        ]),
        profile("Sue", sex: .female, kinships: [
            Kinship(relation: .spouse, relativeTo: .profile(name: "Matt")),
        ]),
    ]

    /// Ancestors-only tree, FamilySearch-shaped: Rick's record has a father
    /// but no siblings/children (that is Rick's real situation).
    private static let tree = """
    0 HEAD
    0 @I1@ INDI
    1 NAME Richard Harding /Breen/ Jr
    1 SEX M
    1 _FSFTID GVQV-NW3
    1 FAMC @F1@
    0 @I2@ INDI
    1 NAME Harold /Breen/
    1 SEX M
    1 BIRT
    2 DATE 1931
    1 FAMS @F1@
    0 @F1@ FAM
    1 HUSB @I2@
    1 CHIL @I1@
    0 TRLR
    """

    private var graph: GedcomFamilyGraph { GedcomFamilyGraph(gedcomText: Self.tree) }

    private func inputs(_ profiles: [POIProfile] = family, ownerName: String? = "Rick Breen")
        -> ArchivistGraphInputs {
        ArchivistGraphInputs(
            graph: graph,
            profiles: profiles.map {
                ArchivistGraphProfileSnapshot(
                    stableID: $0.id, canonicalName: $0.name, aliases: $0.aliases,
                    kinships: $0.kinships, sex: $0.sex, birthdate: $0.birthdate)
            },
            ownerName: ownerName)
    }

    private func kinship(_ name: String, _ relation: ArchivistGraphQuery.Relation,
                         voices: [Int: ArchivistGraphQuery.Voice] = [:]) -> ArchivistGraphQuery {
        ArchivistGraphQuery(people: [name], operation: .kinship, relation: relation, voices: voices)
    }

    private func relationship(_ a: String, _ b: String) -> ArchivistGraphQuery {
        ArchivistGraphQuery(people: [a, b], operation: .relationship)
    }

    // MARK: 1. Schema

    @Test func legacyProfileJSONWithoutKinshipsDecodesToEmpty() throws {
        let legacy = #"{"name": "Grandpa", "referencePath": "/old/path", "sex": "male"}"#
        let p = try JSONDecoder().decode(POIProfile.self, from: Data(legacy.utf8))
        #expect(p.kinships.isEmpty)
        #expect(p.sex == .male)
    }

    @Test func kinshipsRoundTripThroughTempFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_kinship_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let original = Self.profile("Tim", sex: .male, born: 1965, kinships: [
            Kinship(relation: .sibling, relativeTo: .profile(name: "Rick"), note: "younger by 3 years"),
            Kinship(relation: .nieceNephew, relativeTo: .treePerson(familySearchID: "GVQV-NW3")),
        ])
        let url = dir.appendingPathComponent("profile.json")
        try JSONEncoder().encode(original).write(to: url)
        let decoded = try JSONDecoder().decode(POIProfile.self, from: Data(contentsOf: url))
        #expect(decoded == original)
        #expect(decoded.kinships.count == 2)
        #expect(decoded.kinships[0].note == "younger by 3 years")
        #expect(decoded.kinships[1].relativeTo == .treePerson(familySearchID: "GVQV-NW3"))

        // The on-disk shape is the raw enum strings (persistence contract).
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let rows = try #require(obj["kinships"] as? [[String: Any]])
        #expect(rows[0]["relation"] as? String == "sibling")
        #expect((rows[0]["relativeTo"] as? [String: Any])?["profile"] != nil)
    }

    @Test func newerRelationCaseDropsTheListNotTheProfile() throws {
        // A future build writes a relation this build doesn't know: the
        // profile still loads (name, sex intact); kinships degrade to [].
        let json = #"""
        {"name": "Tim", "referencePath": "/p", "sex": "male",
         "kinships": [{"relation": "godparent", "relativeTo": {"profile": {"name": "Rick"}}}]}
        """#
        let p = try JSONDecoder().decode(POIProfile.self, from: Data(json.utf8))
        #expect(p.name == "Tim")
        #expect(p.sex == .male)
        #expect(p.kinships.isEmpty)
    }

    // MARK: 1. Inverse + composition

    @Test func everyRelationHasAnInverseThatInvertsBack() {
        for relation in KinshipRelation.allCases {
            #expect(relation.inverse.inverse == relation, Comment(rawValue: relation.rawValue))
        }
        #expect(KinshipRelation.parent.inverse == .child)
        #expect(KinshipRelation.auntUncle.inverse == .nieceNephew)
        #expect(KinshipRelation.parentInLaw.inverse == .childInLaw)
    }

    @Test(arguments: [
        ([KinshipRelation.spouse, .sibling], KinshipRelation.siblingInLaw),   // brother-in-law
        ([.sibling, .spouse], .siblingInLaw),
        ([.child, .spouse], .childInLaw),                                     // daughter-in-law
        ([.spouse, .parent], .parentInLaw),
        ([.child, .child], .grandchild),
        ([.parent, .parent], .grandparent),
        ([.sibling, .child], .nieceNephew),
        ([.parent, .sibling], .auntUncle),
        ([.parent, .sibling, .child], .cousin),
        ([.parent, .child], .sibling),
        ([.spouse, .sibling, .spouse], .siblingInLaw),
    ])
    func compositionTable(hops: [KinshipRelation], expected: KinshipRelation) {
        #expect(KinshipRelation.compose(hops) == expected)
    }

    @Test func unnameableChainsComposeToNil() {
        #expect(KinshipRelation.compose([.spouse, .spouse]) == nil)
        #expect(KinshipRelation.compose([.parent, .parent, .parent]) == nil) // great-grand: out of vocabulary
        #expect(KinshipRelation.compose([]) == nil)
    }

    @Test func genderedTermsAndParsingAgree() {
        #expect(KinshipRelation.sibling.term(sex: .male) == "brother")
        #expect(KinshipRelation.sibling.term(sex: .female) == "sister")
        #expect(KinshipRelation.sibling.term(sex: nil) == "sibling")
        #expect(KinshipRelation.childInLaw.term(sex: .female) == "daughter-in-law")
        #expect(KinshipRelation.parse(term: "mother-in-law")?.relation == .parentInLaw)
        #expect(KinshipRelation.parse(term: "mother-in-law")?.sex == .female)
        #expect(KinshipRelation.parse(term: "cousins")?.relation == .cousin)
        #expect(KinshipRelation.parse(term: "great-grandfather") == nil)
        // Every graph-vocabulary word the overlay claims to answer parses.
        for relation in ArchivistGraphQuery.Relation.allCases
        where !relation.rawValue.contains("great") {
            #expect(KinshipRelation.parse(term: relation.rawValue) != nil, Comment(rawValue: relation.rawValue))
        }
    }

    // MARK: 1. Display strings (derived, never stored)

    @Test func displayStringsUseBirthdatesAndOmitAgeWhenUnknown() {
        let overlay = FamilyKinshipOverlay(profiles: Self.family, graph: nil)
        let tim = Self.family.first { $0.name == "Tim" }!
        #expect(overlay.relationshipsLine(forProfileStableID: tim.id, kinships: tim.kinships)
                == "Rick's younger brother")
        let ann = Self.family.first { $0.name == "Ann" }!
        #expect(overlay.relationshipsLine(forProfileStableID: ann.id, kinships: ann.kinships)
                == "Rick's older sister")
        // Kate has no birthdate and the relation is spouse: no age word.
        let kate = Self.family.first { $0.name == "Kate" }!
        #expect(overlay.relationshipsLine(forProfileStableID: kate.id, kinships: kate.kinships)
                == "Tim's wife")
    }

    @Test func displayAddsDerivedRelationToDefaultAnchor() {
        let overlay = FamilyKinshipOverlay(profiles: Self.family, graph: nil)
        let rick = overlay.node(profileStableID: "rick")
        let sue = Self.family.first { $0.name == "Sue" }!
        #expect(overlay.relationshipsLine(forProfileStableID: sue.id, kinships: sue.kinships,
                                          defaultAnchor: rick)
                == "Matt's wife (Rick's daughter-in-law)")
        // Anchored on Donna instead: Mary is her mother-in-law.
        let donna = overlay.node(profileStableID: "donna")
        let mary = Self.family.first { $0.name == "Mary" }!
        #expect(overlay.relationshipsLine(forProfileStableID: mary.id, kinships: mary.kinships,
                                          defaultAnchor: donna)
                == "Rick's mother (Donna's mother-in-law)")
        // A row that already names the default anchor gets no parenthetical.
        let tim = Self.family.first { $0.name == "Tim" }!
        #expect(overlay.relationshipsLine(forProfileStableID: tim.id, kinships: tim.kinships,
                                          defaultAnchor: rick)
                == "Rick's younger brother")
        // No rows ⇒ no line.
        #expect(overlay.relationshipsLine(forProfileStableID: "rick", kinships: []) == nil)
    }

    @Test func treeAnchoredRowDisplaysTheTreeName() {
        let junior = Self.profile("Cara", sex: .female, kinships: [
            Kinship(relation: .nieceNephew, relativeTo: .treePerson(familySearchID: "gvqv-nw3")),
        ])
        let overlay = FamilyKinshipOverlay(profiles: [junior], graph: graph)
        #expect(overlay.relationshipsLine(forProfileStableID: junior.id, kinships: junior.kinships)
                == "Richard Harding Breen Jr's niece")
        // Same row with NO tree loaded still displays, by ID.
        let blind = FamilyKinshipOverlay(profiles: [junior], graph: nil)
        #expect(blind.relationshipsLine(forProfileStableID: junior.id, kinships: junior.kinships)
                == "FamilySearch GVQV-NW3's niece")
    }

    // MARK: 5. Resolver sensors (the director's examples)

    @Test func whoIsRicksBrotherIsTimNotTimothy() {
        let result = ArchivistGraphExecutor.execute(kinship("Rick", .brother), inputs: inputs())
        #expect(result.conclusion == .answered)
        #expect(result.prose == "Rick's brother: Tim.")
        #expect(result.basisLine.hasPrefix("Basis: People tab relationship (stored on Tim's profile)"))
        #expect(!result.prose.contains("Timothy"))
    }

    @Test func ownerVoiceSaysYour() {
        let result = ArchivistGraphExecutor.execute(
            kinship("Rick Breen", .children, voices: [0: .owner]), inputs: inputs())
        #expect(result.conclusion == .answered)
        #expect(result.prose == "Your children: Matt, Timothy.")
    }

    @Test func howIsTimothyRelatedToRickIsSon() {
        // "Timothy" is a canonical name; "Tim" is also his alias — the
        // canonical spelling wins outright, so this is the son, not the brother.
        let result = ArchivistGraphExecutor.execute(relationship("Rick", "Timothy"), inputs: inputs())
        #expect(result.conclusion == .answered)
        #expect(result.prose == "Timothy is Rick's son.")
        #expect(result.evidence?.counterpart?.name == "Timothy")
        let reverse = ArchivistGraphExecutor.execute(relationship("Timothy", "Rick"), inputs: inputs())
        #expect(reverse.prose == "Rick is Timothy's father.")
        // And the brother by his own canonical name.
        let brother = ArchivistGraphExecutor.execute(relationship("Rick", "Tim"), inputs: inputs())
        #expect(brother.prose == "Tim is Rick's younger brother.")
    }

    @Test func composedRelationshipShowsItsRoute() {
        let result = ArchivistGraphExecutor.execute(relationship("Rick", "Sue"), inputs: inputs())
        #expect(result.conclusion == .answered)
        #expect(result.prose == "Sue is Rick's daughter-in-law — Rick's son Matt → wife Sue.")
        #expect(result.basisLine.contains("stored on Matt's profile, Sue's profile"))
    }

    @Test func anchorOnDonnaSisterInLaw() {
        let result = ArchivistGraphExecutor.execute(kinship("Donna", .sisterInLaw), inputs: inputs())
        #expect(result.conclusion == .answered)
        // Ann (husband's sister) and Kate (husband's brother's wife), with
        // the derived routes spelled out; direct one-hop rows would be bare.
        #expect(result.prose == "Donna's sisters-in-law: Ann (husband Rick → sister Ann), Kate (husband Rick → brother Tim → wife Kate).")
        let motherInLaw = ArchivistGraphExecutor.execute(kinship("Mom", .motherInLaw), inputs: inputs())
        #expect(motherInLaw.prose == "Donna's mother-in-law: Mary (husband Rick → mother Mary).")
    }

    @Test func grandchildrenAndCousinsCompose() {
        // The graph vocabulary has no "grandchildren" word; the overlay
        // still composes child∘child for the display layer.
        let overlay = inputs().kinshipOverlay
        let grandchildren = overlay.relatives(of: overlay.node(profileStableID: "mary")!, relation: .grandchild)
        #expect(grandchildren.map(\.member.name) == ["Matt", "Timothy"])
        #expect(grandchildren.allSatisfy { $0.hops.count == 2 })
        let uncle = ArchivistGraphExecutor.execute(kinship("Timothy", .uncle), inputs: inputs())
        #expect(uncle.prose == "Timothy's uncle: Tim (father Rick → brother Tim).")
        let nephews = ArchivistGraphExecutor.execute(kinship("Tim", .niecesAndNephews), inputs: inputs())
        #expect(nephews.prose == "Tim's nieces-and-nephews: Matt (brother Rick → son Matt), Timothy (brother Rick → son Timothy).")
    }

    @Test func unknownRelationFallsThroughToTheTree() {
        // Rick's profile bridges to the tree via "Richard Breen"; the overlay
        // has only his MOTHER, so "father" must fall through to GEDCOM.
        let result = ArchivistGraphExecutor.execute(kinship("Rick", .father), inputs: inputs())
        #expect(result.conclusion == .answered)
        #expect(result.prose == "Richard Harding Breen Jr's father: Harold Breen.")
        #expect(!result.basisLine.contains("People tab relationship"))
        // Mother comes from the overlay even though the tree records none.
        let mother = ArchivistGraphExecutor.execute(kinship("Rick", .mother), inputs: inputs())
        #expect(mother.prose == "Rick's mother: Mary.")
    }

    @Test func treePinnedSelectionUnionsWithTheProfile() {
        // The owner chain pins "rick" to the GEDCOM record; the overlay
        // still answers because the profile claims the same spelling.
        let result = ArchivistGraphExecutor.execute(
            kinship("rick", .brother), inputs: inputs(), subject: .gedcomPersonID("@I1@"))
        #expect(result.prose == "Rick's brother: Tim.")
    }

    @Test func sharedSpellingWithoutCanonicalWinnerIsLeftToClarification() {
        // Two profiles claim "Timmy" by alias only → the overlay steps aside.
        let twins = [
            Self.profile("Tim", aliases: ["Timmy"], sex: .male, kinships: [
                Kinship(relation: .sibling, relativeTo: .profile(name: "Rick")),
            ]),
            Self.profile("Timothy", aliases: ["Timmy"], sex: .male, kinships: [
                Kinship(relation: .child, relativeTo: .profile(name: "Rick")),
            ]),
            Self.profile("Rick", sex: .male),
        ]
        let result = ArchivistGraphExecutor.execute(kinship("Timmy", .father), inputs: inputs(twins))
        #expect(result.conclusion == .profileAmbiguous)
        #expect(!result.basisLine.contains("People tab relationship"))
    }

    @Test func noOverlayRowsLeavesEveryRouteUntouched() {
        let bare = Self.family.map { profile -> POIProfile in
            var copy = profile; copy.kinships = []; return copy
        }
        let result = ArchivistGraphExecutor.execute(kinship("Rick", .brother), inputs: inputs(bare))
        #expect(result.conclusion == .missingFact)
        #expect(result.prose.contains("doesn't record a brother"))
    }

    @MainActor
    @Test func turnExecutorRelationshipUsesOwnerSpellingFallback() async throws {
        // "Rick Breen" (the bound owner name) is NOT an alias on the profile;
        // the owner-spelling fallback reaches the one-word "Rick" profile.
        let context = HallieTurnExecutor.Context(
            profiles: Self.family.map {
                HallieTurnExecutor.ProfileSnapshot(
                    stableID: $0.id, canonicalName: $0.name, aliases: $0.aliases,
                    birthdate: $0.birthdate, kinships: $0.kinships, sex: $0.sex)
            },
            graph: graph,
            speakers: HallieTurnExecutor.Speakers(ownerName: "Rick Breen", archivistName: "Hallie Mae"))
        let intent = HallieTurnExecutor.Intent(
            originalQuestion: "how is Timothy related to Rick Breen?",
            ast: .graph(.init(people: ["Rick Breen", "Timothy"], operation: .relationship)))
        let result = try await HallieTurnExecutor.execute(.init(intent: intent), context: context)
        #expect(result.outcome == .answered)
        #expect(result.prose == "Timothy is Rick's son.")
        #expect(result.basisLine.hasPrefix("Basis: People tab relationship"))
        #expect(result.offeredActions.contains {
            if case .ask(let question, _) = $0 { return question == "who is Timothy?" }
            return false
        })

        // One-person kinship through the full turn path too.
        let brother = HallieTurnExecutor.Intent(
            originalQuestion: "who is Rick Breen's brother?",
            ast: .graph(.init(people: ["Rick Breen"], operation: .kinship, relation: .brother)))
        let answer = try await HallieTurnExecutor.execute(.init(intent: brother), context: context)
        #expect(answer.outcome == .answered)
        #expect(answer.prose == "Rick's brother: Tim.")
    }

    // MARK: 2. Scale

    @Test func fiveHundredProfilesTimesFiveKinshipsBuildsUnder50ms() {
        // A ring family: each profile is child of the previous, sibling of
        // the next, spouse of +2, cousin of +3, parent of +4 — 2,500 rows,
        // 5,000 directed edges.
        var profiles: [POIProfile] = []
        for i in 0..<500 {
            func name(_ k: Int) -> String { "P\((k + 500) % 500)" }
            profiles.append(Self.profile("P\(i)", sex: i % 2 == 0 ? .male : .female, born: 1900 + i % 100, kinships: [
                Kinship(relation: .child, relativeTo: .profile(name: name(i - 1))),
                Kinship(relation: .sibling, relativeTo: .profile(name: name(i + 1))),
                Kinship(relation: .spouse, relativeTo: .profile(name: name(i + 2))),
                Kinship(relation: .cousin, relativeTo: .profile(name: name(i + 3))),
                Kinship(relation: .parent, relativeTo: .profile(name: name(i + 4))),
            ]))
        }
        let clock = ContinuousClock()
        var overlay: FamilyKinshipOverlay?
        let elapsed = clock.measure {
            overlay = FamilyKinshipOverlay(profiles: profiles, graph: nil)
        }
        #expect(elapsed < .milliseconds(50), "overlay build took \(elapsed)")
        #expect(overlay?.edgeCount == 5_000)

        // Queries stay bounded on the dense ring (≤ 3 hops, no blow-up).
        let queryTime = clock.measure {
            for i in stride(from: 0, to: 500, by: 50) {
                _ = overlay?.relatives(of: .profile(stableID: "p\(i)"), relation: .cousin)
                _ = overlay?.path(from: .profile(stableID: "p\(i)"), to: .profile(stableID: "p\((i + 7) % 500)"))
            }
        }
        #expect(queryTime < .milliseconds(200), "10 cousin + 10 path queries took \(queryTime)")
    }
}
