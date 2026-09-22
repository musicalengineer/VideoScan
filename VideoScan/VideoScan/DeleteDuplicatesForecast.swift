// DeleteDuplicatesForecast.swift
// Delete Duplicates — the PREVIEW before Start (Rick's SanDisk run,
// 2026-09-21: 2,898 rows, 1.5 hours, ZERO deleted. He should have seen
// "0 deletable" in seconds, not after ninety minutes).
//
// From the catalog and the fixities already stored on its records ALONE —
// no file is opened, nothing is stat'ed — each row of the run is put in
// one bucket:
//     permanent          — ≥ 3 copies with stored evidence would remain
//     trash              — exactly 2 would remain (or "Prefer the Trash")
//     needsSiblingReads  — the count falls short, but siblings WITHOUT
//                          stored evidence are online; the run will read
//                          N of them to decide
//     leftAlone          — only the original remains elsewhere (with every
//                          readable sibling, still fewer than two)
//     likelyNotDuplicate — the catalog already says the bytes differ
//                          (sizes differ, or both stored digests differ)
//     cannotCheck        — the keeper (or the row) is not in the catalog
//                          or its drive is not connected
// plus the bytes the run will read in full (each duplicate once, a keeper
// with no stored fixity once, each sibling to prove).
//
// It is a FORECAST, and says so. The run still decides every row at the
// moment of mutation from fresh stats and full reads — nothing here is
// evidence for anything. The simulation walks the rows in plan order the
// way the job does: an earlier row forecast to go is gone for later rows;
// one forecast to stay is a sibling for them (unproven, so a read); a
// later row is "still to be decided" and never counted; a sibling read
// once is known for the rest of the run; a keeper read once is known.
// Optimistic where the run must read to know (a sibling is assumed to
// match; a duplicate is assumed identical unless the catalog says not).
//
// Cost: O(records) to index the families once, then O(rows × family
// size). Tonight's 2,898 rows: milliseconds. 100k rows: under the scale
// test's budget. Memory: one small value per member record + one bucket
// per row (~100 bytes × records) — freed when the forecast is dropped.
//
// (For Rick: plain value types and a static function — a C++ POD struct
// plus a free function. `[UUID: Copy]` ≈ std::unordered_map.)

import Foundation
import VideoScanCore

struct DeleteDuplicatesForecast: Equatable, Sendable {

    enum Bucket: String, CaseIterable, Sendable {
        case permanent
        case trash
        case needsSiblingReads
        case leftAlone
        case likelyNotDuplicate
        case cannotCheck
    }

    struct Tally: Equatable, Sendable {
        /// Rows in the bucket.
        var files = 0
        var bytes: Int64 = 0
    }

    /// One copy the catalog knows, reduced to what the tier asks about.
    struct Copy: Sendable, Equatable {
        let id: UUID
        let sizeBytes: Int64
        /// The record's stamp-bound fixity digest when it is usable for
        /// verification (sha256, ctime in the stamp) — assumed current.
        let digest: String?
        /// Its drive is connected (mount table; no stat).
        let online: Bool
        /// A Master Archive copy with a promote-time digest on record —
        /// counted like the tier counts it (needs `digest` too), never
        /// read to prove it.
        let isArchive: Bool
        let archiveDigest: String?
    }

    /// One row of the run, in plan order.
    struct Row: Sendable, Equatable {
        let id: UUID
        let sizeBytes: Int64
        /// The duplicate's own usable stored digest, if it has one.
        let digest: String?
        let keeperID: UUID?
        let groupID: UUID?
        /// False when the row's record is gone or moved (the run skips it).
        var inCatalog: Bool = true
    }

    struct Input: Sendable {
        var rows: [Row]
        /// Every record a row may ask about: keepers, members, archive
        /// copies, the rows themselves.
        var copies: [UUID: Copy]
        /// Group id → the ids of its members (and linked archive copies).
        var members: [UUID: [UUID]]
        var preferTrash: Bool
    }

