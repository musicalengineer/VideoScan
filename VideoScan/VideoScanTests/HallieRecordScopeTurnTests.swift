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
        let context = HallieTurnExecutor.Context(recordScope: .ambiguous(candidates, total: 2))
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

    /// codex #976 item 6: the true count survives the five-chip cap, and
    /// identical basenames are told apart by volume in the chip labels —
    /// while every chip still asks by full path.
    @Test func ambiguityKeepsTheTrueCountAndLabelsCollidingBasenamesByVolume() async throws {
        let candidates = [
            ArchivistRecordReferenceResolver.Candidate(id: UUID(), filename: "tape.mov", fullPath: "/Volumes/LaCie/1994/tape.mov"),
            ArchivistRecordReferenceResolver.Candidate(id: UUID(), filename: "tape.mov", fullPath: "/Volumes/MyBook/1994/tape.mov"),
            ArchivistRecordReferenceResolver.Candidate(id: UUID(), filename: "Tape 2.mov", fullPath: "/Volumes/LaCie/1995/Tape 2.mov"),
        ]
        let result = try await HallieTurnExecutor.execute(
            ast(.file(name: "tape"), [.people]),
            context: .init(recordScope: .ambiguous(candidates, total: 7)))
        #expect(result.outcome == .declined)
        #expect(result.prose == "I found 7 files that could be “tape”; here are the first 3: tape.mov (LaCie), tape.mov (MyBook), Tape 2.mov. Which one do you mean?")
        #expect(result.offeredActions == [
            .ask(question: "who is in /Volumes/LaCie/1994/tape.mov", label: "tape.mov (LaCie)"),
            .ask(question: "who is in /Volumes/MyBook/1994/tape.mov", label: "tape.mov (MyBook)"),
            .ask(question: "who is in /Volumes/LaCie/1995/Tape 2.mov", label: "Tape 2.mov"),
        ])
        #expect(result.queryDescription == "shape=record reference=file:tape ambiguous=7")
        #expect(result.basisLine.contains("matched 7 catalog filenames (3 offered"))
    }

    /// codex #976 item 3: a path nobody has is a decline that OFFERS the
    /// same-named files (by exact path) — never a silent substitute.
    @Test func aMissingPathDeclinesAndOffersTheSameNamedFiles() async throws {
        let sameName = [
            ArchivistRecordReferenceResolver.Candidate(id: UUID(), filename: "tape.mov", fullPath: "/Volumes/A/tape.mov"),
        ]
        let one = try await HallieTurnExecutor.execute(
            ast(.file(name: "/Volumes/B/tape.mov"), [.people]),
            context: .init(recordScope: .pathNotFound(path: "/Volumes/B/tape.mov", sameName: sameName, sameNameTotal: 1)))
        #expect(one.route == .record)
        #expect(one.outcome == .declined)
        #expect(one.prose == "I don't have /Volumes/B/tape.mov. I do have /Volumes/A/tape.mov — that one?")
        #expect(one.offeredActions == [.ask(question: "who is in /Volumes/A/tape.mov", label: "tape.mov")])
        #expect(one.citations.isEmpty)
        #expect(one.queryDescription == "shape=record reference=file:/Volumes/B/tape.mov pathNotFound sameName=1")

        let two = try await HallieTurnExecutor.execute(
            ast(.file(name: "/Volumes/C/tape.mov"), [.about]),
            context: .init(recordScope: .pathNotFound(
                path: "/Volumes/C/tape.mov",
                sameName: sameName + [.init(id: UUID(), filename: "tape.mov", fullPath: "/Volumes/B/tape.mov")],
                sameNameTotal: 2)))
        #expect(two.prose == "I don't have /Volumes/C/tape.mov. I do have 2 files called “tape.mov”: tape.mov (A), tape.mov (B). One of those?")
        #expect(two.offeredActions == [
            .ask(question: "tell me about /Volumes/A/tape.mov", label: "tape.mov (A)"),
            .ask(question: "tell me about /Volumes/B/tape.mov", label: "tape.mov (B)"),
        ])

        let none = try await HallieTurnExecutor.execute(
            ast(.file(name: "/Volumes/B/nothing.mov"), [.people]),
            context: .init(recordScope: .pathNotFound(path: "/Volumes/B/nothing.mov", sameName: [], sameNameTotal: 0)))
        #expect(none.outcome == .declined)
        #expect(none.prose.hasPrefix("I don't have /Volumes/B/nothing.mov, and nothing in the catalog is called “nothing.mov”."))
        #expect(none.offeredActions.isEmpty)
    }

    @Test func aWhichOneChipIsARecordQuestionAboutThatPath() async throws {
        let result = try await HallieTurnExecutor.execute(
            ast(.file(name: "Christmas.mov"), [.people]),
            context: .init(recordScope: .ambiguous([
                .init(id: UUID(), filename: "Christmas_1994.mov", fullPath: "/Volumes/A/Christmas_1994.mov"),
            ], total: 1)))
        guard case .ask(let question, _)? = result.offeredActions.first else {
            Issue.record("expected an ask chip"); return
        }
        let record = ArchivistRecordQuestion.detect(question)
        #expect(record?.reference == .file(name: "/Volumes/A/Christmas_1994.mov"))
        #expect(record?.operations == [.people])
    }

    /// codex #976 item 2: a DECLINED record turn empties the playable
    /// memory — "play it" after "who is in Nowhere.mov" must not play the
    /// earlier list's item.
    @Test func aDeclinedRecordTurnClearsThePlayableMemory() async throws {
        var memory = HallieTurnExecutor.ConversationMemory()
        let earlier = HallieTurnExecutor.Intent(
            originalQuestion: "videos of Donna", ast: .presence(.init(people: ["Donna"])))
        memory.record(intent: earlier, result: HallieTurnExecutor.Result(
            route: .presence, outcome: .answered, prose: "1 video", basisLine: "fixture",
            queryDescription: "shape=presence",
            citations: [.init(recordID: recordID, fullPath: path, filename: "New Hampshire.mov", playbackSeconds: nil, bases: [])],
            catalogPersonName: nil, matchCount: 1))
        #expect(memory.lastResultSet?.citations.count == 1)

        let intent = HallieTurnExecutor.Intent(originalQuestion: "who is in Nowhere.mov", ast: ast(.file(name: "Nowhere.mov")))
        let declined = try await HallieTurnExecutor.execute(.init(intent: intent), context: .init())
        #expect(declined.outcome == .declined)
        memory.record(intent: intent, result: declined)
        #expect(memory.lastResultSet == nil)
        #expect(memory.lastShownList == nil)
        #expect(memory.lastRecordDecline == .file("Nowhere.mov"))

        let pre = HallieTurnExecutor.preTranslation(
            question: "play it", playAfterAnswer: false, memory: memory, isKnownPerson: { _ in false })
        guard case .answer(let answer) = pre else { Issue.record("expected a local decline, got \(pre)"); return }
        #expect(answer.route == .followUp)
        #expect(answer.outcome == .declined)
        #expect(answer.mediaAction == nil)
        #expect(answer.prose == "Nothing to play — I couldn't settle which file “Nowhere.mov” is. Name the file exactly as it appears in the Catalog, or select one there, and ask me again.")

        // An answered record turn afterwards restores a playable item.
        let answeredIntent = HallieTurnExecutor.Intent(originalQuestion: "who is in this video", ast: ast())
        let answered = try await HallieTurnExecutor.execute(
            .init(intent: answeredIntent), context: .init(recordScope: .resolved(snapshot())))
        memory.record(intent: answeredIntent, result: answered)
        #expect(memory.lastRecordDecline == nil)
        #expect(memory.lastResultSet?.citations.map(\.recordID) == [recordID])
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

    /// codex #976 item 5: capability and help run BEFORE the record
    /// recogniser, so a question about Hallie that happens to carry "it"
    /// and a date word is answered as capability, never as a record turn.
    @Test(arguments: [
        ("can you change the date on it", HallieTurnExecutor.Route.capability),
        ("can you delete it", .capability),
        ("can you remember the date of this one", .capability),
        ("help", .help),
    ] as [(String, HallieTurnExecutor.Route)])
    func capabilityAndHelpOutrankTheRecordRecogniser(question: String, route: HallieTurnExecutor.Route) {
        let selected = HallieTurnExecutor.SelectedRecord(recordID: recordID, date: nil)
        let pre = HallieTurnExecutor.preTranslation(
            question: question, playAfterAnswer: false, memory: .init(),
            isKnownPerson: { _ in false }, selectedRecord: selected)
        guard case .answer(let result) = pre else {
            Issue.record("\(question): expected a local answer, got \(pre)"); return
        }
        #expect(result.route == route, Comment(rawValue: "\(question) → \(result.route)"))
    }

    /// The same words with the noun beside the referent are still ours.
    @Test func dateBesideThePronounIsStillARecordTurn() {
        let pre = HallieTurnExecutor.preTranslation(
            question: "what is the date of it", playAfterAnswer: false, memory: .init(),
            isKnownPerson: { _ in false })
        guard case .run(let intent) = pre else { Issue.record("expected .run, got \(pre)"); return }
        #expect(intent.ast == ast(.currentSelection, [.date]))
        // And a stray "it" with a date word elsewhere goes to the translator.
        if case .translate = HallieTurnExecutor.preTranslation(
            question: "it would be nice to know the dates", playAfterAnswer: false, memory: .init(),
            isKnownPerson: { _ in false }) {} else {
            Issue.record("a date word away from the pronoun is not a record question")
        }
    }
}
