// PrunePlan.swift
// "Archived — what next?" and Triage ▸ Clean up ▸ Excess copies share THIS
// plan (docs/design/pruneplan_simple_2026-10-21.md, Rick 2026-10-21).
//
// Rick's rule: "Check for dups and copies, offer to delete; if none, say so;
// otherwise let the user delete what he wants. If it is too difficult to
// figure out, don't prune — say 'no obvious choices'."
//
// In one sentence: once a file is promoted, offer its byte-identical extra
// copies for the Trash; for everything else, say "no obvious choices" and why.
//
// A working copy is OFFERED only when all of these hold:
//   R1  its full SHA-256 equals the digest of a live, fixity-verified archive
//       file (`PruneSnapshot.digest` on both sides);
//   R2  it is a live row with no removal state (the app never snapshots one
//       that is not);
//   R3  it is not an archive file (and the app never snapshots one on the
//       archive's tree or volume — FamilyArchive is never listed);
//   R4  its drive is mounted, local, not Read only, not Archive backup;
//   R5  it is not a recovered A/V pair half.
// R2–R5 arrive as `PruneSnapshot.hold`, captured by the app; network and
// "missing on disk" are asked off the main actor by `confirmingOnDisk`.
// Everything else that looks related (the promotion source with other
// bytes, a version cut from it, the same filename) is listed with its
// reason and is never offered. Nothing here touches the disk or decides a
// move: the move re-reads BOTH files in full (VideoScanModel+PruneApply).
//
// Worst-case memory: one `Row` per listed copy (relevant records only — the
// app filters on the main actor) plus three dictionaries over the archive
// files. 100k snapshots ≈ 30 MB transient. Nothing is cached.
//
// (For Rick: plain value types and static functions — no globals; every rule
// is table-testable. `Sendable` ≈ "safe to copy to another thread".)

import Foundation

// MARK: - Reasons ("no obvious choices")

/// Why a copy is not offered, in the words the person reads.
public enum PruneReason: String, CaseIterable, Equatable, Sendable {
    case notPromoted = "not in the Master Archive yet"
    case archiveUnverified = "the archive copy hasn't been verified yet"
    case version = "a version, not the same bytes"
    case sameNameDifferentFootage = "same name, different footage"
    case notHashed = "not hashed yet"
    case driveOffline = "drive not connected"
    case driveProtected = "drive is protected"
    case pairHalf = "part of a recovered A/V pair"
    case missing = "not found where the catalog says"
    case mismatchAtMove = "not the same bytes as the archive copy — kept"

    public var text: String { rawValue }
}

// MARK: - Input: one catalog record

public struct PruneSnapshot: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var filename: String
    public var fullPath: String
    public var volumeName: String
    public var sizeBytes: Int64
    /// Working copy: its own whole-file SHA-256. Archive file: its
    /// fixity-verified SHA-256 — nil means "not verified". Lowercase hex.
    public var digest: String?
    public var isArchive: Bool
    /// Archive file: its promotion source. Working copy: what it was made from.
    public var derivedFrom: UUID?
    /// R2–R5 as the app found them (working copies only); nil = clear.
    public var hold: PruneReason?
    public var attestations: [BackupAttestation]

    public init(id: UUID = UUID(), filename: String, fullPath: String, volumeName: String = "",
                sizeBytes: Int64 = 0, digest: String? = nil, isArchive: Bool = false,
                derivedFrom: UUID? = nil, hold: PruneReason? = nil, attestations: [BackupAttestation] = []) {
        self.id = id; self.filename = filename; self.fullPath = fullPath; self.volumeName = volumeName
        self.sizeBytes = sizeBytes; self.digest = digest; self.isArchive = isArchive
        self.derivedFrom = derivedFrom; self.hold = hold; self.attestations = attestations
    }
}

// MARK: - The plan

public struct PrunePlan: Equatable, Sendable {

    /// The sheet shows at most this many copy rows; Apply acts only on rows shown.
    public static let maxRows = 200

    public struct Row: Equatable, Sendable, Identifiable {
        public let id: UUID
        public let filename: String
        public let fullPath: String
        public let volumeName: String
        public let sizeBytes: Int64
        /// nil = offered (R1–R5 hold); otherwise why not.
        public let reason: PruneReason?
        /// Same stored digest as the archive file — offered, or held by R2–R5.
        public let isIdentical: Bool
        public let attestations: [BackupAttestation]

        public var isOffered: Bool { reason == nil }

