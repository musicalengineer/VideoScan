// DuplicateGroupDigestSplit.swift
// A duplicate group is a set of COPIES: it never holds two members whose
// stored whole-file SHA-256 digests are known and differ (Rick 2026-10-19).
// Before this, DuplicateDetector's strongest signal was the SAMPLED hash
// (`partialMD5`: the first and last 64 KB plus the size), and nothing in
// grouping looked at the whole-file digest — so two files with one header,
// one tail and one length but different bytes in between became "copies"
// (190 such groups on Rick's catalog, 2026-10-18; 466 groups in all held
// more than one digest once similarity-only groups are counted).
//
// ONE rule, used twice:
//   * `partition` — DuplicateDetector applies it to every star group before
//     it stamps members, so such a group can no longer be FORMED;
//   * `plan` — the repair ("Split Duplicate Groups by Full Hash",
//     VideoScanModel+DuplicateDigestSplit.swift) applies it to the groups
//     already in the catalog.
//
// The partition: members are bucketed by their lowercase whole-file digest.
// A member whose digest is NOT known yet is not known to differ: it stays
// with the keeper's bucket. Buckets of two or more members are groups of
// true copies; a bucket of one leaves the group. A group whose members carry
// at most ONE known digest is left exactly as it is (idempotence: a second
// run plans nothing).
//
// Decisions follow the keeper: the bucket holding the kept member keeps the
// group's id and its keeper; any other bucket of ≥ 2 becomes a new group
// whose keeper is elected by the same DuplicateKeeperPolicy the detector
// uses. A member that was not the keeper keeps its own disposition (Extra
// copy / Review) and confidence; a member that leaves loses its group
// fields (it is a unique file now) but keeps its `dupAnalyzedAt` stamp, so
// Find Duplicates does not re-derive it until something about it changes.
//
// Pure value code — no I/O, no model, no clock. Memory: one fact per
// grouped live record (~120 bytes), the buckets, the changes.
//
// (For Rick: `partition` is a generic function template — `T` is any member
// type, `digest` the accessor, like a std::function key extractor.)

import Foundation
import VideoScanCore

enum DuplicateGroupDigestSplit {

    // MARK: - The one rule

    /// The members split into groups of copies (each ≥ 2 members); the
    /// keeper's bucket first. Returns `[members]` unchanged when they carry
    /// at most one known digest. `keeper` indexes `members` (nil = none).
    static func partition<T>(_ members: [T], keeper: Int?, digest: (T) -> String?) -> [[T]] {
        let keys = members.map { digest($0)?.lowercased() }
        let known = Set(keys.compactMap { $0 })
        guard known.count > 1 else { return [members] }
        let keeperKey = keeper.flatMap { keys[$0] }
        var order: [String?] = []
        var buckets: [String?: [T]] = [:]
        for (i, member) in members.enumerated() {
            let key = keys[i] ?? keeperKey
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(member)
        }
        let keeperFirst = order.filter { $0 == keeperKey } + order.filter { $0 != keeperKey }
        return keeperFirst.compactMap { key in
            guard let bucket = buckets[key], bucket.count > 1 else { return nil }
            return bucket
        }
    }

    // MARK: - The repair plan

    /// One live grouped record, as the plan sees it.
    struct MemberFact: Sendable, Equatable {
        var id: UUID
        var groupID: UUID
        var filename: String
        /// The stored whole-file SHA-256 (`VideoScanModel.storedFullDigest`).
        var digest: String?
        var disposition: DuplicateDisposition
        var confidence: DuplicateConfidence?
        var bestMatch: String
    }

    /// What one record becomes.
    struct Change: Sendable, Equatable {
        var id: UUID
        /// nil = the record leaves its group (all group fields cleared).
        var groupID: UUID?
        var disposition: DuplicateDisposition
        var groupCount: Int
        var bestMatch: String
    }

    /// One old group's outcome, in words.
    struct GroupOutcome: Sendable, Equatable {
        var oldGroupID: UUID
        var digests: Int
        var members: Int
        /// Members still in the old group (the keeper's bucket); 0 when it
        /// was a singleton and the group is gone.
        var keptMembers: Int
        /// New groups: id, keeper's filename, member count.
        var newGroups: [NewGroup]
        /// Filenames that left (their digest matches no other member).
        var left: [String]
        var keeperFilename: String

        struct NewGroup: Sendable, Equatable {
            var id: UUID
            var keeperFilename: String
            var members: Int
        }

