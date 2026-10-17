// CatalogConstraints.swift
// Tier 5 of Verify Catalog (Rick 2026-10-16, docs/design/integrity_first_2026_10_16.md
// §3a "declarative constraints"): the PK / FK / check / not-null rules a
// JSON catalog never had, as PURE value code. Rows in, findings out; no I/O,
// no model, no clock. One index pass (O(rows)) and then one small NAMED
// function per rule — a rule is a concept (a foreign key, a mirror, a
// digest's shape), never a step. Tier 4's one rule ("is this derived stamp
// still about THIS content?") lives here too, because it reads the same rows
// and is the same kind of check; `Rule.tier` says which tier owns it.
//
// It checks; it never fixes (design §2.3). Every finding carries the row it
// is about (when it is about one row), family-app words, and whether a
// person has to decide — nothing here writes a row.
//
// Codex (Verify Catalog slice 1, P2): three relations were unchecked —
// path identity on a case-insensitive volume (`pathAliasByCase`), that a
// supersession chain ENDS (`supersessionCycle`), and that the members of
// one duplicate group really carry one set of bytes
// (`duplicateGroupDigestsAgree`). Each is a rule in the table now.
//
// Memory: one IntegrityRow per catalog row (~400 bytes with its strings) ≈
// 6 MB at 14k rows, ≈ 40 MB at 100k, freed when the run ends; the index is
// a few Sets of ids and digests on top. Nothing grows with file size.
//
// (For Rick: `IntegrityRow` is a POD snapshot of the fields the rules read —
// taken on the main actor, handed to a worker as a value; `Rule` ≈ an enum
// class whose `tier` is a lookup; the rule table is an array of function
// pointers, like CatalogAuditor's checks.)

import Foundation
import VideoScanCore

// MARK: - Input projection

/// The fields the constraints read from one catalog row. Built on the main
/// actor (`VideoRecord` lives there), consumed off it.
struct IntegrityRow: Sendable, Equatable {
    var id: UUID
    var fullPath: String
    var filename: String
    var sizeBytes: Int64
    var streamTypeRaw: String
    var audioCodec: String
    /// The scan's sampled `v1:` hash ("" = none).
    var contentHash: String
    /// The stored whole-file SHA-256 covering exactly `sizeBytes`
    /// (`VideoScanModel.storedFullDigest`); nil = identity not known.
    var fullDigest: String?
    var contentFixity: ContentFixity?
    var archiveFixity: ArchiveFixity?
    var lifecycleStage: LifecycleStage
    var archiveStage: ArchiveStage
    var removal: RemovalMarker?
    var removalRevision: Int
    var derivedFrom: UUID?
    var derivationKind: String?
    var supersededByID: UUID?
    var duplicateGroupID: UUID?
    var pairGroupID: UUID?
    var auditSeenOn: AuditSeenOn?
    var audioFingerprint: AudioFingerprintStamp?
    var isSetAside: Bool

    init(id: UUID = UUID(), fullPath: String, filename: String = "", sizeBytes: Int64 = 1,
         streamTypeRaw: String = "", audioCodec: String = "", contentHash: String = "",
         fullDigest: String? = nil, contentFixity: ContentFixity? = nil, archiveFixity: ArchiveFixity? = nil,
         lifecycleStage: LifecycleStage = .cataloged, archiveStage: ArchiveStage = .none,
         removal: RemovalMarker? = nil, removalRevision: Int = 0,
         derivedFrom: UUID? = nil, derivationKind: String? = nil, supersededByID: UUID? = nil,
         duplicateGroupID: UUID? = nil, pairGroupID: UUID? = nil, auditSeenOn: AuditSeenOn? = nil,
         audioFingerprint: AudioFingerprintStamp? = nil, isSetAside: Bool = false) {
        self.id = id
        self.fullPath = fullPath
        self.filename = filename.isEmpty ? (fullPath as NSString).lastPathComponent : filename
        self.sizeBytes = sizeBytes
        self.streamTypeRaw = streamTypeRaw
        self.audioCodec = audioCodec
        self.contentHash = contentHash
        self.fullDigest = fullDigest
        self.contentFixity = contentFixity
        self.archiveFixity = archiveFixity
        self.lifecycleStage = lifecycleStage
        self.archiveStage = archiveStage
        self.removal = removal
        self.removalRevision = removalRevision
        self.derivedFrom = derivedFrom
        self.derivationKind = derivationKind
        self.supersededByID = supersededByID
        self.duplicateGroupID = duplicateGroupID
        self.pairGroupID = pairGroupID
        self.auditSeenOn = auditSeenOn
        self.audioFingerprint = audioFingerprint
        self.isSetAside = isSetAside
    }

