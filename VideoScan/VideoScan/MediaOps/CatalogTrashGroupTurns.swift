// CatalogTrashGroupTurns.swift
// Keeps a recovered audio/video pair whole at the move (DECISIONS
// 2026-11-01). The plan admits a group only when every half is selected and
// passes every gate (CatalogPairGroups.gate). At the move a confirmed pair
// is ONE unit of the one Trash routine (`JunkDeletionGuard.units`,
// `junkUnitTurn`; Codex #195 — no simulated look-ahead):
//   phase 1 — for EVERY half, its real turn: offline, this gate
//     (`problem`: confirmed whole, the very file the plan proved, its row
//     unchanged), the only-copy question, the turn's refusal list; then,
//     off-main, every half's real reservation at once (`reserveAll`), its
//     identity check (`CatalogTrashGroupDiskCheck`), its copy proof with
//     real pins, the archive / Read-only last words. Any refusal: nothing
//     moves, every reservation is released, the pair is held with that
//     reason.
//   phase 2 — the moves, in order, each re-checked (identity) under its own
//     reservation. A refusal or failure after the first move is the one
//     honest SPLIT: reported, never success, naming where each file is.
//
// Memory: O(selected group members) for the batch.
// (A `final class` ≈ a C++ object handed by pointer into the per-file
// callbacks, so they can record what each turn decided.)

import Foundation
import VideoScanCore

@MainActor
final class CatalogTrashGroupTurns {
    let groups: [CatalogPairGroups.Group]
    private var groupOf: [UUID: Int] = [:]
    private var stopped: [Int: String] = [:]

    init(groups: [CatalogPairGroups.Group]) {
        self.groups = groups
        for (gi, g) in groups.enumerated() { for id in g.members { groupOf[id] = gi } }
    }

    /// The members of `id`'s group, if it is in one.
    func group(of id: UUID) -> CatalogPairGroups.Group? { groupOf[id].map { groups[$0] } }


    /// The catalog half of a group member's turn in phase 1 of its unit
    /// (the routine runs it for EVERY member before any moves). nil = go on.
    func problem(_ rec: VideoRecord, model: VideoScanModel) -> String? {
        guard let gi = groupOf[rec.id] else { return Self.notConfirmedAsGroupNote }
        if let why = stopped[gi] { return CatalogPairGroups.groupHeldNote(why) + " — nothing moved" }
        let g = groups[gi]
        guard let k = g.members.firstIndex(of: rec.id) else { return Self.notConfirmedAsGroupNote }
        // The file this turn would move must be the one the plan proved
        // (Codex #191 F1) — a stale row object never moves.
        if rec.fullPath != g.paths[k] {
            return stop(gi, "\(g.filenames[k]) is not the file you confirmed (its catalog row points elsewhere)")
        }
        guard let live = model.record(forID: rec.id), Self.stillAsPlanned(live, g, k) else {
            return stop(gi, "\(g.filenames[k]) changed in the catalog since you confirmed")
        }
        return nil
    }

    /// Stop every confirmed group the plan now sees with other members
    /// (Codex #191 F2): its halves are held at their turns, before any moves.
    func holdGroups(notIn admitted: [CatalogPairGroups.Group], because why: String) {
        let now = Set(admitted.map(\.members))
        for (gi, g) in groups.enumerated() where !now.contains(g.members) { stopped[gi] = why }
    }

    /// The confirmed groups still to be moved as units (a stopped group's
    /// halves are held one by one at their turns).
    var activeGroups: [CatalogPairGroups.Group] {
        groups.indices.filter { stopped[$0] == nil }.map { groups[$0] }
    }

    private func stop(_ gi: Int, _ why: String) -> String {
        stopped[gi] = why
        return CatalogPairGroups.groupHeldNote(why) + " — nothing moved"
    }

