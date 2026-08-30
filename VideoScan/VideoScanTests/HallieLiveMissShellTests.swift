import Foundation
import Testing
@testable import VideoScan

@MainActor
@Suite("Hallie live-miss shell boundary", .serialized)
struct HallieLiveMissShellTests {
    private final class Harness {
        var output: [String] = []
        var translatedQuestions: [String] = []
        var mediaActions: [HallieShellCLI.MediaAction] = []
        var transcriptEvents: [HallieTranscriptEvent] = []
        var pronunciationWrites: [HallieAppTurnCoordinator.PronunciationWrite] = []
        var drillStore = PronunciationDrillStore()
        var drillSaveCount = 0
        var lexicon = HalliePronunciationLexicon.shipped

        func dependencies() -> HallieShellCLI.Dependencies {
            HallieShellCLI.Dependencies(
                loadCatalog: { _ in [] },
                loadProfiles: {
                    .loaded([
                        POIProfile(
                            name: "Eileen Latta",
                            referencePath: "/isolated/poi"
                        ),
                    ])
                },
                loadGraph: { _ in nil },
                translateAST: { [self] question, _ in
                    translatedQuestions.append(question)
                    throw HarnessError.unexpectedTranslation
                },
                executeTurn: HallieTurnExecutor.execute,
                mediaURLIsAvailable: { _ in false },
                tryPerformMediaAction: { [self] action in
                    mediaActions.append(action)
                    return false
                },
                performMediaAction: { _ in },
                recordTranscript: { [self] events in
                    transcriptEvents.append(contentsOf: events)
                },
                speakers: {
                    .init(
                        ownerName: "Rick Breen",
                        archivistName: "Hallie Mae",
                        ownerFamilySearchID: "GVQV-NW3"
                    )
                },
                recordPronunciation: { [self] write in
                    pronunciationWrites.append(write)
                },
                loadDrillStore: { [self] in drillStore },
                saveDrillStore: { [self] store, _ in
                    drillStore = store
                    drillSaveCount += 1
                },
                loadLexicon: { [self] in lexicon }
            )
        }
    }

    private enum HarnessError: LocalizedError {
        case unexpectedTranslation

        var errorDescription: String? {
            "pronunciation prompt escaped to translation"
        }
    }

    /// SENSOR for live misses #14/#15/#17/#18. The exact corpus prompts
    /// must be handled locally before translation, surname reference, or
    /// catalog routing. Eval mode omits `--remember`, so even the injected
    /// write seams must remain silent.
    @Test func exactPronunciationPromptsStayLocalAndReturnReadBacks() async throws {
        let cases: [(prompt: String, description: String, required: [String])] = [
            (
                "Latta should be pronounced with a short a on the La",
                "pronunciation hint",
                ["Latta", "LAT-uh", "short a"]
            ),
            (
                "tell me latta pronounciations",
                "pronunciation question",
                ["Latta", "LAT-uh"]
            ),
            (
                "Latta is prounounced like Ladder but with Laddah or Lattah "
                    + "short a first ah second, like ladder but latt ah",
                "pronunciation",
                ["Latta", "LAT-tah", "LAD-dah", "short a, then ah"]
            ),
            (
                "the family name \"Latta\" should be pronounced with a short a, "
                    + "like in Ladder, but it would be \"Latt uh\"",
                "pronunciation",
                ["Latta", "LAT-uh", "short a"]
            ),
        ]

        for testCase in cases {
            let harness = Harness()
            let options = try HallieShellCLI.parse(arguments: [
                "--hallie", "--once", testCase.prompt,
            ])

            let code = await HallieShellCLI.run(
                options: options,
                output: { harness.output.append($0) },
                dependencies: harness.dependencies()
            )

            let answer = try #require(
                harness.transcriptEvents.last { $0.kind == .assistant },
                Comment(rawValue: testCase.prompt)
            )
            #expect(
                code == HallieShellCLI.ExitCode.success.rawValue,
                Comment(rawValue: testCase.prompt)
            )
            #expect(answer.route == "telling", Comment(rawValue: testCase.prompt))
            #expect(answer.outcome == "answered", Comment(rawValue: testCase.prompt))
            #expect(
                answer.queryDescription == testCase.description,
                Comment(rawValue: testCase.prompt)
            )
            for required in testCase.required {
                #expect(
                    answer.text.localizedCaseInsensitiveContains(required),
                    Comment(rawValue: "\(testCase.prompt) missing \(required): \(answer.text)")
                )
            }
            #expect(
                harness.translatedQuestions.isEmpty,
                Comment(rawValue: "pronunciation escaped to translation: \(testCase.prompt)")
            )
            #expect(harness.mediaActions.isEmpty)
            #expect(answer.mediaEvidence.isEmpty)
            #expect(
                harness.pronunciationWrites.isEmpty,
                Comment(rawValue: "eval-mode prompt wrote pronunciation state: \(testCase.prompt)")
            )
            #expect(
                harness.drillSaveCount == 0,
                Comment(rawValue: "eval-mode prompt wrote drill state: \(testCase.prompt)")
            )
        }
    }
}