    /// Project one record. Main actor (the record lives there).
    @MainActor
    init(record r: VideoRecord) {
        self.init(id: r.id, fullPath: r.fullPath, filename: r.filename, sizeBytes: r.sizeBytes,
                  streamTypeRaw: r.streamTypeRaw, audioCodec: r.audioCodec, contentHash: r.contentHash,
                  fullDigest: VideoScanModel.storedFullDigest(r),
                  contentFixity: r.contentFixity, archiveFixity: r.archiveFixity,
                  lifecycleStage: r.lifecycleStage, archiveStage: r.archiveStage,
                  removal: r.removal, removalRevision: r.removalRevision,
                  derivedFrom: r.derivedFrom, derivationKind: r.derivationKind, supersededByID: r.supersededByID,
                  duplicateGroupID: r.duplicateGroupID, pairGroupID: r.pairGroupID, auditSeenOn: r.auditSeenOn,
                  audioFingerprint: r.audioFingerprint, isSetAside: r.isSetAside)
    }

    /// No removal marker: the row stands for a file that is (as far as the
    /// catalog knows) at its path.
    var isLive: Bool { removal == nil }

    /// Live, in scope and not retired by a repair — `pfActiveRecords`.
    var isActive: Bool { isLive && !isSetAside && supersededByID == nil }

    /// A file with bytes at a path.
    var hasBytes: Bool { sizeBytes > 0 && !fullPath.isEmpty }
}

/// One confirmed event and the content keys of its members
/// (EventsDecisionSnapshot: the stored full SHA-256, "pair:<pairGroupID>",
/// or "id:<recordID>").
struct IntegrityEventFact: Sendable, Equatable {
    var id: UUID
    var name: String
    var memberKeys: [String]

    init(id: UUID = UUID(), name: String, memberKeys: [String]) {
        self.id = id
        self.name = name
        self.memberKeys = memberKeys
    }
}

// MARK: - The constraints

enum CatalogConstraints {

    /// Every rule, each a concept. Raw values are stable (they land in the
    /// report file).
    enum Rule: String, CaseIterable, Sendable, Codable {
        case uniqueIDs
        case oneLiveRowPerPath
        case lineageTargetsExist
        case promotionsHaveASource
        case removalMirrorsLifecycle
        case requiredFields
        case wholeFileDigestsAreWhole
        case removalRevisionNonNegative
        case auditStampNamesItsVolume
        case eventMembersExist
        case pathAliasByCase
        case supersessionCycle
        case duplicateGroupDigestsAgree
        case derivedStampsMatchContent

        /// Which tier owns the rule: the stale-stamp rule is tier 4
        /// ("is derived knowledge still about this content?"), the rest tier 5.
        var tier: Int { self == .derivedStampsMatchContent ? 4 : 5 }

        /// The rule as a heading, and the phrase that follows a count of its
        /// findings ("3 paths have more than one live row") — DATA, not a
        /// switch per use (a growing switch → a table; Rick 2026-10-07).
        private static let words: [Rule: (title: String, counted: String)] = [
            .uniqueIDs: ("Unique ids", "ids are carried by more than one row"),
            .oneLiveRowPerPath: ("One live row per path", "paths have more than one live row"),
            .lineageTargetsExist: ("Lineage targets exist", "lineage links point at nothing"),
            .promotionsHaveASource: ("Archive copies name their source", "archive copies name no source"),
            .removalMirrorsLifecycle: ("Removal marker matches the lifecycle stage", "removal markers disagree with the lifecycle stage"),
            .requiredFields: ("Required fields present", "rows miss a required field"),
            .wholeFileDigestsAreWhole: ("Whole-file digests are whole", "whole-file digests are not whole"),
            .removalRevisionNonNegative: ("Removal revision never negative", "removal revisions are negative"),
            .auditStampNamesItsVolume: ("Audit stamp names its volume", "audit stamps name no volume"),
            .eventMembersExist: ("Event members exist", "event members point at nothing"),
            .pathAliasByCase: ("One file per path on a case-insensitive volume", "paths differ only by case from another live row's"),
            .supersessionCycle: ("Supersession ends", "supersession chains run in a circle"),
            .duplicateGroupDigestsAgree: ("Duplicate groups agree on the bytes", "duplicate groups hold files with different whole-file digests"),
            .derivedStampsMatchContent: ("Derived stamps match the content", "sound prints were made from other content"),
        ]

