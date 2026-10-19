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
// NOTHING KNOWN IS LOST (Rick 2026-10-19: "I don't want to lose the 'same
// event different codec' feature"). A member that leaves the copies is not
// declared unrelated: the plan asks the duplicate check's own likeness rule
// (DuplicateLikeness) how it relates to the files it leaves behind —
//   same footage     alike, lengths agree, different bytes (a re-encode, a
//                    rewrap, another codec or container): the words say so
//                    with the reasons and the two formats, and Find Similar
//                    Footage records the link (FootageGrouping
//                    `copyCheckLikeness`) — never delete-eligible;
//   different length only the sampled hash matched and the lengths disagree:
//                    the sampled-hash collision class — not the same;
//   no likeness      today's rule no longer pairs them (a group from an older
//                    rule) — said so, nothing invented.
// The relationship lives in Find Similar Footage, not in these fields, so the
// split itself destroys nothing: the evidence is the files' own metadata.
//
// HELD, NOT SPLIT (2026-10-19 evidence run on Rick's catalog): Find Similar
// Footage gives each file ONE group whose confidence is its weakest link, so
// it can hold anchored likeness (sampled hash, a specific timecode or name,
// + length) but not a WEAK one between files that are already grouped (a
// default timecode, a camera-counter name, format + length) — taking it
// would demote byte copies to "possible". When the model passes
// `footageGroupOf` (a simulated Find Similar Footage pass over the catalog),
// a group is split only if its members stay CONNECTED afterwards — through
// the new groups of copies or a footage group — or the part cut off is "a
// different length" (evidence: not the same). Otherwise the group is HELD
// exactly as it is, with words saying why; it waits for a place to keep weak
// likeness (Rick's schema decision). Refuse over guess.
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
// grouped live record (~400 bytes with its likeness facts), the buckets,
// the changes; the likeness check scores pairs within ONE old group.
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
        /// The duplicate check's likeness facts (codec, length, name…) —
        /// nil = unknown, and the words then say only what the digest says.
        var likeness: DuplicateLikeness.Facts?
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

    /// How a bucket that leaves the copies relates to the files it leaves.
    struct Relation: Sendable, Equatable {
        enum Kind: Sendable, Equatable { case sameFootage, differentLength, noLikeness }
        var kind: Kind
        /// The member it is most alike (empty for `.noLikeness`).
        var partner: String = ""
        /// "different codec: FFV1 MKV · H.264 MOV" / "different bytes, same format: DV MOV".
        var difference: String = ""
        /// The duplicate check's reasons, verbatim ("filename+duration+resolution").
        var reasons: String = ""

        /// The clause after a filename or a new group.
        var words: String {
            switch kind {
            case .sameFootage:
                return "same footage as \(partner), \(difference) (the duplicate check matched \(reasons)) — kept as same footage, not copies"
            case .differentLength:
                return "a different length from \(partner) (only the sampled hash matched) — not the same footage"
            case .noLikeness:
                return "no likeness to the others by today's rule"
            }
        }
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
        /// How each leaver relates to the rest (same order as `left`; nil =
        /// no likeness facts were given — the digest is all that is known).
        var leftRelations: [Relation?] = []
        /// Held: NOT split, because splitting would lose likeness nothing
        /// else holds (see the file header). `heldWhy` says what.
        var held = false
        var heldWhy = ""

        struct NewGroup: Sendable, Equatable {
            var id: UUID
            var keeperFilename: String
            var members: Int
            var relation: Relation?
        }

        /// Files in this group that leave the copies as the same footage.
        var sameFootageFiles: Int {
            zip(left, leftRelations).filter { $0.1?.kind == .sameFootage }.count
                + newGroups.filter { $0.relation?.kind == .sameFootage }.reduce(0) { $0 + $1.members }
        }

        var differentLengthFiles: Int {
            zip(left, leftRelations).filter { $0.1?.kind == .differentLength }.count
                + newGroups.filter { $0.relation?.kind == .differentLength }.reduce(0) { $0 + $1.members }
        }

        /// "group 1A2B3C4D (4 files, 3 different whole-file SHA-256s): 2
        /// stay with keeper a.mov · 2 became group 5E6F7A8B (keeper b.mov) ·
        /// c.mov left — its SHA-256 matches no other member". With likeness
        /// facts each mover says how it relates ("— same footage as a.mov,
        /// different codec: FFV1 MKV · H.264 MOV (…)").
        var words: String {
            if held {
                return "group \(short(oldGroupID)) (\(members) files, \(digests) different whole-file SHA-256s): kept as it is — "
                    + heldWhy
            }
            var parts: [String] = []
            if keptMembers > 0 {
                parts.append("\(keptMembers) stay with keeper \(keeperFilename)")
            } else {
                parts.append("the keeper \(keeperFilename) has no other copy here — the group is gone")
            }
            for g in newGroups {
                parts.append("\(g.members) became group \(short(g.id)) (keeper \(g.keeperFilename))"
                             + (g.relation.map { " — " + $0.words } ?? ""))
            }
            let plain = left.indices.filter { i in i >= leftRelations.count || leftRelations[i] == nil }.map { left[$0] }
            if !plain.isEmpty {
                parts.append("\(plain.joined(separator: ", ")) left — \(plain.count == 1 ? "its" : "each one's") whole-file SHA-256 matches no other member")
            }
            for (i, name) in left.enumerated() where i < leftRelations.count {
                guard let r = leftRelations[i] else { continue }
                parts.append("\(name) left the copies — " + r.words)
            }
            return "group \(short(oldGroupID)) (\(members) files, \(digests) different whole-file SHA-256s): " + parts.joined(separator: " · ")
        }
    }

    struct Plan: Sendable, Equatable {
        var changes: [Change] = []
        /// Split groups AND held groups (`held`), in catalog order.
        var groups: [GroupOutcome] = []
        var isEmpty: Bool { changes.isEmpty }
        var splitGroups: [GroupOutcome] { groups.filter { !$0.held } }
        var heldGroups: [GroupOutcome] { groups.filter(\.held) }
        var recordsLeaving: Int { changes.filter { $0.groupID == nil }.count }
        var newGroupCount: Int { splitGroups.reduce(0) { $0 + $1.newGroups.count } }
        /// Files that leave the copies but stay linked as the same footage.
        var sameFootageFiles: Int { splitGroups.reduce(0) { $0 + $1.sameFootageFiles } }
        /// Files that leave as a different length (sampled-hash collisions).
        var differentLengthFiles: Int { splitGroups.reduce(0) { $0 + $1.differentLengthFiles } }
    }

    /// The plan for every group in `facts` whose members carry more than
    /// one known digest. `elect` picks a new bucket's keeper among its ids
    /// (the model passes DuplicateKeeperPolicy; nil → the first member).
    /// `newID` mints a new group id (tests pass a deterministic one).
    /// `footageGroupOf`: record id → its footage group after a simulated
    /// Find Similar Footage pass (nil = no hold check — the pure rule).
    static func plan(_ facts: [MemberFact],
                     elect: ([UUID]) -> UUID? = { $0.first },
                     newID: () -> UUID = { UUID() },
                     footageGroupOf: [UUID: UUID]? = nil) -> Plan {
        var byGroup: [UUID: [MemberFact]] = [:]
        var groupOrder: [UUID] = []
        for f in facts {
            if byGroup[f.groupID] == nil { groupOrder.append(f.groupID) }
            byGroup[f.groupID, default: []].append(f)
        }
        var plan = Plan()
        for groupID in groupOrder {
            guard let members = byGroup[groupID] else { continue }
            planGroup(groupID, members, elect: elect, newID: newID, footageGroupOf: footageGroupOf, into: &plan)
        }
        return plan
    }

    private static func planGroup(_ groupID: UUID, _ members: [MemberFact], elect: ([UUID]) -> UUID?,
                                  newID: () -> UUID, footageGroupOf: [UUID: UUID]?, into plan: inout Plan) {
        let digests = Set(members.compactMap { $0.digest?.lowercased() })
        guard digests.count > 1 else { return }
        let keeperIndex = members.firstIndex { $0.disposition == .keep }
        let buckets = partition(members, keeper: keeperIndex, digest: \.digest)
        let keeper = keeperIndex.map { members[$0] }
        var outcome = GroupOutcome(oldGroupID: groupID, digests: digests.count, members: members.count, keptMembers: 0,
                                   newGroups: [], left: [], keeperFilename: keeper?.filename ?? "(none)")
        var placed = Set<UUID>()
        var changes: [Change] = []
        for bucket in buckets {
            let holdsKeeper = keeper.map { k in bucket.contains { $0.id == k.id } } ?? false
            let id = holdsKeeper ? groupID : newID()
            let bucketKeeperID = holdsKeeper ? keeper?.id : (elect(bucket.map(\.id)) ?? bucket.first?.id)
            let bucketKeeper = bucket.first { $0.id == bucketKeeperID } ?? bucket[0]
            for m in bucket {
                changes.append(change(for: m, group: id, keeper: bucketKeeper, bucket: bucket))
                placed.insert(m.id)
            }
            if holdsKeeper {
                outcome.keptMembers = bucket.count
            } else {
                let ids = Set(bucket.map(\.id))
                outcome.newGroups.append(.init(id: id, keeperFilename: bucketKeeper.filename, members: bucket.count,
                                               relation: relation(of: bucket, to: members.filter { !ids.contains($0.id) })))
            }
        }
        for m in members where !placed.contains(m.id) {
            changes.append(Change(id: m.id, groupID: nil, disposition: .none, groupCount: 0, bestMatch: ""))
            outcome.left.append(m.filename)
            outcome.leftRelations.append(relation(of: [m], to: members.filter { $0.id != m.id }))
        }
        if let footageGroupOf, let why = lossIfSplit(members, changes: changes, keeper: keeper, footageGroupOf: footageGroupOf) {
            outcome.held = true
            outcome.heldWhy = why
            plan.groups.append(outcome)
            return
        }
        plan.changes.append(contentsOf: changes)
        plan.groups.append(outcome)
    }

    /// nil when splitting loses nothing: after the split every member is
    /// still connected to the keeper's part — through a new group of copies
    /// or a shared footage group — or the part cut off is a different length
    /// (evidence: not the same footage). Otherwise, in words, what would be
    /// lost. (For Rick: a tiny union-find over the group's members, keyed by
    /// "same new group" and "same footage group".)
    static func lossIfSplit(_ members: [MemberFact], changes: [Change], keeper: MemberFact?,
                            footageGroupOf: [UUID: UUID]) -> String? {
        let newGroup = Dictionary(changes.map { ($0.id, $0.groupID) }, uniquingKeysWith: { a, _ in a })
        var parent = Array(members.indices)
        func find(_ x: Int) -> Int { var x = x; while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }; return x }
        var firstByKey: [String: Int] = [:]
        for (i, m) in members.enumerated() {
            let keys = [newGroup[m.id].flatMap { $0 }.map { "c:" + $0.uuidString },
                        footageGroupOf[m.id].map { "f:" + $0.uuidString }].compactMap { $0 }
            for key in keys {
                if let j = firstByKey[key] { parent[find(i)] = find(j) } else { firstByKey[key] = i }
            }
        }
        let anchor = keeper.flatMap { k in members.firstIndex { $0.id == k.id } } ?? 0
        var parts: [Int: [MemberFact]] = [:]
        for (i, m) in members.enumerated() where find(i) != find(anchor) { parts[find(i), default: []].append(m) }
        var losses: [String] = []
        for part in parts.values.sorted(by: { $0[0].filename < $1[0].filename }) {
            let ids = Set(part.map(\.id))
            let rel = relation(of: part, to: members.filter { !ids.contains($0.id) })
            if rel?.kind == .differentLength { continue }
            let names = part.map(\.filename).joined(separator: ", ")
            if let rel, rel.kind == .sameFootage {
                losses.append("\(names) is alike to \(rel.partner) only weakly (the duplicate check matched \(rel.reasons); "
                              + "\(rel.difference)) and nothing else would link them")
            } else {
                losses.append("\(names) has no likeness to the others by today's rule, and only this group remembers they were matched")
            }
        }
        guard !losses.isEmpty else { return nil }
        return "splitting would lose what the duplicate check knew: " + losses.joined(separator: "; ")
            + ". It waits for a place to keep weak likeness."
    }

    /// How `movers` relate to `rest` by the duplicate check's likeness: the
    /// best-scoring pair across the two sides decides. nil when a mover has
    /// no likeness facts (the plan then says only what the digest says).
    static func relation(of movers: [MemberFact], to rest: [MemberFact]) -> Relation? {
        guard movers.allSatisfy({ $0.likeness != nil }) else { return nil }
        var best: (mover: DuplicateLikeness.Facts, other: DuplicateLikeness.Facts, score: DuplicateLikeness.Score)?
        for m in movers {
            guard let a = m.likeness else { continue }
            for o in rest {
                guard let b = o.likeness, let s = DuplicateLikeness.score(a, b) else { continue }
                if let current = best, s.points <= current.score.points { continue }
                best = (a, b, s)
            }
        }
        guard let best else { return Relation(kind: .noLikeness) }
        let mine = DuplicateLikeness.formatWords(videoCodec: best.mover.videoCodec, audioCodec: best.mover.audioCodec,
                                                 filename: best.mover.filename)
        let theirs = DuplicateLikeness.formatWords(videoCodec: best.other.videoCodec, audioCodec: best.other.audioCodec,
                                                   filename: best.other.filename)
        let kind: Relation.Kind = best.score.reasons.contains("duration") ? .sameFootage : .differentLength
        return Relation(kind: kind, partner: best.other.filename, difference: DuplicateLikeness.differenceWords(mine, theirs),
                        reasons: best.score.reasons.joined(separator: "+"))
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
