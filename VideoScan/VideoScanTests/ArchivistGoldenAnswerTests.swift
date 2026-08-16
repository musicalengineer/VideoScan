import Foundation
import Testing
@testable import VideoScan

// MARK: - Family Archivist golden-answer acceptance tests
//
// This is deliberately a level above NLQueryTests. Those tests prove that a
// sentence becomes the expected query structure. These prove that the query
// returns the expected catalog records and count. A translator that drops a
// load-bearing place/event phrase therefore fails even if its people/year
// fields look plausible.

private struct ArchivistGoldenCase: Decodable {
    let id: String
    let input: String
    let expectedSpec: NLQuerySpec
    let expectedInfix: String
    let expectedPaths: [String]
    let expectedCount: Int
    let answerState: String
    let evidence: [String]
}

private struct ArchivistGoldenCorpus: Decodable {
    let schemaVersion: Int
    let cases: [ArchivistGoldenCase]
}

private func loadArchivistGoldenCorpus() throws -> ArchivistGoldenCorpus {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()     // VideoScanTests
        .deletingLastPathComponent()     // VideoScan
        .deletingLastPathComponent()     // repo root
        .appendingPathComponent("tests/archivist_golden_answers.json")
    return try JSONDecoder().decode(
        ArchivistGoldenCorpus.self,
        from: Data(contentsOf: url))
}

@MainActor
private func makeArchivistGoldenCatalog() -> [VideoRecord] {
    func video(
        _ path: String,
        people: [String] = [],
        captions: [String] = []
    ) -> VideoRecord {
        let record = VideoRecord()
        record.fullPath = path
        record.directory = (path as NSString).deletingLastPathComponent
        record.filename = (path as NSString).lastPathComponent
        record.streamTypeRaw = StreamType.videoAndAudio.rawValue
        record.confirmedByUserPeople = people.map {
            ConfirmedTag(name: $0, confirmedAt: Date(timeIntervalSince1970: 0))
        }
        record.sceneCaptions = captions.map {
            SceneCaption(timestamp: 0, text: $0)
        }
        return record
    }

    return [
        video("/Golden/1992/Cape/donna_timmy_beach.mov",
              people: ["Donna", "Timmy"],
              captions: ["Donna and Timmy at the Cape Cod beach"]),
        video("/Golden/1994/Cape/donna_family_cottage.mov",
              people: ["Donna"],
              captions: ["Family afternoon down the Cape"]),
        video("/Golden/1996/Cape/donna_boardwalk.mov",
              people: ["Donna"],
              captions: ["Donna on the Cape boardwalk"]),
        video("/Golden/1993/Westford/donna_garden.mov",
              people: ["Donna"],
              captions: ["Donna in the garden"]),
        video("/Golden/1991/Home/dad_breen_workshop.mov",
              people: ["Dad Breen"],
              captions: ["Dad Breen in his workshop"]),
        video("/Golden/1990/Home/christmas_morning.mov",
              captions: ["Christmas morning opening presents"]),
        video("/Golden/1996/Home/christmas_morning.mov",
              captions: ["Christmas morning opening presents"]),
        video("/Golden/1993/Home/dan_red_bicycle.mov",
              people: ["Dan"],
              captions: ["Dan opens a red bicycle"]),
        video("/Golden/1993/Home/dan_blue_bicycle.mov",
              people: ["Dan"],
              captions: ["Dan rides a blue bicycle"]),
    ]
}

@MainActor
private func goldenResultPaths(
    spec: NLQuerySpec,
    records: [VideoRecord],
    index: CatalogSearchIndex
) -> (query: NLQuery, infix: String, paths: Set<String>, count: Int) {
    let query = NLQueryNormalizer.normalize(spec)
    let infix = NLQueryComposer.infixString(for: query)
    let matches = index.filter(records: records, query: infix)
    return (query, infix, Set(matches.map(\.fullPath)),
            index.count(records: records, query: infix))
}

@MainActor
@Suite("Family Archivist golden answers", .serialized)
struct ArchivistGoldenAnswerTests {

