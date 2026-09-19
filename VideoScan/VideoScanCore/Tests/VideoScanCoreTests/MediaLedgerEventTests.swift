// MediaLedgerEventTests.swift
// LOGIC for the Media Ledger line model (promote-and-prune stage 2, Rick
// 2026-09-12): the frozen key set, the millisecond timestamp round trip,
// the content key, the JSONL codec's tolerance of blank / broken lines,
// and the on-disk vocabulary (raw values are a contract).

import XCTest
@testable import VideoScanCore

final class MediaLedgerEventTests: XCTestCase {

    // 2026-09-12T20:00:00.123Z
    private let at = Date(timeIntervalSince1970: 1_789_243_200.123)
    private let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    private func event(_ kind: MediaLedgerEvent.Kind = .archived, by: MediaLedgerEvent.Actor = .promote,
                       batchID: String? = "b1", detail: [String: String] = ["fixity": "abc", "verified": "true"]) -> MediaLedgerEvent {
        MediaLedgerEvent(at: at, event: kind, recordID: id, contentKey: "h:v1:deadbeef",
                         filename: "a.mov", fullPath: "/Volumes/T/a.mov", by: by, batchID: batchID, detail: detail)
    }

    func testVocabularyIsFrozen() {
        XCTAssertEqual(MediaLedgerEvent.Kind.allCases.map(\.rawValue),
                       ["cataloged", "setAside", "putBack", "archived", "copyTrashed", "copyDeleted",
                        "restored", "placeSet", "dateSet", "attestation", "approval",
                        "angelProposed", "angelSkipped", "angelCleared"])
        XCTAssertEqual(MediaLedgerEvent.Actor.allCases.map(\.rawValue), ["rick", "tidy", "promote", "angel", "app"])
    }

    func testLineIsSortedKeysWithMillisecondTimestampAndNoTrailingNewline() throws {
        let data = try MediaLedgerEvent.encodeLine(event())
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("{\"at\":\"2026-09-12T"), text)
        XCTAssertTrue(text.contains(".123Z\""), "millisecond precision: \(text)")
        XCTAssertTrue(text.contains("\"batchID\":\"b1\""))
        XCTAssertTrue(text.contains("\"by\":\"promote\""))
        XCTAssertTrue(text.contains("\"event\":\"archived\""))
        XCTAssertTrue(text.contains("\"fullPath\":\"/Volumes/T/a.mov\""), "slashes unescaped")
        XCTAssertFalse(text.hasSuffix("\n"))
        // Key order is alphabetical (byte-stable for a given event).
        let keys = ["at", "batchID", "by", "contentKey", "detail", "event", "filename", "fullPath", "recordID"]
        var last = text.startIndex
        for k in keys {
            let r = try XCTUnwrap(text.range(of: "\"\(k)\":", range: last..<text.endIndex), k)
            last = r.upperBound
        }
    }

    func testRoundTripEqualsItselfAndBatchIDKeyOmittedWhenNil() throws {
        let e = event()
        let back = try XCTUnwrap(MediaLedgerEvent.decodeLine(Substring(String(decoding: try MediaLedgerEvent.encodeLine(e), as: UTF8.self))))
        XCTAssertEqual(back, e)
        XCTAssertEqual(back.at, BackupAttestation.Timestamp.quantized(at))

        let none = event(batchID: nil)
        let text = String(decoding: try MediaLedgerEvent.encodeLine(none), as: UTF8.self)
        XCTAssertFalse(text.contains("batchID"))
        XCTAssertNil(MediaLedgerEvent.decodeLine(Substring(text))?.batchID)
        // Blank batch ids are nil too.
        XCTAssertNil(event(batchID: "   ").batchID)
    }

    func testEncodeLinesTerminatesEveryLineAndDecodeSkipsJunk() throws {
        let data = try MediaLedgerEvent.encodeLines([event(.cataloged), event(.setAside)])
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(text.filter { $0 == "\n" }.count, 2)
        XCTAssertTrue(text.hasSuffix("\n"))
        let poisoned = text + "\n\n{not json\n" + "{\"at\":\"x\"}\n" + text
        let events = MediaLedgerEvent.decodeLines(poisoned)
        XCTAssertEqual(events.map(\.event), [.cataloged, .setAside, .cataloged, .setAside])
    }

    func testDecoderToleratesMissingOptionalKeysAndWholeSecondTimestamps() throws {
        let minimal = "{\"at\":\"2026-09-12T20:00:00Z\",\"event\":\"restored\",\"recordID\":\"\(id.uuidString)\"}"
        let e = try XCTUnwrap(MediaLedgerEvent.decodeLine(Substring(minimal)))
        XCTAssertEqual(e.event, .restored)
        XCTAssertEqual(e.by, .app)
        XCTAssertEqual(e.contentKey, "")
        XCTAssertEqual(e.filename, "")
        XCTAssertEqual(e.detail, [:])
        XCTAssertEqual(e.at, Date(timeIntervalSince1970: 1_789_243_200))
        // An unknown kind is a broken line, not a crash.
        XCTAssertNil(MediaLedgerEvent.decodeLine(Substring(minimal.replacingOccurrences(of: "restored", with: "teleported"))))
    }

    func testContentKeyPrefersHashThenPartialMD5ThenUnknown() {
        XCTAssertEqual(MediaLedgerEvent.contentKey(contentHash: "v1:abc", partialMD5: "m", sizeBytes: 10), "h:v1:abc")
        XCTAssertEqual(MediaLedgerEvent.contentKey(contentHash: "", partialMD5: "m", sizeBytes: 10), "p:m:10")
        XCTAssertEqual(MediaLedgerEvent.contentKey(contentHash: "", partialMD5: "m", sizeBytes: 0), "")
        XCTAssertEqual(MediaLedgerEvent.contentKey(contentHash: "", partialMD5: "", sizeBytes: 10), "")
    }

    func testDetailSurvivesUnicodeAndNewlines() throws {
        let e = event(.approval, by: .rick, detail: ["files": "Ma’s 80th.mov\nDad “USMC”.mov", "count": "2"])
        let back = try XCTUnwrap(MediaLedgerEvent.decodeLine(Substring(String(decoding: try MediaLedgerEvent.encodeLine(e), as: UTF8.self))))
        XCTAssertEqual(back.detail["files"], "Ma’s 80th.mov\nDad “USMC”.mov")
        XCTAssertEqual(back.detail["count"], "2")
    }
}
