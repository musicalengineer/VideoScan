// HallieCloudStructuredOutputTests.swift
//
// Regression for Rick's 2026-11-08 log: every Cloud question failed with
//   HTTP 400: invalid_request_error: tool_choice: type "tool" and "any" are
//   not supported for this model.
// The cloud brain forced one tool call to get schema-shaped JSON; the 5.5
// models refuse a forced tool_choice. It now asks for structured outputs
// (`output_config.format` json_schema) and reads the JSON from a text block.
//
// Dimensions:
//   Logic       — request shape for every op on every menu model; the
//                 sanitizer; text-block decode; refusal / max_tokens.
//   Isolation   — URLProtocol stub only, no network; a refusal or a
//                 truncated reply never reaches the decoder (no repair
//                 retry is spent on it).
//   Truth       — the reply is judged by the same strict decoders: an
//                 out-of-range year the sanitizer let through is still
//                 rejected locally.
//   Sensor      — HallieCloudBrainCanarySensorTests (unchanged gate).
//   Scale / media matrix: N/A — one small text request per question.

import Foundation
import Testing
@testable import VideoScan

/// The cloud models on Hallie's menu.
private let menuModels = ["claude-sonnet-5-5", "claude-opus-5-5", "claude-haiku-5-5"]

private let donna1994 = #"{"shape":"presence","payload":{"people":["donna"],"yearStart":1994,"yearEnd":1994}}"#

/// Keywords Anthropic structured outputs refuse in a schema position.
private let refusedKeywords: Set<String> = [
    "oneOf", "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf",
    "minLength", "maxLength", "maxItems", "uniqueItems",
]

/// Every schema-position problem in `node`, with a JSON-pointer-ish path.
/// Keyword-aware: keys under `properties` are field names, not keywords.
private func schemaProblems(_ node: Any, path: String = "#") -> [String] {
    guard let schema = node as? [String: Any] else { return [] }
    var problems: [String] = []
    let isObject = schema["properties"] != nil || (schema["type"] as? String) == "object"
    if isObject, (schema["additionalProperties"] as? Bool) != false {
        problems.append("\(path): object without additionalProperties false")
    }
    for (keyword, value) in schema {
        if refusedKeywords.contains(keyword) { problems.append("\(path): \(keyword)") }
        if keyword == "minItems", let n = value as? Int, n > 1 { problems.append("\(path): minItems \(n)") }
        switch keyword {
        case "properties", "$defs":
            for (name, child) in value as? [String: Any] ?? [:] {
                problems += schemaProblems(child, path: "\(path)/\(keyword)/\(name)")
            }
        case "anyOf", "allOf", "oneOf":
            for (index, child) in (value as? [Any] ?? []).enumerated() {
                problems += schemaProblems(child, path: "\(path)/\(keyword)/\(index)")
            }
        case "items", "not":
            problems += schemaProblems(value, path: "\(path)/\(keyword)")
        default: break
        }
    }
    return problems
}

