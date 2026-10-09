// JunkTrashOnlyTests.swift
// 🔴 fix 3 + design R3 (codex design review F3, 2026-10-09): Trash only is
// an EXECUTION rule, not a missing button. The app never deletes
// permanently on the Delete Junk / Move to Trash paths — Rick empties the
// Trash himself ("trash day"). So:
//   - no "Delete Permanently" anywhere on these paths (row menu, Triage
//     sheet), and no code on them that can ask for `.permanent`;
//   - a file really lands in the Trash (it is not unlinked);
//   - a Trash failure HOLDS the file — "couldn't move it to the Trash on
//     <drive>: <why> — nothing was deleted" — with exactly one attempt,
//     never a fallback to another kind of removal.
//
// `.permanent` stays in JunkDeletionMode ONLY as the prune lane's test
// mode (its fixtures stay out of the real Trash); the sensor below pins
// that no production call site passes it.

import Foundation
import Testing
@testable import VideoScan

@Suite("Delete Junk / Move to Trash — Trash only, at execution", .serialized)
@MainActor
struct JunkTrashOnlyTests {

    /// The files of the user-facing junk paths (Triage Delete Junk, the
    /// Catalog row menu's Move to Trash, ⌘⌫) — none may remove a file
    /// itself, or ask the routine for anything but the Trash.
    static let junkLaneFiles = [
        "TriageView.swift", "JunkDeleteAction.swift", "DeleteConfirmedJunkSheet.swift",
        "VideoScanModel+JunkTrashSnapshot.swift", "VideoScanModel+TrashSelection.swift",
        "JunkDeletionReport.swift", "CatalogRowContextMenu.swift", "CatalogContent+Table.swift",
        "CatalogRowMenuPlan.swift",
    ]

    @Test("sensor: no junk-lane file can delete permanently, unlink, or offer Delete Permanently")
    func noPermanentOnTheJunkLanes() throws {
        for file in Self.junkLaneFiles {
            let code = try SourceTree.appCode(named: file)
            for banned in [".permanent", "removeItem(", "unlink(", "Delete Permanently", "deletePermanently"] {
                #expect(!code.contains(banned), "\(file) contains \(banned)")
            }
        }
    }

    @Test("sensor: no production call site anywhere passes .permanent to the Trash routine")
    func noProductionCallerAsksForPermanent() throws {
        // Whole app, comment lines dropped (some files hold regex literals
        // the code-only stripper refuses — same reader as the row menu's
        // old-verbs sensor).
        var hits: [String] = []
        for entry in SourceTree.appSources {
            let name = (entry.relative as NSString).lastPathComponent
            let text = try String(contentsOf: entry.url, encoding: .utf8)
            for line in text.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                for banned in ["mode: .permanent", "JunkDeletionMode.permanent", "onAct(.permanent)"] where line.contains(banned) {
                    hits.append("\(name): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        #expect(hits.isEmpty, "\(hits)")
        // The routine's own switch is the one place the case is spelled out.
        let engine = try SourceTree.appCode(named: "VideoScanModel+JunkDelete.swift")
        #expect(engine.contains("case .permanent:"))
    }

    @Test("the row menu's Delete File is ONE item: Move to Trash")
    func rowMenuIsMoveToTrashOnly() throws {
        let menu = try SourceTree.appCode(named: "CatalogRowContextMenu.swift")
        #expect(menu.contains("CatalogRowMenuText.moveToTrash(count:"))
        #expect(menu.contains("accessibilityIdentifier(\"catalog.row.moveToTrash\")"))
        #expect(!menu.contains("catalog.row.deleteToTrash"), "the old submenu item")
        #expect(CatalogRowMenuText.moveToTrash(count: 1) == "Move to Trash")
        #expect(CatalogRowMenuText.moveToTrash(count: 3) == "Move 3 Files to Trash")
    }

    // MARK: Behaviour

    /// No seam: the real routine. The file must be FOUND in the Trash
    /// afterwards — proof it was moved there, not unlinked. (The fixture's
    /// name is unique; the test removes its own fixture from the Trash.)
    @Test("Delete Junk really moves the file to the Trash — it is found there, not unlinked")
    func reallyLandsInTheTrash() async throws {
        let sb = try JunkTrashSandbox("realtrash"); defer { sb.cleanup() }
        let model = sb.model()
        let name = "test_junktrash_\(UUID().uuidString).mov"
        let a = sb.junk(try sb.write(name))
        model.records = [a]
        let snapshot = await model.freezeJunkSnapshot([a], isOffline: { _ in false })

        let result = await model.trashFrozenJunk(snapshot)
        let trash = try #require(FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first)
        let inTrash = trash.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: inTrash) }
        #expect(result.succeeded == 1)
        #expect(!FileManager.default.fileExists(atPath: a.fullPath))
        #expect(FileManager.default.fileExists(atPath: inTrash.path), "the file is not in the Trash — it was unlinked")
        #expect(a.lifecycleStage == .trashed)
        await model.mediaLedger.waitForPendingWrites()
        let kinds = model.mediaLedger.allEvents().map(\.event)
        #expect(kinds.contains(.copyTrashed) && !kinds.contains(.copyDeleted), "\(kinds)")
    }

    @Test("Delete Junk: a Trash failure HOLDS the file with the drive and the reason — one attempt, nothing deleted")
    func frozenTrashFailureHolds() async throws {
        let sb = try JunkTrashSandbox("trashfail"); defer { sb.cleanup() }
        let model = sb.model()
        let a = sb.junk(try sb.write("test_a.mov"))
        model.records = [a]
        let snapshot = await model.freezeJunkSnapshot([a], isOffline: { _ in false })
        sb.trash.failEverything(with: CocoaError(.featureUnsupported))   // "no Trash on this volume"

        let result = await model.trashFrozenJunk(snapshot, fileOperation: sb.trash.operation)
        #expect(sb.trash.attempts == [a.fullPath], "exactly one attempt — never a second, permanent one")
        #expect(FileManager.default.fileExists(atPath: a.fullPath) && a.purgedAt == nil)
        #expect(result.failed.isEmpty && result.refused.count == 1, "a Trash refusal is a hold: \(result.items.map(\.outcome.kind))")
        let why = result.refused.first?.reason ?? ""
        #expect(why.hasPrefix("couldn't move it to the Trash on ") && why.hasSuffix(" — nothing was deleted"), "\(why)")
        await model.mediaLedger.waitForPendingWrites()
        #expect(model.mediaLedger.allEvents().isEmpty)
    }

    @Test("⌘⌫ / row menu: a Trash failure HOLDS the file the same way")
    func catalogTrashFailureHolds() async throws {
        let sb = try JunkTrashSandbox("cmdtrashfail"); defer { sb.cleanup() }
        let model = sb.model()
        let a = sb.junk(try sb.write("test_a.mov"))
        model.records = [a]
        sb.trash.failEverything(with: CocoaError(.fileWriteNoPermission))

        let result = await model.trashSelectedRecords([a], fileOperation: sb.trash.operation)
        #expect(sb.trash.attempts == [a.fullPath])
        #expect(FileManager.default.fileExists(atPath: a.fullPath) && a.purgedAt == nil)
        #expect(result.refused.first?.reason.contains("couldn't move it to the Trash on ") == true, "\(result.refused.map(\.reason))")
        #expect(result.refused.first?.reason.hasSuffix("— nothing was deleted") == true)
    }
}
