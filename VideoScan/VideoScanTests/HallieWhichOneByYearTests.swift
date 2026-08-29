// HallieWhichOneByYearTests.swift
// Live miss #3 (docs/hallie_spot_test_misses_2026_08_28.md): while a
// which-one clarification is pending, a reply that discriminates by birth
// year ("the one born in 1959", "donna 1959"), death year, place, parent
// or spouse, or position must pick the unique candidate and RESUME the
// original ask; a discriminator fitting several narrows the list; one
// fitting nobody is said; a plain new question still falls through.
// Both live candidate sets from the 2026-08-28 transcript are pinned.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private typealias Candidate = HallieTurnExecutor.Candidate
private typealias Match = HallieTurnExecutor.ClarificationReplyMatch

private func gedcom(_ id: String, _ name: String, _ label: String,
                    facts: [String] = []) -> Candidate {
    Candidate(id: .gedcomPersonID(id), canonicalName: name, label: label,
              discriminators: facts.map(PersonResolver.normalize))
}

/// The chips Hallie offered for "rick" at 22:46:43Z — none born in 1959.
private let liveRickChips: [Candidate] = [
    gedcom("@A@", "Anne Bourchier, of Leighs", "Anne Bourchier, of Leighs (b. About 1568, d. About 29 January 1669)"),
    gedcom("@B@", "Catherine Auker", "Catherine Auker (b. 1374, d. 12 July 1441)"),
    gedcom("@C@", "Catherine Cutherey", "Catherine Cutherey (b. July 1410, d. 17 July 1460)"),
    gedcom("@D@", "Elizabeth Mayne", "Elizabeth Mayne (b. 1440, d. 1525)"),
    gedcom("@E@", "Joan Dingley", "Joan Dingley (b. 1472, d. 12 June 1567)"),
    gedcom("@F@", "John De Holbrook V", "John De Holbrook V (b. about 1410, d. 12 July 1443)"),
    gedcom("@G@", "Richard", "Richard (b. 1370)"),
    gedcom("@H@", "Richard Cholmeley", "Richard Cholmeley (b. 1516, d. 17 May 1583)"),
    gedcom("@I@", "Richard Piell", "Richard Piell (b. 1350, d. 1400)"),
    gedcom("@J@", "Robert de Cralle", "Robert de Cralle (b. 1334, d. 1367)"),
]

/// The which-one for "donna" at 23:25:45Z.
private let liveDonnaChoices: [Candidate] = [
    gedcom("@K1@", "Agatha Donna Knauss", "Agatha Donna Knauss (b. ABT 1520, d. ABT 1547)"),
    gedcom("@K2@", "Agatha Donna Knauss", "Agatha Donna Knauss (b. 1520, d. about 1565)"),
    gedcom("@DH@", "Donna Hudson", "Donna Hudson (b. 4 August 1959)"),
]

private func reply(_ text: String, _ candidates: [Candidate]) -> Match {
    HallieTurnExecutor.clarificationReply(text, from: candidates)
}

@Suite("Which-one replies by year, place, kin, position")
struct HallieWhichOneReplyDiscriminatorTests {

    @Test func rickLiveReplyMatchesNobodyAndIsSaidNotRouted() {
        // Rick's exact reply against the exact live chips: no 1959 among
        // them, so the honest outcome is "none of them", NOT a new turn.
        #expect(reply("the one born in 1959", liveRickChips) == .unmatched(discriminator: "born in 1959"))
        #expect(HallieTurnExecutor.clarificationSelection("the one born in 1959", from: liveRickChips) == nil)
    }

    @Test func rickReplySelectsWhenTheRightRichardIsOffered() {
        let chips = liveRickChips + [gedcom("@JR@", "Richard Harding Breen Jr", "Richard Harding Breen Jr (b. 1959)")]
        for text in ["the one born in 1959", "born 1959", "1959", "the 1959 one", "the one born 1959"] {
            #expect(reply(text, chips) == .selected(.gedcomPersonID("@JR@")), "\(text)")
        }
    }

