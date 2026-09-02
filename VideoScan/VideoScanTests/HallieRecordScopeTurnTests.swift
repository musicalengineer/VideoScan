import Foundation
import Testing
@testable import VideoScan

/// The record ROUTE through the shared turn executor (2026-09-02): what a
/// resolved / ambiguous / missing / unselected record scope produces, the
/// chips, conversation memory, and the answer plan.
@MainActor
@Suite("Hallie record-scope turns", .serialized)
struct HallieRecordScopeTurnTests {
    private let recordID = UUID()
    private let path = "/Volumes/Archive/1994/New Hampshire.mov"

    private func snapshot(confirmed: [String] = ["Donna"]) -> ArchivistRecordDossierSnapshot {
        ArchivistRecordDossierSnapshot(
            presence: ArchivistPresenceRecordSnapshot(
                id: recordID, fullPath: path,
                confirmedPeople: confirmed.map { ConfirmedTag(name: $0, confirmedAt: Date(timeIntervalSince1970: 1)) }),
            container: "mov", videoCodec: "h264", audioCodec: "aac")
    }

    private func ast(
        _ reference: ArchivistQueryAST.Record.Reference = .currentSelection,
        _ operations: [ArchivistQueryAST.Record.Operation] = [.people],
        people: [String]? = nil
    ) -> ArchivistQueryAST {
        .record(.init(reference: reference, operations: operations, people: people))
    }

    @Test func resolvedScopeAnswersFromTheRecordWithOneCitation() async throws {
        let context = HallieTurnExecutor.Context(
            recordScope: .resolved(snapshot()),
            speakers: .init(ownerName: "Rick Breen", archivistName: "Hallie"))
        let result = try await HallieTurnExecutor.execute(ast(), context: context)
        #expect(result.route == .record)
        #expect(result.outcome == .answered)
        #expect(result.prose == "In New Hampshire.mov, Donna is tagged (confirmed by a person).")
        #expect(result.citations.map(\.recordID) == [recordID])
        #expect(result.offeredActions.count == 2)
        // The owner binding reaches the executor through the context.
        let me = try await HallieTurnExecutor.execute(ast(.currentSelection, [.people], people: ["me"]), context: context)
        #expect(me.prose == "In New Hampshire.mov, nothing for Rick Breen — not tagged, not detected, and there is no transcript to check.")
    }

    @Test func nothingSelectedAsksForASelectionOrAFileName() async throws {
        let result = try await HallieTurnExecutor.execute(ast(), context: .init())
        #expect(result.route == .record)
        #expect(result.outcome == .declined)
        #expect(result.prose == "Which video? Select one in the Catalog, or name the file, and ask me again.")
        #expect(result.queryDescription == "shape=record reference=selection noSelection")
        #expect(result.citations.isEmpty)
    }

    @Test func aNamedFileTheClientNeverResolvedIsNotFoundNotUnselected() async throws {
        let result = try await HallieTurnExecutor.execute(ast(.file(name: "Nothing.mov")), context: .init())
        #expect(result.outcome == .declined)
        #expect(result.prose.hasPrefix("I couldn't find a file called “Nothing.mov” in the catalog."))
        #expect(result.queryDescription == "shape=record reference=file:Nothing.mov notFound")
    }

