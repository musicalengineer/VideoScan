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
        #expect(plan.contains("fileGuard.units = groupTurns.activeGroups.map(\\.members)"), "a confirmed pair is one unit of the routine")
        #expect(plan.contains("fileGuard.atTheMove = { path in groupDisk.problem(path) }"), "identity re-checked before each move")
        #expect(plan.contains("groupDisk.problem(path) ?? proofs.problemAtTheMove(path)"), "identity proof before the copy proof")
        #expect(plan.contains("groups: groupTurns"))
        #expect(plan.contains("audit.finish(result, note:"), "OUTCOME carries the pairs")
        #expect(plan.contains("fileGuard.ledgerDetail"), "the ledger event carries the pair")
        // The Tidy predicate still starts the gate (CatalogTrashShortcutTests pins it too).
        #expect(plan.contains("CatalogScopePolicy.isPairProtected("))
    }

    @Test("sensor: a unit runs every member's REAL turn — the same functions as one file's turn — and no simulated look-ahead (Codex #195)")
    func unitRunsTheRealTurn() throws {
        let engine = try SourceTree.appCode(named: "VideoScanModel+JunkDelete.swift")
        let turnStart = try #require(engine.range(of: "private func junkTurn("))
        let turnEnd = try #require(engine.range(of: "private func junkUnitTurn(", range: turnStart.upperBound..<engine.endIndex))
        let turn = engine[turnStart.upperBound..<turnEnd.lowerBound]
        #expect(turn.contains("junkTurnOfflineRefusal(path)") && turn.contains("fileGuard.authorize(rec)")
                && turn.contains("junkTurnVerdict(rec, guard: fileGuard)"), "one file's turn")
        #expect(!turn.contains("CatalogMarkerRelay.saveRefusal") && !turn.contains("bulkDeleteRefusal("),
                "no refusal asked outside the shared list")
        let unitEnd = try #require(engine.range(of: "nonisolated static func unitHeld(", range: turnEnd.upperBound..<engine.endIndex))
        let unit = engine[turnEnd.upperBound..<unitEnd.lowerBound]
        #expect(unit.contains("junkTurnOfflineRefusal(rec.fullPath)") && unit.contains("fileGuard.authorize(rec)")
                && unit.contains("junkTurnVerdict(rec, guard: fileGuard)"), "a unit asks each member the very same gates")
        #expect(unit.contains("disk.runUnit("))
        let diskStart = try #require(engine.range(of: "func runUnit("))
        let diskEnd = try #require(engine.range(of: "func run(path: String", range: diskStart.upperBound..<engine.endIndex))
        let disk = engine[diskStart.upperBound..<diskEnd.lowerBound]
        #expect(disk.contains("RemovalReservations.shared.reserveAll("), "every member's real reservation, at once")
        #expect(disk.contains("beforeRemoval(m.path)") && disk.contains("protectionRefusal(path: m.path"), "each member's real proof and last words")
        #expect(disk.contains("try perform(URL(fileURLWithPath: m.path))"), "the moves go through the one file operation")
        let plan = try SourceTree.appCode(named: "VideoScanModel+TrashSelection.swift")
        for gone in ["LaterHalves", "problemAhead", "isLeaving", "junkTurnWouldRefuse"] {
            #expect(!plan.contains(gone) && !engine.contains(gone), "no simulated look-ahead: \(gone)")
        }
        // Codex #197: the selection names intent, the LIVE catalog decides.
        #expect(plan.contains("let requested = liveSelection(selected)"), "the routine gets the catalog's own rows")
        #expect(plan.contains("let records = liveSelection(selected)"), "the plan too")
        let turns = try SourceTree.appCode(named: "CatalogTrashGroupTurns.swift")
        let probStart = try #require(turns.range(of: "func problem(_ rec: VideoRecord, model: VideoScanModel)"))
        let probEnd = try #require(turns.range(of: "func holdGroups(", range: probStart.upperBound..<turns.endIndex))
        let problem = turns[probStart.upperBound..<probEnd.lowerBound]
        #expect(problem.contains("model.record(forID: rec.id)") && problem.contains("resolve(live, in: liveIndex(model))"),
                "membership is resolved again from the live row and the live index")
        #expect(problem.contains("nowIDs != confirmedIDs"), "the live set must equal the confirmed set")
        for field in ["rec.pairGroupID", "rec.pairedWith", "rec.pendingPairedWithID", "rec.removal", "rec.isPurged", "rec.combinedFromPairID"] {
            #expect(!problem.contains(field), "the turn never reads \(field) from the selection's row")
        }
        let groups = try SourceTree.appCode(named: "CatalogPairGroups.swift")
        // Codex #201 F1: the settlement walks with THE SAME function phase 1 uses.
        #expect(turns.contains("CatalogPairGroups.resolve(live, in: liveIndex(model))"), "phase 1's walk")
        #expect(turns.contains("CatalogPairGroups.resolve(first, in: index, treatAsLive: Set(g.members))"), "the settlement's walk")
        #expect(turns.components(separatedBy: "CatalogPairGroups.resolve(").count - 1 == 2, "no third walk")
        #expect(plan.contains("groupTurns.changesDuringMove(g, moved: moved, model: self, index: afterMoves)"))
        #expect(!plan.contains("linkedOutside") && !groups.contains("linkedOutside"), "the old one-sided settlement walk is gone")
        // Codex #195 F1: every row in a group in ANY link direction meets the gate.
        #expect(groups.contains("for half in selection where index.isGroupMember(half)"))
        #expect(plan.contains("member: gate.seen.contains(rec.id)"), "a member the gate saw never falls through to ordinary")
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
