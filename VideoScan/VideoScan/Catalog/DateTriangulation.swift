import Foundation

// MARK: - pfInferRecordDate
//
// Pure helper that triangulates a record's true date from independent
// signals. Used by the dossier orchestrator after a per-record
// VLM + Whisper pass. Returns the best-guess date plus a 0.0–1.0
// confidence the UI can surface ("?" affordance for low values).
//
// PROVEN 2026-06-04 on Clip 03_converted.mov: file mtime says
// 2024-04-20 (transcode date), OCR across 11 of 15 frames reads
// "JUN.21 1991, PM 11:30". The helper must produce 1991-06-21 with
// high confidence, not 2024.
//
// GH #166 (2026-08-20, Clip 01.dv): camcorder OSD burn-ins also come
// through as two-digit apostrophe years — "JUN 21 '97". The old parser
// required a 4-digit year, so ALL content evidence was dropped and the
// 2007 copy-date mtime leaked into inferredRecordDate. Now:
//   * pfParseOcrDate understands '97 / ’97 two-digit years;
//   * transcript + scene-caption year mentions corroborate an OCR date
//     (single OCR hit + an agreeing independent channel → 0.90, which
//     clears RecordDateResolver's content-agreement tier so the result
//     can outvote a copy-era container stamp);
//   * with NO parseable OCR date, agreeing year mentions still beat the
//     mtime — but deliberately BELOW the resolver's 0.6 trust floor,
//     because they are year-precision facts and the resolver/archive
//     currently treats every inferred date as day-precision (a fake
//     "Jan 1" filing would be a false claim; see the confidence table).
//
// Confidence table (what the number MEANS downstream — the resolver's
// floor is 0.6, its stamp-outvote tier is 0.85):
//   0.95  OCR consensus, ≥3 frames agree
//   0.85  OCR, 2 frames agree
//   0.90  OCR, 1 frame + an agreeing transcript/caption year
//   0.75  OCR, 1 frame, uncorroborated
//   0.58  no OCR date; transcript AND captions agree on one year
//   0.55  no OCR date; one channel names exactly one year
//   0.50  path year hint ("Christmas2010/")
//   0.30  file mtime / container time — well-known liar (copy date)

/// Inferred record date plus confidence in 0.0–1.0.
struct RecordDateInference {
    let date: Date?
    let confidence: Float
}

// Allow tuple-style call site (result.date, result.confidence) used by tests.
extension RecordDateInference {
    var asTuple: (date: Date?, confidence: Float) { (date, confidence) }
}

nonisolated func pfInferRecordDate(
    ocrDateCandidates: [String],
    audioTranscript: String?,
    sceneCaptionTexts: [String] = [],
    pathYearHints: [Int],
    fileMtime: Date?,
    containerCreationTime: Date?
) -> (date: Date?, confidence: Float) {

    // Content-year mentions from the two free-text channels. Each set is
    // an independent witness; agreement between them (or with OCR) is
    // what earns real confidence.
    let transcriptYears = Set(audioTranscript.map { pfYearMentions(in: $0) } ?? [])
    let captionYears = Set(sceneCaptionTexts.flatMap { pfYearMentions(in: $0) })

    // 1. OCR — parse each candidate, drop noise, look for consensus.
    let parsedOcr: [Date] = ocrDateCandidates
        .compactMap(pfParseOcrDate(_:))
    if !parsedOcr.isEmpty {
        let bucketed = Dictionary(grouping: parsedOcr) { d in
            // Bucket by year-month-day at noon-UTC for consensus
            let cal = Calendar(identifier: .gregorian)
            var dc = cal.dateComponents([.year, .month, .day], from: d)
            dc.hour = 12
            dc.timeZone = TimeZone(identifier: "UTC")
            return cal.date(from: dc) ?? d
        }
        if let (bestDate, hits) = bucketed.max(by: { $0.value.count < $1.value.count }) {
            // ≥3 frames agree → very high confidence
            // 2 frames agree → high confidence
            // 1 frame only → medium confidence (better than path-year,
            // worse than consensus, comparable to a single audio mention)
            var conf: Float
            switch hits.count {
            case 3...: conf = 0.95
            case 2:    conf = 0.85
            default:   conf = 0.75
            }
            // GH #166: a single OCR frame corroborated by an INDEPENDENT
            // channel naming the same year is "content evidence agreeing
            // with itself" — lift it over the resolver's 0.85 stamp-
            // outvote tier.
            var utcCal = Calendar(identifier: .gregorian)
            utcCal.timeZone = TimeZone(identifier: "UTC") ?? .current
            let ocrYear = utcCal.component(.year, from: bestDate)
            if transcriptYears.contains(ocrYear) || captionYears.contains(ocrYear) {
                conf = max(conf, 0.90)
            }
            return (bestDate, conf)
        }
    }

    // 2. Content-year mentions without a parseable OCR date. Year
    //    precision only, so both tiers sit BELOW the resolver's 0.6
    //    floor on purpose: they fix the DISPLAYED inference (no more
    //    copy-date mtime shown with a straight face) without filing the
    //    archive under a fabricated "Jan 1". Ambiguity (≥2 distinct
    //    years) falls through — a spoken "born in 1962" must not date
    //    the tape.
    let commonYears = transcriptYears.intersection(captionYears)
    if commonYears.count == 1, let y = commonYears.first,
       let d = pfJanuaryFirst(of: y) {
        return (d, 0.58)
    }
    let allContentYears = transcriptYears.union(captionYears)
    if allContentYears.count == 1, let y = allContentYears.first,
       let d = pfJanuaryFirst(of: y) {
        return (d, 0.55)
    }

    // 3. Path year hint — folder named "Christmas2010/" etc.
    if let year = pathYearHints.first, year >= 1900, year <= 2100 {
        if let d = pfJanuaryFirst(of: year) {
            return (d, 0.50)
        }
    }

    // 4. File mtime — well-known liar (transcode date / VHS ingest
    //    date) but better than nothing.
    if let mt = fileMtime {
        return (mt, 0.30)
    }
    if let ct = containerCreationTime {
        return (ct, 0.30)
    }

    return (nil, 0.0)
}