        var title: String { Self.words[self]?.title ?? rawValue }

        /// "3 paths have more than one live row".
        func words(count n: Int) -> String {
            "\(n.formatted()) \(Self.words[self]?.counted ?? "findings")"
        }
    }

    struct Finding: Sendable, Equatable {
        var rule: Rule
        /// The row the finding is about; nil for a catalog-wide fact (an
        /// event member, a duplicated id).
        var recordID: UUID?
        var words: String
        /// A person has to look — a run alone cannot fix it.
        var needsDecision: Bool

        init(_ rule: Rule, recordID: UUID?, words: String, needsDecision: Bool = true) {
            self.rule = rule
            self.recordID = recordID
            self.words = words
            self.needsDecision = needsDecision
        }
    }

    /// The live rows that share one path once case is folded — the first
    /// row's id, every row's id, and the DISTINCT spellings.
    struct CaseAlias: Sendable, Equatable {
        var firstID: UUID
        var rows = 1
        var paths: [String]
    }

    /// The live members of one duplicate group — the first member's id and
    /// the DISTINCT lowercase whole-file digests they carry.
    struct GroupDigests: Sendable, Equatable {
        var firstID: UUID
        var digests: [String]
    }

    /// What the rules look things up in — built ONCE, O(rows).
    struct Index: Sendable {
        var ids: Set<UUID> = []
        /// id → how many rows carry it (only ids seen more than once).
        var duplicatedIDs: [UUID: Int] = [:]
        /// path → ids of the LIVE rows at it (only paths with more than one).
        var sharedLivePaths: [String: [UUID]] = [:]
        /// lowercased path → the live rows there, only when their exact
        /// spellings differ (the same spelling twice is `sharedLivePaths`).
        var caseAliasedPaths: [String: CaseAlias] = [:]
        /// row id → the row that superseded it.
        var supersededBy: [UUID: UUID] = [:]
        /// duplicate group → its live members' digests, only when they differ.
        var disagreeingGroups: [UUID: GroupDigests] = [:]
        var pairGroups: Set<UUID> = []
        /// Lowercase whole-file digests any row carries.
        var fullDigests: Set<String> = []
    }

    static func index(_ rows: [IntegrityRow]) -> Index {
        var idx = Index()
        var seen: [UUID: Int] = [:]
        var byPath: [String: [UUID]] = [:]
        var byFoldedPath: [String: CaseAlias] = [:]
        var groups: [UUID: GroupDigests] = [:]
        idx.ids.reserveCapacity(rows.count)
        for r in rows {
            seen[r.id, default: 0] += 1
            idx.ids.insert(r.id)
            if r.isLive, !r.fullPath.isEmpty {
                byPath[r.fullPath, default: []].append(r.id)
                noteFoldedPath(r, in: &byFoldedPath)
            }
            if r.isLive, let g = r.duplicateGroupID { noteGroupDigest(r, group: g, in: &groups) }
            if let by = r.supersededByID { idx.supersededBy[r.id] = by }
            if let p = r.pairGroupID { idx.pairGroups.insert(p) }
            if let d = r.fullDigest { idx.fullDigests.insert(d.lowercased()) }
        }
        idx.duplicatedIDs = seen.filter { $0.value > 1 }
        idx.sharedLivePaths = byPath.filter { $0.value.count > 1 }
        idx.caseAliasedPaths = byFoldedPath.filter { $0.value.paths.count > 1 }
        idx.disagreeingGroups = groups.filter { $0.value.digests.count > 1 }
        return idx
    }

    private static func noteFoldedPath(_ r: IntegrityRow, in table: inout [String: CaseAlias]) {
        let folded = r.fullPath.lowercased()
        guard var alias = table[folded] else {
            table[folded] = CaseAlias(firstID: r.id, paths: [r.fullPath])
            return
        }
        alias.rows += 1
        if !alias.paths.contains(r.fullPath) { alias.paths.append(r.fullPath) }
        table[folded] = alias
    }

