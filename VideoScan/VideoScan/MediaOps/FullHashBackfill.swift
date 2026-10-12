// FullHashBackfill.swift
// "Fill In Full Hashes…" — the values and the planner (Rick 2026-10-11).
// Every active record on the catalog that lacks a VALID stored full SHA-256
// gets one, so the whole catalog can be backfilled overnight and a later
// "is this really a copy?" question is a stat, not a terabyte read.
//
// Shape:
//   • PLAN (this file, main actor, one O(records) pass, no I/O): group the
//     records that need a read into LANES, one per volume root, each lane
//     sorted by path. The need rule is CheckCopies' (`CheckCopiesPlanner
//     .need`): a valid stored hash → skip; an archived row / archive copy →
//     left alone; otherwise read. Because a record with a valid hash is
//     skipped, running again after a stop, quit or crash IS the resume.
//   • RUN (FullHashBackfillJob.swift): lanes in parallel, one sequential
//     reader per lane, behind the volume gates.
//   • RESUME OFFER (FullHashBackfillResume.swift): a tiny marker beside
//     catalog.json saying a run started and did not finish.
//
// Active = not removed (purged) and not superseded. Set-aside ("hidden")
// rows ARE included on purpose: they are still files on disk, and they are
// exactly the copies a later Clean Up needs proven.
//
// Memory: one `CheckCopiesItem` (~100 bytes) per record needing a read —
// ~10 MB at 100k — plus a dictionary of lanes keyed by volume root.

import Foundation
import VideoScanCore

// MARK: - Plan (values)

/// One drive's queue: read one file at a time, in path order.
struct FullHashBackfillLane: Sendable, Equatable {
    /// Volume root ("/Volumes/Archive1", or "/" for this Mac's disk).
    let root: String
    var items: [CheckCopiesItem] = []

    var bytes: Int64 { items.reduce(Int64(0)) { $0 + $1.sizeBytes } }
    var label: String { FullHashBackfillPlanner.label(forRoot: root) }
}

struct FullHashBackfillPlan: Sendable, Equatable {
    /// Sorted by root (≈ the lock-ordering rule the gate plan also uses).
    var lanes: [FullHashBackfillLane] = []
    /// Already carry a valid stored full hash — skipped (the resume rule).
    var alreadyHashed = 0
    /// Archived rows / archive copies — never written here.
    var archivedLeftAlone = 0

    var fileCount: Int { lanes.reduce(0) { $0 + $1.items.count } }
    var bytes: Int64 { lanes.reduce(Int64(0)) { $0 + $1.bytes } }
}

/// Builds the plan in one pass. Main actor because it reads live records.
@MainActor
enum FullHashBackfillPlanner {

    static func plan(records: [VideoRecord], isReadOnly: (VideoRecord) -> Bool) -> FullHashBackfillPlan {
        var plan = FullHashBackfillPlan()
        var byRoot: [String: FullHashBackfillLane] = [:]
        for r in records where isActive(r) {
            switch CheckCopiesPlanner.need(r, isReadOnly: isReadOnly) {
            case .hashed: plan.alreadyHashed += 1
            case .leftAlone: plan.archivedLeftAlone += 1
            case .hash:
                let root = MediaVolumeGatePolicy.volumeRoot(forPath: r.fullPath)
                byRoot[root, default: FullHashBackfillLane(root: root)].items.append(
                    CheckCopiesItem(id: r.id, path: r.fullPath, sizeBytes: r.sizeBytes, priorFixity: r.contentFixity))
            }
        }
        plan.lanes = byRoot.values
            .map { lane in
                var sorted = lane
                sorted.items.sort { $0.path < $1.path }
                return sorted
            }
            .sorted { $0.root < $1.root }
        return plan
    }

    /// Not removed, not superseded, and pointing at a file.
    static func isActive(_ r: VideoRecord) -> Bool {
        !r.isPurged && !r.isSuperseded && !r.fullPath.isEmpty
    }

    /// "Archive1" for "/Volumes/Archive1"; "this Mac" for "/". Pure — no
    /// disk access (the friendly-name lookup can stat a sleeping drive).
    nonisolated static func label(forRoot root: String) -> String {
        root == "/" ? "this Mac" : (root as NSString).lastPathComponent
    }
}

// MARK: - Results (values)

/// What happened to one file — the detail list's row and the tally's key.
enum FullHashBackfillResult: String, Sendable, Equatable, CaseIterable {
    case hashed
    case driveNotConnected
    case missing
    case unreadable
    case changedDuringRead
    case noVolumeIdentity
    case recordChanged

