// CatalogTrashConfirmationTests.swift
// Codex delete-engines review 2026-10-09, F8 (P2): "Catalog's Trash action
// skips the required confirmation." The row menu's Move to Trash (and ⌘⌫ —
// both call trashSelectedRecords) started the move at once; design R9 keeps
// ONE confirmation.
//
// Now both go through one confirmation: "Move N files (X) to the Trash?",
// listing anything that will be held back, default = Move to Trash, Esc =
// Cancel. Pinned by a source sensor (both gestures, one door) and by the
// pure confirmation model.

import Foundation
import Testing
@testable import VideoScan

@Suite("Catalog Move to Trash — one confirmation for the row menu and ⌘⌫ (codex F8)")
struct CatalogTrashConfirmationSensorTests {

    private func body(_ code: String, from start: String, to end: String) throws -> Substring {
        let a = try #require(code.range(of: start), "no \(start)")
        let b = try #require(code.range(of: end, range: a.upperBound..<code.endIndex), "no \(end) after \(start)")
        return code[a.upperBound..<b.lowerBound]
    }

    @Test("sensor: the row menu and ⌘⌫ both confirm first, through ONE function")
    func bothGesturesConfirmThroughOneDoor() throws {
        let menu = try SourceTree.appCode(named: "CatalogRowContextMenu.swift")
        let table = try SourceTree.appCode(named: "CatalogContent+Table.swift")
        #expect(!menu.contains("model.trashSelectedRecords("), "the row menu must confirm first")
        #expect(menu.contains("confirmThenTrash(targets)"))
        let shortcut = try body(table, from: "private func trashSelectedRows()", to: "private func openSelectedRows()")
        #expect(!shortcut.contains("model.trashSelectedRecords("), "⌘⌫ must confirm first")
        #expect(shortcut.contains("confirmThenTrash(targets)"))
        let door = try body(table, from: "func confirmThenTrash(", to: "func reportDeleteResult(")
        #expect(door.components(separatedBy: "model.trashSelectedRecords(").count - 1 == 1, "the one hand-off")
        #expect(door.contains("CatalogTrashConfirmation("), "the words come from the pure model")
        #expect(door.contains("keyEquivalent = \"\\u{1b}\""), "Esc = Cancel")
    }
}

@Suite("Catalog Move to Trash — the confirmation's words (codex F8)")
@MainActor
struct CatalogTrashConfirmationTests {

    private func rec(_ size: Int64) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = "/tmp/test_conf_\(UUID().uuidString).mov"; r.filename = "x.mov"; r.sizeBytes = size
        return r
    }

    @Test func countsSizeAndEveryHeldReason() {
        let go = [rec(1_000_000), rec(2_000_000), rec(3_000_000)]
        let paired = rec(5), offline = rec(7)
        paired.pairGroupID = UUID()
        let all = go + [paired, offline]
        let plan = VideoScanModel.catalogTrashPlan(for: all, isMasterArchive: { _ in false },
                                                   isOffline: { $0 === offline })
        let c = CatalogTrashConfirmation(plan: plan, sizes: Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0.sizeBytes) }))
        #expect(c.canMove && c.moveCount == 3 && c.moveBytes == 6_000_000)
        let size = ByteCountFormatter.string(fromByteCount: 6_000_000, countStyle: .file)
        #expect(c.title == "Move 3 files (\(size)) to the Trash?")
        #expect(c.detail == "You can put them back from the Trash until you empty it.\n\n"
                + "2 will be held back: half of a recovered audio/video pair (1), drive not connected (1).")
        #expect(CatalogTrashConfirmation.moveButton == "Move to Trash")
    }

    @Test func oneFileAndNothingHeld() {
        let one = rec(4_096)
        let plan = VideoScanModel.catalogTrashPlan(for: [one], isMasterArchive: { _ in false }, isOffline: { _ in false })
        let c = CatalogTrashConfirmation(plan: plan, sizes: [one.id: 4_096])
        #expect(c.title.hasPrefix("Move 1 file (") && c.title.hasSuffix(") to the Trash?"))
        #expect(c.detail == "You can put it back from the Trash until you empty it.")
    }

    /// Nothing can move → no question is asked (the result explains).
    @Test func nothingCanMoveAsksNothing() {
        let archived = rec(10)
        let plan = VideoScanModel.catalogTrashPlan(for: [archived], isMasterArchive: { _ in true }, isOffline: { _ in false })
        let c = CatalogTrashConfirmation(plan: plan, sizes: [archived.id: 10])
        #expect(!c.canMove)
        #expect(c.held == [.init(reason: "in the Master Archive or on a protected drive", count: 1)])
    }
}
