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
        // Since 5ce7c75b the shell keeps diagnostics ("refining: …",
        // "interpreted: …", "offer: …") out of the conversation; the
        // refinement is visible in what Hallie SAYS.
        #expect(harness.output.contains("Narrowed to 1990–1999 — 30 catalog items."))
        #expect(!harness.output.contains("interpreted: shape=presence (local)"))

        // Capability question answered locally, with the offer in the prose.
        #expect(harness.output.contains { $0.hasPrefix("I can't edit biographies or family facts yet") })
        #expect(harness.output.contains { $0.contains("show what I currently have for Donna") })

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

    /// A count still carries the question it counted (2026-09-02, eval
    /// cc007 / cs015): "and the newest?" re-runs it sorted by date, and
    /// "ok show me the second one" is then the second in THAT order.
    @Test func aCountThenTheNewestThenTheSecondOneChainsWithoutTheModel() async throws {
        let harness = Harness(
            inputs: [
                "how many videos of donna do we have from the 90s?",
                "and the newest?",
                "ok show me the second one",
                "and the oldest?",
                ":quit",
            ],
            records: records(),
            translations: [.presence(.init(people: ["donna"], yearStart: 1990, yearEnd: 1999, mediaKind: .video))])
        let options = try HallieShellCLI.parse(arguments: ["--hallie"])
        let code = await HallieShellCLI.run(
            options: options,
            input: { harness.nextInput() },
            output: { harness.output.append($0) },
            dependencies: harness.dependencies())

        #expect(code == 0)
        #expect(harness.translatedQuestions == ["how many videos of donna do we have from the 90s?"])
        // 30 records, paths /isolated/1990…/1999/donna_N.mov: the newest are
        // donna_27/28/29 (1999); ties break by name, so 27 is first.
        #expect(harness.output.contains("The newest of the 30 matches for Donna · 1990–1999 is donna_27.mov (1999)."),
                Comment(rawValue: harness.output.joined(separator: "\n")))
        #expect(harness.output.contains("Showing item 2 from my last answer: “donna_28.mov”."))
        #expect(harness.output.contains("showing donna_28.mov — /isolated/1999/donna_28.mov"))
        #expect(harness.output.contains("The oldest of the 30 matches for Donna · 1990–1999 is donna_0.mov (1990)."))
        let routes = harness.transcriptEvents.compactMap(\.route)
        #expect(routes == ["presence", "presence", "follow-up", "presence"])
    }

    /// A refinement that found nothing does not take the last shown list
    /// away: "ok show me the second one" still means the second item that
    /// was actually listed (eval cs015).
    @Test func theSecondOneAfterAnEmptyRefinementShowsTheLastListShown() async throws {
        let harness = Harness(
            inputs: [
                "do we have anything of donna?",
                "narrow that to winter",
                "ok show me the second one",
                ":quit",
            ],
            records: records(),
            translations: [.presence(.init(people: ["donna"]))])
        let options = try HallieShellCLI.parse(arguments: ["--hallie"])
        _ = await HallieShellCLI.run(
            options: options,
            input: { harness.nextInput() },
            output: { harness.output.append($0) },
            dependencies: harness.dependencies())

        #expect(harness.translatedQuestions == ["do we have anything of donna?"])
        #expect(harness.output.contains { $0.contains("Winter — nothing matched.") },
                Comment(rawValue: harness.output.joined(separator: "\n")))
        #expect(harness.output.contains("Showing item 2 from the last list I showed you: “donna_1.mov”."),
                Comment(rawValue: harness.output.joined(separator: "\n")))
        #expect(harness.output.contains("showing donna_1.mov — /isolated/1990/donna_1.mov"))
    }

    /// With nothing asked yet the superlative is an honest ask, as before.
    @Test func theNewestWithNothingToSortDeclines() async throws {
        let harness = Harness(inputs: ["and the newest?", ":quit"], records: records(), translations: [])
        let options = try HallieShellCLI.parse(arguments: ["--hallie"])
        _ = await HallieShellCLI.run(
            options: options,
            input: { harness.nextInput() },
            output: { harness.output.append($0) },
            dependencies: harness.dependencies())
        #expect(harness.translatedQuestions.isEmpty)
        #expect(harness.output.contains { $0.hasPrefix("Ask me for something first — a search or a count — and then I can pick the newest of it.") })
    }
}
