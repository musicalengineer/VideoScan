// DeleteDuplicatesForecast.swift
// Delete Duplicates — the PREVIEW before Start (Rick's SanDisk run,
// 2026-09-21: 2,898 rows, 1.5 hours, ZERO deleted. He should have seen
// "0 deletable" in seconds, not after ninety minutes).
//
// KEEP ONE, TRASH ONLY (Rick 2026-10-09, design triage_delete_streamline
// §9 R3/R5): a row goes to the Trash when its keeper is proven identical at
// the move. So, from the catalog and the fixities already stored on its
// records ALONE — no file is opened — each row of the run is put in one
// bucket:
//     trash              — the keeper is in the catalog and connected, and
//                          nothing on record says the bytes differ
//     likelyNotDuplicate — the catalog already says the bytes differ
//                          (sizes differ, or both stored digests differ)
//     cannotCheck        — the keeper (or the row) is not in the catalog
//                          or its drive is not connected
// plus the bytes the run will read in full (each duplicate once, a keeper
// with no stored fixity once). No sibling is ever read: the keeper alone
// is the one verified copy the rule needs.
//
// It is a FORECAST, and says so. The run still decides every row at the
// moment of mutation from fresh stats and full reads — nothing here is
// evidence for anything. Optimistic where the run must read to know (a
// duplicate is assumed identical unless the catalog says not).
//
// Cost: O(rows) after the keepers are looked up — 100k rows in well under
// the scale test's budget. Memory: one small value per row and per keeper.
//
// (For Rick: plain value types and a static function — a C++ POD struct
// plus a free function. `[UUID: Copy]` ≈ std::unordered_map.)

import Foundation
import VideoScanCore

struct DeleteDuplicatesForecast: Equatable, Sendable {

    enum Bucket: String, CaseIterable, Sendable {
        case trash
        case likelyNotDuplicate
        case cannotCheck
    }

    struct Tally: Equatable, Sendable {
        /// Rows in the bucket.
        var files = 0
        var bytes: Int64 = 0
    }

    /// One keeper the catalog knows, reduced to what the forecast asks.
    struct Keeper: Sendable, Equatable {
        let id: UUID
        let sizeBytes: Int64
        /// The record's stamp-bound fixity digest when it is usable for
        /// verification (sha256, ctime in the stamp) — assumed current.
        let digest: String?
        /// Its drive is connected (mount table; no stat).
        let online: Bool
    }

    /// One row of the run, in plan order.
    struct Row: Sendable, Equatable {
        let id: UUID
        let sizeBytes: Int64
        /// The duplicate's own usable stored digest, if it has one.
        let digest: String?
        let keeperID: UUID?
        /// False when the row's record is gone or moved (the run skips it).
        var inCatalog: Bool = true
    }

    struct Input: Sendable {
        var rows: [Row]
        var keepers: [UUID: Keeper]
    }

    var buckets: [Bucket: Tally] = [:]
    /// Parallel to `Input.rows`: each row's id and its bucket.
    var rowIDs: [UUID] = []
    var rowBuckets: [Bucket] = []
    /// Everything the run is expected to read in full: each duplicate once,
    /// each keeper without a stored fixity once.
    var bytesToRead: Int64 = 0

    /// The bucket forecast for one row (tests; O(rows)).
    func bucket(for id: UUID) -> Bucket? {
        rowIDs.firstIndex(of: id).map { rowBuckets[$0] }
    }

    func tally(_ bucket: Bucket) -> Tally { buckets[bucket] ?? Tally() }
    var total: Tally {
        buckets.values.reduce(into: Tally()) { $0.files += $1.files; $0.bytes += $1.bytes }
    }

    // MARK: The forecast (pure)

    static func compute(_ input: Input) -> DeleteDuplicatesForecast {
        var out = DeleteDuplicatesForecast()
        out.rowBuckets.reserveCapacity(input.rows.count)
        out.rowIDs.reserveCapacity(input.rows.count)
        var learnedKeepers = Set<UUID>()

        func put(_ bucket: Bucket, _ row: Row) {
            out.rowIDs.append(row.id)
            out.rowBuckets.append(bucket)
            out.buckets[bucket, default: Tally()].files += 1
            out.buckets[bucket, default: Tally()].bytes += row.sizeBytes
        }

        for row in input.rows {
            guard row.inCatalog, let keeperID = row.keeperID, let keeper = input.keepers[keeperID], keeper.online else {
                put(.cannotCheck, row)
                continue
            }
            // Different sizes are refused before a byte is read.
            guard row.sizeBytes == keeper.sizeBytes else {
                put(.likelyNotDuplicate, row)
                continue
            }
            // From here the duplicate is read in full (and a keeper with no
            // stored fixity, once).
            out.bytesToRead += row.sizeBytes
            if keeper.digest == nil, learnedKeepers.insert(keeperID).inserted {
                out.bytesToRead += keeper.sizeBytes
            }
            if let k = keeper.digest, let d = row.digest, k.lowercased() != d.lowercased() {
                put(.likelyNotDuplicate, row)
                continue
            }
            put(.trash, row)
        }
        return out
    }

