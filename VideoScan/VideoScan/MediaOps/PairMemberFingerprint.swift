// PairMemberFingerprint.swift
// THE one description of "what the pair gate reads about a member" (Codex
// #202; the Family Tree "one authority" pattern). Built by ONE function
// from a live catalog row; phase 1 of a pair unit snapshots the confirmed
// group with it, and the settlement after the moves compares the same
// fingerprint again — any inequality is "changed during the move"
// (DECISIONS 2026-11-01 contract). The turn gate reads no member field this
// value does not contain (CatalogTrashPairGroupSensorTests pins it).
//
// Gate inputs, enumerated once:
//   path · pairGroupID · pairedWith · pendingPairedWithID · combinedFromPairID
//   · removal marker · setAsideReason · supersededByID      (the row)
//   · protected (Master Archive tree / volume, a drive marked Read only)
//   · offline (its drive not connected)
//   · only-copy evidence (its whole-file SHA-256 claim)       (eligibility)
// plus, for the group, the walk's outcome: members, siblings linked from
// outside, a capped walk, one-sided linkage, a sibling missing on disk.
// A cap or one-sidedness is part of the fingerprint, so it always warns; a
// cap limits only how many NAMES the alert lists.
//
// Memory: one small value per selected group member, for the batch.
// (A struct of plain values ≈ a C++ POD with operator== generated.)

import Foundation
import VideoScanCore

struct PairMemberFingerprint: Equatable, Sendable {
    let id: UUID
    let filename: String
    let path: String
    let pairGroupID: UUID?
    let pairedWithID: UUID?
    let pendingPairedWithID: UUID?
    let combinedFromPairID: UUID?
    var removalState: RemovalMarker.State?
    let setAsideReason: String?
    let supersededByID: UUID?
    let protected: Bool
    let offline: Bool
    let onlyCopyEvidence: String?

    /// THE one builder: everything the gate reads about `r`, live, now.
    @MainActor
    static func of(_ r: VideoRecord, model: VideoScanModel,
                   archiveVolume: ArchiveVolumeProtection?) -> PairMemberFingerprint {
        PairMemberFingerprint(
            id: r.id, filename: r.filename, path: r.fullPath,
            pairGroupID: r.pairGroupID, pairedWithID: r.pairedWith?.id,
            pendingPairedWithID: r.pendingPairedWithID, combinedFromPairID: r.combinedFromPairID,
            removalState: r.removal?.state, setAsideReason: r.setAsideReason, supersededByID: r.supersededByID,
            protected: model.bulkDeleteRefusal(r, volume: archiveVolume) != nil,
            offline: VideoScanModel.isRecordOnOfflineVolume(r),
            onlyCopyEvidence: ContentCopyProof.digest(r).map { "\($0.digest)|\($0.byteCount)" })
    }

    /// The member is eligible as a half by its own fields (the gate's
    /// active test), read from the fingerprint.
    var isActive: Bool { removalState == nil && setAsideReason == nil && supersededByID == nil && combinedFromPairID == nil }

    /// What differs from `other`, in words ("V.mxf's pair link was changed").
    func differences(from other: PairMemberFingerprint) -> [String] {
        var out: [String] = []
        if path != other.path { out.append("\(filename) was relinked to another path") }
        if pairGroupID != other.pairGroupID || pairedWithID != other.pairedWithID
            || pendingPairedWithID != other.pendingPairedWithID || combinedFromPairID != other.combinedFromPairID {
            out.append("\(filename)'s pair link was changed")
        }
        if removalState != other.removalState { out.append("\(filename)'s removal state was changed") }
        if setAsideReason != other.setAsideReason { out.append("\(filename) was set aside or put back") }
        if supersededByID != other.supersededByID { out.append("\(filename) was replaced by a repair") }
        if protected != other.protected { out.append("\(filename)'s drive protection was changed") }
        if offline != other.offline { out.append("\(filename)'s drive was connected or disconnected") }
        if onlyCopyEvidence != other.onlyCopyEvidence { out.append("\(filename)'s whole-file hash was changed") }
        return out
    }
}

/// A whole group's fingerprint: its members (by catalog row id) and the
/// walk's outcome from the live catalog.
struct PairGroupFingerprint: Equatable, Sendable {
    var members: [UUID: PairMemberFingerprint]
    /// Members the catalog no longer has.
    var gone: [UUID]
    /// Live rows the walk reached that are not confirmed members.
    var joined: [String]
    var capped: Bool
    var oneSided: Bool
    var missingOnDisk: [String]

    /// How many joined names the alert lists before "and N more".
    static let nameCap = 5

    /// THE one builder — phase 1 and the settlement both call it. The walk
    /// is `CatalogPairGroups.resolve` (every link direction); `treatAsLive`
    /// counts the moved members as members after their move.
    @MainActor
    static func of(_ g: CatalogPairGroups.Group, model: VideoScanModel, index: CatalogPairGroups.Index,
                   treatAsLive: Set<UUID> = []) -> PairGroupFingerprint {
        let archiveVolume = model.archiveVolumeProtection()
        var members: [UUID: PairMemberFingerprint] = [:]
        var gone: [UUID] = []
        var first: VideoRecord?
        for id in g.members {
            guard let live = model.record(forID: id) else { gone.append(id); continue }
            if first == nil { first = live }
            members[id] = .of(live, model: model, archiveVolume: archiveVolume)
        }
        var fp = PairGroupFingerprint(members: members, gone: gone, joined: [], capped: false, oneSided: false,
                                      missingOnDisk: [])
        guard let first else { return fp }
        let walk = CatalogPairGroups.resolve(first, in: index, treatAsLive: treatAsLive)
        let confirmed = Set(g.members)
        fp.joined = walk.members.filter { !confirmed.contains($0.id) }.map(\.filename).sorted()
        fp.capped = walk.capped
        fp.oneSided = walk.unknown
        fp.missingOnDisk = walk.missingOnDisk.sorted()
        return fp
    }

    /// Every difference from the expected fingerprint, in words. Empty =
    /// unchanged. Never empty when the walk is capped or one-sided now and
    /// was not then.
    func differences(from expected: PairGroupFingerprint) -> [String] {
        var out: [String] = []
        for (id, now) in members.sorted(by: { $0.value.filename < $1.value.filename }) {
            guard let then = expected.members[id] else { out.append("\(now.filename) was added to the pair"); continue }
            out += now.differences(from: then)
        }
        for id in gone where expected.members[id] != nil {
            out.append("\(expected.members[id]?.filename ?? "a half") left the catalog")
        }
        let newJoined = joined.filter { !expected.joined.contains($0) }
        if !newJoined.isEmpty {
            let shown = newJoined.prefix(Self.nameCap).map { "\($0) was linked during the move" }
            out += shown
            if newJoined.count > Self.nameCap { out.append("and \(newJoined.count - Self.nameCap) more were linked") }
        }
        if capped && !expected.capped { out.append("more files were linked to the pair than the check can follow") }
        if oneSided && !expected.oneSided && newJoined.isEmpty && !capped {
            out.append("a link the catalog can't follow was added")
        }
        let newMissing = missingOnDisk.filter { !expected.missingOnDisk.contains($0) }
        if !newMissing.isEmpty { out.append("\(CatalogPairGroups.list(newMissing)) was linked during the move (missing on disk)") }
        return out
    }
}
