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
    pathYearHints: [Int],
    fileMtime: Date?,
    containerCreationTime: Date?
) -> (date: Date?, confidence: Float) {

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
            let conf: Float
            switch hits.count {
            case 3...: conf = 0.95
            case 2:    conf = 0.85
            default:   conf = 0.75
            }
            return (bestDate, conf)
        }
    }

    // 2. Audio transcript — explicit spoken date mentions. v1: stub,
    //    we don't extract dates from audio yet because the Whisper
    //    transcript usually says "Christmas" or "the kids' birthday"
    //    rather than "December 25 2010". Future work: NLP for date
    //    expressions. For now this branch is reserved.
    //    Intentionally falls through.

    // 3. Path year hint — folder named "Christmas2010/" etc.
    if let year = pathYearHints.first, year >= 1900, year <= 2100 {
        var dc = DateComponents()
        dc.year = year; dc.month = 1; dc.day = 1; dc.hour = 12
        dc.timeZone = TimeZone(identifier: "UTC")
        if let d = Calendar(identifier: .gregorian).date(from: dc) {
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

// MARK: - OCR date parsing
//
// Real OCR output from Qwen2.5-VL-3B-4bit on burn-in timestamps has
// included: "JUN.21 1991", "JUN. 21 1991", "Jun 21, 1991",
// "PM11:30 JUN.21 1991", "P.M. 11 = 30 JUN. 21 1991", "DEC 25 2010".
//
// Strategy: regex-extract the date portion (month-name + day + 4-digit
// year), normalize, parse via DateComponents. Reject noise like
// "NONE", "1:55" (time only without date context).

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

    // Pattern: <MONTH-NAME>[. ]+<DAY>[, ]+<4-DIGIT-YEAR>
    // Tolerates dots, commas, hyphens, "= " (camcorder OSD quirk).
    // Day can have leading zero, year is 19xx or 20xx.
    let upper = trimmed.uppercased()
    let pattern = #"([A-Z]{3,9})[.\s]+(\d{1,2})[.\s,]+((?:19|20)\d{2})"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
    let range = NSRange(upper.startIndex..., in: upper)
    guard let match = regex.firstMatch(in: upper, options: [], range: range),
          match.numberOfRanges >= 4,
          let mRange = Range(match.range(at: 1), in: upper),
          let dRange = Range(match.range(at: 2), in: upper),
          let yRange = Range(match.range(at: 3), in: upper) else {
        return nil
    }

    let monthStr = String(upper[mRange])
    guard let month = monthMap[monthStr] else { return nil }
    guard let day = Int(upper[dRange]), day >= 1, day <= 31 else { return nil }
    guard let year = Int(upper[yRange]) else { return nil }

    var dc = DateComponents()
    dc.year = year; dc.month = month; dc.day = day; dc.hour = 12
    dc.timeZone = TimeZone(identifier: "UTC")
    return Calendar(identifier: .gregorian).date(from: dc)
}
