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
    /// Assets with a byte-verified copy in the Master Archive
    /// (ArchivePromotionIndex.Totals.verified).
    let archivedVerified: Int
    /// Promoted copies present WITHOUT a fixity record — copied, not yet
    /// verified (ArchivePromotionIndex.Totals.unverified; codex #717/#718:
    /// "still to be promoted" must subtract these too).
    let archivedUnverified: Int

    /// The Archive tab's own arithmetic (total = max(unique, verified +
    /// unverified); remaining subtracts both), so Hallie's figures can
    /// never disagree with the progress bar — or exceed 100%.
    var archiveProgress: ArchiveProgress {
        ArchiveProgress(verified: archivedVerified, unverified: archivedUnverified,
                        uniqueTotal: uniqueFileCount, verifiedBytes: 0, uniqueBytes: uniqueBytes)
    }
    /// Seconds of media across active records (duplicates included — it's
    /// what is on disk; the unique figure is given alongside).
    let totalDurationSeconds: Double
    let earliestYear: Int?
    let latestYear: Int?

    /// O(records), once per question that needs it (clients decide when).
    /// `storage` lets a caller pass the footer's already-memoised totals
    /// for this catalog version instead of recomputing them; either way
    /// EVERY figure here describes `CatalogStorageTotalsCalculator
    /// .partition`'s counted population (codex #725) — a hidden
    /// manually-deleted row cannot move the footage total or the year
    /// span while the file count ignores it.
    static func compute(records: [VideoRecord],
                        storage: CatalogStorageTotals? = nil) -> HallieCatalogStats {
        let totals = storage ?? CatalogStorageTotalsCalculator.compute(records: records)
        let active = CatalogStorageTotalsCalculator.partition(records).counted
        var duration = 0.0
        var verified = 0
        var unverified = 0
        var earliest: Int?
        var latest: Int?
        // Same population as ArchivePromotionIndex.totals (the Archive tab's
        // progress bar / footer): promoted copies, not purged, with fixity.
        for rec in records where rec.derivationKind == ArchivePromotion.derivationKind && !rec.isPurged {
            if rec.archiveFixity != nil { verified += 1 } else { unverified += 1 }
        }
        for rec in active {
            duration += max(0, rec.durationSeconds)
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
            archivedUnverified: unverified,
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
            case .archived: return ["archived", "archive", "promoted", "promote", "verified", "safe", "reliably", "unarchived", "familyarchive"]
            case .duplicates: return ["duplicates", "duplicate", "dupes", "copies", "duplicated"]
            case .diskSpace: return ["space", "disk", "storage", "big", "bytes", "gb", "tb", "gigabytes", "terabytes", "size"]
            case .years: return ["years", "year", "decades", "span", "earliest", "oldest", "latest", "newest", "cover", "covers", "range", "from"]
            }
        }

        fileprivate var extras: Set<String> {
            switch self {
            case .total: return ["total", "altogether", "all", "count", "number", "many"]
            case .footage: return ["footage", "video", "videos", "altogether", "total", "all", "much", "many", "there", "is", "of"]
            // "items"/"recordings"/… are .total's keys but a relative says "how many
            // items have been promoted" (live 2026-08-27 — the word fell outside
            // this closed set and the question became a presence search).
            // "not"/"yet"/"still"/"left" cover the complement ("how many are
            // not yet archived"); "on" covers "on FamilyArchive".
            case .archived: return ["files", "videos", "items", "recordings", "clips", "tapes", "movies", "of", "them", "already", "so", "far", "master", "percent", "percentage", "fraction", "share", "been", "has", "have", "many", "much", "what", "is", "not", "yet", "still", "left", "remain", "remaining", "on", "copy", "copies", "raid", "gold"]
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
        // "what's archived" / "whats archived" ask just as plainly as "what".
        guard words.contains(where: { ["how", "what", "what's", "whats", "which"].contains($0) }) else { return nil }
        // Every correctly-spelled vocabulary word, across ALL question
        // kinds. A word found here is NOT a typo — if it doesn't fit the
        // question at hand, the question falls through; fuzzing it would
        // break the overlap ordering ("archived" must never count as
        // filler "archive"; singular "video" must not become "videos").
        let globalVocabulary = Question.allCases.reduce(filler) {
            $0.union($1.keys).union($1.extras)
        }
        for question in Question.allCases {
            let allowed = filler.union(question.keys).union(question.extras)
            // Distance-1 typo forgiveness for UNKNOWN tokens only
            // ("mny"→"many", "archved"→"archived"; live 2026-08-25). A
            // typo'd content word (a name, a place) matches nothing here
            // and the question still falls through to a real search.
            func fuzzable(_ word: String) -> Bool {
                word.count >= 3 && !globalVocabulary.contains(word)
            }
            let exactKeyIndices = words.indices.filter {
                question.keys.contains(words[$0])
            }
            func fuzzyKey(_ word: String, at index: Int) -> Bool {
                let matchesKey = question.keys.contains {
                    $0.count >= 4 && Self.editDistanceIsAtMostOne(word, $0)
                }
                guard matchesKey else { return false }
                // Once a correctly spelled key is already present, accept a
                // second fuzzy key only as an adjacent compound ("disk
                // spce"). This keeps real scoped names such as "files of
                // Miles" from being consumed as another spelling of files.
                return exactKeyIndices.isEmpty
                    || exactKeyIndices.contains { abs($0 - index) == 1 }
            }
            func fits(_ word: String, at index: Int) -> Bool {
                if allowed.contains(word) { return true }
                guard fuzzable(word) else { return false }
                if fuzzyKey(word, at: index) { return true }
                // Filler fuzzing is deliberately syntactic. "how mny" is
                // an obvious quantity typo; an unknown word elsewhere may
                // be a person's name (Mary is one edit from many).
                guard index == 1, words.first == "how" else { return false }
                return ["many", "much"].contains {
                    Self.editDistanceIsAtMostOne(word, $0)
                }
            }
            func isKey(_ word: String, at index: Int) -> Bool {
                question.keys.contains(word)
                    || (fuzzable(word) && fuzzyKey(word, at: index))
            }
            guard words.indices.allSatisfy({ fits(words[$0], at: $0) }),
                  words.indices.contains(where: { isKey(words[$0], at: $0) }) else { continue }
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

    /// "How many are archived / promoted / verified" — both figures, with
    /// the Archive tab's arithmetic (codex #717/#718). Promoted = verified
    /// + not-yet-verified copies; remaining subtracts both; the percentage
    /// is verified over ArchiveProgress.total, so it cannot pass 100%.
    static func archivedProse(_ s: HallieCatalogStats) -> String {
        let p = s.archiveProgress
        let promoted = p.verified + p.unverified
        let unique = "\(p.total.formatted()) unique media files"
        func isAre(_ n: Int) -> String { n == 1 ? "is" : "are" }
        func hasHave(_ n: Int) -> String { n == 1 ? "has" : "have" }
        func files(_ n: Int) -> String { "\(n.formatted()) file\(n == 1 ? "" : "s")" }
        let pct: String
        switch p.percentText {
        case "<1%": pct = "under 1%"
        case ">99%": pct = "over 99%"
        default: pct = p.percentText
        }
        let remaining = p.remaining == 0
            ? "Nothing is left to promote."
            : "\(p.remaining.formatted()) \(isAre(p.remaining)) still to be promoted."
        if promoted == 0 {
            return "Nothing has a verified copy in the Master Archive yet — of \(unique)."
        }
        if p.unverified == 0 {
            return "\(files(p.verified)) \(hasHave(p.verified)) a verified copy in the Master Archive — \(pct) of the \(unique). \(remaining)"
        }
        return "\(files(promoted)) \(hasHave(promoted)) been promoted to the Master Archive, of which \(p.verified.formatted()) \(isAre(p.verified)) verified — \(pct) of the \(unique) verified; \(p.unverified.formatted()) \(isAre(p.unverified)) copied but not yet verified. \(remaining)"
    }

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
            prose = Self.archivedProse(s)
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
            basisLine: "Basis: catalog totals over \(s.fileCount.formatted()) active records (duplicates from catalog analysis; archive counts = promoted Master Archive copies, verified and not yet verified, as the Archive tab counts them; years from each record's resolved date); no model call.",
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
