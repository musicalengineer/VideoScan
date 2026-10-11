// VideoScanModel+DateReadOnly.swift
// THE one seam for "may anything but Update… change this record's date?"
//
// RULING (Rick 2026-10-11): a record at the Archived stage is read-only for
// dates in EVERY writer, whether or not its file sits inside the archive
// root. The rule follows the STAGE, not the folder. Standing rule since
// 2026-09-27: archived = read-only; only the explicit Update… {name, date}
// flow (VideoScanModel+ArchiveUpdate) changes an archived record's date.
//
// What counts as "a date" here: the user date pair (userDate +
// userDateConfidence) and the five inferred fields (inferredRecordDate,
// inferredDateConfidence, inferredDateRange, inferredDateReason,
// inferredDateSource). `embeddedCreationDate` is NOT — it is a probe fact
// about the bytes (like the codec), identical on every copy and unchanged
// by archiving.
//
// Every writer consults `isDateReadOnly(_:)` — directly, or (for the pure
// static helpers that have no model) through a predicate its model-side
// caller hands in. No writer re-derives the rule. The list of writers and
// the reason each is allowed is pinned by ArchivedDateReadOnlySensorTests,
// so a NEW writer fails CI until it is routed here or justified.
//
// Exempt by design (they ARE the filing / Rick's hand, not a background
// writer): Promote registering the archive copy it just made
// (PromoteToArchiveJob+Steps, registerPromotedCopy), the Update… flow,
// the Inspector's "When was this?" field, rescan preservation (it restores
// the record's OWN preserved values), and the Archive Angel's restore of a
// stamp it wrote itself on a promote that did not land.
//
// (For Rick: this is a const member predicate — `bool isDateReadOnly(const
// VideoRecord&) const` — and the static helpers take it as a
// `std::function<bool(const VideoRecord&)>` from the caller.)

import Foundation
import VideoScanCore

extension VideoScanModel {

    /// True when no writer other than Update… may change `record`'s dates:
    /// its lifecycle stage is Archived (Rick 2026-10-11 — the stage rule),
    /// or it IS a Master Archive file (`isArchiveElement`: a promoted copy
    /// or anything under the archive root — Rick 2026-09-27, kept so a file
    /// inside the archive that was never stamped Archived stays protected).
    /// Reading the record is always allowed; it may still DONATE its date.
    /// O(1): an enum compare, a string compare and a prefix test.
    func isDateReadOnly(_ record: VideoRecord) -> Bool {
        record.lifecycleStage == .archived || isArchiveElement(record)
    }

    /// Rick's hand-entered date (+ its confidence) rides from `source` to
    /// `target` when the target has none of its own — the one carry rule
    /// for the repair confirm, the duplicate-delete keeper fold, the
    /// Archived-what-next prune fold and Link Repaired Copy. When
    /// `targetDateReadOnly` (the seam, judged by the caller BEFORE it
    /// changed anything on the target — a repair that takes its original's
    /// Archived stage in the same fold still takes its date) nothing is
    /// written and one audit line says what was declined. Returns true when
    /// the date was written.
    @discardableResult
    func carryHandEnteredDate(from source: VideoRecord, to target: VideoRecord,
                              targetDateReadOnly: Bool, writer: String) -> Bool {
        guard target.userDate == nil, let date = source.userDate else { return false }
        if targetDateReadOnly {
            noteDateLeftAsFiled(target, writer: writer, declined: "\(date) from \(source.filename)")
            return false
        }
        target.userDate = date
        target.userDateConfidence = source.userDateConfidence
        return true
    }

    /// One audit line when a writer would have put a HAND-ENTERED date on a
    /// read-only record and did not (the value is not lost silently: it is
    /// in the log, and still on the record it came from). Machine dates
    /// (the inferred-date lanes) are skipped without a line — they are
    /// re-derived on every pass and a line per row would drown the log.
    func noteDateLeftAsFiled(_ record: VideoRecord, writer: String, declined value: String) {
        log("\(writer): \(record.filename) is archived — date left as filed "
            + "(\(record.userDate ?? "none")); \(value) not written. Use Update… to change an archived file's date.")
    }
}
