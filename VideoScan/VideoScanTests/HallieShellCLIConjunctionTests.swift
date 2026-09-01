// HallieShellCLIConjunctionTests.swift
// Two eval misses from 2026-09-01 (runID hallie-eval-20260901T185546-a392faeb),
// both in the headless shell:
//
//   A. "who is Tim's brother and how old is Tim" — the split loop kept
//      going after clause 1 asked "Which tim do you mean?", so clause 2
//      was consumed as a REPLY to the which-one: "I need one of the listed
//      names or numbers so I don't guess." The loop must stop on a pending
//      clarification, as the chat window and the web bridge already do.
//
//   B. "where was Martha Lamson born and when was she born" → "did she have
//      kids" → "and her husband?" — the last turn became a which-one over
//      five tree people with "Husband" in the name (the follow-up refiner
//      read "her" as filler and "husband" as a known person, and kept
//      relation = children). Martha is still the subject; her husband is
//      Matthew Rice, and no model is needed to say so.
//
// Fixture graphs, fixture translator keyed by question text (an unknown
// question fails loudly), no model.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@MainActor
@Suite("Hallie shell — split questions and pronoun follow-ups", .serialized)
struct HallieShellCLIConjunctionTests {

    private static let twoTims = GedcomFamilyGraph(gedcomText: """
    0 HEAD
    0 @I1@ INDI
    1 NAME Tim /Breen/
    1 SEX M
    1 BIRT
    2 DATE 1985
    1 FAMC @F1@
    0 @I2@ INDI
    1 NAME Tim /Breen/
    1 SEX M
    1 BIRT
    2 DATE 1990
    1 FAMC @F1@
    0 @F1@ FAM
    1 CHIL @I1@
    1 CHIL @I2@
    0 TRLR
    """)

    private static let marthasFamily = GedcomFamilyGraph(gedcomText: """
    0 HEAD
    0 @I1@ INDI
    1 NAME Martha /Lamson/
    1 SEX F
    1 BIRT
    2 DATE BEF 13 JAN 1633
    2 PLAC Ridgewell, Essex, England
    1 DEAT
    2 DATE AFT 1717
    1 FAMS @F1@
    0 @I2@ INDI
    1 NAME Matthew /Rice/
    1 SEX M
    1 FAMS @F1@
    0 @I3@ INDI
    1 NAME Isaac /Rice/
    1 SEX M
    1 FAMC @F1@
    0 @I4@ INDI
    1 NAME Patience /Rice/
    1 SEX F
    1 FAMC @F1@
    0 @I5@ INDI
    1 NAME Weston Browne 1 /Husband/
    1 SEX M
    0 @F1@ FAM
    1 HUSB @I2@
    1 WIFE @I1@
    1 CHIL @I3@
    1 CHIL @I4@
    1 MARR
    2 DATE 7 JUL 1654
    0 TRLR
    """)

    private final class Harness {
        var output: [String] = []
        var translatedQuestions: [String] = []
        var transcriptEvents: [HallieTranscriptEvent] = []
        let graph: GedcomFamilyGraph
        let translations: [String: ArchivistQueryAST]

        init(graph: GedcomFamilyGraph, translations: [String: ArchivistQueryAST]) {
            self.graph = graph
            self.translations = translations
        }

        struct UnexpectedTranslation: LocalizedError {
            let question: String
            var errorDescription: String? { "no fixture translation for “\(question)”" }
        }

        func dependencies() -> HallieShellCLI.Dependencies {
            HallieShellCLI.Dependencies(
                loadCatalog: { _ in [] },
                loadProfiles: { .loaded([]) },
                loadGraph: { [self] _ in graph },
                translateAST: { [self] question, _ in
                    translatedQuestions.append(question)
                    guard let ast = translations[question] else {
                        throw UnexpectedTranslation(question: question)
                    }
                    return .init(ast: ast, responderHost: "fixture-translator")
                },
                executeTurn: HallieTurnExecutor.execute,
                performMediaAction: { _ in },
                recordTranscript: { [self] events in
                    transcriptEvents.append(contentsOf: events)
                })
        }

        var assistantTurns: [HallieTranscriptEvent] {
            transcriptEvents.filter { $0.kind == .assistant }
        }

        func session() -> HallieShellCLI.Session {
            HallieShellCLI.Session(
                records: [], profiles: [], graph: graph, cyberBrain: nil,
                speakers: .init(ownerName: "Rick Breen", archivistName: "Hallie Mae"),
                model: "fixture-model", runID: "conjunction-tests")
        }
    }

    private func ask(_ question: String, harness: Harness,
                     state: inout HallieShellCLI.Session) async throws -> HallieShellCLI.AnswerOutcome {
        let options = try HallieShellCLI.parse(arguments: ["--hallie"])
        return await HallieShellCLI.answer(
            question, options: options, state: &state,
            output: { harness.output.append($0) },
            dependencies: harness.dependencies())
    }

    // MARK: A — the split loop stops on a which-one

