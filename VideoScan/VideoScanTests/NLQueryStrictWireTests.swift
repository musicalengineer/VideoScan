import Foundation
import Testing
@testable import VideoScan

@Suite("Family Archivist strict query wire")
struct NLQueryStrictWireTests {
    @Test func sparseLegacySpecRemainsAccepted() throws {
        let spec = try NLQuerySpec.decodeStrictWire(
            Data(#"{"people":["Donna"]}"#.utf8))
        #expect(spec.people == ["Donna"])
        #expect(spec.intent == nil)
    }

    @Test func unknownFieldsAreRejectedRatherThanIgnored() {
        #expect(throws: NLQuerySpecWireError.self) {
            try NLQuerySpec.decodeStrictWire(
                Data(#"{"people":[],"answer":"Donna was there"}"#.utf8))
        }
    }

    @Test func unknownIntentAndMediaKindAreRejectedRatherThanGuessed() {
        #expect(throws: NLQuerySpecWireError.self) {
            try NLQuerySpec.decodeStrictWire(
                Data(#"{"intent":"summarize"}"#.utf8))
        }
        #expect(throws: NLQuerySpecWireError.self) {
            try NLQuerySpec.decodeStrictWire(
                Data(#"{"mediaKind":"hologram"}"#.utf8))
        }
    }

    @Test func presentCollectionsMustHonorSchemaShapeAndBound() {
        #expect(throws: NLQuerySpecWireError.self) {
            try NLQuerySpec.decodeStrictWire(Data(#"{"people":null}"#.utf8))
        }
        let seven = Array(repeating: "Donna", count: 7)
        let data = try! JSONSerialization.data(withJSONObject: ["people": seven])
        #expect(throws: NLQuerySpecWireError.self) {
            try NLQuerySpec.decodeStrictWire(data)
        }
    }

    /// Production-path sensor: a host can ignore the requested JSON schema.
    /// Its structurally valid but contract-invalid reply must become a
    /// non-retryable model failure, not a silently weakened catalog query.
    @Test func translatorRejectsSchemaIgnoringHostReply() async {
        let envelope = #"{"message":{"content":"{\"people\":[\"Donna\"],\"intent\":\"summarize\"}"}}"#
        var translator = OllamaQueryTranslator()
        translator.transport = .fake { _, _ in .ok(envelope) }

        do {
            _ = try await translator.translate("summarize Donna")
            Issue.record("contract-invalid model output should throw")
        } catch let error as NLTranslatorError {
            guard case .badResponse = error else {
                Issue.record("expected badResponse, got \(error)")
                return
            }
            #expect(!error.isRetryableOnAnotherHost)
        } catch {
            Issue.record("expected classified translator error, got \(error)")
        }
    }
}
