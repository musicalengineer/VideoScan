// DeleteDuplicatesTargetGates.swift
// R4 (design triage_delete_streamline_2026_10_09 §9 R4, codex F4): keeper
// precedence is ELECTION, not protection. Choosing an SSD keeper must never
// make the archive selectable. So every kind of copy that may NEVER be a
// target of Delete Duplicates has a named EXECUTION gate — asked at the
// row's turn, and where it can change under a long read, again at the
// removal itself:
//
//   never a target                 gate (where)
//   ─────────────────────────────  ─────────────────────────────────────────
//   Master Archive tree / volume   bulkDeleteRefusal → .archiveTree /
//                                  .archiveVolume / …Unprovable, at the
//                                  plan, at the row's turn
//                                  (authorizeDuplicateDeletion), by the
//                                  file's own volume UUID before the move
//                                  (worker `archiveCheck`), and from TODAY's
//                                  designation at the removal
//                                  (`removalBoundary`)
//   a drive marked Read only       bulkDeleteRefusal → .readOnlyVolume* at the
//   — and an ARCHIVE BACKUP drive  row's turn; the marks again at the removal
//     (marking a backup makes it   (`removalBoundary` → ReadOnlyVolume-
//     Read only: one mark, one     Protection.verdictAtRemoval)
//     gate)
//   a network mount                `DeleteDuplicatesTargetGate.networkHold`:
//                                  the worker, before the move; again at the
//                                  removal (`removalBoundary`; statfs: not
//                                  MNT_LOCAL)
//   half of a recovered A/V pair   `duplicateTargetHold` at the row's turn
//                                  (travels with the pair, the worker holds
//                                  it before the move); again at the removal
//                                  (the one hop)
//   a copy LONGER than an archive  `duplicateTargetHold` at the row's turn —
//   master of its content (or one  the Tier 1 rule, `ExcessCopiesPlan
//   whose length cannot be         .lengthVerdict`; not asked when the keeper
//   compared)                      IS the archive copy (identical bytes)
//   a keeper (any name)            the plan (`DeleteDuplicatesReview.holds`)
//                                  and the verifier (`.samePath`, by inode)
//   this Mac in viewer mode        the job refuses to start
//   a sampled-hash-only match      never: the copy is read in full and its
//                                  digest matched to the keeper's at the move
//
// Every hold is a SKIP with its reason, never a refusal: nothing is wrong
// with the pair, so the copy is not re-marked Review. And a held copy is
// never counted as a surviving copy for another row of the run.

import Foundation
import VideoScanCore

enum DeleteDuplicatesTargetGate {

    /// The network gate: true when `path` is on a network share. The live
    /// probe is the archive protection's (statfs, not MNT_LOCAL).
    static let liveIsNetworkMount: @Sendable (String) -> Bool = { ArchiveVolumeProtection.isNetworkMount($0) }

    /// The network gate's reason for `path`, or nil (`isNetworkMount` =
    /// the probe: statfs in production, a seam in tests).
    static func networkHold(_ path: String,
                            isNetworkMount: @Sendable (String) -> Bool = liveIsNetworkMount) -> String? {
        isNetworkMount(path) ? ExcessCopiesPlan.networkReason : nil
    }
}

extension VideoScanModel {

    /// The catalog's half of the target gates the bulk-verb gate does not
    /// cover (R4): half of a recovered A/V pair; a copy longer than an
    /// archive master of its content, or whose length cannot be compared
    /// with one. `archiveMasterDurations` = the lengths of the family's
    /// Master Archive copies (`DeletionTierCandidates`). nil = none holds.
    func duplicateTargetHold(record rec: VideoRecord, keeper: VideoRecord,
                             archiveMasterDurations: [Double]) -> String? {
        if CatalogScopePolicy.isPairProtected(rec) { return ExcessCopiesPlan.pairReason }
        // The keeper IS the archive copy: the copy is proven byte-identical
        // to it before anything moves, so it cannot be longer.
        guard !isArchiveCopy(keeper) else { return nil }
        for master in archiveMasterDurations {
            switch ExcessCopiesPlan.lengthVerdict(copy: rec.durationSeconds, master: master) {
            case .fits: continue
            case .longer: return ExcessCopiesPlan.longerFlag
            case .unknown: return ExcessCopiesPlan.unknownLengthReason
            }
        }
        return nil
    }

    /// The removal boundary's part of the same rule (only what can change
    /// during a read without a catalog rescan): the A/V pairing.
    func duplicateTargetHoldAtRemoval(recordID: UUID) -> String? {
        guard let rec = record(forID: recordID), CatalogScopePolicy.isPairProtected(rec) else { return nil }
        return ExcessCopiesPlan.pairReason
    }
}
