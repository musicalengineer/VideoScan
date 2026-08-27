import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

/// The chat window's side of a told pronunciation: whose name the word is
/// decides where it is written; the reply confirms; a telling session in
/// progress rides through untouched.
@MainActor
@Suite("Hallie pronunciation route", .serialized)
struct HalliePronunciationCoordinatorTests {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [HallieAppTurnCoordinator.PronunciationWrite] = []
        var failWith: String?
        func append(_ value: HallieAppTurnCoordinator.PronunciationWrite) { lock.withLock { storage.append(value) } }
        var writes: [HallieAppTurnCoordinator.PronunciationWrite] { lock.withLock { storage } }
    }

    private let graph = GedcomFamilyGraph(gedcomText: """
    0 HEAD
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
    """)

    private func brain() throws -> CyberBrainIndex {
        try CyberBrainIndex(archive: CyberBrainArchive(
            archiveID: "family", displayName: "Family",
            people: [CyberBrainPerson(id: "person.nathaniel", canonicalName: "Nathaniel McGill", aliases: ["Nate"])],
            sources: []))
    }

    private func dependencies(_ recorder: Recorder, brain: CyberBrainIndex?) -> HallieAppTurnCoordinator.Dependencies {
        HallieAppTurnCoordinator.Dependencies(
            startLocalBrain: { $0 },
            translateAST: { _, _, _ in
                Issue.record("translation must not run for a pronunciation")
                throw NLTranslatorError.unreachable("fixture")
            },
            loadProfiles: { nil },
            loadGraph: { [graph] in graph },
            loadCyberBrain: { brain },
            recordPronunciation: { write in
                if let failWith = recorder.failWith { throw CyberBrainWriter.WriteError.ioFailure(failWith) }
                recorder.append(write)
            },
            executeRequest: { _, _ in
                Issue.record("no catalog query for a pronunciation")
                throw NLTranslatorError.unreachable("fixture")
            },
            continueTurn: { _, _, _ in throw NLTranslatorError.unreachable("fixture") },
            resolveBiographyPhoto: { _ in nil })
    }

    private func run(_ question: String, recorder: Recorder, brain: CyberBrainIndex?,
                     telling: HallieTellingMode.Session? = nil) async throws -> HallieAppTurnCoordinator.Response {
        try await HallieAppTurnCoordinator.execute(
            question: question, records: [],
            referent: .init(recordID: nil, temporalDate: nil),
            hosts: ["fixture.invalid"], modelName: "fixture-model",
            telling: telling,
            dependencies: dependencies(recorder, brain: brain))
    }

    @Test func aCyberBrainNameWritesToThatPerson() async throws {
        let recorder = Recorder()
        let response = try await run("Nathaniel is pronounced nah-thahn-yul", recorder: recorder, brain: try brain())
        #expect(recorder.writes == [.init(word: "Nathaniel", saidAs: "nah-thahn-yul",
                                          target: .cyberBrainPerson(id: "person.nathaniel", name: "Nathaniel McGill"))])
        #expect(response.result.prose == "Got it — I'll say Nathaniel as nah-thahn-yul from now on. I've kept that with Nathaniel McGill.")
        #expect(response.result.route == .telling)
        #expect(response.responderHost == HallieAppTurnCoordinator.localResponder)
        #expect(response.executedIntent == nil)
    }

    @Test func aTreeOnlyNameMintsThatPersonAndASharedNameGoesToTheFile() async throws {
        let recorder = Recorder()
        _ = try await run("say Edith as EE-dith", recorder: recorder, brain: try brain())
        #expect(recorder.writes.last == .init(word: "Edith", saidAs: "EE-dith",
                                              target: .treePerson(name: "Edith Latta", gedcomID: "@I1@", aliases: [])))

        // McGill: one CyberBrain person AND two tree people carry it — the
        // brain's single carrier wins (his record, word applies everywhere).
        let withBrain = try await run("you're mispronouncing McGill, it's muh-GILL", recorder: recorder, brain: try brain())
        #expect(recorder.writes.last?.target == .cyberBrainPerson(id: "person.nathaniel", name: "Nathaniel McGill"))
        #expect(withBrain.result.prose.hasPrefix("Got it — I'll say McGill as muh-GILL from now on."))

        // Without a brain, two tree McGills → nobody's record: the file.
        let noBrain = try await run("you're mispronouncing McGill, it's muh-GILL", recorder: recorder, brain: nil)
        #expect(recorder.writes.last == .init(word: "McGill", saidAs: "muh-GILL", target: .file))
        #expect(noBrain.result.prose.contains("pronunciation list"))
    }

    @Test func aFailedWriteIsSaidHonestlyAndATellingSessionRidesThrough() async throws {
        let recorder = Recorder()
        recorder.failWith = "read-only volume"
        var session = HallieTellingMode.Session(opening: .init(subject: "Dad Breen", relation: nil, pronoun: .he, firstStatement: nil))
        session.passages = ["He fixed typewriters."]
        session.persistedCount = 1
        let response = try await run("Nathaniel is pronounced nuh-THAN-yul", recorder: recorder, brain: try brain(), telling: session)
        #expect(recorder.writes.isEmpty)
        #expect(response.result.prose.contains("read-only volume"))
        #expect(response.result.prose.contains("won't stick"))
        #expect(response.telling == session)
    }

    @Test func targetResolutionPrefersOneBrainCarrierThenOneTreeCarrierThenTheFile() throws {
        typealias C = HallieAppTurnCoordinator
        #expect(C.resolvePronunciationTarget(word: "nate", cyberBrain: try brain(), graph: graph)
                == .cyberBrainPerson(id: "person.nathaniel", name: "Nathaniel McGill"))
        #expect(C.resolvePronunciationTarget(word: "Latta", cyberBrain: try brain(), graph: graph)
                == .treePerson(name: "Edith Latta", gedcomID: "@I1@", aliases: []))
        #expect(C.resolvePronunciationTarget(word: "Bethiah", cyberBrain: try brain(), graph: graph) == .file)
        #expect(C.resolvePronunciationTarget(word: "McGill", cyberBrain: nil, graph: graph) == .file)
        #expect(C.resolvePronunciationTarget(word: "", cyberBrain: try brain(), graph: graph) == .file)
    }
}