    @Test func donnaLiveReplySelectsDonnaHudson() {
        for text in ["donna 1959", "the one born in 1959", "1959", "Donna born 1959", "hudson", "the last one"] {
            #expect(reply(text, liveDonnaChoices) == .selected(.gedcomPersonID("@DH@")), "\(text)")
        }
    }

    @Test func deathYearAndOrdinalsPickAmongTheAgathas() {
        #expect(reply("died 1547", liveDonnaChoices) == .selected(.gedcomPersonID("@K1@")))
        #expect(reply("the one who died in 1565", liveDonnaChoices) == .selected(.gedcomPersonID("@K2@")))
        #expect(reply("the second one", liveDonnaChoices) == .selected(.gedcomPersonID("@K2@")))
        #expect(reply("the first one", liveDonnaChoices) == .selected(.gedcomPersonID("@K1@")))
    }

    @Test func ambiguousYearNarrowsToTheMatchingSubset() {
        guard case .narrowed(let subset, let discriminator) = reply("donna 1520", liveDonnaChoices) else {
            Issue.record("expected a narrowed list"); return
        }
        #expect(subset.map(\.id) == [.gedcomPersonID("@K1@"), .gedcomPersonID("@K2@")])
        #expect(discriminator == "1520")
        // A birth qualifier narrows the same way; a death year nobody has is said.
        if case .narrowed(let born, _) = reply("the one born in 1520", liveDonnaChoices) {
            #expect(born.count == 2)
        } else { Issue.record("expected narrowed") }
        #expect(reply("died 1700", liveDonnaChoices) == .unmatched(discriminator: "died in 1700"))
    }

    private let marthas: [Candidate] = [
        gedcom("@M1@", "Martha Lamson", "Martha Lamson (b. 1633, d. 1717)",
               facts: ["Sudbury, Middlesex, Massachusetts Bay Colony", "Matthew Rice", "Barnabas Lamson"]),
        gedcom("@M2@", "Martha Lamson", "Martha Lamson (b. 1700, d. 1760)",
               facts: ["Boston, Suffolk, Massachusetts", "Richard Harding Breen Jr", "John Lamson"]),
    ]

    @Test func placeParentAndSpouseDiscriminate() {
        #expect(reply("the one from Sudbury", marthas) == .selected(.gedcomPersonID("@M1@")))
        #expect(reply("the sudbury one", marthas) == .selected(.gedcomPersonID("@M1@")))
        #expect(reply("Matthew Rice's wife", marthas) == .selected(.gedcomPersonID("@M1@")))
        #expect(reply("the one married to Matthew", marthas) == .selected(.gedcomPersonID("@M1@")))
        #expect(reply("Barnabas Lamson's daughter", marthas) == .selected(.gedcomPersonID("@M1@")))
        // A nickname counts as the recorded name (rick → Richard).
        #expect(reply("the one married to Rick", marthas) == .selected(.gedcomPersonID("@M2@")))
        #expect(reply("the one from Paris", marthas) == .unmatched(discriminator: "paris"))
        // "massachusetts" is in both places → narrowed, never a guess.
        if case .narrowed(let both, _) = reply("the one from Massachusetts", marthas) {
            #expect(both.count == 2)
        } else { Issue.record("expected narrowed") }
    }

    @Test func aNewQuestionIsNotASelection() {
        for text in ["show videos from 1994", "what about 1959?", "who is Matthew Rice?",
                     "you presented me a list of people born hundreds or years ago",
                     "tell me about the one from Sudbury", "not the one born in 1633"] {
            #expect(reply(text, marthas) == .notASelection, "\(text)")
        }
    }
}

// MARK: - The ask resumes: lineage common ancestor with which-one chips

