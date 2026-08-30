import Foundation
import Testing
@testable import VideoScan

@MainActor
@Suite("Hallie pronunciation shell sessions", .serialized)
struct HalliePronunciationShellSessionTests {
    private static let lexicon = HalliePronunciationLexicon(entries: [
        .init(written: "Latta", spoken: "LAT-uh"),
    ])

    private final class Harness: @unchecked Sendable {
        var inputs: [String]
        var output: [String] = []
        var recorded = 0
        var saved = 0
        var capturedSpeakers: HallieTurnExecutor.Speakers?

        init(_ inputs: [String]) { self.inputs = inputs }
        func next() -> String? { inputs.isEmpty ? nil : inputs.removeFirst() }
    }

    private func dependencies(_ harness: Harness) -> HallieShellCLI.Dependencies {
        HallieShellCLI.Dependencies(
            loadCatalog: { _ in [] },
            speakers: {
                .init(ownerName: "Rick Breen", archivistName: "Hallie Mae")
            },
            loadProfiles: {
                .loaded([POIProfile(name: "Rick Breen", referencePath: "/fixture")])
            },
            loadGraph: { _ in nil },
            translateAST: { _, _ in throw NLTranslatorError.unreachable("fixture") },
            executeTurn: { _, context in
                harness.capturedSpeakers = context.speakers
                throw NLTranslatorError.unreachable("fixture")
            },
            performMediaAction: { _ in },
            recordPronunciation: { _ in harness.recorded += 1 },
            saveDrillStore: { _, _ in harness.saved += 1 },
            loadLexicon: { Self.lexicon })
    }

    @Test func drillTeachUsesTransientOverlayUntilResetAndNeverWrites() async {
        let harness = Harness([
            "let's practice names",
            "Rick is pronounced REEK",
            "how do you say Rick?",
            ":reset",
            "how do you say Rick?",
        ])
        _ = await HallieShellCLI.run(
            options: HallieShellCLI.Options(), input: harness.next,
            output: { harness.output.append($0) }, dependencies: dependencies(harness))
        let text = harness.output.joined(separator: "\n")
        let resetSections = text.components(separatedBy: "reset: conversation forgotten")
        #expect(resetSections.count == 2)
        #expect(resetSections[0].contains("OK, noted — Rick."))
        #expect(resetSections[0].contains("Kept for this session only"))
        #expect(resetSections[0].contains("I say Rick as REEK"))
        #expect(!resetSections[1].contains("REEK"))
        #expect(harness.recorded == 0 && harness.saved == 0)

        let fresh = Harness(["how do you say Rick?"])
        _ = await HallieShellCLI.run(
            options: HallieShellCLI.Options(), input: fresh.next,
            output: { fresh.output.append($0) }, dependencies: dependencies(fresh))
        #expect(!fresh.output.joined(separator: "\n").contains("REEK"))
        #expect(fresh.recorded == 0 && fresh.saved == 0)
    }

    @Test func sessionCapturesInjectedSpeakersInsteadOfReadingProcessDefaults() async {
        let harness = Harness(["who is in the archive?"])
        let injected = HallieTurnExecutor.Speakers(
            ownerName: "Injected Owner \(UUID().uuidString)",
            archivistName: "Injected Archivist")
        let dependencies = HallieShellCLI.Dependencies(
            loadCatalog: { _ in [] },
            loadProfiles: { .loaded([]) },
            loadGraph: { _ in nil },
            translateAST: { _, _ in
                .init(ast: .presence(.init(people: ["Donna"])), responderHost: "fixture")
            },
            executeTurn: { _, context in
                harness.capturedSpeakers = context.speakers
                return .init(
                    route: .presence, outcome: .answered,
                    prose: "captured \(context.speakers.ownerName ?? "none")",
                    basisLine: "Basis: fixture", queryDescription: "fixture",
                    citations: [], catalogPersonName: nil)
            },
            performMediaAction: { _ in },
            speakers: { injected })
        _ = await HallieShellCLI.run(
            options: HallieShellCLI.Options(), input: harness.next,
            output: { harness.output.append($0) }, dependencies: dependencies)
        #expect(harness.capturedSpeakers == injected)
        #expect(harness.output.contains("captured \(injected.ownerName ?? "none")"))
    }
}
