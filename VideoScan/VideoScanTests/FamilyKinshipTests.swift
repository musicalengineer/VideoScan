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

    /// Rick's contemporary family. Profiles use the Director's CORRECTED
    /// acceptance shapes (2026-08-27): Rick carries his formal Jr name and
    /// nicknames, Dad carries the Sr name — "Dad" is NOT an alias of Rick.
    ///   Dad + Mary (parents) → Rick ═ Donna; Rick's siblings Tim (younger)
    ///   and Ann; Tim ═ Kate; Rick's sons Matt (═ Sue) and Timothy.
    /// (The Tim/Timothy shared-spelling case lives in its own sensor.)
    private static let family: [POIProfile] = [
        profile("Rick", aliases: ["Dicky", "Rich", "Richy", "Richard Harding Breen Jr"],
                sex: .male, born: 1962, kinships: [
            // Stored as "Rick is child of Dad" (row semantics: <profile> is
            // <relation> of <anchor>, the editor's "[child] of [Dad]").
            Kinship(relation: .child, relativeTo: .profile(name: "Dad")),
        ]),
        profile("Dad", aliases: ["Grampa Breen", "Dick", "Dad Breen", "Richard Harding Breen Sr"],
                sex: .male, born: 1931),
        profile("Donna", aliases: ["Mom", "Donna Breen"], sex: .female, born: 1959, kinships: [
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
        profile("Timothy", sex: .male, born: 1990, kinships: [
            Kinship(relation: .child, relativeTo: .profile(name: "Rick")),
            Kinship(relation: .child, relativeTo: .profile(name: "Donna")),
        ]),
        profile("Sue", sex: .female, kinships: [
            Kinship(relation: .spouse, relativeTo: .profile(name: "Matt")),
        ]),
    ]

    /// main's FamilyTreeLiveModelTests.juniorSeniorGedcom (6017591f) — the
    /// two Richards + Donna — plus one FAM so Sr is Jr's tree father. No
    /// siblings/children for Jr (Rick's real, ancestors-only situation).
    private static let tree = """
    0 HEAD
    0 @I1@ INDI
    1 NAME Richard Harding /Breen/ Jr
    1 _FSFTID GVQV-NW3
    1 FAMC @F1@
    0 @I2@ INDI
    1 NAME Richard Harding /Breen/ Sr
    1 _FSFTID G2S4-JF4
    1 FAMS @F1@
    0 @I3@ INDI
    1 NAME Donna /Breen/
    0 @F1@ FAM
    1 HUSB @I2@
    1 CHIL @I1@
    0 TRLR
    """

    /// The profiles as they were LIVE on 2026-08-27: "Dad" is an alias of
    /// Rick, and neither profile carries a formal GEDCOM name.
    private static let uncorrected: [POIProfile] = [
        profile("Rick", aliases: ["Dicky", "Dad"], sex: .male, born: 1962, kinships: [
            Kinship(relation: .child, relativeTo: .profile(name: "Dad")),
        ]),
        profile("Dad", aliases: ["Grampa Breen", "Dick", "Dad Breen"], sex: .male, born: 1931),
        profile("Donna", aliases: ["Mom"], sex: .female, born: 1959, kinships: [
            Kinship(relation: .spouse, relativeTo: .profile(name: "Rick")),
        ]),
    ]

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

    @Test func unreadableRowsAreQuarantinedPerRowAndSurviveASave() throws {
        // A future build writes a relation this build doesn't know, next to
        // two readable rows: the two stay usable, the odd one is kept
        // verbatim and written back on save (codex #778).
        let json = #"""
        {"name": "Tim", "referencePath": "/p", "sex": "male",
         "kinships": [{"relation": "sibling", "relativeTo": {"profile": {"name": "Rick"}}},
                      {"relation": "godparent", "relativeTo": {"profile": {"name": "Rick"}}, "note": "keep me"},
                      {"relation": "spouse", "relativeTo": {"treePerson": {"familySearchID": "GVQV-NW3"}}}]}
        """#
        let p = try JSONDecoder().decode(POIProfile.self, from: Data(json.utf8))
        #expect(p.name == "Tim")
        #expect(p.kinships.map(\.relation) == [.sibling, .spouse])
        #expect(p.kinshipsQuarantined.count == 1)

        let data = try JSONEncoder().encode(p)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((obj["kinships"] as? [Any])?.count == 2)
        let kept = try #require(obj["kinshipsQuarantined"] as? [[String: Any]])
        #expect(kept.count == 1)
        #expect(kept[0]["relation"] as? String == "godparent")
        #expect(kept[0]["note"] as? String == "keep me")
        // And a second round trip still carries it.
        let again = try JSONDecoder().decode(POIProfile.self, from: data)
        #expect(again.kinshipsQuarantined == p.kinshipsQuarantined)
        #expect(again.kinships == p.kinships)
    }

    @Test func durableAnchorsSurviveARename() throws {
        // Legacy name anchors are upgraded to uuid anchors on load; a rename
        // of the anchored profile then leaves the other profile's row intact.
        let rick = Self.profile("Rick", sex: .male, born: 1962)
        let tim = Self.profile("Tim", sex: .male, born: 1965, kinships: [
            Kinship(relation: .sibling, relativeTo: .profile(name: "Rick")),
        ])
        let upgraded = POIProfile.upgradingKinshipAnchors([rick, tim])
        #expect(upgraded[1].kinships == [Kinship(relation: .sibling, relativeTo: .profile(id: rick.uuid))])

        // The uuid anchor round-trips as {"profile":{"id":…}}.
        let data = try JSONEncoder().encode(upgraded[1])
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let row = try #require((obj["kinships"] as? [[String: Any]])?.first)
        #expect(((row["relativeTo"] as? [String: Any])?["profile"] as? [String: Any])?["id"] as? String
                == rick.uuid.uuidString)
        #expect(try JSONDecoder().decode(POIProfile.self, from: data).kinships == upgraded[1].kinships)

        var renamed = upgraded[0]
        renamed.name = "Richard"
        let overlay = FamilyKinshipOverlay(profiles: [renamed, upgraded[1]], graph: nil)
        #expect(overlay.relationshipsLine(forProfileStableID: "tim", kinships: upgraded[1].kinships)
                == "Richard's younger brother")
        // A uuid nobody has any more is named honestly and flagged.
        let orphan = Self.profile("Ann", sex: .female, kinships: [
            Kinship(relation: .sibling, relativeTo: .profile(id: UUID())),
        ])
        let orphaned = FamilyKinshipOverlay(profiles: [orphan], graph: nil)
        #expect(orphaned.relationshipsLine(forProfileStableID: "ann", kinships: orphan.kinships)
                == "a removed profile's sister")
        #expect(orphaned.warnings(forProfileNamed: "Ann").count == 1)
    }

    @Test func stepAndHalfRelationsAreNeverInvented() {
        #expect(KinshipRelation.compose([.spouse, .child]) == nil)      // spouse's child ≠ my child
        #expect(KinshipRelation.compose([.parent, .spouse]) == nil)     // parent's spouse ≠ my parent
        #expect(KinshipRelation.compose([.sibling, .sibling]) == nil)   // sibling's sibling ≠ my sibling
        // And the overlay shows the route instead of a word for such a chain.
        let profiles = [
            Self.profile("Rick", sex: .male),
            Self.profile("Jane", sex: .female, kinships: [
                Kinship(relation: .spouse, relativeTo: .profile(name: "Rick")),
            ]),
            Self.profile("Kid", sex: .male, kinships: [
                Kinship(relation: .child, relativeTo: .profile(name: "Jane")),
            ]),
        ]
        let result = ArchivistGraphExecutor.execute(relationship("Rick", "Kid"), inputs: inputs(profiles))
        #expect(result.prose == "Kid is related to Rick through Rick's wife Jane → son Kid — the People tab links them, but not in a way with a single name.")
        let sons = ArchivistGraphExecutor.execute(kinship("Rick", .son), inputs: inputs(profiles))
        #expect(sons.conclusion != .answered)
    }

    @Test func overlayAndPersonResolverGiveTheSameVerdict() {
        for profiles in [Self.family, Self.uncorrected] {
            let overlay = inputs(profiles).kinshipOverlay
            let resolver = PersonResolver(profiles: profiles)
            for spelling in ["Rick", "Dad", "Dicky", "Dick", "Dad Breen", "Mom", "Nobody", "Timothy"] {
                let nodes = overlay.nodes(claiming: spelling)
                switch resolver.resolve(spelling) {
                case .resolved(let name):
                    #expect(nodes.count == 1, Comment(rawValue: spelling))
                    #expect(nodes.first.flatMap { overlay.member($0)?.name } == name, Comment(rawValue: spelling))
                case .ambiguous(let candidates):
                    #expect(Set(nodes.compactMap { overlay.member($0)?.name }) == Set(candidates), Comment(rawValue: spelling))
                case .unknown:
                    #expect(nodes.isEmpty, Comment(rawValue: spelling))
                }
            }
        }
    }

    @MainActor
    @Test func displayCenterRebuildsWhenASameCountTreeReplacesTheOld() {
        let cara = Self.profile("Cara", sex: .female, kinships: [
            Kinship(relation: .nieceNephew, relativeTo: .treePerson(familySearchID: "GVQV-NW3")),
        ])
        let center = KinshipDisplayCenter()
        center.install(graph: graph)
        #expect(center.relationshipsLine(for: cara, among: [cara]) == "Richard Harding Breen Jr's niece")
        // Same people count, different content.
        let replaced = GedcomFamilyGraph(gedcomText: Self.tree.replacingOccurrences(
            of: "Richard Harding /Breen/ Jr", with: "Richard Harding /Breen/ Junior"))
        #expect(replaced.people.count == graph.people.count)
        center.install(graph: replaced)
        #expect(center.relationshipsLine(for: cara, among: [cara]) == "Richard Harding Breen Junior's niece")
        #expect(center.graphGeneration == 2)
    }

    @Test func exportLocalPointerAnchorsHoldOnlyForTheirExport() {
        // An Ancestry-style export: no FamilySearch IDs at all.
        let ancestry = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I7@ INDI
        1 NAME Thankful /Pratt/
        1 SEX F
        0 TRLR
        """)
        let fingerprint = FamilyKinshipOverlay.fingerprint(of: ancestry)
        let cara = Self.profile("Cara", sex: .female, kinships: [
            Kinship(relation: .grandchild, relativeTo: .treePointer(pointer: "@I7@", sourceFingerprint: fingerprint)),
        ])
        let live = FamilyKinshipOverlay(profiles: [cara], graph: ancestry)
        #expect(live.relationshipsLine(forProfileStableID: "cara", kinships: cara.kinships)
                == "Thankful Pratt's granddaughter")
        #expect(live.warnings.isEmpty)
        // A different export (even one that reuses @I7@) makes the row stale.
        let other = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I7@ INDI
        1 NAME Somebody /Else/
        0 TRLR
        """)
        let stale = FamilyKinshipOverlay(profiles: [cara], graph: other)
        #expect(stale.relationshipsLine(forProfileStableID: "cara", kinships: cara.kinships)
                == "tree person @I7@ (export changed)'s granddaughter")
        #expect(stale.warnings(forProfileNamed: "Cara") == ["Relationship row on Cara points at @I7@ in an older tree export — pick them again"])
        // Same content copied to a new file keeps the same fingerprint.
        #expect(FamilyKinshipOverlay.fingerprint(of: GedcomFamilyGraph(gedcomText: "0 HEAD\n0 @I7@ INDI\n1 NAME Thankful /Pratt/\n1 SEX F\n0 TRLR")) == fingerprint)
    }

    @Test func myDadResolvesThroughTheRowNotTheStrayAlias() {
        // Live conflict: Rick still carries the "Dad" alias, Dad has the Sr
        // formal name. "my dad" must follow Rick's "child of Dad" row → Sr.
        let conflicting: [POIProfile] = [
            Self.profile("Rick", aliases: ["Dicky", "Dad"], sex: .male, born: 1962, kinships: [
                Kinship(relation: .child, relativeTo: .profile(name: "Dad")),
            ]),
            Self.profile("Dad", aliases: ["Grampa Breen", "Dick", "Dad Breen", "Richard Harding Breen Sr"],
                         sex: .male, born: 1931),
        ]
        let speakers = HallieTurnExecutor.Speakers(ownerName: "Rick Breen", archivistName: "Hallie Mae")
        // main's juniorSeniorGedcom exactly: no FAM, so the tree alone
        // cannot name a father.
        let bareTree = GedcomFamilyGraph(gedcomText: Self.tree
            .replacingOccurrences(of: "1 FAMC @F1@\n", with: "")
            .replacingOccurrences(of: "1 FAMS @F1@\n", with: "")
            .replacingOccurrences(of: "0 @F1@ FAM\n1 HUSB @I2@\n1 CHIL @I1@\n", with: ""))
        #expect(bareTree.familyCount == 0)

        let overlay = FamilyKinshipOverlay(profiles: conflicting, graph: bareTree)
        let bound = HallieTurnExecutor.SpeakerKinship.rebind(
            people: ["me"], question: "show me videos of my dad", speakers: speakers,
            graph: bareTree, kinshipOverlay: overlay)
        #expect(bound.failure == nil)
        #expect(bound.people == ["Dad"])
        #expect(bound.notes == ["'my dad' = Dad (Richard Harding Breen Sr), father of Rick Breen in the People tab relationships"])

        // Row absent → the tree is asked and declines honestly by name.
        var rowless = conflicting
        rowless[0].kinships = []
        let declined = HallieTurnExecutor.SpeakerKinship.rebind(
            people: ["me"], question: "show me videos of my dad", speakers: speakers,
            graph: bareTree, kinshipOverlay: FamilyKinshipOverlay(profiles: rowless, graph: bareTree))
        #expect(declined.failure?.hasPrefix("The family tree doesn't list a father for Richard Harding Breen Jr") == true)
        #expect(declined.people == ["me"])
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
        let result = ArchivistGraphExecutor.execute(relationship("Rick", "Timothy"), inputs: inputs())
        #expect(result.conclusion == .answered)
        #expect(result.prose == "Timothy is Rick's son.")
        #expect(result.evidence?.counterpart?.name == "Timothy")
        let reverse = ArchivistGraphExecutor.execute(relationship("Timothy", "Rick"), inputs: inputs())
        #expect(reverse.prose == "Rick (Richard Harding Breen Jr) is Timothy's father.")
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

     func unknownRelationFallsThroughToTheTree() {
        // Donna bridges to @I3@ via "Donna Breen"; the overlay has no parent
        // rows for her, so "father" must fall through to the GEDCOM decline.
        let result = ArchivistGraphExecutor.execute(kinship("Donna", .father), inputs: inputs())
        #expect(result.conclusion == .missingFact)
        #expect(result.prose.hasPrefix("The family tree doesn't record a father for Donna Breen"))
        #expect(!result.basisLine.contains("People tab relationship"))
        // Mother comes from the overlay even though the tree records none.
        let mother = ArchivistGraphExecutor.execute(kinship("Rick", .mother), inputs: inputs())
        #expect(mother.prose == "Rick's mother: Mary.")
    }

    // MARK: 5. Director acceptance contract (codex #772)

     func correctedShapesPinEverySpellingToTheRightRichard() {
        let overlay = inputs().kinshipOverlay
        for spelling in ["Rick", "Dicky", "Rich", "Richy", "Richard Harding Breen Jr", "rick breen"] {
            #expect(overlay.nodes(claiming: spelling, ownerName: "Rick Breen") == [.tree(gedcomID: "@")],
                    Comment(rawValue: spelling))
        }
        for spelling in ["Dad", "Dad Breen", "Dick", "Grampa Breen", "Richard Harding Breen Sr"] {
            #expect(overlay.nodes(claiming: spelling) == [.tree(gedcomID: "@")],
                    Comment(rawValue: spelling))
        }
        #expect(overlay.member(.tree(gedcomID: "@"))?.displayName == "Dad (Richard Harding Breen Sr)")
        #expect(overlay.warnings.isEmpty)

        // The row on Rick's profile ("Rick is child of Dad") answers both ways.
        let father = ArchivistGraphExecutor.execute(kinship("Rick", .father), inputs: inputs())
        #expect(father.conclusion == .answered)
        #expect(father.prose == "Rick's father: Dad (Richard Harding Breen Sr).")
        #expect(father.basisLine.hasPrefix("Basis: People tab relationship (stored on Rick's profile)"))
        let son = ArchivistGraphExecutor.execute(kinship("Grampa Breen", .son), inputs: inputs())
        #expect(son.prose == "Dad's son: Rick (Richard Harding Breen Jr).")
        let related = ArchivistGraphExecutor.execute(relationship("Dicky", "Dick"), inputs: inputs())
        #expect(related.prose == "Dad (Richard Harding Breen Sr) is Rick's father.")

        // The same fact stored on Dad's side ("Dad is parent of Rick") is
        // equivalent — the overlay adds inverses.
        var dadSide = Self.family
        dadSide[0].kinships = []
        dadSide[1].kinships = [Kinship(relation: .parent, relativeTo: .profile(name: "Rick"))]
        let mirrored = ArchivistGraphExecutor.execute(kinship("Rick", .father), inputs: inputs(dadSide))
        #expect(mirrored.prose == "Rick's father: Dad (Richard Harding Breen Sr).")
    }

     func uncorrectedLiveShapesReportDadAsAmbiguousNeverRick() {
        let overlay = inputs(Self.uncorrected).kinshipOverlay
        // "Dad" is claimed by Rick (alias) and Dad (canonical): a relational
        // word shared by two profiles is reported, never resolved to Rick.
        let claimants = overlay.nodes(claiming: "Dad")
        #expect(claimants.count == 2)
        #expect(overlay.warnings == ["Alias 'Dad' on Rick looks relational — use a Relationship row instead"])
        #expect(overlay.warnings(forProfileNamed: "Rick").count == 1)
        #expect(overlay.warnings(forProfileNamed: "Dad").isEmpty)

        // Asking about "Dad" never yields an answer about Rick.
        let son = ArchivistGraphExecutor.execute(kinship("Dad", .son), inputs: inputs(Self.uncorrected))
        #expect(son.conclusion != .answered)
        #expect(!son.prose.contains("Rick's"))
        #expect(!son.basisLine.contains("People tab relationship"))
        // No formal aliases → the tree cannot tell Jr from Sr → unbridged.
        #expect(overlay.node(profileStableID: "rick") == .profile(stableID: "rick"))
        #expect(overlay.node(profileStableID: "dad") == .profile(stableID: "dad"))

        // The Relationships line resolves the ANCHOR by canonical profile,
        // so Rick's card still names the Dad profile, never himself.
        let rick = Self.uncorrected[0]
        #expect(overlay.relationshipsLine(forProfileStableID: rick.id, kinships: rick.kinships) == "Dad's son")
        let father = ArchivistGraphExecutor.execute(kinship("Rick", .father), inputs: inputs(Self.uncorrected))
        #expect(father.prose == "Rick's father: Dad.")
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
