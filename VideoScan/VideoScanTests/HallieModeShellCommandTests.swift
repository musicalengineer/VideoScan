// HallieModeShellCommandTests.swift
// Design §3.6 step 7 — the shell's ":mode": prints the session's mode,
// ":mode tree|catalog" holds it (and the next turn's diagnostics say
// "forced"), ":mode auto" releases, ":reset" clears it. Harness pattern:
// HallieLiveMissShellTests / HallieTwoModeShellTests.

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
@Suite("Shell :mode command (design §3.6 step 7)", .serialized)
struct HallieModeShellCommandTests {
    private final class Harness: @unchecked Sendable {
        var inputs: [String]
        var output: [String] = []
        var translatedQuestions: [String] = []
        var transcriptEvents: [HallieTranscriptEvent] = []
        let graph = GedcomFamilyGraph(gedcomText: tree)

        init(inputs: [String]) {
            self.inputs = inputs
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
                    throw NLTranslatorError.badResponse("no fixture translation")
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

    private func run(_ inputs: [String], diagnostics: Bool = true) async throws -> Harness {
        let harness = Harness(inputs: inputs)
        let options = try HallieShellCLI.parse(
            arguments: diagnostics ? ["--hallie", "--diagnostics"] : ["--hallie"])
        let code = await HallieShellCLI.run(
            options: options,
            input: { harness.nextInput() },
            output: { harness.output.append($0) },
            dependencies: harness.dependencies())
        #expect(code == HallieShellCLI.ExitCode.success.rawValue)
        return harness
    }

    @Test func modeForcesAndResetClears() async throws {
        let harness = try await run([
            ":mode", ":mode tree", ":mode", ":mode bogus", ":mode auto", ":mode",
            ":mode catalog", ":mode", ":reset", ":mode", ":quit",
        ])
        // Forcing echoes the new state, so ":mode tree" then ":mode" print
        // the same line twice.
        let modeLines = harness.output.filter { $0.hasPrefix("mode: ") || $0.hasPrefix("usage: :mode") }
        #expect(modeLines == [
            "mode: unknown (automatic)",
            "mode: tree (forced)", "mode: tree (forced)",
            "usage: :mode [tree|catalog|auto]",
            "mode: unknown (automatic)", "mode: unknown (automatic)",
            "mode: catalog (forced)", "mode: catalog (forced)",
            "mode: unknown (automatic)",
        ], Comment(rawValue: harness.output.joined(separator: "\n")))
        #expect(harness.translatedQuestions.isEmpty)
    }

    @Test func aHeldModeShowsAsForcedInTheNextTurnsDiagnostics() async throws {
        let harness = try await run([":mode tree", "tell me about john hastings", ":quit"])
        // The biography is a local graph run; the diagnostics line for the
        // turn reports the forced verdict, the same words ":mode" printed.
        let forcedLines = harness.output.filter { $0 == "mode: tree (forced)" }
        #expect(forcedLines.count == 2, Comment(rawValue: harness.output.joined(separator: "\n")))
        let answers = harness.transcriptEvents.filter { $0.kind == .assistant }
        #expect(answers.last?.route == "graph", Comment(rawValue: answers.last?.text ?? "nil"))
        #expect(harness.translatedQuestions.isEmpty)
    }

    @Test func helpMentionsMode() async throws {
        let harness = try await run([":help", ":quit"], diagnostics: false)
        #expect(harness.output.contains { $0.contains(":mode tree|catalog|auto") })
    }
}
