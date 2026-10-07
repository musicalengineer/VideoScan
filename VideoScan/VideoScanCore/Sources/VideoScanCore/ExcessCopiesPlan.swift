// ExcessCopiesPlan.swift
// "Delete excess copies", Tier 1 (docs/design/delete_excess_copies_2026_10_06.md,
// with the C05 amendments and Rick's decisions of 2026-10-07).
//
// THE WORKFLOW, in Rick's words: "Once the whole master FFV1, access,
// editable is in the archive, review and delete all the rest, in bulk, not
// one video at a time." Tier 1 is the part of "the rest" that is
// BYTE-FOR-BYTE an archived file.
//
// This file is the pure half: which catalog copies OUTSIDE the Master
// Archive are offered, which are left alone (and why), and which are
// flagged instead of offered. It reads plain values (`ExcessCopySnapshot`)
// the app captures from the catalog; it never touches the disk and never
// decides a move on its own. The move is the app's PruneApply pipeline,
// which reads every offered copy in full against the archive digest at the
// moment of the move (a nomination here is never proof).
//
// NOMINATION (how a copy offers itself — never authority to delete):
//   * `digest`  — the copy's own stored whole-file SHA-256 equals an
//                 archived file's read-back digest (`archiveFixity`), sizes
//                 equal. "Proven" for the forecast; still read at the move.
//   * `sampled` — its segmented `v1:` hash and size equal an archived
//                 file's. A CANDIDATE only: the full read at the move
//                 decides (codex #320 — a sampled hash proves "different",
//                 never "same").
//
// KEEP RULES (a copy that hits one is listed, never offered), in order:
//   1. on a drive marked Archive backup (amendment 3);
//   2. the one bulk-verb gate refuses it (archive tree, archive volume,
//      a drive marked Read only) — the app's verdict, carried in;
//   3. on a network mount (amendment 6);
//   4. on a drive that LOOKS like an archive backup — most of its matches
//      sit at the archive's own relative paths — until Rick marks it
//      (amendment 3; refused as a whole drive);
//   5. its drive is not connected (unknown means keep);
//   6. part of a recovered A/V pair;
//   7. in use by the Archive Angel;
//   8. Rick holds it (a "Keep" tag, Keep chosen in this lane, or a star
//      rating ≥ 4 — never ★★★, which Promote sets on every source).
// Then Rick's hard rule (decision 2): a copy whose duration exceeds the
// archived master's by more than `durationToleranceSeconds` is NEVER
// offered — it is FLAGGED "this copy is LONGER than the archive master: the
// archive may be missing footage". A length that cannot be compared (either
// side unknown) is left alone too: unknown means keep.
//
// NO OVERRIDE PATH (amendment 1): nothing here has a "the person checked it
// anyway" input. A copy is offered or it is not.
//
// ONE PLAN (amendment 4): the forecast, the confirmation and the run share
// this value; the run moves only copies that BOTH the plan it was shown and
// a fresh plan offer, against the same archived file.
//
// Worst-case memory: the archive-side indexes (two dictionaries over the
// archived files — hundreds) plus one `Copy` per nominated record. A 100k-
// record catalog with no nominations allocates nothing per record beyond
// the dictionary probes. Nothing is cached here.
//
// (For Rick: plain value types and static functions, like PrunePlan —
// `Sendable` ≈ "safe to copy to another thread"; no globals.)

import Foundation

// MARK: - Snapshot of one catalog record

