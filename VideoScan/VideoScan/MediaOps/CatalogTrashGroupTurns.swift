// CatalogTrashGroupTurns.swift
// Keeps a recovered audio/video pair whole at the move (DECISIONS
// 2026-11-01). The plan admits a group only when every half is selected and
// passes every gate (CatalogPairGroups.gate); this is that rule again at
// each half's TURN in the one Trash routine, so the group is never split by
// anything that changed after the confirmation:
//
//   catalog half (main actor, `problem`) — for the half whose turn it is:
//     * it belongs to a group the person confirmed (else: held);
//     * every member BEFORE it in the group actually moved (else: held — a
//       member that was held, offline or failed keeps the rest);
//     * it and every member AFTER it is still the row the plan saw: active,
//       same path, same pairGroupID, links only inside the group, and (for
//       the later ones) its drive is connected.
//   disk half (off-main, `CatalogTrashGroupDiskCheck.problem`) — immediately
//     before this half's own move, inside the routine's reservation: it and
//     every later member still has the device + inode + size + mtime the
//     plan saw (identity before and after).
// The first half of a group therefore checks the whole group before
// anything of it moves (refuse before mutating). What cannot be ruled out
// is a later half failing at its own move (the Trash refuses it, or a
// check flips in the microseconds between) after an earlier one moved:
// that is reported as SPLIT — never success — naming where each file is.
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
    private var moved: Set<UUID> = []
    private var stopped: [Int: String] = [:]

    init(groups: [CatalogPairGroups.Group]) {
        self.groups = groups
        for (gi, g) in groups.enumerated() { for id in g.members { groupOf[id] = gi } }
    }

    /// The members of `id`'s group, if it is in one.
    func group(of id: UUID) -> CatalogPairGroups.Group? { groupOf[id].map { groups[$0] } }

    /// The routine settled `id` (every turn, in order).
    func settled(_ id: UUID, moved didMove: Bool) {
        if didMove { moved.insert(id) }
    }

    /// The catalog half of a group member's turn. nil = go on.
    func problem(_ rec: VideoRecord, model: VideoScanModel,
                 isOffline: (VideoRecord) -> Bool) -> String? {
        guard let gi = groupOf[rec.id] else { return Self.notConfirmedAsGroupNote }
        if let why = stopped[gi] { return CatalogPairGroups.groupHeldNote(why) + " — nothing moved" }
        let g = groups[gi]
        guard let k = g.members.firstIndex(of: rec.id) else { return Self.notConfirmedAsGroupNote }
        // The file this turn would move must be the one the plan proved
        // (Codex #191 F1) — a stale row object never moves.
        if rec.fullPath != g.paths[k] {
            return stop(gi, "\(g.filenames[k]) is not the file you confirmed (its catalog row points elsewhere)")
        }
        for j in 0..<k where !moved.contains(g.members[j]) {
            return stop(gi, "its related half \(g.filenames[j]) did not move")
        }
        let members = Set(g.members)
        for j in k..<g.members.count {
            guard let live = model.record(forID: g.members[j]), Self.stillAsPlanned(live, g, j, members) else {
                return stop(gi, "its related half \(g.filenames[j]) changed in the catalog since you confirmed")
            }
            if j > k, isOffline(live) {
                return stop(gi, "the drive of its related half \(g.filenames[j]) is not connected")
            }
        }
        return nil
    }

    /// The members after `id` in its group (empty when it is in none).
    func laterMembers(after id: UUID) -> [UUID] {
        guard let g = group(of: id), let k = g.members.firstIndex(of: id) else { return [] }
        return Array(g.members[(k + 1)...])
    }

    /// Stop every confirmed group the plan now sees with other members
    /// (Codex #191 F2): its halves are held at their turns, before any moves.
    func holdGroups(notIn admitted: [CatalogPairGroups.Group], because why: String) {
        let now = Set(admitted.map(\.members))
        for (gi, g) in groups.enumerated() where !now.contains(g.members) { stopped[gi] = why }
    }

    /// May a Stop take effect before `id`'s turn? Not between the halves
    /// of a pair whose first half already moved (Codex #191 F7): the pair
    /// completes (or is reported SPLIT); Stop acts between pairs.
    func mayCancel(before id: UUID) -> Bool {
        guard let g = group(of: id), let k = g.members.firstIndex(of: id) else { return true }
        return !g.members[..<k].contains(where: moved.contains)
    }

    /// Stop `id`'s group for `why`; the held note for `id`.
    func hold(_ id: UUID, because why: String) -> String {
        guard let gi = groupOf[id] else { return Self.notConfirmedAsGroupNote }
        return stop(gi, why)
    }

    private func stop(_ gi: Int, _ why: String) -> String {
        stopped[gi] = why
        return CatalogPairGroups.groupHeldNote(why) + " — nothing moved"
    }

    /// The live row is still the half the plan admitted.
    private static func stillAsPlanned(_ live: VideoRecord, _ g: CatalogPairGroups.Group, _ j: Int,
                                       _ members: Set<UUID>) -> Bool {
        guard !live.isPurged, !live.isSetAside, !live.isSuperseded,
              live.combinedFromPairID == nil,
              live.fullPath == g.paths[j], live.pairGroupID == g.pairGroupIDs[j] else { return false }
        if let p = live.pairedWith?.id, !members.contains(p) { return false }
        if let p = live.pendingPairedWithID, !members.contains(p) { return false }
        return true
    }

    /// The ledger detail keys a pair half's copyTrashed event carries.
    nonisolated static let ledgerPairGroup = "pairGroup"
    nonisolated static let ledgerPairFiles = "pairGroupFiles"

    nonisolated static let notConfirmedAsGroupNote =
        "is half of a recovered audio/video pair, which Combine still needs — it was not part of a whole pair you confirmed, so nothing moved"

    /// The disk half's checks, as one Sendable value for the worker.
    /// `laterProofs` holds what the later halves must prove (filled by
    /// `catalogTrashLaterHalvesProblem` at the same turn).
    func diskCheck(laterProofs: CatalogTrashMoveProofs) -> CatalogTrashGroupDiskCheck {
        CatalogTrashGroupDiskCheck(groups: groups, laterProofs: laterProofs)
    }

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

