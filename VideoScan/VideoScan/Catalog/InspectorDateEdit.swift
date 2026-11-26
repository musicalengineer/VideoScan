// InspectorDateEdit.swift
// The Inspector's "When was this?" field writes Rick's date through here —
// the one place the Inspector touches `userDate` / `userDateConfidence`, so
// the rule is testable without a view host.
//
// GH #221 (rule 3, "Archived means fixed"): a record the date seam calls
// read-only (`VideoScanModel.isDateReadOnly` — Archived stage, or a Master
// Archive file) is NOT written here. Its date is the one the archive filed it
// under (folder, filename, manifest row); only Update… changes it, and Update…
// moves all four together. The Inspector shows the filed date and offers
// Update… instead of the field (InspectorDateView).
//
// Codex #383 (round 2): the date is stored per CONTENT, so a record whose
// content has a live archived copy is fixed too — `archivedCopy(fixing:)`
// finds that copy; the Inspector refuses for every copy of the digest and
// its Update… opens the archived one.
//
// (For Rick: a namespace of free functions — `namespace InspectorDateEdit {
// Outcome save(...); }` — the caller passes the seam's verdict in, as the
// static helpers in VideoScanModel+DateReadOnly do.)

import Foundation
import VideoScanCore

@MainActor
enum InspectorDateEdit {

    enum Outcome: Equatable {
        /// Written: the canonical date now on the record.
        case saved(String)
        /// The date and its confidence were removed.
        case cleared
        /// The typed text is not a date ("Hmm, couldn't read that").
        case unreadable
        /// The record is archived: nothing was written (Update… only).
        case refusedArchived
        /// Nothing to do (an empty entry on a record with no date).
        case unchanged
    }

    /// Save the typed entry (empty = clear) at the chosen confidence.
    /// `readOnly` is `model.isDateReadOnly(record)`, judged by the caller.
    /// An archived record is refused before the text is even parsed.
    static func save(entry: String, known: Bool, to record: VideoRecord, readOnly: Bool) -> Outcome {
        guard !readOnly else { return .refusedArchived }
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return record.userDate == nil ? .unchanged : clear(record, readOnly: readOnly)
        }
        guard let canonical = UserDateEntry.canonicalize(trimmed) else { return .unreadable }
        record.userDate = canonical
        record.userDateConfidence = (known ? UserDateConfidence.known : UserDateConfidence.estimated).rawValue
        return .saved(canonical)
    }

    /// The archived record whose filed date fixes `record`'s date: `record`
    /// itself when the seam calls it read-only, else a LIVE copy of the same
    /// content (same whole-file digest, no removal marker) the seam calls
    /// read-only, else nil (the date is editable).
    ///
    /// Why a twin counts (Codex #383, rule 3): catalog.sqlite keeps Rick's
    /// date per CONTENT — `user_dates` is keyed by digest and the loader
    /// joins it by digest — so a date saved on any copy IS the archived
    /// copy's date after the next launch, while the archive's folder,
    /// filename and manifest row stay where Update… left them.
    ///
    /// O(records) with a size pre-filter (an Int compare per row; the digest
    /// is read only for rows of the same size). The Inspector memoizes it per
    /// (selection, records version); a save re-asks it fresh. No allocation
    /// beyond the one digest string of `record`.
    /// (For Rick: `std::find_if` over the vector with a cheap first clause.)
    static func archivedCopy(fixing record: VideoRecord, in records: [VideoRecord],
                             isReadOnly: (VideoRecord) -> Bool) -> VideoRecord? {
        if isReadOnly(record) { return record }
        guard let digest = CatalogCommit.digest(of: record) else { return nil }
        let size = record.sizeBytes
        return records.first { other in
            other.sizeBytes == size && other !== record && other.removal == nil
                && isReadOnly(other) && CatalogCommit.digest(of: other) == digest
        }
    }

    /// Forget the date (the file goes back to needing one).
    static func clear(_ record: VideoRecord, readOnly: Bool) -> Outcome {
        guard !readOnly else { return .refusedArchived }
        record.userDate = nil
        record.userDateConfidence = nil   // meaningless without a date
        return .cleared
    }
}