    @Test func corpusIsReviewableAndInternallyConsistent() throws {
        let corpus = try loadArchivistGoldenCorpus()
        #expect(corpus.schemaVersion == 1)
        #expect(corpus.cases.count == 5)
        #expect(Set(corpus.cases.map(\.id)).count == corpus.cases.count)
        for testCase in corpus.cases {
            #expect(!testCase.input.isEmpty, "\(testCase.id): missing user question")
            #expect(testCase.expectedCount == testCase.expectedPaths.count,
                    "\(testCase.id): count and path oracle disagree")
            #expect(testCase.answerState == "answered")
            #expect(!testCase.evidence.isEmpty,
                    "\(testCase.id): every answer needs stated evidence")
        }
    }

    /// Oracle sensor: the reviewed specs must compose through production
    /// code and return the exact reviewed records. This stays deterministic,
    /// fast, and LLM-free in every ordinary test run.
    @Test func reviewedSpecsReturnExactGoldenAnswers() throws {
        let records = makeArchivistGoldenCatalog()
        let index = CatalogSearchIndex()
        index.rebuild(records: records)

        for testCase in try loadArchivistGoldenCorpus().cases {
            let result = goldenResultPaths(
                spec: testCase.expectedSpec, records: records, index: index)
            #expect(result.infix == testCase.expectedInfix,
                    "\(testCase.id): composed query changed")
            #expect(result.paths == Set(testCase.expectedPaths),
                    "\(testCase.id): got \(result.paths.sorted()), expected \(testCase.expectedPaths.sorted())")
            #expect(result.count == testCase.expectedCount,
                    "\(testCase.id): count() disagrees with golden answer")
            #expect((result.query.intent == .count) ==
                    (testCase.expectedSpec.intent == "count"),
                    "\(testCase.id): answer intent changed")
        }
    }

    /// Small latency sensor for the complete normalized-query → indexed
    /// answer path. Large-catalog scaling remains covered by the existing
    /// 100k CatalogSearchIndex performance tests.
    @Test func goldenAnswerPathStaysInteractive() throws {
        let records = makeArchivistGoldenCatalog()
        let index = CatalogSearchIndex()
        index.rebuild(records: records)

        let started = ContinuousClock.now
        for _ in 0..<100 {
            for testCase in try loadArchivistGoldenCorpus().cases {
                _ = goldenResultPaths(
                    spec: testCase.expectedSpec, records: records, index: index)
            }
        }
        let elapsed = started.duration(to: .now)
        #expect(elapsed < .milliseconds(250),
                "500 golden-answer searches exceeded the 250 ms local budget: \(elapsed)")
    }
}

// This is the intentional red/green TDD layer. It is opt-in because it needs
// the M5 ollama service and is not deterministic CI material. Unlike the older
// translator audition, it grades every load-bearing keyword by executing the
// translated query and comparing the final answer set exactly.
@MainActor
@Suite("Family Archivist live golden-answer eval", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["NL_GOLDEN_EVAL"] == "1"))
struct ArchivistLiveGoldenAnswerTests {

    @Test(.timeLimit(.minutes(5)))
    func realTranslatorReturnsExactGoldenAnswers() async throws {
        let corpus = try loadArchivistGoldenCorpus()
        let records = makeArchivistGoldenCatalog()
        let index = CatalogSearchIndex()
        index.rebuild(records: records)
        var brain = OllamaQueryTranslator(transport: .curl)
        if let host = ProcessInfo.processInfo.environment["NL_EVAL_HOST"],
           !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            brain.host = host
        }
        var rows: [[String: Any]] = []
        var passes = 0

        for testCase in corpus.cases {
            var row: [String: Any] = ["id": testCase.id, "input": testCase.input]
            do {
                let translated = try await brain.translate(testCase.input)
                let result = goldenResultPaths(
                    spec: translated, records: records, index: index)
                let exact = result.paths == Set(testCase.expectedPaths)
                    && result.count == testCase.expectedCount
                    && result.query.intent.rawValue == testCase.expectedSpec.intent
                if exact { passes += 1 }
                row["pass"] = exact
                row["gotInfix"] = result.infix
                row["wantInfix"] = testCase.expectedInfix
                row["gotPaths"] = result.paths.sorted()
                row["wantPaths"] = testCase.expectedPaths.sorted()
                #expect(exact,
                        "\(testCase.id): translated as '\(result.infix)', returned \(result.paths.sorted())")
            } catch {
                row["pass"] = false
                row["error"] = "\(error)"
                Issue.record("\(testCase.id): translator failed: \(error)")
            }
            rows.append(row)
        }

        let stamp = ISO8601DateFormatter().string(from: Date())
        let report: [String: Any] = [
            "brain": brain.displayName,
            "when": stamp,
            "passes": passes,
            "total": corpus.cases.count,
            "contract": "exact final record set and answer intent",
            "cases": rows,
        ]
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("tools/search-eval")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let safeStamp = stamp.replacingOccurrences(of: ":", with: "-")
        let output = directory.appendingPathComponent(
            "golden-answers-\(safeStamp).json")
        try JSONSerialization.data(
            withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output)
        print("NL golden answers: \(passes)/\(corpus.cases.count) exact — \(output.path)")

        #expect(passes == corpus.cases.count,
                "translator is still red: \(passes)/\(corpus.cases.count) exact; see \(output.path)")
    }
}
