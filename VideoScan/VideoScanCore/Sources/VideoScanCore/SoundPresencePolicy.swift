// SoundPresencePolicy.swift (VideoScanCore)
// THE one rule for "a picture with no sound track" (Rick 2026-10-10).
//
// Rick ran Verify and Get Info on Thanksgiving2009-DVD.m2v — an MPEG-2
// elementary stream from DVD authoring, picture only — and both said the
// file was fine. His ruling: missing sound is NOT fine for video newer
// than 1980; before 1980, silent home movies (8 mm / Super 8) are normal.
// An unknown date is treated as after 1980, and the words say so.
//
// Extended 2026-10-23 (Rick: "every file in archive has audio … only
// videos from 1980 and after should follow that rule"): a sound track that
// is THERE but measured silent (the full Verify's levels pass, every
// channel under the program floor) is judged by the same rule — before
// 1980 silent is normal, 1980 or later / undated it is a warning. The
// measurement comes from the stored report card, never from a guess.
//
// Two exceptions never read as broken:
//   * a known A/V half — a video-only file with a correlated sound partner
//     (the Correlate / Find Missing Audio pairing): "Video half of a pair —
//     its sound is in <file>";
//   * pre-1980 dated media: fine, "silent (normal for film before 1980)".
//
// Every surface that shows a health verdict asks THIS type — Verify's
// report card (CheckMediaRules), Get Info, Copies & Advice — so the rule
// lives in one place and the truth table is one test.
//
// Pure: plain values in, one value out. No I/O, no catalog. The record
// bridge at the bottom lifts the facts off a VideoRecord with the shared
// date ranking (RecordDateResolver — the same call ArchiveReadiness and
// the archive's placement use), O(1) per record.
//
// (For Rick: `enum` with associated values ≈ a C++ std::variant; each
// case carries only what its sentence needs.)

import Foundation

/// What the date and the pairing say about a file, minus its streams.
public struct SoundPresenceContext: Sendable, Equatable {
    /// The year the footage was recorded, as best the catalog knows. nil =
    /// unknown (treated as after 1980).
    public var recordedYear: Int?
    /// Where that year came from, for the WHY in the sentence.
    public var yearSource: RecordDateResolution.Source
    /// The filename of the correlated sound partner, when this is the
    /// picture half of a known A/V pair.
    public var soundPartnerName: String?

    public init(recordedYear: Int? = nil, yearSource: RecordDateResolution.Source = .none,
                soundPartnerName: String? = nil) {
        self.recordedYear = recordedYear
        self.yearSource = recordedYear == nil ? .none : yearSource
        self.soundPartnerName = soundPartnerName
    }

    /// Nothing known: no date, no partner.
    public static let unknown = SoundPresenceContext()
}

/// The policy's answer for one file.
public enum SoundPresence: Sendable, Equatable {
    /// The file has a sound track (or no picture) — nothing to say here.
    case notApplicable
    /// Picture only, but its sound lives in a correlated partner file.
    case videoHalfOfPair(soundFile: String)
    /// Picture only, dated before 1980 — silent film is normal.
    case silentFilmEra(year: Int, source: RecordDateResolution.Source)
    /// Picture only, dated 1980 or later, or undated — a WARNING.
    case noSound(year: Int?, source: RecordDateResolution.Source)
    /// A sound track that was decoded and measured silent, dated 1980 or
    /// later, or undated — a WARNING (2026-10-23).
    case silentTrack(year: Int?, source: RecordDateResolution.Source)

    /// The card verdict for the "Sound track" row. nil = leave the row as
    /// the sound checks wrote it (there IS a sound track to check).
    public var verdict: MediaCheckVerdict? {
        switch self {
        case .notApplicable: return nil
        case .videoHalfOfPair, .silentFilmEra: return .ok
        case .noSound, .silentTrack: return .warning
        }
    }

    public var isWarning: Bool { verdict == .warning }