    /// The live row is still the half the plan admitted. Its links may name
    /// only members — or a sibling that departed (Codex #195 F4).
    private static func stillAsPlanned(_ live: VideoRecord, _ g: CatalogPairGroups.Group, _ j: Int) -> Bool {
        guard !live.isPurged, !live.isSetAside, !live.isSuperseded,
              live.combinedFromPairID == nil,
              live.fullPath == g.paths[j], live.pairGroupID == g.pairGroupIDs[j] else { return false }
        let allowed = Set(g.members).union(g.departedIDs)
        if let p = live.pairedWith?.id, !allowed.contains(p) { return false }
        if let p = live.pendingPairedWithID, !allowed.contains(p) { return false }
        return true
    }

    /// The ledger detail keys a pair half's copyTrashed event carries.
    nonisolated static let ledgerPairGroup = "pairGroup"
    nonisolated static let ledgerPairFiles = "pairGroupFiles"

    nonisolated static let notConfirmedAsGroupNote =
        "is half of a recovered audio/video pair, which Combine still needs — it was not part of a whole pair you confirmed, so nothing moved"

    /// The disk half's identity check, as one Sendable value for the worker.
    var diskCheck: CatalogTrashGroupDiskCheck { CatalogTrashGroupDiskCheck(groups: groups) }

    // MARK: - The groups' outcome (OUTCOME line, alert)

    struct Summary: Equatable {
        var moved: [[String]] = []
        var held: [CatalogPairGroups.HeldGroup] = []
        var failed: [CatalogPairGroups.HeldGroup] = []
        /// Some halves moved, some did not: each line says where each file is.
        var split: [String] = []
        var isEmpty: Bool { moved.isEmpty && held.isEmpty && failed.isEmpty && split.isEmpty }

        /// "pair groups: moved 1 · held 1 · failed 0 · split 0"
        var counts: String {
            "pair groups: moved \(moved.count) · held \(held.count) · failed \(failed.count) · split \(split.count)"
        }

        /// The result alert's line: "Recovered A/V pairs: 1 moved whole, 1 kept."
        var alertCounts: String {
            var parts = ["\(moved.count) moved whole"]
            if !held.isEmpty { parts.append("\(held.count) kept") }
            if !failed.isEmpty { parts.append("\(failed.count) could not be moved") }
            if !split.isEmpty { parts.append("\(split.count) SPLIT — see below") }
            return "Recovered A/V pairs: " + parts.joined(separator: ", ") + "."
        }

        /// The result alert's lines (empty when no pair was involved).
        var alertNotes: [String] { isEmpty ? [] : [alertCounts] + split.map { "Split pair: " + $0 } }

        /// The OUTCOME line's addition (nil when no pair was involved).
        var outcomeNote: String? { isEmpty ? nil : counts }

        /// One console line per group that did not move whole.
        var lines: [String] {
            held.map { "Move to Trash: kept the pair \(CatalogPairGroups.list($0.filenames)) — \($0.reason)." }
                + failed.map { "Move to Trash: the pair \(CatalogPairGroups.list($0.filenames)) could not be moved — \($0.reason); every half is where it was." }
                + split.map { "Move to Trash: SPLIT PAIR — \($0)" }
        }
    }

