import Testing
import Foundation
@testable import VideoScan

// MARK: - NL search translator tests (family archivist P1, 2026-08-01)
//
// Two tiers:
//  1. Deterministic (always on): normalizer fail-closed behavior, the
//     composer's grammar output, corpus internal consistency, and the
//     round-trip sensor — every composed string must tokenize into the
//     EXACT intended structure via the real pfTokenizeSearchQuery, so
//     no translator output can ever mint an unintended field token.
//  2. Live eval (NL_EVAL=1): runs the golden corpus through the real
//     ollama brain and persists graded results under tools/search-eval/
//     — the audition record the Jim/Fred retrospective said we must
//     keep. Never runs in CI; the suite stays LLM-free by default.

// MARK: Corpus plumbing

private struct CorpusCase: Decodable {
    let id: String
    let input: String
    let expect: NLQuerySpec       // expect keys are a subset of the wire format
    let infix: String
}

private struct Corpus: Decodable {
    let cases: [CorpusCase]
}

private func loadCorpus() throws -> Corpus {
    // <repo>/VideoScan/VideoScanTests/NLQueryTests.swift → <repo>/tests/…
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()     // VideoScanTests
        .deletingLastPathComponent()     // VideoScan
        .deletingLastPathComponent()     // repo root
        .appendingPathComponent("tests/search_nl_cases.json")
    return try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
}

// MARK: - Deterministic tier

@Suite("NLQuery normalizer + composer")
struct NLQueryTests {

    // Corpus self-consistency: normalizing each case's expected spec and
    // composing it must yield exactly the case's documented infix string.
    // Pins corpus, normalizer, and composer against each other.
    @Test func corpusExpectationsComposeToDocumentedInfix() throws {
        let corpus = try loadCorpus()
        #expect(corpus.cases.count >= 15)
        for testCase in corpus.cases {
            let composed = NLQueryComposer.infixString(
                for: NLQueryNormalizer.normalize(testCase.expect))
            #expect(composed == testCase.infix,
                    "\(testCase.id): composed \"\(composed)\" != documented \"\(testCase.infix)\"")
        }
    }

    // Round-trip sensor: every composed corpus string must tokenize into
    // exactly the intended structure — field tokens for people/transcript/
    // type, one yearRange when years are set, substrings ONLY for
    // keywords. A regression here means translator output could smuggle
    // or lose structure in the real search path.
    @Test func composedStringsTokenizeWithoutStructureLeaks() throws {
        for testCase in try loadCorpus().cases {
            let query = NLQueryNormalizer.normalize(testCase.expect)
            let tokens = pfTokenizeSearchQuery(NLQueryComposer.infixString(for: query))

            var fields = 0, yearRanges = 0, substrings = 0
            for token in tokens {
                switch token {
                case .field: fields += 1
                case .yearRange: yearRanges += 1
                case .substring: substrings += 1
                }
            }
            let expectedFields = query.people.count + query.transcript.count
                + (query.mediaKind == nil ? 0 : 1)
            #expect(fields == expectedFields, "\(testCase.id): field tokens \(fields) != \(expectedFields)")
            #expect(yearRanges == (query.years == nil ? 0 : 1), "\(testCase.id): yearRange count wrong")
            #expect(substrings == query.keywords.count, "\(testCase.id): substrings \(substrings) != keywords \(query.keywords.count)")
        }
    }

    // A value can never mint grammar structure: colons and quotes are
    // data, not syntax, no matter where the brain puts them.
    @Test func fieldSyntaxInValuesIsNeutralized() {
        let hostile = NLQuerySpec(
            people: ["type:junk"],
            keywords: ["notes:secret stuff", "say \"boo\""],
            transcript: ["ocr:1234"],
            intent: "filter")
        let query = NLQueryNormalizer.normalize(hostile)
        let composed = NLQueryComposer.infixString(for: query)
        let tokens = pfTokenizeSearchQuery(composed)

        // people/transcript values got their colons stripped → each is a
        // single people:/transcript: field whose VALUE is plain text; the
        // multi-word keyword is re-quoted as one substring phrase.
        for token in tokens {
            if case .field(let name, let value) = token {
                #expect(name == .people || name == .transcript)
                #expect(!value.contains(":"))
            }
        }
        #expect(!composed.contains("notes:"))
        #expect(!composed.contains("ocr:"))
    }

    @Test func multiWordPersonSplitsIntoPerWordTokens() {
        let query = NLQueryNormalizer.normalize(
            NLQuerySpec(people: ["Dad Breen"], intent: "filter"))
        #expect(query.people == ["dad", "breen"])
        #expect(NLQueryComposer.infixString(for: query) == "people:dad people:breen")
    }

    @Test func yearsClampSwapAndHalfOpen() {
        // Outside the grammar's 1900...2099 → dropped.
        #expect(NLQueryNormalizer.normalizeYears(start: 1850, end: nil) == nil)
        // Reversed pair → swapped.
        #expect(NLQueryNormalizer.normalizeYears(start: 1995, end: 1992) == 1992...1995)
        // Half-open → single year.
        #expect(NLQueryNormalizer.normalizeYears(start: nil, end: 1987) == 1987...1987)
        // One sane + one insane bound → the sane one survives alone.
        #expect(NLQueryNormalizer.normalizeYears(start: 1992, end: 99999) == 1992...1992)
    }

    @Test func mediaKindSynonymsMapAndUnknownDrops() {
        func kind(_ raw: String) -> String? {
            NLQueryNormalizer.normalize(NLQuerySpec(mediaKind: raw)).mediaKind
        }
        #expect(kind("Movies") == "video")
        #expect(kind("recordings") == "audio")
        #expect(kind("silent") == "video-only")
        #expect(kind("hologram") == nil)      // unknown → no filter, never a guess
    }

    @Test func listAndLengthCapsHold() {
        let flood = NLQuerySpec(
            people: (0..<20).map { "person\($0)" },
            keywords: [String(repeating: "x", count: 500)],
            intent: "filter")
        let query = NLQueryNormalizer.normalize(flood)
        #expect(query.people.count == NLQueryNormalizer.maxListItems)
        #expect(query.keywords[0].count == NLQueryNormalizer.maxValueLength)
    }

    @Test func emptySpecReportsEmptyForSubstringFallback() {
        let query = NLQueryNormalizer.normalize(NLQuerySpec(intent: "count"))
        #expect(query.isEmpty)
        #expect(query.intent == .count)
        #expect(NLQueryComposer.infixString(for: query).isEmpty)
    }
}

