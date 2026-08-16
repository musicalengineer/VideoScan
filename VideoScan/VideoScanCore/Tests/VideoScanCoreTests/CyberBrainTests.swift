import Foundation
import Testing
@testable import VideoScanCore

struct CyberBrainTests {
    private static let instant = Date(timeIntervalSince1970: 1_700_000_000)

    private func source(id: String = "source.interview") -> CyberBrainSource {
        CyberBrainSource(
            id: id,
            type: .familyWitness,
            title: "Synthetic family interview",
            attribution: "Alex River",
            locator: "sources/interviews/alex.txt")
    }

    private func item(
        id: String = "item.biography",
        text: String = "Jordan restored radios and taught the craft to younger relatives.",
        confidence: CyberBrainItem.Confidence = .confirmed,
        privacy: CyberBrainItem.Privacy = .family,
        status: CyberBrainItem.Status = .active,
        supersedes: String? = nil,
        disputes: [String] = [],
        updatedAt: Date = Self.instant
    ) -> CyberBrainItem {
        CyberBrainItem(
            id: id,
            kind: .biography,
            text: text,
            subjectPersonIDs: ["person.jordan"],
            sourceIDs: ["source.interview"],
            confidence: confidence,
            privacy: privacy,
            status: status,
            supersedesItemID: supersedes,
            disputesItemIDs: disputes,
            createdAt: Self.instant,
            updatedAt: updatedAt)
    }

    private func archive(
        aliases: [String] = ["Jordy"],
        items: [CyberBrainItem]? = nil,
        sources: [CyberBrainSource]? = nil
    ) -> CyberBrainArchive {
        CyberBrainArchive(
            archiveID: "synthetic-family",
            displayName: "Synthetic Family CyberBrain",
            people: [
                CyberBrainPerson(
                    id: "person.jordan",
                    gedcomPersonID: "@I1@",
                    canonicalName: "Jordan River",
                    aliases: aliases,
                    biographyPassages: items ?? [item()]),
            ],
            sources: sources ?? [source()])
    }

    @Test func endToEndLoadIndexPlanComposeCarriesExactEvidence() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(archive(), to: root)

        let loaded = try CyberBrainLoader(rootURL: root).load()
        let index = try CyberBrainIndex(archive: loaded)
        let graph = GedcomFamilyGraph(gedcomText: """
        0 @I1@ INDI
        1 NAME Jordan /River/
        1 BIRT
        2 DATE ABT 1944
        0 TRLR
        """)
        let plan = CyberBrainBiographyPlanner.plan(
            personName: "Jordy", index: index, graph: graph,
            privacyCeiling: .private)
        let prose = CyberBrainDeterministicComposer.compose(plan)

