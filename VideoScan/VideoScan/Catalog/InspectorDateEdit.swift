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

    /// Forget the date (the file goes back to needing one).
    static func clear(_ record: VideoRecord, readOnly: Bool) -> Outcome {
        guard !readOnly else { return .refusedArchived }
        record.userDate = nil
        record.userDateConfidence = nil   // meaningless without a date
        return .cleared
    }
}
