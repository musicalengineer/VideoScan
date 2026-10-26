// CatalogRowLock.swift
// ONE hash of the PER-ROW parts of a stored `files` row, as the store reads
// them back (codex #141 F2 closing pass, cycle #143: "refuse rather than
// guess"). The app's committer keeps, per record, the lock of the row it
// last saw stored; a commit submits it with the row, and the store refuses
// the WHOLE commit when the row it holds now hashes differently — another
// writer (a second process, a second connection) changed that row since
// this session last read or wrote it. An optimistic per-row lock on top of
// the catalog-wide generation compare-and-set.
//
// Computed by the STORE on both sides, from `CatalogLoadedRow` — never from
// the in-memory record: a record's whole-record fingerprint cannot
// round-trip through a load (display strings, junk scores and per-content
// values are not stored per row), so a lock taken from memory would refuse
// honest saves. The lock is read at launch (one per loaded row), after every
// landed row (the row read back once more inside the same transaction), and
// before every submitted row (the read-back the commit already does).
//
// What is IN the lock — everything keyed by the row's id:
//   files columns (path, size, probe facts, lifecycle, the removal marker
//   and its revision, the audit stamp), archive copy, backup destinations,
//   footage decisions, duplicate membership, the row-scoped knowledge
//   (lineage, supersession, repair confirmation, archivedAt), the pair link.
// What is NOT — everything keyed by the content digest or the volume, which
// a SIBLING copy's save or a volume rename changes without touching this
// row: the shared curated values (stars, notes, tags, people, date, place,
// attestations, music — these have their own per-field baseline,
// CatalogSharedCurated), the sound print, the bound derived values, the
// duplicate group's member count, the volume's names. A per-content fact
// changed by another writer is therefore NOT held back by this lock: the
// shared SCALARS are checked beside it through the per-field baseline, the
// shared SETS are written as deltas (merge-safe), and the machine facts
// (sound print, derived values) follow the last writer, as between two
// copies in one session.
//
// Cost: one SipHash over ~60 columns ≈ 10 µs a row; 14k rows at launch
// ≈ 0.15 s serial, run in parallel (`locks(of:)`). Memory: one Int a row.
// Dictionaries (probe_extra, row_knowledge) are hashed as canonical text so
// their iteration order never changes the lock. `Hasher` is seeded per
// process: a lock is never persisted or compared across launches.
//
// (For Rick: a row version number computed from the row's own columns —
// `WHERE rowversion = @expected` without a rowversion column.)

import Foundation

public enum CatalogRowLock {

    public typealias Value = Int

    /// The lock of one stored row.
    public static func of(_ row: CatalogLoadedRow) -> Value {
        var hasher = Hasher()
        hasher.combine(fileColumns(row.file))
        hasher.combine(encoded(row.archiveCopy))
        hasher.combine(encoded(row.backupDestinations))
        hasher.combine(encoded(row.footageDecisions))
        hasher.combine(encoded(row.duplicate))
        for field in row.rowKnowledge.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            hasher.combine(field.rawValue)
            hasher.combine(row.rowKnowledge[field]?.canonicalText() ?? "")
        }
        hasher.combine(row.pair?.pairedWithID)
        hasher.combine(row.pair?.pairGroupID)
        hasher.combine(row.pair?.pairConfidence)
        hasher.combine(row.pair?.combinedFromPairID)
        return hasher.finalize()
    }

    /// The locks of many rows, in order (the launch: the cores share the work).
    public static func locks(of rows: [CatalogLoadedRow]) -> [Value] {
        let count = rows.count
        guard count > 0 else { return [] }
        let chunkSize = max(64, count / (ProcessInfo.processInfo.activeProcessorCount * 4))
        let chunks = (count + chunkSize - 1) / chunkSize
        var out = [Value](repeating: 0, count: count)
        out.withUnsafeMutableBufferPointer { buffer in
            // Each chunk writes only its own index range (as CatalogChangeDetector does).
            nonisolated(unsafe) let slots = buffer
            DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                let lower = chunk * chunkSize
                let upper = min(count, lower + chunkSize)
                for index in lower..<upper { slots[index] = of(rows[index]) }
            }
        }
        return out
    }

    /// The `files` columns with `probe_extra` hashed as canonical text.
    private static func fileColumns(_ file: CatalogRecordDTO.FileRow) -> Int {
        var plain = file
        plain.probeExtra = [:]
        var hasher = Hasher()
        hasher.combine(encoded(plain))
        hasher.combine(CatalogJSONValue.object(file.probeExtra).canonicalText())
        return hasher.finalize()
    }

    /// A value's encoding, hashed. The row structs are plain Codable value
    /// types whose synthesized encoding cannot throw; were it ever to, the
    /// lock is a fresh random number — it then never matches, and the save
    /// is REFUSED and named rather than let through unchecked.
    private static func encoded<T: Encodable>(_ value: T) -> Int {
        (try? HashingEncoder.hash(value)) ?? Int.random(in: Int.min...Int.max)
    }
}