    /// Every group the person confirmed plus every group the plan held,
    /// against the run's per-file outcomes.
    /// `alsoHeld`: groups admitted now that the person did not confirm as
    /// such (they changed in between) — held at their turns.
    /// `currentPath`: each member's catalog path NOW (a SPLIT names where a
    /// half that stayed is at report time — Codex #194 F3).
    func summary(plan: VideoScanModel.CatalogTrashPlan, alsoHeld: [CatalogPairGroups.Group] = [],
                 result: VideoScanModel.JunkDeletionResult,
                 currentPath: (UUID) -> String? = { _ in nil }) -> Summary {
        // A confirmed pair the plan now holds is summarised once, below,
        // from its members' outcomes.
        let confirmedIDs = Set(groups.flatMap(\.members))
        let planHeld = plan.heldGroups.filter { Set($0.ids).isDisjoint(with: confirmedIDs) }
        var s = Summary(held: planHeld + alsoHeld.filter { Set($0.members).isDisjoint(with: confirmedIDs) }.map {
            CatalogPairGroups.HeldGroup(filenames: $0.filenames, reason: "the pair changed since you confirmed", ids: $0.members)
        })
        let outcome = Dictionary(result.items.map { ($0.record.id, $0.outcome) }, uniquingKeysWith: { first, _ in first })
        for g in groups {
            let outs = g.members.map { outcome[$0] }
            let movedIdx = outs.indices.filter { outs[$0]?.isMoved == true }
            if movedIdx.count == g.members.count { s.moved.append(g.filenames); continue }
            guard let firstStay = outs.indices.first(where: { outs[$0]?.isMoved != true }) else { continue }
            let why = outs[firstStay].map { Self.words($0) } ?? "it was not reached"
            if movedIdx.isEmpty {
                let failed = outs.contains { $0?.kind == .failed }
                let group = CatalogPairGroups.HeldGroup(filenames: g.filenames, reason: "\(g.filenames[firstStay]) \(why)",
                                                        ids: g.members)
                if failed { s.failed.append(group) } else { s.held.append(group) }
                continue
            }
            let movedText = movedIdx.map { i -> String in
                if case .moved(_, let trash)? = outs[i], let trash { return "\(g.filenames[i]) is in the Trash (\(trash))" }
                return "\(g.filenames[i]) is in the Trash"
            }
            let stayed = outs.indices.filter { outs[$0]?.isMoved != true }.map { i in
                "\(g.filenames[i]) \(Self.location(planned: g.paths[i], now: currentPath(g.members[i]))) (\(outs[i].map { Self.words($0) } ?? "not reached"))"
            }
            s.split.append((movedText + stayed).joined(separator: "; ")
                           + " — put the moved half back (Show Removed ▸ Restore) or move the rest again.")
        }
        return s
    }

    /// Where a half that did not move is, as evidenced now: its current
    /// catalog path, "(relinked from …)" when that changed, and a plain
    /// "not found there now" when no file is at it.
    static func location(planned: String, now: String?) -> String {
        let path = now ?? planned
        var words = path == planned ? "stayed at \(path)" : "is at \(path) (relinked from \(planned))"
        if PairHalfIdentity.capture(path: path) == nil { words += " — not found there now" }
        return words
    }

    private static func words(_ o: VideoScanModel.JunkFileOutcome) -> String {
        switch o {
        case .moved: return "moved"
        case .held(let why): return why
        case .failed(let error): return "could not be moved (\(error.localizedDescription))"
        case .missing: return "was already gone"
        case .offline: return "is on a drive that is not connected"
        case .cancelled: return "was not reached — the run was stopped"
        }
    }
}

/// A group member's identity check (off the main actor, under its
/// reservation): the file at `path` still has the device + inode + size +
/// mtime the plan saw. Asked in phase 1 and again right before the move.
/// A path that is no group member is not this check's business.
struct CatalogTrashGroupDiskCheck: Sendable {
    private let identities: [String: (filename: String, identity: PairHalfIdentity)]

    init(groups: [CatalogPairGroups.Group]) {
        var map: [String: (filename: String, identity: PairHalfIdentity)] = [:]
        for g in groups { for k in g.members.indices { map[g.paths[k]] = (g.filenames[k], g.identities[k]) } }
        identities = map
    }

    /// nil = this is the file the plan saw.
    func problem(_ path: String) -> String? {
        guard let e = identities[path], PairHalfIdentity.capture(path: path) != e.identity else { return nil }
        return CatalogPairGroups.groupHeldNote("\(e.filename) changed or went away on disk since you confirmed (device, inode, size or date)")
            + " — nothing moved"
    }
}