public struct ExcessCopySnapshot: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var filename: String
    public var fullPath: String
    public var volumeName: String
    public var sizeBytes: Int64
    /// 0 = unknown (never probed, or the probe failed).
    public var durationSeconds: Double
    /// Segmented `v1:` content hash; "" = never hashed.
    public var contentHash: String
    /// The record's OWN stored whole-file SHA-256 (lowercased), when usable.
    public var wholeDigest: String?
    /// A promoted archive copy, or anything inside the archive root.
    public var isArchiveSide: Bool
    /// Archive side only: the read-back SHA-256 (`archiveFixity`), lowercased.
    /// nil = not verified — such a file nominates nothing.
    public var archiveDigest: String?
    /// Archive side only: when that digest was last confirmed.
    public var archiveVerifiedAt: Date?
    /// Archive side only: the FFV1 preservation master of its item.
    public var isPreservationMaster: Bool
    /// Archive side only: the path below the archive root.
    public var archiveRelPath: String?
    /// Lineage — archive files of one item share a root up this chain.
    public var derivedFrom: UUID?
    public var isPurged: Bool
    /// The VOLUME is mounted (never "the file exists").
    public var isOnline: Bool
    /// The one bulk-verb gate's refusal, in words; nil = clear.
    public var gateRefusal: String?
    /// The gate's refusal is the MASTER ARCHIVE's (its tree, its volume, or
    /// a drive that cannot be told apart from it — e.g. a firmlink spelling
    /// of an archive file). Such a copy is never a surviving copy outside
    /// the archive. A Read-only / Archive backup refusal is not this: those
    /// files are real copies elsewhere and still count (QA MAJOR 2).
    public var gateRefusesAsArchive: Bool
    public var isOnArchiveBackupDrive: Bool
    public var isNetworkMount: Bool
    public var isPairMember: Bool
    public var heldByAngel: Bool
    public var starRating: Int
    public var tags: [String]
    /// Rick chose Keep for this copy in the lane.
    public var keptInLane: Bool

    public init(id: UUID = UUID(), filename: String, fullPath: String, volumeName: String = "",
                sizeBytes: Int64, durationSeconds: Double = 0, contentHash: String = "",
                wholeDigest: String? = nil, isArchiveSide: Bool = false, archiveDigest: String? = nil,
                archiveVerifiedAt: Date? = nil, isPreservationMaster: Bool = false,
                archiveRelPath: String? = nil, derivedFrom: UUID? = nil, isPurged: Bool = false,
                isOnline: Bool = true, gateRefusal: String? = nil, gateRefusesAsArchive: Bool = false,
                isOnArchiveBackupDrive: Bool = false,
                isNetworkMount: Bool = false, isPairMember: Bool = false, heldByAngel: Bool = false,
                starRating: Int = 0, tags: [String] = [], keptInLane: Bool = false) {
        self.id = id; self.filename = filename; self.fullPath = fullPath; self.volumeName = volumeName
        self.sizeBytes = sizeBytes; self.durationSeconds = durationSeconds; self.contentHash = contentHash
        self.wholeDigest = wholeDigest; self.isArchiveSide = isArchiveSide; self.archiveDigest = archiveDigest
        self.archiveVerifiedAt = archiveVerifiedAt; self.isPreservationMaster = isPreservationMaster
        self.archiveRelPath = archiveRelPath; self.derivedFrom = derivedFrom; self.isPurged = isPurged
        self.isOnline = isOnline; self.gateRefusal = gateRefusal
        self.gateRefusesAsArchive = gateRefusesAsArchive; self.isOnArchiveBackupDrive = isOnArchiveBackupDrive
        self.isNetworkMount = isNetworkMount; self.isPairMember = isPairMember; self.heldByAngel = heldByAngel
        self.starRating = starRating; self.tags = tags; self.keptInLane = keptInLane
    }
}

// MARK: - The plan

public struct ExcessCopiesPlan: Equatable, Sendable {

    /// A copy whose length exceeds the master's by more than this is never
    /// offered (Rick's decision 2: "a small container tolerance").
    public static let durationToleranceSeconds: Double = 1.0

    /// How a copy nominated itself (never the proof — the move reads it).
    public enum Proof: String, Equatable, Sendable {
        case digest, sampled

        public var chip: String {
            switch self {
            case .digest:  return "exact (stored digest)"
            case .sampled: return "likely exact (read decides)"
            }
        }
    }

    public struct Copy: Equatable, Sendable, Identifiable {
        public let id: UUID
        public let filename: String
        public let fullPath: String
        public let volumeName: String
        public let sizeBytes: Int64
        public let durationSeconds: Double
        /// The archived file it matches — the one it is read against.
        public let archiveID: UUID
        public let proof: Proof
    }

    public struct LeftAlone: Equatable, Sendable, Identifiable {
        public var id: UUID { copy.id }
        public let copy: Copy
        public let reason: String
        /// Its drive is connected — it STAYS as a checkable copy outside
        /// the archive (an offline copy cannot be counted on).
        public let isConnected: Bool
    }

