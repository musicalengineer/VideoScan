import Foundation
import Testing
@testable import VideoScan

/// Live 2026-11-15, Rick's spot test: "tell me of thankful pratt" failed on
/// every cloud brain (sonnet, haiku, opus) with "yearStart must be in
/// 1900...2099", twice each (the repair retry sent the same thing). The cloud
/// copy of the schema carries no numeric bounds (AnthropicSchemaSanitizer), so
/// a cloud model is free to attach years to an ancestor's name; the strict
/// decoder then threw the whole turn away. A year the question never states
/// is not a constraint — the presence lane already drops an in-range one
/// (HallieInventedPresenceYears) — so an out-of-range one is dropped the same
/// way, with a note, and the rest of the translation stands.
@Suite("Hallie: a year the question never states does not fail the turn")
struct HallieUnstatedYearDecodingTests {

    static let question = "tell me of thankful pratt"

    private func reply(shape: String = "presence", start: Int?, end: Int?) -> String {
        var payload = #""people":["thankful pratt"]"#
        if let start { payload += #","yearStart":\#(start)"# }
        if let end { payload += #","yearEnd":\#(end)"# }
        return #"{"payload":{\#(payload)},"shape":"\#(shape)"}"#
    }

    private func interpret(_ json: String, question: String = Self.question) throws -> ArchivistQueryAST {
        let value = try HallieBrainDecoding.interpretation(
            content: json, data: Data(json.utf8), question: question)
        guard case .archive(let ast) = value else {
            Issue.record("expected an archive shape")
            throw CancellationError()
        }
        return ast
    }

    @Test("the live miss: years outside 1900...2099 beside a name are dropped, the name stands",
          arguments: [(1761, 1849), (0, 0), (1700, 1800), (-1, -1), (2100, 2150), (1761, 1994)])
    func outOfRangeUnstatedYearsAreDropped(_ years: (Int, Int)) throws {
        let ast = try interpret(reply(start: years.0, end: years.1))
        guard case .presence(let payload) = ast else {
            Issue.record("expected presence, got \(ast)")
            return
        }
        #expect(payload.people == ["thankful pratt"])
        #expect(payload.yearStart == nil)
        // An in-range year beside it is not this rule's business.
        #expect(payload.yearEnd == (ArchivistQueryAST.yearRange.contains(years.1) ? years.1 : nil))
    }

    @Test("the same through every shape that carries years", arguments: ["presence", "cross", "event"])
    func everyYearCarryingShape(_ shape: String) throws {
        let ast = try interpret(reply(shape: shape, start: 1761, end: 1849))
        switch ast {
        case .presence(let p): #expect(p.yearStart == nil && p.yearEnd == nil)
        case .cross(let p): #expect(p.yearStart == nil && p.yearEnd == nil)
        case .event(let p): #expect(p.yearStart == nil && p.yearEnd == nil)
        default: Issue.record("unexpected shape \(ast)")
        }
    }

    @Test("the archive-only translation takes the same rule")
    func astDecoderToo() throws {
        let json = reply(start: 1761, end: 1849)
        let ast = try HallieBrainDecoding.ast(
            content: json, data: Data(json.utf8), question: Self.question)
        guard case .presence(let payload) = ast else {
            Issue.record("expected presence")
            return
        }
        #expect(payload.yearStart == nil && payload.yearEnd == nil)
    }

    @Test("in tree mode the turn then answers as her biography")
    func treeModeAnswersTheBiography() throws {
        let ast = try interpret(reply(start: 1761, end: 1849))
        let outcome = HallieModeGate.reconcile(
            ast: ast, mode: .tree, question: Self.question, memory: .init())
        guard case .rewrite(let rewritten, _) = outcome,
              case .graph(let graph) = rewritten else {
            Issue.record("expected a rewrite to a family-tree lookup, got \(outcome)")
            return
        }
        #expect(graph.operation == .biography)
        #expect(graph.people == ["thankful pratt"])
    }

    // MARK: Guards — what must NOT change

    @Test("a year the reader did state is still refused, never silently dropped",
          arguments: ["videos of thankful pratt from 1850", "thankful pratt in the 1700s",
                      "thankful pratt when she was young", "thankful pratt last century"])
    func statedTimeStaysStrict(_ question: String) {
        #expect(throws: NLTranslatorError.self) {
            _ = try interpret(reply(start: 1850, end: 1850), question: question)
        }
    }

    @Test("an in-range year is untouched")
    func inRangeYearsSurvive() throws {
        let ast = try interpret(reply(start: 1994, end: 1994))
        guard case .presence(let payload) = ast else {
            Issue.record("expected presence")
            return
        }
        #expect(payload.yearStart == 1994 && payload.yearEnd == 1994)
    }

    @Test("without the question the decoder stays strict")
    func noQuestionNoTolerance() {
        #expect(throws: (any Error).self) {
            _ = try ArchivistQueryAST.decodeTranslatorOutput(Data(reply(start: 1761, end: 1849).utf8))
        }
    }

    @Test("a year that is not a whole number is still a malformed reply",
          arguments: [#""1761""#, "true", "17.5", "[1761]"])
    func nonIntegerYearStillRejected(_ value: String) {
        let json = #"{"payload":{"people":["thankful pratt"],"yearStart":\#(value)},"shape":"presence"}"#
        #expect(throws: NLTranslatorError.self) { _ = try interpret(json) }
    }

    @Test("the drop is noted, naming the field and the year")
    func theDropIsNoted() throws {
        let decoded = try ArchivistQueryAST.decodeTranslatorOutput(
            Data(reply(start: 1761, end: 1849).utf8), question: Self.question)
        #expect(decoded.notes.contains { $0.contains("payload.yearStart") && $0.contains("1761") })
        #expect(decoded.notes.contains { $0.contains("payload.yearEnd") && $0.contains("1849") })
    }

    @Test("nonsense years never crash and never survive", arguments: [
        Int.min, Int.max, -2026, 1, 99, 1899, 2100, 9999, 20261115,
    ])
    func nonsenseYears(_ year: Int) throws {
        let ast = try interpret(reply(start: year, end: year))
        guard case .presence(let payload) = ast else {
            Issue.record("expected presence")
            return
        }
        #expect(payload.yearStart == nil && payload.yearEnd == nil)
    }
}
