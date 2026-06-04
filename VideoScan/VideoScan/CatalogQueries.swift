import Foundation

// MARK: - Universal search (issue #66, pattern 2)
//
// Multi-token AND search across every catalog field a user might think
// of: filename, path, year, detectedPeople, avidClipName, codec,
// lifecycleStage. Pure functions so the same logic can drive a search
// bar in any tab plus power scripted queries.

/// A single search token. Most are plain substrings, but year ranges
/// like "1990s" / "199x" are first-class so the user can type them
/// naturally.
enum SearchToken: Equatable {
    case substring(String)              // case-insensitive contains
    case yearRange(ClosedRange<Int>)    // e.g. 1990...1999 for "1990s"
}

/// Split a search query into tokens. Whitespace separates tokens; each
/// token is recognised as a year shorthand if it matches `YYYYs` or
/// `YYYx`, otherwise treated as a substring.
///
///     "donna 1990s holiday"
///       → [.substring("donna"), .yearRange(1990...1999), .substring("holiday")]
nonisolated func pfTokenizeSearchQuery(_ query: String) -> [SearchToken] {
    let parts = query.split(whereSeparator: \.isWhitespace).map(String.init)
    return parts.compactMap { part in
        let trimmed = part.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        // Year decade shorthand: "1990s", "1990S"
        if trimmed.count == 5,
           let prefix = Int(trimmed.dropLast()),
           trimmed.last?.lowercased() == "s",
           prefix >= 1900, prefix <= 2099,
           prefix % 10 == 0 {
            return .yearRange(prefix...(prefix + 9))
        }
        // Year wildcard: "199x", "200x"
        if trimmed.count == 4,
           trimmed.last?.lowercased() == "x",
           let prefix = Int(trimmed.dropLast()),
           prefix >= 190, prefix <= 209 {
            let base = prefix * 10
            return .yearRange(base...(base + 9))
        }
        return .substring(trimmed)
    }
}

/// Extract any 4-digit years (1900–2099) found in a catalog record's
/// path or filename. Used by universal search for year-token matching.
nonisolated func pfYearsFromRecord(_ rec: VideoRecord) -> Set<Int> {
    var years = Set<Int>()
    let haystack = rec.fullPath + " " + rec.directory + " " + rec.filename
    var index = haystack.startIndex
    while index < haystack.endIndex {
        // Find a run of 4 digits.
        if haystack[index].isNumber,
           let end = haystack.index(index, offsetBy: 4, limitedBy: haystack.endIndex) {
            let chunk = haystack[index..<end]
            if chunk.allSatisfy(\.isNumber), let y = Int(chunk),
               y >= 1900, y <= 2099 {
                // Reject if it's part of a longer digit run (e.g. "19999").
                let nextIsDigit = end < haystack.endIndex && haystack[end].isNumber
                let prevIdx = index > haystack.startIndex
                    ? haystack.index(before: index) : haystack.startIndex
                let prevIsDigit = index > haystack.startIndex && haystack[prevIdx].isNumber
                if !nextIsDigit && !prevIsDigit {
                    years.insert(y)
                }
            }
        }
        index = haystack.index(after: index)
    }
    // Also use dateModifiedRaw / dateCreatedRaw years if available.
    let cal = Calendar(identifier: .gregorian)
    if let d = rec.dateModifiedRaw {
        years.insert(cal.component(.year, from: d))
    }
    if let d = rec.dateCreatedRaw {
        years.insert(cal.component(.year, from: d))
    }
    return years
}

/// Return true if `token` matches any field on `record`.
nonisolated func pfTokenMatches(_ token: SearchToken, _ rec: VideoRecord) -> Bool {
    switch token {
    case .substring(let needle):
        let n = needle.lowercased()
        if rec.filename.lowercased().contains(n) { return true }
        if rec.fullPath.lowercased().contains(n) { return true }
        if rec.directory.lowercased().contains(n) { return true }
        if rec.detectedPeople.contains(where: { $0.lowercased().contains(n) }) { return true }
        if rec.suspectedPeople.contains(where: { $0.lowercased().contains(n) }) { return true }
        // Scene captions search (v1 — linear substring across caption text).
        // Composes with the people-tag matches above so "donna playing guitar"
        // matches via Donna (detectedPeople) + "playing guitar" (sceneCaptions).
        // For v2 at >10k records, see docs/scene_captions_plan.md FTS5 plan.
        if rec.sceneCaptions.contains(where: { $0.text.lowercased().contains(n) }) { return true }
        // Audio transcript search (Phase 1 — linear substring across the
        // single transcript text blob). Same case-insensitive comparison
        // and same hit semantics as sceneCaptions: a token matches if any
        // text source contains it — caller doesn't distinguish "matched
        // via caption" from "matched via transcript". For thousands of
        // orphaned audio-only MXFs this turns Whisper output into a
        // first-class search dimension.
        if let t = rec.audioTranscript, t.lowercased().contains(n) { return true }
        if rec.avidClipName.lowercased().contains(n) { return true }
        if rec.videoCodec.lowercased().contains(n) { return true }
        if rec.audioCodec.lowercased().contains(n) { return true }
        if rec.lifecycleStage.rawValue.lowercased().contains(n) { return true }
        if rec.archiveStage.rawValue.lowercased().contains(n) { return true }
        if rec.notes.lowercased().contains(n) { return true }
        return false
    case .yearRange(let range):
        return pfYearsFromRecord(rec).contains(where: { range.contains($0) })
    }
}

