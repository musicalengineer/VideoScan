import Foundation
import Testing
@testable import VideoScan

/// Sensors for `ArchivistQueryAST.decodeTranslatorOutput`, the tolerant
/// front door for MODEL output. Rick's "how many videos of Donna do we
/// have?" (Hallie log 2026-08-17) died with "content is not a strict
/// ArchivistQueryAST" because qwen added `"limit":1` to a presence payload.
/// The strict Codable (ArchivistQueryASTTests) is unchanged; this layer only
/// strips benign decoration and normalizes list quirks before it.
@Suite("Family Archivist translator-output decoding")
struct ArchivistQueryASTTranslatorDecodingTests {
    private func decode(
        _ json: String,
        originalQuestion: String? = nil
    ) throws -> ArchivistQueryAST.TranslatorDecoding {
        try ArchivistQueryAST.decodeTranslatorOutput(
            Data(json.utf8), originalQuestion: originalQuestion)
    }

    private func assertRejected(
        _ json: String,
        originalQuestion: String? = nil,
        _ comment: Comment? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(throws: (any Error).self, comment, sourceLocation: sourceLocation) {
            try decode(json, originalQuestion: originalQuestion)
        }
    }

    // MARK: The reported turn

    @Test func presencePayloadWithLimitDecodesAndNotesTheExtra() throws {
        // Verbatim shape of the model output that failed the turn.
        let decoded = try decode(
            #"{"shape":"presence","payload":{"people":["donna"],"mediaKind":"video","limit":1}}"#)
        #expect(decoded.ast == .presence(.init(
            people: ["donna"], mediaKind: .video)))
        #expect(decoded.notes == ["ignored extra field payload.limit"])
    }

    // MARK: Benign extras

    @Test func unknownDecorationIsIgnoredAtEveryLevelWithNotes() throws {
        let decoded = try decode(
            #"{"shape":"temporal","confidence":0.9,"payload":{"subject":"Timmy","operation":"age","explanation":"age question","reference":{"kind":"currentSelection","reasoning":"here means this clip"}},"count":1}"#)
        #expect(decoded.ast == .temporal(.init(
            subject: "Timmy", operation: .age, reference: .currentSelection)))
        #expect(Set(decoded.notes) == [
            "ignored extra field confidence",
            "ignored extra field count",
            "ignored extra field payload.explanation",
            "ignored extra field payload.reference.reasoning",
        ])
    }

    @Test func nullOptionalFieldsAreTreatedAsAbsent() throws {
        let decoded = try decode(
            #"{"shape":"presence","payload":{"people":["donna"],"yearStart":null,"yearEnd":null,"mediaKind":null,"keywords":null}}"#)
        #expect(decoded.ast == .presence(.init(people: ["donna"])))
        #expect(decoded.notes.count == 4)
        #expect(decoded.notes.allSatisfy { $0.hasPrefix("dropped null payload.") })
    }

    @Test func limitIsKeptOnlyWhereTheContractDefinesIt() throws {
        let aggregate = try decode(
            #"{"shape":"aggregate","payload":{"operation":"coOccurrence","anchorPeople":["Donna"],"limit":3}}"#)
        #expect(aggregate.ast == .aggregate(.init(
            operation: .coOccurrence, anchorPeople: ["Donna"], limit: 3)))
        #expect(aggregate.notes.isEmpty)

        let graph = try decode(
            #"{"shape":"graph","payload":{"people":["ellen"],"operation":"biography","limit":5}}"#)
        #expect(graph.ast == .graph(.init(people: ["ellen"], operation: .biography)))
        #expect(graph.notes == ["ignored extra field payload.limit"])

        // A defined-but-invalid limit is still a contract violation.
        assertRejected(
            #"{"shape":"aggregate","payload":{"operation":"coOccurrence","anchorPeople":["Donna"],"limit":0}}"#)
    }

    @Test func strictOutputProducesNoNotes() throws {
        let decoded = try decode(
            #"{"shape":"graph","payload":{"people":["ellen"],"operation":"kinship","relation":"father"}}"#)
        #expect(decoded.ast == .graph(.init(
            people: ["ellen"], operation: .kinship, relation: .father)))
        #expect(decoded.notes.isEmpty)
    }

    // MARK: List quirks

    @Test func listEntriesAreTrimmedDedupedAndStopwordsDropped() throws {
        let decoded = try decode(
            #"{"shape":"presence","payload":{"people":[" donna ","","donna","we"],"keywords":["videos","down the cape","the"],"yearStart":1990,"yearEnd":1999}}"#)
        #expect(decoded.ast == .presence(.init(
            people: ["donna"], yearStart: 1990, yearEnd: 1999,
            keywords: ["down the cape"])))
        #expect(decoded.notes.contains("dropped empty entry in payload.people"))
        #expect(decoded.notes.contains("dropped duplicate people entry 'donna'"))
        #expect(decoded.notes.contains("dropped stopword-only people entry 'we'"))
        #expect(decoded.notes.contains("dropped stopword-only keywords entry 'videos'"))
        #expect(decoded.notes.contains("dropped stopword-only keywords entry 'the'"))
    }

    @Test func optionalListThatBecomesEmptyIsRemoved() throws {
        let decoded = try decode(
            #"{"shape":"presence","payload":{"people":["videos"],"yearStart":1994}}"#)
        #expect(decoded.ast == .presence(.init(yearStart: 1994)))
        #expect(decoded.notes.contains("dropped now-empty list payload.people"))
    }

    @Test func requiredListsStayRequiredAfterNormalization() {
        assertRejected(#"{"shape":"graph","payload":{"people":[""],"operation":"biography"}}"#)
        assertRejected(#"{"shape":"graph","payload":{"people":["the"],"operation":"biography"}}"#)
        assertRejected(#"{"shape":"aggregate","payload":{"operation":"coOccurrence","anchorPeople":["  "]}}"#)
    }

    // MARK: Temporal reference shorthand (seen live from qwen3.6)

    @Test func temporalReferenceShorthandIsRewrittenToContractForm() throws {
        let expected = ArchivistQueryAST.temporal(.init(
            subject: "timmy", operation: .age, reference: .explicitYear(1998)))
        for shorthand in [
            #"{"explicitYear":1998}"#, #""1998""#, "1998",
            // Right kind, wrong key for the number (qwen3.6 live, 2026-08-17).
            #"{"kind":"explicitYear","value":1998}"#,
        ] {
            let decoded = try decode(
                #"{"shape":"temporal","payload":{"subject":"timmy","operation":"age","reference":\#(shorthand)}}"#)
            #expect(decoded.ast == expected, "\(shorthand)")
            #expect(decoded.notes == ["rewrote shorthand payload.reference"])
        }
        let selection = ArchivistQueryAST.temporal(.init(
            subject: "timmy", operation: .age, reference: .currentSelection))
        for shorthand in [#"{"currentSelection":true}"#, #""currentSelection""#] {
            let decoded = try decode(
                #"{"shape":"temporal","payload":{"subject":"timmy","operation":"age","reference":\#(shorthand)}}"#)
            #expect(decoded.ast == selection, "\(shorthand)")
        }
        // Not shorthand: an unknown reference kind is still malformed.
        assertRejected(#"{"shape":"temporal","payload":{"subject":"timmy","operation":"age","reference":{"clipDate":1998}}}"#)
        assertRejected(#"{"shape":"temporal","payload":{"subject":"timmy","operation":"age","reference":{"explicitYear":1899}}}"#)
        assertRejected(#"{"shape":"temporal","payload":{"subject":"timmy","operation":"age","reference":"yesterday"}}"#)
    }

    // MARK: Still rejected

    @Test func misplacedKnownConstraintFieldsAreStillRejected() {
        // Dropping these would silently change the question's meaning.
        assertRejected(#"{"shape":"presence","payload":{"transcript":["Donna"]}}"#)
        assertRejected(#"{"shape":"presence","payload":{},"yearStart":1990}"#)
        assertRejected(#"{"shape":"temporal","payload":{"subject":"Timmy","operation":"age","reference":{"kind":"currentSelection","year":1997}}}"#)
        assertRejected(#"{"shape":"graph","payload":{"people":["Ellen"],"operation":"biography","relation":"father"}}"#)
    }

    @Test func modelThatAnswersInsteadOfTranslatingIsRejected() {
        assertRejected(#"{"shape":"presence","payload":{"answer":"Donna was there"}}"#)
        assertRejected(#"{"shape":"presence","payload":{"people":["donna"]},"answer":"yes"}"#)
        assertRejected(#"{"shape":"aggregate","payload":{"operation":"coOccurrence","anchorPeople":["Donna"],"sql":"SELECT *"}}"#)
    }

    @Test func genuinelyMalformedShapesAreStillRejected() {
        assertRejected(#"{"shape":"biography","payload":{}}"#)
        assertRejected(#"{"shape":"presence","payload":{"mediaKind":"hologram"}}"#)
        assertRejected(#"{"shape":"presence","payload":{"yearStart":2100}}"#)
        assertRejected(#"{"shape":"temporal","payload":{"subject":"Timmy","operation":"age","reference":null}}"#)
        assertRejected(#"{"shape":"graph","payload":{"people":["Ellen"],"operation":"kinship"}}"#)
        assertRejected(#"["shape","presence"]"#)
        assertRejected(#"not json"#)
        assertRejected(#"{"payload":{"people":["donna"]}}"#)
    }

    // MARK: Presence/cross "relation" rejoin (live 2026-09-04)
    //
    // Homebrew ollama 0.33.2 returns HTTP 501 for a schema-enforced request
    // (commit 88dceb2a), so the translator retries WITHOUT `format` and the
    // model is free to invent keys. "show me videos of my mother" came back
    // as `{"people":["me"],"relation":"mother"}` — the kin word landed
    // OUTSIDE `people`, where no non-graph payload has ever accepted it, so
    // the strict decoder failed with "unknown field(s): relation". "my mom"
    // and "my dad" already worked because there the model keeps the kin
    // word INSIDE `people`, where SpeakerKinship.rebind already resolves it.
    // This block reunites the two fields — but ONLY when the caller's own
    // question backs up the join; the decoder must never assert a family
    // relationship on the model's say-so alone.

    @Test func presenceRelationIsRejoinedIntoPeopleWhenTheQuestionConfirmsIt() throws {
        let decoded = try decode(
            #"{"shape":"presence","payload":{"people":["me"],"mediaKind":"video","relation":"mother"}}"#,
            originalQuestion: "show me videos of my mother")
        #expect(decoded.ast == .presence(.init(people: ["my mother"], mediaKind: .video)))
        #expect(decoded.notes.contains {
            $0.contains("rejoined payload.relation 'mother' into people 'my mother'")
        })
    }

    @Test func presenceRelationRejoinRequiresAnOriginalQuestion() {
        // No `originalQuestion` at all: the gate cannot fire, and the
        // payload is malformed exactly as it was before this fix.
        assertRejected(
            #"{"shape":"presence","payload":{"people":["me"],"mediaKind":"video","relation":"mother"}}"#)
    }

    @Test func presenceRelationRejoinRejectsAThirdPartyPossessive() {
        // "Tim's mother" — not the speaker's own mother.
        assertRejected(
            #"{"shape":"presence","payload":{"people":["me"],"relation":"mother"}}"#,
            originalQuestion: "Tim's mother")
    }

    @Test func presenceRelationRejoinRejectsTheArchivistsPossessive() {
        // "your mother" — the archivist's relative, not the speaker's.
        assertRejected(
            #"{"shape":"presence","payload":{"people":["me"],"relation":"mother"}}"#,
            originalQuestion: "your mother")
    }

    @Test func presenceRelationRejoinRequiresMyAndTheRelationAdjacent() {
        // Both words appear, but not next to each other — no confirmed phrase.
        assertRejected(
            #"{"shape":"presence","payload":{"people":["me"],"relation":"mother"}}"#,
            originalQuestion: "my goodness, her mother called")
    }

    @Test func aNamedPersonBlocksInventingARelationEvenWithTheWordsAdjacent() {
        // The sensor: the question is about DONNA. If the model also
        // invents `relation:"mother"`, the decoder must not turn that into
        // a search for "mother" — that would be a confident wrong-person
        // answer. `people` already names Donna, so the rejoin's "speaker
        // pronouns only" gate blocks it regardless of wording.
        assertRejected(
            #"{"shape":"presence","payload":{"people":["Donna"],"mediaKind":"video","relation":"mother"}}"#,
            originalQuestion: "how many videos of Donna do we have")
    }

    @Test func presenceRelationRejoinRejectsANonKinWord() {
        // "neighbour" is not in the SpeakerKinship vocabulary.
        assertRejected(
            #"{"shape":"presence","payload":{"people":["me"],"relation":"neighbour"}}"#,
            originalQuestion: "show me videos of my neighbour")
    }

    // MARK: Translator wiring

    @Test func translatorAcceptsDecoratedPresenceReply() async throws {
        var translator = OllamaQueryTranslator()
        translator.transport = .fake { _, _ in
            let content = #"{"shape":"presence","payload":{"people":["donna"],"mediaKind":"video","limit":1}}"#
            let envelope: [String: Any] = ["message": ["content": content]]
            return .init(
                data: try? JSONSerialization.data(withJSONObject: envelope),
                statusCode: 200)
        }
        let ast = try await translator.translateAST("how many videos of Donna do we have?")
        #expect(ast == .presence(.init(people: ["donna"], mediaKind: .video)))
    }
}