        init(_ s: PruneSnapshot, reason: PruneReason?, isIdentical: Bool) {
            id = s.id; filename = s.filename; fullPath = s.fullPath; volumeName = s.volumeName
            sizeBytes = s.sizeBytes; self.reason = reason; self.isIdentical = isIdentical
            attestations = s.attestations
        }

        /// The same row, held for `reason`.
        func with(_ reason: PruneReason) -> Row {
            Row(PruneSnapshot(id: id, filename: filename, fullPath: fullPath, volumeName: volumeName,
                              sizeBytes: sizeBytes, attestations: attestations),
                reason: reason, isIdentical: isIdentical)
        }
    }

    /// One archive file and the copies outside the archive that relate to it.
    public struct Item: Equatable, Sendable, Identifiable {
        /// The archive file itself (reason `.archiveUnverified` when it has no verified digest).
        public let archive: Row
        public let digest: String?
        public let sourceID: UUID?
        public internal(set) var rows: [Row]

        public var id: UUID { archive.id }
        public var offered: [Row] { rows.filter(\.isOffered) }
        public var offeredBytes: Int64 { offered.reduce(0) { $0 + $1.sizeBytes } }
        public var hasIdenticalCopy: Bool { rows.contains(where: \.isIdentical) }
    }

    public let items: [Item]
    /// Batch records with no archive file: "not in the Master Archive yet".
    public let unarchived: [Row]
    /// Rows left out by `shown(maxRows:)` — never offered from here.
    public let hiddenRowCount: Int

    public init(items: [Item], unarchived: [Row] = [], hiddenRowCount: Int = 0) {
        self.items = items; self.unarchived = unarchived; self.hiddenRowCount = hiddenRowCount
    }

    public static let empty = PrunePlan(items: [])

    public var offeredIDs: Set<UUID> { Set(items.lazy.flatMap(\.offered).map(\.id)) }
    public var offeredCount: Int { items.reduce(0) { $0 + $1.offered.count } }
    public var offeredBytes: Int64 { items.reduce(0) { $0 + $1.offeredBytes } }
    public var rowCount: Int { items.reduce(unarchived.count) { $0 + $1.rows.count } }

    /// Bytes of the offered rows in `selected`.
    public func selectedBytes(_ selected: Set<UUID>) -> Int64 {
        items.lazy.flatMap(\.offered).filter { selected.contains($0.id) }.reduce(0) { $0 + $1.sizeBytes }
    }

    public func selectedCount(_ selected: Set<UUID>) -> Int {
        items.lazy.flatMap(\.offered).filter { selected.contains($0.id) }.count
    }

    /// Where a row lives, by id — built once per call, O(rows).
    public struct Located: Equatable, Sendable {
        public let item: Item
        public let row: Row
    }

    public func locator() -> [UUID: Located] {
        var out: [UUID: Located] = [:]
        for item in items { for row in item.rows { out[row.id] = Located(item: item, row: row) } }
        return out
    }

    // MARK: Build

    /// The plan from the app's snapshots. `batch` nil = the whole catalog
    /// (items with an identical copy); otherwise the items the batch's
    /// records belong to, plus the batch records with no archive file.
    /// O(snapshots), dictionary passes; pure.
    public static func build(_ snapshots: [PruneSnapshot], batch: Set<UUID>? = nil) -> PrunePlan {
        var lookup = ArchiveLookup(snapshots.lazy.filter(\.isArchive))
        for s in snapshots where !s.isArchive { lookup.place(s) }
        let items = lookup.items.filter { keeps($0, batch: batch) }
        return PrunePlan(items: items, unarchived: unarchived(snapshots, items: items, batch: batch))
    }

    static func keeps(_ item: Item, batch: Set<UUID>?) -> Bool {
        guard let batch else { return item.hasIdenticalCopy }
        if batch.contains(item.archive.id) { return true }
        if let source = item.sourceID, batch.contains(source) { return true }
        return item.rows.contains { $0.isIdentical && batch.contains($0.id) }
    }

    static func unarchived(_ snapshots: [PruneSnapshot], items: [Item], batch: Set<UUID>?) -> [Row] {
        guard let batch, !batch.isEmpty else { return [] }
        var placed = Set(items.map(\.archive.id))
        for item in items { placed.formUnion(item.rows.map(\.id)) }
        return snapshots.filter { !$0.isArchive && batch.contains($0.id) && !placed.contains($0.id) }
            .map { Row($0, reason: .notPromoted, isIdentical: false) }
    }