    private static func noteGroupDigest(_ r: IntegrityRow, group: UUID, in table: inout [UUID: GroupDigests]) {
        let digest = r.fullDigest?.lowercased()
        guard var g = table[group] else {
            table[group] = GroupDigests(firstID: r.id, digests: digest.map { [$0] } ?? [])
            return
        }
        if let digest, !g.digests.contains(digest) { g.digests.append(digest) }
        table[group] = g
    }

    /// Run every rule. Findings come out in rule order, then row order.
    static func check(rows: [IntegrityRow], events: [IntegrityEventFact]) -> [Finding] {
        let idx = index(rows)
        var out: [Finding] = []
        for rule in rules { out += rule(rows, idx, events) }
        return out
    }

    /// The rule table: an array of function references (≈ a C++ table of
    /// function pointers). Its order is the report's order. `@Sendable`
    /// because the table is read from a worker thread.
    static let rules: [@Sendable ([IntegrityRow], Index, [IntegrityEventFact]) -> [Finding]] = [
        uniqueIDs, oneLiveRowPerPath, lineageTargetsExist, promotionsHaveASource, removalMirrorsLifecycle,
        requiredFields, wholeFileDigestsAreWhole, removalRevisionNonNegative, auditStampNamesItsVolume,
        eventMembersExist, pathAliasByCase, supersessionCycle, duplicateGroupDigestsAgree,
        derivedStampsMatchContent,
    ]

    // MARK: Rules (one concept each)

    /// PK: no two rows carry one id.
    static func uniqueIDs(_ rows: [IntegrityRow], _ idx: Index, _ events: [IntegrityEventFact]) -> [Finding] {
        idx.duplicatedIDs.sorted { $0.key.uuidString < $1.key.uuidString }.map { id, n in
            Finding(.uniqueIDs, recordID: id, words: "\(n) rows carry the same id \(short(id))")
        }
    }

    /// Unique: one LIVE row per path (a row with a removal marker may share
    /// the path of the row that replaced it).
    static func oneLiveRowPerPath(_ rows: [IntegrityRow], _ idx: Index, _ events: [IntegrityEventFact]) -> [Finding] {
        idx.sharedLivePaths.sorted { $0.key < $1.key }.map { path, ids in
            Finding(.oneLiveRowPerPath, recordID: ids.first, words: "\(ids.count) rows share the path \(path)")
        }
    }

    /// FK: `derivedFrom` and `supersededByID` point at rows that exist.
    static func lineageTargetsExist(_ rows: [IntegrityRow], _ idx: Index, _ events: [IntegrityEventFact]) -> [Finding] {
        var out: [Finding] = []
        for r in rows {
            if let from = r.derivedFrom, !idx.ids.contains(from) {
                out.append(Finding(.lineageTargetsExist, recordID: r.id,
                                   words: "lineage points at a row that no longer exists (derived from \(short(from)))"))
            }
            if let by = r.supersededByID, !idx.ids.contains(by) {
                out.append(Finding(.lineageTargetsExist, recordID: r.id,
                                   words: "superseded by a row that no longer exists (\(short(by)))"))
            }
        }
        return out
    }

    /// An archive copy (Promote's derivation kind) always knows what it was
    /// promoted from.
    static func promotionsHaveASource(_ rows: [IntegrityRow], _ idx: Index, _ events: [IntegrityEventFact]) -> [Finding] {
        rows.filter { $0.derivationKind == ArchivePromotion.derivationKind && $0.derivedFrom == nil }.map {
            Finding(.promotionsHaveASource, recordID: $0.id,
                    words: "an archive copy with no record of what it was promoted from")
        }
    }

    /// The marker ⇔ lifecycle rule the one removal engine writes
    /// (`VideoScanModel.lifecycleMirror(for:)`): In the Trash mirrors as
    /// Trashed; the other states leave the stage alone.
    static func removalMirrorsLifecycle(_ rows: [IntegrityRow], _ idx: Index, _ events: [IntegrityEventFact]) -> [Finding] {
        var out: [Finding] = []
        for r in rows {
            guard let state = r.removal?.state, let mirror = VideoScanModel.lifecycleMirror(for: state),
                  r.lifecycleStage != mirror else { continue }
            out.append(Finding(.removalMirrorsLifecycle, recordID: r.id,
                               words: "marked \(words(state)), but the lifecycle stage says \"\(r.lifecycleStage.rawValue)\" (expected \"\(mirror.rawValue)\")"))
        }
        return out
    }

