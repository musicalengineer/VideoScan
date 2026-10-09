// CopiesAdviceSensorTests.swift
// SENSORS for "Copies & Advice…" (design §10):
//   * SCALE — building ONE card over a 100k-record catalog stays well
//     under a second (the card's promise: "opens in < 1 s for one file").
//     The main-actor part is one id-compare pass + O(group).
//   * MENUS — the item is the FIRST item of the Triage right-click, and sits
//     right after Get Info… in the Catalog row menu's inspect group.
//   * NO DELETE CODE — the card's files never remove, unlink or trash a
//     file themselves; the one delete button hands the record to the ⌘⌫
//     routine (`trashSelectedRecords`) and nothing else.

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@Suite("Copies & Advice — scale sensor (100k records)")
@MainActor
struct CopiesAdviceScaleTests {

    @Test func oneCardOver100kRecordsBuildsUnderBudget() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("copies_scale")
        defer { sb.cleanup() }
        let m = MasterArchiveTestSupport.makeModel(sb)
        let dupGroup = UUID(), footGroup = UUID()
        var rows: [VideoRecord] = []
        rows.reserveCapacity(100_000)
        for i in 0..<100_000 {
            let r = VideoRecord()
            r.fullPath = "/Volumes/test_Scale\(i % 7)/dir\(i % 100)/test_clip\(i).mov"
            r.filename = "test_clip\(i).mov"
            r.sizeBytes = 1_000_000
            r.partialMD5 = i % 5_000 == 0 ? "md5-same" : "md5-\(i)"
            if i % 5_000 == 0 { r.duplicateGroupID = dupGroup; r.dupAnalyzedAt = Date() }   // 20 copies
            if i % 2_000 == 1 {                                                              // 50 same-footage
                r.footage = FootageMembership(groupID: footGroup, groupSize: 50, confidence: .likely, role: .reEncode,
                                              rank: i / 2_000, likelyOriginalID: footGroup, originalInCatalog: true,
                                              evidence: ["same name + length"], scannedAt: Date(), algorithmVersion: 1)
            }
            rows.append(r)
        }
        let anchor = rows[0]
        anchor.footage = FootageMembership(groupID: footGroup, groupSize: 51, confidence: .likely, role: .original,
                                           rank: 0, likelyOriginalID: anchor.id, originalInCatalog: true,
                                           evidence: [], scannedAt: Date(), algorithmVersion: 1)
        m.records = rows

        let clock = ContinuousClock()
        var advice: CopiesAdvice?
        let mainPart = clock.measure {
            _ = CopiesAdviceInput.project(anchor, model: m)
        }
        let whole = await clock.measure {
            advice = await CopiesAdviceLoader.load(recordID: anchor.id, model: m)
        }
        let a = try #require(advice)
        #expect(a.copyCount == 20, "this + 19 sampled copies")
        #expect(a.sameFootage.count + a.sameFootageHidden == 50)
        #expect(a.verdict == .connect("test_Scale0"), "no test_Scale drive is connected, so the card waits for it")
        // Measured ≈ 30–60 ms in Debug on the M4; the budget is the card's
        // one-second promise with room for a loaded machine.
        #expect(mainPart < PerformanceLane.loadAwareDebugCeiling(.milliseconds(400)),
                "projection took \(mainPart) (\(PerformanceLane.loadDescription()))")
        #expect(whole < PerformanceLane.loadAwareDebugCeiling(.milliseconds(1_000)),
                "the whole card took \(whole) (\(PerformanceLane.loadDescription()))")
    }
}

@Suite("Copies & Advice — menu and no-delete-code sensors")
struct CopiesAdviceSensorTests {

    private func slice(_ text: String, from start: String, to end: String) throws -> Substring {
        let a = try #require(text.range(of: start), "no \(start)")
        let b = try #require(text.range(of: end, range: a.upperBound..<text.endIndex), "no \(end) after \(start)")
        return text[a.upperBound..<b.lowerBound]
    }

    @Test func theLabelIsCopiesAndAdvice() {
        #expect(CopiesAdviceText.menuLabel == "Copies & Advice\u{2026}")
        #expect(CopiesAdviceText.trashButton == "Move This Copy to Trash\u{2026}")
    }

    /// Triage: the FIRST thing the right-click builds, single selection only.
    @Test func itIsTheFirstItemOfTheTriageRightClick() throws {
        let code = try SourceTree.appCode(named: "TriageView.swift")
        let menu = try slice(code, from: "private func triageContextMenu(", to: "Section(\"Triage (")
        #expect(menu.contains("CopiesAdviceText.menuLabel"))
        #expect(menu.contains(".disabled(count != 1)"), "single selection only")
        #expect(!menu.contains("Button(role: .destructive)"))
        let item = try #require(menu.range(of: "CopiesAdviceText.menuLabel"))
        #expect(!menu[menu.startIndex..<item.lowerBound].contains("Section("), "nothing comes before it")
        #expect(code.contains(".sheet(item: $copiesAdviceRequest)"))
    }

    /// Catalog: Get Info… · Copies & Advice… · Verify… · Repair…, single row.
    @Test func itFollowsGetInfoInTheCatalogRowMenu() throws {
        let code = try SourceTree.appCode(named: "CatalogRowContextMenu+Media.swift")
        let group = try slice(code, from: "func mediaCheckMenuItems(", to: "func presentMediaInfo(")
        let info = try #require(group.range(of: "CatalogRowMenuText.getInfo"))
        let card = try #require(group.range(of: "CopiesAdviceText.menuLabel"))
        let verify = try #require(group.range(of: "checkMediaMenuItem("))
        #expect(info.lowerBound < card.lowerBound && card.lowerBound < verify.lowerBound)
        let single = try #require(group.range(of: "if activeRecs.count == 1 {"))
        #expect(single.lowerBound < card.lowerBound, "inside the single-row branch")
        let helpers = try SourceTree.appCode(named: "CatalogHelpers.swift")
        #expect(helpers.contains(".sheet(item: $copiesAdviceRequest)"))
    }

    /// The card has no delete code of its own: the only door is the ⌘⌫
    /// routine, called once, from the sheet.
    @Test func theCardHasNoDeleteCodeOfItsOwn() throws {
        let files = ["CopiesAdvice.swift", "CopiesAdvice+Projection.swift", "CopiesAdviceSheet.swift"]
        let forbidden = ["removeItem(", "trashItem(", "unlink(", "unlinkat(", "rmdir(", "deleteConfirmedJunk(",
                         "DeleteDuplicatesJob", "deleteDuplicates(", "recycle(", "renamex_np(", "moveItem("]
        for file in files {
            let code = try SourceTree.appCode(named: file)
            for word in forbidden {
                #expect(!code.contains(word), "\(file) must not call \(word)")
            }
        }
        let sheet = try SourceTree.appCode(named: "CopiesAdviceSheet.swift")
        #expect(sheet.components(separatedBy: "trashSelectedRecords(").count - 1 == 1,
                "exactly one hand-off to the ⌘⌫ routine")
        // …and it sits behind a fresh advice that still offers the Trash.
        let move = try slice(sheet, from: "private func moveThisCopyToTrash()", to: "trashSelectedRecords(")
        #expect(move.contains("CopiesAdviceLoader.load("))
        #expect(move.contains("fresh.offersTrash"))
        // The button only exists when the advice offers it.
        #expect(sheet.contains("if let a = advice, a.offersTrash {"))
    }
}