    // MARK: Words

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func number(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    /// The Start confirmation's button: one verb (design §2.3).
    static let confirmationButtonTitle = "Move Proven Copies to the Trash"
    static let decidesAtTheMoment = "The run proves each copy against its keeper at the moment it acts; a copy only ever goes to the Trash — emptying it is yours."

    /// The Start confirmation's lead, in plain words: what will be checked,
    /// the forecast with sizes, an honest "nothing will move" when that is
    /// the forecast, the bytes to read, and that the run decides each file.
    func confirmationText(volume: String) -> String {
        let n = total.files
        var text = "Check \(Self.number(n)) cop\(n == 1 ? "y" : "ies") on \(volume).\n\n"
        let t = tally(.trash), x = tally(.likelyNotDuplicate), c = tally(.cannotCheck)
        var parts: [String] = ["about \(Self.number(t.files)) to the Trash (\(Self.size(t.bytes)))"]
        parts.append("\(Self.number(x.files)) likely not duplicates (\(Self.size(x.bytes)))")
        if c.files > 0 {
            parts.append("\(Self.number(c.files)) cannot be checked — keeper not connected or not in the catalog (\(Self.size(c.bytes)))")
        }
        text += "Forecast (from the catalog — no file read yet): " + parts.joined(separator: ", ") + "."
        if t.files == 0 {
            text += "\n\nNothing will move — no copy here has a keeper that can be checked now."
        }
        text += "\n\nAbout \(Self.size(bytesToRead)) will be read in full. " + Self.decidesAtTheMoment
        return text
    }

    /// The same numbers as one app-log line.
    func logLine(volume: String) -> String {
        func part(_ bucket: Bucket, _ words: String) -> String {
            let t = tally(bucket)
            return "\(words) \(t.files) (\(Self.size(t.bytes)))"
        }
        let parts = [
            part(.trash, "trash"),
            part(.likelyNotDuplicate, "likely not duplicates"),
            part(.cannotCheck, "cannot check"),
            "to read \(Self.size(bytesToRead))",
        ]
        return "delete duplicates forecast: \(volume) — " + parts.joined(separator: " · ")
    }
}

// MARK: - From the live catalog

extension VideoScanModel {

    /// One row to forecast: the plan row's id and size, its live record
    /// (nil when gone or moved), and its keeper's id. Every extra is a
    /// candidate — pairs included (R5 revised 2026-10-09 evening).
    struct DeleteDuplicatesForecastRow {
        let id: UUID
        let sizeBytes: Int64
        let record: VideoRecord?
        let keeperID: UUID?
    }

    /// The forecast for the Start confirmation: the same rows, in the same
    /// order, that `prepareDuplicateDeletion` will plan (the selection
    /// minus Master Archive files). Catalog only — O(records) passes.
    func deleteDuplicatesForecast(onVolume volumePath: String) -> DeleteDuplicatesForecast {
        let selection = duplicateDeletionSelection(onVolume: volumePath)
        let archiveVolume = archiveVolumeProtection()
        let targets = selection.targets.filter { r in bulkDeleteRefusal(r, volume: archiveVolume) == nil }
        let rows = targets.map { r in
            DeleteDuplicatesForecastRow(id: r.id, sizeBytes: r.sizeBytes, record: r,
                                        keeperID: r.duplicateGroupID.flatMap { selection.keepers[$0]?.id })
        }
        return deleteDuplicatesForecast(rows: rows)
    }

    /// The forecast for a plan about to run (fresh, resumed or reviewed):
    /// its unsettled rows, in plan order — every one of them chosen.
    func deleteDuplicatesForecast(for plan: DeleteDuplicatesPlan) -> DeleteDuplicatesForecast {
        let rows = plan.entries.filter { !$0.status.isSettled }.map { e -> DeleteDuplicatesForecastRow in
            let r = record(forID: e.id)
            let live = (r.map { !$0.isPurged && $0.fullPath == e.path } ?? false) ? r : nil
            return .init(id: e.id, sizeBytes: e.sizeBytes, record: live, keeperID: e.keeperPath.isEmpty ? nil : e.keeperID)
        }
        return deleteDuplicatesForecast(rows: rows)
    }

    /// Build the pure input: each row's keeper, looked up once, and whether
    /// its drive is connected (the mount table, read once).
    func deleteDuplicatesForecast(rows: [DeleteDuplicatesForecastRow]) -> DeleteDuplicatesForecast {
        let mounted = VolumeReachability.currentMountedRoots()
        var mountCache: [Substring: Bool] = [:]
        func online(_ path: String) -> Bool {
            guard path.hasPrefix("/Volumes/") else { return true }
            let name = path.dropFirst(9).prefix { $0 != "/" }
            if let hit = mountCache[name] { return hit }
            let isMounted = mounted.contains("/Volumes/" + name)
            mountCache[name] = isMounted
            return isMounted
        }
        func usableDigest(_ r: VideoRecord) -> String? {
            guard let f = r.contentFixity, f.isUsableForVerification else { return nil }
            return f.digest
        }
        var keepers: [UUID: DeleteDuplicatesForecast.Keeper] = [:]
        var out: [DeleteDuplicatesForecast.Row] = []
        out.reserveCapacity(rows.count)
        for row in rows {
            if let keeperID = row.keeperID, keepers[keeperID] == nil, let k = record(forID: keeperID), !k.isPurged {
                keepers[keeperID] = .init(id: k.id, sizeBytes: k.sizeBytes, digest: usableDigest(k), online: online(k.fullPath))
            }
            guard let r = row.record else {
                out.append(.init(id: row.id, sizeBytes: row.sizeBytes, digest: nil, keeperID: row.keeperID,
                                 inCatalog: false))
                continue
            }
            out.append(.init(id: r.id, sizeBytes: row.sizeBytes, digest: usableDigest(r), keeperID: row.keeperID))
        }
        return DeleteDuplicatesForecast.compute(.init(rows: out, keepers: keepers))
    }
}