    /// Not-null / check: a path, and a size that is not negative.
    static func requiredFields(_ rows: [IntegrityRow], _ idx: Index, _ events: [IntegrityEventFact]) -> [Finding] {
        var out: [Finding] = []
        for r in rows {
            if r.fullPath.trimmingCharacters(in: .whitespaces).isEmpty {
                out.append(Finding(.requiredFields, recordID: r.id, words: "a row with no path"))
            }
            if r.sizeBytes < 0 {
                out.append(Finding(.requiredFields, recordID: r.id, words: "a negative size (\(r.sizeBytes))"))
            }
        }
        return out
    }

    /// A whole-file digest field never holds the sampled `v1:` value: when
    /// the algorithm says sha256 the digest is 64 hex characters.
    static func wholeFileDigestsAreWhole(_ rows: [IntegrityRow], _ idx: Index, _ events: [IntegrityEventFact]) -> [Finding] {
        var out: [Finding] = []
        for r in rows {
            if let f = r.contentFixity, f.algorithm == ContentFixity.sha256, let why = digestShapeProblem(f.digest) {
                out.append(Finding(.wholeFileDigestsAreWhole, recordID: r.id, words: "the whole-file fixity \(why)"))
            }
            if let a = r.archiveFixity, a.algorithm == ContentFixity.sha256, let why = digestShapeProblem(a.digest) {
                out.append(Finding(.wholeFileDigestsAreWhole, recordID: r.id, words: "the archive fixity \(why)"))
            }
        }
        return out
    }

    /// Why a sha256 digest string is not a whole-file SHA-256; nil when it is.
    static func digestShapeProblem(_ digest: String) -> String? {
        if digest.hasPrefix("v1:") { return "holds a sampled \"v1:\" value, not a whole-file SHA-256" }
        if !isSHA256Hex(digest) { return "is not a 64-character SHA-256 (\"\(digest.prefix(16))…\")" }
        return nil
    }

    static func isSHA256Hex(_ s: String) -> Bool {
        s.count == 64 && s.allSatisfy(\.isHexDigit)
    }

    /// Check: the engine's write counter never goes below zero.
    static func removalRevisionNonNegative(_ rows: [IntegrityRow], _ idx: Index, _ events: [IntegrityEventFact]) -> [Finding] {
        rows.filter { $0.removalRevision < 0 }.map {
            Finding(.removalRevisionNonNegative, recordID: $0.id, words: "a removal revision below zero (\($0.removalRevision))")
        }
    }

    /// An audit where-seen stamp always names its volume (the audit's one
    /// proof rule compares it; an empty one would prove nothing).
    static func auditStampNamesItsVolume(_ rows: [IntegrityRow], _ idx: Index, _ events: [IntegrityEventFact]) -> [Finding] {
        rows.filter { ($0.auditSeenOn?.volumeUUID ?? "x").trimmingCharacters(in: .whitespaces).isEmpty }.map {
            Finding(.auditStampNamesItsVolume, recordID: $0.id, words: "the audit's where-seen stamp names no volume")
        }
    }

    /// FK: every confirmed event member resolves to a row — by id, by A/V
    /// pair group, or by whole-file digest.
    static func eventMembersExist(_ rows: [IntegrityRow], _ idx: Index, _ events: [IntegrityEventFact]) -> [Finding] {
        var out: [Finding] = []
        for e in events {
            for key in e.memberKeys where !memberResolves(key, in: idx) {
                out.append(Finding(.eventMembersExist, recordID: nil,
                                   words: "event \"\(e.name)\": a member points at a row that no longer exists (\(key.prefix(24)))"))
            }
        }
        return out
    }

    static func memberResolves(_ key: String, in idx: Index) -> Bool {
        if key.hasPrefix("id:") { return UUID(uuidString: String(key.dropFirst(3))).map(idx.ids.contains) ?? false }
        if key.hasPrefix("pair:") { return UUID(uuidString: String(key.dropFirst(5))).map(idx.pairGroups.contains) ?? false }
        return idx.fullDigests.contains(key.lowercased())
    }

