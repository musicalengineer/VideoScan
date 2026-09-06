import Foundation
import Testing
@testable import VideoScan

// MARK: - The repair retry needs to know WHAT was wrong (2026-09-03)
//
// THE INCIDENT (see also OllamaStructuredOutputFallbackTests.swift).
// Homebrew ollama 0.33.2 answers every `format:`-bearing request with HTTP
// 501, so the fallback resends the SAME host without a schema. Nothing then
// enforces the JSON schema's `required` arrays, and the strict Swift
// decoder is the only judge of the model's answer. `OllamaFailoverTranslator`
// feeds a rejection back into the next attempt via `repairHint` /
// `repairSuffix(for:)` — but every catch site built that rejection with
// `DecodingError.localizedDescription`, which discards `debugDescription`
// and the coding path. At temperature 0 the model then received only "you
// were rejected" and reproduced the identical wrong answer.
//
// Two live captures, Rick, 2026-09-03:
//   "how old is Tim"                 -> keyNotFound(payload.reference)
//   "show me videos of my mother"    -> dataCorrupted, unknown field "relation"
@Suite("Hallie — repair hint names the offending field")
struct OllamaDecodeFailureDetailTests {

    /// SENSOR. Decodes the two literal live-capture payloads through the
    /// PRODUCTION decoder (`ArchivistQueryAST.decodeTranslatorOutput`) and
    /// asserts the rendered detail names the real field, not Foundation's
    /// generic "couldn't be read" wording. If a future decoder refactor
    /// changes how these fail, this test fails here — in CI — rather than
    /// silently degrading the repair hint again in front of Rick's family.
    @Test func repairHintNamesTheOffendingField_soTheTemperatureZeroRetryCanChange() throws {
        // A temporal payload missing a required field.
        //
        // This used to use a missing `reference`, which no longer fails:
        // 828e00da (merged 2026-09-06) defaults a missing reference to
        // `.currentSelection` so that "how old is Tim" survives a server
        // that cannot enforce the schema. That branch and this test were
        // written the same night against different bases and only met in
        // the merge. `operation` is still genuinely required — it has no
        // sensible default, since nothing can guess whether the question is
        // about an age or a date — so it is what this now asks about.
        let missingOperation = Data(
            #"{"shape":"temporal","payload":{"subject":"tim"}}"#.utf8)
        do {
            _ = try ArchivistQueryAST.decodeTranslatorOutput(missingOperation)
            Issue.record("a temporal payload with no operation must fail to decode")
        } catch {
            let detail = OllamaQueryTranslator.decodeFailureDetail(error)
            #expect(detail.contains("operation"), "got: \(detail)")
            #expect(!detail.lowercased().contains("couldn't be read"),
                    "must not fall back to the generic Foundation wording: \(detail)")
        }

        // "show me videos of my mother": presence payload carrying a graph
        // field ("relation") that is unknown on presence.
        let unknownRelation = Data(
            #"{"shape":"presence","payload":{"people":["me"],"mediaKind":"video","relation":"mother"}}"#.utf8)
        do {
            _ = try ArchivistQueryAST.decodeTranslatorOutput(unknownRelation)
            Issue.record("an unknown presence field must fail to decode")
        } catch {
            let detail = OllamaQueryTranslator.decodeFailureDetail(error)
            #expect(detail.contains("relation"), "got: \(detail)")
            #expect(!detail.lowercased().contains("correct format"),
                    "must not fall back to the generic Foundation wording: \(detail)")
        }
    }

    /// Negative: something that is NOT a `DecodingError` (a transport
    /// failure, say) still renders via `localizedDescription` — the helper
    /// only special-cases the case it can say something better about.
    @Test func nonDecodingErrorsStillRenderTheirLocalizedDescription() {
        struct Boom: Error, LocalizedError {
            var errorDescription: String? { "boom happened" }
        }
        #expect(OllamaQueryTranslator.decodeFailureDetail(Boom()) == "boom happened")
    }

    /// `.keyNotFound` renders as a dotted path ending in the missing key —
    /// this is the exact shape `repairSuffix(for:)` appends to the prompt.
    @Test func keyNotFoundRendersADottedPath() {
        enum Key: String, CodingKey { case reference }
        let context = DecodingError.Context(
            codingPath: [ArchivistPathProbeKey(stringValue: "payload")!],
            debugDescription: "no value associated with key reference")
        let error = DecodingError.keyNotFound(Key.reference, context)
        #expect(OllamaQueryTranslator.decodeFailureDetail(error)
            == "missing required field 'payload.reference'")
    }

    /// `.dataCorrupted` renders the coding path plus the decoder's own
    /// complaint verbatim — this is what carries "unknown field(s): X".
    @Test func dataCorruptedRendersPathAndDebugDescription() {
        let context = DecodingError.Context(
            codingPath: [ArchivistPathProbeKey(stringValue: "payload")!],
            debugDescription: "unknown field(s): relation")
        let error = DecodingError.dataCorrupted(context)
        #expect(OllamaQueryTranslator.decodeFailureDetail(error)
            == "payload: unknown field(s): relation")
    }

    /// A root-level failure (empty coding path) must not print a stray
    /// leading colon.
    @Test func rootLevelDataCorruptedHasNoStrayColon() {
        let context = DecodingError.Context(
            codingPath: [], debugDescription: "not a JSON object")
        let error = DecodingError.dataCorrupted(context)
        #expect(OllamaQueryTranslator.decodeFailureDetail(error) == "not a JSON object")
    }

    /// Very long debug descriptions are capped so the repair-suffix budget
    /// (`repairSuffix(for:)` already truncates at 240, with the offending
    /// JSON appended after it) is not blown by one field's message.
    @Test func longDetailIsCapped() {
        let context = DecodingError.Context(
            codingPath: [], debugDescription: String(repeating: "x", count: 400))
        let error = DecodingError.dataCorrupted(context)
        #expect(OllamaQueryTranslator.decodeFailureDetail(error).count <= 200)
    }
}

/// A standalone `CodingKey` for building `DecodingError.Context` values
/// directly in tests, independent of any private nested `CodingKeys` type.
private struct ArchivistPathProbeKey: CodingKey {
    let stringValue: String
    let intValue: Int?
    init?(stringValue: String) { self.stringValue = stringValue; intValue = nil }
    init?(intValue: Int) { stringValue = String(intValue); self.intValue = intValue }
}
