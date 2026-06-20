import Foundation

// MARK: - Universal search (issue #66, pattern 2)
//
// Multi-token AND search across every catalog field a user might think
// of: filename, path, year, detectedPeople, avidClipName, codec,
// lifecycleStage. Pure functions so the same logic can drive a search
// bar in any tab plus power scripted queries.

/// A single search token. Most are plain substrings, but year ranges
/// like "1990s" / "199x" are first-class so the user can type them
/// naturally. Field-prefix tokens like `people:donna` restrict the
/// match to a specific record field — useful when a name collides
/// with a place ("matt" the person vs "Matthew" the directory).
enum SearchToken: Equatable {
    case substring(String)                          // case-insensitive contains, any field
    case yearRange(ClosedRange<Int>)                // e.g. 1990...1999 for "1990s"
    case field(name: SearchField, value: String)    // e.g. people:donna
}

/// Field-prefix names recognised by the tokenizer. Keep this enum and
/// the per-field match logic in `pfFieldTokenMatches` in lock-step.
enum SearchField: String, Equatable {
    case people       // detected + suspected + confirmed
    case transcript   // audioTranscript
    case caption      // sceneCaptions[].text
    case ocr          // ocrText + ocrDateCandidates
    case filename     // filename only (not path/dir)
    case notes        // user-written notes (only via field prefix; never via plain substring on catalog bar)
    case streamType   // structural filter on rec.streamType (audio/video/both/failed/none)

    static func parse(_ raw: String) -> SearchField? {
        switch raw.lowercased() {
        case "people", "person", "who":     return .people
        case "transcript", "audio", "said": return .transcript
        case "caption", "captions", "scene": return .caption
        case "ocr", "text":                 return .ocr
        case "filename", "name", "file":    return .filename
        case "notes", "note":               return .notes
        case "stream", "streamtype":        return .streamType
        default:                            return nil
        }
    }
}

/// Lex-level result: a raw token plus whether it came from a quoted
/// phrase. Quoted phrases bypass field-prefix recognition downstream so
/// `"filename:cape"` (with quotes) matches the literal string
/// `filename:cape` instead of being parsed as a field token.
private struct PFRawToken {
    let text: String
    let quoted: Bool
}

/// Lex the query into raw tokens. Separators are whitespace, comma, and
/// semicolon (Rick 2026-06-16 — natural-language punctuation as
/// separators so "elevator, cape cod, donna" parses the way users
/// expect). Pipe `|` is RESERVED for future OR semantics and not split
/// on here. Double-quoted phrases are kept as single tokens with the
/// quote marks stripped: `"cape cod"` → one token `cape cod`.
/// Unterminated quotes treat the trailing material as a phrase.
private func pfLexSearchTokens(_ query: String) -> [PFRawToken] {
    var out: [PFRawToken] = []
    var current = ""
    var inQuotes = false
    for ch in query {
        if inQuotes {
            if ch == "\"" {
                if !current.isEmpty { out.append(PFRawToken(text: current, quoted: true)) }
                current = ""
                inQuotes = false
            } else {
                current.append(ch)
            }
        } else if ch == "\"" {
            if !current.isEmpty { out.append(PFRawToken(text: current, quoted: false)) }
            current = ""
            inQuotes = true
        } else if ch.isWhitespace || ch == "," || ch == ";" {
            if !current.isEmpty { out.append(PFRawToken(text: current, quoted: false)) }
            current = ""
        } else {
            current.append(ch)
        }
    }
    if !current.isEmpty {
        // Unterminated quote → trailing material treated as a phrase
        // (matches what the user almost certainly meant — they started
        // a quoted phrase and forgot to close it before submitting).
        out.append(PFRawToken(text: current, quoted: inQuotes))
    }
    return out
}

