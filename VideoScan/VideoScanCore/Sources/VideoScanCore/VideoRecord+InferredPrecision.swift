// VideoRecord+InferredPrecision.swift
// GH #293 item 2 (2026-10-07): a YEAR-ONLY inferred date must stay a year
// everywhere it is shown, and its WHY must say where the year came from.
//
// The bug: GH #201 (2026-09-26) made `inferredDateRange` the marker of a
// year-only inference, and every reader keyed on it ("range != nil → show
// the year"). Rows written BEFORE GH #201 carry no range — yet some of them
// only ever knew the year, stored as a Jan 1 noon-UTC point:
//   • the bare-year folder prior ("folder-year", confidence 0.30), and
//   • the old dossier's path-year tiers (0.50, 0.55 — the band
//     `pfInferredDatePrecision(confidence:)` already treats as a year).
// Master Archive files are frozen to the date passes (Rick 2026-09-27), so
// such a row is never re-derived — and it showed as "1995-01-01" with the
// tooltip "figured out from the video". The real case: an edit copy of a
// 1992 tape, transcoded straight into the archive's 1995 folder, whose
// folder prior then read "1995" back off the folder it had been put in.
//
// The rule (pure, O(1), no allocation beyond a small span):
//   a row's inferred date is YEAR-ONLY when it has a span, OR its source is
//   "folder-year", OR it is a LEGACY row (no written reason) whose
//   confidence sits in the old year-only band 0.50…0.60.
// A row WITH a written reason was decided by the GH #201 triangulator,
// whose span (or its absence) is authoritative — a burn-in "JAN 1 2004"
// with a reason stays a day.
//
// Nothing here writes to the record: the archived rows stay exactly as
// stored (archived = read-only); readers ask these properties instead of
// `inferredDateRange` directly.
//
// (For Rick: computed properties in an `extension` ≈ const member functions
// added to the class from another translation unit.)

import Foundation

extension VideoRecord {

    /// `inferredDateSource` written by the bare-year folder prior (rule 3).
    /// The app's `VideoScanModel.InferredDateSource.folderYear` is the same
    /// string; it lives here too so Core readers need no app import.
    public static let folderYearInferredDateSource = "folder-year"

    /// The pre-GH #201 confidence band that only ever knew the YEAR (the
    /// dossier's path-year tier 0.50 and its corroborated 0.55 / 0.60).
    /// Same band as the app's `pfInferredDatePrecision(confidence:)`.
    public static let legacyYearOnlyConfidence: ClosedRange<Float> = 0.50...0.60

    /// True when the inferred date only knows its YEAR (see file header).
    /// false when there is no inferred date.
    public var inferredDateIsYearOnly: Bool {
        guard inferredRecordDate != nil else { return false }
        if inferredDateRange != nil { return true }
        if inferredDateSource == Self.folderYearInferredDateSource { return true }
        guard inferredDateReason?.isEmpty ?? true, let c = inferredDateConfidence else { return false }
        return Self.legacyYearOnlyConfidence.contains(c)
    }

    /// The span a year-only inference is SHOWN under: the stored span, else
    /// the single year of a legacy year-only row. nil for a day-precise
    /// inference (or none). Display-only — never written back.
    public var effectiveInferredDateRange: InferredDateRange? {
        if let stored = inferredDateRange { return stored }
        guard inferredDateIsYearOnly, let d = inferredRecordDate else { return nil }
        return InferredDateRange(year: Self.inferredPrecisionUTC.component(.year, from: d))
    }

    /// The WHY behind the inferred date: the written reason, else — for a
    /// legacy row whose provenance is known — a reconstructed one, so a
    /// folder name is never passed off as "what the video shows". nil when
    /// nothing honest can be said.
    public var inferredDateReasonShown: String? {
        if let reason = inferredDateReason, !reason.isEmpty { return reason }
        guard inferredRecordDate != nil else { return nil }
        if inferredDateSource == Self.folderYearInferredDateSource,
           let year = effectiveInferredDateRange?.startYear {
            return "the folder it sits in is named '\(year)' — that is where the file was put, "
                + "not evidence of when it was filmed; a placeholder any real evidence replaces"
        }
        return nil
    }

    static let inferredPrecisionUTC: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        return cal
    }()
}