    var buckets: [Bucket: Tally] = [:]
    /// Parallel to `Input.rows`: each row's id and its bucket.
    var rowIDs: [UUID] = []
    var rowBuckets: [Bucket] = []

    /// The bucket forecast for one row (tests; O(rows)).
    func bucket(for id: UUID) -> Bucket? {
        rowIDs.firstIndex(of: id).map { rowBuckets[$0] }
    }
    /// Siblings the run is expected to read to prove them.
    var siblingReads = 0
    var siblingReadBytes: Int64 = 0
    /// Everything the run is expected to read in full: duplicates,
    /// keepers without a stored fixity, siblings.
    var bytesToRead: Int64 = 0
    /// Trash rows that one more proven sibling would make permanent.
    var trashMayBecomePermanent = 0

    func tally(_ bucket: Bucket) -> Tally { buckets[bucket] ?? Tally() }
    var total: Tally {
        buckets.values.reduce(into: Tally()) { $0.files += $1.files; $0.bytes += $1.bytes }
    }

    // MARK: The simulation (pure)

    static func compute(_ input: Input) -> DeleteDuplicatesForecast {
        var out = DeleteDuplicatesForecast()
        out.rowBuckets.reserveCapacity(input.rows.count)
        out.rowIDs.reserveCapacity(input.rows.count)
        let goal = input.preferTrash ? DeletionTierDecision.minimumForTrash : DeletionTierDecision.minimumForPermanent
        var position: [UUID: Int] = [:]
        position.reserveCapacity(input.rows.count)
        for (i, row) in input.rows.enumerated() where position[row.id] == nil { position[row.id] = i }
        var removed = Set<UUID>()
        var notACopy = Set<UUID>()
        var proven = Set<UUID>()
        var learnedKeepers = Set<UUID>()

        func put(_ bucket: Bucket, _ row: Row) {
            out.rowIDs.append(row.id)
            out.rowBuckets.append(bucket)
            out.buckets[bucket, default: Tally()].files += 1
            out.buckets[bucket, default: Tally()].bytes += row.sizeBytes
        }

        for (i, row) in input.rows.enumerated() {
            guard row.inCatalog, let keeperID = row.keeperID, let keeper = input.copies[keeperID], keeper.online else {
                put(.cannotCheck, row)
                continue
            }
            let keeperKnown = keeper.digest != nil || learnedKeepers.contains(keeperID)
            let wanted = keeper.digest ?? row.digest
            var counted = 1
            var readable: [Copy] = []
            var seen = Set<UUID>()
            for memberID in input.members[row.groupID ?? UUID()] ?? [] {
                guard memberID != row.id, memberID != keeperID, seen.insert(memberID).inserted,
                      let copy = input.copies[memberID] else { continue }
                if copy.isArchive {
                    if copy.online, let d = copy.digest, copy.archiveDigest == d, wanted == nil || d == wanted {
                        counted += 1
                    }
                    continue
                }
                if let p = position[memberID], p > i { continue }        // still to be decided in this run
                if removed.contains(memberID) || notACopy.contains(memberID) || !copy.online { continue }
                if let d = copy.digest {
                    if wanted == nil || d == wanted { counted += 1 }
                    continue
                }
                if proven.contains(memberID) { counted += 1; continue }
                readable.append(copy)
            }

            // The job's pre-check: with the keeper's digest known, a row
            // that cannot reach two even with every readable sibling is
            // left where it is — nothing moved, nothing read.
            if keeperKnown && counted + readable.count < DeletionTierDecision.minimumForTrash {
                put(.leftAlone, row)
                continue
            }
            // Different sizes are refused before a byte is read.
            if row.sizeBytes != keeper.sizeBytes {
                put(.likelyNotDuplicate, row)
                notACopy.insert(row.id)
                continue
            }
            // From here the duplicate is read in full (and a keeper with
            // no stored fixity, once).
            out.bytesToRead += row.sizeBytes
            if !keeperKnown {
                out.bytesToRead += keeper.sizeBytes
                learnedKeepers.insert(keeperID)
            }
            if let k = keeper.digest, let d = row.digest, k != d {
                put(.likelyNotDuplicate, row)
                notACopy.insert(row.id)
                continue
            }
            func read(_ n: Int) {
                for copy in readable.prefix(n) {
                    proven.insert(copy.id)
                    out.siblingReads += 1
                    out.siblingReadBytes += copy.sizeBytes
                    out.bytesToRead += copy.sizeBytes
                }
            }
            if counted >= goal {
                put(counted >= DeletionTierDecision.minimumForPermanent && !input.preferTrash ? .permanent : .trash, row)
                removed.insert(row.id)
            } else if counted >= DeletionTierDecision.minimumForTrash {
                // Two with evidence (and Prefer the Trash off): the Trash
                // at least; one proven sibling more would make it permanent.
                put(.trash, row)
                if !readable.isEmpty { read(1); out.trashMayBecomePermanent += 1 }
                removed.insert(row.id)
            } else if counted + readable.count >= DeletionTierDecision.minimumForTrash {
                put(.needsSiblingReads, row)
                read(min(readable.count, goal - counted))
                removed.insert(row.id)
            } else {
                put(.leftAlone, row)
            }
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

    /// The Start confirmation's block: one line per non-empty bucket with
    /// the count and the size, then the bytes to read.
    static let confirmationButtonTitle = "Check and Remove Proven Copies"
    static let decidesAtTheMoment = "The run decides each file at the moment it acts; nothing leaves unless the copies are proven."

    /// The Start confirmation's lead, in plain words (2026-09-22: the old
    /// "This will permanently delete N…" was untrue — the Trash at exactly
    /// two, left-alone rows): what will be checked, the forecast with
    /// sizes, an honest "nothing can be removed yet" when that is the
    /// forecast, the bytes to read, and that the run decides each file.
    func confirmationText(volume: String) -> String {
        let n = total.files
        var text = "Check \(Self.number(n)) cop\(n == 1 ? "y" : "ies") on \(volume).\n\n"
        let p = tally(.permanent), t = tally(.trash), r = tally(.needsSiblingReads)
        let l = tally(.leftAlone), x = tally(.likelyNotDuplicate), c = tally(.cannotCheck)
        var parts = [
            "about \(Self.number(p.files)) deleted (\(Self.size(p.bytes)))",
            "\(Self.number(t.files)) to the Trash (\(Self.size(t.bytes)))",
            "\(Self.number(r.files)) need other copies read first (\(Self.size(siblingReadBytes)) to read)",
            "\(Self.number(l.files)) left alone — only the original remains elsewhere (\(Self.size(l.bytes)))",
            "\(Self.number(x.files)) likely not duplicates (\(Self.size(x.bytes)))",
        ]
        if c.files > 0 {
            parts.append("\(Self.number(c.files)) cannot be checked — keeper not connected or not in the catalog (\(Self.size(c.bytes)))")
        }
        text += "Forecast (from the catalog — no file read yet): " + parts.joined(separator: ", ") + "."
        if trashMayBecomePermanent > 0 {
            text += " \(Self.number(trashMayBecomePermanent)) of the Trash ones may be deleted outright once one more copy is proven."
        }
        if p.files + t.files == 0 {
            text += r.files > 0
                ? "\n\nNothing can be removed yet — \(Self.number(r.files)) cop\(r.files == 1 ? "y needs its" : "ies need their") other copies read first."
                : "\n\nNothing can be removed — no copy here has enough proven copies elsewhere."
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
            part(.permanent, "delete"),
            part(.trash, "trash"),
            part(.needsSiblingReads, "needs sibling reads") + " [\(siblingReads) reads, \(Self.size(siblingReadBytes))]",
            part(.leftAlone, "left alone"),
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
    /// (nil when gone or moved) and its keeper's id.
    struct DeleteDuplicatesForecastRow {
        let id: UUID
        let sizeBytes: Int64
        let record: VideoRecord?
        let keeperID: UUID?
    }

    /// The forecast for the Start confirmation: the same rows, in the same
    /// order, that `prepareDuplicateDeletion` will plan (the selection
    /// minus Master Archive files). Catalog only — one O(records) pass.
    func deleteDuplicatesForecast(onVolume volumePath: String) -> DeleteDuplicatesForecast {
        let selection = duplicateDeletionSelection(onVolume: volumePath)
        let hasArchive = masterArchiveRootPath != nil
        let rows = selection.targets.compactMap { r -> DeleteDuplicatesForecastRow? in
            if hasArchive && (isArchiveCopy(r) || isInsideMasterArchive(path: r.fullPath)) { return nil }
            return .init(id: r.id, sizeBytes: r.sizeBytes, record: r,
                         keeperID: r.duplicateGroupID.flatMap { selection.keepers[$0]?.id })
        }
        return deleteDuplicatesForecast(rows: rows)
    }

    /// The forecast for a plan about to run (fresh or resumed): its
    /// unsettled rows, in plan order.
    func deleteDuplicatesForecast(for plan: DeleteDuplicatesPlan) -> DeleteDuplicatesForecast {
        let rows = plan.entries.filter { !$0.status.isSettled }.map { e -> DeleteDuplicatesForecastRow in
            let r = record(forID: e.id)
            let live = (r.map { !$0.isPurged && $0.fullPath == e.path } ?? false) ? r : nil
            return .init(id: e.id, sizeBytes: e.sizeBytes, record: live, keeperID: e.keeperPath.isEmpty ? nil : e.keeperID)
        }
        return deleteDuplicatesForecast(rows: rows)
    }

    /// Build the pure input: the families of every row from ONE pass over
    /// `records`, keepers and promotion-linked archive copies added,
    /// drives checked against the mount table once (no stat of any file).
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
        var copies: [UUID: DeleteDuplicatesForecast.Copy] = [:]
        func add(_ r: VideoRecord) {
            guard copies[r.id] == nil else { return }
            let archive = isArchiveCopy(r) ? r.archiveFixity : nil
            copies[r.id] = .init(id: r.id, sizeBytes: r.sizeBytes, digest: usableDigest(r), online: online(r.fullPath),
                                 isArchive: archive != nil, archiveDigest: archive?.digest.lowercased())
        }
        var groups = Set<UUID>()
        for row in rows { if let g = row.record?.duplicateGroupID { groups.insert(g) } }
        var members: [UUID: [UUID]] = [:]
        if !groups.isEmpty {
            var memberRecords: [VideoRecord] = []
            for r in records where !r.isPurged {
                guard let g = r.duplicateGroupID, groups.contains(g) else { continue }
                members[g, default: []].append(r.id)
                memberRecords.append(r)
                add(r)
            }
            // Archive copies linked by promotion (the tier asks about
            // `masterArchiveCopy(of:)` of every member and of the row).
            for r in memberRecords {
                guard let g = r.duplicateGroupID, let copy = masterArchiveCopy(of: r), !copy.isPurged,
                      copies[copy.id] == nil else { continue }
                add(copy)
                members[g, default: []].append(copy.id)
            }
        }
        var out: [DeleteDuplicatesForecast.Row] = []
        out.reserveCapacity(rows.count)
        for row in rows {
            if let keeperID = row.keeperID, copies[keeperID] == nil, let k = record(forID: keeperID), !k.isPurged { add(k) }
            guard let r = row.record else {
                out.append(.init(id: row.id, sizeBytes: row.sizeBytes, digest: nil, keeperID: row.keeperID,
                                 groupID: nil, inCatalog: false))
                continue
            }
            out.append(.init(id: r.id, sizeBytes: row.sizeBytes, digest: usableDigest(r), keeperID: row.keeperID,
                             groupID: r.duplicateGroupID))
        }
        return DeleteDuplicatesForecast.compute(.init(rows: out, copies: copies, members: members,
                                                      preferTrash: duplicateKeeperSettings.preferTrashForEveryDuplicate))
    }
}
