import Foundation
import Testing
@testable import VideoScan

@MainActor
@Suite("Hallie live-miss shell boundary", .serialized)
struct HallieLiveMissShellTests {
    private final class Harness: @unchecked Sendable {
        var inputs: [String]
        var output: [String] = []
        var translatedQuestions: [String] = []
        var mediaActions: [HallieShellCLI.MediaAction] = []
        var transcriptEvents: [HallieTranscriptEvent] = []
        var pronunciationWrites: [HallieAppTurnCoordinator.PronunciationWrite] = []
        var drillStore = PronunciationDrillStore()
        var drillSaveCount = 0
        var speakerLoads = 0
        var capturedSpeakers: HallieTurnExecutor.Speakers?
        let injectedSpeakers = HallieTurnExecutor.Speakers(
            ownerName: "Injected Owner",
            archivistName: "Injected Hallie",
            ownerFamilySearchID: "INJECTED-FSID"
        )
        var lexicon = HalliePronunciationLexicon(entries: [
            .init(written: "Latta", spoken: "LAT-uh"),
        ])

        init(inputs: [String] = []) {
            self.inputs = inputs
        }

        func nextInput() -> String? {
            inputs.isEmpty ? nil : inputs.removeFirst()
        }

        func dependencies() -> HallieShellCLI.Dependencies {
            HallieShellCLI.Dependencies(
                loadCatalog: { _ in [] },
                loadProfiles: {
                    .loaded([
                        POIProfile(
                            name: "Latta",
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
                performMediaAction: { [self] action in
                    mediaActions.append(action)
                },
                recordTranscript: { [self] events in
                    transcriptEvents.append(contentsOf: events)
                },
                speakers: { [self] in
                    speakerLoads += 1
                    return injectedSpeakers
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

    private struct DefaultsPoison {
        private let defaults: UserDefaults
        private let saved: [(String, Any?)]

        init(defaults: UserDefaults = .standard) {
            self.defaults = defaults
            let values: [(String, String)] = [
                (HallieTurnExecutor.Speakers.ownerDefaultsKey, "POISON OWNER"),
                (HallieTurnExecutor.Speakers.archivistNameDefaultsKey, "POISON ARCHIVIST"),
                (HallieTurnExecutor.Speakers.archivistPersonNameDefaultsKey, "POISON PERSON"),
                (HallieTurnExecutor.Speakers.ownerFamilySearchIDDefaultsKey, "POISON-FSID"),
            ]
            saved = values.map { key, _ in (key, defaults.object(forKey: key)) }
            for (key, value) in values {
                defaults.set(value, forKey: key)
            }
        }

        func restore() {
            for (key, value) in saved {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
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

    /// The shell must carry its injected identity all the way through the
    /// executor boundary. This specifically fails if Session or its render /
    /// turn context silently reloads process UserDefaults.
    @Test func poisonedDefaultsCannotReplaceInjectedSpeakers() async throws {
        let poison = DefaultsPoison()
        defer { poison.restore() }

        let harness = Harness(inputs: ["who is in the archive?"])
        let dependencies = HallieShellCLI.Dependencies(
            loadCatalog: { _ in [] },
            loadProfiles: { .loaded([]) },
            loadGraph: { _ in nil },
            translateAST: { question, _ in
                harness.translatedQuestions.append(question)
                return .init(
                    ast: .presence(.init(people: ["Donna"])),
                    responderHost: "fixture"
                )
            },
            executeTurn: { _, context in
                harness.capturedSpeakers = context.speakers
                return .init(
                    route: .presence,
                    outcome: .answered,
                    prose: "captured \(context.speakers.ownerName ?? "none")",
                    basisLine: "Basis: fixture",
                    queryDescription: "fixture",
                    citations: [],
                    catalogPersonName: nil
                )
            },
            performMediaAction: { _ in },
            speakers: {
                harness.speakerLoads += 1
                return harness.injectedSpeakers
            }
        )
        let code = await HallieShellCLI.run(
            options: HallieShellCLI.Options(),
            input: harness.nextInput,
            output: { harness.output.append($0) },
            dependencies: dependencies
        )

        #expect(code == HallieShellCLI.ExitCode.success.rawValue)
        #expect(harness.speakerLoads == 1)
        #expect(harness.capturedSpeakers == harness.injectedSpeakers)
        #expect(harness.output.contains("captured Injected Owner"))
        #expect(harness.translatedQuestions == ["who is in the archive?"])
        #expect(harness.mediaActions.isEmpty)
        #expect(harness.pronunciationWrites.isEmpty)
        #expect(harness.drillSaveCount == 0)
    }

    /// Isolation/sensor contract for the no-remember shell used by the live
    /// corpus. A taught alternative must be useful for the rest of this one
    /// interactive session, including the drill picker, but must never reach
    /// defaults, pronunciation storage, the drill sheet, translation, media,
    /// reset state, or the next shell session.
    @Test func transientPronunciationSurvivesInteractiveTurnsButNotResetOrFreshSession() async throws {
        let poison = DefaultsPoison()
        defer { poison.restore() }

        let harness = Harness(inputs: [
            "Latta is prounounced like Ladder but with Laddah or Lattah "
                + "short a first ah second, like ladder but latt ah",
            "tell me latta pronounciations",
            "what pronunciations do you have?",
            "let's practice names",
            "no",
            ":reset",
            "tell me latta pronounciations",
        ])
        harness.drillStore.set(
            name: "Latta",
            status: .alternativesPending,
            alternatives: ["STALE-store-value"]
        )
        let code = await HallieShellCLI.run(
            options: HallieShellCLI.Options(),
            input: harness.nextInput,
            output: { harness.output.append($0) },
            dependencies: harness.dependencies()
        )

        #expect(code == HallieShellCLI.ExitCode.success.rawValue)
        #expect(harness.speakerLoads == 1)
        let text = harness.output.joined(separator: "\n")
        let resetSections = text.components(separatedBy: "reset: conversation forgotten")
        let beforeReset = try #require(resetSections.first)
        let afterReset = try #require(resetSections.last)
        #expect(resetSections.count == 2)

        // Teach, direct query, and list all read the transient alternatives.
        #expect(beforeReset.contains("I'll use that for this session only"))
        #expect(beforeReset.contains("I say Latta as LAT-tah (or LAD-dah)"))
        #expect(beforeReset.contains("Latta as LAT-tah"))

        // The active drill's bare "no" opens a picker seeded from the same
        // transient alternatives. :reset must pre-empt and clear both modes.
        #expect(beforeReset.contains("1 name to go"))
        #expect(beforeReset.contains("Next name: Latta"))
        #expect(beforeReset.contains("Here are a few ways to say Latta"))
        #expect(beforeReset.contains("LAT-tah"))
        #expect(beforeReset.contains("LAD-dah"))
        #expect(afterReset.contains("I say Latta as LAT-uh"))
        #expect(!afterReset.contains("LAT-tah"))
        #expect(!afterReset.contains("LAD-dah"))

        let fresh = Harness(inputs: ["tell me latta pronounciations"])
        let freshCode = await HallieShellCLI.run(
            options: HallieShellCLI.Options(),
            input: fresh.nextInput,
            output: { fresh.output.append($0) },
            dependencies: fresh.dependencies()
        )
        let freshText = fresh.output.joined(separator: "\n")
        #expect(freshCode == HallieShellCLI.ExitCode.success.rawValue)
        #expect(fresh.speakerLoads == 1)
        #expect(freshText.contains("I say Latta as LAT-uh"))
        #expect(!freshText.contains("LAT-tah"))
        #expect(!freshText.contains("LAD-dah"))

        for value in ["POISON OWNER", "POISON ARCHIVIST", "POISON PERSON", "POISON-FSID"] {
            #expect(!text.contains(value))
            #expect(!freshText.contains(value))
        }
        #expect(harness.translatedQuestions.isEmpty)
        #expect(fresh.translatedQuestions.isEmpty)
        #expect(harness.pronunciationWrites.isEmpty)
        #expect(fresh.pronunciationWrites.isEmpty)
        #expect(harness.drillSaveCount == 0)
        #expect(fresh.drillSaveCount == 0)
        #expect(harness.mediaActions.isEmpty)
        #expect(fresh.mediaActions.isEmpty)
    }
}
