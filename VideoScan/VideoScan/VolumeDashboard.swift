// VolumeDashboard.swift
// The arithmetic behind the per-volume dashboard in the Storage tab
// (Rick 2026-08-19: "click a drive → volume info on top, pretty charts
// below — what's on each volume, easy to see lots of info").
//
// One O(n) pass over Sendable projections of the records that live under
// ONE scan target, producing the series the dashboard cards draw:
//
//   * kind      — container/extension           (donut)
//   * streams   — video+audio / video-only / …  (donut)
//   * decade    — by best date                  (bars, chronological)
//   * year      — by best date                  (bars; Master Archive)
//   * review    — MediaDisposition              (computed; not drawn today)
//   * archive   — archived / reviewed / not yet  (donut, fixed order/colors)
//   * copies    — copies known elsewhere        (donut: none / 1 / 2+)
//   * folders   — top-level folders by size     (horizontal bars, top 8)
//   * capacity  — cataloged bytes vs the volume's capacity (gauge)
//
// Same contract as MediaDistribution.swift: pure, `nonisolated`, no I/O,
// budgeted for 100k records. The view projects on the main actor and
// aggregates in a detached task. Kind/streams/decade reuse
// `MediaDistributionCalculator`'s labels so the words match the
// "Where media lives" sheet.

import Foundation
import SwiftUI

// MARK: - Input projection

/// The facts the dashboard needs from one record. Value type so it can
/// cross to a background task (`VideoRecord` is a main-actor class).
struct VolumeDashboardInput: Sendable, Equatable {
    var fullPath: String
    var sizeBytes: Int64
    var isManuallyDeleted: Bool
    var ext: String
    var streamTypeRaw: String
    var bestDate: Date?
    var dispositionRaw: String
    /// Copies of this file known to exist on OTHER volumes: verified
    /// backup entries, or duplicate-analysis siblings (group count − 1),
    /// whichever is larger.
    var copiesElsewhere: Int
    var starRating: Int
    /// Master Archive: this record IS a promoted copy (`derivationKind ==
    /// ArchivePromotion.derivationKind`), and whether its fixity has been
    /// verified (`archiveFixity != nil`).
    var isPromotedCopy: Bool
    var fixityVerified: Bool
    /// Archive progress for THIS file: promoted to the Master Archive (or
    /// the archived copy itself), or at least reviewed in Triage.
    var isArchived: Bool
    var isReviewed: Bool

    var streamType: StreamType { StreamType(rawValue: streamTypeRaw) ?? .ffprobeFailed }
    var disposition: MediaDisposition { MediaDisposition(rawValue: dispositionRaw) ?? .unreviewed }

    init(fullPath: String,
         sizeBytes: Int64,
         isManuallyDeleted: Bool = false,
         ext: String = "",
         streamType: StreamType = .videoAndAudio,
         bestDate: Date? = nil,
         disposition: MediaDisposition = .unreviewed,
         copiesElsewhere: Int = 0,
         starRating: Int = 0,
         isPromotedCopy: Bool = false,
         fixityVerified: Bool = false,
         isArchived: Bool = false,
         isReviewed: Bool = false) {
        self.fullPath = fullPath
        self.sizeBytes = sizeBytes
        self.isManuallyDeleted = isManuallyDeleted
        self.ext = ext
        self.streamTypeRaw = streamType.rawValue
        self.bestDate = bestDate
        self.dispositionRaw = disposition.rawValue
        self.copiesElsewhere = copiesElsewhere
        self.starRating = starRating
        self.isPromotedCopy = isPromotedCopy
        self.fixityVerified = fixityVerified
        self.isArchived = isArchived
        self.isReviewed = isReviewed
    }
}

// MARK: - Result

