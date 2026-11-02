// CatalogPairGroups.swift
// "Which files are the halves of this recovered audio/video clip?" — and the
// Delete Selected Files… gate built on it (DECISIONS 2026-11-01: a whole
// group may go at once; a half is refused only when it would be orphaned).
//
// A HALF is a row the pair gate protects (`CatalogScopePolicy.isPairProtected`)
// that is not a Combine output (`combinedFromPairID`): Combine's raw
// material. Its GROUP is every half the catalog links it to, followed to a
// fixed point: the same `pairGroupID`, its `pairedWith` partner, its decoded
// `pendingPairedWithID`, and any half that points back at it. The
// correlator writes two halves per group today; nothing here assumes two.
//   * A sibling removed from the catalog (purged) is no longer a member — it
//     already left, so moving the rest orphans nothing. It is named in the
//     confirmation ("its related half X was already removed").
//   * A link the catalog cannot follow (a pending id with no row, a partner
//     object that is not a catalog row), or a half with no sibling at all,
//     means the group is unknown: every half of it is held (refuse rather
//     than guess).
//   * A Combine output is never a member and keeps its own refusal.
//
// The gate (Delete Selected Files…): for each half in the selection, its
// group is admitted as a unit only when EVERY member is in the selection,
// each passes every other gate on its own (active, not Master Archive, drive
// connected), and each can be stat'ed now (its device + inode + size + mtime
// are kept — the move proves them again). Otherwise every selected member is
// held, and the reason names the sibling that holds it. A group is never
// split by the plan; the turn gate (CatalogTrashGroupTurns) keeps it whole
// at the move.
//
// Cost: `Index` is one pass over the catalog keeping only the halves
// (worst case every row is a half: 3 dictionary entries per row ≈ 100 B ×
// 100k = 10 MB, freed with the plan). Resolving a group is O(group). The
// identity probe is one lstat per admitted member (no open, no read).
// (For Rick: a caseless `enum` ≈ a C++ namespace of free functions.)

import Foundation
import VideoScanCore

/// A file's identity as the plan saw it: device + inode + size + mtime,
/// from `lstat` (a symlink or a non-regular file has none). Two values
/// differ when the file was replaced, rewritten or moved away.
struct PairHalfIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let mtimeNs: Int64

    /// nil when `path` is not a regular file now (gone, a folder, a link).
    nonisolated static func capture(path: String) -> PairHalfIdentity? {
        var info = stat()
        guard !path.isEmpty, lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return PairHalfIdentity(
            device: DeviceID.from(info.st_dev), inode: UInt64(info.st_ino), size: Int64(info.st_size),
            mtimeNs: Int64(info.st_mtimespec.tv_sec) &* 1_000_000_000 &+ Int64(info.st_mtimespec.tv_nsec))
    }
}

enum CatalogPairGroups {

    /// Combine's raw material: pair-protected and not a Combine output.
    nonisolated static func isHalf(_ r: VideoRecord) -> Bool {
        r.combinedFromPairID == nil && CatalogScopePolicy.isPairProtected(r)
    }

    /// The catalog's halves, indexed once per plan (or per menu click).
    struct Index {
        fileprivate var byID: [UUID: VideoRecord] = [:]
        fileprivate var byGroup: [UUID: [VideoRecord]] = [:]
        /// Halves whose `pairedWith` / `pendingPairedWithID` names the key.
        fileprivate var pointingAt: [UUID: [VideoRecord]] = [:]

        nonisolated init(catalog: [VideoRecord]) {
            for r in catalog where CatalogPairGroups.isHalf(r) {
                if byID[r.id] == nil { byID[r.id] = r }
                if let g = r.pairGroupID { byGroup[g, default: []].append(r) }
                // Both link kinds, each on its own (Codex #191 F5): a half
                // can carry an object link AND a pending one.
                for p in Set([r.pairedWith?.id, r.pendingPairedWithID].compactMap({ $0 })) {
                    pointingAt[p, default: []].append(r)
                }
            }
        }
    }

    /// One half's group as the catalog holds it now.
    struct Resolution {
        /// The live halves, the start first, then in discovery order.
        var members: [VideoRecord] = []
        /// Siblings deliberately removed (in the Trash, or removed from the
        /// catalog by the person) — their file names.
        var departed: [String] = []
        /// Siblings marked missing on disk (or gone with no removal marker):
        /// never "departed" — they hold the group (Codex #191 F6).
        var missingOnDisk: [String] = []
        /// A link could not be followed, or no sibling exists at all.
        var unknown = false
    }

