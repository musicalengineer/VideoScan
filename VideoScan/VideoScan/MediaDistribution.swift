// MediaDistribution.swift
// The arithmetic behind "Where media lives" — the donut chart in the
// Volumes window toolbar (Rick, 2026-08-18: after moving the library off
// the slow LaCie spindle he wants to SEE the new distribution).
//
//     ┌───────────────────────────────────────────────────────────┐
//     │        ╭──────╮        ■ FamilyArchive   3.1 TB  52%  4,102 │
//     │      ╭─╯      ╰─╮      ■ MediaExpansion  1.2 TB  20%    137 │
//     │      │  5.9 TB  │      ■ Mac (home)      0.9 TB  15%  1,880 │
//     │      ╰─╮ 7,795 ╭─╯     ■ X9              0.5 TB   8%  1,010 │
//     │        ╰──────╯        ■ Other           0.2 TB   5%    666 │
//     └───────────────────────────────────────────────────────────┘
//
// WHAT COUNTS. Present, non-purged records only (`pfActiveRecords`),
// minus two honest exclusions:
//   * `archiveStage == .manuallyDeleted` — the file is gone from every
//     drive; it does not "live" anywhere.
//   * records under a RETIRED scan target — the drive is in a drawer.
//     Their bytes are tallied separately (`retiredBytes`) so the sheet
//     can say "Retired drives hold X GB (not shown)" instead of quietly
//     omitting them.
//
// GROUPING. ONE aggregation, parameterized by a `MediaDistributionDimension`
// (Rick 2026-08-18 addition — "make the pie a general distribution view"):
//   * volume  — `/Volumes/<name>`; anything under `/Users` → "Mac (home)"
//   * kind    — container/extension, lowercased ("mov", "mxf", …)
//   * streams — video+audio / video-only / audio-only / no streams
//               (the MXF A/V-halves picture)
//   * decade  — from the record's best date; "Undated" when nil
// More than `maxSlices` categories → the smallest fold into "Other" and
// the largest `maxSlices - 1` keep their names.
//
// COLOR FOLLOWS THE ENTITY. Each named slice gets a fixed palette slot
// assigned by ALPHABETICAL category name — not by size rank — so a volume
// keeps its color when the sizes shift after a migration (and a kind or
// decade keeps its color when you flip Size ↔ Files). "Other" is
// always system gray. The chart's `chartForegroundStyleScale(domain:
// range:)` and the legend swatches read the same slot, so they agree
// by construction.
//
// COST. One O(n) pass over lightweight `Sendable` projections plus a
// dictionary group-by, no disk I/O. Budgeted at 100k records (< 0.5 s)
// by MediaDistributionTests. Memory: one ~48-byte projection per active
// record (~5 MB at 100k), freed on return. The sheet projects on the
// main actor and aggregates in a detached task — `VideoRecord` is a
// non-Sendable class, and the projection is what lets the heavy step
// leave the UI thread.
//
// All functions `nonisolated` and pure — same testability contract as
// CatalogStorageTotals.swift. (Swift `enum` with only static members ≈
// a C++ namespace: no instances, just a scoping shell for free functions.)

import Foundation
import SwiftUI

// MARK: - Input projection

/// The facts the aggregation needs from a record — one per dimension
/// plus size and the deleted flag. A plain value type so it can cross
/// to a background task — `VideoRecord` itself is a class the main
/// actor owns.
struct MediaDistributionInput: Sendable, Equatable {
    var fullPath: String
    var sizeBytes: Int64
    var isManuallyDeleted: Bool
    /// Extension as stored (production uppercases it); lowercased at
    /// grouping time.
    var ext: String
    /// Stored as the raw string because `StreamType` (VideoScanCore)
    /// is not declared Sendable; `streamType` re-derives the enum.
    var streamTypeRaw: String
    var streamType: StreamType { StreamType(rawValue: streamTypeRaw) ?? .ffprobeFailed }
    /// Best available date: `inferredRecordDate ?? embeddedCreationDate
    /// ?? dateCreatedRaw`. nil → "Undated".
    var bestDate: Date?

    init(fullPath: String,
         sizeBytes: Int64,
         isManuallyDeleted: Bool = false,
         ext: String = "",
         streamType: StreamType = .videoAndAudio,
         bestDate: Date? = nil) {
        self.fullPath = fullPath
        self.sizeBytes = sizeBytes
        self.isManuallyDeleted = isManuallyDeleted
        self.ext = ext
        self.streamTypeRaw = streamType.rawValue
        self.bestDate = bestDate
    }
}

