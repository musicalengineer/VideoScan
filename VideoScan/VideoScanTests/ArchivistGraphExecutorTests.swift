import Foundation
import Testing
@testable import VideoScan

@MainActor
@Suite("Family Archivist deterministic graph executor", .serialized)
struct ArchivistGraphExecutorTests {
    private static let familyTree = """
    0 HEAD
    0 @I1@ INDI
    1 NAME Alex /River/ Sr
    1 SEX M
    1 BIRT
    2 DATE 1 JAN 1900
    1 DEAT
    2 DATE 2 FEB 1980
    1 FAMS @F1@
    0 @I2@ INDI
    1 NAME Bailey /River/
    1 SEX F
    1 FAMS @F1@
    0 @I3@ INDI
    1 NAME Chris /River/
    1 SEX M
    1 BIRT
    2 DATE 3 MAR 1930
    1 FAMC @F1@
    1 FAMS @F2@
    0 @I4@ INDI
    1 NAME Zoe /River/
    1 SEX F
    1 FAMC @F1@
    0 @I5@ INDI
    1 NAME Morgan /Vale/
    1 SEX F
    1 FAMS @F2@
    0 @I6@ INDI
    1 NAME Zoe /River/ Jr
    1 SEX F
    1 FAMC @F2@
    0 @I7@ INDI
    1 NAME Aaron /River/
    1 SEX M
    1 FAMC @F2@
    0 @I8@ INDI
    1 NAME Casey /Solo/
    0 @F1@ FAM
    1 HUSB @I1@
    1 WIFE @I2@
    1 CHIL @I3@
    1 CHIL @I4@
    0 @F2@ FAM
    1 HUSB @I3@
    1 WIFE @I5@
    1 CHIL @I7@
    1 CHIL @I6@
    0 TRLR
    """

    private var graph: GedcomFamilyGraph {
        GedcomFamilyGraph(gedcomText: Self.familyTree)
    }

    private func execute(
        people: [String],
        operation: ArchivistGraphQuery.Operation,
        relation: ArchivistGraphQuery.Relation? = nil,
        graph: GedcomFamilyGraph? = nil,
        profiles: [ArchivistGraphProfileSnapshot] = []
    ) -> ArchivistGraphResult {
        ArchivistGraphExecutor.execute(
            .init(people: people, operation: operation, relation: relation),
            inputs: .init(graph: graph ?? self.graph, profiles: profiles))
    }

    @Test func biographyCarriesFactsInDeterministicPolicyOrder() throws {
        let result = execute(people: ["Chris River"], operation: .biography)
        let repeated = execute(people: ["Chris River"], operation: .biography)

        #expect(result == repeated)
        #expect(result.conclusion == .answered)
        #expect(result.prose
                == "Chris River — born 3 MAR 1930; "
                    + "child of Alex River Sr and Bailey River; "
                    + "married to Morgan Vale; "
                    + "parent of Aaron River, Zoe River Jr.")
        #expect(result.basisLine == ArchivistBiographyPolicy.gedcomBasis)
        #expect(result.catalogPersonName == "Chris River")
        #expect(result.candidates.isEmpty)