    @Test func ambiguousScopeListsCandidatesWithOneChipEach() async throws {
        let candidates = [
            ArchivistRecordReferenceResolver.Candidate(id: UUID(), filename: "Christmas_1994.mov", fullPath: "/Volumes/A/Christmas_1994.mov"),
            ArchivistRecordReferenceResolver.Candidate(id: UUID(), filename: "Christmas_1995.mkv", fullPath: "/Volumes/A/Christmas_1995.mkv"),
        ]
        let context = HallieTurnExecutor.Context(recordScope: .ambiguous(candidates))
        let result = try await HallieTurnExecutor.execute(
            ast(.file(name: "Christmas.mov"), [.people], people: ["Donna"]), context: context)
        #expect(result.outcome == .declined)
        #expect(result.prose == "I found 2 files that could be “Christmas.mov”: Christmas_1994.mov, Christmas_1995.mkv. Which one do you mean?")
        #expect(result.offeredActions == [
            .ask(question: "is Donna in /Volumes/A/Christmas_1994.mov", label: "Christmas_1994.mov"),
            .ask(question: "is Donna in /Volumes/A/Christmas_1995.mkv", label: "Christmas_1995.mkv"),
        ])
        #expect(result.queryDescription == "shape=record reference=file:Christmas.mov ambiguous=2")
    }

    @Test func aWhichOneChipIsARecordQuestionAboutThatPath() async throws {
        let result = try await HallieTurnExecutor.execute(
            ast(.file(name: "Christmas.mov"), [.people]),
            context: .init(recordScope: .ambiguous([
                .init(id: UUID(), filename: "Christmas_1994.mov", fullPath: "/Volumes/A/Christmas_1994.mov"),
            ])))
        guard case .ask(let question, _)? = result.offeredActions.first else {
            Issue.record("expected an ask chip"); return
        }
        let record = ArchivistRecordQuestion.detect(question)
        #expect(record?.reference == .file(name: "/Volumes/A/Christmas_1994.mov"))
        #expect(record?.operations == [.people])
    }

    @Test func aContinuationIsRefusedOnTheRecordRoute() async throws {
        // Records have no which-person clarification; a stale chip cannot resume one.
        let result = try await HallieTurnExecutor.execute(ast(), context: .init(recordScope: .resolved(snapshot())))
        #expect(result.clarification == nil)
    }

    @Test func memoryKeepsTheSingleCitationForPlayItAndForgetsNoList() async throws {
        let context = HallieTurnExecutor.Context(recordScope: .resolved(snapshot()))
        let intent = HallieTurnExecutor.Intent(originalQuestion: "who is in this video", ast: ast())
        let result = try await HallieTurnExecutor.execute(.init(intent: intent), context: context)
        var memory = HallieTurnExecutor.ConversationMemory()
        memory.record(intent: intent, result: result)
        #expect(memory.lastResultSet?.citations.map(\.recordID) == [recordID])
        #expect(memory.lastRefinable == nil)
        #expect(memory.lastProvenance?.route == .record)
        // "play it" resolves against that one citation.
        let followUp = ArchivistFollowUpResolver.resolve(
            "play it", snapshot: memory.followUpSnapshot, isKnownPerson: { _ in false })
        if case .mediaAction(let verb, let indices) = followUp {
            #expect(verb == .play)
            #expect(indices == [0])
        } else {
            Issue.record("expected a media action, got \(followUp)")
        }
    }

    @Test func provenanceNamesTheOneRecord() async throws {
        let context = HallieTurnExecutor.Context(recordScope: .resolved(snapshot()))
        let result = try await HallieTurnExecutor.execute(ast(), context: context)
        let answer = HallieProvenanceFollowUp.answer(.source, provenance: .init(result: result))
        #expect(answer.prose.contains("That came from that one video's own catalog entry"), Comment(rawValue: answer.prose))
        #expect(answer.prose.contains("confirmed by a person"))
    }

    @Test func answeredRecordTurnsPlanAsFactsAndDeclinesStayFixed() async throws {
        let answered = try await HallieTurnExecutor.execute(ast(), context: .init(recordScope: .resolved(snapshot())))
        let plan = HallieAnswerPlan.derive(from: answered)
        #expect(plan.shape == .fact)
        #expect(plan.isComposable)
        #expect(plan.claims.count == 1)
        let declined = try await HallieTurnExecutor.execute(ast(), context: .init())
        #expect(HallieAnswerPlan.derive(from: declined).shape == .fixed)
    }

    @Test func preTranslationRunsARecordIntentModelFree() {
        let pre = HallieTurnExecutor.preTranslation(
            question: "who is in New Hampshire.mov",
            playAfterAnswer: false,
            memory: .init(),
            isKnownPerson: { _ in false })
        guard case .run(let intent) = pre else { Issue.record("expected .run, got \(pre)"); return }
        #expect(intent.ast == ast(.file(name: "New Hampshire.mov"), [.people]))
        #expect(intent.originalQuestion == "who is in New Hampshire.mov")

        // With a row selected, the date lane still wins for "when was this filmed".
        let selected = HallieTurnExecutor.SelectedRecord(recordID: recordID, date: nil)
        if case .answer(let result) = HallieTurnExecutor.preTranslation(
            question: "when was this filmed", playAfterAnswer: false, memory: .init(),
            isKnownPerson: { _ in false }, selectedRecord: selected) {
            #expect(result.route == .temporal)
        } else {
            Issue.record("the selection-date lane must keep 'when was this filmed'")
        }
        // Nothing selected: still not ours; the translator gets it.
        if case .translate = HallieTurnExecutor.preTranslation(
            question: "when was this filmed", playAfterAnswer: false, memory: .init(),
            isKnownPerson: { _ in false }) {} else {
            Issue.record("'when was this filmed' with no selection must translate")
        }
    }
}