/// One bar / one sector: a category with its byte and file tallies and
/// a display color chosen by the calculator (semantic for review/copies,
/// palette-slot for the open-ended dimensions).
struct VolumeDashboardSlice: Identifiable, Sendable, Equatable {
    var name: String
    var bytes: Int64
    var files: Int
    /// Palette slot for open-ended dimensions (kind/streams/folders);
    /// nil when `fixedColor` carries a semantic color instead.
    var colorSlot: Int?
    var fixedColor: VolumeDashboardColor?
    var isOther: Bool = false
    var id: String { name }
}

/// Scheme-independent semantic colors the calculator can pin to a slice.
/// Resolved to SwiftUI colors by the view (the calculator stays free of
/// `@Environment(\.colorScheme)`).
enum VolumeDashboardColor: Sendable, Equatable {
    case gray, blue, teal, orange, red, green, yellow, purple, secondary
}

/// A whole series — the slices plus totals, for one card.
struct VolumeDashboardSeries: Sendable, Equatable {
    var slices: [VolumeDashboardSlice] = []
    var totalBytes: Int64 = 0
    var totalFiles: Int = 0

    func percent(of slice: VolumeDashboardSlice, by measure: MediaDistributionMeasure) -> Double {
        switch measure {
        case .size:
            guard totalBytes > 0 else { return 0 }
            return Double(slice.bytes) / Double(totalBytes) * 100
        case .files:
            guard totalFiles > 0 else { return 0 }
            return Double(slice.files) / Double(totalFiles) * 100
        }
    }
}

/// Everything the dashboard draws for one volume.
struct VolumeDashboardStats: Sendable, Equatable {
    var totalBytes: Int64 = 0
    var totalFiles: Int = 0
    var totalSeconds: Double = 0
    var kind = VolumeDashboardSeries()
    var streams = VolumeDashboardSeries()
    var decade = VolumeDashboardSeries()
    var year = VolumeDashboardSeries()
    var review = VolumeDashboardSeries()
    var copies = VolumeDashboardSeries()
    var folders = VolumeDashboardSeries()
    var stars = VolumeDashboardSeries()
    /// Archive progress: Archived / Reviewed, not archived / Not yet reviewed.
    var archive = VolumeDashboardSeries()
    /// Master Archive only: promoted copies, verified vs not yet verified.
    var fixity = VolumeDashboardSeries()
    /// Records that are gone from every drive (`manuallyDeleted`) —
    /// excluded from the charts, reported in the footer.
    var deletedFiles: Int = 0
    var computedAt: Date = Date(timeIntervalSince1970: 0)

    var isEmpty: Bool { totalFiles == 0 }
}

// MARK: - Calculator

enum VolumeDashboardCalculator {

    static let maxSlices = MediaDistributionCalculator.maxSlices
    static let maxFolders = 8
    static let otherName = MediaDistributionCalculator.otherName
    static let undatedName = MediaDistributionCalculator.undatedName
    static let rootFolderName = "(top level)"

    // MARK: Projection (main actor side)

    /// Project the records that live under `searchPath` into Sendable
    /// rows. Applies `pfActiveRecords` (drops purged / set-aside /
    /// superseded) — the same "present" definition every other feature
    /// surface uses. `searchPath` matching is prefix-by-component so
    /// `/Volumes/X9` does not claim `/Volumes/X9-Matt`.
    static func project(_ records: [VideoRecord], under searchPath: String) -> [VolumeDashboardInput] {
        let root = normalizedRoot(searchPath)
        guard !root.isEmpty else { return [] }
        let active = pfActiveRecords(records)
        var out: [VolumeDashboardInput] = []
        out.reserveCapacity(min(active.count, 4096))
        for r in active where isUnder(r.fullPath, root: root) {
            let dupSiblings = max(0, r.duplicateGroupCount - 1)
            out.append(VolumeDashboardInput(
                fullPath: r.fullPath,
                sizeBytes: r.sizeBytes,
                isManuallyDeleted: r.archiveStage == .manuallyDeleted,
                ext: r.ext,
                streamType: r.streamType,
                bestDate: r.inferredRecordDate ?? r.embeddedCreationDate ?? r.dateCreatedRaw,
                disposition: r.mediaDisposition,
                copiesElsewhere: max(r.backupDestinations.count, dupSiblings),
                starRating: r.starRating,
                isPromotedCopy: r.derivationKind == ArchivePromotion.derivationKind,
                fixityVerified: r.archiveFixity != nil,
                // Promote stamps the SOURCE `.masterAssigned` and the copy
                // `.archived`; the Triage "Archive" button sets `.archived`.
                isArchived: r.lifecycleStage == .archived
                    || r.archiveStage == .masterAssigned
                    || r.archiveStage == .archived,
                isReviewed: r.mediaDisposition != .unreviewed))
        }
        return out
    }