        /// "group 1A2B3C4D (4 files, 3 different whole-file SHA-256s): 2
        /// stay with keeper a.mov · 2 became group 5E6F7A8B (keeper b.mov) ·
        /// c.mov left — its SHA-256 matches no other member".
        var words: String {
            var parts: [String] = []
            if keptMembers > 0 {
                parts.append("\(keptMembers) stay with keeper \(keeperFilename)")
            } else {
                parts.append("the keeper \(keeperFilename) has no other copy here — the group is gone")
            }
            for g in newGroups {
                parts.append("\(g.members) became group \(short(g.id)) (keeper \(g.keeperFilename))")
            }
            if !left.isEmpty {
                parts.append("\(left.joined(separator: ", ")) left — \(left.count == 1 ? "its" : "each one's") whole-file SHA-256 matches no other member")
            }
            return "group \(short(oldGroupID)) (\(members) files, \(digests) different whole-file SHA-256s): " + parts.joined(separator: " · ")
        }
    }

    struct Plan: Sendable, Equatable {
        var changes: [Change] = []
        var groups: [GroupOutcome] = []
        var isEmpty: Bool { changes.isEmpty }
        var recordsLeaving: Int { changes.filter { $0.groupID == nil }.count }
        var newGroupCount: Int { groups.reduce(0) { $0 + $1.newGroups.count } }
    }

    /// The plan for every group in `facts` whose members carry more than
    /// one known digest. `elect` picks a new bucket's keeper among its ids
    /// (the model passes DuplicateKeeperPolicy; nil → the first member).
    /// `newID` mints a new group id (tests pass a deterministic one).
    static func plan(_ facts: [MemberFact],
                     elect: ([UUID]) -> UUID? = { $0.first },
                     newID: () -> UUID = { UUID() }) -> Plan {
        var byGroup: [UUID: [MemberFact]] = [:]
        var groupOrder: [UUID] = []
        for f in facts {
            if byGroup[f.groupID] == nil { groupOrder.append(f.groupID) }
            byGroup[f.groupID, default: []].append(f)
        }
        var plan = Plan()
        for groupID in groupOrder {
            guard let members = byGroup[groupID] else { continue }
            planGroup(groupID, members, elect: elect, newID: newID, into: &plan)
        }
        return plan
    }

    private static func planGroup(_ groupID: UUID, _ members: [MemberFact], elect: ([UUID]) -> UUID?,
                                  newID: () -> UUID, into plan: inout Plan) {
        let digests = Set(members.compactMap { $0.digest?.lowercased() })
        guard digests.count > 1 else { return }
        let keeperIndex = members.firstIndex { $0.disposition == .keep }
        let buckets = partition(members, keeper: keeperIndex, digest: \.digest)
        let keeper = keeperIndex.map { members[$0] }
        var outcome = GroupOutcome(oldGroupID: groupID, digests: digests.count, members: members.count, keptMembers: 0,
                                   newGroups: [], left: [], keeperFilename: keeper?.filename ?? "(none)")
        var placed = Set<UUID>()
        for bucket in buckets {
            let holdsKeeper = keeper.map { k in bucket.contains { $0.id == k.id } } ?? false
            let id = holdsKeeper ? groupID : newID()
            let bucketKeeperID = holdsKeeper ? keeper?.id : (elect(bucket.map(\.id)) ?? bucket.first?.id)
            let bucketKeeper = bucket.first { $0.id == bucketKeeperID } ?? bucket[0]
            for m in bucket {
                plan.changes.append(change(for: m, group: id, keeper: bucketKeeper, bucket: bucket))
                placed.insert(m.id)
            }
            if holdsKeeper {
                outcome.keptMembers = bucket.count
            } else {
                outcome.newGroups.append(.init(id: id, keeperFilename: bucketKeeper.filename, members: bucket.count))
            }
        }
        for m in members where !placed.contains(m.id) {
            plan.changes.append(Change(id: m.id, groupID: nil, disposition: .none, groupCount: 0, bestMatch: ""))
            outcome.left.append(m.filename)
        }
        plan.groups.append(outcome)
    }

    /// A member's fields in its bucket: the keeper keeps (or becomes) Keep
    /// and names its strongest remaining match — its old best match when
    /// that file is still beside it, else the first other member; the
    /// others name the keeper, and a former keeper takes its confidence's
    /// disposition (classifyGroup's rule).
    private static func change(for m: MemberFact, group: UUID, keeper: MemberFact, bucket: [MemberFact]) -> Change {
        if m.id == keeper.id {
            let others = bucket.filter { $0.id != m.id }.map(\.filename)
            let best = others.contains(m.bestMatch) ? m.bestMatch : (others.first ?? "")
            return Change(id: m.id, groupID: group, disposition: .keep, groupCount: bucket.count, bestMatch: best)
        }
        let disposition: DuplicateDisposition
        switch m.disposition {
        case .keep, .none: disposition = m.confidence == .high ? .extraCopy : .review
        case .review, .extraCopy: disposition = m.disposition
        }
        return Change(id: m.id, groupID: group, disposition: disposition, groupCount: bucket.count, bestMatch: keeper.filename)
    }

    static func short(_ id: UUID) -> String { String(id.uuidString.prefix(8)) }
}
