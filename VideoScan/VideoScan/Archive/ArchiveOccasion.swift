// ArchiveOccasion.swift
// Archive tab — occasion cues on the decade page (Rick 2026-10-07: "like a
// Christmas tree and a turkey and a cake with candles for known events …
// color helps the eye … but nothing garish"). A glance at a year should say
// "good variety of events for 1995".
//
// Occasions are NOT stored. Each archived item's occasion is the Archive
// Angel's own answer (`archiveAngel.occasionReader` — its front door, never
// its internals), folded here into six display categories. Computed once per
// data change inside ArchiveView's timeline memo, never in a view body.
//
// Pure and SwiftUI-free (the colours live in ArchiveOccasionCueView.swift).

import Foundation
import VideoScanCore

// MARK: - The six display categories

/// What the eye sorts by. Many labeller events fold into one category
/// (beach, lake, camp, cape, Disney → trip); everything else that is a
/// known event but not one of the four headline ones is `other`.
enum ArchiveOccasion: String, CaseIterable, Sendable {
    case christmas, thanksgiving, birthday, trip, other, unlabeled

    /// The icon half of the cue (colour is never the only signal).
    var emoji: String { Self.emojis[self] ?? "" }

    /// The legend word ("Trip", "Other").
    var word: String { Self.words[self] ?? rawValue }

    // Tables, not switches: one place to read, and no CCN cost.
    private static let emojis: [ArchiveOccasion: String] = [
        .christmas: "🎄", .thanksgiving: "🦃", .birthday: "🎂",
        .trip: "🏖", .other: "✨", .unlabeled: "○",
    ]
    private static let words: [ArchiveOccasion: String] = [
        .christmas: "Christmas", .thanksgiving: "Thanksgiving", .birthday: "Birthday",
        .trip: "Trip", .other: "Other", .unlabeled: "Unlabeled",
    ]

    /// Labeller event id → category. Anything not listed is `other`.
    static let categoryByEvent: [String: ArchiveOccasion] = [
        "christmas": .christmas, "thanksgiving": .thanksgiving, "birthday": .birthday,
        "vacation": .trip, "beach": .trip, "lake": .trip, "cape": .trip,
        "disney": .trip, "camp": .trip,
    ]

    /// The short word a ROW shows for one labeller event: the category's
    /// word for the headline four, the event's own name otherwise
    /// ("Camping", "Lake", "Halloween") — more telling than "Trip"/"Other".
    static let rowWordByEvent: [String: String] = [
        "vacation": "Vacation", "camp": "Camping",
    ]

    static func category(forEvent event: String) -> ArchiveOccasion {
        categoryByEvent[event] ?? .other
    }
}

// MARK: - One row's cue

/// The cue one card shows: icon + short word + (in the view) a soft tint.
struct ArchiveOccasionCue: Equatable, Sendable {
    var occasion: ArchiveOccasion
    /// "Christmas", "Camping", "Halloween", "Unlabeled".
    var word: String
    /// Tooltip: "Christmas 1994 — folder name says 'xmas'". Empty when unlabeled.
    var help: String

    static let unlabeled = ArchiveOccasionCue(occasion: .unlabeled, word: ArchiveOccasion.unlabeled.word,
                                              help: "No occasion found in the date or the name")

    /// The FIRST label wins — the labeller orders calendar, then birthday,
    /// then file name, then folder, so a trusted Dec 25 beats a "trip"
    /// folder, and "xmas at the lake" is Christmas.
    static func from(labels: [EventLabel]) -> ArchiveOccasionCue {
        guard let first = labels.first else { return .unlabeled }
        let occasion = ArchiveOccasion.category(forEvent: first.event)
        let word: String
        switch occasion {
        case .trip, .other:
            word = ArchiveOccasion.rowWordByEvent[first.event] ?? EventLabeler.displayName(first.event)
        default:
            word = occasion.word
        }
        return ArchiveOccasionCue(occasion: occasion, word: word, help: "\(first.title) — \(first.reason)")
    }

    /// Two answers for one item (the source record and its archive copy):
    /// the source's labels first, then the copy's events it lacks.
    static func merged(_ primary: [EventLabel], _ secondary: [EventLabel]) -> [EventLabel] {
        guard !secondary.isEmpty else { return primary }
        var out = primary
        for l in secondary where !out.contains(where: { $0.event == l.event }) { out.append(l) }
        return out
    }
}

// MARK: - A year's strip