    /// `/Volumes/X9/` → `/Volumes/X9`; `/` stays `/`.
    static func normalizedRoot(_ path: String) -> String {
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// Component-wise prefix test: `path == root` or `path` starts with
    /// `root + "/"` (root `/` matches everything).
    static func isUnder(_ path: String, root: String) -> Bool {
        if root == "/" { return path.hasPrefix("/") }
        guard path.hasPrefix(root) else { return false }
        if path.count == root.count { return true }
        let idx = path.index(path.startIndex, offsetBy: root.count)
        return path[idx] == "/"
    }

    /// First path component below the root: the record's top-level
    /// folder on this volume. Files sitting directly in the root →
    /// "(top level)".
    static func topFolder(of path: String, root: String) -> String {
        guard isUnder(path, root: root) else { return rootFolderName }
        let rel: Substring
        if root == "/" {
            rel = path.dropFirst(1)
        } else {
            rel = path.dropFirst(root.count + 1)
        }
        guard let slash = rel.firstIndex(of: "/") else { return rootFolderName }   // file at root
        let first = rel[rel.startIndex..<slash]
        return first.isEmpty ? rootFolderName : String(first)
    }

    // MARK: Entry point

    /// Aggregate one volume's projections. `root` is the scan target's
    /// search path (for the folders series); `now` is an injected clock.
    static func compute(inputs: [VolumeDashboardInput],
                        root: String,
                        now: Date = Date()) -> VolumeDashboardStats {
        var s = VolumeDashboardStats()
        s.computedAt = now
        let root = normalizedRoot(root)

        struct Acc { var bytes: Int64 = 0; var files: Int = 0 }
        var kind: [String: Acc] = [:]
        var streams: [String: Acc] = [:]
        var decade: [String: Acc] = [:]
        var year: [String: Acc] = [:]
        var review: [MediaDisposition: Acc] = [:]
        var copies: [Int: Acc] = [:]      // 0, 1, 2 (= 2+)
        var folders: [String: Acc] = [:]
        var stars: [Int: Acc] = [:]       // 0…3
        var fixity: [Bool: Acc] = [:]     // fixityVerified
        var archive: [Int: Acc] = [:]     // 0 archived, 1 reviewed, 2 not yet

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0) ?? .current

        func bump(_ acc: inout Acc, _ bytes: Int64) { acc.bytes += bytes; acc.files += 1 }

        for row in inputs {
            if row.isManuallyDeleted { s.deletedFiles += 1; continue }
            let bytes = max(0, row.sizeBytes)
            s.totalBytes += bytes
            s.totalFiles += 1

            bump(&kind[MediaDistributionCalculator.kindLabel(forExtension: row.ext), default: Acc()], bytes)
            bump(&streams[MediaDistributionCalculator.streamsLabel(for: row.streamType), default: Acc()], bytes)
            bump(&decade[MediaDistributionCalculator.decadeLabel(for: row.bestDate), default: Acc()], bytes)
            let yearLabel = row.bestDate.map { String(cal.component(.year, from: $0)) } ?? undatedName
            bump(&year[yearLabel, default: Acc()], bytes)
            bump(&review[row.disposition, default: Acc()], bytes)
            bump(&copies[min(2, max(0, row.copiesElsewhere)), default: Acc()], bytes)
            bump(&folders[topFolder(of: row.fullPath, root: root), default: Acc()], bytes)
            bump(&stars[min(3, max(0, row.starRating)), default: Acc()], bytes)
            if row.isPromotedCopy { bump(&fixity[row.fixityVerified, default: Acc()], bytes) }
            bump(&archive[row.isArchived ? 0 : (row.isReviewed ? 1 : 2), default: Acc()], bytes)
        }

        s.kind = paletteSeries(kind.map { ($0.key, $0.value.bytes, $0.value.files) }, maxSlices: maxSlices)
        s.streams = paletteSeries(streams.map { ($0.key, $0.value.bytes, $0.value.files) }, maxSlices: maxSlices)
        s.folders = paletteSeries(folders.map { ($0.key, $0.value.bytes, $0.value.files) }, maxSlices: maxFolders)
        s.decade = chronologicalSeries(decade.map { ($0.key, $0.value.bytes, $0.value.files) })
        s.year = chronologicalSeries(year.map { ($0.key, $0.value.bytes, $0.value.files) })

        // Review: fixed triage order + the Triage tab's colors.
        s.review = fixedSeries(MediaDisposition.allCases.compactMap { d -> VolumeDashboardSlice? in
            guard let acc = review[d] else { return nil }
            return VolumeDashboardSlice(name: reviewLabel(d), bytes: acc.bytes, files: acc.files,
                                        colorSlot: nil, fixedColor: reviewColor(d))
        })
        // Copies: at-risk first, so the legend reads as a safety ladder.
        s.copies = fixedSeries([0, 1, 2].compactMap { n -> VolumeDashboardSlice? in
            guard let acc = copies[n] else { return nil }
            return VolumeDashboardSlice(name: copiesLabel(n), bytes: acc.bytes, files: acc.files,
                                        colorSlot: nil, fixedColor: copiesColor(n))
        })
        // Stars: unrated, ★, ★★, ★★★.
        s.stars = fixedSeries([0, 1, 2, 3].compactMap { n -> VolumeDashboardSlice? in
            guard let acc = stars[n] else { return nil }
            return VolumeDashboardSlice(name: starsLabel(n), bytes: acc.bytes, files: acc.files,
                                        colorSlot: nil, fixedColor: starsColor(n))
        })
        s.archive = fixedSeries([0, 1, 2].compactMap { n -> VolumeDashboardSlice? in
            guard let acc = archive[n] else { return nil }
            return VolumeDashboardSlice(name: archiveLabel(n), bytes: acc.bytes, files: acc.files,
                                        colorSlot: nil, fixedColor: archiveColor(n))
        })
        s.fixity = fixedSeries([true, false].compactMap { v -> VolumeDashboardSlice? in
            guard let acc = fixity[v] else { return nil }
            return VolumeDashboardSlice(name: v ? "Verified" : "Not yet verified",
                                        bytes: acc.bytes, files: acc.files,
                                        colorSlot: nil, fixedColor: v ? .green : .orange)
        })
        return s
    }