private func json(_ data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

// MARK: - Request shape (the regression)

@Suite("Hallie cloud brain — structured outputs request shape")
struct HallieCloudStructuredOutputShapeTests {

    enum Op: String, CaseIterable, Sendable { case translate, translateAST, interpretTurn }

    /// The body the brain actually handed the transport for `op` on `model`.
    private func sentBody(_ op: Op, model: String) async throws -> [String: Any] {
        let (session, token) = hallieCloudStubSession()
        let brain = hallieStubbedCloudBrain(session, model: model)
        // The reply is irrelevant here; only the request is judged.
        switch op {
        case .translate: _ = try? await brain.translate("how many videos are in the catalog?")
        case .translateAST: _ = try? await brain.translateAST("how many videos are in the catalog?")
        case .interpretTurn: _ = try? await brain.interpretTurn("how many videos are in the catalog?")
        }
        let first = try #require(HallieCloudStubLedger.shared.seen(token).first)
        return try json(first.body)
    }

    @Test("no forced tool_choice; output_config json_schema; every object closed",
          arguments: menuModels, Op.allCases)
    func structuredOutputsNotForcedTool(model: String, op: Op) async throws {
        let body = try await sentBody(op, model: model)
        #expect(body["model"] as? String == model)

        if let choice = body["tool_choice"] as? [String: Any] {
            let type = choice["type"] as? String
            #expect(type != "tool" && type != "any", "\(op) on \(model) forces tool_choice \(type ?? "?")")
        }
        #expect(body["tools"] == nil, "\(op) on \(model) still sends tools")

        let config = try #require(body["output_config"] as? [String: Any], "\(op) on \(model): no output_config")
        let format = try #require(config["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        let schema = try #require(format["schema"] as? [String: Any])
        let problems = schemaProblems(schema)
        #expect(problems.isEmpty, "\(op) on \(model): \(problems.prefix(8))")
    }

    @Test("no sampling knobs, no prefill, no thinking override", arguments: Op.allCases)
    func nothingTheModelRefuses(op: Op) async throws {
        let body = try await sentBody(op, model: "claude-sonnet-5-5")
        for knob in ["temperature", "top_p", "top_k", "thinking"] {
            #expect(body[knob] == nil, "\(op) sends \(knob)")
        }
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["user"], "\(op): history or assistant prefill")
    }

    @Test("the system prompt no longer tells the model to call a tool", arguments: Op.allCases)
    func noToolInstruction(op: Op) async throws {
        let body = try await sentBody(op, model: "claude-sonnet-5-5")
        let text = ((body["system"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        #expect(!text.contains("calling the tool"))
        #expect(!text.contains("hallie_answer"))
    }
}

// MARK: - Decode (stubbed replies)

@Suite("Hallie cloud brain — structured outputs decode")
struct HallieCloudStructuredOutputDecodeTests {

    @Test("a text block of JSON decodes to the same plan the local decoder gives")
    func textBlockDecodes() async throws {
        let (session, token) = hallieCloudStubSession()
        HallieCloudStubLedger.shared.queue(token, status: 200, body: hallieStructuredReply(donna1994))
        let cloud = try await hallieStubbedCloudBrain(session).translateAST("show me Donna in 1994")
        let local = try HallieBrainDecoding.ast(
            content: donna1994, data: Data(donna1994.utf8), question: "show me Donna in 1994")
        #expect(cloud == local)
        guard case .presence(let presence) = cloud else {
            Issue.record("expected presence, got \(cloud)"); return
        }
        #expect(presence.people == ["donna"])
        #expect(HallieCloudStubLedger.shared.seen(token).count == 1)
    }

    @Test("translate and interpretTurn read the text block too")
    func otherOpsDecode() async throws {
        let (s1, t1) = hallieCloudStubSession()
        HallieCloudStubLedger.shared.queue(t1, status: 200, body: hallieStructuredReply(
            #"{"people":["donna"],"keywords":[],"transcript":[],"intent":"count","yearStart":null,"yearEnd":null,"mediaKind":null}"#))
        let spec = try await hallieStubbedCloudBrain(s1).translate("how many videos of Donna?")
        #expect(spec.people == ["donna"])

        let (s2, t2) = hallieCloudStubSession()
        HallieCloudStubLedger.shared.queue(t2, status: 200, body: hallieStructuredReply(
            #"{"shape":"conversation","payload":{"kind":"casual"}}"#))
        #expect(try await hallieStubbedCloudBrain(s2).interpretTurn("thanks!") == .conversation(.casual))
    }

    @Test("a thinking block before the text block is ignored")
    func thinkingBlockIgnored() throws {
        let root: [String: Any] = [
            "content": [["type": "thinking", "thinking": "{not json"], ["type": "text", "text": donna1994]],
            "stop_reason": "end_turn",
        ]
        let (content, _) = try AnthropicBrain.structuredAnswer(root)
        #expect(content == donna1994)
    }

    @Test("refusal: a plain HallieBrainError, no decode, no repair retry")
    func refusal() async throws {
        let (session, token) = hallieCloudStubSession()
        HallieCloudStubLedger.shared.queue(
            token, status: 200, body: hallieStructuredReply("I can't help with that.", stopReason: "refusal"))
        await #expect(throws: HallieBrainError.cloudRefused) {
            _ = try await hallieStubbedCloudBrain(session).interpretTurn("how many videos are in the catalog?")
        }
        #expect(HallieCloudStubLedger.shared.seen(token).count == 1)
        #expect(HallieHelperFailure.kind(of: HallieBrainError.cloudRefused) == .unusableAnswer)
        #expect(ArchivistDiagnosticLine.failure(.interpretation, error: HallieBrainError.cloudRefused)
                    .hasSuffix("reason=cloud-refusal"))
    }

    @Test("max_tokens: partial JSON is never decoded, even when the prefix would parse")
    func truncated() async throws {
        let (session, token) = hallieCloudStubSession()
        // A complete-looking object: only stop_reason says it was cut off.
        HallieCloudStubLedger.shared.queue(
            token, status: 200, body: hallieStructuredReply(donna1994, stopReason: "max_tokens"))
        await #expect(throws: HallieBrainError.cloudTruncated) {
            _ = try await hallieStubbedCloudBrain(session).translateAST("show me Donna in 1994")
        }
        #expect(HallieCloudStubLedger.shared.seen(token).count == 1)
        #expect(HallieHelperFailure.message(for: HallieBrainError.cloudTruncated)
                    .contains("didn't search the archive"))
        #expect(ArchivistDiagnosticLine.failure(.interpretation, error: HallieBrainError.cloudTruncated)
                    .hasSuffix("reason=cloud-max-tokens"))
    }

    @Test("compose: a refusal is an error, so the composer falls back to its template")
    func composeRefusal() async {
        let (session, token) = hallieCloudStubSession()
        HallieCloudStubLedger.shared.queue(
            token, status: 200, body: hallieStructuredReply("I won't.", stopReason: "refusal"))
        await #expect(throws: HallieBrainError.cloudRefused) {
            _ = try await hallieStubbedCloudBrain(session).composePlainText(
                system: "You are Hallie.", user: "[c1] 12 videos.", dataClass: .familyText)
        }
        #expect(HallieCloudStubLedger.shared.seen(token).count == 1)
    }

    @Test("truth: a year the sanitizer stopped bounding is still rejected by the local decoder")
    func boundsStillEnforcedLocally() async throws {
        let (session, token) = hallieCloudStubSession()
        let outOfRange = #"{"shape":"presence","payload":{"people":["donna"],"yearStart":99999}}"#
        HallieCloudStubLedger.shared.queue(token, status: 200, body: hallieStructuredReply(outOfRange))
        await #expect(throws: NLTranslatorError.self) {
            _ = try await hallieStubbedCloudBrain(session).translateAST("show me Donna in 99999")
        }
        // The repair retry was spent, as for any decoder rejection.
        #expect(HallieCloudStubLedger.shared.seen(token).count == 2)
    }
}

