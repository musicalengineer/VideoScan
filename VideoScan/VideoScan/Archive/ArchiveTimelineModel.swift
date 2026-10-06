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
    /// The other versions folded into this card (ArchiveItemVersions),
    /// this card's own file included. Empty = a single-file item.
    var versions: [ArchiveItemVersion] = []
    /// The catalog's lineage link (VideoRecord.derivedFrom) — the asset
    /// this one was made from — when the catalog knows it. Promotion
    /// links (archive copy → source) are NOT passed here: those are the
    /// same item, not a version. An established relationship; version
    /// grouping prefers it over name heuristics (codex #1644).
    var derivedFromID: UUID? = nil
    /// VideoRecord.derivationKind for `derivedFromID` ("balanceAudio",
    /// "trim", …) — names the chip when the filename does not.
    var derivationKind: String? = nil

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
        // Date prefix: YYYY(-MM|-xx)(-DD|-xx) followed by _ or space — every
        // one of them ("1990-xx-xx_1990-xx-xx_Christmas" → "Christmas";
        // promote once doubled the prefix).
        let stem = ArchiveItemVersions.stripDatePrefixes((name as NSString).deletingPathExtension)
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
    func contains(_ id: UUID) -> Bool { cardID(for: id) != nil }

    /// The card that shows `id` — itself, or the card a version of it is
    /// folded into (a hand-off to "…cleaned" lands on its item's card).
    func cardID(for id: UUID) -> UUID? {
        func hit(_ item: ArchiveTimelineItem) -> Bool {
            item.id == id || item.versions.contains { $0.id == id }
        }
        if let c = undated.first(where: hit) { return c.id }
        for d in decades {
            for y in d.years {
                if let c = y.items.first(where: hit) { return c.id }
            }
        }
        return nil
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
            $0.peopleText.lowercased().contains(q) ||
            $0.versions.contains { $0.archiveFilename.lowercased().contains(q) || $0.label.contains(q) }
        })
    }
}

// MARK: - Decade ribbon (horizontal timeline navigation, Rick 2026-10-06)
//
// The Archive tab walks the family archive by decade: a horizontal ribbon
// of decades across the top (ArchiveDecadeRibbon.swift) and, below it, one
// decade's years. Everything the ribbon needs is derived HERE, once per
// data change (memoised by ArchiveView), so hovering the ribbon costs
// O(decades) per frame — never O(items).

/// One decade (or the Undated shelf) on the ribbon.
struct ArchiveDecadeTick: Identifiable, Equatable {
    /// Page id of the Undated shelf. Decade ids are their first year.
    static let undatedID = -1

    /// Decade start (1990) or `undatedID`.
    let id: Int
    let label: String
    /// Cards on this page (after search narrowing).
    let count: Int
    /// Years in this decade that hold at least one card — the dwell-zoom
    /// row dims the other years.
    let yearsWithMedia: Set<Int>

    var isUndated: Bool { id == Self.undatedID }
    var isGap: Bool { count == 0 }
    /// The ten years of the decade, in order; none for Undated.
    var years: [Int] { isUndated ? [] : Array(id...(id + 9)) }

    /// O(decades × 10). Undated, when present, is the last tick.
    static func ticks(for timeline: ArchiveTimeline) -> [ArchiveDecadeTick] {
        var out = timeline.decades.map { d in
            ArchiveDecadeTick(id: d.start, label: d.label, count: d.count,
                              yearsWithMedia: Set(d.years.map(\.year)))
        }
        if !timeline.undated.isEmpty {
            out.append(ArchiveDecadeTick(id: undatedID, label: "Undated",
                                         count: timeline.undated.count, yearsWithMedia: []))
        }
        return out
    }
}

/// The timeline plus its ribbon ticks, built together once per data
/// change (records version + search text) and memoised by ArchiveView.
struct ArchiveTimelineSnapshot: Equatable {
    var timeline = ArchiveTimeline()
    var ticks: [ArchiveDecadeTick] = []

    var isEmpty: Bool { timeline.isEmpty }

    /// O(n log n) in archived items — the grouping. Never call from a
    /// view body except through the memo.
    static func build(items: [ArchiveTimelineItem], matching query: String) -> ArchiveTimelineSnapshot {
        let tl = ArchiveTimeline.build(items: items, matching: query)
        return ArchiveTimelineSnapshot(timeline: tl, ticks: ArchiveDecadeTick.ticks(for: tl))
    }

    /// The page to show: the user's pick while it is still on the ribbon,
    /// else the oldest decade that holds media (a chronicle starts at the
    /// beginning), else whatever exists. Nil only when empty.
    func page(selected: Int?) -> Int? {
        if let s = selected, ticks.contains(where: { $0.id == s }) { return s }
        return ticks.first(where: { !$0.isGap })?.id ?? ticks.first?.id
    }

    /// Which page shows the card for `id` (an item or one of its folded
    /// versions) — a hand-off lands on the right decade. O(archived).
    func page(containing id: UUID) -> Int? {
        func hit(_ item: ArchiveTimelineItem) -> Bool {
            item.id == id || item.versions.contains { $0.id == id }
        }
        if timeline.undated.contains(where: hit) { return ArchiveDecadeTick.undatedID }
        for d in timeline.decades where d.years.contains(where: { $0.items.contains(where: hit) }) {
            return d.start
        }
        return nil
    }
}

/// Dock-style magnification for the ribbon: each decade's scale follows
/// its distance from the pointer, a smooth raised-cosine falloff from
/// `maxScale` under the pointer to 1 at `radius`.
enum ArchiveRibbonMagnifier {
    static let maxScale = 1.6
    /// Reach of the bulge, in ribbon slots (the Dock's is ~2–3 icons).
    static let radiusInSlots = 2.5

    /// `distance` and `radius` in the same units (points or slots).
    static func scale(distance: Double, radius: Double) -> Double {
        guard radius > 0, distance.isFinite else { return 1 }
        let d = abs(distance)
        guard d < radius else { return 1 }
        let falloff = (cos(Double.pi * d / radius) + 1) / 2   // 1 at the pointer, 0 at the edge
        return 1 + (maxScale - 1) * falloff
    }
}
