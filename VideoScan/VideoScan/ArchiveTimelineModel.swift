// ArchiveTimelineModel.swift
// Archive tab — Timeline view data model (docs/archive-view.md,
// Rick + Claude 2026-08-20). Pure and headless-testable; SwiftUI-free.
//
// The archive's disk layout IS the timeline's source of truth: a promoted
// copy lives at <decade>/<year>/<human name> (e.g.
// "1990-1999/1997/1997-xx-xx_Family_CapeCod_1997.dv"), placed by the same
// ArchiveDateHint the promote flow resolves. Parsing decade/year back out
// of the relative path means the view and the disk can never disagree.
// Anything that doesn't parse (Undated/, scaffold folders like 10_Photos/
// without a year, hand-copied strays) lands on the Undated shelf — shown,
// not hidden.

import Foundation

// MARK: - One item on the timeline

/// One vetted archived asset, ready to render. Built on the main actor
/// from the archived snapshot (ArchiveView+Timeline), consumed here.
struct ArchiveTimelineItem: Identifiable, Equatable {
    /// The ASSET record id (the source record, or the orphan copy standing
    /// in for a vanished source) — same id the table/context menus use.
    let id: UUID
    /// Human title derived from the archive filename:
    /// "1997-xx-xx_Family_CapeCod_1997.dv" → "Family CapeCod 1997".
    let title: String
    /// The copy's filename exactly as it sits in the archive.
    let archiveFilename: String
    /// Archive-relative path of the master copy.
    let relPath: String
    /// Year parsed from the archive path (folder first, filename second).
    let year: Int?
    let kind: Kind
    /// Raw duration in seconds (0 = unknown); rendered via
    /// `friendlyDuration` — the story view says "2 hr 10 min", not
    /// "2:10:45" (Rick, RD round 1).
    let durationSeconds: Double
    /// "Rick, Matt · Donna?" or "" when nobody is tagged.
    let peopleText: String
    /// Fixity recorded at promote time (byte-verified copy).
    let isVerified: Bool

    enum Kind: Equatable {
        case video
        case audio
        /// Milestone photos — timeline markers, not a photo database.
        case photo
    }

    /// "2 hr 10 min" / "12 min" / "45 sec"; "" when unknown. Friendly,
    /// not frame-accurate: hour-scale truncates to the minute (2:10:45 →
    /// "2 hr 10 min"), minute-scale rounds, sub-minute rounds to seconds.
    var friendlyDuration: String {
        ArchiveTimelinePath.friendlyDuration(seconds: durationSeconds)
    }
}

// MARK: - Path → year / title

enum ArchiveTimelinePath {

    /// Year of record from the archive-relative path. Folder layout wins
    /// ("1990-1999/1997/…" → 1997); a filename that leads with a plausible
    /// year ("1997-xx-xx_…") is the fallback for strays outside the
    /// decade tree (10_Photos/…). Nil → Undated shelf.
    static func year(fromRelPath rel: String) -> Int? {
        let comps = rel.split(separator: "/").map(String.init)
        if comps.count >= 3,
           isDecadeFolder(comps[0]),
           let y = plausibleYear(comps[1]) {
            return y
        }
        if let name = comps.last, let y = leadingYear(in: name) {
            return y
        }
        return nil
    }

    /// "1990-1999" (any ten-year span formatted start-end).
    static func isDecadeFolder(_ s: String) -> Bool {
        let parts = s.split(separator: "-")
        guard parts.count == 2,
              let a = Int(parts[0]), let b = Int(parts[1]),
              parts[0].count == 4, parts[1].count == 4 else { return false }
        return b == a + 9 && plausibleYear(String(parts[0])) != nil
    }

    /// A year home video can plausibly carry (film transfers included).
    static func plausibleYear(_ s: String) -> Int? {
        guard s.count == 4, let y = Int(s), (1900...2099).contains(y) else { return nil }
        return y
    }

    /// Leading "YYYY" of a filename, only when it reads as a date prefix
    /// ("1997-xx-xx_…", "1997_…", "1997-…") — never digits mid-name.
    static func leadingYear(in filename: String) -> Int? {
        guard filename.count >= 4 else { return nil }
        let head = String(filename.prefix(4))
        guard let y = plausibleYear(head) else { return nil }
        if filename.count == 4 { return y }
        let next = filename[filename.index(filename.startIndex, offsetBy: 4)]
        return (next == "-" || next == "_" || next == " " || next == ".") ? y : nil
    }