// MARK: - Sanitizer (pure)

@Suite("Anthropic schema sanitizer")
struct AnthropicSchemaSanitizerTests {

    private func roundTrip(_ schema: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: AnthropicSchemaSanitizer.sanitize(schema))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("drops numeric, string-length and array bounds; keeps minItems 0/1")
    func dropsBounds() throws {
        let out = try roundTrip([
            "type": "object",
            "properties": [
                "year": ["type": "integer", "minimum": 1800, "maximum": 2100, "multipleOf": 1,
                         "exclusiveMinimum": 0, "exclusiveMaximum": 3000],
                "name": ["type": "string", "minLength": 1, "maxLength": 40],
                "one": ["type": "array", "minItems": 1, "maxItems": 6, "items": ["type": "string"]],
                "two": ["type": "array", "minItems": 2, "uniqueItems": true, "items": ["type": "string"]],
            ],
            "required": ["year"],
        ])
        let props = try #require(out["properties"] as? [String: [String: Any]])
        #expect(Set(props["year"]?.keys.map { $0 } ?? []) == ["type"])
        #expect(Set(props["name"]?.keys.map { $0 } ?? []) == ["type"])
        #expect(props["one"]?["minItems"] as? Int == 1)
        #expect(props["one"]?["maxItems"] == nil)
        #expect(props["two"]?["minItems"] == nil)
        #expect(props["two"]?["uniqueItems"] == nil)
        #expect(out["required"] as? [String] == ["year"])
    }