/// Universal-search entry point. All tokens must match (AND semantics);
/// empty query → matches everything.
nonisolated func pfRecordMatchesQuery(_ rec: VideoRecord, query: String) -> Bool {
    let tokens = pfTokenizeSearchQuery(query)
    if tokens.isEmpty { return true }
    return tokens.allSatisfy { pfTokenMatches($0, rec) }
}

/// Convenience: filter a record list against a query string.
nonisolated func pfRecordsMatchingQuery(_ records: [VideoRecord], query: String) -> [VideoRecord] {
    let tokens = pfTokenizeSearchQuery(query)
    if tokens.isEmpty { return records }
    return records.filter { rec in tokens.allSatisfy { pfTokenMatches($0, rec) } }
}

// MARK: - Catalog search (filename + person tags)
//
// Powers the Catalog tab's search bar. Matches filenames (Finder-style
// behavior the user expects) AND person tags on the record. Path,
// directory, codec, notes, etc. are intentionally NOT searched here
// — those live in the universal search (pfRecordMatchesQuery) which
// is too broad for the always-on catalog search bar. Typing "matt"
// should find files named *matt* and files tagged with Matt, not
// every file in a "Matthew" directory.

/// Case-insensitive substring match against filename + detectedPeople
/// + suspectedPeople. Returns true on empty query so callers don't
/// need their own short-circuit.
nonisolated func pfRecordFilenameOrPersonMatch(_ rec: VideoRecord, query: String) -> Bool {
    if query.isEmpty { return true }
    let q = query.lowercased()
    if rec.filename.lowercased().contains(q) { return true }
    if rec.detectedPeople.contains(where: { $0.lowercased().contains(q) }) { return true }
    if rec.suspectedPeople.contains(where: { $0.lowercased().contains(q) }) { return true }
    // User-confirmed names match the same as algorithm-detected names
    // for catalog search — both are valid "this video has X" tags.
    // rejectedPeople is intentionally NOT searched here: a record where
    // Rick said "not Anna" should never surface for "anna" queries,
    // which is the whole point of that field.
    if rec.confirmedByUserPeople.contains(where: { $0.name.lowercased().contains(q) }) { return true }
    // Semantic content tags — captions and audio transcripts describe
    // what's IN the video, so they belong with people tags as
    // "content-style" fields. Distinct from path/directory above which
    // describe where the file lives and are intentionally excluded.
    if rec.sceneCaptions.contains(where: { $0.text.lowercased().contains(q) }) { return true }
    if let t = rec.audioTranscript, t.lowercased().contains(q) { return true }
    return false
}

// MARK: - Family tagging predicates (Step 5)
//
// Pure helpers powering the catalog's "Has Family" / "Untagged" filters and
// the People column. The catalog table calls these directly so the same
// rules drive screen and tests with no behavioural drift.

/// True if `rec` has at least one detected OR suspected person tag.
/// Drives the "Has Family" catalog filter — fastest way to surface
/// keeper-candidate footage.
nonisolated func pfRecordHasAnyPerson(_ rec: VideoRecord) -> Bool {
    !rec.detectedPeople.isEmpty || !rec.suspectedPeople.isEmpty
}

/// True if `rec` has no person tags at all in either array. Drives the
/// "Untagged (junk candidate)" filter — these are the rows where a
/// family scan found nothing recognisable, so they're the highest-yield
/// triage targets for deletion / archival.
nonisolated func pfRecordIsUntagged(_ rec: VideoRecord) -> Bool {
    rec.detectedPeople.isEmpty && rec.suspectedPeople.isEmpty
}

// MARK: - Triage disposition (issue #66, pattern 3)
//
// junkScore today is just a column. Promote it to a triage assist:
// records below `autoJunkBelow` are auto-junkable IFF a verified backup
// exists; records above `autoKeepAbove` are auto-keep; the band in
// between is what the human actually has to triage. Trims the queue
// to the records where the human call matters.

enum TriageDisposition: String, Equatable {
    /// junkScore high enough to keep automatically.
    case autoKeep
    /// In the borderline band — human review required.
    case queue
    /// Score low enough to auto-junk, AND backup safety gate satisfied.
    case autoJunk
    /// Score low enough to auto-junk but backup gate NOT satisfied —
    /// queue it for the human (don't risk catastrophic loss).
    case junkButNotBackedUp
}

