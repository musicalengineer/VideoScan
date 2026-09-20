// LedgerNarratorTests.swift
// LOGIC for the template narrator (promote-and-prune stage 2): one
// sentence per event kind, the actor phrasing, the design's example
// sentences, newest-first ordering with stable ties, and the fixed-zone
// date text.

import XCTest
@testable import VideoScanCore

final class LedgerNarratorTests: XCTestCase {

    private let utc = TimeZone(identifier: "UTC")!
    private let id = UUID()

    private func e(_ kind: MediaLedgerEvent.Kind, by: MediaLedgerEvent.Actor = .rick,
                   at: Date? = nil, detail: [String: String] = [:]) -> MediaLedgerEvent {
        MediaLedgerEvent(at: at ?? Date(timeIntervalSince1970: 1_789_308_000), event: kind, recordID: id,
                         contentKey: "h:x", filename: "MyFavoriteVideo.mov", fullPath: "/Volumes/LaCie/MyFavoriteVideo.mov",
                         by: by, detail: detail)
    }

    private func one(_ ev: MediaLedgerEvent) -> String {
        LedgerNarrator.sentences(for: [ev], timeZone: utc).first ?? ""
    }

    func testDateTextIsFixedLocaleAndZone() {
        // 2026-09-12T20:00:00Z reads Sep 12 in UTC and Sep 13 in Auckland.
        let d = Date(timeIntervalSince1970: 1_789_243_200)
        let s = LedgerNarrator.sentences(for: [e(.restored, at: d)], timeZone: utc).first ?? ""
        XCTAssertTrue(s.hasSuffix("on Sep 12, 2026."), s)
        let nz = LedgerNarrator.sentences(for: [e(.restored, at: d)], timeZone: TimeZone(identifier: "Pacific/Auckland")!).first ?? ""
        XCTAssertTrue(nz.hasSuffix("on Sep 13, 2026."), nz)
    }

    func testDesignSentences() {
        let d = Date(timeIntervalSince1970: 1_789_243_200)   // Sep 12, 2026 UTC
        XCTAssertEqual(one(e(.archived, by: .promote, at: d, detail: ["archive": "FamilyArchive", "verified": "true", "fixity": "abc"])),
                       "Archived to FamilyArchive on Sep 12, 2026, read back and verified.")
        XCTAssertEqual(one(e(.approval, by: .rick, at: d, detail: ["count": "15", "files": "a.mov\nb.mov"])),
                       "You approved 15 copies to the Trash on Sep 12, 2026: a.mov, b.mov.")
        XCTAssertEqual(one(e(.copyDeleted, by: .rick, at: d, detail: ["volume": "LaCie"])),
                       "You deleted this copy permanently on Sep 12, 2026 (the copy on LaCie).")
        XCTAssertEqual(one(e(.copyTrashed, by: .rick, at: d)),
                       "You moved this copy to the Trash on Sep 12, 2026.")
    }

    func testEveryKindHasASentence() {
        for kind in MediaLedgerEvent.Kind.allCases {
            let s = one(e(kind))
            XCTAssertFalse(s.isEmpty, "\(kind)")
            XCTAssertTrue(s.hasSuffix("."), "\(kind): \(s)")
            XCTAssertTrue(s.contains("2026"), "\(kind): \(s)")
        }
    }

    func testActorPhrasing() {
        XCTAssertTrue(one(e(.setAside, by: .tidy, detail: ["reason": "still-image"])).hasPrefix("Tidy set it aside on"))
        XCTAssertTrue(one(e(.setAside, by: .tidy, detail: ["reason": "still-image"])).hasSuffix("— a photo, not a video."))
        XCTAssertTrue(one(e(.setAside, by: .rick, detail: ["reason": "removed-by-user"])).hasPrefix("You set it aside on"))
        XCTAssertTrue(one(e(.setAside, by: .rick, detail: ["reason": "removed-from-catalog"])).hasPrefix("You removed it from the catalog on"))
        XCTAssertTrue(one(e(.archived, by: .angel, detail: ["verified": "true"])).hasSuffix("verified. (Archive Angel)"))
        XCTAssertTrue(one(e(.archived, by: .promote, detail: ["verified": "false"])).contains("not yet verified"))
        XCTAssertTrue(one(e(.putBack, by: .app)).hasPrefix("VideoScan put it back"))
        XCTAssertTrue(one(e(.cataloged, by: .app, detail: ["volume": "LaCie"])).hasPrefix("Cataloged from LaCie on"))
    }