/// What the donut groups by. Raw values are the persisted form
/// (UserDefaults, see MediaDistributionSheet).
enum MediaDistributionDimension: String, CaseIterable, Identifiable, Sendable {
    case volume, kind, streams, decade
    var id: String { rawValue }

    /// Segmented-control label.
    var title: String {
        switch self {
        case .volume:  return "Drive"
        case .kind:    return "Kind"
        case .streams: return "Streams"
        case .decade:  return "Decade"
        }
    }
    /// The header line's suffix: "Where media lives — by drive".
    var headerPhrase: String {
        switch self {
        case .volume:  return "by drive"
        case .kind:    return "by kind"
        case .streams: return "by streams"
        case .decade:  return "by decade"
        }
    }
    /// Legend column heading for the category.
    var legendHeading: String {
        switch self {
        case .volume:  return "Drive"
        case .kind:    return "Kind"
        case .streams: return "Streams"
        case .decade:  return "Decade"
        }
    }
}

// MARK: - Result

/// One slice of the donut / one row of the legend.
struct MediaDistributionSlice: Identifiable, Sendable, Equatable {
    /// Display name — the category label (volume name / "Mac (home)",
    /// "mov", "Video only", "1990s", "Undated") or "Other".
    var name: String
    var bytes: Int64
    var files: Int
    /// True for the folded "Other" slice — always drawn system gray.
    var isOther: Bool
    /// Palette slot (0..<maxSlices) for named slices; nil for Other.
    var colorSlot: Int?
    /// Volume dimension only: nil = no scan target claims this volume,
    /// so we can't say. Always nil for the other dimensions.
    var isReachable: Bool?
    /// Number of categories folded into this slice (1 for a named slice).
    var foldedVolumeCount: Int = 1

    var id: String { name }
}

/// The complete answer for one catalog revision. Value type, `Equatable`
/// so SwiftUI can skip redundant redraws.
struct MediaDistribution: Sendable, Equatable {
    var dimension: MediaDistributionDimension = .volume
    /// Sorted by bytes descending; "Other" (if any) is always last.
    var slices: [MediaDistributionSlice] = []
    var totalBytes: Int64 = 0
    var totalFiles: Int = 0
    /// Bytes / records excluded because they sit under a retired target.
    var retiredBytes: Int64 = 0
    var retiredFiles: Int = 0
    /// Records considered (active, non-deleted, non-retired) — the "N
    /// records" in the footer.
    var recordCount: Int { totalFiles }
    var computedAt: Date = Date(timeIntervalSince1970: 0)

    /// Domain for `chartForegroundStyleScale` — named slices sorted by
    /// name (their slot order), then "Other".
    var colorDomain: [String] {
        let named = slices.filter { !$0.isOther }
            .sorted { ($0.colorSlot ?? .max) < ($1.colorSlot ?? .max) }
            .map(\.name)
        return slices.contains(where: \.isOther) ? named + [MediaDistributionCalculator.otherName] : named
    }

