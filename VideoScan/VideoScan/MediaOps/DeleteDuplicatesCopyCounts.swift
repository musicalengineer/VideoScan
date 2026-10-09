// DeleteDuplicatesCopyCounts.swift
// R5 (Rick 2026-10-09, design triage_delete_streamline §9 R5): how many
// copies of a group's content the catalog knows — the input to the
// PRE-SELECTION default ("groups with 3+ copies: extras pre-checked; groups
// with exactly 2: allowed, not pre-checked"). A disposal default, never
// proof of identity: every copy that leaves is proven against its keeper
// at the moment of the move.
//
// (For Rick: an `extension` adds member functions to an existing class
// from another file — like defining more methods of a C++ class in a
// second .cpp. `[UUID: Int]` ≈ std::unordered_map<UUID, int>.)

import Foundation
import VideoScanCore

extension VideoScanModel {

    /// Copies per duplicate group in `groups`: the group's live members,
    /// plus every Master Archive copy promoted from one of them that is not
    /// itself a member (an archive copy usually sits outside the group).
    /// O(records): one pass over the catalog and one over the derived
    /// records it met. Never called from a view body.
    func duplicateGroupCopyCounts(_ groups: Set<UUID>) -> [UUID: Int] {
        guard !groups.isEmpty else { return [:] }
        var counts: [UUID: Int] = [:]
        var groupOfMember: [UUID: UUID] = [:]
        var derived: [VideoRecord] = []
        for r in records where !r.isPurged {
            if let g = r.duplicateGroupID, groups.contains(g) {
                counts[g, default: 0] += 1
                groupOfMember[r.id] = g
            } else if r.derivedFrom != nil {
                derived.append(r)
            }
        }
        for r in derived {
            guard let parent = r.derivedFrom, let g = groupOfMember[parent], isArchiveCopy(r) else { continue }
            counts[g, default: 0] += 1
        }
        return counts
    }
}