        #expect(plan.answerState == .answered)
        #expect(plan.subject == "Jordan River")
        #expect(plan.claims.map(\.id)
                == ["gedcom:@I1@:birth", "item.biography"])
        #expect(plan.claims[0].text.contains("ABT 1944"))
        #expect(plan.claims[0].evidenceIDs == ["gedcom:@I1@"])
        #expect(plan.claims[1].evidenceIDs == ["source.interview"])
        #expect(plan.sourceCitations.map(\.id)
                == ["gedcom:@I1@", "source.interview"])
        #expect(Set(plan.claims.flatMap(\.evidenceIDs))
                == Set(plan.sourceCitations.map(\.id)))
        #expect(prose.contains("ABT 1944"))
        #expect(prose.contains("restored radios"))
        #expect(!prose.lowercased().contains("born in 1944"))
    }

    @Test func privacyRetractionAndSupersessionFailClosed() throws {
        let old = item(id: "item.old", text: "An obsolete account.",
                       status: .superseded)
        let replacement = item(id: "item.new", text: "A corrected account.",
                               privacy: .private, supersedes: "item.old",
                               updatedAt: Self.instant.addingTimeInterval(1))
        let retracted = item(id: "item.retracted", text: "A retracted claim.",
                             status: .retracted)
        let index = try CyberBrainIndex(archive: archive(
            items: [old, replacement, retracted]))

        let publicPlan = CyberBrainBiographyPlanner.plan(
            personName: "Jordan River", index: index,
            privacyCeiling: .public)
        #expect(publicPlan.answerState == .noEvidence)
        #expect(publicPlan.claims.isEmpty)

        let privatePlan = CyberBrainBiographyPlanner.plan(
            personName: "Jordan River", index: index,
            privacyCeiling: .private)
        #expect(privatePlan.claims.map(\.text) == ["A corrected account."])
        #expect(!privatePlan.claims.map(\.text).contains("An obsolete account."))
        #expect(!privatePlan.claims.map(\.text).contains("A retracted claim."))
    }

    @Test func ambiguousAliasNeverChoosesAnIdentity() throws {
        let second = CyberBrainPerson(
            id: "person.jordan.two", canonicalName: "Jordan Lake",
            aliases: ["Jordy"])
        let base = archive()
        let ambiguous = CyberBrainArchive(
            archiveID: base.archiveID, displayName: base.displayName,
            people: base.people + [second], sources: base.sources)
        let index = try CyberBrainIndex(archive: ambiguous)

        let plan = CyberBrainBiographyPlanner.plan(
            personName: "Jordy", index: index)
        #expect(plan.answerState == .ambiguous)
        #expect(plan.claims.isEmpty)
        #expect(plan.ambiguityCandidates.map(\.id)
                == ["person.jordan.two", "person.jordan"])
        #expect(plan.constraints.contains(.doNotChooseAmbiguousIdentity))
    }

    @Test func disputedAccountIsLabeledAndNeverResolvedByComposer() throws {
        let counter = item(id: "item.counter",
                           text: "One witness remembers the earlier year.")
        let disputed = item(
            text: "Another witness remembers a later year.",
            confidence: .disputed, disputes: ["item.counter"])
        let index = try CyberBrainIndex(
            archive: archive(items: [counter, disputed]))
        let plan = CyberBrainBiographyPlanner.plan(
            personName: "Jordan River", index: index,
            privacyCeiling: .family)
        let prose = CyberBrainDeterministicComposer.compose(plan)

        #expect(plan.answerState == .disputed)
        #expect(plan.uncertaintyStatements.contains(where: {
            $0.lowercased().contains("disputed")
        }))
        #expect(plan.constraints.contains(.doNotResolveDispute))
        #expect(prose.lowercased().contains("disputed"))
    }

    @Test func gedcomFactsArePrivateAndNeverCrossLowerPrivacyCeilings() throws {
        let index = try CyberBrainIndex(archive: archive(items: []))
        let graph = GedcomFamilyGraph(gedcomText: """
        0 @I1@ INDI
        1 NAME Jordan /River/
        1 BIRT
        2 DATE 4 MAR 1944
        0 TRLR
        """)

        for ceiling in [CyberBrainItem.Privacy.public, .family] {
            let plan = CyberBrainBiographyPlanner.plan(
                personName: "Jordan", index: index, graph: graph,
                privacyCeiling: ceiling)
            #expect(plan.answerState == .noEvidence)
            #expect(plan.claims.isEmpty)
            #expect(plan.sourceCitations.isEmpty)
            #expect(plan.uncertaintyStatements.contains(where: {
                $0.contains("privacy ceiling")
            }))
        }

        let privatePlan = CyberBrainBiographyPlanner.plan(
            personName: "Jordan", index: index, graph: graph,
            privacyCeiling: .private)
        #expect(privatePlan.answerState == .answered)
        #expect(privatePlan.claims.map(\.text).contains(where: {
            $0.contains("4 MAR 1944")
        }))
    }

    @Test func disputeBeyondClaimLimitStillControlsStateAndIsCited() throws {
        let confirmed = item(id: "item.00", text: "A confirmed account.")
        let disputed = item(
            id: "item.99", text: "A disputed account.",
            confidence: .disputed, disputes: ["item.00"])
        let index = try CyberBrainIndex(
            archive: archive(items: [confirmed, disputed]))
        let plan = CyberBrainBiographyPlanner.plan(
            personName: "Jordan", index: index,
            privacyCeiling: .family, itemLimit: 1)

        #expect(plan.answerState == .disputed)
        #expect(plan.claims.map(\.id) == ["item.00", "item.99"])
        #expect(plan.sourceCitations.map(\.id) == ["source.interview"])
        #expect(plan.constraints.contains(.doNotResolveDispute))
    }

    @Test func graphOnlyPersonFallsBackWithoutRequiringCyberBrainEntry() throws {
        let index = try CyberBrainIndex(archive: archive())
        let graph = GedcomFamilyGraph(gedcomText: """
        0 @I9@ INDI
        1 NAME Ellen /Stone/
        1 BIRT
        2 DATE ABT 1930
        0 TRLR
        """)
        let plan = CyberBrainBiographyPlanner.plan(
            personName: "Ellen", index: index, graph: graph,
            privacyCeiling: .private)

        #expect(plan.answerState == .answered)
        #expect(plan.subject == "Ellen Stone")
        #expect(plan.claims.map(\.id) == ["gedcom:@I9@:birth"])
        #expect(plan.sourceCitations.map(\.id) == ["gedcom:@I9@"])
    }

    @Test func sharedTokenIdentityPolicySupportsUnambiguousPartialName() throws {
        let index = try CyberBrainIndex(archive: archive())
        guard case .resolved(let person) = index.resolve("Jordan") else {
            Issue.record("Expected token-subset identity resolution")
            return
        }
        #expect(person.id == "person.jordan")
    }

    @Test func validatorRejectsDanglingAndTraversalReferences() {
        let missingSource = archive(sources: [])
        #expect(throws: CyberBrainError.danglingReference("source.interview")) {
            try CyberBrainValidator.validate(missingSource)
        }

        let unsafe = archive(sources: [CyberBrainSource(
            id: "source.interview", type: .curatedBiography,
            title: "Unsafe", locator: "../outside.txt")])
        #expect(throws: CyberBrainError.unsafePath("../outside.txt")) {
            try CyberBrainValidator.validate(unsafe)
        }
    }

    @Test func loaderRejectsUnknownFieldsAndUnsupportedSchema() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var data = try encoded(archive())
        var object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["privacyDefault"] = "public"
        data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: root.appendingPathComponent("cyberbrain.json"))
        #expect(throws: CyberBrainError.self) {
            try CyberBrainLoader(rootURL: root).load()
        }

        let unsupported = CyberBrainArchive(
            schemaVersion: 99, archiveID: "future", displayName: "Future",
            people: [], sources: [])
        try write(unsupported, to: root)
        #expect(throws: CyberBrainError.unsupportedSchema(99)) {
            try CyberBrainLoader(rootURL: root).load()
        }
    }

    @Test func loaderRejectsSymlinkAndOversizedInputWithoutReadingFamilyState() throws {
        let parent = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("isolated", isDirectory: true)
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: false)
        let outside = parent.appendingPathComponent("outside.json")
        try encoded(archive()).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("cyberbrain.json"),
            withDestinationURL: outside)
        #expect(throws: CyberBrainError.self) {
            try CyberBrainLoader(rootURL: root).load()
        }

        try FileManager.default.removeItem(
            at: root.appendingPathComponent("cyberbrain.json"))
        try Data(repeating: 0x20, count: 1_025).write(
            to: root.appendingPathComponent("cyberbrain.json"))
        #expect(throws: CyberBrainError.oversizedFile(1_025)) {
            try CyberBrainLoader(rootURL: root, maximumBytes: 1_024).load()
        }
    }

    @Test func oneItemCorrectionChangesGenerationAndRemovesOldClaim() throws {
        let first = try CyberBrainIndex(archive: archive())
        let corrected = item(text: "Jordan repaired radios and documented each restoration.",
                             updatedAt: Self.instant.addingTimeInterval(60))
        let second = try CyberBrainIndex(archive: archive(items: [corrected]))
        let plan = CyberBrainBiographyPlanner.plan(
            personName: "Jordan River", index: second,
            privacyCeiling: .family)

        #expect(first.generation != second.generation)
        #expect(plan.claims.map(\.text).contains(corrected.text))
        #expect(!plan.claims.map(\.text).contains(item().text))
    }

    @Test func anyPersistedReferenceOrSourceChangeInvalidatesGeneration() throws {
        let first = try CyberBrainIndex(archive: archive())
        let changedSource = CyberBrainSource(
            id: "source.interview", type: .familyWitness,
            title: "Synthetic family interview", attribution: "Alex River",
            locator: "sources/interviews/alex.txt",
            notes: "Corrected transcription notes")
        let second = try CyberBrainIndex(archive: archive(sources: [changedSource]))

        #expect(first.generation != second.generation)
    }

    @Test func answerPlanRoundTripsForFutureRedactedRendererBoundary() throws {
        let index = try CyberBrainIndex(archive: archive())
        let plan = CyberBrainBiographyPlanner.plan(
            personName: "Jordy", index: index, privacyCeiling: .family)
        let data = try JSONEncoder().encode(plan)
        let decoded = try JSONDecoder().decode(
            CyberBrainAnswerPlan.self, from: data)
        #expect(decoded == plan)
    }

    @Test func supersessionCyclesAndUnlinkedDisputesAreRejected() {
        let first = item(id: "item.first", supersedes: "item.second")
        let second = item(id: "item.second", supersedes: "item.first")
        #expect(throws: CyberBrainError.self) {
            try CyberBrainValidator.validate(
                archive(items: [first, second]))
        }

        let unsupported = item(
            id: "item.disputed", confidence: .disputed)
        #expect(throws: CyberBrainError.self) {
            try CyberBrainValidator.validate(
                archive(items: [unsupported]))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func hundredThousandPeopleIndexAndLookupStayWithinExplicitBudget() throws {
        var people: [CyberBrainPerson] = []
        people.reserveCapacity(100_000)
        for index in 0..<100_000 {
            people.append(CyberBrainPerson(
                id: "person.\(index)",
                canonicalName: index == 99_999
                    ? "Needle Archivist" : "Synthetic Person \(index)"))
        }
        let large = CyberBrainArchive(
            archiveID: "scale", displayName: "Scale Fixture",
            people: people, sources: [])

        let started = ContinuousClock.now
        let index = try CyberBrainIndex(archive: large)
        let resolution = index.resolve("Needle Archivist")
        let elapsed = started.duration(to: .now)

        guard case .resolved(let person) = resolution else {
            Issue.record("Expected exact identity resolution")
            return
        }
        #expect(person.id == "person.99999")
        #expect(elapsed < .seconds(3),
                "100k CyberBrain index+lookup exceeded 3 seconds: \(elapsed)")
    }

    @Test(.timeLimit(.minutes(1)))
    func hundredThousandItemsIndexSortHashAndBoundedQueryStayWithinBudget() throws {
        var items: [CyberBrainItem] = []
        items.reserveCapacity(100_000)
        for index in 0..<100_000 {
            items.append(item(
                id: String(format: "item.%06d", index),
                text: "Synthetic evidence \(index)"))
        }
        let large = archive(items: items)

        let started = ContinuousClock.now
        let index = try CyberBrainIndex(archive: large)
        let evidence = index.evidence(
            for: "person.jordan", privacyCeiling: .family, limit: 12)
        let elapsed = started.duration(to: .now)

        #expect(evidence.count == 12)
        #expect(evidence.first?.id == "item.000000")
        #expect(elapsed < .seconds(3),
                "100k CyberBrain item index+query exceeded 3 seconds: \(elapsed)")
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cyberbrain-tests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: false)
        return root
    }

    private func encoded(_ archive: CyberBrainArchive) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(archive)
    }

    private func write(_ archive: CyberBrainArchive, to root: URL) throws {
        try encoded(archive).write(
            to: root.appendingPathComponent("cyberbrain.json"), options: .atomic)
    }
}