    func percent(of slice: MediaDistributionSlice, by measure: MediaDistributionMeasure) -> Double {
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

/// What the donut's angle measures. Bound to the sheet's segmented control.
enum MediaDistributionMeasure: String, CaseIterable, Identifiable, Sendable {
    case size = "Size"
    case files = "Files"
    var id: String { rawValue }
}

// MARK: - Calculator

enum MediaDistributionCalculator {

    /// Maximum slices including "Other". Matches the palette size.
    static let maxSlices = 8
    static let otherName = "Other"
    static let homeName = "Mac (home)"
    static let undatedName = "Undated"
    static let noExtensionName = "no extension"

    // MARK: Palette
    //
    // Eight categorical slots, validated colorblind-safe (Rick's spec
    // 2026-08-18). Light and dark variants; the sheet picks by
    // `@Environment(\.colorScheme)`.
    static let lightPalette: [Color] = [
        Color(hexRGB: 0x2a78d6), Color(hexRGB: 0xeb6834), Color(hexRGB: 0x1baf7a),
        Color(hexRGB: 0xeda100), Color(hexRGB: 0xe87ba4), Color(hexRGB: 0x008300),
        Color(hexRGB: 0x4a3aa7), Color(hexRGB: 0xe34948),
    ]
    static let darkPalette: [Color] = [
        Color(hexRGB: 0x3987e5), Color(hexRGB: 0xd95926), Color(hexRGB: 0x199e70),
        Color(hexRGB: 0xc98500), Color(hexRGB: 0xd55181), Color(hexRGB: 0x008300),
        Color(hexRGB: 0x9085e9), Color(hexRGB: 0xe66767),
    ]

    static func palette(for scheme: ColorScheme) -> [Color] {
        scheme == .dark ? darkPalette : lightPalette
    }

    /// Color for one slice. Other → gray; a slot beyond the palette
    /// (cannot happen with `maxSlices == palette.count`, but be safe)
    /// wraps rather than crashing.
    static func color(for slice: MediaDistributionSlice, scheme: ColorScheme) -> Color {
        guard let slot = slice.colorSlot, !slice.isOther else { return .gray }
        let p = palette(for: scheme)
        return p[slot % p.count]
    }

    /// Range for `chartForegroundStyleScale`, aligned with
    /// `MediaDistribution.colorDomain`.
    static func colorRange(for distribution: MediaDistribution, scheme: ColorScheme) -> [Color] {
        distribution.colorDomain.map { name in
            if name == otherName { return .gray }
            let slot = distribution.slices.first { $0.name == name }?.colorSlot ?? 0
            return palette(for: scheme)[slot % palette(for: scheme).count]
        }
    }

    // MARK: Grouping

    /// Volume label for a path: `/Volumes/<X>/…` → "X"; anything under
    /// `/Users` → "Mac (home)"; other absolute paths → their top-level
    /// directory (matches `VolumeReachability.volumeName(forPath:)`).
    static func volumeLabel(forPath path: String) -> String {
        let comps = (path as NSString).pathComponents
        if comps.count >= 2, comps[1] == "Users" { return homeName }
        return VolumeReachability.volumeName(forPath: path)
    }

    /// Kind = container/extension, lowercased. Empty → "no extension"
    /// (the app's whole recovery mission is extensionless Avid essence,
    /// so that bucket is a real category, not an error).
    static func kindLabel(forExtension ext: String) -> String {
        let e = ext.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return e.isEmpty ? noExtensionName : e
    }

    /// Streams = the four shapes ffprobe reports, plus a bucket for the
    /// files it couldn't read at all.
    static func streamsLabel(for type: StreamType) -> String {
        switch type {
        case .videoAndAudio: return "Video + audio"
        case .videoOnly:     return "Video only"
        case .audioOnly:     return "Audio only"
        case .noStreams:     return "No streams"
        case .ffprobeFailed: return "Unreadable"
        }
    }

    /// Decade = "1990s" from the best date; nil → "Undated". Gregorian,
    /// current-timezone year — the label is a decade, so the ±1-day
    /// timezone edge cannot move a record's bucket except on Jan 1 of a
    /// decade boundary, which is noise at this granularity.
    static func decadeLabel(for date: Date?) -> String {
        guard let date else { return undatedName }
        let year = Calendar(identifier: .gregorian).component(.year, from: date)
        return "\((year / 10) * 10)s"
    }

    /// The single key extractor every dimension routes through.
    /// (A closure-free `switch` rather than a stored closure so the
    /// aggregation stays trivially `Sendable`.)
    static func key(for row: MediaDistributionInput, dimension: MediaDistributionDimension) -> String {
        switch dimension {
        case .volume:  return volumeLabel(forPath: row.fullPath)
        case .kind:    return kindLabel(forExtension: row.ext)
        case .streams: return streamsLabel(for: row.streamType)
        case .decade:  return decadeLabel(for: row.bestDate)
        }
    }

    // MARK: Projection (main actor side)

    /// Project the catalog into Sendable rows. Applies `pfActiveRecords`
    /// (drops purged / set-aside / superseded) — the same "present"
    /// definition every other feature surface uses.
    static func project(_ records: [VideoRecord]) -> [MediaDistributionInput] {
        let active = pfActiveRecords(records)
        var out: [MediaDistributionInput] = []
        out.reserveCapacity(active.count)
        for r in active {
            out.append(MediaDistributionInput(
                fullPath: r.fullPath,
                sizeBytes: r.sizeBytes,
                isManuallyDeleted: r.archiveStage == .manuallyDeleted,
                ext: r.ext,
                streamType: r.streamType,
                // Best date: consensus inference first, then the
                // container's own stamp (survives copies), then the
                // filesystem birth time (reset by every copy).
                bestDate: r.inferredRecordDate ?? r.embeddedCreationDate ?? r.dateCreatedRaw))
        }
        return out
    }

    // MARK: Entry point

    /// Aggregate projections into slices.
    ///
    /// - Parameters:
    ///   - inputs: projected records (already `pfActiveRecords`-filtered
    ///     when they come from `project(_:)`).
    ///   - dimension: what to group by (see `MediaDistributionDimension`).
    ///   - retiredPrefixes: `searchPath`s of retired scan targets. Any
    ///     record under one is excluded from the chart and tallied into
    ///     `retiredBytes` / `retiredFiles`.
    ///   - reachableVolumes: labels of volumes reachable right now, and
    ///     `knownVolumes` the labels any scan target claims. Both derived
    ///     by the CALLER from cached target state — reachability is
    ///     filesystem I/O and must never run inside an O(records) loop.
    ///     A volume in neither set gets `isReachable == nil`.
    ///   - now: injected clock for deterministic tests.
    static func compute(
        inputs: [MediaDistributionInput],
        dimension: MediaDistributionDimension = .volume,
        retiredPrefixes: [String] = [],
        reachableVolumes: Set<String> = [],
        knownVolumes: Set<String> = [],
        maxSlices: Int = MediaDistributionCalculator.maxSlices,
        now: Date = Date()
    ) -> MediaDistribution {
        var d = MediaDistribution()
        d.dimension = dimension
        d.computedAt = now

        // Retired prefixes normalized once; empty ones would match
        // everything via hasPrefix("").
        let retired = retiredPrefixes.filter { !$0.isEmpty }

        // Group-by pass. Value struct accumulators in a dictionary keyed
        // by label — the only per-volume allocation.
        struct Acc { var bytes: Int64 = 0; var files: Int = 0 }
        var groups: [String: Acc] = [:]
        groups.reserveCapacity(16)

        for row in inputs {
            if row.isManuallyDeleted { continue }
            let bytes = max(0, row.sizeBytes)   // negative size = corrupt metadata, not a credit
            if !retired.isEmpty, retired.contains(where: { row.fullPath.hasPrefix($0) }) {
                d.retiredBytes += bytes
                d.retiredFiles += 1
                continue
            }
            let label = key(for: row, dimension: dimension)
            var acc = groups[label] ?? Acc()
            acc.bytes += bytes
            acc.files += 1
            groups[label] = acc
            d.totalBytes += bytes
            d.totalFiles += 1
        }
        guard !groups.isEmpty else { return d }

        // Sort by size desc (name asc as tiebreak so equal sizes are stable).
        var ranked = groups.map { (name: $0.key, acc: $0.value) }
            .sorted { $0.acc.bytes != $1.acc.bytes ? $0.acc.bytes > $1.acc.bytes : $0.name < $1.name }

        // Fold the tail into Other when we exceed the palette. Keep the
        // largest (maxSlices - 1) named.
        var other: MediaDistributionSlice? = nil
        if ranked.count > maxSlices {
            let keep = max(1, maxSlices - 1)
            let tail = ranked[keep...]
            other = MediaDistributionSlice(
                name: otherName,
                bytes: tail.reduce(0) { $0 + $1.acc.bytes },
                files: tail.reduce(0) { $0 + $1.acc.files },
                isOther: true,
                colorSlot: nil,
                isReachable: nil,
                foldedVolumeCount: tail.count)
            ranked = Array(ranked[..<keep])
        }

        // Color slot by ALPHABETICAL name among the named survivors —
        // color follows the entity, not its rank.
        let slotByName: [String: Int] = Dictionary(
            uniqueKeysWithValues: ranked.map(\.name).sorted().enumerated().map { ($1, $0) })

        var slices: [MediaDistributionSlice] = ranked.map { entry in
            var reachable: Bool? = nil
            if dimension == .volume {         // reachability is a drive property only
                if entry.name == homeName {
                    reachable = true          // the boot volume is always here
                } else if reachableVolumes.contains(entry.name) {
                    reachable = true
                } else if knownVolumes.contains(entry.name) {
                    reachable = false
                }
            }
            return MediaDistributionSlice(
                name: entry.name,
                bytes: entry.acc.bytes,
                files: entry.acc.files,
                isOther: false,
                colorSlot: slotByName[entry.name],
                isReachable: reachable)
        }
        if let o = other { slices.append(o) }
        d.slices = slices
        return d
    }
}

// MARK: - Color(hexRGB:)

extension Color {
    /// `Color(hexRGB: 0x2a78d6)` — sRGB, opaque. Kept private to this
    /// feature's namespace by name (`hexRGB`) to avoid colliding with any
    /// future general-purpose `init(hex:)`.
    init(hexRGB: UInt32) {
        let r = Double((hexRGB >> 16) & 0xff) / 255.0
        let g = Double((hexRGB >> 8) & 0xff) / 255.0
        let b = Double(hexRGB & 0xff) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1.0)
    }
}