/// Rick's pull merged with Donna's, plus two "Agatha Donna Knauss" so
/// "donna" is a which-one, and two Matthew Rices for a both-sides case.
private let tree = """
0 HEAD
0 @I1@ INDI
1 NAME Richard Harding /Breen/ Jr
1 SEX M
1 BIRT
2 DATE 1959
1 FAMC @F1@
1 FAMS @F2@
0 @I2@ INDI
1 NAME Donna /Hudson/
1 SEX F
1 BIRT
2 DATE 4 AUG 1959
1 FAMC @F5@
1 FAMS @F2@
0 @I3@ INDI
1 NAME Richard Harding /Breen/ Sr
1 SEX M
1 BIRT
2 DATE 1930
1 FAMC @F3@
1 FAMS @F1@
0 @I4@ INDI
1 NAME George /Breen/
1 SEX M
1 FAMC @F4@
1 FAMS @F3@
0 @I5@ INDI
1 NAME Z /Common/
1 SEX M
1 BIRT
2 DATE 1840
1 FAMS @F4@
0 @I6@ INDI
1 NAME Walter /Hudson/
1 SEX M
1 FAMC @F6@
1 FAMS @F5@
0 @I7@ INDI
1 NAME Y /Hudson/
1 SEX M
1 FAMC @F4@
1 FAMS @F6@
0 @I8@ INDI
1 NAME Agatha Donna /Knauss/
1 SEX F
1 BIRT
2 DATE ABT 1520
1 DEAT
2 DATE ABT 1547
0 @I9@ INDI
1 NAME Agatha Donna /Knauss/
1 SEX F
1 BIRT
2 DATE 1520
1 DEAT
2 DATE ABT 1565
0 @I10@ INDI
1 NAME Matthew /Rice/
1 SEX M
1 BIRT
2 DATE 28 FEB 1629
2 PLAC Sudbury, Middlesex, Massachusetts Bay Colony
1 FAMS @F7@
0 @I11@ INDI
1 NAME Matthew /Rice/
1 SEX M
1 BIRT
2 DATE 1700
2 PLAC Boston, Suffolk, Massachusetts
0 @I12@ INDI
1 NAME Martha /Lamson/
1 SEX F
1 FAMS @F7@
0 @F1@ FAM
1 HUSB @I3@
1 CHIL @I1@
0 @F2@ FAM
1 HUSB @I1@
1 WIFE @I2@
0 @F3@ FAM
1 HUSB @I4@
1 CHIL @I3@
0 @F4@ FAM
1 HUSB @I5@
1 CHIL @I4@
1 CHIL @I7@
0 @F5@ FAM
1 HUSB @I6@
1 CHIL @I2@
0 @F6@ FAM
1 HUSB @I7@
1 CHIL @I6@
0 @F7@ FAM
1 HUSB @I10@
1 WIFE @I12@
0 TRLR
"""

private func fixtureGraph() -> GedcomFamilyGraph { GedcomFamilyGraph(gedcomText: tree) }

private func context(_ graph: GedcomFamilyGraph) -> HallieTurnExecutor.Context {
    HallieTurnExecutor.Context(
        profiles: [], graph: graph,
        speakers: .init(ownerName: "Rick Breen", archivistName: nil, archivistPersonName: nil))
}

private func lineageIntent(_ question: String, context: HallieTurnExecutor.Context) throws -> HallieTurnExecutor.Intent {
    let pre = HallieTurnExecutor.preTranslation(
        question: question, playAfterAnswer: false, memory: .init(),
        isKnownPerson: { _ in false }, catalogStats: nil, rosterAnswer: nil,
        lineageAnswer: { HallieLineageAnswer.answer($0, context: context) })
    guard case .run(let intent) = pre else {
        throw FixtureError.unexpected("expected .run, got \(pre)")
    }
    return intent
}

private enum FixtureError: Error { case unexpected(String) }

@Suite("Common ancestor which-one resumes the ask")
struct HallieCommonAncestorWhichOneTests {