    /// Unique, case-folded: two live rows whose paths differ only by case
    /// name ONE file on the volumes this app ships on (APFS and HFS+ as
    /// formatted by default are case-insensitive). A case-sensitive volume
    /// can hold both — the words say which assumption is made, and a
    /// person decides.
    static func pathAliasByCase(_ rows: [IntegrityRow], _ idx: Index, _ events: [IntegrityEventFact]) -> [Finding] {
        idx.caseAliasedPaths.sorted { $0.key < $1.key }.map { _, alias in
            Finding(.pathAliasByCase, recordID: alias.firstID,
                    words: "\(alias.rows) rows at paths that differ only by case (\(alias.paths.joined(separator: " · "))) — one file on a case-insensitive volume")
        }
    }

    /// Acyclic: following `supersededByID` ends somewhere. A circle makes no
    /// row the current one — every member is "retired by" another member.
    /// One finding per circle (at its first row in row order); a chain that
    /// merely leads INTO a circle is not reported again. Each id is walked
    /// once (`settled`), so this is O(rows) over any shape.
    static func supersessionCycle(_ rows: [IntegrityRow], _ idx: Index, _ events: [IntegrityEventFact]) -> [Finding] {
        var out: [Finding] = []
        var settled: Set<UUID> = []
        for r in rows where r.supersededByID != nil && !settled.contains(r.id) {
            var path: [UUID] = []
            var seen: Set<UUID> = []
            var cursor: UUID? = r.id
            while let id = cursor, !settled.contains(id), seen.insert(id).inserted {
                path.append(id)
                cursor = idx.supersededBy[id]
            }
            if let id = cursor, seen.contains(id), !settled.contains(id) {
                let circle = Array(path.drop { $0 != id })
                out.append(Finding(.supersessionCycle, recordID: circle.first,
                                   words: "superseded in a circle (\((circle + [id]).map(short).joined(separator: " → "))) — no row is the current one"))
            }
            settled.formUnion(path)
        }
        return out
    }

    /// Consistency: the live members of one duplicate group carry ONE
    /// whole-file digest (or none yet). Two digests in one group means the
    /// group claims "copies" of files that are not the same bytes.
    static func duplicateGroupDigestsAgree(_ rows: [IntegrityRow], _ idx: Index, _ events: [IntegrityEventFact]) -> [Finding] {
        idx.disagreeingGroups.sorted { $0.key.uuidString < $1.key.uuidString }.map { group, g in
            Finding(.duplicateGroupDigestsAgree, recordID: g.firstID,
                    words: "duplicate group \(short(group)): its members carry \(g.digests.count) different whole-file digests — not copies of one another")
        }
    }

    /// Tier 4: a derived stamp (the sound print today) names the content it
    /// was made from; when the row's own digest or size no longer agrees,
    /// the knowledge is about other bytes.
    static func derivedStampsMatchContent(_ rows: [IntegrityRow], _ idx: Index, _ events: [IntegrityEventFact]) -> [Finding] {
        var out: [Finding] = []
        for r in rows {
            guard let stamp = r.audioFingerprint, let why = staleStampReason(stamp, row: r) else { continue }
            out.append(Finding(.derivedStampsMatchContent, recordID: r.id, words: "stale derived knowledge: the sound print \(why)"))
        }
        return out
    }

    /// Why `stamp` is no longer about `row`'s content; nil when it still is
    /// (or when neither side knows enough to say). Tier 3 uses the same
    /// rule to leave a stale stamp alone (it is this tier's finding).
    static func staleStampReason(_ stamp: AudioFingerprintStamp, row: IntegrityRow) -> String? {
        if stamp.sizeBytes != row.sizeBytes {
            return "was made from a file of another size (\(stamp.sizeBytes) vs \(row.sizeBytes) bytes)"
        }
        if AudioFingerprintStamp.isFullDigest(stamp.contentDigest) {
            guard let digest = row.fullDigest else { return nil }
            return stamp.contentDigest.lowercased() == AudioFingerprintStamp.fullDigest(digest) ? nil
                : "was made from other content (its SHA-256 differs from the row's)"
        }
        if !row.contentHash.isEmpty, stamp.contentDigest != row.contentHash {
            return "was made from other content (its sampled hash differs from the row's)"
        }
        return nil
    }

    // MARK: Words

    static func short(_ id: UUID) -> String { String(id.uuidString.prefix(8)) }

    static func words(_ state: RemovalMarker.State) -> String {
        switch state {
        case .inTrash: return "In the Trash"
        case .removedFromCatalog: return "removed from the catalog"
        case .missing: return "Missing"
        }
    }
}
