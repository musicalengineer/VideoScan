// CatalogTrashPairGroupSensorTests.swift
// Source sensor for DECISIONS 2026-11-01 (a whole recovered A/V pair may be
// moved at once): the new logic lives in pure plan types, not in a new
// `extension VideoScanModel` (#337); none of the new files does file work
// of its own — `MediaTrash.move` stays the one Trash call, reached only
// through the one routine; the turn gate is wired into ⌘⌫; the row menu
// offers Select Related Halves through the shared rule.

import Foundation
import Testing
@testable import VideoScan

@Suite("Catalog Delete Selected Files — pair groups sensor")
@MainActor
struct CatalogTrashPairGroupSensorTests {

    static let newFiles = ["CatalogPairGroups.swift", "CatalogTrashGroupTurns.swift", "CatalogContent+RelatedHalves.swift"]

    @Test("sensor: no new extension VideoScanModel; the TrashSelection file keeps its one")
    func noNewModelExtension() throws {
        for name in Self.newFiles {
            let code = try SourceTree.appCode(named: name)
            #expect(!code.contains("extension VideoScanModel"), "\(name) adds model state (#337)")
        }
        let plan = try SourceTree.appCode(named: "VideoScanModel+TrashSelection.swift")
        #expect(plan.components(separatedBy: "extension VideoScanModel").count - 1 == 1)
    }

    @Test("sensor: the new files own no file operation; the one Trash routine and MediaTrash.move stay the only door")
    func noFileWorkOfTheirOwn() throws {
        for name in Self.newFiles {
            let code = try SourceTree.appCode(named: name)
            for banned in ["trashItem(", "removeItem(", "moveItem(", "unlink(", "rename(", "renamex_np", "FileManager", "MediaTrash."] {
                #expect(!code.contains(banned), "\(name) contains \(banned)")
            }
        }
        let plan = try SourceTree.appCode(named: "VideoScanModel+TrashSelection.swift")
        #expect(plan.contains("await deleteConfirmedJunk(targets, mode: .toTrash, reason: .catalogTrash, guard: fileGuard)"))
        #expect(!plan.contains("trashItem(") && !plan.contains("FileManager"))
        let engine = try SourceTree.appCode(named: "VideoScanModel+JunkDelete.swift")
        #expect(engine.contains("return try MediaTrash.move(url).path"), "the routine still moves through MediaTrash.move only")
        #expect(!engine.contains("trashItem("))
    }

    @Test("sensor: ⌘⌫ wires the pair gate into the plan and the turn, and the result names the pairs")
    func turnGateIsWired() throws {
        let plan = try SourceTree.appCode(named: "VideoScanModel+TrashSelection.swift")
        #expect(plan.contains("CatalogPairGroups.gate("), "the plan's pair gate")
        #expect(plan.contains("CatalogTrashGroupTurns(groups: confirmed.groups)"), "the turn gate is built from what was confirmed")
        #expect(plan.contains("groupTurns.settled(rec.id, moved: outcome.isMoved)"))
        #expect(plan.contains("groupDisk.problem(path) ?? proofs.problemAtTheMove(path)"), "identity proof before the copy proof")
        #expect(plan.contains("groups: groupTurns"))
        #expect(plan.contains("audit.finish(result, note:"), "OUTCOME carries the pairs")
        #expect(plan.contains("fileGuard.ledgerDetail"), "the ledger event carries the pair")
        // The Tidy predicate still starts the gate (CatalogTrashShortcutTests pins it too).
        #expect(plan.contains("CatalogScopePolicy.isPairProtected("))
    }

    @Test("sensor: the pair look-ahead asks a later half the SAME refusal list its own turn runs (Codex #194 F2)")
    func lookAheadUsesTheTurnsRefusalList() throws {
        let engine = try SourceTree.appCode(named: "VideoScanModel+JunkDelete.swift")
        let turnStart = try #require(engine.range(of: "private func junkTurn("))
        let turnEnd = try #require(engine.range(of: "func junkTurnOfflineRefusal(", range: turnStart.upperBound..<engine.endIndex))
        let turn = engine[turnStart.upperBound..<turnEnd.lowerBound]
        #expect(turn.contains("junkTurnOfflineRefusal(path)"), "the turn's offline refusal")
        #expect(turn.contains("junkTurnVerdict(rec, guard: fileGuard)"), "the turn's archive / marker / Read-only refusals")
        #expect(!turn.contains("CatalogMarkerRelay.saveRefusal"), "no refusal asked outside the shared list")
        #expect(!turn.contains("bulkDeleteRefusal("), "no refusal asked outside the shared list")
        let wouldStart = try #require(engine.range(of: "func junkTurnWouldRefuse("))
        let wouldEnd = try #require(engine.range(of: "func junkTurnVerdict(", range: wouldStart.upperBound..<engine.endIndex))
        let would = engine[wouldStart.upperBound..<wouldEnd.lowerBound]
        #expect(would.contains("junkTurnOfflineRefusal(rec.fullPath)") && would.contains("junkTurnVerdict(rec, guard: fileGuard)"))
        let plan = try SourceTree.appCode(named: "VideoScanModel+TrashSelection.swift")
        let aheadStart = try #require(plan.range(of: "func catalogTrashLaterHalvesProblem("))
        let ahead = plan[aheadStart.upperBound...].prefix(2_000)
        #expect(ahead.contains("junkTurnWouldRefuse(live, guard: nil)"), "the look-ahead asks the shared list")
        #expect(plan.contains("RemovalReservations.shared.isLeaving($0.path)"), "the look-ahead's survivor rule matches the move's pin")
    }

    @Test("sensor: the row menu offers Select Related Halves for a half, through the shared rule")
    func selectRelatedHalvesIsWired() throws {
        let menu = try SourceTree.appCode(named: "CatalogRowContextMenu+FileOps.swift")
        #expect(menu.contains("Button(\"Select Related Halves\")"))
        #expect(menu.contains("if CatalogPairGroups.isHalf(rec) {"))
        let gesture = try SourceTree.appCode(named: "CatalogContent+RelatedHalves.swift")
        #expect(gesture.contains("CatalogPairGroups.relatedSelection(of: rec, catalog: model.records"))
        #expect(gesture.contains("displayedIDs(among:"), "rows on screen only")
        #expect(gesture.contains("model.log(pick.line)"), "a hidden half is said, never silently dropped")
    }
}
