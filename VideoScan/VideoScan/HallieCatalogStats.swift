// HallieCatalogStats.swift
// Catalog-wide numbers a relative would know off the top of her head
// (overnight cycle 2, 2026-08-22): "how much footage is there altogether",
// "how many are archived", "how many duplicates", "how much disk space",
// "what years does it cover". Until now these went to the translator as an
// empty search and came back "I need something to look for".
//
// No new query shape: the question is recognised deterministically BEFORE
// translation (a closed vocabulary — any extra content word, a name, a
// place, a year, means it is NOT a catalog-wide question and falls
// through), and answered from one snapshot computed by the client from
// the records it already holds. The numbers are the same ones the Storage
// footer and the Archive progress bar show. Never the model.

import Foundation
import VideoScanCore

struct HallieCatalogStats: Equatable, Sendable {
    let fileCount: Int
    let uniqueFileCount: Int
    let grossBytes: Int64
    let uniqueBytes: Int64
    let duplicateFiles: Int
    let duplicateBytes: Int64
    let volumeCount: Int
    /// Assets with a byte-verified copy in the Master Archive.
    let archivedVerified: Int
    /// Seconds of media across active records (duplicates included — it's
    /// what is on disk; the unique figure is given alongside).
    let totalDurationSeconds: Double
    let earliestYear: Int?
    let latestYear: Int?

    /// O(records), once per question that needs it (clients decide when).
    static func compute(records: [VideoRecord]) -> HallieCatalogStats {
        let totals = CatalogStorageTotalsCalculator.compute(records: records)
        let active = pfActiveRecords(records)
        var duration = 0.0
        var verified = 0
        var earliest: Int?
        var latest: Int?
        for rec in active {
            duration += max(0, rec.durationSeconds)
            if rec.archiveFixity != nil { verified += 1 }
            let resolution = RecordDateResolver.resolve(
                userDate: rec.userDate,
                userDateConfidence: rec.userDateConfidence,
                embeddedCreationDate: rec.embeddedCreationDate,
                originMake: rec.originMake,
                originModel: rec.originModel,
                originEncoder: rec.originEncoder,
                inferredRecordDate: rec.inferredRecordDate,
                inferredDateConfidence: rec.inferredDateConfidence,
                filename: rec.filename.isEmpty ? nil : rec.filename)
            if resolution.precision <= .year, let year = resolution.year {
                earliest = min(earliest ?? year, year)
                latest = max(latest ?? year, year)
            }
        }
        return HallieCatalogStats(
            fileCount: totals.fileCount,
            uniqueFileCount: totals.uniqueFileCount,
            grossBytes: totals.grossBytes,
            uniqueBytes: totals.uniqueBytes,
            duplicateFiles: totals.duplicateFiles,
            duplicateBytes: totals.duplicateBytes,
            volumeCount: totals.volumeCount,
            archivedVerified: verified,
            totalDurationSeconds: duration,
            earliestYear: earliest,
            latestYear: latest)
    }

    // MARK: - The questions

    enum Question: Equatable, Sendable, CaseIterable {
        case total          // how many videos do we have
        case footage        // how much footage / how many hours
        case archived       // how many are archived
        case duplicates     // how many duplicates
        case diskSpace      // how much disk space
        case years          // how many years / what years

        /// Every token of the question must come from the shared filler
        /// plus this kind's own words, and at least one KEY word must be
        /// present. A name, a place, a year or any other content word
        /// disqualifies the turn (it is then a real search).
        fileprivate var keys: Set<String> {
            switch self {
            case .total: return ["videos", "files", "recordings", "tapes", "clips", "items", "movies"]
            case .footage: return ["footage", "hours", "minutes", "long", "runtime", "duration", "playing", "time"]
            case .archived: return ["archived", "archive", "promoted", "verified", "safe", "reliably"]
            case .duplicates: return ["duplicates", "duplicate", "dupes", "copies", "duplicated"]
            case .diskSpace: return ["space", "disk", "storage", "big", "bytes", "gb", "tb", "gigabytes", "terabytes", "size"]
            case .years: return ["years", "year", "decades", "span", "earliest", "oldest", "latest", "newest", "cover", "covers", "range", "from"]
            }
        }

