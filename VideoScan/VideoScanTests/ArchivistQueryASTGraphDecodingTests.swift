import Foundation
import Testing
@testable import VideoScan

/// Wire contract for the graph additions (familyTree, multi-hop relations,
/// side, surname): what the strict decoder accepts and rejects, and which
/// benign model spellings the tolerant decoder maps — never guessing.
@Suite("Family Archivist QueryAST graph shapes")
struct ArchivistQueryASTGraphDecodingTests {
    private let decoder = JSONDecoder()

    private func strict(_ json: String) throws -> ArchivistQueryAST {
        try decoder.decode(ArchivistQueryAST.self, from: Data(json.utf8))
    }

    private func tolerant(_ json: String) throws -> ArchivistQueryAST.TranslatorDecoding {
        try ArchivistQueryAST.decodeTranslatorOutput(Data(json.utf8))
    }

    @Test func familyTreeAcceptsPersonSurnameOrNeither() throws {
        #expect(try strict(#"{"shape":"graph","payload":{"people":["donna"],"operation":"familyTree"}}"#)
                == .graph(.init(people: ["donna"], operation: .familyTree)))
        #expect(try strict(#"{"shape":"graph","payload":{"operation":"familyTree","surname":"breen"}}"#)
                == .graph(.init(people: [], operation: .familyTree, surname: "breen")))
        #expect(try strict(#"{"shape":"graph","payload":{"operation":"familyTree"}}"#)
                == .graph(.init(people: [], operation: .familyTree)))
        #expect(try strict(#"{"shape":"graph","payload":{"people":[],"operation":"familyTree"}}"#)
                == .graph(.init(people: [], operation: .familyTree)))
    }

    @Test func multiHopKinshipWithSideRoundTrips() throws {
        let ast = try strict(#"{"shape":"graph","payload":{"people":["donna"],"operation":"kinship","relation":"great-grandmother","side":"maternal"}}"#)
        #expect(ast == .graph(.init(
            people: ["donna"], operation: .kinship,
            relation: .greatGrandmother, side: .maternal)))
        let encoded = try JSONEncoder().encode(ast)
        #expect(try decoder.decode(ArchivistQueryAST.self, from: encoded) == ast)
        for relation in ArchivistQueryAST.Graph.Relation.allCases {
            let json = #"{"shape":"graph","payload":{"people":["x"],"operation":"kinship","relation":"\#(relation.rawValue)"}}"#
            #expect(try strict(json) == .graph(.init(people: ["x"], operation: .kinship, relation: relation)),
                    Comment(rawValue: relation.rawValue))
        }
    }

    @Test(arguments: [
        // people still required outside familyTree
        #"{"shape":"graph","payload":{"operation":"biography"}}"#,
        #"{"shape":"graph","payload":{"people":[],"operation":"kinship","relation":"father"}}"#,
        // side only with kinship
        #"{"shape":"graph","payload":{"people":["donna"],"operation":"biography","side":"maternal"}}"#,
        #"{"shape":"graph","payload":{"people":["donna"],"operation":"familyTree","side":"maternal"}}"#,
        // surname only with familyTree, and not together with people
        #"{"shape":"graph","payload":{"people":["donna"],"operation":"biography","surname":"breen"}}"#,
        #"{"shape":"graph","payload":{"people":["donna"],"operation":"familyTree","surname":"breen"}}"#,
        #"{"shape":"graph","payload":{"operation":"familyTree","surname":"  "}}"#,
        // unknown vocabulary is rejected, never coerced
        #"{"shape":"graph","payload":{"people":["donna"],"operation":"kinship","relation":"godmother"}}"#,
        #"{"shape":"graph","payload":{"people":["donna"],"operation":"kinship","relation":"father","side":"left"}}"#,
        #"{"shape":"graph","payload":{"people":["donna"],"operation":"lineage"}}"#,
    ])
    func strictDecoderRejectsMalformedGraphPayloads(json: String) {
        #expect(throws: DecodingError.self, Comment(rawValue: json)) { try strict(json) }
    }

    @Test func tolerantDecoderMapsObviousFamilyTreeSpellings() throws {
        for spelling in ["family tree", "family_tree", "familytree", "ancestors", "ancestry",
                         "descendants", "lineage", "pedigree", "genealogy", "tree"] {
            let decoded = try tolerant(#"{"shape":"graph","payload":{"people":["donna"],"operation":"\#(spelling)"}}"#)
            #expect(decoded.ast == .graph(.init(people: ["donna"], operation: .familyTree)), Comment(rawValue: spelling))
            #expect(decoded.notes == ["rewrote payload.operation '\(spelling)' to familyTree"], Comment(rawValue: spelling))
        }
        let surname = try tolerant(#"{"shape":"graph","payload":{"people":["the Breens"],"operation":"familyTree"}}"#)
        #expect(surname.ast == .graph(.init(people: [], operation: .familyTree, surname: "Breens")))
        #expect(surname.notes == ["rewrote payload.people 'the Breens' to surname"])
    }

    @Test func tolerantDecoderMapsColloquialRelationsAndSides() throws {
        let cases: [(String, ArchivistQueryAST.Graph.Relation, ArchivistQueryAST.Graph.Side?)] = [
            ("grandma", .grandmother, nil),
            ("great grandmother", .greatGrandmother, nil),
            ("great-grandma", .greatGrandmother, nil),
            ("maternal great grandmother", .greatGrandmother, .maternal),
            ("paternal grandfather", .grandfather, .paternal),
            ("mom", .mother, nil),
            ("dad", .father, nil),
            ("kids", .children, nil),
            ("uncles", .uncle, nil),
            ("in-laws", .parentsInLaw, nil),
        ]
        for (spelling, relation, side) in cases {
            let decoded = try tolerant(#"{"shape":"graph","payload":{"people":["donna"],"operation":"kinship","relation":"\#(spelling)"}}"#)
            #expect(decoded.ast == .graph(.init(
                people: ["donna"], operation: .kinship, relation: relation, side: side)), Comment(rawValue: spelling))
            #expect(decoded.notes.first == "rewrote payload.relation '\(spelling)' to '\(relation.rawValue)'", Comment(rawValue: spelling))
        }
        let side = try tolerant(#"{"shape":"graph","payload":{"people":["donna"],"operation":"kinship","relation":"grandmother","side":"mother's side"}}"#)
        #expect(side.ast == .graph(.init(people: ["donna"], operation: .kinship,
                                         relation: .grandmother, side: .maternal)))
        #expect(side.notes == ["rewrote payload.side 'mother's side' to 'maternal'"])

        // An explicit side is never overridden by wording.
        let explicit = try tolerant(#"{"shape":"graph","payload":{"people":["donna"],"operation":"kinship","relation":"maternal grandmother","side":"paternal"}}"#)
        #expect(explicit.ast == .graph(.init(people: ["donna"], operation: .kinship,
                                             relation: .grandmother, side: .paternal)))
    }

    @Test func tolerantDecoderStillRejectsUnknownVocabulary() {
        #expect(throws: DecodingError.self) {
            try tolerant(#"{"shape":"graph","payload":{"people":["donna"],"operation":"kinship","relation":"godmother"}}"#)
        }
        #expect(throws: DecodingError.self) {
            try tolerant(#"{"shape":"graph","payload":{"people":["donna"],"operation":"marriage"}}"#)
        }
        #expect(throws: DecodingError.self) {
            try tolerant(#"{"shape":"graph","payload":{"people":["donna"],"operation":"kinship","relation":"great-great-great-grandfather"}}"#)
        }
    }

    @Test func translatorSchemaAdvertisesTheNewVocabulary() throws {
        let data = try JSONSerialization.data(withJSONObject: OllamaQueryTranslator.astResponseSchema)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("familyTree"))
        #expect(text.contains("great-grandmother"))
        #expect(text.contains("mother-in-law"))
        #expect(text.contains("maternal"))
        #expect(text.contains("surname"))
        #expect(OllamaQueryTranslator.astSystemPrompt.contains("familyTree"))
        #expect(OllamaQueryTranslator.astSystemPrompt.contains("\"side\":\"maternal\""))
        #expect(OllamaQueryTranslator.astSystemPrompt.contains("as a baby"))
        #expect(OllamaQueryTranslator.astSystemPrompt.contains("do NOT invent years"))
    }


    /// Swift 6 stage 4 (#376): the schema statics are computed per call now.
    /// Every schema the translator sends must still be a JSON object
    /// `JSONSerialization` accepts, with its nested branch arrays intact.
    @Test func everyTranslatorSchemaIsAValidJSONObjectWithItsBranches() throws {
        let schemas: [(String, [String: Any])] = [
            ("responseSchema", OllamaQueryTranslator.responseSchema),
            ("astResponseSchema", OllamaQueryTranslator.astResponseSchema),
            ("interpretationResponseSchema", OllamaQueryTranslator.interpretationResponseSchema),
        ]
        for (name, schema) in schemas {
            #expect(JSONSerialization.isValidJSONObject(schema), Comment(rawValue: name))
            let data = try JSONSerialization.data(withJSONObject: schema)
            let decoded = try JSONSerialization.jsonObject(with: data)
            let back = try #require(decoded as? [String: Any], Comment(rawValue: name))
            #expect(!back.isEmpty, Comment(rawValue: name))
        }
        // The nested array-of-object literals kept their shape.
        let props = try #require(OllamaQueryTranslator.responseSchema["properties"] as? [String: Any])
        let mediaKind = try #require(props["mediaKind"] as? [String: Any])
        #expect((mediaKind["anyOf"] as? [[String: Any]])?.count == 2)
        let branches = try #require(OllamaQueryTranslator.astResponseSchema["oneOf"] as? [[String: Any]])
        #expect(branches.count == 6)
        let interpretation = try #require(OllamaQueryTranslator.interpretationResponseSchema["oneOf"] as? [[String: Any]])
        #expect(interpretation.count == 7, "six archive shapes plus conversation")
        let temporal = try #require(branches.first { ($0["properties"] as? [String: Any]).flatMap { ($0["shape"] as? [String: Any])?["enum"] as? [String] } == ["temporal"] })
        let payload = try #require((temporal["properties"] as? [String: Any])?["payload"] as? [String: Any])
        let reference = try #require((payload["properties"] as? [String: Any])?["reference"] as? [String: Any])
        #expect((reference["oneOf"] as? [[String: Any]])?.count == 2)
    }
}