/// Split a search query into tokens. Whitespace AND `,` `;` separate
/// tokens (Rick 2026-06-16); double-quoted strings stay together as
/// one phrase token. Each token is then recognised in order:
///
///   1. **Quoted phrase** → substring with the literal phrase text
///      (no field-prefix or year-shorthand interpretation).
///   2. **Field-prefix** like `people:donna` / `year:1991` / `year:1989..1995`
///      / `transcript:beach`. The field name comes from `SearchField.parse`.
///   3. **Decade shorthand** `1990s` / `199x` → year range.
///   4. **Plain substring** (default).
///
/// Examples:
///
///     "donna 1990s holiday"
///       → [.substring("donna"), .yearRange(1990...1999), .substring("holiday")]
///     "elevator, cape cod, donna"
///       → [.substring("elevator"), .substring("cape"), .substring("cod"), .substring("donna")]
///     `"cape cod" donna stream:audio`
///       → [.substring("cape cod"), .substring("donna"), .field(.streamType,"audio")]
///     "people:donna year:1991..1995 caption:beach"
///       → [.field(.people,"donna"), .yearRange(1991...1995), .field(.caption,"beach")]
nonisolated func pfTokenizeSearchQuery(_ query: String) -> [SearchToken] {
    return pfLexSearchTokens(query).compactMap { raw in
        let trimmed = raw.text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        // Quoted phrases bypass all special-token recognition — they're
        // the user's explicit signal "match this exact text, including
        // any colons or year-like sequences inside it."
        if raw.quoted {
            return .substring(trimmed)
        }
        // 1. Field-prefix: key:value (year:... handled specially as a range)
        if let colonIdx = trimmed.firstIndex(of: ":") {
            let rawKey = String(trimmed[..<colonIdx])
            let value = String(trimmed[trimmed.index(after: colonIdx)...])
            if value.isEmpty { return .substring(trimmed) }
            // year:1991 → yearRange(1991...1991)
            // year:1989..1995 → yearRange(1989...1995)
            // decade:1990 / decade:1990s → yearRange(1990...1999)
            let lk = rawKey.lowercased()
            if lk == "year" {
                if let range = pfParseYearRangeValue(value) {
                    return .yearRange(range)
                }
                // year:gibberish — fall through to substring of the whole token
                return .substring(trimmed)
            }
            if lk == "decade" {
                if let range = pfParseDecadeValue(value) {
                    return .yearRange(range)
                }
                return .substring(trimmed)
            }
            if let field = SearchField.parse(rawKey) {
                return .field(name: field, value: value)
            }
            // Unknown field prefix — fall back to substring so "URL:foo"
            // still finds files literally containing "URL:foo".
            return .substring(trimmed)
        }
        // 2. Year decade shorthand: "1990s", "1990S"
        if trimmed.count == 5,
           let prefix = Int(trimmed.dropLast()),
           trimmed.last?.lowercased() == "s",
           prefix >= 1900, prefix <= 2099,
           prefix % 10 == 0 {
            return .yearRange(prefix...(prefix + 9))
        }
        // 2b. Year wildcard: "199x", "200x"
        if trimmed.count == 4,
           trimmed.last?.lowercased() == "x",
           let prefix = Int(trimmed.dropLast()),
           prefix >= 190, prefix <= 209 {
            let base = prefix * 10
            return .yearRange(base...(base + 9))
        }
        // 3. Plain substring
        return .substring(trimmed)
    }
}

/// Parse a year range value: "1991" → 1991...1991, "1989..1995" → 1989...1995,
/// "1990s" → 1990...1999. Returns nil if the value isn't a recognised form.
nonisolated func pfParseYearRangeValue(_ value: String) -> ClosedRange<Int>? {
    // Range form: "1989..1995"
    if let dotdot = value.range(of: "..") {
        let lo = Int(value[..<dotdot.lowerBound])
        let hi = Int(value[dotdot.upperBound...])
        if let lo, let hi, (1900...2099).contains(lo), (1900...2099).contains(hi), lo <= hi {
            return lo...hi
        }
        return nil
    }
    // Decade form: "1990s"
    if value.lowercased().hasSuffix("s"),
       let n = Int(value.dropLast()),
       (1900...2099).contains(n), n % 10 == 0 {
        return n...(n + 9)
    }
    // Single year
    if let y = Int(value), (1900...2099).contains(y) {
        return y...y
    }
    return nil
}

