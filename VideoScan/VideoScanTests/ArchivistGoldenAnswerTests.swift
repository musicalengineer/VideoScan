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

/// QueryAST-v2 golden case: raw translator text in, final answer out.
private struct ArchivistGoldenASTCase: Decodable {
    struct Continuation: Decodable {
        /// "cyberBrain:<id>", "gedcom:<pointer>", or "profile:<stableID>".
        let select: String
        let expectedOutcome: String
        let expectedProse: String?
        let expectedBasisContains: String?
    }

    let id: String
    let input: String
    let modelOutput: String
    let expectedOutcome: String
    let expectedCount: Int?
    let expectedPaths: [String]?
    let expectedProseContains: String?
    let expectedBasisContains: String?
    let expectedTranslatorNotes: [String]?
    let expectedChipLabels: [String]?
    let continuation: Continuation?
    let evidence: [String]
}

private struct ArchivistGoldenCorpus: Decodable {
    let schemaVersion: Int
    let cases: [ArchivistGoldenCase]
    let astCases: [ArchivistGoldenASTCase]
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

// MARK: - QueryAST-v2 fixture (Hallie log 2026-08-17 shapes)
//
// The catalog spells the place the way Rick's files do ("Cape-1992-archive",
// "CapeCod_June_1997"); the family tree has two Richard Harding Breens; the
// CyberBrain knows both as "Rick". Everything is synthetic — no family data.

private let goldenFamilyTree = """
0 HEAD
0 @I1@ INDI
1 NAME Richard Harding /Breen/ Sr
1 SEX M
1 BIRT
2 DATE 12 MAR 1931
1 FAMS @F1@
0 @I2@ INDI
1 NAME Richard Harding /Breen/ Jr
1 SEX M
1 BIRT
2 DATE 4 JUL 1962
1 FAMC @F1@
0 @I3@ INDI
1 NAME Mary /Breen/
1 SEX F
1 FAMS @F1@
0 @F1@ FAM
1 HUSB @I1@
1 WIFE @I3@
1 CHIL @I2@
0 TRLR
"""

private func makeGoldenCyberBrain() throws -> CyberBrainIndex {
    try CyberBrainIndex(archive: .init(
        archiveID: "golden-fixture",
        displayName: "Golden fixture CyberBrain",
        people: [
            CyberBrainPerson(
                id: "person.rick.sr", gedcomPersonID: "@I1@",
                canonicalName: "Richard Harding Breen",
                aliases: ["Rick", "Big Rick"]),
            CyberBrainPerson(
                id: "person.rick.jr", gedcomPersonID: "@I2@",
                canonicalName: "Richard Harding Breen",
                aliases: ["Rick", "Ricky"]),
        ],
        sources: []))
}

private func makeGoldenPresenceRecords() -> [ArchivistPresenceRecordSnapshot] {
    let stamp = Date(timeIntervalSince1970: 1_700_000_000)
    func record(
        _ path: String, people: [String],
        streamType: StreamType = .videoAndAudio
    ) -> ArchivistPresenceRecordSnapshot {
        ArchivistPresenceRecordSnapshot(
            fullPath: path,
            directory: (path as NSString).deletingLastPathComponent,
            volumeName: "LaCie",
            streamTypeRaw: streamType.rawValue,
            confirmedPeople: people.map {
                ConfirmedTag(name: $0, confirmedAt: stamp)
            })
    }
    return [
        record("/Volumes/LaCie/Cape-1992-archive.mkv", people: ["Donna"]),
        record("/Volumes/LaCie/CapeCod_June_1997.mp4", people: ["Donna"]),
        record("/Volumes/LaCie/Donna-CapeCod-1990s_prob4_1.mov", people: ["Donna"]),
        record("/Volumes/LaCie/Cape-1993/reel.mov", people: ["Donna", "Rick"]),
        record("/Volumes/LaCie/cape-1992-edit.mov", people: ["Donna"]),
        record("/Volumes/LaCie/Cape-2004-archive.mkv", people: ["Donna"]),
        record("/Volumes/LaCie/Down the Road 1995.mov", people: ["Donna"]),
        record("/Volumes/LaCie/1998/donna_birthday.mov", people: ["Donna"]),
        record("/Volumes/LaCie/Cape-1994-rick.mov", people: ["Rick"]),
        record("/Volumes/LaCie/audio/donna_interview_1996.wav",
               people: ["Donna"], streamType: .audioOnly),
    ]
}

private func makeGoldenASTContext() throws -> HallieTurnExecutor.Context {
    HallieTurnExecutor.Context(
        presenceRecords: makeGoldenPresenceRecords(),
        profiles: [.init(stableID: "profile-rick", canonicalName: "Rick")],
        graph: GedcomFamilyGraph(gedcomText: goldenFamilyTree),
        cyberBrain: try makeGoldenCyberBrain())
}

private func goldenCandidateID(_ select: String) -> HallieTurnExecutor.CandidateID? {
    let parts = select.split(separator: ":", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { return nil }
    switch parts[0] {
    case "cyberBrain": return .cyberBrainPersonID(parts[1])
    case "gedcom": return .gedcomPersonID(parts[1])
    case "profile": return .profileStableID(parts[1])
    default: return nil
    }
}

private func goldenOutcomeName(_ outcome: HallieTurnExecutor.Outcome) -> String {
    switch outcome {
    case .answered: return "answered"
    case .declined: return "declined"
    case .unsupported: return "unsupported"
    case .needsClarification: return "needsClarification"
    }
}

/// Grades one executed turn against a v2 golden case. Shared by the
/// deterministic run (modelOutput) and the live translator run.
@MainActor
private func gradeGoldenAST(
    _ testCase: ArchivistGoldenASTCase,
    ast: ArchivistQueryAST,
    context: HallieTurnExecutor.Context,
    label: String
) async throws {
    let result = try await HallieTurnExecutor.execute(
        HallieTurnExecutor.Request(intent: .init(
            originalQuestion: testCase.input, ast: ast)),
        context: context)
    #expect(goldenOutcomeName(result.outcome) == testCase.expectedOutcome,
            "\(label): outcome \(result.outcome), prose '\(result.prose)', basis '\(result.basisLine)'")
    if let prose = testCase.expectedProseContains {
        #expect(result.prose.contains(prose),
                "\(label): prose '\(result.prose)'")
    }
    if let basis = testCase.expectedBasisContains {
        let allBasis = ([result.basisLine]
            + result.citations.flatMap { $0.bases.map(\.summary) })
            .joined(separator: " | ")
        #expect(allBasis.contains(basis), "\(label): basis '\(allBasis)'")
    }
    if let paths = testCase.expectedPaths {
        // Citations are capped at 25; every golden set is smaller.
        #expect(Set(result.citations.map(\.fullPath)) == Set(paths),
                "\(label): got \(result.citations.map(\.fullPath).sorted())")
    }
    if let count = testCase.expectedCount {
        #expect(result.prose.contains("\(count) catalog item"),
                "\(label): count not in prose '\(result.prose)'")
    }
    if let labels = testCase.expectedChipLabels {
        #expect(result.clarification?.candidates.map(\.label) == labels,
                "\(label): chips \(result.clarification?.candidates.map(\.label) ?? [])")
    }
    if let continuation = testCase.continuation {
        let pending = try #require(result.clarification, "\(label): no clarification to continue")
        let selected = try #require(goldenCandidateID(continuation.select),
                                    "\(label): bad continuation selector")
        let continued = try await HallieTurnExecutor.continue(
            pending: pending, selecting: selected, context: context)
        #expect(goldenOutcomeName(continued.outcome) == continuation.expectedOutcome,
                "\(label): continued outcome \(continued.outcome), prose '\(continued.prose)'")
        if let prose = continuation.expectedProse {
            #expect(continued.prose == prose, "\(label): continued prose '\(continued.prose)'")
        }
        if let basis = continuation.expectedBasisContains {
            #expect(continued.basisLine.contains(basis),
                    "\(label): continued basis '\(continued.basisLine)'")
        }
    }
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
        #expect(corpus.schemaVersion == 2)
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
        #expect(corpus.astCases.count == 3)
        #expect(Set(corpus.astCases.map(\.id)).count == corpus.astCases.count)
        for testCase in corpus.astCases {
            #expect(!testCase.input.isEmpty, "\(testCase.id): missing user question")
            #expect(!testCase.evidence.isEmpty,
                    "\(testCase.id): every answer needs stated evidence")
            if let paths = testCase.expectedPaths {
                #expect(testCase.expectedCount == paths.count,
                        "\(testCase.id): count and path oracle disagree")
            }
            // Raw model text must be JSON the tolerant decoder accepts.
            _ = try ArchivistQueryAST.decodeTranslatorOutput(
                Data(testCase.modelOutput.utf8))
        }
    }

    /// QueryAST-v2 oracle: the RAW translator text (with the model's real
    /// quirks) decodes, executes deterministically, and lands on the reviewed
    /// final answer — including clarification chips and their continuation.
    @Test func reviewedModelOutputsReturnExactGoldenAnswers() async throws {
        let corpus = try loadArchivistGoldenCorpus()
        for testCase in corpus.astCases {
            let context = try makeGoldenASTContext()
            let decoded = try ArchivistQueryAST.decodeTranslatorOutput(
                Data(testCase.modelOutput.utf8))
            if let notes = testCase.expectedTranslatorNotes {
                #expect(decoded.notes == notes, "\(testCase.id): notes \(decoded.notes)")
            }
            try await gradeGoldenAST(
                testCase, ast: decoded.ast, context: context, label: testCase.id)
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

    /// v2 counterpart: the live translator's AST for each astCase must land
    /// on the same final answer as the reviewed model output.
    @Test(.timeLimit(.minutes(5)))
    func realTranslatorASTReturnsExactGoldenAnswers() async throws {
        let corpus = try loadArchivistGoldenCorpus()
        var brain = OllamaQueryTranslator(transport: .curl)
        if let host = ProcessInfo.processInfo.environment["NL_EVAL_HOST"],
           !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            brain.host = host
        }
        if let model = ProcessInfo.processInfo.environment["NL_EVAL_MODEL"],
           !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            brain.model = model
        }
        for testCase in corpus.astCases {
            do {
                let ast = try await brain.translateAST(testCase.input)
                print("NL golden AST \(testCase.id): \(HallieTurnExecutor.description(of: ast))")
                try await gradeGoldenAST(
                    testCase, ast: ast, context: try makeGoldenASTContext(),
                    label: "\(testCase.id) (live)")
            } catch {
                Issue.record("\(testCase.id): translator failed: \(error)")
            }
        }
    }
}