    func testPlaceDateAndAttestationTemplates() {
        XCTAssertTrue(one(e(.placeSet, detail: ["place": "Cape Cod", "confidence": "estimated"])).contains("set the place to Cape Cod on"))
        XCTAssertTrue(one(e(.placeSet, detail: ["place": "Cape Cod", "confidence": "estimated"])).hasSuffix("(best guess)."))
        XCTAssertTrue(one(e(.placeSet, detail: ["place": ""])).hasPrefix("You cleared the place on"))
        XCTAssertTrue(one(e(.dateSet, detail: ["date": "1992-07", "confidence": "known"])).hasSuffix("(you're sure)."))
        XCTAssertTrue(one(e(.dateSet, detail: ["date": ""])).hasPrefix("You cleared the date on"))
        XCTAssertTrue(one(e(.attestation, detail: ["kind": "cloud", "answer": "yes", "label": "iCloud"])).hasPrefix("You said there is a cloud copy (iCloud) on"))
        XCTAssertTrue(one(e(.attestation, detail: ["kind": "offsite", "answer": "no"])).hasPrefix("You said there is no off-site copy on"))
        XCTAssertTrue(one(e(.attestation, detail: ["kind": "offsite", "answer": "n/a"])).hasPrefix("You said an off-site copy does not apply on"))
        XCTAssertTrue(one(e(.attestation, detail: ["kind": "cloud", "answer": "n/a"])).hasPrefix("You said a cloud copy does not apply on"))
    }

    func testApprovalListTruncatesAfterFive() {
        let files = (1...8).map { "f\($0).mov" }.joined(separator: "\n")
        let s = one(e(.approval, detail: ["count": "8", "files": files]))
        XCTAssertTrue(s.contains("f1.mov, f2.mov, f3.mov, f4.mov, f5.mov and 3 more."), s)
        XCTAssertTrue(one(e(.approval, detail: ["count": "1"])).contains("approved 1 copy to the Trash"))
    }

    func testApprovalSaysWhenItWentAgainstTheBar() {
        let d = Date(timeIntervalSince1970: 1_789_243_200)   // Sep 12, 2026 UTC
        let against = "2 copies — ★★★ / Important — no cloud or off-site copy attested"
        XCTAssertEqual(one(e(.approval, at: d, detail: ["count": "2", "files": "a.mov\nb.mov", "override": against])),
                       "You approved 2 copies to the Trash on Sep 12, 2026: a.mov, b.mov — against the bar: \(against).")
        XCTAssertEqual(MediaLedgerEvent.Detail.barOverride, "override", "the stored key")
        XCTAssertFalse(one(e(.approval, at: d, detail: ["count": "2", "override": ""])).contains("against the bar"), "empty = respected the bar")
    }

    func testNewestFirstWithStableTies() {
        let t1 = Date(timeIntervalSince1970: 1_789_000_000)
        let t2 = Date(timeIntervalSince1970: 1_789_100_000)
        let a = e(.cataloged, at: t1), b = e(.setAside, at: t2, detail: ["reason": "music-format"]), c = e(.putBack, at: t2)
        let newest = LedgerNarrator.sentences(for: [a, b, c], timeZone: utc)
        XCTAssertTrue(newest[0].hasPrefix("You put it back"), "the LAST line written at an equal time comes first: \(newest)")
        XCTAssertTrue(newest[1].hasPrefix("You set it aside"))
        XCTAssertTrue(newest[2].hasPrefix("Cataloged"))
        let oldest = LedgerNarrator.sentences(for: [a, b, c], newestFirst: false, timeZone: utc)
        XCTAssertEqual(oldest, Array(newest.reversed()))
        XCTAssertEqual(LedgerNarrator.sentences(for: [], timeZone: utc), [])
    }
}
