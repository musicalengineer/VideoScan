import Foundation
import Testing
@testable import VideoScan

/// The headless shell shares the app's conversation memory: "play the first
/// one" acts on the citations it just printed (through the media-action
/// seam), "show more" pages, refinements re-run without the translator, and
/// capability questions answer locally. Transcript routes are plain strings.
@MainActor
@Suite("Hallie shell follow-ups", .serialized)
struct HallieShellCLIFollowUpTests {
    private final class Harness {
        var inputs: [String]
        var output: [String] = []
        var translatedQuestions: [String] = []
        var mediaActions: [HallieShellCLI.MediaAction] = []
        var transcriptEvents: [HallieTranscriptEvent] = []
        var translations: [ArchivistQueryAST]
        let records: [VideoRecord]

        init(inputs: [String], records: [VideoRecord], translations: [ArchivistQueryAST]) {
            self.inputs = inputs
            self.records = records
            self.translations = translations
        }

        func dependencies() -> HallieShellCLI.Dependencies {
            HallieShellCLI.Dependencies(
                loadCatalog: { [self] _ in records },
                loadProfiles: { .loaded([]) },
                loadGraph: { _ in nil },
                translateAST: { [self] question, _ in
                    translatedQuestions.append(question)
                    guard !translations.isEmpty else {
                        throw NLTranslatorError.badResponse("no fixture translation")
                    }
                    return .init(ast: translations.removeFirst(),
                                 responderHost: "fixture-translator")
                },
                executeTurn: HallieTurnExecutor.execute,
                executeRequest: { request, context in
                    try await HallieTurnExecutor.execute(request, context: context)
                },
                tryPerformMediaAction: { [self] action in
                    mediaActions.append(action)
                    return true
                },
                performMediaAction: { _ in },
                recordTranscript: { [self] events in
                    transcriptEvents.append(contentsOf: events)
                })
        }

        func nextInput() -> String? {
            inputs.isEmpty ? nil : inputs.removeFirst()
        }
    }

    private func records() -> [VideoRecord] {
        (0..<30).map { index in
            let record = VideoRecord()
            record.fullPath = "/isolated/\(1990 + index / 3)/donna_\(index).mov"
            record.filename = "donna_\(index).mov"
            record.streamTypeRaw = StreamType.videoAndAudio.rawValue
            record.confirmedByUserPeople = [
                ConfirmedTag(name: "Donna", confirmedAt: Date(timeIntervalSince1970: 0)),
            ]
            return record
        }
    }

    @Test func aFullDemoConversationRunsThroughTheShell() async throws {
        let harness = Harness(
            inputs: [
                "count how many videos of donna we have?",
                "play one of them, say the first one",
                "show more",
                "and in the 90s?",
                "can we change donna's biography?",
                "play it",
                ":quit",
            ],
            records: records(),
            translations: [.presence(.init(people: ["donna"], mediaKind: .video))])
        let options = try HallieShellCLI.parse(arguments: ["--hallie"])
        let code = await HallieShellCLI.run(
            options: options,
            input: { harness.nextInput() },
            output: { harness.output.append($0) },
            dependencies: harness.dependencies())

        #expect(code == 0)
        // Exactly one translation for six questions.
        #expect(harness.translatedQuestions == ["count how many videos of donna we have?"])
        #expect(harness.output.contains("I found 30 catalog items matching that."))

        // "play the first one" opened citation #1 through the seam.
        #expect(harness.output.contains("Playing item 1 from my last answer: “donna_0.mov”."))
        #expect(harness.mediaActions.first == .play(URL(fileURLWithPath: "/isolated/1990/donna_0.mov")))

        // "show more" paged; "and in the 90s?" refined without the model.
        #expect(harness.output.contains("Here are 5 more (items 26–30 of 30)."))
        #expect(harness.output.contains { $0.contains("refining your last question (years → 1990–1999)") })
        #expect(harness.output.contains("interpreted: shape=presence (local)"))

        // Capability question answered locally with an offer line.
        #expect(harness.output.contains { $0.hasPrefix("I can't edit biographies or family facts yet") })
        #expect(harness.output.contains("offer: ask “who is Donna?”"))

        // "play it" after the refinement plays the refined set's first item.
        #expect(harness.mediaActions.count == 2)

        let routes = harness.transcriptEvents.compactMap(\.route)
        #expect(routes == ["presence", "follow-up", "presence", "presence", "capability", "follow-up"])
        let outcomes = harness.transcriptEvents.compactMap(\.outcome)
        #expect(outcomes == ["answered", "answered", "answered", "answered", "unsupported", "answered"])
        let offered = harness.transcriptEvents.compactMap { $0.offeredActions.first }
        #expect(offered == ["Show what I have for Donna"])
    }

    @Test func onceModeExitCodesReflectLocalAnswers() async throws {
        for (question, expected) in [
            ("play one of them, say the first one", HallieShellCLI.ExitCode.noEvidence),
            ("can we change donna's biography?", .unsupportedShape),
            ("show more", .noEvidence),
        ] {
            let harness = Harness(inputs: [], records: records(), translations: [])
            let options = try HallieShellCLI.parse(arguments: ["--hallie", "--once", question])
            let code = await HallieShellCLI.run(
                options: options, output: { harness.output.append($0) },
                dependencies: harness.dependencies())
            #expect(code == expected.rawValue, Comment(rawValue: question))
            #expect(harness.translatedQuestions.isEmpty, Comment(rawValue: question))
            #expect(harness.mediaActions.isEmpty, Comment(rawValue: question))
        }
    }
}