    /// Bound on a group's size: the correlator makes pairs; a "group" of
    /// more than this is corrupt linkage and is held, never moved.
    nonisolated static let maxMembers = 16

    /// Follow every link from `start` to a fixed point (breadth first).
    nonisolated static func resolve(_ start: VideoRecord, in index: Index) -> Resolution {
        var out = Resolution()
        var seen: Set<UUID> = [start.id]
        // The catalog's own row for the start when it has one (a selected
        // row may be a stale copy — Codex #191 F1).
        var queue: [VideoRecord] = [index.byID[start.id] ?? start]
        var head = 0
        while head < queue.count {
            let r = queue[head]; head += 1
            if r.isPurged {
                switch r.removal?.state {
                case .inTrash?, .removedFromCatalog?: out.departed.append(r.filename)
                default: out.missingOnDisk.append(r.filename)
                }
                continue
            }
            out.members.append(r)
            var next: [VideoRecord] = []
            if let g = r.pairGroupID { next += index.byGroup[g] ?? [] }
            next += index.pointingAt[r.id] ?? []
            for link in [r.pairedWith?.id, r.pendingPairedWithID].compactMap({ $0 }) {
                guard let row = index.byID[link] else { out.unknown = true; continue }
                next.append(row)
            }
            for n in next where seen.insert(n.id).inserted { queue.append(n) }
            if queue.count > maxMembers { out.unknown = true; break }
        }
        if out.members.count == 1, out.departed.isEmpty { out.unknown = true }   // no sibling known
        if !out.members.contains(where: { $0.id == start.id }) { out.unknown = true }   // the start itself is gone
        return out
    }

    // MARK: - The Delete Selected Files… gate

    /// An admitted group: every member is selected and passed every gate.
    /// Arrays are parallel, in selection order.
    struct Group: Equatable, Sendable {
        let key: UUID
        let members: [UUID]
        let filenames: [String]
        let paths: [String]
        /// Each member's `pairGroupID` at plan time — the turn gate refuses
        /// a member re-paired since.
        let pairGroupIDs: [UUID?]
        /// Each member's device + inode + size + mtime at plan time.
        let identities: [PairHalfIdentity]
        /// Siblings already removed from the catalog.
        let departed: [String]
        /// Members other than the first — "its N related halves".
        var relatedCount: Int { members.count - 1 }
    }

    /// A group the plan holds, with the one reason that holds it.
    struct HeldGroup: Equatable, Sendable {
        let filenames: [String]
        let reason: String
        /// The selected members' ids (to tell groups apart).
        var ids: [UUID] = []
    }

    /// Why a selected half is held, in the plan's words.
    enum HalfHold: Equatable {
        /// The group is unknown or a sibling is not selected (`note`).
        case pairMember(String)
        /// The group is complete, but another member is held (`note`).
        case groupHeld(String)
    }

    struct GateResult {
        var admitted: [Group] = []
        var held: [HeldGroup] = []
        /// Per selected half that is held; a member refused on its own
        /// (archive, offline, inactive) keeps that refusal and is absent here.
        var holds: [UUID: HalfHold] = [:]
    }

