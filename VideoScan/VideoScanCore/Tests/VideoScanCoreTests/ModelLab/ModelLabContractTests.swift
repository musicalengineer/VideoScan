// ModelLabContractTests.swift — the output contracts and the assertion
// mapping (video_llm_lab §3.3, §4 "Harness", §6). Dimensions:
//   LOGIC — every family decodes its valid fixture; invalid and adversarial
//           fixtures (extra key, wrong type, year 19910, reversed range,
//           window end < start, bad family word, oversize response) each
//           yield `.schemaInvalid(reason)` and never a partial value; empty
//           cues are fine. The mapping carries prompt hash, host, frame
//           times and elapsed into evidenceJSON, puts selfConfidence there
//           and ONLY there, and spells `by` as machine:<id>@r<rev>.

import Foundation
import Testing
@testable import VideoScanCore

private let window = SampleWindow(startS: 120, endS: 180, frameTimesS: [120, 131, 140, 150, 160, 170], audioRange: 120...180)

private func decode(_ family: FieldFamily, _ json: String) -> ContractDecodeResult {
    ContractDecoder.decode(family: family, json: Data(json.utf8), window: window)
}

private func invalidReason(_ result: ContractDecodeResult, sourceLocation: SourceLocation = #_sourceLocation) -> String {
    switch result {
    case .schemaInvalid(let reason): return reason
    case .output(let output):
        Issue.record("expected schemaInvalid, decoded \(output.value)", sourceLocation: sourceLocation)
        return ""
    }
}

private func output(_ result: ContractDecodeResult, sourceLocation: SourceLocation = #_sourceLocation) throws -> ApproachOutput {
    switch result {
    case .output(let output): return output
    case .schemaInvalid(let reason):
        Issue.record("expected a decode, got schemaInvalid: \(reason)", sourceLocation: sourceLocation)
        throw ModelLabTestFailure.unexpectedInvalid(reason)
    }
}

enum ModelLabTestFailure: Error { case unexpectedInvalid(String) }

enum ContractFixture {
    static let era = """
    { "family": "era", "window": [120.0, 180.0],
      "yearRange": [1991, 1995], "rationale": "4:3, camcorder OSD 'SP', boxy sedan, CRT television",
      "cues": [{"kind": "technical", "text": "analog tracking lines at frame bottom", "atS": 131.0},
               {"kind": "cultural",  "text": "Charlotte Hornets starter jacket",       "atS": 140.0}],
      "selfConfidence": 0.7 }
    """
    static let roomFeatures = """
    { "family": "roomFeatures", "window": [120.0, 180.0],
      "setting": "indoor", "locationType": "residential living room",
      "features": ["green shag carpet", "brick fireplace", "oak panelling"], "selfConfidence": 0.8 }
    """
    static let ocrDate = """
    { "family": "ocrDate", "window": [120.0, 180.0], "text": "JUN 21 1991", "atS": 131.0,
      "year": 1991, "month": 6, "day": 21, "selfConfidence": 0.9 }
    """
    static let ocrText = """
    { "family": "ocrText", "window": [120.0, 180.0],
      "lines": [{"text": "SP", "atS": 120.0}, {"text": "PLAY", "atS": 150.0}], "selfConfidence": 0.6 }
    """
    static let scene = """
    { "family": "scene", "window": [120.0, 180.0],
      "description": "A child opens presents beside a decorated tree; adults watch from a sofa.", "selfConfidence": 0.5 }
    """
    static let occasionKind = """
    { "family": "occasionKind", "window": [120.0, 180.0], "kind": "christmas",
      "rationale": "decorated tree, wrapped presents, stockings on the mantel",
      "cues": [{"kind": "environmental", "text": "decorated tree", "atS": 125.0}], "selfConfidence": 0.75 }
    """
}

@Suite("ModelLab — output contracts: valid fixtures decode to typed values")
struct ModelLabContractValidTests {

    @Test("era: window, yearRange, rationale, cues, selfConfidence; the raw JSON rides along untouched")
    func era() throws {
        let out = try output(decode(.era, ContractFixture.era))
        guard case .era(let era) = out.value else { Issue.record("not an era value"); return }
        #expect(era.yearRange == 1991...1995)
        #expect(era.window == ContractWindow(startS: 120, endS: 180))
        #expect(era.cues.count == 2 && era.cues[1].kind == .cultural && era.cues[1].atS == 140)
        #expect(era.selfConfidence == 0.7)
        #expect(out.family == .era && out.window == window)
        #expect(out.rawJSON == Data(ContractFixture.era.utf8), "raw bytes are kept byte-for-byte for the notebook")
    }