    @Test("every object is closed, nested and in branches; a schema-valued additionalProperties becomes false")
    func closesObjects() throws {
        let out = try roundTrip([
            "anyOf": [
                ["type": "object", "properties": ["a": ["type": "object", "properties": [:]]]],
                ["type": "object", "additionalProperties": true],
                ["type": "object", "additionalProperties": ["type": "string"]],
                ["type": "string"],
            ],
        ])
        let branches = try #require(out["anyOf"] as? [[String: Any]])
        #expect(branches.count == 4)
        #expect(branches[0]["additionalProperties"] as? Bool == false)
        let inner = try #require((branches[0]["properties"] as? [String: [String: Any]])?["a"])
        #expect(inner["additionalProperties"] as? Bool == false)
        #expect(branches[1]["additionalProperties"] as? Bool == false)
        #expect(branches[2]["additionalProperties"] as? Bool == false)
        #expect(branches[3]["additionalProperties"] == nil, "a string is not an object")
        #expect(out["additionalProperties"] == nil, "a bare anyOf root is not itself an object")
    }

    @Test("oneOf becomes anyOf, at the root and nested")
    func oneOfToAnyOf() throws {
        let out = try roundTrip([
            "oneOf": [["type": "object", "properties": ["r": ["oneOf": [["type": "string"], ["type": "null"]]]]]],
        ])
        #expect(out["oneOf"] == nil)
        let branch = try #require((out["anyOf"] as? [[String: Any]])?.first)
        let r = try #require((branch["properties"] as? [String: [String: Any]])?["r"])
        #expect(r["oneOf"] == nil)
        #expect((r["anyOf"] as? [Any])?.count == 2)
    }

    @Test("field NAMES that look like keywords survive; enum/const values are untouched")
    func namesAreNotKeywords() throws {
        let out = try roundTrip([
            "type": "object",
            "properties": [
                "minimum": ["type": "string", "enum": ["maxLength", "oneOf"]],
                "oneOf": ["const": "minimum"],
            ],
        ])
        let props = try #require(out["properties"] as? [String: [String: Any]])
        #expect(props["minimum"]?["enum"] as? [String] == ["maxLength", "oneOf"])
        #expect(props["oneOf"]?["const"] as? String == "minimum")
    }

    @Test("$defs and $ref pass through, sanitized inside")
    func defsAndRefs() throws {
        let out = try roundTrip([
            "type": "object",
            "properties": ["p": ["$ref": "#/$defs/person"]],
            "$defs": ["person": ["type": "object", "properties": ["n": ["type": "string", "minLength": 1]]]],
        ])
        let person = try #require((out["$defs"] as? [String: [String: Any]])?["person"])
        #expect(person["additionalProperties"] as? Bool == false)
        #expect((person["properties"] as? [String: [String: Any]])?["n"]?["minLength"] == nil)
        #expect((out["properties"] as? [String: [String: Any]])?["p"]?["$ref"] as? String == "#/$defs/person")
    }