        let evidence = try #require(result.evidence)
        #expect(evidence.subjectID == "@I3@")
        #expect(evidence.subjectName == "Chris River")
        #expect(evidence.birthDate == "3 MAR 1930")
        #expect(evidence.deathDate == nil)
        #expect(evidence.relationships.map(\.relation)
                == [.parents, .spouse, .children])
        #expect(evidence.relationships[0].people.map(\.id) == ["@I1@", "@I2@"])
        #expect(evidence.relationships[1].people.map(\.id) == ["@I5@"])
        // #expect is Swift Testing's direct equivalent of EXPECT_EQ.
        let childIDs = evidence.relationships[2].people.map(\.id)
        #expect(childIDs == ["@I7@", "@I6@"]) // Stable name order.
    }

    @Test func biographyProseAndEvidenceIgnoreGedcomDeclarationOrder() throws {
        let firstOrder = GedcomFamilyGraph(gedcomText: """
        0 @S@ INDI
        1 NAME Parent /One/
        1 FAMS @F2@
        1 FAMS @F1@
        0 @Z@ INDI
        1 NAME Zoe /Partner/
        1 FAMS @F2@
        0 @C2@ INDI
        1 NAME Sam /Child/
        1 FAMC @F2@
        0 @A@ INDI
        1 NAME Aaron /Child/
        1 FAMC @F2@
        0 @B@ INDI
        1 NAME Amy /Partner/
        1 FAMS @F1@
        0 @C1@ INDI
        1 NAME Sam /Child/
        1 FAMC @F1@
        0 @F2@ FAM
        1 HUSB @S@
        1 WIFE @Z@
        1 CHIL @C2@
        1 CHIL @A@
        0 @F1@ FAM
        1 HUSB @S@
        1 WIFE @B@
        1 CHIL @C1@
        0 TRLR
        """)
        let reversedOrder = GedcomFamilyGraph(gedcomText: """
        0 @C1@ INDI
        1 NAME Sam /Child/
        1 FAMC @F1@
        0 @B@ INDI
        1 NAME Amy /Partner/
        1 FAMS @F1@
        0 @A@ INDI
        1 NAME Aaron /Child/
        1 FAMC @F2@
        0 @C2@ INDI
        1 NAME Sam /Child/
        1 FAMC @F2@
        0 @Z@ INDI
        1 NAME Zoe /Partner/
        1 FAMS @F2@
        0 @S@ INDI
        1 NAME Parent /One/
        1 FAMS @F1@
        1 FAMS @F2@
        0 @F1@ FAM
        1 HUSB @S@
        1 WIFE @B@
        1 CHIL @C1@
        0 @F2@ FAM
        1 HUSB @S@
        1 WIFE @Z@
        1 CHIL @A@
        1 CHIL @C2@
        0 TRLR
        """)

        let first = execute(
            people: ["Parent One"], operation: .biography,
            graph: firstOrder)
        let reversed = execute(
            people: ["Parent One"], operation: .biography,
            graph: reversedOrder)

        #expect(first == reversed)
        #expect(first.prose
                == "Parent One — married to Amy Partner, Zoe Partner; "
                    + "parent of Aaron Child, Sam Child, Sam Child.")
        let evidence = try #require(first.evidence)
        #expect(evidence.relationships.map(\.relation) == [.spouse, .children])
        let spouseIDs = evidence.relationships[0].people.map(\.id)
        let childIDs = evidence.relationships[1].people.map(\.id)
        #expect(spouseIDs == ["@B@", "@Z@"]) // Stable name order.
        #expect(childIDs == ["@A@", "@C1@", "@C2@"]) // ID breaks name ties.
    }

    @Test func birthAndDeathExposeOnlyTheRequestedDateEvidence() throws {
        let birth = execute(people: ["Alex River Sr"], operation: .birth)
        #expect(birth.conclusion == .answered)
        #expect(birth.prose == "Alex River Sr was born 1 JAN 1900.")
        #expect(birth.evidence?.birthDate == "1 JAN 1900")
        #expect(birth.evidence?.deathDate == nil)
        #expect(birth.evidence?.relationships.isEmpty == true)

        let death = execute(people: ["Alex River Sr"], operation: .death)
        #expect(death.conclusion == .answered)
        #expect(death.prose == "Alex River Sr is no longer with us — he has been resting in peace since 2 FEB 1980.")
        #expect(death.evidence?.subjectID == "@I1@")
        #expect(death.evidence?.birthDate == nil)
        #expect(death.evidence?.deathDate == "2 FEB 1980")
    }

    @Test func everyKinshipRelationUsesTypedGraphSemantics() throws {
        let expectations: [(ArchivistGraphQuery.Relation, String, [String])] = [
            (.father, "Chris River", ["Alex River Sr"]),
            (.mother, "Chris River", ["Bailey River"]),
            (.parents, "Chris River", ["Alex River Sr", "Bailey River"]),
            (.brother, "Zoe River", ["Chris River"]),
            (.sister, "Chris River", ["Zoe River"]),
            (.siblings, "Chris River", ["Zoe River"]),
            (.son, "Chris River", ["Aaron River"]),
            (.daughter, "Chris River", ["Zoe River Jr"]),
            (.children, "Chris River", ["Aaron River", "Zoe River Jr"]),
            (.husband, "Morgan Vale", ["Chris River"]),
            (.wife, "Chris River", ["Morgan Vale"]),
            (.spouse, "Chris River", ["Morgan Vale"]),
        ]

        for (relation, subject, names) in expectations {
            let result = execute(
                people: [subject], operation: .kinship, relation: relation)
            #expect(result.conclusion == .answered, "\(relation) should answer")
            #expect(result.evidence?.relationships.count == 1)
            #expect(result.evidence?.relationships.first?.relation.rawValue
                    == relation.rawValue)
            #expect(result.evidence?.relationships.first?.people.map(\.name)
                    == names)
            #expect(result.basisLine == ArchivistBiographyPolicy.gedcomBasis)
        }
    }

    @Test func relationshipOrderingIsStableByNormalizedNameThenGedcomID() {
        let repeatedNames = GedcomFamilyGraph(gedcomText: """
        0 @P@ INDI
        1 NAME Parent /One/
        1 FAMS @F@
        0 @C2@ INDI
        1 NAME Sam /One/
        1 FAMC @F@
        0 @C1@ INDI
        1 NAME Sam /One/
        1 FAMC @F@
        0 @A@ INDI
        1 NAME Álvaro /One/
        1 FAMC @F@
        0 @F@ FAM
        1 HUSB @P@
        1 CHIL @C2@
        1 CHIL @C1@
        1 CHIL @A@
        0 TRLR
        """)

        let result = execute(
            people: ["Parent One"], operation: .kinship,
            relation: .children, graph: repeatedNames)

        #expect(result.prose == "Parent One's children: Álvaro One, Sam One, Sam One.")
        #expect(result.evidence?.relationships[0].people.map(\.id)
                == ["@A@", "@C1@", "@C2@"])
    }

    @Test func directGedcomResolutionFoldsCaseWhitespaceAndDiacritics() {
        let folded = GedcomFamilyGraph(gedcomText: """
        0 @R@ INDI
        1 NAME Renée /Dubois/
        1 BIRT
        2 DATE 7 JUL 1970
        0 TRLR
        """)

        let result = execute(
            people: ["  RENEE dubois\n"], operation: .birth, graph: folded)

        #expect(result.conclusion == .answered)
        #expect(result.prose == "Renée Dubois was born 7 JUL 1970.")
        #expect(result.evidence?.subjectID == "@R@")
    }

    @Test func profileAliasBridgesIdentityWhileFactsRetainGedcomProvenance() {
        let profile = ArchivistGraphProfileSnapshot(
            stableID: "rick", canonicalName: "Richard Breen",
            aliases: ["Rick", "Rícky"])
        let formalNames = GedcomFamilyGraph(gedcomText: """
        0 @RB@ INDI
        1 NAME Richard /Breen/
        1 BIRT
        2 DATE 4 MAR 1959
        0 @RJ@ INDI
        1 NAME Richard /Jones/
        0 TRLR
        """)

        for spelling in ["rick", " RICK ", "ricky"] {
            let requested = spelling.trimmingCharacters(
                in: .whitespacesAndNewlines)
            let result = execute(
                people: [spelling], operation: .birth,
                graph: formalNames, profiles: [profile])
            #expect(result.conclusion == .answered)
            #expect(result.basisLine
                    == "Basis: People profile identity bridge “\(requested)” "
                        + "→ “Richard Breen” → GEDCOM “Richard Breen”; "
                        + "family facts from imported family tree (GEDCOM).")
            #expect(result.evidence?.subjectID == "@RB@")
            #expect(result.evidence?.subjectName == "Richard Breen")
            #expect(result.evidence?.birthDate == "4 MAR 1959")
            #expect(result.evidence?.identityBridge
                    == ArchivistGraphEvidence.IdentityBridge(
                requestedName: requested,
                profileCanonicalName: "Richard Breen",
                effectiveGEDCOMPersonID: "@RB@",
                effectiveGEDCOMName: "Richard Breen"))
        }
    }

    @Test func formalProfileNameWinsOverItsBroaderAlias() {
        let formalNames = GedcomFamilyGraph(gedcomText: """
        0 @RB@ INDI
        1 NAME Richard /Breen/
        1 BIRT
        2 DATE 1959
        0 @RJ@ INDI
        1 NAME Richard /Jones/
        1 BIRT
        2 DATE 1960
        0 TRLR
        """)
        let profile = ArchivistGraphProfileSnapshot(
            stableID: "richard-breen", canonicalName: "Richard Breen",
            aliases: ["Richard"])

        let result = execute(
            people: ["Richard"], operation: .birth,
            graph: formalNames, profiles: [profile])

        #expect(result.conclusion == .answered)
        #expect(result.evidence?.subjectID == "@RB@")
        #expect(result.evidence?.identityBridge
                == ArchivistGraphEvidence.IdentityBridge(
            requestedName: "Richard",
            profileCanonicalName: "Richard Breen",
            effectiveGEDCOMPersonID: "@RB@",
            effectiveGEDCOMName: "Richard Breen"))
        #expect(result.basisLine
                == "Basis: People profile identity bridge “Richard” "
                    + "→ “Richard Breen” → GEDCOM “Richard Breen”; "
                    + "family facts from imported family tree (GEDCOM).")
    }

    @Test func canonicalPOINameRetainsBridgeWhenAliasResolvesGEDCOM() {
        let formalNames = GedcomFamilyGraph(gedcomText: """
        0 @RB@ INDI
        1 NAME Richard /Breen/
        1 BIRT
        2 DATE 1959
        0 TRLR
        """)
        let profile = ArchivistGraphProfileSnapshot(
            stableID: "rick-breen", canonicalName: "Rick Breen",
            aliases: ["Richard Breen"])

        let result = execute(
            people: ["Rick Breen"], operation: .birth,
            graph: formalNames, profiles: [profile])

        #expect(result.conclusion == .answered)
        #expect(result.evidence?.subjectID == "@RB@")
        #expect(result.evidence?.birthDate == "1959")
        #expect(result.evidence?.identityBridge
                == ArchivistGraphEvidence.IdentityBridge(
            requestedName: "Rick Breen",
            profileCanonicalName: "Rick Breen",
            effectiveGEDCOMPersonID: "@RB@",
            effectiveGEDCOMName: "Richard Breen"))
        #expect(result.basisLine
                == "Basis: People profile identity bridge “Rick Breen” "
                    + "→ “Rick Breen” → GEDCOM “Richard Breen”; "
                    + "family facts from imported family tree (GEDCOM).")
    }

    @Test func mostSpecificFallbackAliasWinsBeforeBroadAlias() {
        let formalNames = GedcomFamilyGraph(gedcomText: """
        0 @RB@ INDI
        1 NAME Richard /Breen/
        1 BIRT
        2 DATE 1959
        0 @RJ@ INDI
        1 NAME Richard /Jones/
        1 BIRT
        2 DATE 1960
        0 TRLR
        """)
        let profile = ArchivistGraphProfileSnapshot(
            stableID: "rick-breen", canonicalName: "Rick Breen",
            aliases: ["Rick", "Richard", "Richard Breen"])

        let result = execute(
            people: ["Rick"], operation: .birth,
            graph: formalNames, profiles: [profile])

        #expect(result.conclusion == .answered)
        #expect(result.evidence?.subjectID == "@RB@")
        #expect(result.evidence?.identityBridge
                == ArchivistGraphEvidence.IdentityBridge(
            requestedName: "Rick",
            profileCanonicalName: "Rick Breen",
            effectiveGEDCOMPersonID: "@RB@",
            effectiveGEDCOMName: "Richard Breen"))
        #expect(result.basisLine
                == "Basis: People profile identity bridge “Rick” "
                    + "→ “Rick Breen” → GEDCOM “Richard Breen”; "
                    + "family facts from imported family tree (GEDCOM).")
    }

    @Test func conflictingAliasesInStrongestTierAreUnionedAndSurfaced() {
        let formalNames = GedcomFamilyGraph(gedcomText: """
        0 @RB@ INDI
        1 NAME Richard /Breen/
        0 @RJ@ INDI
        1 NAME Robert /Jones/
        0 TRLR
        """)
        let profile = ArchivistGraphProfileSnapshot(
            stableID: "rick", canonicalName: "Rick Family",
            aliases: ["Rick", "Richard Breen", "Robert Jones", "Richard"])

        let result = execute(
            people: ["Rick"], operation: .biography,
            graph: formalNames, profiles: [profile])

        #expect(result.conclusion == .personAmbiguous)
        #expect(result.evidence == nil)
        #expect(
            result.candidates.map(\.id) == ["@RB@", "@RJ@"])
    }

    @Test func conflictingDuplicateStableIDsFailClosedRegardlessOfInputOrder() {
        let first = ArchivistGraphProfileSnapshot(
            stableID: "rick", canonicalName: "Chris River", aliases: ["Rick"])
        let conflicting = ArchivistGraphProfileSnapshot(
            stableID: "rick", canonicalName: "Alex River Sr", aliases: ["Rick"])

        let forward = execute(
            people: ["Rick"], operation: .biography,
            profiles: [first, conflicting])
        let reversed = execute(
            people: ["Rick"], operation: .biography,
            profiles: [conflicting, first])

        #expect(forward == reversed)
        #expect(forward.conclusion == .conflictingProfileStableID("rick"))
        #expect(forward.evidence == nil)
        #expect(forward.profileCandidates.isEmpty)
        #expect(forward.basisLine
                == "Checked: People profiles; the family tree was not consulted.")
    }

    @Test func unrelatedConflictingStableIDDoesNotBlockAnotherIdentity() {
        let unrelatedFirst = ArchivistGraphProfileSnapshot(
            stableID: "damaged", canonicalName: "Unrelated Person",
            aliases: ["Unrelated alias"])
        let unrelatedConflict = ArchivistGraphProfileSnapshot(
            stableID: "damaged", canonicalName: "Different Person",
            aliases: ["Different alias"])

        let result = execute(
            people: ["Chris River"], operation: .birth,
            profiles: [unrelatedFirst, unrelatedConflict])

        #expect(result.conclusion == .answered)
        #expect(result.evidence?.subjectID == "@I3@")
        #expect(result.evidence?.birthDate == "3 MAR 1930")
    }

    @Test func semanticallyIdenticalDuplicateStableIDsCollapse() {
        let first = ArchivistGraphProfileSnapshot(
            stableID: "chris", canonicalName: "Chris River",
            aliases: ["Chris", "River son", "Ríver child"])
        let reorderedCaseVaried = ArchivistGraphProfileSnapshot(
            stableID: "chris", canonicalName: " CHRIS RÍVER ",
            aliases: [
                "river CHILD", "RIVER SON", "chris", "Chris",
                // A canonical-name spelling in aliases adds no identity
                // meaning and must not create a false stable-ID conflict.
                "chris river",
            ])

        let forward = execute(
            people: ["River son"], operation: .birth,
            profiles: [first, reorderedCaseVaried])
        let reversed = execute(
            people: ["River son"], operation: .birth,
            profiles: [reorderedCaseVaried, first])

        #expect(forward == reversed)
        #expect(forward.conclusion == .answered)
        #expect(forward.evidence?.subjectID == "@I3@")
        #expect(forward.profileCandidates.isEmpty)
    }

    @Test func sharedProfileAliasIsAmbiguousAndDeterministicallyOrdered() {
        let profiles = [
            ArchivistGraphProfileSnapshot(
                stableID: "matt", canonicalName: "Matthew Breen",
                aliases: ["birthday boy"]),
            ArchivistGraphProfileSnapshot(
                stableID: "dan", canonicalName: "Daniel Breen",
                aliases: ["Birthday Boy"]),
            // Repeated storage rows for one stable identity must not create
            // a false ambiguity.
            ArchivistGraphProfileSnapshot(
                stableID: "dan", canonicalName: "Daniel Breen",
                aliases: ["Birthday Boy"]),
        ]

        let result = execute(
            people: ["BIRTHDAY BOY"], operation: .biography,
            profiles: profiles)

        #expect(result.conclusion == .profileAmbiguous)
        #expect(result.profileCandidates == ["Daniel Breen", "Matthew Breen"])
        #expect(result.candidates.isEmpty)
        #expect(result.evidence == nil)
        #expect(result.catalogPersonName == nil)
        #expect(result.basisLine == "Checked: People profiles.")
    }

    @Test func repeatedGedcomNamesReturnStableIDAwareCandidates() {
        let repeated = GedcomFamilyGraph(gedcomText: """
        0 @I20@ INDI
        1 NAME Alex /River/
        1 BIRT
        2 DATE 1955
        0 @I10@ INDI
        1 NAME Alex /River/
        1 BIRT
        2 DATE 1901
        1 DEAT
        2 DATE 1980
        0 TRLR
        """)

        let result = execute(
            people: ["Alex River"], operation: .biography, graph: repeated)

        #expect(result.conclusion == .personAmbiguous)
        #expect(result.evidence == nil)
        #expect(result.candidates.map(\.id) == ["@I10@", "@I20@"])
        #expect(result.candidates.map(\.label) == [
            "Alex River (b. 1901, d. 1980)",
            "Alex River (b. 1955)",
        ])
    }

    @Test func missingPersonAndMissingFactsRemainDistinguishable() {
        let unknown = execute(people: ["Nobody Here"], operation: .biography)
        #expect(unknown.conclusion == .personNotFound)
        #expect(unknown.basisLine == ArchivistBiographyPolicy.gedcomCheck)
        #expect(unknown.evidence == nil)

        let emptyBiography = execute(people: ["Casey Solo"], operation: .biography)
        #expect(emptyBiography.conclusion == .missingFact)
        #expect(emptyBiography.evidence?.subjectID == "@I8@")

        let missingDeath = execute(people: ["Chris River"], operation: .death)
        #expect(missingDeath.conclusion == .missingFact)
        #expect(missingDeath.evidence?.subjectID == "@I3@")
        #expect(missingDeath.evidence?.deathDate == nil)

        let missingRelation = execute(
            people: ["Casey Solo"], operation: .kinship, relation: .parents)
        #expect(missingRelation.conclusion == .missingFact)
        #expect(missingRelation.evidence?.relationships == [
            .init(relation: .parents, people: []),
        ])
    }

    @Test func malformedGraphQueriesFailClosedBeforeIdentityResolution() {
        let validationBasis =
            "Checked: graph-query validation only; no family source was consulted."

        let noRelation = execute(people: ["Chris River"], operation: .kinship)
        #expect(noRelation.conclusion == .missingRelation)
        #expect(noRelation.basisLine == validationBasis)
        #expect(noRelation.evidence == nil)

        let unexpectedRelation = execute(
            people: ["Chris River"], operation: .birth, relation: .father)
        #expect(unexpectedRelation.conclusion == .unexpectedRelation)
        #expect(unexpectedRelation.basisLine == validationBasis)
        #expect(unexpectedRelation.evidence == nil)

        let blank = execute(people: [" \n\t "], operation: .biography)
        #expect(blank.conclusion == .invalidPerson)
        #expect(blank.basisLine == validationBasis)
        #expect(blank.evidence == nil)

        let none = execute(people: [], operation: .biography)
        #expect(none.conclusion == .unsupportedPeopleCount(0))
        #expect(none.basisLine == validationBasis)
        #expect(none.evidence == nil)

        let multiple = execute(
            people: ["Chris River", "Casey Solo"], operation: .biography)
        #expect(multiple.conclusion == .unsupportedPeopleCount(2))
        #expect(multiple.basisLine == validationBasis)
        #expect(multiple.evidence == nil)
    }

    @Test func productionASTBridgeCopiesTheClosedGraphWirePayload() {
        let payload = ArchivistQueryAST.Graph(
            people: ["Chris River"], operation: .kinship,
            relation: .father)
        let query = ArchivistGraphQuery(payload)

        #expect(query == .init(
            people: ["Chris River"], operation: .kinship,
            relation: .father))
        let result = ArchivistGraphExecutor.execute(
            query, inputs: .init(graph: graph))
        #expect(result.conclusion == .answered)
        #expect(result.evidence?.relationships.first?.relation == .father)
        #expect(result.evidence?.relationships.first?.people.map(\.id)
                == ["@I1@"])
    }

    @Test("100k profile resolution stays bounded off the main actor",
          .timeLimit(.minutes(1)))
    func profileResolutionScaleSensor() async {
        var profiles: [ArchivistGraphProfileSnapshot] = []
        profiles.reserveCapacity(100_000)
        for index in 0..<99_999 {
            profiles.append(.init(
                stableID: "person-\(index)",
                canonicalName: "Synthetic Person \(index)",
                aliases: ["Synthetic Alias \(index)"]))
        }
        profiles.append(.init(
            stableID: "rick", canonicalName: "Chris River",
            aliases: ["Target Alias"]))
        let inputs = ArchivistGraphInputs(graph: graph, profiles: profiles)
        let query = ArchivistGraphQuery(
            people: ["target alias"], operation: .birth)

        let started = ContinuousClock.now
        let result = await Task.detached {
            ArchivistGraphExecutor.execute(query, inputs: inputs)
        }.value
        let elapsed = started.duration(to: .now)

        #expect(result.conclusion == .answered)
        #expect(result.evidence?.subjectID == "@I3@")
        #expect(elapsed < .seconds(5),
                "100k injected profiles exceeded the 5 s execution budget: \(elapsed)")
    }

    /// Component-boundary sensor: family evidence is accepted and returned
    /// only as deterministic values. Adding a translator dependency or call
    /// to this production component intentionally breaks this test for review.
    @Test func executorSourceHasNoTranslatorDependencyOrCall() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("VideoScan/ArchivistGraphExecutor.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(!source.contains("NLQueryTranslating"))
        #expect(!source.contains("OllamaQueryTranslator"))
        #expect(!source.contains(".translate("))
    }

    /// Production bridge sensor: POIProfile is UI/persistence state; only its
    /// stable identity spellings may enter detached graph execution.
    @Test func productionPOIProfileSnapshotBridgeCopiesOnlyIdentity() {
        let profile = POIProfile(
            name: "Renée Dubois", referencePath: "/private/family/photos",
            rejectedFiles: ["private-rejection.jpg"],
            notes: "private family note", aliases: ["Renee", "Aunt Renée"],
            identityNotes: "private appearance note")

        let snapshot = ArchivistGraphProfileSnapshot(profile: profile)
        let inputs = ArchivistGraphInputs(graph: graph, profiles: [profile])

        #expect(snapshot == .init(
            stableID: profile.id, canonicalName: "Renée Dubois",
            aliases: ["Renee", "Aunt Renée"]))
        #expect(inputs.profiles == [snapshot])
        #expect(Mirror(reflecting: snapshot).children.compactMap(\.label)
                == ["stableID", "canonicalName", "aliases"])
        #expect(!String(reflecting: snapshot).contains(profile.referencePath))
        #expect(!String(reflecting: snapshot).contains(profile.notes))
        #expect(!String(reflecting: snapshot).contains(profile.identityNotes!))
    }
}
