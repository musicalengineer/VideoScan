import Foundation
import Testing
@testable import VideoScan

/// The `record` shape (2026-09-02): strict wire contract, round trip, and
/// the tolerant-decoder rewrites that turn a catalog-wide shape about "it"
/// or a named file into a one-record question.
@Suite("Family Archivist QueryAST record shape")
struct ArchivistQueryASTRecordTests {
    private let decoder = JSONDecoder()

    private func decode(_ json: String) throws -> ArchivistQueryAST {
        try decoder.decode(ArchivistQueryAST.self, from: Data(json.utf8))
    }

    private func assertRejected(
        _ json: String,
        _ comment: Comment? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(throws: (any Error).self, comment, sourceLocation: sourceLocation) {
            try decode(json)
        }
    }

    // MARK: - Strict contract

    @Test func decodesBothReferenceForms() throws {
        #expect(try decode(
            #"{"shape":"record","payload":{"reference":{"kind":"currentSelection"},"operations":["people"]}}"#)
            == .record(.init(reference: .currentSelection, operations: [.people])))
        #expect(try decode(
            #"{"shape":"record","payload":{"reference":{"kind":"file","name":"New Hampshire.mov"},"operations":["people","date"],"people":["Rick","me"]}}"#)
            == .record(.init(reference: .file(name: "New Hampshire.mov"),
                             operations: [.people, .date], people: ["Rick", "me"])))
    }

    @Test func roundTripsThroughCodable() throws {
        let values: [ArchivistQueryAST] = [
            .record(.init(reference: .currentSelection, operations: [.about])),
            .record(.init(reference: .file(name: "/Volumes/X/New Hampshire.mov"),
                          operations: [.people, .date], people: ["tim", "nancy", "me"])),
        ]
        for value in values {
            let data = try JSONEncoder().encode(value)
            #expect(try decoder.decode(ArchivistQueryAST.self, from: data) == value)
        }
    }

    @Test func rejectsMalformedPayloads() {
        assertRejected(#"{"shape":"record","payload":{"reference":{"kind":"currentSelection"},"operations":[]}}"#, "empty operations")
        assertRejected(#"{"shape":"record","payload":{"reference":{"kind":"currentSelection"},"operations":["people","people"]}}"#, "duplicate operations")
        assertRejected(#"{"shape":"record","payload":{"reference":{"kind":"currentSelection"},"operations":["about","people"]}}"#, "about must stand alone")
        assertRejected(#"{"shape":"record","payload":{"reference":{"kind":"currentSelection"},"operations":["said"]}}"#, "unknown operation")
        assertRejected(#"{"shape":"record","payload":{"reference":{"kind":"file","name":"  "},"operations":["people"]}}"#, "empty file name")
        assertRejected(#"{"shape":"record","payload":{"reference":{"kind":"file"},"operations":["people"]}}"#, "file without a name")
        assertRejected(#"{"shape":"record","payload":{"reference":{"kind":"currentSelection","name":"x.mov"},"operations":["people"]}}"#, "name is not valid for currentSelection")
        assertRejected(#"{"shape":"record","payload":{"operations":["people"]}}"#, "reference is required")
        assertRejected(#"{"shape":"record","payload":{"reference":{"kind":"currentSelection"},"operations":["people"],"people":["a","b","c","d","e","f","g"]}}"#, "people exceeds six")
        assertRejected(#"{"shape":"record","payload":{"reference":{"kind":"currentSelection"},"operations":["people"],"people":[""]}}"#, "empty person")
        assertRejected(#"{"shape":"record","payload":{"reference":{"kind":"currentSelection"},"operations":["people"],"keywords":["x"]}}"#, "keywords is not a record field")
    }

    @Test func mediaExtensionDetectionMirrorsTheEvalList() {
        #expect(ArchivistQueryAST.Record.endsWithMediaExtension("New Hampshire.mov"))
        #expect(ArchivistQueryAST.Record.endsWithMediaExtension("/Volumes/X/tape.MXF"))
        #expect(ArchivistQueryAST.Record.endsWithMediaExtension("clip.m2ts"))
        #expect(!ArchivistQueryAST.Record.endsWithMediaExtension("Christmas"))
        #expect(!ArchivistQueryAST.Record.endsWithMediaExtension(".mov"))
        #expect(!ArchivistQueryAST.Record.endsWithMediaExtension("v1.2"))
        #expect(!ArchivistQueryAST.Record.endsWithMediaExtension("notes.txt"))
    }

    @Test func selectionWordsCoverTheTranslatorSpellings() {
        for word in ["it", "this", "this video", "the selected video", "currentSelection", "selection"] {
            #expect(ArchivistQueryAST.Record.isSelectionWord(word), Comment(rawValue: word))
        }
        for word in ["Donna", "the boys", "New Hampshire"] {
            #expect(!ArchivistQueryAST.Record.isSelectionWord(word), Comment(rawValue: word))
        }
    }

    // MARK: - Tolerant decoder rewrites

    private func tolerant(_ json: String) throws -> ArchivistQueryAST.TranslatorDecoding {
        try ArchivistQueryAST.decodeTranslatorOutput(Data(json.utf8))
    }

    @Test func aggregateAnchoredOnASelectionWordBecomesARecordQuestion() throws {
        // cs003 "who else is in it": the translator's aggregate on the word "it".
        let decoded = try tolerant(
            #"{"shape":"aggregate","payload":{"operation":"coOccurrence","anchorPeople":["it"]}}"#)
        #expect(decoded.ast == .record(.init(reference: .currentSelection, operations: [.people])))
        #expect(decoded.notes.contains { $0.contains("rewrote aggregate anchored on 'it'") })

        let spelled = try tolerant(
            #"{"shape":"aggregate","payload":{"operation":"coOccurrence","anchorPeople":["currentSelection"],"limit":5}}"#)
        #expect(spelled.ast == .record(.init(reference: .currentSelection, operations: [.people])))
    }

    @Test func aggregateAnchoredOnAPersonIsUntouched() throws {
        let decoded = try tolerant(
            #"{"shape":"aggregate","payload":{"operation":"coOccurrence","anchorPeople":["Donna"]}}"#)
        #expect(decoded.ast == .aggregate(.init(operation: .coOccurrence, anchorPeople: ["Donna"])))
        #expect(decoded.notes.isEmpty)
        // Two anchors, one of them "it": not a lone selection word — untouched.
        let two = try tolerant(
            #"{"shape":"aggregate","payload":{"operation":"coOccurrence","anchorPeople":["Donna","it"]}}"#)
        if case .aggregate = two.ast {} else { Issue.record("expected aggregate, got \(two.ast)") }
    }

    @Test func presenceOrCrossNamingAFileBecomesARecordQuestionCarryingPeople() throws {
        let presence = try tolerant(
            #"{"shape":"presence","payload":{"people":["rick","me"],"keywords":["New Hampshire.mov"]}}"#)
        #expect(presence.ast == .record(.init(
            reference: .file(name: "New Hampshire.mov"), operations: [.people], people: ["rick", "me"])))
        #expect(presence.notes.contains { $0.contains("rewrote presence naming file 'New Hampshire.mov'") })

        let cross = try tolerant(
            #"{"shape":"cross","payload":{"keywords":["New Hampshire.mov","names"],"transcript":["rick"]}}"#)
        #expect(cross.ast == .record(.init(reference: .file(name: "New Hampshire.mov"), operations: [.people])))
        #expect(cross.notes.contains { $0.contains("dropped keywords: names, rick") })
    }

    @Test func presenceWithoutAFileKeywordIsUntouched() throws {
        let decoded = try tolerant(
            #"{"shape":"presence","payload":{"people":["Donna"],"keywords":["christmas"]}}"#)
        #expect(decoded.ast == .presence(.init(people: ["Donna"], keywords: ["christmas"])))
        #expect(decoded.notes.isEmpty)
    }

    @Test func recordFieldsAreKnownSoOnlyDecorationIsDropped() throws {
        let decoded = try tolerant(
            #"{"shape":"record","payload":{"reference":{"kind":"file","name":"x.mov"},"operations":["people"],"confidence":0.9}}"#)
        #expect(decoded.ast == .record(.init(reference: .file(name: "x.mov"), operations: [.people])))
        #expect(decoded.notes == ["ignored extra field payload.confidence"])
    }

    @Test func recordRouteIsClosed() {
        #expect(HallieTurnExecutor.route(.record(.init(reference: .currentSelection, operations: [.people]))) == .record)
        #expect(HallieTurnExecutor.label(HallieTurnExecutor.Route.record) == "record")
        #expect(HallieTurnExecutor.description(of: .record(.init(reference: .currentSelection, operations: [.about]))) == "shape=record")
        #expect(HallieShellCLI.route(.record(.init(reference: .currentSelection, operations: [.date]))) == .record)
    }
}