/// "Backup-verified" means: at least two distinct backup destinations,
/// OR archiveStage marked as healthy / backed-up. Conservative on
/// purpose — auto-delete should only fire when we're CONFIDENT.
nonisolated func pfRecordHasVerifiedBackup(_ rec: VideoRecord) -> Bool {
    // Two-locations rule (the "2" in 3-2-1)
    if rec.backupDestinations.count >= 2 { return true }
    // Lifecycle marker
    if rec.archiveStage.rawValue == ArchiveStage.healthy.rawValue { return true }
    return false
}

/// Decide what to do with a single record given the band thresholds.
/// Higher junkScore = MORE junky (less keepable) per the existing
/// scoring convention; thresholds invert that for the human-friendly
/// "auto-keep above N" reading.
///
/// **Convention check:** in this codebase `junkScore` is a "junkiness"
/// number — higher = more likely junk. So:
/// - `junkScore >= autoJunkAbove` → auto-junk candidate
/// - `junkScore <= autoKeepBelow` → auto-keep
/// - between → queue for human
nonisolated func pfTriageDisposition(
    _ rec: VideoRecord,
    autoKeepBelow: Int = 30,
    autoJunkAbove: Int = 70,
    requireBackupForJunk: Bool = true
) -> TriageDisposition {
    let s = rec.junkScore
    if s >= autoJunkAbove {
        if requireBackupForJunk && !pfRecordHasVerifiedBackup(rec) {
            return .junkButNotBackedUp
        }
        return .autoJunk
    }
    if s <= autoKeepBelow {
        return .autoKeep
    }
    return .queue
}

/// Filter a record list down to only the records that need a human
/// triage call. Optionally include "junkButNotBackedUp" so the user
/// can see why those weren't auto-junked.
nonisolated func pfTriageQueueRecords(
    from records: [VideoRecord],
    autoKeepBelow: Int = 30,
    autoJunkAbove: Int = 70,
    includeUnbackedJunk: Bool = true
) -> [VideoRecord] {
    records.filter { rec in
        let d = pfTriageDisposition(rec,
                                    autoKeepBelow: autoKeepBelow,
                                    autoJunkAbove: autoJunkAbove)
        switch d {
        case .queue: return true
        case .junkButNotBackedUp: return includeUnbackedJunk
        case .autoKeep, .autoJunk: return false
        }
    }
}

/// Aggregate counts for a triage dashboard.
struct TriageBandCounts: Equatable {
    var autoKeep: Int = 0
    var queue: Int = 0
    var autoJunk: Int = 0
    var junkButNotBackedUp: Int = 0
    var total: Int { autoKeep + queue + autoJunk + junkButNotBackedUp }
}

nonisolated func pfTriageBandCounts(
    from records: [VideoRecord],
    autoKeepBelow: Int = 30,
    autoJunkAbove: Int = 70
) -> TriageBandCounts {
    var counts = TriageBandCounts()
    for rec in records {
        switch pfTriageDisposition(rec,
                                   autoKeepBelow: autoKeepBelow,
                                   autoJunkAbove: autoJunkAbove) {
        case .autoKeep:           counts.autoKeep += 1
        case .queue:              counts.queue += 1
        case .autoJunk:           counts.autoJunk += 1
        case .junkButNotBackedUp: counts.junkButNotBackedUp += 1
        }
    }
    return counts
}

// MARK: - Soft-delete (purge) filter
//
// Mirrors the POI soft-delete UX: removed records stay in catalog.json (so
// the user can always recover) but are hidden from the default table view.
// The default is "hide purged" — the user opts into seeing them via the
// "Show removed" toolbar toggle. Compose with the existing online / view
// filters in CatalogContent.computeFiltered(): each filter narrows the
// previous result independently.
//
// Pure functions so the same logic drives the table filter, batch ops, and
// the unit tests in CatalogPurgeTests.

/// Return records whose `purgedAt` is nil — the default catalog view.
nonisolated func pfActiveRecords(_ records: [VideoRecord]) -> [VideoRecord] {
    records.filter { !$0.isPurged }
}

/// Return records whose `purgedAt` is non-nil — the "Show removed" view.
nonisolated func pfPurgedRecords(_ records: [VideoRecord]) -> [VideoRecord] {
    records.filter { $0.isPurged }
}

/// Apply the soft-delete filter. When `showRemoved` is false (the default
/// user state) purged rows are hidden; when true, all records pass through
/// and the caller is responsible for any extra purged-row styling.
///
/// This is independent of the online/offline reachability filter so the
/// two compose: e.g. user can see (online + active), (offline + active),
/// (online + purged when showRemoved is on), or (offline + purged when
/// showRemoved is on).
nonisolated func pfApplyPurgeFilter(
    _ records: [VideoRecord],
    showRemoved: Bool
) -> [VideoRecord] {
    if showRemoved { return records }
    return pfActiveRecords(records)
}
