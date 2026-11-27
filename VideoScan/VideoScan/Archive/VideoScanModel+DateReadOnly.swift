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
// rescan preservation (it restores the record's OWN preserved values), and
// the Archive Angel's restore of a stamp it wrote itself on a promote that
// did not land. The Inspector's "When was this?" field is NOT exempt (GH
// #221, rule 3): it writes through InspectorDateEdit, which refuses a
// read-only record, and an archived row shows its filed date + Update….
//
// GH #528 (rule 3, every copy): the catalog stores ONE date per content
// (`user_dates` / `inferred_dates` keyed by the whole-file digest, joined by
// digest at load), so a date written on an unarchived copy of archived
// content IS the archived copy's date after relaunch. The seam is therefore
// twin-aware: a row is read-only when it is archived ITSELF
// (`isDateReadOnlyItself`) or a LIVE archived copy of its content exists
// (`archivedCopyFixingDate`, O(1) through ArchivedContentIndex). Every
// writer above inherits that without a change. Questions about the archived
// copy itself (which row Update… opens, the committer's "is archived" log
// line, Dossier's per-row flags) ask `isDateReadOnlyItself`. The commit
// refuses a date group on a twin as well (CatalogCommitter, defence in
// depth, one log line).
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
    ///
    /// GH #528: ALSO true for every other live copy of archived content
    /// (same whole-file digest) — the catalog keeps one date per content, so
    /// a twin's date write is the archived copy's date after relaunch.
    /// O(1): the per-row test, then (only when some archived copy has this
    /// row's size) one digest read and a bucket probe.
    func isDateReadOnly(_ record: VideoRecord) -> Bool {
        isDateReadOnlyItself(record) || archivedTwin(of: record) != nil
    }

    /// The per-row half of the seam: THIS row is archived — its lifecycle
    /// stage is Archived (Rick 2026-10-11) or it IS a Master Archive file
    /// (`isArchiveElement`, Rick 2026-09-27). O(1): an enum compare, a
    /// string compare and a prefix test.
    func isDateReadOnlyItself(_ record: VideoRecord) -> Bool {
        Self.isDateReadOnlyItself(record, root: masterArchiveRootPath)
    }

    /// The per-row rule with the archive root captured — THE rule both the
    /// instance seam and `DateReadOnlyRule` apply (stage, promoted copy,
    /// inside the root — `isArchiveElement` with its root read once).
    static func isDateReadOnlyItself(_ record: VideoRecord, root: String?) -> Bool {
        record.lifecycleStage == .archived || isArchiveElement(record, root: root)
    }

    /// The seam hoisted for ONE synchronous pass over many rows (a date
    /// writer's bucketing walk over the whole catalog): the archive root,
    /// the records array and the archived-content index's stamp are read
    /// once here, so each row costs the per-row test plus (only when an
    /// archived copy has the row's size) one digest read and a bucket probe.
    /// Same answers as `isDateReadOnly` — same per-row rule, same index —
    /// for as long as the pass does not await (never store it).
    /// 2026-11-27: per-row `isDateReadOnly` re-read two @Published values,
    /// took the generation lock and re-checked the index stamp for each of
    /// 100k rows (≈ 0.5 µs a row), which made a donor-scoped catch-up pass
    /// ~50 ms slower than before GH #528 (DateReviewF2Tests).
    func dateReadOnlyRule() -> DateReadOnlyRule {
        let root = masterArchiveRootPath
        let itself = { (rec: VideoRecord) in Self.isDateReadOnlyItself(rec, root: root) }
        return DateReadOnlyRule(root: root, twins: archivedContentIndex.frozen(records, root: root, isFixedItself: itself))
    }

    /// The archived row whose filed date fixes `record`'s date: `record`
    /// itself when it is archived, else a live archived copy of the same
    /// content (GH #528 / codex #383), else nil (the date is editable).
    /// What the Inspector shows ("Filed as …") and where its Update… goes.
    func archivedCopyFixingDate(of record: VideoRecord) -> VideoRecord? {
        isDateReadOnlyItself(record) ? record : archivedTwin(of: record)
    }

    /// A LIVE row other than `record`, archived itself, holding `record`'s
    /// whole-file digest (`CatalogCommit.digest(of:)`) — nil without a digest.
    private func archivedTwin(of record: VideoRecord) -> VideoRecord? {
        archivedContentIndex.archivedCopy(sharingContentOf: record, in: records, root: masterArchiveRootPath,
                                          isFixedItself: { self.isDateReadOnlyItself($0) })
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
        // GH #528: a twin is named with the archived copy that fixes it.
        if let archived = archivedCopyFixingDate(of: record), archived !== record {
            log("\(writer): \(record.filename) is a copy of archived \(archived.filename) — date left as filed "
                + "(\(record.userDate ?? "none")); \(value) not written. Use Update… on \(archived.filename) to change it.")
            return
        }
        log("\(writer): \(record.filename) is archived — date left as filed "
            + "(\(record.userDate ?? "none")); \(value) not written. Use Update… to change an archived file's date.")
    }
}

/// `VideoScanModel.dateReadOnlyRule()` — the date seam for one synchronous
/// pass (≈ a C++ functor holding the root and a const view of the index).
@MainActor
struct DateReadOnlyRule {
    let root: String?
    let twins: ArchivedContentIndex.Frozen

    /// `isDateReadOnly(_:)`, with the pass's root and index view.
    func isDateReadOnly(_ record: VideoRecord) -> Bool {
        let root = self.root
        let itself = { (rec: VideoRecord) in VideoScanModel.isDateReadOnlyItself(rec, root: root) }
        return itself(record) || twins.archivedCopy(sharingContentOf: record, isFixedItself: itself) != nil
    }
}