    /// The one-line headline a person sees (Get Info, Verify, Copies &
    /// Advice). nil when there is nothing to say.
    public var headline: String? {
        switch self {
        case .notApplicable: return nil
        case .videoHalfOfPair(let file): return "Video half of a pair — its sound is in \(file)"
        case .silentFilmEra: return SoundPresencePolicy.silentFilmTitle
        case .noSound: return SoundPresencePolicy.noSoundTitle
        case .silentTrack: return SoundPresencePolicy.silentTrackTitle
        }
    }

    /// The WHY under the headline: which date, and where it came from.
    public var reason: String? {
        switch self {
        case .notApplicable:
            return nil
        case .videoHalfOfPair:
            return "Play or combine the two together."
        case .silentFilmEra(let year, let source):
            return "Dated \(year), from \(SoundPresencePolicy.words(for: source))."
        case .noSound(let year?, let source), .silentTrack(let year?, let source):
            return "It dates from \(year) (from \(SoundPresencePolicy.words(for: source))), "
                + "and home video after 1980 normally has sound."
        case .noSound(nil, _), .silentTrack(nil, _):
            return "Its date is unknown, so it is treated as after 1980, when home video normally has sound."
        }
    }

    /// The report card's "Sound track" row sentence: headline + the WHY.
    public var sentence: String? {
        guard let headline, let reason else { return nil }
        return "\(headline). \(reason)"
    }

    /// What to do about it ("" when nothing needs doing).
    public var fix: String {
        switch self {
        case .noSound: return SoundPresencePolicy.noSoundFix
        case .silentTrack: return SoundPresencePolicy.silentTrackFix
        default: return ""
        }
    }
}

public enum SoundPresencePolicy {

    /// Media dated before this year may be silent (8 mm / Super 8 film).
    public static let silentFilmCutoffYear = 1980

    public static let noSoundTitle = "No sound — this copy has no audio track"
    public static let silentFilmTitle = "Silent (normal for film before 1980)"
    public static let silentTrackTitle = "No sound — the sound track is silent"
    public static let silentTrackFix =
        "Listen to confirm, then look for a copy with sound (Find Matching Audio) "
        + "or an earlier transfer of the same tape."
    public static let noSoundFix =
        "Watch a copy with sound instead (Get Info lists one when the catalog has it), "
        + "or combine this picture with its sound."

    /// THE rule. `hasPicture` / `hasSound` come from the probe when one
    /// ran (Verify, Get Info), else from the catalog's stream type.
    /// `soundMeasuredSilent`: the full check decoded the sound track and
    /// every channel was below the program floor (MediaReportCard
    /// .soundMeasuredSilent). Only meaningful when `hasSound`.
    public static func assess(hasPicture: Bool, hasSound: Bool, soundMeasuredSilent: Bool = false,
                              context: SoundPresenceContext) -> SoundPresence {
        guard hasPicture else { return .notApplicable }
        let silentTrack = hasSound && soundMeasuredSilent
        guard !hasSound || silentTrack else { return .notApplicable }
        if let partner = context.soundPartnerName, !partner.isEmpty {
            return .videoHalfOfPair(soundFile: partner)
        }
        if let year = context.recordedYear, year < silentFilmCutoffYear {
            return .silentFilmEra(year: year, source: context.yearSource)
        }
        return silentTrack
            ? .silentTrack(year: context.recordedYear, source: context.yearSource)
            : .noSound(year: context.recordedYear, source: context.yearSource)
    }

    /// Where a year came from, in family words.
    public static func words(for source: RecordDateResolution.Source) -> String {
        switch source {
        case .userDate: return "your date"
        case .embedded: return "the date stored in the file"
        case .inferred: return "the catalog's best guess"
        case .filename: return "its name"
        case .none: return "nowhere — it is undated"
        }
    }

    // MARK: Display guards (the sensor's subject)

    /// The headline Get Info shows over a stored report card. A card saved
    /// before this rule existed may say "Looks healthy" for a picture with
    /// no sound; the live assessment wins over a stale all-clear, so Get
    /// Info never calls a post-1980 video without sound fine. A card whose
    /// silent track was judged with an older date (before or after 1980)
    /// is judged again with today's date (Codex P0 2026-10-24).
    public static func displayHeadline(card: MediaReportCard, presence: SoundPresence) -> String {
        if presence.isWarning, card.verdict.rank < MediaCheckVerdict.warning.rank {
            return (presence.headline ?? noSoundTitle) + "."
        }
        if let relaxed = relaxedSilentTrackVerdict(card: card, presence: presence),
           relaxed.rank < card.verdict.rank, let headline = presence.headline {
            return headline + "."
        }
        return card.displayHeadline
    }