    @Test("Hallie's real schemas come out clean, and the originals are unchanged",
          arguments: ["spec", "ast", "interpretation"])
    func realSchemas(_ name: String) throws {
        let original: [String: Any] = switch name {
        case "spec": OllamaQueryTranslator.responseSchema
        case "ast": OllamaQueryTranslator.astResponseSchema
        default: OllamaQueryTranslator.interpretationResponseSchema
        }
        let before = try JSONSerialization.data(withJSONObject: original, options: [.sortedKeys])
        let out = try roundTrip(original)
        #expect(schemaProblems(out).isEmpty, "\(schemaProblems(out).prefix(8))")
        let after = try JSONSerialization.data(withJSONObject: original, options: [.sortedKeys])
        #expect(before == after, "sanitize must not mutate the local schema")
        // The local schema still carries the full rules the decoder checks.
        let raw = String(bytes: before, encoding: .utf8) ?? ""
        if name != "spec" { #expect(raw.contains("\"minimum\"") && raw.contains("\"oneOf\"")) }
    }

    @Test("branches that differ only in one enum merge into the union; anything else stays apart")
    func mergesEnumSiblings() throws {
        func branch(_ shape: String, payload: [String: Any]) -> [String: Any] {
            ["type": "object", "properties": ["shape": ["type": "string", "enum": [shape]], "payload": payload],
             "required": ["shape", "payload"]]
        }
        let text: [String: Any] = ["type": "object", "properties": ["k": ["type": "string"]]]
        let other: [String: Any] = ["type": "object", "properties": ["n": ["type": "integer"]]]
        let out = try roundTrip(["oneOf": [
            branch("event", payload: text), branch("presence", payload: other), branch("cross", payload: text),
        ]])
        let branches = try #require(out["anyOf"] as? [[String: Any]])
        let shapes = branches.map { (($0["properties"] as? [String: Any])?["shape"] as? [String: Any])?["enum"] as? [String] }
        #expect(shapes == [["event", "cross"], ["presence"]])

        // Two differing properties: not a union of the branches, so no merge.
        let apart = try roundTrip(["anyOf": [
            ["type": "object", "properties": ["a": ["enum": ["x"]], "b": ["enum": ["1"]]]],
            ["type": "object", "properties": ["a": ["enum": ["y"]], "b": ["enum": ["2"]]]],
        ]])
        #expect((apart["anyOf"] as? [Any])?.count == 2)
        // Differing `required`: not mergeable either.
        let req = try roundTrip(["anyOf": [
            ["type": "object", "properties": ["a": ["enum": ["x"]]], "required": ["a"]],
            ["type": "object", "properties": ["a": ["enum": ["y"]]]],
        ]])
        #expect((req["anyOf"] as? [Any])?.count == 2)
    }

    /// Tripwire for Anthropic's undocumented grammar budget. On 2026-11-08
    /// the unmerged interpretation schema (7 branches, 21 optional
    /// properties) was refused live — "The compiled grammar is too large" —
    /// and the merged one (6 branches, 15 optional) was accepted. If a new
    /// shape pushes past what was accepted, re-run the live smoke before
    /// raising these numbers.
    @Test("grammar budget: the cloud schemas stay at or under the size accepted live")
    func grammarBudget() {
        func optional(_ node: Any) -> Int {
            guard let schema = node as? [String: Any] else { return 0 }
            var count = 0
            if let props = schema["properties"] as? [String: Any] {
                count += Set(props.keys).subtracting(schema["required"] as? [String] ?? []).count
                count += props.values.map(optional).reduce(0, +)
            }
            for key in ["anyOf", "allOf"] { count += (schema[key] as? [Any] ?? []).map(optional).reduce(0, +) }
            if let items = schema["items"] { count += optional(items) }
            return count
        }
        let interp = AnthropicSchemaSanitizer.sanitize(OllamaQueryTranslator.interpretationResponseSchema)
        #expect((interp["anyOf"] as? [Any])?.count ?? 99 <= 6)
        #expect(optional(interp) <= 15, "\(optional(interp)) optional properties")
        let ast = AnthropicSchemaSanitizer.sanitize(OllamaQueryTranslator.astResponseSchema)
        #expect(optional(ast) <= 15)
    }

    @Test("scale: sanitizing the interpretation schema 200 times (about 140 ms in Debug) stays under a second")
    func scale() {
        let schema = OllamaQueryTranslator.interpretationResponseSchema
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for _ in 0..<200 { _ = AnthropicSchemaSanitizer.sanitize(schema) }
        }
        #expect(elapsed < .seconds(1), "\(elapsed)")
    }
}
