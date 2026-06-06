import Foundation

// MARK: - Date validation helpers
//
// Tiny pure helpers that classify whether a Date is plausibly a real
// recording timestamp. Used by:
//
//   - The probe-time ingestion path (VideoScanModel+ProbeEngine) to
//     reject obviously-bogus filesystem creation dates before they
//     land in `dateCreatedRaw`.
//   - The catalog cleanup tool (`scripts/dedup_bogus_dates.py`) to
//     identify the same condition in already-persisted records.
//
// The motivation is the 2026-06-06 case Rick spotted: every MTS file
// in his Thanksgiving 2009 folder had a *duplicate* record carrying
// `dateCreatedRaw = 2040-02-06T06:28:16Z`. The dossier-side date
// triangulation (pfInferRecordDate) already ignored those bogus
// dates and fell back to mtime correctly — but the catalog table
// displayed the wrong year. These predicates let us hide them.

/// The earliest year we'll accept as a real recording date. Anything
/// before 1900 is almost certainly a clock-reset / epoch underflow.
/// Rick's archive does include some 1940s and 1960s reference footage,
/// so we keep the floor loose.
private let pfMinimumPlausibleYear = 1900

/// The exact bogus timestamp every duplicate row in Rick's catalog
/// shares: `2040-02-06T06:28:16Z`. Came from a prior scan run on a
/// MacPro with a dead PRAM battery (default-future-date situation).
/// All duplicates carry this stamp byte-for-byte, which makes the
/// dedup pass trivially safe.
private let pfBogus2040Sentinel: Date = {
    var dc = DateComponents()
    dc.year = 2040; dc.month = 2; dc.day = 6
    dc.hour = 6; dc.minute = 28; dc.second = 16
    dc.timeZone = TimeZone(identifier: "UTC")
    return Calendar(identifier: .gregorian).date(from: dc)!
}()

/// True if `date` is impossible to be a real recording timestamp —
/// either in the future or before 1900. `nil` is plausible (no
/// signal), so it returns false.
///
/// The "future" check is `date > now`, not `date > now + tolerance`,
/// because real recording timestamps are always in the past. We
/// can't capture footage from tomorrow.
nonisolated func pfIsImpossibleDate(_ date: Date?, now: Date = Date()) -> Bool {
    guard let date else { return false }
    if date > now { return true }
    // Use UTC for the year extraction so the boundary is stable across
    // timezones — otherwise an "1900-01-01 UTC" date gets interpreted
    // as 1899-12-31 in a UTC-negative timezone and falsely rejected.
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let year = cal.component(.year, from: date)
    return year < pfMinimumPlausibleYear
}

/// True if `date` matches the known 2040-02-06 06:28:16 UTC sentinel
/// to-the-second. The exact-match condition is important: legitimate
/// 2040 dates (when 2040 eventually arrives) won't all collide on
/// this one specific second.
nonisolated func pfIs2040Sentinel(_ date: Date?) -> Bool {
    guard let date else { return false }
    return abs(date.timeIntervalSince(pfBogus2040Sentinel)) < 1.0
}

/// Convenience: return `date` if it's a plausible recording timestamp,
/// or nil if it's impossible. Used at the ingestion seam so the bogus
/// value never gets persisted.
///
///   r.dateCreatedRaw = pfDateOrNilIfImpossible(attrs?[.creationDate] as? Date)
nonisolated func pfDateOrNilIfImpossible(_ date: Date?, now: Date = Date()) -> Date? {
    if pfIsImpossibleDate(date, now: now) { return nil }
    if pfIs2040Sentinel(date) { return nil }
    return date
}