/// ONE comparison of what the committer expects the store to hold for a
/// row against what a reader finds — the same check at the commit door
/// (inside the transaction, CatalogCommitBody) and in Catalog ▸ Reopen's
/// read-back (the app's CatalogCommitter), so the two cannot disagree.
/// Pure: the reader's finding in, a mismatch (or nil) out.
public enum CatalogRowCheck {

    /// What the store holds for an id.
    public enum Found: Sendable {
        /// A `files` row (live, or tombstoned, or purged — the lock says which).
        case row(CatalogLoadedRow)
        /// No `files` row; a `pending_rows` payload that is not purged.
        case pendingOnly
        /// Neither.
        case nothing
    }

    /// Why the row may not be saved as the committer submitted it.
    public enum Mismatch: Sendable, Equatable {
        /// Expected a row at this lock: the store holds no row for the id.
        case rowGone
        /// Expected a row at this lock: its per-row parts changed.
        case rowChanged
        /// Expected a held payload: another writer stored the record as a row.
        case materialised
        /// Expected a held payload: it is gone.
        case pendingGone
        /// A shared scalar group this session edited was also changed in
        /// the store since this session's baseline (notes, stars, …).
        case sharedChanged([CatalogSharedCurated.Group])
        /// The stored row no longer becomes a record (cannot be compared).
        case undecodable(String)

        public var words: String {
            switch self {
            case .rowGone: return "its row is no longer in the catalog"
            case .rowChanged: return "another writer changed its row"
            case .materialised: return "another writer stored it as a row while this session held it without a whole-file hash"
            case .pendingGone: return "its held payload is no longer in the catalog"
            case .sharedChanged(let groups): return "another writer also changed its \(groups.map { "\($0)" }.joined(separator: ", "))"
            case .undecodable(let why): return "its stored row could not be compared: \(why)"
            }
        }
    }

    /// The reader's finding for `id`.
    public static func find(id: String, in reader: any CatalogLiveReading) throws -> Found {
        if let row = try reader.storedRow(id: id) { return .row(row) }
        return try reader.storedRecordPresent(id: id) ? .pendingOnly : .nothing
    }

    /// nil = the store holds exactly what the committer expects (for the
    /// parts the lock and the per-field baseline cover); else why not.
    public static func check(_ expected: CatalogCommit.Expectation, snapshot: VideoRecordDTO,
                             sharedBaseline: CatalogSharedCurated?, found: Found) -> Mismatch? {
        switch (expected, found) {
        case (.row(let lock), .row(let row)):
            guard CatalogRowLock.of(row) == lock else { return .rowChanged }
            return sharedScalarMismatch(snapshot: snapshot, baseline: sharedBaseline, stored: row)
        case (.row, .pendingOnly), (.row, .nothing):
            return .rowGone
        case (.pending, .row):
            return .materialised
        case (.pending, .pendingOnly):
            return nil
        case (.pending, .nothing):
            return .pendingGone
        }
    }

    /// A shared SCALAR group this session edited (since its own baseline)
    /// whose stored value is not that baseline: the other writer changed it
    /// too, and writing ours would overwrite theirs unnamed. A group the
    /// store shows as a copies' CONFLICT (empty, `shown.conflicts`) is not
    /// one: a person's write resolves that by design (decision 1). Sets are
    /// deltas (merge-safe) and are not compared.
    private static func sharedScalarMismatch(snapshot: VideoRecordDTO, baseline: CatalogSharedCurated?,
                                             stored row: CatalogLoadedRow) -> Mismatch? {
        guard let baseline else { return nil }
        let mine = CatalogSharedCurated(snapshot)
        let edited = CatalogSharedCurated.Group.allCases.filter { !$0.isSet && !mine.same($0, as: baseline) }
        guard !edited.isEmpty else { return nil }
        let stored: CatalogSharedCurated
        do {
            stored = CatalogSharedCurated(try VideoRecord(loaded: row))
        } catch {
            return .undecodable(String(describing: error))
        }
        let inConflict = Set(row.shown.conflicts)
        let changed = edited.filter { group in
            !group.fields.contains(where: inConflict.contains) && !baseline.sameAsStored(group, as: stored)
        }
        return changed.isEmpty ? nil : .sharedChanged(changed)
    }
}
