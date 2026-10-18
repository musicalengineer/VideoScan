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
// The first real report (Rick's catalog, 745 findings, 2026-10-17) taught
// three rules what the catalog actually promises:
//   • a duplicate group is a CANDIDATE (DuplicateDetector scores duration,
//     timecode, audio, created…); only a group whose reasons say "hash"
//     claimed the bytes matched, so only that group can be wrong about
//     them (514 of 710 groups were false positives before);
//   • a lineage link to a row that was purged is HISTORY, not a decision —
//     it is reported unverified (`needsDecision == false`; tier 5 counts it
//     as could-not-check) and the link is kept (100 rows, 74 on the archive);
//   • a QuickTime reference movie is a few MB that ffprobe reads as hours
//     of video (`referenceMovie`): bytes per second tells it apart, no I/O.
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
    /// ffprobe's duration (0 = unknown).
    var durationSeconds: Double
    var streamTypeRaw: String
    /// ffprobe's container name ("QuickTime / MOV", "MXF (Material
    /// eXchange Format)"…); "" = not probed.
    var container: String
    /// "" = no video stream.
    var videoCodec: String
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
    /// How DuplicateDetector put this row in its group — its tags joined
    /// by "+" ("duration+timecode+audio"; "hash" = the sampled hashes
    /// matched). "" = no group or no reason recorded.
    var duplicateReasons: String
    var pairGroupID: UUID?
    var auditSeenOn: AuditSeenOn?
    var audioFingerprint: AudioFingerprintStamp?
    var isSetAside: Bool

    init(id: UUID = UUID(), fullPath: String, filename: String = "", sizeBytes: Int64 = 1, durationSeconds: Double = 0,
         streamTypeRaw: String = "", container: String = "", videoCodec: String = "", audioCodec: String = "", contentHash: String = "",
         fullDigest: String? = nil, contentFixity: ContentFixity? = nil, archiveFixity: ArchiveFixity? = nil,
         lifecycleStage: LifecycleStage = .cataloged, archiveStage: ArchiveStage = .none,
         removal: RemovalMarker? = nil, removalRevision: Int = 0,
         derivedFrom: UUID? = nil, derivationKind: String? = nil, supersededByID: UUID? = nil,
         duplicateGroupID: UUID? = nil, duplicateReasons: String = "", pairGroupID: UUID? = nil,
         auditSeenOn: AuditSeenOn? = nil, audioFingerprint: AudioFingerprintStamp? = nil, isSetAside: Bool = false) {
        self.id = id
        self.fullPath = fullPath
        self.filename = filename.isEmpty ? (fullPath as NSString).lastPathComponent : filename
        self.sizeBytes = sizeBytes
        self.durationSeconds = durationSeconds
        self.streamTypeRaw = streamTypeRaw
        self.container = container
        self.videoCodec = videoCodec
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
        self.duplicateReasons = duplicateReasons
        self.pairGroupID = pairGroupID
        self.auditSeenOn = auditSeenOn
        self.audioFingerprint = audioFingerprint
        self.isSetAside = isSetAside
    }

    /// Project one record, on whichever task owns it: the main actor for
    /// the live rows (`verifyCatalogSnapshot`), the read task for rows
    /// decoded from the audited file (Import to SQLite's Verify phase,
    /// codex 2026-10-17 P2). It reads stored fields and a nonisolated
    /// static only.
    init(record r: VideoRecord) {
        self.init(id: r.id, fullPath: r.fullPath, filename: r.filename, sizeBytes: r.sizeBytes, durationSeconds: r.durationSeconds,
                  streamTypeRaw: r.streamTypeRaw, container: r.container, videoCodec: r.videoCodec, audioCodec: r.audioCodec,
                  contentHash: r.contentHash,
                  fullDigest: VideoScanModel.storedFullDigest(r),
                  contentFixity: r.contentFixity, archiveFixity: r.archiveFixity,
                  lifecycleStage: r.lifecycleStage, archiveStage: r.archiveStage,
                  removal: r.removal, removalRevision: r.removalRevision,
                  derivedFrom: r.derivedFrom, derivationKind: r.derivationKind, supersededByID: r.supersededByID,
                  duplicateGroupID: r.duplicateGroupID, duplicateReasons: r.duplicateReasons, pairGroupID: r.pairGroupID,
                  auditSeenOn: r.auditSeenOn,
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
        case referenceMovie
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
            .lineageTargetsExist: ("Lineage targets exist", "lineage links point at replacements removed from the catalog — the replacement may be lost"),
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
            .referenceMovie: ("Possible reference movies", "files may be reference movies — Verify Media decides"),
            .derivedStampsMatchContent: ("Derived stamps match the content", "sound prints were made from other content"),
        ]

        /// The phrase for a rule's UNVERIFIED findings (`needsDecision ==
        /// false`) when it differs from its decided phrase — only the
        /// lineage rule has both (a purged source is history; a purged
        /// replacement is a loss signal).
        private static let unverifiedWords: [Rule: String] = [
            .lineageTargetsExist: "lineage links point at rows removed from the catalog — kept as history",
        ]

        var title: String { Self.words[self]?.title ?? rawValue }

        /// "3 paths have more than one live row". `decided: false` asks for
        /// the unverified phrase where the rule has one.
        func words(count n: Int, decided: Bool = true) -> String {
            let phrase = decided ? nil : Self.unverifiedWords[self]
            return "\(n.formatted()) \(phrase ?? Self.words[self]?.counted ?? "findings")"
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

    /// The live members of one duplicate group — the first member's id,
    /// the DISTINCT lowercase whole-file digests they carry, and whether
    /// any member's reasons say the group was formed on a sampled-hash
    /// match (the only kind of group that claims the bytes agree).
    struct GroupDigests: Sendable, Equatable {
        var firstID: UUID
        var digests: [String]
        var sampledHashMatch = false
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
        /// duplicate group → its live members' digests, only when the group
        /// was formed on a sampled-hash match AND the digests differ.
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
        idx.disagreeingGroups = groups.filter { $0.value.sampledHashMatch && $0.value.digests.count > 1 }
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
        var g = table[group] ?? GroupDigests(firstID: r.id, digests: [])
        if let digest, !g.digests.contains(digest) { g.digests.append(digest) }
        if claimsSampledHashMatch(r.duplicateReasons) { g.sampledHashMatch = true }
        table[group] = g
    }

    /// DuplicateDetector's reasons are its scoring tags joined by "+"
    /// ("hash+duration+timecode"); only the "hash" tag says the sampled
    /// hashes matched — the rest are similarity, never bytes.
    static func claimsSampledHashMatch(_ reasons: String) -> Bool {
        reasons.split(separator: "+").contains { $0.trimmingCharacters(in: .whitespaces) == "hash" }
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
        eventMembersExist, pathAliasByCase, supersessionCycle, duplicateGroupDigestsAgree, referenceMovie,
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

    /// FK: `derivedFrom` / `supersededByID` whose target id is not in the
    /// catalog. Two meanings (codex P2, 2026-10-17):
    ///   * `derivedFrom` → purged: a purged SOURCE (Remove from Catalog, the
    ///     ledger's prune) leaves its children's links behind on purpose —
    ///     UNVERIFIED, kept as history (`needsDecision == false`; tier 5
    ///     counts it as could-not-check). Nothing asks anyone to cut it.
    ///   * `supersededByID` → purged: the REPLACEMENT — the row that was
    ///     the usable copy — is gone. A loss signal: a DECISION.
    static func lineageTargetsExist(_ rows: [IntegrityRow], _ idx: Index, _ events: [IntegrityEventFact]) -> [Finding] {
        var out: [Finding] = []
        for r in rows {
            if let from = r.derivedFrom, !idx.ids.contains(from) {
                out.append(Finding(.lineageTargetsExist, recordID: r.id,
                                   words: "derived from a row that was removed from the catalog — the link is kept as history",
                                   needsDecision: false))
            }
            if let by = r.supersededByID, !idx.ids.contains(by) {
                out.append(Finding(.lineageTargetsExist, recordID: r.id,
                                   words: "superseded by a row that was removed from the catalog — the replacement may be lost; check the ledger",
                                   needsDecision: true))
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

    /// Consistency: a duplicate group formed on a sampled-hash match
    /// ("hash" among some live member's reasons) claimed the bytes agree;
    /// two whole-file digests among its live members say they do not. A
    /// group formed on similarity alone (duration, timecode, audio,
    /// created…) never promised byte identity and is not a finding.
    static func duplicateGroupDigestsAgree(_ rows: [IntegrityRow], _ idx: Index, _ events: [IntegrityEventFact]) -> [Finding] {
        idx.disagreeingGroups.sorted { $0.key.uuidString < $1.key.uuidString }.map { group, g in
            Finding(.duplicateGroupDigestsAgree, recordID: g.firstID,
                    words: "duplicate group \(short(group)): formed on a sampled-hash match, but its members carry \(g.digests.count) different whole-file digests")
        }
    }

    /// A clip shorter than this is never judged a reference movie.
    static let referenceMovieMinSeconds = 10.0
    /// Real video, even DV at its thinnest, carries far more than this
    /// per second; a QuickTime reference movie carries only pointers.
    static let referenceMovieMaxBytesPerSecond = 5_000.0

    /// Plausibility, reported as UNVERIFIED: a live QuickTime video row
    /// whose bytes per second of duration are far below any real codec may
    /// be a reference movie — a small file that names media kept in other
    /// files (33 rows of Rick's catalog read as hours of dvvideo at 3 MB).
    /// No I/O: size, duration, codec and container from the row; Verify
    /// Media (tier 2) decides, so this is never a decision (codex P2,
    /// 2026-10-17: a self-contained 13 KB / 20 s H.264 MP4 fired). Reference
    /// movies are a QuickTime feature, so only `.mov` / `.qt` files (or an
    /// extensionless file whose container says QuickTime) are judged;
    /// audio-only rows are left alone (an MP3 at 16 KB/s is real).
    static func referenceMovie(_ rows: [IntegrityRow], _ idx: Index, _ events: [IntegrityEventFact]) -> [Finding] {
        rows.filter(isPossibleReferenceMovie).map {
            Finding(.referenceMovie, recordID: $0.id,
                    words: "\(sizeWords($0.sizeBytes)) for \(durationWords($0.durationSeconds)) in a QuickTime file — possibly a reference movie whose content lives in other files; Verify Media decides",
                    needsDecision: false)
        }
    }

    static func isPossibleReferenceMovie(_ r: IntegrityRow) -> Bool {
        guard r.isLive, r.hasBytes, isQuickTimeFile(r), !r.videoCodec.isEmpty,
              r.durationSeconds >= referenceMovieMinSeconds else { return false }
        return Double(r.sizeBytes) / r.durationSeconds < referenceMovieMaxBytesPerSecond
    }

    /// The extension decides (ffprobe names the SAME "QuickTime / MOV"
    /// demuxer for .mp4); the container only vouches for a file with none.
    static func isQuickTimeFile(_ r: IntegrityRow) -> Bool {
        let ext = (r.fullPath as NSString).pathExtension.lowercased()
        if ext == "mov" || ext == "qt" { return true }
        return ext.isEmpty && r.container.lowercased().contains("quicktime")
    }

    /// "3.3 MB", "812 KB", "1.2 GB" — decimal units, one decimal above KB.
    static func sizeWords(_ bytes: Int64) -> String {
        let b = Double(bytes)
        if b >= 1e9 { return String(format: "%.1f GB", b / 1e9) }
        if b >= 1e6 { return String(format: "%.1f MB", b / 1e6) }
        return "\(Int((b / 1e3).rounded())) KB"
    }

    /// "2 h 1 min", "5 min 10 s", "35 s".
    static func durationWords(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let (h, m, s) = (total / 3_600, total % 3_600 / 60, total % 60)
        if h > 0 { return "\(h) h \(m) min" }
        if m > 0 { return "\(m) min \(s) s" }
        return "\(s) s"
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