    @Test func donnaWhichOneCarriesResumableChipsAndDonna1959Answers() async throws {
        let graph = fixtureGraph()
        let ctx = context(graph)
        // The tree really has three "donna"s.
        #expect(graph.people(namedLike: "donna").count == 3)

        let intent = try lineageIntent("Find the most recent common ancestor between rick and donna", context: ctx)
        guard case .graph(let payload) = intent.ast else { Issue.record("not graph"); return }
        #expect(payload.operation == .commonAncestor)

        let asked = try await HallieTurnExecutor.execute(HallieTurnExecutor.Request(intent: intent), context: ctx)
        #expect(asked.outcome == .needsClarification)
        #expect(asked.prose.hasPrefix("Which Donna do you mean — "))
        #expect(asked.prose.contains("Donna Hudson (b. 4 AUG 1959)"))
        let pending = try #require(asked.clarification)
        #expect(pending.stage == .gedcomPerson)
        #expect(pending.candidates.count == 3)

        // Rick's exact reply.
        let match = HallieTurnExecutor.clarificationReply("donna 1959", from: pending.candidates)
        #expect(match == .selected(.gedcomPersonID("@I2@")))

        let answer = try await HallieTurnExecutor.continue(
            pending: pending, selecting: .gedcomPersonID("@I2@"), context: ctx)
        #expect(answer.outcome == .answered, "\(answer.prose)")
        #expect(answer.prose.contains("Z Common"))
        #expect(answer.prose.contains("Richard Harding Breen Jr") && answer.prose.contains("Donna Hudson"))
        #expect(answer.clarification == nil)
    }

    @Test func theOneBornIn1959AlsoResumes() async throws {
        let ctx = context(fixtureGraph())
        let intent = try lineageIntent("closest common ancestor of rick and donna", context: ctx)
        let asked = try await HallieTurnExecutor.execute(HallieTurnExecutor.Request(intent: intent), context: ctx)
        let pending = try #require(asked.clarification)
        guard case .selected(let id) = HallieTurnExecutor.clarificationReply("the one born in 1959", from: pending.candidates) else {
            Issue.record("expected selection"); return
        }
        let answer = try await HallieTurnExecutor.continue(pending: pending, selecting: id, context: ctx)
        #expect(answer.outcome == .answered)
        #expect(answer.prose.contains("Z Common"))
    }

    @Test func bothSidesAmbiguousPinTheFirstChoiceThroughTheSecond() async throws {
        let ctx = context(fixtureGraph())
        let intent = try lineageIntent("common ancestor of matthew rice and donna", context: ctx)
        let first = try await HallieTurnExecutor.execute(HallieTurnExecutor.Request(intent: intent), context: ctx)
        #expect(first.prose.hasPrefix("Which Matthew Rice do you mean"))
        let matthews = try #require(first.clarification)
        // The Sudbury Matthew: place is a discriminator built from the tree.
        guard case .selected(let matthew) = HallieTurnExecutor.clarificationReply("the one from Sudbury", from: matthews.candidates) else {
            Issue.record("expected the Sudbury Matthew"); return
        }
        #expect(matthew == .gedcomPersonID("@I10@"))
        #expect(HallieTurnExecutor.clarificationReply("Martha Lamson's husband", from: matthews.candidates) == .selected(.gedcomPersonID("@I10@")))

        let second = try await HallieTurnExecutor.continue(pending: matthews, selecting: matthew, context: ctx)
        #expect(second.outcome == .needsClarification)
        #expect(second.prose.hasPrefix("Which Donna do you mean"))
        let donnas = try #require(second.clarification)
        #expect(donnas.intent.pinnedGraphSubjects[0] == .gedcomPersonID("@I10@"))

        let final = try await HallieTurnExecutor.continue(pending: donnas, selecting: .gedcomPersonID("@I2@"), context: ctx)
        #expect(final.outcome == .declined, "\(final.prose)")   // no shared ancestor, honestly
        #expect(final.prose.contains("Matthew Rice"))
        #expect(final.queryDescription == "common ancestor: Matthew Rice & Donna Hudson")
    }

    @Test func narrowedClarificationIsASubsetOfItself() async throws {
        let ctx = context(fixtureGraph())
        let intent = try lineageIntent("common ancestor of rick and donna", context: ctx)
        let asked = try await HallieTurnExecutor.execute(HallieTurnExecutor.Request(intent: intent), context: ctx)
        let pending = try #require(asked.clarification)
        guard case .narrowed(let subset, _) = HallieTurnExecutor.clarificationReply("donna 1520", from: pending.candidates) else {
            Issue.record("expected narrowed"); return
        }
        let narrowed = try #require(pending.narrowed(to: subset))
        #expect(narrowed.candidates.count == 2)
        // A narrowed list still continues (same token, same intent).
        let answer = try await HallieTurnExecutor.continue(pending: narrowed, selecting: subset[0].id, context: ctx)
        #expect(answer.outcome != .failed)
        // A forged subset is refused.
        #expect(pending.narrowed(to: [gedcom("@ZZ@", "Nobody", "Nobody")]) == nil)
        #expect(pending.narrowed(to: []) == nil)
    }