        fileprivate var extras: Set<String> {
            switch self {
            case .total: return ["total", "altogether", "all", "count", "number", "many"]
            case .footage: return ["footage", "video", "videos", "altogether", "total", "all", "much", "many", "there", "is", "of"]
            case .archived: return ["files", "videos", "of", "them", "already", "so", "far", "master", "percent", "percentage", "fraction", "share", "been", "has", "have", "many", "much", "what", "is"]
            case .duplicates: return ["files", "videos", "there", "are", "many", "have", "we", "got", "of", "any", "much"]
            case .diskSpace: return ["whole", "archive", "catalog", "collection", "everything", "take", "takes", "taking", "up", "use", "uses", "used", "does", "much", "how", "is", "it", "total", "altogether", "all", "the", "library", "files", "videos"]
            case .years: return ["footage", "video", "videos", "archive", "catalog", "collection", "do", "does", "we", "have", "many", "much", "what", "which", "is", "the", "to", "does", "it", "go", "back", "far", "how", "recording", "recordings"]
            }
        }
    }

    private static let filler: Set<String> = [
        "how", "many", "much", "do", "does", "did", "we", "have", "has", "had", "there", "are", "is",
        "to", "into", "been",
        "in", "the", "our", "this", "that", "of", "a", "an", "altogether", "all", "total", "totally",
        "overall", "whole", "entire", "catalog", "catalogue", "archive", "collection", "library", "family",
        "hallie", "please", "can", "could", "you", "tell", "me", "what", "whats", "what's", "roughly",
        "about", "approximately", "exactly", "so", "far", "now", "currently", "at", "moment", "got",
    ]

    static func detect(_ text: String) -> Question? {
        let words = text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map(String.init)
        guard !words.isEmpty, words.count <= 14 else { return nil }
        // Any digit (a year), or any word outside the closed vocabulary,
        // means this is a real search, not a catalog-wide question.
        guard !words.contains(where: { $0.contains(where: \.isNumber) }) else { return nil }
        // A question must actually ASK a quantity.
        guard words.contains("how") || words.contains("what") || words.contains("which") else { return nil }
        for question in Question.allCases {
            let allowed = filler.union(question.keys).union(question.extras)
            // Distance-1 typo forgiveness TOWARD vocabulary words only
            // ("mny"→"many", "archved"→"archived"; live 2026-08-25). A
            // typo'd content word (a name, a place) matches nothing here
            // and the question still falls through to a real search.
            func fits(_ word: String) -> Bool {
                if allowed.contains(word) { return true }
                guard word.count >= 3 else { return false }
                return allowed.contains { $0.count >= 4 && Self.editDistanceIsAtMostOne(word, $0) }
            }
            func isKey(_ word: String) -> Bool {
                question.keys.contains(word)
                    || (word.count >= 4 && question.keys.contains {
                        $0.count >= 4 && Self.editDistanceIsAtMostOne(word, $0)
                    })
            }
            guard words.allSatisfy(fits),
                  words.contains(where: isKey) else { continue }
            // "how many videos" must not be read as "how many years" etc.:
            // prefer the kind whose key appears; ordering below resolves
            // the overlaps (archived before total, years before footage).
            return question
        }
        return nil
    }

    /// True when `a` becomes `b` with at most one edit (insert, delete, or
    /// substitute). Small inputs only — both words are question tokens.
    static func editDistanceIsAtMostOne(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let x = Array(a), y = Array(b)
        if abs(x.count - y.count) > 1 { return false }
        var i = 0, j = 0, edits = 0
        while i < x.count && j < y.count {
            if x[i] == y[j] { i += 1; j += 1; continue }
            edits += 1
            if edits > 1 { return false }
            if x.count == y.count { i += 1; j += 1 }        // substitution
            else if x.count > y.count { i += 1 }            // deletion from a
            else { j += 1 }                                 // insertion into a
        }
        return edits + (x.count - i) + (y.count - j) <= 1
    }