// MARK: - Live eval tier (audition record; NL_EVAL=1 only)

@Suite("NL translator live eval",
       .enabled(if: ProcessInfo.processInfo.environment["NL_EVAL"] == "1"))
struct NLTranslatorLiveEvalTests {

    /// Runs every corpus case through the real brain, grades the
    /// STRUCTURAL fields strictly (people / years / mediaKind / intent —
    /// inventing these is the failure that matters) and keywords
    /// leniently (reported, not graded: passthrough of odd words is
    /// acceptable), then persists the run under tools/search-eval/ so
    /// hiring decisions have a written record.
    @Test(.timeLimit(.minutes(10)))
    func gradeBrainAgainstGoldenCorpus() async throws {
        let corpus = try loadCorpus()
        // curl transport: the headless test host has no Local Network
        // TCC grant, so URLSession to a .local host silently times out.
        let brain = OllamaQueryTranslator(transport: .curl)
        var rows: [[String: Any]] = []
        var strictPasses = 0

        for testCase in corpus.cases {
            var row: [String: Any] = ["id": testCase.id, "input": testCase.input]
            do {
                let got = NLQueryNormalizer.normalize(try await brain.translate(testCase.input))
                let want = NLQueryNormalizer.normalize(testCase.expect)
                let strict = got.people == want.people
                    && got.years == want.years
                    && got.mediaKind == want.mediaKind
                    && got.intent == want.intent
                if strict { strictPasses += 1 }
                row["strictPass"] = strict
                row["got"] = NLQueryComposer.infixString(for: got)
                row["want"] = testCase.infix
            } catch {
                row["strictPass"] = false
                row["error"] = "\(error)"
            }
            rows.append(row)
        }

        let stamp = ISO8601DateFormatter().string(from: Date())
        let report: [String: Any] = [
            "brain": brain.displayName,
            "when": stamp,
            "strictPasses": strictPasses,
            "total": corpus.cases.count,
            "cases": rows,
        ]
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tools/search-eval")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safeStamp = stamp.replacingOccurrences(of: ":", with: "-")
        let out = dir.appendingPathComponent("eval-\(safeStamp).json")
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: out)
        print("NL eval: \(strictPasses)/\(corpus.cases.count) strict — results at \(out.path)")

        // The bar to beat before this brain drives a UI: ~2/3 strict.
        #expect(Double(strictPasses) >= Double(corpus.cases.count) * 0.66,
                "brain below hiring bar — see \(out.path)")
    }
}
