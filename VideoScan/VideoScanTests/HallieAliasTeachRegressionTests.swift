import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

/// GH #184 item 6 (live 2026-09-11 22:11Z). Rick typed
///   "when you see KY as a location in caps, it is OK, and recommended to
///    pornounce it "Kentucky""
/// and the free-form pronunciation route resolved the word "see" to Adam
/// FitzHerbert of Llanllowell through his notes-style tree alias
/// "Llanlowell Llan Hywel and see note", then minted a CyberBrain person
/// carrying {"see": "KY | OK"}. These pin the fix at every layer the
/// sentence crosses: the resolver, the teach, the shell, and the reply.
@MainActor
@Suite("Hallie alias teach regression (GH #184 item 6)", .serialized)
struct HallieAliasTeachRegressionTests {
    static let liveSentence = "when you see KY as a location in caps, it is OK, and recommended to pornounce it \"Kentucky\""

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [HallieAppTurnCoordinator.PronunciationWrite] = []
        func append(_ value: HallieAppTurnCoordinator.PronunciationWrite) { lock.withLock { storage.append(value) } }
        var writes: [HallieAppTurnCoordinator.PronunciationWrite] { lock.withLock { storage } }
    }

    /// The real alias shape (GEDCOM @IB23862@) beside the ordinary
    /// fixture people.
    private static let tree = """
    0 HEAD
    0 @IB23862@ INDI
    1 NAME Adam FitzHerbert of Llanllowell
    1 NAME Llanlowell Llan Hywel and see note
    1 SEX M
    0 @I1@ INDI
    1 NAME Edith /Latta/
    1 SEX F
    0 @I2@ INDI
    1 NAME Patrick /McGill/
    1 SEX M
    0 @I3@ INDI
    1 NAME Ann /McGill/
    1 SEX F
    0 TRLR
    """
    private let graph = GedcomFamilyGraph(gedcomText: tree)

    private func brain() throws -> CyberBrainIndex {
        try CyberBrainIndex(archive: CyberBrainArchive(
            archiveID: "family", displayName: "Family",
            people: [CyberBrainPerson(id: "person.nathaniel", canonicalName: "Nathaniel McGill", aliases: ["Nate"])],
            sources: []))
    }

    private func dependencies(_ recorder: Recorder) throws -> HallieAppTurnCoordinator.Dependencies {
        let brain = try brain()
        return HallieAppTurnCoordinator.Dependencies(
            startLocalBrain: { $0 },
            translateAST: { _, _, _ in
                Issue.record("translation must not run for a pronunciation teach")
                throw NLTranslatorError.unreachable("fixture")
            },
            loadProfiles: { nil },
            loadGraph: { [graph] in graph },
            loadCyberBrain: { brain },
            recordPronunciation: { recorder.append($0) },
            saveDrillStore: { _, _ in },
            executeRequest: { _, _ in
                Issue.record("no catalog query for a pronunciation teach")
                throw NLTranslatorError.unreachable("fixture")
            },
            continueTurn: { _, _, _ in throw NLTranslatorError.unreachable("fixture") },
            resolveBiographyPhoto: { _ in nil })
    }

    private func run(_ question: String, recorder: Recorder,
                     telling: HallieTellingMode.Session? = nil) async throws -> HallieAppTurnCoordinator.Response {
        try await HallieAppTurnCoordinator.execute(
            question: question, records: [],
            referent: .init(recordID: nil, temporalDate: nil),
            hosts: ["fixture.invalid"], modelName: "fixture-model",
            telling: telling,
            dependencies: dependencies(recorder))
    }

    @Test func theFixtureCarriesTheRealGarbageAlias() throws {
        let adam = try #require(graph.people["@IB23862@"])
        #expect(adam.name == "Adam FitzHerbert of Llanllowell")
        #expect(adam.alternateNames == ["Llanlowell Llan Hywel and see note"])
    }

    @Test func theLiveSentenceCreatesNothingAndDeclines() async throws {
        let recorder = Recorder()
        let response = try await run(Self.liveSentence, recorder: recorder)
        #expect(response.result.route == .telling)
        #expect(response.result.outcome == .declined)
        #expect(response.result.prose == "I keep pronunciations for people — who is this for?")
        #expect(response.result.basisLine.contains("NOT kept"))
        #expect(recorder.writes.isEmpty)
        #expect(!response.result.prose.contains("FitzHerbert"))
        #expect(!response.result.prose.contains("noted"))
    }

    @Test func seeAloneNeverResolvesToAdamFitzHerbert() throws {
        typealias C = HallieAppTurnCoordinator
        let brain = try brain()
        for word in ["see", "See", "and", "note", "Hywel"] {
            #expect(C.resolvePronunciationTarget(word: word, cyberBrain: brain, graph: graph) == .file,
                    Comment(rawValue: word))
            #expect(C.knownSpelling(word, dependencies: try dependencies(Recorder())) == nil,
                    Comment(rawValue: word))
        }
        // His real name still resolves to him.
        #expect(C.resolvePronunciationTarget(word: "FitzHerbert", cyberBrain: brain, graph: graph)
                == .treePerson(name: "Adam FitzHerbert of Llanllowell", gedcomID: "@IB23862@",
                               aliases: ["Llanlowell Llan Hywel and see note"]))
        #expect(C.knownSpelling("fitzherbert", dependencies: try dependencies(Recorder())) == "FitzHerbert")
        // Neither does "KY", "OK" or "Kentucky" belong to anyone.
        for word in ["KY", "OK", "Kentucky"] {
            #expect(C.knownSpelling(word, dependencies: try dependencies(Recorder())) == nil, Comment(rawValue: word))
        }
    }

    @Test func aLegitimateTeachStillWorks() async throws {
        let recorder = Recorder()
        // McGill: one CyberBrain carrier (Nathaniel McGill) outranks the
        // two tree McGills, as before.
        let shared = try await run("pronounce McGill as muh-GILL", recorder: recorder)
        #expect(shared.result.outcome == .answered)
        #expect(shared.result.prose.hasPrefix("OK, noted — McGill."))
        #expect(recorder.writes.last?.word == "McGill")
        #expect(recorder.writes.last?.saidAs == "muh-GILL")
        #expect(recorder.writes.last?.target == .cyberBrainPerson(id: "person.nathaniel", name: "Nathaniel McGill"))
        // Shared by two tree people and nobody in the brain → the file.
        #expect(HallieAppTurnCoordinator.resolvePronunciationTarget(word: "McGill", cyberBrain: nil, graph: graph) == .file)
        // One tree person → minted on her record, as before.
        let edith = try await run("say Edith as EE-dith", recorder: recorder)
        #expect(edith.result.outcome == .answered)
        #expect(recorder.writes.last?.target == .treePerson(name: "Edith Latta", gedcomID: "@I1@", aliases: []))
        // One CyberBrain alias → that person, as before.
        let nate = try await run("Nate is pronounced NAYT", recorder: recorder)
        #expect(nate.result.outcome == .answered)
        #expect(recorder.writes.last?.target == .cyberBrainPerson(id: "person.nathaniel", name: "Nathaniel McGill"))
        #expect(recorder.writes.count == 3)
    }

    @Test func aStrictTeachOfAWordNobodyCarriesIsDeclinedNotFiled() async throws {
        let recorder = Recorder()
        for sentence in ["pronounce KY as Kentucky", "Zzyzx is pronounced ZY-zix", "say Berkshires as BURK-sheers"] {
            let response = try await run(sentence, recorder: recorder)
            #expect(response.result.outcome == .declined, Comment(rawValue: sentence))
            #expect(response.result.prose == HallieAppTurnCoordinator.declinedTeachProse, Comment(rawValue: sentence))
        }
        #expect(recorder.writes.isEmpty)
    }

    @Test func insideAnInterviewNarrativeWithPronouncedIsNotHijacked() async throws {
        let recorder = Recorder()
        let session = HallieTellingMode.Session(opening: .init(subject: "Dad Breen", relation: nil, pronoun: .he, firstStatement: nil))
        let response = try await run("he pronounced every word carefully at the shop", recorder: recorder, telling: session)
        // Not the pronunciation decline: the telling route keeps the turn.
        #expect(response.result.prose != HallieAppTurnCoordinator.declinedTeachProse)
        #expect(recorder.writes.isEmpty)
    }

    // MARK: - Shell parity

    private final class ShellHarness: @unchecked Sendable {
        var inputs: [String]
        var output: [String] = []
        var recorded = 0
        init(_ inputs: [String]) { self.inputs = inputs }
        func next() -> String? { inputs.isEmpty ? nil : inputs.removeFirst() }
    }

    @Test func theShellDeclinesTheLiveSentenceAndWritesNothing() async {
        let harness = ShellHarness([Self.liveSentence, "pronounce KY as Kentucky"])
        let dependencies = HallieShellCLI.Dependencies(
            loadCatalog: { _ in [] },
            loadProfiles: { .loaded([]) },
            loadGraph: { [graph] _ in graph },
            translateAST: { _, _ in throw NLTranslatorError.unreachable("fixture") },
            executeTurn: { _, _ in throw NLTranslatorError.unreachable("fixture") },
            performMediaAction: { _ in },
            recordPronunciation: { _ in harness.recorded += 1 },
            saveDrillStore: { _, _ in },
            loadLexicon: { HalliePronunciationLexicon(entries: []) })
        var options = HallieShellCLI.Options()
        options.remember = true
        _ = await HallieShellCLI.run(
            options: options, input: harness.next,
            output: { harness.output.append($0) }, dependencies: dependencies)
        let text = harness.output.joined(separator: "\n")
        #expect(text.components(separatedBy: HallieAppTurnCoordinator.declinedTeachProse).count == 3, Comment(rawValue: text))
        #expect(!text.contains("FitzHerbert"))
        #expect(!text.contains("OK, noted"))
        #expect(harness.recorded == 0)
    }
}