    public struct ArchiveFile: Equatable, Sendable, Identifiable {
        public let id: UUID
        public let filename: String
        public let fullPath: String
        public let volumeName: String
        public let sizeBytes: Int64
        public let durationSeconds: Double
        public let verifiedAt: Date?
        public let isPreservationMaster: Bool

        init(_ s: ExcessCopySnapshot) {
            id = s.id; filename = s.filename; fullPath = s.fullPath; volumeName = s.volumeName
            sizeBytes = s.sizeBytes; durationSeconds = s.durationSeconds; verifiedAt = s.archiveVerifiedAt
            isPreservationMaster = s.isPreservationMaster
        }
    }

    /// One archived item (its archive files share a lineage root) and the
    /// copies outside the archive that match one of its files.
    public struct Item: Equatable, Sendable, Identifiable {
        public let id: UUID
        /// The length every copy is judged against: the preservation master
        /// when the item has one, else the archived file matched first.
        public let master: ArchiveFile
        /// The archived files that copies match, in first-match order.
        public var archiveFiles: [ArchiveFile]
        public var offered: [Copy]
        public var leftAlone: [LeftAlone]
        /// Rick's hard rule: flagged, never offered.
        public var longer: [Copy]

        public var offeredBytes: Int64 { offered.reduce(0) { $0 + $1.sizeBytes } }

        /// Copies that STAY outside the archive (connected, so their file
        /// can be checked at the move), per archived file.
        public func survivors(of archiveID: UUID) -> [Copy] {
            leftAlone.filter { $0.copy.archiveID == archiveID && $0.isConnected }.map(\.copy)
                + longer.filter { $0.archiveID == archiveID }
        }

        /// After the offered copies go, no connected copy of this item's
        /// matched files remains outside the archive.
        public var leavesArchiveOnly: Bool {
            !offered.isEmpty && Set(offered.map(\.archiveID)).allSatisfy { survivors(of: $0).isEmpty }
        }

        public func archiveFile(_ id: UUID) -> ArchiveFile? { archiveFiles.first { $0.id == id } }
    }

    public let items: [Item]
    /// Drives refused as a whole because they look like an archive backup.
    public let backupLikeVolumes: [String]

    public init(items: [Item], backupLikeVolumes: [String]) {
        self.items = items
        self.backupLikeVolumes = backupLikeVolumes
    }

    public static let empty = ExcessCopiesPlan(items: [], backupLikeVolumes: [])

    public var offered: [Copy] { items.flatMap(\.offered) }
    public var offeredIDs: Set<UUID> { Set(items.lazy.flatMap(\.offered).map(\.id)) }
    public var offeredCount: Int { items.reduce(0) { $0 + $1.offered.count } }
    public var offeredBytes: Int64 { items.reduce(0) { $0 + $1.offeredBytes } }
    public var sampledCount: Int { items.reduce(0) { $0 + $1.offered.filter { $0.proof == .sampled }.count } }
    public var longerCount: Int { items.reduce(0) { $0 + $1.longer.count } }
    public var leftAloneCount: Int { items.reduce(0) { $0 + $1.leftAlone.count } }
    /// Items whose offered copies are all that remain outside the archive.
    public var archiveOnlyItems: [Item] { items.filter(\.leavesArchiveOnly) }

    /// The offered copy with this id, and the item it belongs to.
    public func offeredCopy(_ id: UUID) -> (item: Item, copy: Copy)? {
        for item in items { if let c = item.offered.first(where: { $0.id == id }) { return (item, c) } }
        return nil
    }

    // MARK: Words (one place; the views and tests read them)

    public static let offlineReason = "drive not connected"
    public static let backupDriveReason = "on a drive marked Archive backup — it keeps the archive safe"
    public static let networkReason = "on a network drive — this cleanup never removes files over the network"
    public static let backupLikeReason = "this drive looks like a backup of the archive (its files sit in the archive's own folders) — mark it Archive backup; until you decide, nothing on it is offered"
    public static let pairReason = "part of a recovered A/V pair Combine still needs"
    public static let angelReason = "in use by the Archive Angel"
    public static let unknownLengthReason = "its length could not be compared with the archive master — left alone"
    public static let longerFlag = "this copy is LONGER than the archive master: the archive may be missing footage"

