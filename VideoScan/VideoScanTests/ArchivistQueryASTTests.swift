import Foundation
import Testing
@testable import VideoScan

@Suite("Family Archivist QueryAST v2 wire contract")
struct ArchivistQueryASTTests {
    private let decoder = JSONDecoder()

    @Test func decodesAllSixDocumentedShapes() throws {
        let cases: [(String, ArchivistQueryAST)] = [
            (#"{"shape":"presence","payload":{"people":["Donna"],"yearStart":1990,"yearEnd":1999,"keywords":["Christmas"]}}"#,
             .presence(.init(people: ["Donna"], yearStart: 1990,
                             yearEnd: 1999, keywords: ["Christmas"]))),
            (#"{"shape":"temporal","payload":{"subject":"Timmy","operation":"age","reference":{"kind":"currentSelection"}}}"#,
             .temporal(.init(subject: "Timmy", operation: .age,
                             reference: .currentSelection))),
            (#"{"shape":"aggregate","payload":{"operation":"coOccurrence","anchorPeople":["Donna"],"limit":10}}"#,
             .aggregate(.init(operation: .coOccurrence,
                              anchorPeople: ["Donna"], limit: 10))),
            (#"{"shape":"event","payload":{"people":["Matt"],"keywords":["first birthday"],"transcript":["birthday"]}}"#,
             .event(.init(people: ["Matt"], keywords: ["first birthday"],
                          transcript: ["birthday"]))),
            (#"{"shape":"graph","payload":{"people":["Ellen"],"operation":"biography"}}"#,
             .graph(.init(people: ["Ellen"], operation: .biography))),
            (#"{"shape":"cross","payload":{"people":["Dan"],"keywords":["red bike"],"transcript":["opens"]}}"#,
             .cross(.init(people: ["Dan"], keywords: ["red bike"],
                          transcript: ["opens"]))),
        ]

        for (json, expected) in cases {
            #expect(try decoder.decode(ArchivistQueryAST.self,
                                       from: Data(json.utf8)) == expected)
        }
    }

    @Test func sparseCatalogAndTextPayloadsRoundTripWithoutDefaults() throws {
        let values: [ArchivistQueryAST] = [
            .presence(.init()),
            .event(.init(transcript: ["birthday"])),
            .cross(.init(keywords: ["red bike"])),
        ]

        for value in values {
            let data = try JSONEncoder().encode(value)
            #expect(try decoder.decode(ArchivistQueryAST.self, from: data) == value)
        }
    }

    @Test func temporalExplicitYearIsTypedAndRoundTrips() throws {
        let value = ArchivistQueryAST.temporal(.init(
            subject: "Timmy", operation: .age, reference: .explicitYear(1997)))
        let data = try JSONEncoder().encode(value)
        #expect(try decoder.decode(ArchivistQueryAST.self, from: data) == value)
    }

    @Test func yearsMustStayWithinTheCatalogGrammarRange() {
        assertRejected(#"{"shape":"temporal","payload":{"subject":"Timmy","operation":"age","reference":{"kind":"explicitYear","year":1899}}}"#)
        assertRejected(#"{"shape":"presence","payload":{"yearStart":2100}}"#)
        assertRejected(#"{"shape":"event","payload":{"yearEnd":1899}}"#)
        assertRejected(#"{"shape":"cross","payload":{"yearStart":2100}}"#)
    }

    @Test func unknownDiscriminatorsAndEnumValuesAreRejected() {
        assertRejected(#"{"shape":"biography","payload":{}}"#)
        assertRejected(#"{"shape":"temporal","payload":{"subject":"Timmy","operation":"height","reference":{"kind":"currentSelection"}}}"#)
        assertRejected(#"{"shape":"temporal","payload":{"subject":"Timmy","operation":"age","reference":{"kind":"clipDate"}}}"#)
        assertRejected(#"{"shape":"aggregate","payload":{"operation":"count","anchorPeople":["Donna"],"limit":10}}"#)
        assertRejected(#"{"shape":"graph","payload":{"people":["Ellen"],"operation":"marriage"}}"#)
        assertRejected(#"{"shape":"graph","payload":{"people":["Ellen"],"operation":"kinship","relation":"cousin"}}"#)
        assertRejected(#"{"shape":"presence","payload":{"mediaKind":"hologram"}}"#)
    }

    @Test func unknownKeysAreRejectedAtEveryNestingLevel() {
        assertRejected(#"{"shape":"presence","payload":{},"answer":"Donna was there"}"#)
        assertRejected(#"{"shape":"presence","payload":{"transcript":["Donna"]}}"#)
        assertRejected(#"{"shape":"temporal","payload":{"subject":"Timmy","operation":"age","reference":{"kind":"currentSelection","year":1997}}}"#)
        assertRejected(#"{"shape":"aggregate","payload":{"operation":"coOccurrence","anchorPeople":["Donna"],"limit":10,"sql":"SELECT *"}}"#)
    }

    @Test func requiredSemanticFieldsCannotBeMissingOrNull() {
        assertRejected(#"{"shape":"temporal","payload":{"operation":"age","reference":{"kind":"currentSelection"}}}"#)
        assertRejected(#"{"shape":"temporal","payload":{"subject":"Timmy","operation":"age","reference":null}}"#)
        assertRejected(#"{"shape":"aggregate","payload":{"operation":"coOccurrence","anchorPeople":[],"limit":10}}"#)
        assertRejected(#"{"shape":"graph","payload":{"people":[],"operation":"biography"}}"#)
        assertRejected(#"{"shape":"presence","payload":{"people":null}}"#)
        assertRejected(#"{"shape":"temporal","payload":{"subject":"  ","operation":"age","reference":{"kind":"currentSelection"}}}"#)
        assertRejected(#"{"shape":"aggregate","payload":{"operation":"coOccurrence","anchorPeople":["Donna","  "],"limit":10}}"#)
        assertRejected(#"{"shape":"graph","payload":{"people":[""],"operation":"biography"}}"#)
        assertRejected(#"{"shape":"cross","payload":{"keywords":["red bike",""]}}"#)
    }

    @Test func relationIsRequiredOnlyForKinship() throws {
        let valid = #"{"shape":"graph","payload":{"people":["Ellen"],"operation":"kinship","relation":"mother"}}"#
        _ = try decoder.decode(ArchivistQueryAST.self, from: Data(valid.utf8))

        for operation in ["biography", "birth", "death"] {
            let json = #"{"shape":"graph","payload":{"people":["Ellen"],"operation":"\#(operation)"}}"#
            _ = try decoder.decode(ArchivistQueryAST.self, from: Data(json.utf8))
        }

        assertRejected(#"{"shape":"graph","payload":{"people":["Ellen"],"operation":"kinship"}}"#)
        assertRejected(#"{"shape":"graph","payload":{"people":["Ellen"],"operation":"biography","relation":"mother"}}"#)
    }

    @Test func arraysAndAggregateLimitHonorBothBounds() throws {
        let six = Array(repeating: "person", count: ArchivistQueryAST.maxListItems)
        let seven = Array(repeating: "person", count: ArchivistQueryAST.maxListItems + 1)

        let accepted = try JSONSerialization.data(withJSONObject: [
            "shape": "aggregate",
            "payload": [
                "operation": "coOccurrence", "anchorPeople": six,
                "limit": ArchivistQueryAST.resultLimitRange.upperBound,
            ],
        ])
        _ = try decoder.decode(ArchivistQueryAST.self, from: accepted)

        let inferredTopOne = #"{"shape":"aggregate","payload":{"operation":"coOccurrence","anchorPeople":["Donna"]}}"#
        #expect(try decoder.decode(
            ArchivistQueryAST.self, from: Data(inferredTopOne.utf8))
            == .aggregate(.init(operation: .coOccurrence,
                                anchorPeople: ["Donna"])))

        let oversizedCases: [[String: Any]] = [
            ["shape": "presence", "payload": ["people": seven]],
            ["shape": "presence", "payload": ["keywords": seven]],
            ["shape": "event", "payload": ["transcript": seven]],
            ["shape": "cross", "payload": ["people": seven]],
            ["shape": "cross", "payload": ["keywords": seven]],
            ["shape": "cross", "payload": ["transcript": seven]],
            ["shape": "graph", "payload": [
                "people": seven, "operation": "biography",
            ]],
            ["shape": "aggregate", "payload": [
                "operation": "coOccurrence", "anchorPeople": seven,
                "limit": 10,
            ]],
        ]
        for object in oversizedCases {
            let data = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: DecodingError.self) {
                try decoder.decode(ArchivistQueryAST.self, from: data)
            }
        }
        for limit in [0, ArchivistQueryAST.resultLimitRange.upperBound + 1] {
            let json = #"{"shape":"aggregate","payload":{"operation":"coOccurrence","anchorPeople":["Donna"],"limit":\#(limit)}}"#
            assertRejected(json)
        }
    }

    @Test func invertedYearRangesAreRejectedForEveryCatalogShape() {
        for shape in ["presence", "event", "cross"] {
            assertRejected(
                #"{"shape":"\#(shape)","payload":{"yearStart":2000,"yearEnd":1990}}"#)
        }
    }

    @Test func hostileStringsRemainData() throws {
        let hostile = #"answer\":\"Donna was there"#
        let data = try JSONSerialization.data(withJSONObject: [
            "shape": "cross",
            "payload": ["keywords": [hostile]],
        ])
        let decoded = try decoder.decode(ArchivistQueryAST.self, from: data)
        guard case .cross(let payload) = decoded else {
            Issue.record("expected cross payload")
            return
        }
        #expect(payload.keywords == [hostile])
    }

    @Test func topLevelAndPayloadMustBeObjects() {
        assertRejected(#"["presence"]"#)
        assertRejected(#"{"shape":"presence"}"#)
        assertRejected(#"{"shape":"presence","payload":[]}"#)
    }

    private func assertRejected(_ json: String) {
        #expect(throws: DecodingError.self) {
            try decoder.decode(ArchivistQueryAST.self, from: Data(json.utf8))
        }
    }
}