    // MARK: Off-main disk facts

    /// Offered rows whose file is gone, or that sit on a network drive, are
    /// held with the reason. Only offered rows are asked (one stat each).
    public func confirmingOnDisk(isMissing: (String) -> Bool, isNetwork: (String) -> Bool) -> PrunePlan {
        func check(_ r: Row) -> Row {
            guard r.isOffered else { return r }
            if isMissing(r.fullPath) { return r.with(.missing) }
            return isNetwork(r.fullPath) ? r.with(.driveProtected) : r
        }
        let checked = items.map { item -> Item in
            var out = item
            out.rows = item.rows.map(check)
            return out
        }
        return PrunePlan(items: checked, unarchived: unarchived, hiddenRowCount: hiddenRowCount)
    }

    // MARK: The 200-row cap

    /// What the sheet lists: items with an offered row first, offered rows
    /// first within an item, at most `maxRows` rows; the rest are counted in
    /// `hiddenRowCount` and can never be selected or moved from here.
    public func shown(maxRows: Int = PrunePlan.maxRows) -> PrunePlan {
        var budget = max(0, maxRows), hidden = hiddenRowCount
        var out: [Item] = []
        for item in items.filter({ !$0.offered.isEmpty }) + items.filter({ $0.offered.isEmpty }) {
            let rows = item.rows.filter(\.isOffered) + item.rows.filter { !$0.isOffered }
            let take = min(budget, rows.count)
            hidden += rows.count - take
            budget -= take
            guard take > 0 || rows.isEmpty else { continue }
            var kept = item
            kept.rows = Array(rows.prefix(take))
            out.append(kept)
        }
        let listed = Array(unarchived.prefix(budget))
        hidden += unarchived.count - listed.count
        return PrunePlan(items: out, unarchived: listed, hiddenRowCount: hidden)
    }
}

// MARK: - Archive lookup (build's helper)

/// The archive files, and how a working copy finds the one it belongs to:
/// by verified digest (identical), by lineage (the source, or a version cut
/// from it or from the archive file), or by filename.
struct ArchiveLookup {
    private(set) var items: [PrunePlan.Item] = []
    private var byDigest: [String: Int] = [:]
    private var byLink: [UUID: Int] = [:]
    private var byName: [String: Int] = [:]

    fileprivate init<S: Sequence>(_ archives: S) where S.Element == PruneSnapshot {
        for a in archives { add(a) }
    }

    private mutating func add(_ a: PruneSnapshot) {
        let index = items.count
        let row = PrunePlan.Row(a, reason: a.digest == nil ? .archiveUnverified : nil, isIdentical: false)
        items.append(PrunePlan.Item(archive: row, digest: a.digest, sourceID: a.derivedFrom, rows: []))
        if let d = a.digest, byDigest[d] == nil { byDigest[d] = index }
        if let source = a.derivedFrom, byLink[source] == nil { byLink[source] = index }
        if byLink[a.id] == nil { byLink[a.id] = index }
        let name = a.filename.lowercased()
        if byName[name] == nil { byName[name] = index }
    }

    private struct Placement {
        let index: Int
        let reason: PruneReason?
        let isIdentical: Bool
    }

    /// First rule that matches wins: digest, then lineage, then name.
    private func placement(_ s: PruneSnapshot) -> Placement? {
        if let d = s.digest, let i = byDigest[d] { return Placement(index: i, reason: s.hold, isIdentical: true) }
        if let i = byLink[s.id] ?? s.derivedFrom.flatMap({ byLink[$0] }) {
            return Placement(index: i, reason: Self.related(s, items[i], otherBytes: .version), isIdentical: false)
        }
        guard let i = byName[s.filename.lowercased()] else { return nil }
        return Placement(index: i, reason: Self.related(s, items[i], otherBytes: .sameNameDifferentFootage),
                         isIdentical: false)
    }

    fileprivate mutating func place(_ s: PruneSnapshot) {
        guard let p = placement(s) else { return }
        items[p.index].rows.append(PrunePlan.Row(s, reason: p.reason, isIdentical: p.isIdentical))
    }

    /// A related (not identical) copy is never offered; the words say why.
    private static func related(_ s: PruneSnapshot, _ item: PrunePlan.Item, otherBytes: PruneReason) -> PruneReason {
        if item.digest == nil { return .archiveUnverified }
        return s.digest == nil ? .notHashed : otherBytes
    }
}