/// The disk half of a group member's turn (off the main actor): this half
/// and every later member still has the identity the plan recorded, and
/// every later member's surviving-copy proof (when it has one) holds now.
/// Keyed by path; a path that is no group member is not this check's business.
struct CatalogTrashGroupDiskCheck: Sendable {
    struct Entry: Sendable {
        let filename: String
        let path: String
        let identity: PairHalfIdentity
    }
    private let fromHere: [String: [Entry]]
    private let laterProofs: CatalogTrashMoveProofs

    init(groups: [CatalogPairGroups.Group], laterProofs: CatalogTrashMoveProofs) {
        self.laterProofs = laterProofs
        var map: [String: [Entry]] = [:]
        for g in groups {
            let entries = g.members.indices.map { Entry(filename: g.filenames[$0], path: g.paths[$0], identity: g.identities[$0]) }
            for k in entries.indices { map[entries[k].path] = Array(entries[k...]) }
        }
        fromHere = map
    }

    /// nil = every member from this one on is the file the plan saw.
    func problem(_ path: String) -> String? {
        guard let entries = fromHere[path] else { return nil }
        for e in entries where PairHalfIdentity.capture(path: e.path) != e.identity {
            let who = e.path == path ? "it" : "its related half \(e.filename)"
            return CatalogPairGroups.groupHeldNote("\(who) changed or went away on disk since you confirmed (device, inode, size or date)")
                + " — nothing moved"
        }
        for e in entries.dropFirst() {
            // Codex #191 F4: a later half another removal holds (leaving, or
            // relied on as a survivor) would be held at its own turn.
            if RemovalReservations.shared.isReserved(e.path) {
                return CatalogPairGroups.groupHeldNote("its related half \(e.filename) is being removed or relied on by another job right now")
                    + " — nothing moved"
            }
            if let why = laterProofs.problemAhead(e.path) {
                let bare = why.replacingOccurrences(of: " — nothing moved", with: "")
                return CatalogPairGroups.groupHeldNote("its related half \(e.filename): \(bare)") + " — nothing moved"
            }
        }
        return nil
    }
}
