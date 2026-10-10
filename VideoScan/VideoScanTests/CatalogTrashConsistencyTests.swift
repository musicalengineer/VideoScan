// CatalogTrashConsistencyTests.swift
// Item 6 of the Delete Junk streamline (2026-10-09): the Catalog's two
// "Move to Trash" gestures — ⌘⌫ and the row menu's Move to Trash — go
// through the SAME function (`trashSelectedRecords`), so they behave
// identically: the same gates (Master Archive, Read only, A/V pair half,
// offline), the same held-with-reason results, and the same ignore list
// (before, ⌘⌫ wrote the ignore list and the row menu did not). And the
// dead CatalogToolbar Delete Junk sheets stay gone.

import Foundation
import Testing
@testable import VideoScan

@Suite("Catalog Move to Trash — ⌘⌫ and the row menu are one path", .serialized)
@MainActor
struct CatalogTrashConsistencyTests {

    @Test("sensor: the row menu's Move to Trash calls trashSelectedRecords, like ⌘⌫ — never the routine directly")
    func rowMenuAndShortcutShareOneFunction() throws {
        // Since codex delete-engines F8 both go through ONE confirmation,
        // `confirmThenTrash`, which makes the one trashSelectedRecords call.
        let menu = try SourceTree.appCode(named: "CatalogRowContextMenu.swift")
        #expect(menu.contains("confirmThenTrash(targets)"))
        #expect(!menu.contains("deleteConfirmedJunk("), "the row menu bypasses the shared Move to Trash")
        let table = try SourceTree.appCode(named: "CatalogContent+Table.swift")
        #expect(table.contains("let result = await model.trashSelectedRecords(targets)"))
        #expect(table.contains("reportDeleteResult(result)"))
        #expect(!table.contains("deleteConfirmedJunk("))
    }

    @Test("sensor: the dead CatalogToolbar Delete Junk sheets are gone")
    func deadToolbarSheetsAreGone() throws {
        let toolbar = try SourceTree.appCode(named: "CatalogToolbar.swift")
        for gone in ["openJunkConfirmSheet", "DeleteConfirmedJunkConfirmSheet", "DeleteConfirmedJunkResultSheet",
                     "JunkDeleteAction", "showJunkConfirmSheet", "junkResultMode"] {
            #expect(!toolbar.contains(gone), "CatalogToolbar still has \(gone)")
        }
    }

    /// The shared function's ignore-list rule, through the seam: what left
    /// the disk is remembered; what stayed is not.
    @Test("the shared Move to Trash remembers what moved on the ignore list, and nothing that stayed")
    func ignoreListFollowsWhatMoved() async throws {
        let sb = try JunkTrashSandbox("ignore"); defer { sb.cleanup() }
        let model = sb.model()
        let moved = sb.junk(try sb.write("test_moved.mov"))
        moved.partialMD5 = "md5moved"
        let pair = sb.junk(try sb.write("test_pair.mxf"))
        pair.pairGroupID = UUID()
        pair.partialMD5 = "md5pair"
        model.records = [moved, pair]

        let result = await model.trashSelectedRecords([moved, pair], fileOperation: sb.trash.operation)
        #expect(result.succeeded == 1 && result.refused.count == 1)
        let store = model.ignoredContentStore
        #expect(store.contains(partialMD5: moved.partialMD5, sizeBytes: moved.sizeBytes, filename: moved.filename))
        #expect(!store.contains(partialMD5: pair.partialMD5, sizeBytes: pair.sizeBytes, filename: pair.filename))
    }
}