    /// See ArchiveTimelineItem.friendlyDuration for the display rules.
    static func friendlyDuration(seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "" }
        if seconds < 59.5 { return "\(Int(seconds.rounded())) sec" }
        let totalMinutes = seconds >= 3600
            ? Int(seconds / 60)                    // hour scale: truncate
            : Int((seconds / 60).rounded())        // minute scale: round
        if totalMinutes < 60 { return "\(totalMinutes) min" }
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        return m == 0 ? "\(h) hr" : "\(h) hr \(m) min"
    }

    /// Human title from the archive filename: drop the extension, strip
    /// the date prefix the Helper adds ("1997-xx-xx_", "1997-07-04_"),
    /// underscores become spaces. The trailing year many names carry
    /// ("…_CapeCod_1997") is part of the name; it stays.
    static func title(fromArchiveFilename name: String) -> String {
        var stem = (name as NSString).deletingPathExtension
        // Date prefix: YYYY(-MM|-xx)(-DD|-xx) followed by _ or space.
        if let range = stem.range(of: #"^\d{4}(-[0-9x]{2}){0,2}[_ ]+"#,
                                  options: .regularExpression) {
            stem.removeSubrange(range)
        }
        let words = stem
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
        let title = words.joined(separator: " ")
        return title.isEmpty ? (name as NSString).deletingPathExtension : title
    }
}

// MARK: - Grouping: years → decades, gaps kept

struct ArchiveTimelineYear: Identifiable, Equatable {
    let year: Int
    var items: [ArchiveTimelineItem]
    var id: Int { year }
}

struct ArchiveTimelineDecade: Identifiable, Equatable {
    /// First year of the decade (1990 for the 1990s).
    let start: Int
    /// Years that actually hold media, ascending. Empty ⇒ this decade is
    /// a GAP — drawn honestly ("tapes in the attic?"), never omitted.
    var years: [ArchiveTimelineYear]
    var id: Int { start }
    var label: String { "\(start)s" }
    var rangeLabel: String { "\(start)–\(start + 9)" }
    var count: Int { years.reduce(0) { $0 + $1.items.count } }
    var isGap: Bool { years.isEmpty }
}

/// The whole timeline: decades oldest-first (a chronicle reads downward —
/// Rick 2026-08-20), plus the pinned Undated shelf.
struct ArchiveTimeline: Equatable {
    var decades: [ArchiveTimelineDecade] = []
    var undated: [ArchiveTimelineItem] = []

    var isEmpty: Bool { decades.isEmpty && undated.isEmpty }
    var datedCount: Int { decades.reduce(0) { $0 + $1.count } }

    /// Is this item on the timeline (after any search narrowing)? Used to
    /// decide whether a hand-off target can be scrolled to. O(archived).
    func contains(_ id: UUID) -> Bool {
        undated.contains { $0.id == id } ||
        decades.contains { $0.years.contains { $0.items.contains { $0.id == id } } }
    }

    /// O(n log n) in the number of ARCHIVED items (never the whole
    /// catalog). Decade span runs from the earliest to the latest year
    /// with media, inclusive, so interior gaps show.
    static func build(items: [ArchiveTimelineItem]) -> ArchiveTimeline {
        var byYear: [Int: [ArchiveTimelineItem]] = [:]
        var undated: [ArchiveTimelineItem] = []
        for item in items {
            if let y = item.year { byYear[y, default: []].append(item) }
            else { undated.append(item) }
        }
        undated.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        guard let minYear = byYear.keys.min(), let maxYear = byYear.keys.max() else {
            return ArchiveTimeline(decades: [], undated: undated)
        }

        var decades: [ArchiveTimelineDecade] = []
        var start = (minYear / 10) * 10
        let lastStart = (maxYear / 10) * 10
        while start <= lastStart {
            let years = (start...(start + 9)).compactMap { y -> ArchiveTimelineYear? in
                guard var its = byYear[y] else { return nil }
                its.sort {
                    $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
                return ArchiveTimelineYear(year: y, items: its)
            }
            decades.append(ArchiveTimelineDecade(start: start, years: years))
            start += 10
        }
        return ArchiveTimeline(decades: decades, undated: undated)
    }

    /// Search narrowing for the toolbar field: title, filename, people.
    /// Runs over archived items only (small), per keystroke.
    static func build(items: [ArchiveTimelineItem], matching query: String) -> ArchiveTimeline {
        guard !query.isEmpty else { return build(items: items) }
        let q = query.lowercased()
        return build(items: items.filter {
            $0.title.lowercased().contains(q) ||
            $0.archiveFilename.lowercased().contains(q) ||
            $0.relPath.lowercased().contains(q) ||
            $0.peopleText.lowercased().contains(q)
        })
    }
}