    @Test func unambiguousCommonAncestorStillAnswersWithoutAnIntent() {
        let ctx = context(fixtureGraph())
        let pre = HallieTurnExecutor.preTranslation(
            question: "common ancestor of rick and walter hudson", playAfterAnswer: false, memory: .init(),
            isKnownPerson: { _ in false }, catalogStats: nil, rosterAnswer: nil,
            lineageAnswer: { HallieLineageAnswer.answer($0, context: ctx) })
        guard case .answer(let r) = pre else { Issue.record("expected .answer, got \(pre)"); return }
        #expect(r.outcome == .answered)
        #expect(r.prose.contains("Z Common"))
    }
}

// MARK: - App parity (coordinator) and shell parity

@MainActor
@Suite("Common ancestor which-one — app and shell parity")
struct HallieCommonAncestorWhichOneClientTests {

    @Test func coordinatorKeepsThePendingClarificationAndContinues() async throws {
        let graph = fixtureGraph()
        let translations = LockedCounter()
        let dependencies = HallieAppTurnCoordinator.Dependencies(
            startLocalBrain: { hosts in hosts },
            translateAST: { _, _, _ in
                translations.increment()
                throw FixtureError.unexpected("the translator must not be consulted")
            },
            loadProfiles: { [] },
            loadGraph: { graph },
            loadSpeakers: { .init(ownerName: "Rick Breen", archivistName: nil, archivistPersonName: nil) },
            executeRequest: { request, context in
                try await HallieTurnExecutor.execute(request, context: context)
            },
            continueTurn: { clarification, selectedID, context in
                try await HallieTurnExecutor.continue(pending: clarification, selecting: selectedID, context: context)
            },
            resolveBiographyPhoto: { _ in nil })

        let first = try await HallieAppTurnCoordinator.execute(
            question: "Find the most recent common ancestor between rick and donna", records: [],
            referent: .init(recordID: nil, temporalDate: nil),
            hosts: ["fixture.invalid"], modelName: "fixture-model", dependencies: dependencies)
        #expect(first.result.outcome == .needsClarification)
        let pending = try #require(first.pendingClarification)
        #expect(translations.value == 0)

        switch HallieTurnExecutor.clarificationReply("donna 1959", from: pending.clarification.candidates) {
        case .selected(let id):
            let answer = try await HallieAppTurnCoordinator.continue(
                pending: pending, selecting: id, dependencies: dependencies)
            #expect(answer.result.outcome == .answered)
            #expect(answer.result.prose.contains("Z Common"))
            #expect(answer.pendingClarification == nil)
        default:
            Issue.record("donna 1959 must select Donna Hudson")
        }
        // The narrowed pending keeps the context and composition.
        if case .narrowed(let subset, _) = HallieTurnExecutor.clarificationReply("donna 1520", from: pending.clarification.candidates) {
            let narrowed = try #require(pending.narrowed(to: subset))
            #expect(narrowed.clarification.candidates.count == 2)
            #expect(narrowed.responderHost == pending.responderHost)
        } else { Issue.record("expected narrowed") }
        #expect(translations.value == 0)
    }

    @Test func shellSaysNoneThenResumesOnDonna1959() async throws {
        let harness = Harness(
            inputs: ["Find the most recent common ancestor between Richard Harding Breen Jr and donna",
                     "the one born in 1900",
                     "donna 1959",
                     ":quit"],
            graph: fixtureGraph())
        let continuations = LockedCounter()
        harness.executeRequest = { request, context in
            try await HallieTurnExecutor.execute(request, context: context)
        }
        harness.continueTurn = { pending, selectedID, context in
            continuations.increment()
            return try await HallieTurnExecutor.continue(pending: pending, selecting: selectedID, context: context)
        }
        let options = try HallieShellCLI.parse(arguments: ["--hallie", "--catalog", "/isolated/catalog.json"])
        let code = await HallieShellCLI.run(
            options: options, input: harness.nextInput,
            output: { harness.output.append($0) },
            dependencies: harness.dependencies())

        #expect(code == HallieShellCLI.ExitCode.success.rawValue)
        #expect(harness.translatedQuestions.isEmpty, "\(harness.translatedQuestions)")
        #expect(harness.output.contains { $0.hasPrefix("Which Donna do you mean — ") })
        #expect(harness.output.contains { $0.hasPrefix("None of them matches “born in 1900”.") })
        // The list is shown with the question and again after the miss.
        #expect(harness.output.filter { $0 == "choices:" }.count == 2)
        #expect(continuations.value == 1)
        #expect(harness.output.contains { $0.contains("Z Common") })
    }