    /// Stars at or above this hold a copy (the design's "star rating ≥ 4").
    /// NOT ★★★: Promote itself raises every promotion source to ★★★
    /// (VideoScanModel+MasterArchive), so ★★★ carries no person's intent
    /// and would hold the lane's largest class. On today's 1–3 scale this
    /// rule never fires; Rick's live holds are the Keep tag and Keep here.
    public static let holdStarRating = 4

    /// Rick's own hold on a copy, in words; nil = none.
    public static func personHold(starRating: Int, tags: [String], keptInLane: Bool) -> String? {
        if keptInLane { return "you chose Keep for it" }
        if starRating >= holdStarRating { return "you rated it \(starRating) stars" }
        if tags.contains(where: { $0.caseInsensitiveCompare("keep") == .orderedSame }) { return "you tagged it Keep" }
        return nil
    }

    public enum LengthVerdict: Equatable, Sendable { case fits, longer, unknown }

    /// Rick's decision 2, Tier 1 form.
    public static func lengthVerdict(copy: Double, master: Double) -> LengthVerdict {
        guard copy > 0, master > 0, copy.isFinite, master.isFinite else { return .unknown }
        return copy > master + durationToleranceSeconds ? .longer : .fits
    }

    // MARK: Compute

    /// The plan, from every catalog snapshot. O(snapshots) with dictionary
    /// passes; pure.
    public static func compute(_ snapshots: [ExcessCopySnapshot]) -> ExcessCopiesPlan {
        let index = ArchiveIndex(snapshots)
        guard !index.isEmpty else { return .empty }
        var nominated: [(snap: ExcessCopySnapshot, archive: ExcessCopySnapshot, proof: Proof)] = []
        for s in snapshots where !s.isPurged && !s.isArchiveSide {
            if let hit = index.nominate(s) { nominated.append((s, hit.archive, hit.proof)) }
        }
        let backupLike = backupLikeVolumes(nominated.map { ($0.snap, $0.archive) })
        var builder = ItemBuilder(index: index)
        for n in nominated {
            builder.add(n.snap, archive: n.archive, proof: n.proof, backupLike: backupLike)
        }
        return ExcessCopiesPlan(items: builder.items(), backupLikeVolumes: backupLike.sorted())
    }

    /// Why a nominated copy is left alone (keep rules 1–8), or nil.
    public static func keepReason(_ s: ExcessCopySnapshot, backupLike: Set<String>) -> String? {
        if s.isOnArchiveBackupDrive { return backupDriveReason }
        if let gate = s.gateRefusal { return gate }
        if s.isNetworkMount { return networkReason }
        if !s.volumeName.isEmpty, backupLike.contains(s.volumeName) { return backupLikeReason }
        if !s.isOnline { return offlineReason }
        if s.isPairMember { return pairReason }
        if s.heldByAngel { return angelReason }
        return personHold(starRating: s.starRating, tags: s.tags, keptInLane: s.keptInLane)
    }

    /// Amendment 3's structural detector: a drive where at least half of the
    /// archive matches sit at the archive's own relative path (two or more
    /// folder levels, so a bare filename never counts).
    static func backupLikeVolumes(_ pairs: [(copy: ExcessCopySnapshot, archive: ExcessCopySnapshot)]) -> Set<String> {
        var matches: [String: Int] = [:], mirrored: [String: Int] = [:]
        for (copy, archive) in pairs where !copy.volumeName.isEmpty {
            matches[copy.volumeName, default: 0] += 1
            if mirrorsArchivePath(copy.fullPath, relPath: archive.archiveRelPath) {
                mirrored[copy.volumeName, default: 0] += 1
            }
        }
        return Set(mirrored.filter { $0.value > 0 && $0.value * 2 >= (matches[$0.key] ?? 0) }.keys)
    }

    public static func mirrorsArchivePath(_ path: String, relPath: String?) -> Bool {
        guard let rel = relPath?.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
              rel.split(separator: "/").count >= 3 else { return false }
        return path.lowercased().hasSuffix("/" + rel.lowercased())
    }
}

// MARK: - Archive-side index

/// The archived files a copy can match, by whole digest and by `v1:`+size,
/// and the item each belongs to (lineage root). First match wins, in
/// snapshot order, so the result is deterministic.
struct ArchiveIndex {
    private var byDigest: [String: ExcessCopySnapshot] = [:]
    private var bySampled: [String: ExcessCopySnapshot] = [:]
    private var parentOf: [UUID: UUID] = [:]
    private var preservationByRoot: [UUID: ExcessCopySnapshot] = [:]