/// Noon-UTC Jan 1 of a year — the codebase's year-only placeholder
/// convention (same shape the path-hint branch has always produced).
nonisolated func pfJanuaryFirst(of year: Int) -> Date? {
    var dc = DateComponents()
    dc.year = year; dc.month = 1; dc.day = 1; dc.hour = 12
    dc.timeZone = TimeZone(identifier: "UTC")
    return Calendar(identifier: .gregorian).date(from: dc)
}

// MARK: - Content-year extraction (transcript / captions)
//
// Plausible year mentions in free text: bounded 4-digit 19xx/20xx not
// embedded in a longer digit run ("019975" is not 1997), plus camcorder-
// style apostrophe two-digit years ("'97" / "’97"). Used both by the
// triangulation above and by the GH #166 catalog sensor.

/// All plausible year mentions in `text`, in order of appearance
/// (duplicates preserved — callers Set() when they want distinctness).
/// A recording date cannot be in the future, so the ceiling is
/// now-year + 1 (clock-skew grace) — the real catalog has a caption
/// reading "2040" that must not date a tape.
nonisolated func pfYearMentions(in text: String, now: Date = Date()) -> [Int] {
    guard !text.isEmpty else { return [] }
    let pattern = #"(?<!\d)(?:((?:19|20)\d{2})|['’](\d{2}))(?!\d)"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    var utcCal = Calendar(identifier: .gregorian)
    utcCal.timeZone = TimeZone(identifier: "UTC") ?? .current
    let maxYear = utcCal.component(.year, from: now) + 1
    let range = NSRange(text.startIndex..., in: text)
    var years: [Int] = []
    for m in regex.matches(in: text, range: range) {
        if let r = Range(m.range(at: 1), in: text), let y = Int(text[r]) {
            years.append(y)
        } else if let r = Range(m.range(at: 2), in: text), let yy = Int(text[r]) {
            years.append(pfExpandTwoDigitYear(yy))
        }
    }
    return years.filter { $0 >= 1900 && $0 <= maxYear }
}

/// Two-digit-year pivot, fixed at 30: '30–'99 → 19xx, '00–'29 → 20xx.
/// Family-archive domain — camcorder OSDs with apostrophe years are
/// overwhelmingly 1980s–1990s tape.
nonisolated func pfExpandTwoDigitYear(_ yy: Int) -> Int {
    yy >= 30 ? 1900 + yy : 2000 + yy
}

// MARK: - GH #166 sensor helper
//
// "What year does the CONTENT evidence agree on?" — the pure core of
// the catalog-wide sensor (DateInferenceSensorTests) that counts
// records whose stored inferredRecordDate contradicts their own content
// evidence by ≥3 years. Returns nil when there is no content evidence
// or it disagrees with itself.

