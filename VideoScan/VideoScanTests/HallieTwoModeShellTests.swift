// HallieTwoModeShellTests.swift
// The shell client runs the same mode gate as the app (design §3.4 B): a
// two-turn session — a biography, then a pronoun question the stand-in
// translator answers with a catalog `presence` — ends in a graph answer,
// never a keyword search, and the diagnostics line names the mode.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private let tree = """
0 HEAD
0 @I1@ INDI
1 NAME John /Hastings/
1 SEX M
1 BIRT
2 DATE 11 OCT 1372
2 PLAC Kenilworth, Warwickshire, England
1 DEAT
2 DATE 30 DEC 1389
0 TRLR
"""

@MainActor
@Suite("Two-mode gate: shell", .serialized)
struct HallieTwoModeShellTests {
    private final class Harness: @unchecked Sendable {
        var inputs: [String]
        var output: [String] = []
        var translatedQuestions: [String] = []
        var translations: [ArchivistQueryAST]
        var transcriptEvents: [HallieTranscriptEvent] = []
        let graph = GedcomFamilyGraph(gedcomText: tree)

        init(inputs: [String], translations: [ArchivistQueryAST]) {
            self.inputs = inputs
            self.translations = translations
        }

        func nextInput() -> String? {
            inputs.isEmpty ? nil : inputs.removeFirst()
        }

        func dependencies() -> HallieShellCLI.Dependencies {
            HallieShellCLI.Dependencies(
                loadCatalog: { _ in [] },
                loadProfiles: { .loaded([]) },
                loadGraph: { [self] _ in graph },
                translateAST: { [self] question, _ in
                    translatedQuestions.append(question)
                    guard !translations.isEmpty else {
                        throw NLTranslatorError.badResponse("no fixture translation")
                    }
                    return .init(ast: translations.removeFirst(), responderHost: "fixture-translator")
                },
                executeTurn: HallieTurnExecutor.execute,
                executeRequest: { request, context in
                    try await HallieTurnExecutor.execute(request, context: context)
                },
                performMediaAction: { _ in },
                recordTranscript: { [self] events in
                    transcriptEvents.append(contentsOf: events)
                },
                speakers: { .init(ownerName: "Rick Breen", archivistName: nil, archivistPersonName: nil) })
        }
    }

    @Test func aTranslatorPresenceAfterABiographyBecomesAGraphAnswerInTheShell() async throws {
        let harness = Harness(
            inputs: ["tell me about john hastings", "what did he do for a living?"],
            translations: [.presence(.init(people: ["john hastings"], keywords: ["living"]))])
        let options = try HallieShellCLI.parse(arguments: ["--hallie", "--diagnostics"])
        let code = await HallieShellCLI.run(
            options: options,
            input: { harness.nextInput() },
            output: { harness.output.append($0) },
            dependencies: harness.dependencies())
        #expect(code == HallieShellCLI.ExitCode.success.rawValue)
        #expect(harness.translatedQuestions == ["what did John Hastings do for a living?"])

        let answers = harness.transcriptEvents.filter { $0.kind == .assistant }
        #expect(answers.count == 2, Comment(rawValue: "\(answers.map(\.text))"))
        let second = try #require(answers.last)
        #expect(second.route == "graph", Comment(rawValue: second.text))
        #expect(second.outcome == "answered", Comment(rawValue: second.text))
        #expect(second.queryDescription?.contains("keyword=") != true, Comment(rawValue: second.queryDescription ?? "nil"))
        #expect(harness.output.contains { $0.hasPrefix("mode gate: read “what did John Hastings do for a living?” as a family-tree question") },
                Comment(rawValue: harness.output.joined(separator: "\n")))
        #expect(harness.output.contains("mode: tree (sticky)"), Comment(rawValue: harness.output.joined(separator: "\n")))
    }
}
