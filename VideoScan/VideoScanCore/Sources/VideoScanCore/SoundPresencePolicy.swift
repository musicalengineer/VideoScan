// SoundPresencePolicy.swift (VideoScanCore)
// THE one rule for "a picture with no sound track" (Rick 2026-10-10).
//
// Rick ran Verify and Get Info on Thanksgiving2009-DVD.m2v — an MPEG-2
// elementary stream from DVD authoring, picture only — and both said the
// file was fine. His ruling: missing sound is NOT fine for video newer
// than 1980; before 1980, silent home movies (8 mm / Super 8) are normal.
// An unknown date is treated as after 1980, and the words say so.
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

    /// The card verdict for the "Sound track" row. nil = leave the row as
    /// the sound checks wrote it (there IS a sound track to check).
    public var verdict: MediaCheckVerdict? {
        switch self {
        case .notApplicable: return nil
        case .videoHalfOfPair, .silentFilmEra: return .ok
        case .noSound: return .warning
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
        case .noSound(let year?, let source):
            return "It dates from \(year) (from \(SoundPresencePolicy.words(for: source))), "
                + "and home video after 1980 normally has sound."
        case .noSound(nil, _):
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
        isWarning ? SoundPresencePolicy.noSoundFix : ""
    }
}

public enum SoundPresencePolicy {

    /// Media dated before this year may be silent (8 mm / Super 8 film).
    public static let silentFilmCutoffYear = 1980

    public static let noSoundTitle = "No sound — this copy has no audio track"
    public static let silentFilmTitle = "Silent (normal for film before 1980)"
    public static let noSoundFix =
        "Watch a copy with sound instead (Get Info lists one when the catalog has it), "
        + "or combine this picture with its sound."

    /// THE rule. `hasPicture` / `hasSound` come from the probe when one
    /// ran (Verify, Get Info), else from the catalog's stream type.
    public static func assess(hasPicture: Bool, hasSound: Bool,
                              context: SoundPresenceContext) -> SoundPresence {
        guard hasPicture, !hasSound else { return .notApplicable }
        if let partner = context.soundPartnerName, !partner.isEmpty {
            return .videoHalfOfPair(soundFile: partner)
        }
        if let year = context.recordedYear, year < silentFilmCutoffYear {
            return .silentFilmEra(year: year, source: context.yearSource)
        }
        return .noSound(year: context.recordedYear, source: context.yearSource)
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
    /// Info never calls a post-1980 video-only file fine.
    public static func displayHeadline(card: MediaReportCard, presence: SoundPresence) -> String {
        guard presence.isWarning, card.verdict.rank < MediaCheckVerdict.warning.rank else {
            return card.displayHeadline
        }
        return noSoundTitle + "."
    }

    /// The verdict icon to draw beside `displayHeadline`: never better than
    /// Warning while the file has no sound and should.
    public static func displayVerdict(card: MediaReportCard, presence: SoundPresence) -> MediaCheckVerdict {
        guard presence.isWarning, card.verdict.rank < MediaCheckVerdict.warning.rank else { return card.verdict }
        return .warning
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

    /// The policy's answer from the catalog's own stream type (no probe).
    public var catalogSoundPresence: SoundPresence {
        let s = streamType
        return SoundPresencePolicy.assess(hasPicture: s == .videoOnly || s == .videoAndAudio,
                                          hasSound: s == .videoAndAudio || s == .audioOnly,
                                          context: soundPresenceContext)
    }
}