nonisolated func pfContentEvidenceYear(
    ocrDateCandidates: [String],
    audioTranscript: String?,
    sceneCaptionTexts: [String]
) -> Int? {
    var utcCal = Calendar(identifier: .gregorian)
    utcCal.timeZone = TimeZone(identifier: "UTC") ?? .current
    // OCR burn-ins are the strongest channel: majority year wins.
    let ocrYears = ocrDateCandidates.compactMap(pfParseOcrDate(_:))
        .map { utcCal.component(.year, from: $0) }
    if !ocrYears.isEmpty {
        let counts = Dictionary(grouping: ocrYears) { $0 }.mapValues(\.count)
        return counts.max { $0.value < $1.value }?.key
    }
    // No OCR: only an UNANIMOUS mention year counts as evidence.
    let transcriptYears = Set(audioTranscript.map { pfYearMentions(in: $0) } ?? [])
    let captionYears = Set(sceneCaptionTexts.flatMap { pfYearMentions(in: $0) })
    let common = transcriptYears.intersection(captionYears)
    if common.count == 1 { return common.first }
    let all = transcriptYears.union(captionYears)
    if all.count == 1 { return all.first }
    return nil
}

// MARK: - OCR date parsing
//
// Real OCR output from Qwen2.5-VL-3B-4bit on burn-in timestamps has
// included: "JUN.21 1991", "JUN. 21 1991", "Jun 21, 1991",
// "PM11:30 JUN.21 1991", "P.M. 11 = 30 JUN. 21 1991", "DEC 25 2010",
// and (GH #166) the two-digit form "JUN 21 '97" / "JUN\n21\n'97".
//
// Strategy: regex-extract the date portion (month-name + day + year),
// normalize, parse via DateComponents. Reject noise like "NONE",
// "1:55" (time only without date context). Two-digit years REQUIRE the
// apostrophe — a bare trailing "11" after "JUN 21" is more likely a
// truncated "11:30" than a year.

/// Parse one OCR date candidate string. Returns nil for noise or
/// strings without a recognizable date.
nonisolated func pfParseOcrDate(_ raw: String) -> Date? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty || trimmed.uppercased() == "NONE" { return nil }

    // Three-letter month abbreviations + full forms.
    let monthMap: [String: Int] = [
        "JAN": 1, "JANUARY": 1,
        "FEB": 2, "FEBRUARY": 2,
        "MAR": 3, "MARCH": 3,
        "APR": 4, "APRIL": 4,
        "MAY": 5,
        "JUN": 6, "JUNE": 6,
        "JUL": 7, "JULY": 7,
        "AUG": 8, "AUGUST": 8,
        "SEP": 9, "SEPT": 9, "SEPTEMBER": 9,
        "OCT": 10, "OCTOBER": 10,
        "NOV": 11, "NOVEMBER": 11,
        "DEC": 12, "DECEMBER": 12
    ]

    // Pattern: <MONTH-NAME>[. ]+<DAY>[, ]+<YEAR>
    // Tolerates dots, commas, hyphens, "= " (camcorder OSD quirk) and
    // newlines (the VLM sometimes stacks OSD lines: "JUN\n21\n'97").
    // Year is 4-digit 19xx/20xx, OR apostrophe + 2 digits ('97, ’97, `97).
    let upper = trimmed.uppercased()
    let pattern = #"([A-Z]{3,9})[.\s]+(\d{1,2})[.\s,]+(?:((?:19|20)\d{2})|['’`]\s?(\d{2}))(?!\d)"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
    let range = NSRange(upper.startIndex..., in: upper)
    guard let match = regex.firstMatch(in: upper, options: [], range: range),
          match.numberOfRanges >= 5,
          let mRange = Range(match.range(at: 1), in: upper),
          let dRange = Range(match.range(at: 2), in: upper) else {
        return nil
    }

    let monthStr = String(upper[mRange])
    guard let month = monthMap[monthStr] else { return nil }
    guard let day = Int(upper[dRange]), day >= 1, day <= 31 else { return nil }

    let year: Int
    if let yRange = Range(match.range(at: 3), in: upper), let y = Int(upper[yRange]) {
        year = y
    } else if let yyRange = Range(match.range(at: 4), in: upper), let yy = Int(upper[yyRange]) {
        year = pfExpandTwoDigitYear(yy)
    } else {
        return nil
    }

    var dc = DateComponents()
    dc.year = year; dc.month = month; dc.day = day; dc.hour = 12
    dc.timeZone = TimeZone(identifier: "UTC")
    return Calendar(identifier: .gregorian).date(from: dc)
}
