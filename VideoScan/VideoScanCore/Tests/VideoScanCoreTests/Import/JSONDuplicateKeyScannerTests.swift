// JSONDuplicateKeyScannerTests.swift
// Codex D′ #2: the byte-level duplicate-key pre-pass. A duplicate anywhere
// in a document is found and named (path, key, catalog row ordinal), keys
// are compared after unescaping, strings that look like structure do not
// confuse it, a clean document scans to nil, the JSONL variant names the
// line, and a 100k-row document scans within a budget. One condition per #expect.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("JSONDuplicateKeyScannerTests")
struct JSONDuplicateKeyScannerTests {

    private static func scan(_ text: String) -> JSONDuplicateKeyScanner.Duplicate? {
        JSONDuplicateKeyScanner.firstDuplicate(in: Data(text.utf8))
    }

    @Test func aCleanDocumentHasNoDuplicate() {
        #expect(Self.scan(#"{"version":6,"records":[{"id":"a","userNotes":"x"},{"id":"b","userNotes":"y"}]}"#) == nil)
    }

    @Test func aRowCarryingOneKeyTwiceIsNamedWithItsOrdinal() {
        let found = Self.scan(#"{"version":6,"records":[{"id":"a"},{"id":"b","userNotes":"first","userNotes":"second"}]}"#)
        #expect(found == JSONDuplicateKeyScanner.Duplicate(path: "records[1].userNotes", key: "userNotes", recordOrdinal: 1))
    }

    @Test func aDuplicateInsideANestedObjectNamesTheWholePath() {
        let found = Self.scan(#"{"records":[{},{},{"scanContext":{"volumeUUID":"A","volumeUUID":"B"}}]}"#)
        #expect(found == JSONDuplicateKeyScanner.Duplicate(path: "records[2].scanContext.volumeUUID", key: "volumeUUID", recordOrdinal: 2))
    }

    @Test func aDuplicateAtTheTopLevelHasNoOrdinal() {
        let found = Self.scan(#"{"storeVersion":1,"events":[],"storeVersion":1}"#)
        #expect(found == JSONDuplicateKeyScanner.Duplicate(path: "storeVersion", key: "storeVersion", recordOrdinal: nil))
    }

    @Test func theSameKeyInTwoSiblingObjectsIsNotADuplicate() {
        #expect(Self.scan(#"{"a":{"k":1},"b":{"k":2},"c":[{"k":3},{"k":4}]}"#) == nil)
    }

    @Test func anEscapedKeyEqualsItsPlainSpelling() {
        let found = Self.scan(#"{"a":1,"\u0061":2}"#)
        #expect(found?.key == "a")
    }

    @Test func escapesInsideKeysAreResolvedBeforeComparing() {
        let found = Self.scan(#"{"line\nbreak":1,"line\u000Abreak":2}"#)
        #expect(found?.key == "line\nbreak")
    }

    @Test func stringsThatLookLikeStructureDoNotConfuseIt() {
        let text = #"{"a":"{\"a\":1,\"a\":2}","b":"[{,}]","c":"quote \" here","a2":"\\"}"#
        #expect(Self.scan(text) == nil)
    }

    @Test func aDuplicateAfterAnEscapedStringIsStillFound() {
        let found = Self.scan(#"{"a":"\\","b":"\"","a":2}"#)
        #expect(found?.path == "a")
    }

    @Test func aDuplicateInsideAnArrayOfArraysIsPathed() {
        let found = Self.scan(#"{"m":[[{"x":1,"x":2}]]}"#)
        #expect(found?.path == "m[0][0].x")
    }

    @Test func theLinesVariantNamesTheLine() {
        let lines = "{\"at\":1}\n{\"at\":1,\"at\":2}\n{\"at\":3}\n"
        let found = JSONDuplicateKeyScanner.firstDuplicate(inLines: Data(lines.utf8))
        #expect(found?.line == 1)
        #expect(found?.duplicate.key == "at")
    }

    @Test func aDocumentThatIsNotJSONReportsNoDuplicate() {
        #expect(Self.scan("not json at all {{{ \"a\"") == nil)
    }

    @Test func thePoisonedFixtureScansClean() {
        let fixture = PoisonedCatalogFixture()
        #expect(JSONDuplicateKeyScanner.firstDuplicate(in: fixture.catalogData) == nil)
        #expect(JSONDuplicateKeyScanner.firstDuplicate(in: fixture.auditData) == nil)
        for data in fixture.sidecarData.values {
            #expect(JSONDuplicateKeyScanner.firstDuplicate(in: data) == nil)
        }
    }
}

@Suite("JSONDuplicateKeyScannerScaleTests")
struct JSONDuplicateKeyScannerScaleTests {
    /// ≈ 9 MB of records: a byte loop in Debug is well under this; the
    /// 100k-row importer scale test covers the real file.
    static let budget: Duration = .seconds(10)

    @Test func hundredThousandRecordsScanWithinBudget() {
        var text = "{\"version\":6,\"records\":["
        text.reserveCapacity(10_000_000)
        for i in 0..<100_000 {
            if i > 0 { text += "," }
            text += "{\"id\":\"00000000-0000-4000-8000-\(String(format: "%012d", i))\",\"fullPath\":\"/V/\(i).mov\",\"userNotes\":\"n \\\"q\\\" \(i)\"}"
        }
        text += "]}"
        let data = Data(text.utf8)
        let loadBefore = TimingBudget.sampleLoad()
        let clock = ContinuousClock()
        let start = clock.now
        let found = JSONDuplicateKeyScanner.firstDuplicate(in: data)
        let elapsed = clock.now - start
        #expect(found == nil)
        expectWithinTimingBudget("duplicate-key scan 100k records", measured: elapsed, budget: Self.budget, loadBefore: loadBefore)
    }
}