    /// The verdict icon to draw beside `displayHeadline`: never better than
    /// Warning while the file has no sound and should; a stale silent-track
    /// warning on a file now dated before 1980 is lifted. Damaged sound
    /// (a Problem row) is never softened.
    public static func displayVerdict(card: MediaReportCard, presence: SoundPresence) -> MediaCheckVerdict {
        if presence.isWarning, card.verdict.rank < MediaCheckVerdict.warning.rank { return .warning }
        return relaxedSilentTrackVerdict(card: card, presence: presence) ?? card.verdict
    }

    /// The card's verdict with its Sound row re-judged by `presence`, when
    /// the card MEASURED a silent track, the row is no worse than Warning,
    /// and the live answer is no longer a warning. nil otherwise.
    static func relaxedSilentTrackVerdict(card: MediaReportCard, presence: SoundPresence) -> MediaCheckVerdict? {
        guard card.soundMeasuredSilent == true, !presence.isWarning, let live = presence.verdict,
              let row = card.check(.sound), row.verdict.rank <= MediaCheckVerdict.warning.rank else { return nil }
        let others = card.checks.filter { $0.kind != .sound }.map(\.verdict) + [live]
        return others.max { $0.rank < $1.rank }
    }
}

// MARK: - Record bridge

extension VideoRecord {

    /// The date and pairing facts the policy reads, lifted off this record.
    /// O(1): one RecordDateResolver call and one pointer hop to the partner.
    public var soundPresenceContext: SoundPresenceContext {
        let r = RecordDateResolver.resolve(userDate: userDate,
                                           userDateConfidence: userDateConfidence,
                                           embeddedCreationDate: embeddedCreationDate,
                                           originMake: originMake,
                                           originModel: originModel,
                                           originEncoder: originEncoder,
                                           inferredRecordDate: inferredRecordDate,
                                           inferredDateConfidence: inferredDateConfidence,
                                           inferredDateRange: inferredDateRange,
                                           filename: filename.isEmpty ? nil : filename)
        return SoundPresenceContext(recordedYear: r.year, yearSource: r.source,
                                    soundPartnerName: soundPartner?.filename)
    }

    /// The correlated partner that carries this picture's sound: a live
    /// (not removed) audio-only record paired with this one.
    public var soundPartner: VideoRecord? {
        guard let p = pairedWith, p.purgedAt == nil, p.streamType == .audioOnly else { return nil }
        return p
    }

    /// The stored full Verify measured this file's sound track silent: a
    /// FULL card for this file's current size (the card is keyed by content
    /// SHA-256 in the store; the size guard is the card's own staleness
    /// rule). False when not measured — absence of a measurement is never
    /// read as silence. O(1).
    public var soundMeasuredSilent: Bool {
        guard let card = mediaReportCard, card.tier == .full,
              card.isCurrent(forSizeBytes: sizeBytes) else { return false }
        return card.soundMeasuredSilent == true
    }

    /// The policy's answer from the catalog's stream type plus the stored
    /// sound measurement (2026-10-23): "no track" or "silent track", judged
    /// against the record's CURRENT date. The Archive tab's yellow mark. O(1).
    public var measuredSoundPresence: SoundPresence {
        let s = streamType
        return SoundPresencePolicy.assess(hasPicture: s == .videoOnly || s == .videoAndAudio,
                                          hasSound: s == .videoAndAudio || s == .audioOnly,
                                          soundMeasuredSilent: soundMeasuredSilent,
                                          context: soundPresenceContext)
    }

    /// The policy's answer from the catalog's own stream type (no probe).
    public var catalogSoundPresence: SoundPresence {
        let s = streamType
        return SoundPresencePolicy.assess(hasPicture: s == .videoOnly || s == .videoAndAudio,
                                          hasSound: s == .videoAndAudio || s == .audioOnly,
                                          context: soundPresenceContext)
    }
}