    /// The gate over the selection's halves. `alone[id]` is the person's
    /// words for a row refused on its own (nil = it passes alone);
    /// `identity` is the plan-time probe (injectable for tests).
    nonisolated static func gate(_ selection: [VideoRecord], index: Index,
                                 alone: [UUID: String],
                                 identity: (VideoRecord) -> PairHalfIdentity?) -> GateResult {
        var out = GateResult()
        let order = Dictionary(selection.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let selected = Dictionary(selection.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var done: Set<UUID> = []
        for half in selection where isHalf(half) && !half.isPurged && !done.contains(half.id) {
            let res = resolve(half, in: index)
            let picked = res.members.filter { order[$0.id] != nil }
                .sorted { (order[$0.id] ?? .max) < (order[$1.id] ?? .max) }
            done.formUnion(res.members.map(\.id)); done.insert(half.id)
            let names = picked.map(\.filename)
            func holdAll(_ hold: (VideoRecord) -> HalfHold?, reason: String) {
                for m in picked where alone[m.id] == nil { if let h = hold(m) { out.holds[m.id] = h } }
                if !picked.isEmpty { out.held.append(HeldGroup(filenames: names, reason: reason, ids: picked.map(\.id))) }
            }
            if res.unknown {
                let why = "the catalog can't find every related half of it"
                holdAll({ _ in .pairMember(Self.pairMemberNote(why)) }, reason: why)
                continue
            }
            if !res.missingOnDisk.isEmpty {
                let why = "its related half \(Self.list(res.missingOnDisk)) is missing — not found on its drive"
                holdAll({ _ in .pairMember(Self.pairMemberNote(why)) }, reason: why)
                continue
            }
            // Codex #191 F1: the row the person selected must be the row
            // the catalog holds now (same path) — never move a stale copy.
            if let stale = picked.first(where: { m in selected[m.id].map { $0.fullPath != m.fullPath } ?? false }) {
                let why = "\(stale.filename) changed in the catalog since you selected it"
                holdAll({ _ in .groupHeld(Self.groupHeldNote(why)) }, reason: why)
                continue
            }
            let missing = res.members.filter { order[$0.id] == nil }.map(\.filename)
            if !missing.isEmpty {
                let why = "its related half \(Self.list(missing)) is not selected"
                holdAll({ _ in .pairMember(Self.pairMemberNote(why) + " — select every half to move the clip") }, reason: why)
                continue
            }
            if let blocker = picked.first(where: { alone[$0.id] != nil }), let words = alone[blocker.id] {
                let why = "its related half \(blocker.filename) is held (\(words))"
                holdAll({ $0.id == blocker.id ? nil : .groupHeld(Self.groupHeldNote(why)) }, reason: why)
                continue
            }
            let ids = picked.map { identity($0) }
            if let i = ids.firstIndex(where: { $0 == nil }) {
                let why = "\(picked[i].filename) can't be read on its drive right now"
                holdAll({ _ in .groupHeld(Self.groupHeldNote(why)) }, reason: why)
                continue
            }
            out.admitted.append(Group(
                key: half.pairGroupID ?? half.id, members: picked.map(\.id), filenames: names,
                paths: picked.map(\.fullPath), pairGroupIDs: picked.map(\.pairGroupID),
                identities: ids.compactMap { $0 }, departed: res.departed))
        }
        return out
    }

    /// "a.mxf" · "a.mxf and b.mxf" · "a.mxf, b.mxf and c.mxf".
    nonisolated static func list(_ names: [String]) -> String {
        guard names.count > 1, let last = names.last else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }

    nonisolated static func pairMemberNote(_ why: String) -> String {
        "is half of a recovered audio/video pair, which Combine still needs — \(why)"
    }

    nonisolated static func groupHeldNote(_ why: String) -> String {
        "stays with its recovered audio/video pair — \(why); a pair moves whole or not at all"
    }

    // MARK: - Select Related Halves

    /// What "Select Related Halves" selects and what it must say.
    struct RelatedSelection: Equatable {
        let select: Set<UUID>
        let line: String
    }

    /// The group's rows that are on screen (`shown`), and the console line —
    /// naming any member a filter or the folder view hides, so the gesture
    /// never silently selects fewer. O(records) for the index: an event
    /// handler only, never a view body.
    nonisolated static func relatedSelection(of rec: VideoRecord, catalog: [VideoRecord],
                                             shown: (Set<UUID>) -> Set<UUID>) -> RelatedSelection {
        let res = resolve(rec, in: Index(catalog: catalog))
        let ids = Set(res.members.map(\.id))
        let visible = shown(ids)
        let hidden = res.members.filter { !visible.contains($0.id) }.map(\.filename)
        let verb = "Select Related Halves"
        var line: String
        if hidden.isEmpty {
            line = "\(verb): selected \(visible.count) \(visible.count == 1 ? "half" : "halves") of \(rec.filename)'s clip — \(list(res.members.map(\.filename)))."
        } else {
            line = "\(verb): selected \(visible.count) of \(res.members.count) halves — \(list(hidden)) \(hidden.count == 1 ? "is" : "are") hidden by the current filter or folder view; show \(hidden.count == 1 ? "it" : "them") to select the whole clip (Delete Selected Files… moves a pair only with every half)."
        }
        if res.unknown {
            line += " The catalog can't find every related half of \(rec.filename), so Delete Selected Files… will keep it."
        }
        if !res.departed.isEmpty {
            line += " Already removed from the catalog: \(list(res.departed))."
        }
        return RelatedSelection(select: visible, line: line)
    }
}
