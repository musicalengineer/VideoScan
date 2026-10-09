// DeleteDuplicatesOutcome.swift
// R6/R7 (design triage_delete_streamline_2026_10_09 §9 R6/R7, codex F6/F7):
// ONE outcome per requested copy, and the counts add up.
//
//   requested == moved + held + failed + recoveryNeeded + missing
//                + offline + cancelled (+ deletedOutright, history only)
//
// Each copy of a plan is in exactly one bucket — by construction, because
// the outcome is a function of the row (`Entry.outcome`). Nothing is
// truncated: the report lists every row with its reason (a view may show
// it lazily). Bytes are "moved to the Trash" — never "freed": the space
// comes back when Rick empties the Trash.
//
// (For Rick: an `enum … : String, Codable` ≈ a C++ enum class that also
// reads and writes itself as its name in JSON.)

import Foundation

/// What became of ONE requested copy — exactly one of these.
enum DeleteDuplicatesOutcomeKind: String, Codable, Sendable, CaseIterable {
    /// In its drive's Trash, proven identical to its keeper first.
    case moved
    /// Left where it is, untouched, for the reason on the row (a
    /// protection, a changed fact, a keeper that failed its proof, a Trash
    /// the drive refused, not pre-selected).
    case held
    /// The attempt failed; the file is where it was — the reason says.
    case failed
    /// Still in its quarantine folder: a Put Back is owed, and the plan
    /// stays offered until it is done.
    case recoveryNeeded
    /// Not there: gone from the catalog at that path, or from the disk.
    case missing
    /// Its drive is not connected.
    case offline
    /// Not reached: the run was stopped (or suspended) first.
    case cancelled
    /// HISTORY ONLY: deleted outright by a build before 2026-10-09.
    case deletedOutright

    /// "moved to the Trash", "held back", … — the result banner's words.
    var words: String {
        switch self {
        case .moved: return "moved to the Trash"
        case .held: return "held back"
        case .failed: return "failed"
        case .recoveryNeeded: return "waiting to be put back"
        case .missing: return "missing"
        case .offline: return "drive not connected"
        case .cancelled: return "not reached"
        case .deletedOutright: return "deleted outright (an older run)"
        }
    }
}

extension DeleteDuplicatesPlan.Entry {
    /// This row's outcome. A row still in quarantine owes a put-back,
    /// whatever its status says; a row never settled was not reached.
    var outcome: DeleteDuplicatesOutcomeKind {
        if needsRecovery { return .recoveryNeeded }
        if status.isSettled, let outcomeKind { return outcomeKind }
        switch status {
        case .pending, .verifying, .verified: return .cancelled
        case .trashed: return .moved
        case .deleted: return .deletedOutright
        case .refused, .skipped: return .held
        case .failed: return .failed
        }
    }
}

/// Every requested copy of one or more plans, with its outcome and reason.
struct DeleteDuplicatesOutcomeReport: Equatable, Sendable {
    struct Row: Identifiable, Equatable, Sendable {
        let id: UUID
        let filename: String
        let path: String
        let sizeBytes: Int64
        let kind: DeleteDuplicatesOutcomeKind
        /// Why — never empty for anything but `.moved`.
        let reason: String
        /// For `.moved`: the drive whose Trash holds it ("Open Trash", R8).
        let trashVolume: String?
    }

    static let notReachedReason = "not reached — the run was stopped first"

    /// One per requested copy, in plan order. Never truncated.
    private(set) var rows: [Row] = []
    private var counts: [DeleteDuplicatesOutcomeKind: (n: Int, bytes: Int64)] = [:]

    init(plans: [DeleteDuplicatesPlan]) {
        for plan in plans {
            for e in plan.entries {
                let kind = e.outcome
                let reason = kind == .cancelled && e.note.isEmpty ? Self.notReachedReason : e.note
                rows.append(Row(id: e.id, filename: e.filename, path: e.path, sizeBytes: e.sizeBytes, kind: kind,
                                reason: reason, trashVolume: kind == .moved ? e.trashedOnVolume : nil))
                let c = counts[kind] ?? (0, 0)
                counts[kind] = (c.n + 1, c.bytes + e.sizeBytes)
            }
        }
    }

    static func == (a: Self, b: Self) -> Bool { a.rows == b.rows }

    var requested: Int { rows.count }
    func count(_ kind: DeleteDuplicatesOutcomeKind) -> Int { counts[kind]?.n ?? 0 }
    func bytes(_ kind: DeleteDuplicatesOutcomeKind) -> Int64 { counts[kind]?.bytes ?? 0 }
    /// The sum of the moved copies' own sizes (R7: never scaled).
    var bytesMovedToTrash: Int64 { bytes(.moved) }
    /// Every row of a kind (the held list, the missing list, …).
    func rows(_ kind: DeleteDuplicatesOutcomeKind) -> [Row] { rows.filter { $0.kind == kind } }

    /// "Moved 212 (48 GB) to the Trash · 3 held back · 1 missing" — the
    /// counts that are not zero, in a fixed order.
    var line: String {
        let size = { (b: Int64) in ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
        var parts = ["Moved \(count(.moved)) (\(size(bytesMovedToTrash))) to the Trash"]
        for kind in DeleteDuplicatesOutcomeKind.allCases where kind != .moved && count(kind) > 0 {
            parts.append("\(count(kind)) \(kind.words)")
        }
        return parts.joined(separator: " · ")
    }
}

extension DeleteDuplicatesPlan {
    /// One outcome per row (R6/R7). O(entries); never from a view body.
    var outcomeReport: DeleteDuplicatesOutcomeReport { DeleteDuplicatesOutcomeReport(plans: [self]) }
}

extension VideoScanModel {
    /// R6: a row the catalog no longer authorises is MISSING when its record
    /// is gone or now points somewhere else; any other reason to skip it (a
    /// hold, a re-decision) is a HOLD.
    func skipOutcome(for entry: DeleteDuplicatesPlan.Entry) -> DeleteDuplicatesOutcomeKind {
        guard let r = record(forID: entry.id), !r.isPurged, r.fullPath == entry.path else { return .missing }
        return .held
    }
}

extension DeleteDuplicatesBatchRun {
    /// Every requested copy of the batch: the started volumes' rows as they
    /// settled, and the rows of volumes whose turn never came (not reached).
    var outcomeReport: DeleteDuplicatesOutcomeReport {
        DeleteDuplicatesOutcomeReport(plans: jobs.compactMap(\.plan) + notStarted)
    }
}
