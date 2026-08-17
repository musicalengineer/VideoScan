import Foundation
import Testing
@testable import VideoScan

/// Opt-in semantic acceptance test for the exact QueryAST-v2 translator used
/// by Hallie. The ordinary suite remains deterministic and model-free.
///
/// Run locally with:
///
///     NL_AST_EVAL=1 NL_EVAL_HOST=127.0.0.1 xcodebuild test ...
///
/// `NL_EVAL_HOST` is explicit so an M4 model pull is never accidentally
/// evaluated against the historical M5 default.
@Suite("Family Archivist QueryAST-v2 live eval", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["NL_AST_EVAL"] == "1"))
struct ArchivistQueryASTLiveEvalTests {
    private struct Case: Sendable {
        let id: String
        let question: String
        /// Any of these is a correct translation. Most cases have exactly
        /// one; a few accept a benign spelling difference the tolerant
        /// decoder already normalizes ("breens" vs "breen").
        let accepted: [ArchivistQueryAST]

        init(id: String, question: String, expected: ArchivistQueryAST) {
            self.id = id
            self.question = question
            self.accepted = [expected]
        }

        init(id: String, question: String, accepted: [ArchivistQueryAST]) {
            self.id = id
            self.question = question
            self.accepted = accepted
        }
    }

    private static let cases: [Case] = [
        Case(
            id: "presence-person-year",
            question: "Show me Donna in 1994.",
            expected: .presence(.init(
                people: ["donna"], yearStart: 1994, yearEnd: 1994))),
        Case(
            id: "presence-era-kind-topic",
            question: "Show me Christmas videos from the 1990s.",
            expected: .presence(.init(
                yearStart: 1990, yearEnd: 1999, mediaKind: .video,
                keywords: ["christmas"]))),
        Case(
            id: "temporal-selection",
            question: "How old was Timmy here?",
            expected: .temporal(.init(
                subject: "timmy", operation: .age,
                reference: .currentSelection))),
        Case(
            id: "temporal-year",
            question: "How old was Timmy in 1998?",
            expected: .temporal(.init(
                subject: "timmy", operation: .age,
                reference: .explicitYear(1998)))),
        Case(
            id: "aggregate-default",
            question: "Who appears most often with Donna?",
            expected: .aggregate(.init(
                operation: .coOccurrence, anchorPeople: ["donna"]))),
        Case(
            id: "aggregate-explicit-limit",
            question: "Which three people appear most often with Donna?",
            expected: .aggregate(.init(
                operation: .coOccurrence, anchorPeople: ["donna"], limit: 3))),
        Case(
            id: "graph-biography",
            question: "Who is Ellen?",
            expected: .graph(.init(
                people: ["ellen"], operation: .biography))),
        Case(
            id: "graph-birth",
            question: "When was Ellen born?",
            expected: .graph(.init(
                people: ["ellen"], operation: .birth))),
        Case(
            id: "graph-death",
            question: "When did Ellen die?",
            expected: .graph(.init(
                people: ["ellen"], operation: .death))),
        Case(
            id: "graph-kinship",
            question: "Who is Ellen's father?",
            expected: .graph(.init(
                people: ["ellen"], operation: .kinship,
                relation: .father))),
        Case(
            id: "event-spoken",
            question: "What happened when someone said surprise?",
            expected: .event(.init(transcript: ["surprise"]))),
        Case(
            id: "cross-person-action-object",
            question: "Find Dan opening the red bike.",
            expected: .cross(.init(
                people: ["dan"], keywords: ["opening", "red bike"]))),

        // Rick's demo to Donna, 2026-08-17 (verbatim phrasing).
        Case(
            id: "demo-count-donna-videos",
            question: "count how many videos of donna we have?",
            accepted: [
                .presence(.init(people: ["donna"], mediaKind: .video)),
                .presence(.init(people: ["donna"])),
            ]),
        Case(
            id: "demo-family-tree-person",
            question: "show donna's family tree",
            expected: .graph(.init(people: ["donna"], operation: .familyTree))),
        Case(
            id: "demo-family-tree-no-apostrophe",
            question: "show ricks family tree",
            accepted: [
                .graph(.init(people: ["ricks"], operation: .familyTree)),
                .graph(.init(people: ["rick"], operation: .familyTree)),
            ]),
        Case(
            id: "demo-family-tree-surname",
            question: "get me the family tree for the breens",
            accepted: [
                .graph(.init(people: [], operation: .familyTree, surname: "breen")),
                .graph(.init(people: [], operation: .familyTree, surname: "breens")),
                .graph(.init(people: [], operation: .familyTree, surname: "Breen")),
            ]),
        Case(
            id: "demo-family-tree-whole",
            question: "show family tree",
            expected: .graph(.init(people: [], operation: .familyTree))),
        Case(
            id: "demo-maternal-great-grandmother",
            question: "who was donna's great grandmother on her maternal side?",
            expected: .graph(.init(
                people: ["donna"], operation: .kinship,
                relation: .greatGrandmother, side: .maternal))),
        Case(
            id: "demo-cousins",
            question: "who are rick's cousins?",
            accepted: [
                .graph(.init(people: ["rick"], operation: .kinship, relation: .cousins)),
                .graph(.init(people: ["rick"], operation: .kinship, relation: .cousin)),
            ]),
        Case(
            id: "demo-timmy-as-a-baby-saying-peekaboo",
            question: "show timmy as a baby saying peekaboo",
            accepted: [
                .cross(.init(people: ["timmy"], keywords: ["as a baby"],
                             transcript: ["peekaboo"])),
                .cross(.init(people: ["timmy"], keywords: ["baby"],
                             transcript: ["peekaboo"])),
                .cross(.init(people: ["timmy"], mediaKind: .video,
                             keywords: ["as a baby"], transcript: ["peekaboo"])),
            ]),
    ]

    @Test(.timeLimit(.minutes(10)))
    func currentModelRoutesRepresentativeQuestionsExactly() async throws {
        var brain = OllamaQueryTranslator(transport: .curl)
        if let host = ProcessInfo.processInfo.environment["NL_EVAL_HOST"],
           !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            brain.host = host
        }
        if let model = ProcessInfo.processInfo.environment["NL_EVAL_MODEL"],
           !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            brain.model = model
        }
        brain.timeoutSeconds = 90

        var failures: [String] = []
        var passes = 0
        for testCase in Self.cases {
            do {
                let actual = try await brain.translateAST(testCase.question)
                if testCase.accepted.contains(actual) {
                    passes += 1
                    print("NL AST eval PASS \(testCase.id): \(HallieTurnExecutor.description(of: actual))")
                } else {
                    failures.append(
                        "\(testCase.id): got \(String(describing: actual)); "
                            + "accepted \(testCase.accepted.map { String(describing: $0) })")
                }
            } catch {
                failures.append("\(testCase.id): \(error)")
            }
        }
        print("NL AST eval: \(passes)/\(Self.cases.count) exact — \(brain.displayName)")

        if !failures.isEmpty {
            Issue.record(Comment(rawValue:
                "QueryAST-v2 semantic failures:\n"
                    + failures.joined(separator: "\n")))
        }
        #expect(failures.isEmpty)
    }
}
