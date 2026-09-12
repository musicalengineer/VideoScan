// HallieGH184RoutesShellTests.swift
// GH #184 items 4 and 5 through the shell client, with the translator
// forbidden: a bare exact tree name opens the biography and a second-person
// life fact gets the persona reply — neither reaches the model. Sensor for
// the two live misses of 2026-09-11 22:05Z, at the client boundary.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@MainActor
@Suite("GH #184 routes through the shell", .serialized)
struct HallieGH184RoutesShellTests {

    private static let tree = GedcomFamilyGraph(gedcomText: """
    0 HEAD
    0 @I1@ INDI
    1 NAME Hallie Mae /McGill/
    1 SEX F
    1 BIRT
    2 DATE 1876
    2 PLAC Stoughton, Massachusetts
    0 TRLR
    """)

    private final class Harness: @unchecked Sendable {
        var output: [String] = []
        var translatedQuestions: [String] = []
        var transcriptEvents: [HallieTranscriptEvent] = []

        func dependencies() -> HallieShellCLI.Dependencies {
            HallieShellCLI.Dependencies(
                loadCatalog: { _ in [] },
                loadProfiles: {
                    .loaded([POIProfile(name: "Donna", referencePath: "/isolated/poi")])
                },
                loadGraph: { _ in HallieGH184RoutesShellTests.tree },
                translateAST: { [self] question, _ in
                    translatedQuestions.append(question)
                    throw HarnessError.unexpectedTranslation
                },
                executeTurn: HallieTurnExecutor.execute,
                mediaURLIsAvailable: { _ in false },
                performMediaAction: { _ in },
                recordTranscript: { [self] events in
                    transcriptEvents.append(contentsOf: events)
                },
                speakers: { .init(ownerName: "Rick Breen", archivistName: "Hallie Mae") })
        }
    }

    private enum HarnessError: LocalizedError {
        case unexpectedTranslation
        var errorDescription: String? { "the question escaped to the translator" }
    }

    private func answer(_ prompt: String) async throws -> (HallieTranscriptEvent, Harness) {
        let harness = Harness()
        let options = try HallieShellCLI.parse(arguments: ["--hallie", "--once", prompt])
        let code = await HallieShellCLI.run(
            options: options,
            output: { harness.output.append($0) },
            dependencies: harness.dependencies())
        #expect(code == HallieShellCLI.ExitCode.success.rawValue, Comment(rawValue: prompt))
        let event = try #require(harness.transcriptEvents.last { $0.kind == .assistant }, Comment(rawValue: prompt))
        return (event, harness)
    }

    @Test func aBareTreeNameOpensTheBiographyWithoutTheModel() async throws {
        let (event, harness) = try await answer("hallie mae mcgill")
        #expect(harness.translatedQuestions.isEmpty)
        #expect(event.route == "graph")
        #expect(event.outcome == "answered")
        #expect(event.text.contains("Hallie Mae McGill"), Comment(rawValue: event.text))
        #expect(!event.text.lowercased().contains("video"), Comment(rawValue: event.text))
    }

    @Test func whereWereYouBornHallieGetsThePersonaReplyWithoutTheModel() async throws {
        let (event, harness) = try await answer("where were you born, hallie?")
        #expect(harness.translatedQuestions.isEmpty)
        #expect(event.route == "conversation")
        #expect(event.outcome == "answered")
        #expect(event.text.contains("archivist"), Comment(rawValue: event.text))
        #expect(event.text.contains("named after Hallie Mae McGill"), Comment(rawValue: event.text))
        #expect(!event.text.contains("I need to know who you mean"), Comment(rawValue: event.text))
    }
}