    @Test func shellNarrowsThenTheOrdinalPicksFromTheSubset() async throws {
        let harness = Harness(
            inputs: ["Find the most recent common ancestor between Richard Harding Breen Jr and donna",
                     "donna 1520",
                     "the first one",
                     ":quit"],
            graph: fixtureGraph())
        let continuations = LockedCounter()
        harness.executeRequest = { request, context in
            try await HallieTurnExecutor.execute(request, context: context)
        }
        harness.continueTurn = { pending, selectedID, context in
            continuations.increment()
            #expect(pending.candidates.count == 2, "the narrowed list continues")
            #expect(selectedID == .gedcomPersonID("@I8@"))
            return try await HallieTurnExecutor.continue(pending: pending, selecting: selectedID, context: context)
        }
        let options = try HallieShellCLI.parse(arguments: ["--hallie", "--catalog", "/isolated/catalog.json"])
        _ = await HallieShellCLI.run(
            options: options, input: harness.nextInput,
            output: { harness.output.append($0) },
            dependencies: harness.dependencies())

        #expect(harness.translatedQuestions.isEmpty)
        #expect(harness.output.contains { $0.hasPrefix("2 of them match “1520” — which one?") })
        #expect(harness.output.contains("  2. Agatha Donna Knauss (b. 1520, d. ABT 1565)"))
        // The full list (3) once, the narrowed list (2) once: "3." appears only in the first.
        #expect(harness.output.filter { $0.hasPrefix("  3. ") }.count == 1)
        #expect(harness.output.filter { $0 == "choices:" }.count == 2)
        #expect(continuations.value == 1)
        // Agatha has no recorded parents: the honest decline, for HER.
        #expect(harness.output.contains { $0.contains("Agatha Donna Knauss") && $0.contains("isn’t in the tree yet") })
    }
}

// MARK: - Shell harness (mirrors HallieShellCLITests.Harness, graph-only)

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

@MainActor
private final class Harness {
    var inputs: [String]
    var output: [String] = []
    var translatedQuestions: [String] = []
    var transcriptEvents: [HallieTranscriptEvent] = []
    let graph: GedcomFamilyGraph
    var executeRequest: (@Sendable (HallieTurnExecutor.Request, HallieTurnExecutor.Context) async throws -> HallieTurnExecutor.Result)?
    var continueTurn: (@Sendable (HallieTurnExecutor.Clarification, HallieTurnExecutor.CandidateID, HallieTurnExecutor.Context) async throws -> HallieTurnExecutor.Result)?

    init(inputs: [String], graph: GedcomFamilyGraph) {
        self.inputs = inputs
        self.graph = graph
    }

    func dependencies() -> HallieShellCLI.Dependencies {
        HallieShellCLI.Dependencies(
            loadCatalog: { _ in [] },
            loadProfiles: { .loaded([]) },
            loadGraph: { [self] _ in graph },
            loadCyberBrain: { nil },
            translateAST: { [self] question, _ in
                translatedQuestions.append(question)
                throw FixtureError.unexpected("no translation in this test")
            },
            executeTurn: HallieTurnExecutor.execute,
            executeRequest: executeRequest,
            continueTurn: continueTurn,
            mediaURLIsAvailable: { _ in true },
            tryPerformMediaAction: { _ in true },
            performMediaAction: { _ in },
            recordTranscript: { [self] events in transcriptEvents.append(contentsOf: events) })
    }

    func nextInput() -> String? { inputs.isEmpty ? nil : inputs.removeFirst() }
}