/// The thin strip under a year header: one segment per occasion present,
/// sized by minutes (by count when no item knows its duration), in the
/// fixed category order so years compare at a glance.
struct ArchiveOccasionStrip: Equatable, Sendable {
    struct Segment: Equatable, Sendable, Identifiable {
        let occasion: ArchiveOccasion
        var count: Int
        var seconds: Double
        /// 0…1 of the strip's width.
        var fraction: Double = 0
        var id: ArchiveOccasion { occasion }
    }

    var segments: [Segment] = []
    /// Tooltip, built once with the strip: "🎄 Christmas — 3 videos, 42 min".
    var help: String = ""
    /// The one-line key under the bar, so the strip never speaks in colour
    /// alone: "🎄 Christmas · 🏖 Trip · ○ Unlabeled" (strip order). Icons
    /// and words only — no tallies on screen (Rick: calm, for everyone;
    /// nothing curator-ish). Counts live in the tooltip only.
    var summary: String = ""

    var isEmpty: Bool { segments.isEmpty }

    /// O(items). Items without a cue (photos) are not counted.
    static func build(_ items: [ArchiveTimelineItem]) -> ArchiveOccasionStrip {
        var counts = [Int](repeating: 0, count: ArchiveOccasion.allCases.count)
        var seconds = [Double](repeating: 0, count: counts.count)
        for item in items {
            guard let cue = item.occasion, let i = index[cue.occasion] else { continue }
            counts[i] += 1
            if item.durationSeconds.isFinite, item.durationSeconds > 0 { seconds[i] += item.durationSeconds }
        }
        let totalSeconds = seconds.reduce(0, +)
        let totalCount = counts.reduce(0, +)
        guard totalCount > 0 else { return ArchiveOccasionStrip() }
        var segments: [Segment] = []
        for (i, occasion) in ArchiveOccasion.allCases.enumerated() where counts[i] > 0 {
            let share = totalSeconds > 0 ? seconds[i] / totalSeconds : Double(counts[i]) / Double(totalCount)
            segments.append(Segment(occasion: occasion, count: counts[i], seconds: seconds[i], fraction: share))
        }
        let summary = segments.map { "\($0.occasion.emoji) \($0.occasion.word)" }.joined(separator: " · ")
        return ArchiveOccasionStrip(segments: segments, help: helpText(segments), summary: summary)
    }

    private static let index: [ArchiveOccasion: Int] =
        Dictionary(uniqueKeysWithValues: ArchiveOccasion.allCases.enumerated().map { ($1, $0) })

    /// One line per occasion, biggest first by minutes.
    static func helpText(_ segments: [Segment]) -> String {
        segments
            .sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.count > $1.count }
            .map { s in
                let n = s.count == 1 ? "1 video" : "\(s.count) videos"
                let dur = ArchiveTimelinePath.friendlyDuration(seconds: s.seconds)
                return "\(s.occasion.emoji) \(s.occasion.word) — \(n)" + (dur.isEmpty ? "" : ", \(dur)")
            }
            .joined(separator: "\n")
    }
}

// MARK: - Deriving cues for the archive (main actor → any thread)

extension ArchiveOccasionCue {

    /// The facts the Angel's reader is asked about one record. (Same
    /// fields the Triage steward projects — StewardCaseBuilder.)
    static func facts(_ r: VideoRecord) -> ArchiveAngel.OccasionFacts {
        ArchiveAngel.OccasionFacts(
            id: r.id, filename: r.filename, fullPath: r.fullPath,
            userDate: r.userDate, userDateConfidence: r.userDateConfidence,
            embeddedDate: r.embeddedCreationDate, originMake: r.originMake, originModel: r.originModel,
            originEncoder: r.originEncoder,
            inferredDate: r.inferredRecordDate, inferredConfidence: r.inferredDateConfidence,
            inferredRange: r.inferredDateRange)
    }

    /// One archived item: the source record's answer, plus its archive
    /// copy's (the copy's human name — "Family_CapeCod_1997" — often says
    /// more than a camera's "clip0042"). `folders` is the pass's memo.
    /// Cost: one or two `occasions(for:)` calls, O(characters of the name).
    static func cue(source: VideoRecord, copy: VideoRecord, reader: ArchiveAngel.OccasionReader,
                    now: Date, folders: inout EventLabeler.FolderWordCache) -> ArchiveOccasionCue {
        let own = reader.occasions(for: facts(source), now: now, folders: &folders)
        guard copy.id != source.id else { return from(labels: own.labels) }
        let theirs = reader.occasions(for: facts(copy), now: now, folders: &folders)
        return from(labels: merged(own.labels, theirs.labels))
    }
}