    @Test("roomFeatures: setting, locationType, features")
    func roomFeatures() throws {
        let out = try output(decode(.roomFeatures, ContractFixture.roomFeatures))
        guard case .roomFeatures(let room) = out.value else { Issue.record("not a roomFeatures value"); return }
        #expect(room.setting == .indoor && room.locationType == "residential living room")
        #expect(room.features == ["green shag carpet", "brick fireplace", "oak panelling"])
    }

    @Test("ocrDate: the literal text read, the frame it was read at, and optional parsed parts")
    func ocrDate() throws {
        let out = try output(decode(.ocrDate, ContractFixture.ocrDate))
        guard case .ocrDate(let date) = out.value else { Issue.record("not an ocrDate value"); return }
        #expect(date.text == "JUN 21 1991" && date.atS == 131 && date.year == 1991 && date.month == 6 && date.day == 21)
        let textOnly = try output(decode(.ocrDate, """
        {"family":"ocrDate","window":[120,180],"text":"06 21 '91","atS":131,"selfConfidence":0.4}
        """))
        guard case .ocrDate(let partial) = textOnly.value else { Issue.record("not an ocrDate value"); return }
        #expect(partial.year == nil && partial.month == nil && partial.day == nil, "unparsed is honest, not invented")
    }

    @Test("ocrText: timed lines; an empty list is a valid 'nothing legible'")
    func ocrText() throws {
        let out = try output(decode(.ocrText, ContractFixture.ocrText))
        guard case .ocrText(let text) = out.value else { Issue.record("not an ocrText value"); return }
        #expect(text.lines.map(\.text) == ["SP", "PLAY"])
        let empty = try output(decode(.ocrText, #"{"family":"ocrText","window":[120,180],"lines":[],"selfConfidence":0.9}"#))
        guard case .ocrText(let none) = empty.value else { Issue.record("not an ocrText value"); return }
        #expect(none.lines.isEmpty)
    }

    @Test("scene: free text, reported only")
    func scene() throws {
        let out = try output(decode(.scene, ContractFixture.scene))
        guard case .scene(let scene) = out.value else { Issue.record("not a scene value"); return }
        #expect(scene.description.hasPrefix("A child opens presents"))
    }

    @Test("occasionKind: one of the nine categories, or mixed / unknown")
    func occasionKind() throws {
        let out = try output(decode(.occasionKind, ContractFixture.occasionKind))
        guard case .occasionKind(let occasion) = out.value else { Issue.record("not an occasionKind value"); return }
        #expect(occasion.kind == .christmas && occasion.cues.count == 1)
        #expect(OccasionKind.allCases.count == 11, "nine EventCategoryRules categories + mixed + unknown")
        let unknown = try output(decode(.occasionKind, """
        {"family":"occasionKind","window":[120,180],"kind":"unknown","rationale":"nothing distinctive","cues":[],"selfConfidence":0.2}
        """))
        guard case .occasionKind(let u) = unknown.value else { Issue.record("not an occasionKind value"); return }
        #expect(u.kind == .unknown)
    }

    @Test("era with empty cues is valid; selfConfidence at the bounds 0 and 1 is valid")
    func emptyCuesAndBounds() throws {
        _ = try output(decode(.era, #"{"family":"era","window":[120,180],"yearRange":[1991,1991],"rationale":"OSD date","cues":[],"selfConfidence":0}"#))
        _ = try output(decode(.era, #"{"family":"era","window":[120,180],"yearRange":[1900,2100],"rationale":"anything","cues":[],"selfConfidence":1}"#))
    }

    @Test("carrierClues and spokenNamePresence have no contract in this build: schemaInvalid in words, never a crash")
    func familiesWithoutAContractYet() {
        let reason = invalidReason(decode(.carrierClues, ContractFixture.era))
        #expect(reason.contains("carrierClues") && reason.contains("no output contract"))
        _ = invalidReason(decode(.spokenNamePresence, ContractFixture.era))
    }
}

@Suite("ModelLab — output contracts fail closed")
struct ModelLabContractFailClosedTests {

    @Test("an extra key is rejected (no silent tolerance of a model's extra field)")
    func extraKey() {
        let reason = invalidReason(decode(.era, """
        {"family":"era","window":[120,180],"yearRange":[1991,1995],"rationale":"r","cues":[],"selfConfidence":0.7,"confidence_score":0.95}
        """))
        #expect(reason.contains("confidence_score"), Comment(rawValue: reason))
    }

    @Test("a wrong type is rejected: a string year, a numeric rationale, a cue list that is an object")
    func wrongType() {
        #expect(invalidReason(decode(.era, #"{"family":"era","window":[120,180],"yearRange":["1991","1995"],"rationale":"r","cues":[],"selfConfidence":0.7}"#)).contains("yearRange"))
        #expect(invalidReason(decode(.era, #"{"family":"era","window":[120,180],"yearRange":[1991,1995],"rationale":42,"cues":[],"selfConfidence":0.7}"#)).contains("rationale"))
        #expect(invalidReason(decode(.era, #"{"family":"era","window":[120,180],"yearRange":[1991,1995],"rationale":"r","cues":{},"selfConfidence":0.7}"#)).contains("cues"))
        #expect(invalidReason(decode(.era, #"{"family":"era","window":[120,180],"yearRange":[1991.5,1995],"rationale":"r","cues":[],"selfConfidence":0.7}"#)).contains("1991.5"), "a fractional year is not an Int (Foundation names the number, not the key)")
    }

    @Test("a year outside 1900…2100 is rejected (19910, 1899, 2101)")
    func yearOutOfRange() {
        for bad in ["[19910,1995]", "[1899,1950]", "[2000,2101]"] {
            let reason = invalidReason(decode(.era, #"{"family":"era","window":[120,180],"yearRange":\#(bad),"rationale":"r","cues":[],"selfConfidence":0.7}"#))
            #expect(reason.contains("1900") && reason.contains("2100"), Comment(rawValue: reason))
        }
    }

    @Test("a reversed year range is rejected; a 3-element or 1-element range is rejected")
    func reversedRange() {
        #expect(invalidReason(decode(.era, #"{"family":"era","window":[120,180],"yearRange":[1995,1991],"rationale":"r","cues":[],"selfConfidence":0.7}"#)).contains("reversed"))
        #expect(invalidReason(decode(.era, #"{"family":"era","window":[120,180],"yearRange":[1991,1993,1995],"rationale":"r","cues":[],"selfConfidence":0.7}"#)).contains("two"))
        #expect(invalidReason(decode(.era, #"{"family":"era","window":[120,180],"yearRange":[1991],"rationale":"r","cues":[],"selfConfidence":0.7}"#)).contains("two"))
    }

    @Test("a window with end < start, a negative start, or not exactly two numbers is rejected")
    func badWindow() {
        #expect(invalidReason(decode(.era, #"{"family":"era","window":[180,120],"yearRange":[1991,1995],"rationale":"r","cues":[],"selfConfidence":0.7}"#)).contains("window"))
        #expect(invalidReason(decode(.era, #"{"family":"era","window":[-1,120],"yearRange":[1991,1995],"rationale":"r","cues":[],"selfConfidence":0.7}"#)).contains("window"))
        #expect(invalidReason(decode(.era, #"{"family":"era","window":[120],"yearRange":[1991,1995],"rationale":"r","cues":[],"selfConfidence":0.7}"#)).contains("window"))
        #expect(invalidReason(decode(.era, #"{"family":"era","window":"120-180","yearRange":[1991,1995],"rationale":"r","cues":[],"selfConfidence":0.7}"#)).contains("window"))
    }

    @Test("a missing required key is rejected and named")
    func missingKey() {
        #expect(invalidReason(decode(.era, #"{"family":"era","window":[120,180],"yearRange":[1991,1995],"cues":[],"selfConfidence":0.7}"#)).contains("rationale"))
        #expect(invalidReason(decode(.roomFeatures, #"{"family":"roomFeatures","window":[120,180],"setting":"indoor","features":[],"selfConfidence":0.7}"#)).contains("locationType"))
    }

    @Test("the family word must match the family asked for; an unknown family word is rejected")
    func familyMismatch() {
        #expect(invalidReason(decode(.era, ContractFixture.roomFeatures)).contains("roomFeatures"))
        #expect(invalidReason(decode(.era, #"{"family":"vibes","window":[120,180],"yearRange":[1991,1995],"rationale":"r","cues":[],"selfConfidence":0.7}"#)).contains("vibes"))
    }

    @Test("selfConfidence outside 0…1, an unknown cue kind, a cue before the window, an unknown setting, an unknown occasion kind — each rejected")
    func enumAndRangeGuards() {
        #expect(invalidReason(decode(.era, #"{"family":"era","window":[120,180],"yearRange":[1991,1995],"rationale":"r","cues":[],"selfConfidence":1.5}"#)).contains("selfConfidence"))
        #expect(invalidReason(decode(.era, #"{"family":"era","window":[120,180],"yearRange":[1991,1995],"rationale":"r","cues":[{"kind":"vibe","text":"t","atS":130}],"selfConfidence":0.5}"#)).contains("vibe"))
        #expect(invalidReason(decode(.era, #"{"family":"era","window":[120,180],"yearRange":[1991,1995],"rationale":"r","cues":[{"kind":"technical","text":"t","atS":-4}],"selfConfidence":0.5}"#)).contains("atS"))
        #expect(invalidReason(decode(.roomFeatures, #"{"family":"roomFeatures","window":[120,180],"setting":"underwater","locationType":"x","features":[],"selfConfidence":0.5}"#)).contains("underwater"))
        #expect(invalidReason(decode(.occasionKind, #"{"family":"occasionKind","window":[120,180],"kind":"barMitzvah","rationale":"r","cues":[],"selfConfidence":0.5}"#)).contains("barMitzvah"))
        #expect(invalidReason(decode(.ocrDate, #"{"family":"ocrDate","window":[120,180],"text":"JUN 21 1991","atS":131,"year":1991,"month":13,"selfConfidence":0.5}"#)).contains("month"))
        #expect(invalidReason(decode(.ocrDate, #"{"family":"ocrDate","window":[120,180],"text":"JUN 21 1991","atS":131,"day":21,"selfConfidence":0.5}"#)).contains("day"), "a day without a month and year is not a date part")
        #expect(invalidReason(decode(.ocrDate, #"{"family":"ocrDate","window":[120,180],"text":"","atS":131,"selfConfidence":0.5}"#)).contains("text"), "empty text is 'nothing read', which ocrText says with an empty list")
    }

    @Test("not JSON, an array, empty bytes, invalid UTF-8 and a response over the size cap are rejected in words")
    func garbage() {
        #expect(!invalidReason(decode(.era, "the model said: probably the early nineties")).isEmpty)
        #expect(!invalidReason(decode(.era, "[1991, 1995]")).isEmpty)
        #expect(!invalidReason(decode(.era, "")).isEmpty)
        #expect(!invalidReason(ContractDecoder.decode(family: .era, json: Data([0xFF, 0xFE, 0x7B]), window: window)).isEmpty)
        let huge = #"{"family":"scene","window":[120,180],"description":"\#(String(repeating: "x", count: ContractDecoder.maxJSONBytes))","selfConfidence":0.5}"#
        #expect(invalidReason(decode(.scene, huge)).contains("larger"))
    }

    @Test("R6: a contract decoded outside ContractDecoder (bare JSONDecoder, no expected family) refuses — even a well-formed answer")
    func bareDecoderIsNotADoor() {
        let vibes = Data(#"{"family":"vibes","window":[0,60],"yearRange":[1991,1995],"rationale":"r","cues":[],"selfConfidence":0.5}"#.utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(EraContract.self, from: vibes) }
        #expect(throws: (any Error).self) { try JSONDecoder().decode(EraContract.self, from: Data(ContractFixture.era.utf8)) }
    }

    @Test("too many features, too many cues, too many lines — bounded, in words")
    func caps() {
        let features = (0..<(ContractDecoder.maxListItems + 1)).map { "\"f\($0)\"" }.joined(separator: ",")
        #expect(invalidReason(decode(.roomFeatures, #"{"family":"roomFeatures","window":[120,180],"setting":"indoor","locationType":"x","features":[\#(features)],"selfConfidence":0.5}"#)).contains("features"))
    }
}

@Suite("ModelLab — ApproachOutput → EvidenceAssertion")
struct ModelLabAssertionMappingTests {

    private let approach = ModelLabFixtures.descriptor(revision: 3, host: .pythonWorker(venv: "venv-mlx", script: "vlm.py"), promptHash: "sha256:feedbeef")

    @Test("era → one era.yearRange assertion; by = machine:<id>@r<rev>; evidenceJSON carries rationale, cues, frame times, prompt hash, host, elapsed and selfConfidence; value does not")
    func eraMapping() throws {
        let out = try output(decode(.era, ContractFixture.era))
        let assertions = EvidenceAssertionMapper.assertions(from: out, subjectDigest: "sha256:abc123", approach: approach, elapsedS: 2.25)
        #expect(assertions.count == 1)
        let a = try #require(assertions.first)
        #expect(a.subjectDigest == "sha256:abc123")
        #expect(a.rangeStartS == 120 && a.rangeEndS == 180)
        #expect(a.field == "era.yearRange" && a.value == "1991-1995")
        #expect(a.by == "machine:qwen2.5-vl-3b-4bit/era-v1/window-60s@r3")
        let evidence = try #require(try JSONSerialization.jsonObject(with: Data(a.evidenceJSON.utf8)) as? [String: Any])
        #expect(evidence["promptHash"] as? String == "sha256:feedbeef")
        #expect(evidence["host"] as? String == "pythonWorker(venv-mlx, vlm.py)")
        #expect(evidence["frameTimesS"] as? [Double] == [120, 131, 140, 150, 160, 170])
        #expect(evidence["elapsedS"] as? Double == 2.25)
        #expect(evidence["selfConfidence"] as? Double == 0.7, "stored for the Judge")
        #expect((evidence["cues"] as? [[String: Any]])?.count == 2)
        #expect(evidence["rationale"] as? String == "4:3, camcorder OSD 'SP', boxy sedan, CRT television")
        #expect(evidence["declaredWindow"] as? [Double] == [120, 180])
        #expect(!a.value.contains("0.7") && !a.field.contains("confidence"), "events_design rule 9: selfConfidence never reaches a displayed field")
    }

    @Test("roomFeatures → setting, locationType and one assertion per feature")
    func roomMapping() throws {
        let out = try output(decode(.roomFeatures, ContractFixture.roomFeatures))
        let fields = EvidenceAssertionMapper.assertions(from: out, subjectDigest: "sha256:r", approach: approach, elapsedS: 1).map { ($0.field, $0.value) }
        #expect(fields.map(\.0) == ["room.setting", "room.locationType", "room.feature", "room.feature", "room.feature"])
        #expect(fields.map(\.1) == ["indoor", "residential living room", "green shag carpet", "brick fireplace", "oak panelling"])
    }

    @Test("ocrDate → ocr.date with the literal text as value and the parsed parts in evidence; ocrText → one ocr.text per line; scene → scene.text; occasionKind → occasion.kind")
    func otherFamilies() throws {
        let date = EvidenceAssertionMapper.assertions(from: try output(decode(.ocrDate, ContractFixture.ocrDate)), subjectDigest: "sha256:d", approach: approach, elapsedS: 1)
        #expect(date.map(\.field) == ["ocr.date"] && date.first?.value == "JUN 21 1991")
        #expect(date.first?.evidenceJSON.contains("\"year\":1991") == true)
        #expect(date.first?.evidenceJSON.contains("\"atS\":131") == true)
        let text = EvidenceAssertionMapper.assertions(from: try output(decode(.ocrText, ContractFixture.ocrText)), subjectDigest: "sha256:t", approach: approach, elapsedS: 1)
        #expect(text.map(\.field) == ["ocr.text", "ocr.text"] && text.map(\.value) == ["SP", "PLAY"])
        let scene = EvidenceAssertionMapper.assertions(from: try output(decode(.scene, ContractFixture.scene)), subjectDigest: "sha256:s", approach: approach, elapsedS: 1)
        #expect(scene.map(\.field) == ["scene.text"])
        let occasion = EvidenceAssertionMapper.assertions(from: try output(decode(.occasionKind, ContractFixture.occasionKind)), subjectDigest: "sha256:o", approach: approach, elapsedS: 1)
        #expect(occasion.map(\.field) == ["occasion.kind"] && occasion.first?.value == "christmas")
        let empty = EvidenceAssertionMapper.assertions(from: try output(decode(.ocrText, #"{"family":"ocrText","window":[120,180],"lines":[],"selfConfidence":0.9}"#)), subjectDigest: "sha256:e", approach: approach, elapsedS: 1)
        #expect(empty.isEmpty, "nothing read → nothing asserted")
    }

    @Test("R5: a non-finite or negative elapsedS is recorded as null and never erases the rest of the evidence")
    func nonFiniteElapsedDoesNotBlankEvidence() throws {
        let out = try output(decode(.era, ContractFixture.era))
        for bad in [Double.infinity, -.infinity, .nan, -1] {
            let a = EvidenceAssertionMapper.assertions(from: out, subjectDigest: "sha256:x", approach: approach, elapsedS: bad)
            let json = try #require(a.first?.evidenceJSON)
            #expect(json.contains("\"promptHash\":\"sha256:feedbeef\"") && json.contains("\"cues\":[{"), "elapsedS=\(bad): \(json)")
            #expect(json.contains("\"elapsedS\":null"))
        }
    }

    @Test("evidenceJSON is deterministic (sorted keys) so two runs of the same output compare byte-for-byte")
    func deterministic() throws {
        let out = try output(decode(.era, ContractFixture.era))
        let a = EvidenceAssertionMapper.assertions(from: out, subjectDigest: "sha256:x", approach: approach, elapsedS: 1)
        let b = EvidenceAssertionMapper.assertions(from: out, subjectDigest: "sha256:x", approach: approach, elapsedS: 1)
        #expect(a == b)
    }
}