    @Test func aSplitQuestionStopsAtTheFirstWhichOne() async throws {
        let harness = Harness(
            graph: Self.twoTims,
            translations: [
                "who is Tim's brother": .graph(.init(people: ["Tim"], operation: .kinship, relation: .brother)),
                "how old is Tim": .temporal(.init(subject: "Tim", operation: .age, reference: .currentSelection)),
            ])
        var state = harness.session()
        #expect(HallieQuestionSplitter.split("who is Tim's brother and how old is Tim")?.count == 2,
                "the fixture line must actually split")

        _ = try await ask("who is Tim's brother and how old is Tim", harness: harness, state: &state)

        // Exactly one assistant turn — the which-one — and it is pending.
        #expect(harness.assistantTurns.count == 1, "\(harness.assistantTurns.map(\.text))")
        #expect(harness.assistantTurns.first?.outcome == "needs-clarification")
        #expect(harness.assistantTurns.first?.text.hasPrefix("Which Tim") == true,
                "\(harness.assistantTurns.first?.text ?? "")")
        #expect(state.pendingClarification != nil)
        #expect(state.pendingClarification?.value.candidates.count == 2)
        // Clause 2 was NOT run as a reply to the which-one.
        #expect(harness.translatedQuestions == ["who is Tim's brother"])
        #expect(!harness.output.contains { $0.contains("I need one of the listed names") })
        // The transcript still pairs the assistant turn with the FULL line.
        #expect(harness.transcriptEvents.first?.kind == .user)
        #expect(harness.transcriptEvents.first?.text == "who is Tim's brother and how old is Tim")

        // The reader's choice resumes clause 1, and the which-one is gone.
        let outcome = try await ask("the one born in 1985", harness: harness, state: &state)
        #expect(outcome == .answered, "\(harness.output.suffix(3))")
        #expect(state.pendingClarification == nil)
        #expect(harness.assistantTurns.count == 2)
        #expect(harness.assistantTurns.last?.text.contains("brother") == true,
                "\(harness.assistantTurns.last?.text ?? "")")
    }

    // MARK: B — "and her husband?" follows the subject through the tree

    @Test func andHerHusbandFollowsMarthaNotHerChildren() async throws {
        let martha = "Martha Lamson"
        let harness = Harness(
            graph: Self.marthasFamily,
            translations: [
                "where was \(martha) born": .graph(.init(people: [martha], operation: .birthPlace)),
                "when was \(martha) born": .graph(.init(people: [martha], operation: .birth)),
                "did \(martha) have kids": .graph(.init(people: [martha], operation: .kinship, relation: .children)),
            ])
        var state = harness.session()

        _ = try await ask("where was Martha Lamson born and when was she born", harness: harness, state: &state)
        #expect(harness.assistantTurns.count == 2, "\(harness.assistantTurns.map(\.text))")
        #expect(harness.assistantTurns.allSatisfy { $0.outcome == "answered" })

        _ = try await ask("did she have kids", harness: harness, state: &state)
        let kids = try #require(harness.assistantTurns.last)
        #expect(kids.text == "Martha Lamson's children: Isaac Rice, Patience Rice.", "\(kids.text)")
        // The children are NOT the subject now; Martha still is.
        #expect(state.memory.pronounReferents == ["Martha Lamson"])

        let outcome = try await ask("and her husband?", harness: harness, state: &state)
        let husband = try #require(harness.assistantTurns.last)
        #expect(outcome == .answered, "\(husband.text)")
        #expect(husband.outcome == "answered")
        #expect(husband.text.contains("Matthew Rice"), "\(husband.text)")
        #expect(!husband.text.contains("Which Husband"), "\(husband.text)")
        #expect(husband.queryDescription?.contains("relation=husband") == true,
                "\(husband.queryDescription ?? "nil")")
        #expect(husband.queryDescription?.lowercased().contains("person=martha lamson") == true,
                "\(husband.queryDescription ?? "nil")")
        #expect(state.pendingClarification == nil)
        // Deterministic: the model was never asked about the husband.
        #expect(harness.translatedQuestions == [
            "where was Martha Lamson born", "when was Martha Lamson born", "did Martha Lamson have kids",
        ], "\(harness.translatedQuestions)")

        // And "her" keeps pointing at Martha for the next turn too.
        #expect(state.memory.pronounReferents == ["Martha Lamson"])
    }

    /// With nothing in memory the fragment asks who — never a lookup of a
    /// person named "Her".
    @Test func andHerHusbandWithNoSubjectAsksWho() async throws {
        let harness = Harness(graph: Self.marthasFamily, translations: [:])
        var state = harness.session()
        let outcome = try await ask("and her husband?", harness: harness, state: &state)
        #expect(outcome == .declined)
        let turn = try #require(harness.assistantTurns.last)
        #expect(turn.text.hasPrefix("I'm not sure who you mean by “her”"), "\(turn.text)")
        #expect(harness.translatedQuestions.isEmpty)
        #expect(state.pendingClarification == nil)
    }
}