    // MARK: Series builders

    /// Open-ended categories: rank by bytes, fold the tail into "Other"
    /// past `maxSlices`, color slot by ALPHABETICAL name so a kind keeps
    /// its color across volumes and across Size ↔ Files flips.
    static func paletteSeries(_ entries: [(name: String, bytes: Int64, files: Int)],
                              maxSlices: Int) -> VolumeDashboardSeries {
        var ranked = entries.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.name < $1.name }
        var other: VolumeDashboardSlice? = nil
        if ranked.count > maxSlices {
            let keep = max(1, maxSlices - 1)
            let tail = ranked[keep...]
            other = VolumeDashboardSlice(name: otherName,
                                         bytes: tail.reduce(0) { $0 + $1.bytes },
                                         files: tail.reduce(0) { $0 + $1.files },
                                         colorSlot: nil, fixedColor: .gray, isOther: true)
            ranked = Array(ranked[..<keep])
        }
        let slotByName = Dictionary(uniqueKeysWithValues:
            ranked.map(\.name).sorted().enumerated().map { ($1, $0) })
        var slices = ranked.map {
            VolumeDashboardSlice(name: $0.name, bytes: $0.bytes, files: $0.files,
                                 colorSlot: slotByName[$0.name], fixedColor: nil)
        }
        if let other { slices.append(other) }
        return VolumeDashboardSeries(slices: slices,
                                     totalBytes: entries.reduce(0) { $0 + $1.bytes },
                                     totalFiles: entries.reduce(0) { $0 + $1.files })
    }

    /// Decade / year labels sorted chronologically ("Undated" last);
    /// color slot follows chronological rank so bars read as a ramp.
    static func chronologicalSeries(_ entries: [(name: String, bytes: Int64, files: Int)]) -> VolumeDashboardSeries {
        let sorted = entries.sorted { a, b in
            if a.name == undatedName { return false }
            if b.name == undatedName { return true }
            return a.name < b.name
        }
        let slices = sorted.enumerated().map { i, e in
            VolumeDashboardSlice(name: e.name, bytes: e.bytes, files: e.files,
                                 colorSlot: e.name == undatedName ? nil : i,
                                 fixedColor: e.name == undatedName ? .gray : nil)
        }
        return VolumeDashboardSeries(slices: slices,
                                     totalBytes: entries.reduce(0) { $0 + $1.bytes },
                                     totalFiles: entries.reduce(0) { $0 + $1.files })
    }

    static func fixedSeries(_ slices: [VolumeDashboardSlice]) -> VolumeDashboardSeries {
        VolumeDashboardSeries(slices: slices,
                              totalBytes: slices.reduce(0) { $0 + $1.bytes },
                              totalFiles: slices.reduce(0) { $0 + $1.files })
    }

    // MARK: Labels & semantic colors

    /// Human words for the review buckets — the Triage tab's vocabulary
    /// plus "Undecided" for unreviewed (feedback_friendly_language).
    static func reviewLabel(_ d: MediaDisposition) -> String {
        switch d {
        case .unreviewed:    return "Undecided"
        case .important:     return "Keep"
        case .recoverable:   return "Needs repair"
        case .suspectedJunk: return "Suspected junk"
        case .confirmedJunk: return "Junk"
        }
    }
    static func reviewColor(_ d: MediaDisposition) -> VolumeDashboardColor {
        switch d {
        case .unreviewed:    return .secondary
        case .important:     return .blue
        case .recoverable:   return .teal
        case .suspectedJunk: return .orange
        case .confirmedJunk: return .red
        }
    }
    static func copiesLabel(_ n: Int) -> String {
        switch n {
        case 0:  return "Only copy is here"
        case 1:  return "1 copy elsewhere"
        default: return "2+ copies elsewhere"
        }
    }
    static func copiesColor(_ n: Int) -> VolumeDashboardColor {
        switch n {
        case 0:  return .red
        case 1:  return .orange
        default: return .green
        }
    }
    static func archiveLabel(_ n: Int) -> String {
        switch n {
        case 0:  return "Archived"
        case 1:  return "Reviewed, not archived"
        default: return "Not yet reviewed"
        }
    }
    static func archiveColor(_ n: Int) -> VolumeDashboardColor {
        switch n {
        case 0:  return .green
        case 1:  return .blue
        default: return .secondary
        }
    }
    static func starsLabel(_ n: Int) -> String {
        n == 0 ? "Unrated" : String(repeating: "★", count: n)
    }
    static func starsColor(_ n: Int) -> VolumeDashboardColor {
        switch n {
        case 0:  return .secondary
        case 1:  return .teal
        case 2:  return .blue
        default: return .yellow
        }
    }
}