    /// Plain words for the detail row and the summary line.
    var words: String {
        switch self {
        case .hashed: return "hashed in full"
        case .driveNotConnected: return "drive not connected"
        case .missing: return "missing at its path"
        case .unreadable: return "unreadable"
        case .changedDuringRead: return "changed while it was read"
        case .noVolumeIdentity: return "on a drive with no volume id"
        case .recordChanged: return "changed in the catalog meanwhile"
        }
    }
}

struct FullHashBackfillItem: Identifiable, Sendable, Equatable {
    let id: Int
    let filename: String
    let path: String
    let drive: String
    let result: FullHashBackfillResult
    let detail: String
}

/// One drive's row in the detail.
struct FullHashBackfillLaneStatus: Identifiable, Sendable, Equatable {
    enum Phase: String, Sendable { case waiting, reading, finished, disconnected, stopped }
    var id: String { root }
    let root: String
    let label: String
    let planned: Int
    var done = 0
    var phase: Phase = .waiting
}

struct FullHashBackfillTotals: Sendable, Equatable {
    var planned = 0
    var plannedBytes: Int64 = 0
    var alreadyHashed = 0
    var archivedLeftAlone = 0
    /// Files resolved, whatever the outcome (the "N" of "N of M").
    var done = 0
    var doneBytes: Int64 = 0
    /// Bytes actually read end to end (the rate's numerator).
    var readBytes: Int64 = 0
    var hashedBytes: Int64 = 0
    var counts: [FullHashBackfillResult: Int] = [:]

    subscript(_ r: FullHashBackfillResult) -> Int { counts[r] ?? 0 }

    mutating func add(_ r: FullHashBackfillResult, files n: Int = 1, bytes: Int64) {
        counts[r, default: 0] += n
        done += n
        doneBytes += bytes
    }

    /// "1,204 of 3,310 hashed in full (412 GB) · 96,000 already had one · 2 unreadable"
    var line: String {
        var parts = ["\(self[.hashed].formatted()) of \(planned.formatted()) hashed in full (\(MediaBytes.display(hashedBytes)))",
                     "\(alreadyHashed.formatted()) already had one"]
        if archivedLeftAlone > 0 { parts.append("\(archivedLeftAlone.formatted()) archived, left alone") }
        for r in FullHashBackfillResult.allCases where r != .hashed && self[r] > 0 {
            parts.append("\(self[r].formatted()) \(r.words)")
        }
        return parts.joined(separator: " · ")
    }

    /// "1,204 of 3,310 · 2 drives · clip.mov +1 · 410 MB/s · ~3 h 10 min left".
    /// `inFlight` = bytes read so far in the files being read now.
    func progressLine(reading: [String], lanesActive: Int, inFlight: Int64, elapsed: TimeInterval) -> String {
        var parts = ["\(done.formatted()) of \(planned.formatted())"]
        if lanesActive > 0 { parts.append("\(lanesActive) drive\(lanesActive == 1 ? "" : "s") reading") }
        if let first = reading.first { parts.append(reading.count > 1 ? "\(first) +\(reading.count - 1)" : first) }
        let read = readBytes + inFlight
        guard elapsed > 5, read > 0 else { return parts.joined(separator: " · ") }
        let rate = Double(read) / elapsed
        parts.append("\(MediaBytes.display(Int64(rate)))/s")
        let left = Double(max(0, plannedBytes - doneBytes - inFlight)) / rate
        parts.append(Self.timeLeft(left))
        return parts.joined(separator: " · ")
    }

    nonisolated static func timeLeft(_ secs: TimeInterval) -> String {
        if secs < 60 { return "~\(max(1, Int(secs.rounded()))) s left" }
        if secs < 3600 { return "~\(Int((secs / 60).rounded())) min left" }
        return "~\(Int(secs / 3600)) h \(Int(secs.truncatingRemainder(dividingBy: 3600) / 60)) min left"
    }
}

extension FullHashBackfillResult {
    /// The tally key for a read's outcome. nil for `.bound` (the store
    /// decides hashed vs recordChanged) and `.interrupted` (retried).
    /// `.offline` here means the drive is still there (the lane checked),
    /// so the file itself is missing.
    init?(failure outcome: FixityRebind.Outcome) {
        switch outcome {
        case .bound, .interrupted: return nil
        case .offline: self = .missing
        case .unreadable: self = .unreadable
        case .changedDuringRead: self = .changedDuringRead
        case .noVolumeIdentity: self = .noVolumeIdentity
        }
    }

    /// Why, in words, for the detail row.
    static func detail(for outcome: FixityRebind.Outcome) -> String {
        switch outcome {
        case .unreadable(let why), .changedDuringRead(let why): return why
        case .offline: return "not at its path (the drive is connected) — skipped"
        case .noVolumeIdentity: return "the drive reports no volume id, so the hash cannot be bound to it"
        case .bound, .interrupted: return ""
        }
    }
}
