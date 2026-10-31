// EvidenceAssertion.swift (VideoScanCore/ModelLab)
// ONE SENTENCE: the typed, timestamped, machine-signed claim a model makes
// about a range of a file — and the PURE map from one `ApproachOutput` to
// the assertions it carries (docs/design/video_llm_lab_2026_10_30.md §3.3,
// "ApproachOutput → EvidenceAssertion").
//
// For Rick (C++): `EvidenceAssertionMapper.assertions` is a free function
// `std::vector<Assertion> f(const Output&, …)` with no state and no I/O;
// the same input gives the same bytes (sorted-key JSON), so two runs
// compare byte-for-byte.
//
// Rules carried here:
//   • subject = content digest (never a path; CLAUDE.md rule 6);
//   • by = "machine:<approach id>@r<revision>" — a machine's word, so the
//     Provenance sheet can say "machine-generated, unconfirmed";
//   • `selfConfidence` goes into `evidenceJSON` ONLY. It is the model's
//     self-assessment, kept for the Judge (§4), and is never the confidence
//     the UI shows: events_design.md rule 9 — "Confidence words come from
//     evaluated evidence rules, never from a model's self-assessment. No
//     percentages without calibration on Rick's own footage." There is no
//     confidence field on EvidenceAssertion by design.
//
// MEMORY: a few hundred bytes per assertion; one output yields at most
// `ContractDecoder.maxListItems` + 2 assertions.

import Foundation

public struct EvidenceAssertion: Sendable, Hashable {
    /// "sha256:<hex>" — the content, never a path.
    public let subjectDigest: String
    /// The window of the file the claim is about, seconds.
    public let rangeStartS: Double
    public let rangeEndS: Double
    /// Family-specific: "era.yearRange", "room.feature", "occasion.kind",
    /// "ocr.date", "ocr.text", "scene.text", "room.setting", "room.locationType".
    public let field: String
    /// The claim, as words: "1991-1995", "green shag carpet", "christmas".
    public let value: String
    /// "machine:<approach id>@r<revision>".
    public let by: String
    /// Sorted-key JSON: rationale, cues, frameTimesS, promptHash, host,
    /// elapsedS, selfConfidence, declaredWindow, and family-specific parts.
    public let evidenceJSON: String

    public init(subjectDigest: String, rangeStartS: Double, rangeEndS: Double, field: String, value: String, by: String, evidenceJSON: String) {
        self.subjectDigest = subjectDigest
        self.rangeStartS = rangeStartS
        self.rangeEndS = rangeEndS
        self.field = field
        self.value = value
        self.by = by
        self.evidenceJSON = evidenceJSON
    }
}

public enum EvidenceAssertionMapper {

    /// Every assertion in `output`, signed by `approach`. Pure.
    public static func assertions(from output: ApproachOutput, subjectDigest: String,
                                  approach: ApproachDescriptor, elapsedS: Double) -> [EvidenceAssertion] {
        var common: [String: Any] = [
            "promptHash": approach.promptHash,
            "host": approach.host.label,
            "frameTimesS": output.window.frameTimesS,
            // A non-finite or negative elapsed is a measurement bug; it is
            // recorded as null, never allowed to blank the rest (reviewer R5).
            "elapsedS": elapsedS.isFinite && elapsedS >= 0 ? elapsedS as Any : NSNull(),
            "selfConfidence": output.value.selfConfidence,
            "declaredWindow": [output.value.declaredWindow.startS, output.value.declaredWindow.endS],
            "family": output.family.rawValue,
        ]
        let by = approach.signer

        func make(_ field: String, _ value: String, extra: [String: Any] = [:]) -> EvidenceAssertion {
            var evidence = common
            for (k, v) in extra { evidence[k] = v }
            return EvidenceAssertion(subjectDigest: subjectDigest, rangeStartS: output.window.startS, rangeEndS: output.window.endS,
                                     field: field, value: value, by: by, evidenceJSON: canonicalJSON(evidence))
        }

        switch output.value {
        case .era(let era):
            common["rationale"] = era.rationale
            common["cues"] = cuesJSON(era.cues)
            return [make("era.yearRange", "\(era.yearRange.lowerBound)-\(era.yearRange.upperBound)")]

        case .roomFeatures(let room):
            var out = [make("room.setting", room.setting.rawValue), make("room.locationType", room.locationType)]
            out += room.features.map { make("room.feature", $0) }
            return out

        case .ocrDate(let date):
            var extra: [String: Any] = ["atS": date.atS]
            if let y = date.year { extra["year"] = y }
            if let m = date.month { extra["month"] = m }
            if let d = date.day { extra["day"] = d }
            return [make("ocr.date", date.text, extra: extra)]

        case .ocrText(let text):
            return text.lines.map { make("ocr.text", $0.text, extra: ["atS": $0.atS]) }

        case .scene(let scene):
            return [make("scene.text", scene.description)]

        case .occasionKind(let occasion):
            common["rationale"] = occasion.rationale
            common["cues"] = cuesJSON(occasion.cues)
            return [make("occasion.kind", occasion.kind.rawValue)]
        }
    }

    private static func cuesJSON(_ cues: [ContractCue]) -> [[String: Any]] {
        cues.map { ["kind": $0.kind.rawValue, "text": $0.text, "atS": $0.atS] }
    }

    /// Sorted keys, no whitespace: the same evidence is the same string.
    /// Every value here is finite by construction (contract-validated numbers,
    /// sampler frame times, a sanitized elapsed), so an invalid object is a
    /// programming error and stops the process rather than emitting an
    /// assertion with its evidence quietly erased.
    static func canonicalJSON(_ object: [String: Any]) -> String {
        precondition(JSONSerialization.isValidJSONObject(object), "evidence JSON must hold only finite values")
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(bytes: data, encoding: .utf8) else {
            preconditionFailure("JSONSerialization refused an object it called valid")
        }
        return text
    }
}
