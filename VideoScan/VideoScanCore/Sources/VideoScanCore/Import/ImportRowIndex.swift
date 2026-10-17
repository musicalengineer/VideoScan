// ImportRowIndex.swift
// What the later passes know about the catalog rows, by canonical id: the
// digest (when the row binds one), the files.id when it landed in files,
// the path and audit stamp (the audit results need them, N1), the pair
// groups (F9) and the digests that have a `content` row. ONE construction
// rule, `record`, used by the row pass as it writes and by the comparator as
// it re-derives the same facts from its own decode (codex D′ #1/#3): a
// member key, a ledger line or an audit row resolves the same way on both
// sides because both sides fill this index by the same rule.
//
// The rules (contract §f, F9, codex D′ #6):
//   * a repeated id (every occurrence `duplicateId`) binds nothing — no digest,
//     no file — but keeps the FIRST occurrence's path and stamp (N1) and its
//     pair group (so a `pair:` key naming it stays listed, never half-resolved);
//   * an `unrepresentable` occurrence binds nothing either (no content row
//     was written for its digest) and joins no pair group;
//   * every other occurrence records its digest, file id, path, stamp and
//     pair group, and its digest is a content row.
//
// (For Rick: a POD of three maps plus one insert rule — the symbol table
// the second pass reads.)

import Foundation

/// What later passes need to know about one occurrence.
struct ImportRowFacts: Sendable, Equatable {
    var digest: String?
    /// The `files.id` when the occurrence landed in files.
    var fileID: String?
    var fullPath: String
    var auditSeenAt: Int64?
    var pairGroupID: String?
}

struct ImportRowIndex: Sendable, Equatable {
    private(set) var facts: [String: ImportRowFacts] = [:]
    /// Canonical pair group id → the canonical ids of its halves.
    private(set) var pairGroups: [String: [String]] = [:]
    /// Every digest that has a `content` row.
    private(set) var contentDigests: Set<String> = []

    /// One occurrence, after its landing is known. `reason` is the quarantine
    /// reason, nil for a main landing.
    mutating func record(id: String, digest: String?, fileID: String?, fullPath: String, auditSeenAt: Int64?,
                         pairGroupID: String?, reason: CatalogDDL.ReasonCode?) {
        if reason == .unrepresentable || reason == .duplicateId {
            if facts[id] == nil {
                facts[id] = ImportRowFacts(digest: nil, fileID: nil, fullPath: fullPath, auditSeenAt: auditSeenAt, pairGroupID: nil)
            }
            if reason == .duplicateId, let group = pairGroupID {
                pairGroups[CatalogRecordDTO.canonicalID(group), default: []].append(id)
            }
            return
        }
        facts[id] = ImportRowFacts(digest: digest, fileID: fileID, fullPath: fullPath, auditSeenAt: auditSeenAt,
                                   pairGroupID: pairGroupID)
        if let group = pairGroupID { pairGroups[CatalogRecordDTO.canonicalID(group), default: []].append(id) }
        if let digest { contentDigests.insert(digest) }
    }
}

// MARK: - Member key → digests (§f: a digest, both halves of a pair, one row)

enum MemberKeyResolution {
    struct Digests: Equatable {
        var found: [String]
        /// False when the key names a row (or a half) whose digest is unknown.
        var complete: Bool
    }

    static func digests(for key: String, index: ImportRowIndex) -> Digests {
        if let group = EventMemberKey.pairGroupID(key) {
            let halves = index.pairGroups[group] ?? []
            let found = halves.compactMap { index.facts[$0]?.digest }
            return Digests(found: found, complete: !halves.isEmpty && found.count == halves.count)
        }
        if let rowID = EventMemberKey.rowID(key) {
            let digest = index.facts[rowID]?.digest
            return Digests(found: digest.map { [$0] } ?? [], complete: digest != nil)
        }
        if let digest = EventMemberKey.digest(key), index.contentDigests.contains(digest) {
            return Digests(found: [digest], complete: true)
        }
        return Digests(found: [], complete: false)
    }

    /// The `event_members` rows a folded member becomes when it resolves
    /// (every digest it names is known and its event exists); nil = listed.
    static func resolve(_ member: EventsDecisionsJSON.Member, index: ImportRowIndex,
                        knownEvents: Set<String>) -> [ImportComparator.ResolvedMember]? {
        let digests = digests(for: member.contentKey, index: index)
        guard knownEvents.contains(member.eventID), digests.complete, !digests.found.isEmpty else { return nil }
        return digests.found.map {
            ImportComparator.ResolvedMember(eventID: member.eventID, digest: $0, rangeStart: member.start, rangeEnd: member.end)
        }
    }
}

/// The three shapes of `ContentRange.contentKey` (EventsDecisionStore.swift:35).
enum EventMemberKey {
    static func pairGroupID(_ key: String) -> String? {
        key.hasPrefix("pair:") ? CatalogRecordDTO.canonicalID(String(key.dropFirst("pair:".count))) : nil
    }

    static func rowID(_ key: String) -> String? {
        key.hasPrefix("id:") ? CatalogRecordDTO.canonicalID(String(key.dropFirst("id:".count))) : nil
    }

    /// The plain digest, with or without a `sha256:` prefix; nil otherwise.
    static func digest(_ key: String) -> String? {
        let hex = (key.hasPrefix("sha256:") ? String(key.dropFirst("sha256:".count)) : key).lowercased()
        return CatalogRecordDTO.isWholeFileDigest(hex) ? hex : nil
    }
}