    /// Lineage hops followed to find an item's root (transcode → promote
    /// chains are two or three deep).
    static let maxHops = 8

    var isEmpty: Bool { byDigest.isEmpty && bySampled.isEmpty }

    init(_ snapshots: [ExcessCopySnapshot]) {
        for s in snapshots {
            if let p = s.derivedFrom { parentOf[s.id] = p }
        }
        for s in snapshots where s.isArchiveSide && !s.isPurged {
            guard let digest = s.archiveDigest, !digest.isEmpty else { continue }
            if byDigest[digest] == nil { byDigest[digest] = s }
            if let key = Self.sampledKey(s), bySampled[key] == nil { bySampled[key] = s }
            if s.isPreservationMaster {
                let root = root(of: s.id)
                if preservationByRoot[root] == nil { preservationByRoot[root] = s }
            }
        }
    }

    static func sampledKey(_ s: ExcessCopySnapshot) -> String? {
        guard s.contentHash.hasPrefix("v1:"), s.sizeBytes > 0 else { return nil }
        return "\(s.contentHash)|\(s.sizeBytes)"
    }

    func nominate(_ s: ExcessCopySnapshot) -> (archive: ExcessCopySnapshot, proof: ExcessCopiesPlan.Proof)? {
        if let d = s.wholeDigest, let a = byDigest[d], a.sizeBytes == s.sizeBytes { return (a, .digest) }
        if let key = Self.sampledKey(s), let a = bySampled[key] { return (a, .sampled) }
        return nil
    }

    /// The first record up the `derivedFrom` chain with no parent (cycle- and
    /// hop-guarded). Cheap: at most `maxHops` dictionary probes.
    func root(of id: UUID) -> UUID {
        var cursor = id
        var seen: Set<UUID> = [id]
        for _ in 0..<Self.maxHops {
            guard let p = parentOf[cursor], seen.insert(p).inserted else { break }
            cursor = p
        }
        return cursor
    }

    func master(for archive: ExcessCopySnapshot) -> (root: UUID, master: ExcessCopySnapshot) {
        let root = root(of: archive.id)
        return (root, preservationByRoot[root] ?? archive)
    }
}

// MARK: - Item assembly

struct ItemBuilder {
    let index: ArchiveIndex
    private var order: [UUID] = []
    private var byRoot: [UUID: ExcessCopiesPlan.Item] = [:]

    init(index: ArchiveIndex) { self.index = index }

    mutating func add(_ s: ExcessCopySnapshot, archive: ExcessCopySnapshot, proof: ExcessCopiesPlan.Proof,
                      backupLike: Set<String>) {
        let (root, master) = index.master(for: archive)
        var item = byRoot[root] ?? ExcessCopiesPlan.Item(id: root, master: .init(master), archiveFiles: [],
                                                         offered: [], leftAlone: [], longer: [])
        if byRoot[root] == nil { order.append(root) }
        if !item.archiveFiles.contains(where: { $0.id == archive.id }) { item.archiveFiles.append(.init(archive)) }
        let copy = ExcessCopiesPlan.Copy(id: s.id, filename: s.filename, fullPath: s.fullPath, volumeName: s.volumeName,
                                         sizeBytes: s.sizeBytes, durationSeconds: s.durationSeconds,
                                         archiveID: archive.id, proof: proof)
        if let why = ExcessCopiesPlan.keepReason(s, backupLike: backupLike) {
            item.leftAlone.append(.init(copy: copy, reason: why, isConnected: s.isOnline))
        } else {
            switch ExcessCopiesPlan.lengthVerdict(copy: s.durationSeconds, master: master.durationSeconds) {
            case .fits:    item.offered.append(copy)
            case .longer:  item.longer.append(copy)
            case .unknown: item.leftAlone.append(.init(copy: copy, reason: ExcessCopiesPlan.unknownLengthReason,
                                                       isConnected: s.isOnline))
            }
        }
        byRoot[root] = item
    }

    func items() -> [ExcessCopiesPlan.Item] { order.compactMap { byRoot[$0] } }
}