/// Parse a decade value: "1990", "1990s", "199" all → 1990...1999.
nonisolated func pfParseDecadeValue(_ value: String) -> ClosedRange<Int>? {
    let trimmed = value.lowercased().hasSuffix("s") ? String(value.dropLast()) : value
    if let n = Int(trimmed) {
        // Accept "1990" or "199" (3-digit shorthand).
        if n >= 1900 && n <= 2099 && n % 10 == 0 {
            return n...(n + 9)
        }
        if n >= 190 && n <= 209 {
            let base = n * 10
            return base...(base + 9)
        }
    }
    return nil
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

/// Match a `.field(name, value)` token against `rec`'s specific field.
/// Substring, case-insensitive. Field-prefix tokens behave the same in
/// both universal and catalog matchers — they're already explicit about
/// what to look at, so there's no narrow-vs-broad ambiguity to resolve.
nonisolated func pfFieldTokenMatches(_ field: SearchField, _ value: String, _ rec: VideoRecord) -> Bool {
    let n = value.lowercased()
    switch field {
    case .people:
        if rec.detectedPeople.contains(where: { $0.lowercased().contains(n) }) { return true }
        if rec.suspectedPeople.contains(where: { $0.lowercased().contains(n) }) { return true }
        if rec.confirmedByUserPeople.contains(where: { $0.name.lowercased().contains(n) }) { return true }
        return false
    case .transcript:
        if let t = rec.audioTranscript, t.lowercased().contains(n) { return true }
        return false
    case .caption:
        return rec.sceneCaptions.contains { $0.text.lowercased().contains(n) }
    case .ocr:
        if rec.ocrText.contains(where: { $0.text.lowercased().contains(n) }) { return true }
        if rec.ocrDateCandidates.contains(where: { $0.text.lowercased().contains(n) }) { return true }
        return false
    case .filename:
        return rec.filename.lowercased().contains(n)
    case .notes:
        return rec.notes.lowercased().contains(n)
    case .streamType:
        return pfStreamTypeAliasMatches(value: n, recordType: rec.streamType)
    }
}

/// Structural filter for `stream:<alias>` tokens. `value` is matched
/// against a hand-picked set of friendly aliases per StreamType case so
/// users can type whatever feels natural. Unknown values return false
/// rather than falling through — typo in `stream:audoi` should produce
/// empty results, not match everything. Rick 2026-06-15.
///
/// Extracted from `pfFieldTokenMatches` to drop its cyclomatic
/// complexity (was 19; this is independently 6). Behavior unchanged.
nonisolated func pfStreamTypeAliasMatches(value: String, recordType: StreamType) -> Bool {
    switch value {
    case "audio", "audioonly":             return recordType == .audioOnly
    case "video", "videoonly":             return recordType == .videoOnly
    case "both", "av", "videoandaudio":    return recordType == .videoAndAudio
    case "failed", "ffprobefailed":        return recordType == .ffprobeFailed
    case "empty", "none", "nostreams":     return recordType == .noStreams
    default:                               return false
    }
}

/// Return true if `token` matches any field on `record`.
nonisolated func pfTokenMatches(_ token: SearchToken, _ rec: VideoRecord) -> Bool {
    switch token {
    case .field(let field, let value):
        return pfFieldTokenMatches(field, value, rec)
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

// MARK: - Catalog search (content-only — filename / people / dossier text)
//
// Powers the Catalog tab's search bar. Matches the "what's in this
// video" fields (filename, people tags, captions, transcript, OCR).
// Path, directory, codec, lifecycle, notes are intentionally NOT
// searched here — those belong to universal search
// (pfRecordMatchesQuery), which is too broad for the always-on
// catalog bar. Typing "matt" should find files named *matt* and
// files tagged with Matt, not every file in a "Matthew" directory.
//
// Token semantics (Rick 2026-06-08): the query string is split on
// whitespace and EVERY token must match somewhere on the record (AND
// semantics across tokens, OR semantics across fields per-token). So
// typing "mark dan grampa" finds family clips whose audio transcript
// mentions all three names — the natural-language semantic search
// surface Rick was after. Year shorthand ("1990s", "199x") is
// year-range matched against any year embedded in filename/path or
// date-modified/created, sharing the universal-search tokenizer.
// Pre-existing universal-search tokens that only make sense over
// path/codec/notes (e.g. a substring matching only a directory name)
// still won't fire here because this match uses the narrower field
// set below.

/// Match one tokenised search term against the catalog's narrow
/// (content-only) field set. Same per-token semantics as the
/// universal `pfTokenMatches` but excludes path/directory/codec/notes.
nonisolated func pfCatalogTokenMatches(_ token: SearchToken, _ rec: VideoRecord) -> Bool {
    switch token {
    case .field(let field, let value):
        // Field-prefix tokens explicitly name the field, so they're
        // safe to honor in the catalog bar too — even fields the bar
        // would otherwise exclude (notes). The user opted in by typing
        // the prefix.
        return pfFieldTokenMatches(field, value, rec)
    case .substring(let needle):
        let n = needle.lowercased()
        if rec.filename.lowercased().contains(n) { return true }
        // Rick 2026-06-15: directory + volumeName join the catalog
        // narrow matcher so folder-based queries like "Cape Cod 1997"
        // match files organized by project folder. Must stay aligned
        // with CatalogSearchIndex.buildHaystack — correctness contract.
        if rec.directory.lowercased().contains(n) { return true }
        if rec.volumeName.lowercased().contains(n) { return true }
        if rec.detectedPeople.contains(where: { $0.lowercased().contains(n) }) { return true }
        if rec.suspectedPeople.contains(where: { $0.lowercased().contains(n) }) { return true }
        // User-confirmed names match the same as algorithm-detected names
        // for catalog search — both are valid "this video has X" tags.
        // rejectedPeople is intentionally NOT searched here: a record where
        // Rick said "not Anna" should never surface for "anna" queries,
        // which is the whole point of that field.
        if rec.confirmedByUserPeople.contains(where: { $0.name.lowercased().contains(n) }) { return true }
        // Semantic content tags — captions and audio transcripts describe
        // what's IN the video. Composes with people-tag matches: typing
        // "donna guitar" finds clips tagged with Donna AND whose caption
        // mentions guitar — the original two-signal AND demo from the
        // 2026-06-07 brainstorm.
        if rec.sceneCaptions.contains(where: { $0.text.lowercased().contains(n) }) { return true }
        if let t = rec.audioTranscript, t.lowercased().contains(n) { return true }
        // Dossier OCR fields — date burn-ins and on-screen text are the
        // same kind of "what's in the frame" content as captions. Typing
        // "1991" should find a record whose burn-in shows JUN 1991 even
        // when the file mtime says 2024 (transcode date).
        if rec.ocrDateCandidates.contains(where: { $0.text.lowercased().contains(n) }) { return true }
        if rec.ocrText.contains(where: { $0.text.lowercased().contains(n) }) { return true }
        return false
    case .yearRange(let range):
        // Year shorthand fires on filename-embedded years (e.g. "Cape
        // Cod 1990 or earlier") AND on dossier-inferred dates so
        // typing "1990s" finds clips dated to that decade by ANY
        // signal — file metadata, path year, or OCR-derived dates.
        let years = pfYearsFromRecord(rec)
        if years.contains(where: { range.contains($0) }) { return true }
        // Inferred record date from dossier (multi-signal triangulation).
        // Highest-confidence year signal we have; honor it for decade
        // queries even when filename/path carry no year hint.
        if let inf = rec.inferredRecordDate {
            let y = Calendar(identifier: .gregorian).component(.year, from: inf)
            if range.contains(y) { return true }
        }
        return false
    }
}

/// Tokenised AND match against the catalog's narrow field set.
/// Empty query matches every record so callers don't need a short-
/// circuit. Examples:
///
///     ""                  → all records
///     "donna"             → records mentioning donna in any
///                           content field
///     "mark dan grampa"   → records with ALL three substrings,
///                           each in any content field (the original
///                           jq demo, now native)
///     "donna 1990s"       → donna AND a 1990s year signal
nonisolated func pfRecordFilenameOrPersonMatch(_ rec: VideoRecord, query: String) -> Bool {
    let tokens = pfTokenizeSearchQuery(query)
    if tokens.isEmpty { return true }
    return tokens.allSatisfy { pfCatalogTokenMatches($0, rec) }
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

/// Volume-membership predicate for the catalog's Volume filter. A record
/// belongs to a selected volume only when its CURRENT location (`fullPath`)
/// is under one of the selected scan-target prefixes.
///
/// Deliberately does NOT match on `originalFullPath`: after a Relocate, a file
/// that moved (e.g. RicksBackups → LaCie) now lives on LaCie, so selecting the
/// SOURCE volume must not surface it — otherwise you click RicksBackups and see
/// LaCie files, which is confusing and inconsistent with the Volume column
/// (which already reads the current volume). The record's origin is still kept
/// on `originalFullPath` / File Journey for provenance; it just doesn't drive
/// this physical-location filter. (Bug fix 2026-06-20.)
nonisolated func pfRecordOnSelectedVolume(_ rec: VideoRecord, prefixes: [String]) -> Bool {
    prefixes.contains { rec.fullPath.hasPrefix($0) }
}