    // MARK: - The answers

    static func answer(_ question: Question, stats s: HallieCatalogStats) -> HallieTurnExecutor.Result {
        let prose: String
        switch question {
        case .total:
            prose = s.fileCount == 0
                ? "The catalog is empty right now."
                : "There are \(s.fileCount.formatted()) media files in the catalog across \(s.volumeCount) volume\(s.volumeCount == 1 ? "" : "s") — \(s.uniqueFileCount.formatted()) unique once the duplicate copies are set aside."
        case .footage:
            prose = s.totalDurationSeconds < 60
                ? "I don't have running times for the catalog yet."
                : "About \(Self.hours(s.totalDurationSeconds)) of footage altogether, in \(s.fileCount.formatted()) files (\(s.uniqueFileCount.formatted()) unique)."
        case .archived:
            let pct = s.uniqueFileCount > 0 ? Double(s.archivedVerified) / Double(s.uniqueFileCount) * 100 : 0
            let pctText = s.archivedVerified > 0 && pct < 1 ? "under 1%" : "\(Int(pct.rounded()))%"
            prose = s.archivedVerified == 0
                ? "Nothing has a verified copy in the Master Archive yet — of \(s.uniqueFileCount.formatted()) unique media files."
                : "\(s.archivedVerified.formatted()) file\(s.archivedVerified == 1 ? " has" : "s have") a verified copy in the Master Archive — \(pctText) of the \(s.uniqueFileCount.formatted()) unique media files. The rest are still to be promoted."
        case .duplicates:
            prose = s.duplicateFiles == 0
                ? "The catalog hasn't found any duplicate copies."
                : "\(s.duplicateFiles.formatted()) files are extra copies of something already counted — \(MediaBytes.display(s.duplicateBytes)) that could be set aside once the keepers are chosen."
        case .diskSpace:
            prose = s.grossBytes == 0
                ? "I don't have file sizes for the catalog yet."
                : "Everything in the catalog takes up \(MediaBytes.display(s.grossBytes)) across \(s.volumeCount) volume\(s.volumeCount == 1 ? "" : "s"); the unique content is \(MediaBytes.display(s.uniqueBytes)), and \(MediaBytes.display(s.duplicateBytes)) of that total is duplicate copies."
        case .years:
            if let first = s.earliestYear, let last = s.latestYear {
                let span = last - first + 1
                prose = span <= 1
                    ? "Everything I can date is from \(first)."
                    : "The footage runs from \(first) to \(last) — about \(span) years of the family's life. (Undated files aren't counted here.)"
            } else {
                prose = "I can't put years to the footage yet — nothing in the catalog has a dated record."
            }
        }
        return HallieTurnExecutor.Result(
            route: .aggregate,
            outcome: .answered,
            prose: prose,
            basisLine: "Basis: catalog totals over \(s.fileCount.formatted()) active records (duplicates from catalog analysis; archive count = records with a verified Master Archive copy; years from each record's resolved date); no model call.",
            queryDescription: "catalog-stats \(question)",
            citations: [],
            catalogPersonName: nil,
            answerPlan: HallieAnswerPlan(route: .aggregate, shape: .fixed, fallbackText: prose))
    }

    static func hours(_ seconds: Double) -> String {
        let hours = seconds / 3600
        if hours < 1 { return "\(Int((seconds / 60).rounded())) minutes" }
        if hours < 10 { return String(format: "%.1f hours", hours) }
        if hours < 100 { return "\(Int(hours.rounded())) hours" }
        return "\(Int(hours.rounded()).formatted()) hours (\(Int((hours / 24).rounded())) days of playing time)"
    }
}
