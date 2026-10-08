// MediaReportCard.swift (VideoScanCore)
// Check Media's result, as plain values (Rick 2026-10-07). One row per
// check — verdict, a plain-English sentence, the evidence numbers and a
// suggested fix — under a one-line headline. Persisted on VideoRecord as
// the additive optional `mediaReportCard` so Get Media Info and the
// Archive Angel can read the last verdict without re-checking.
//
// Value semantics throughout (≈ C++ structs copied by value; no shared
// mutable state), Codable for the catalog JSON, Sendable so the card can
// cross from the background probe to the main actor.
//
// Design: docs/design/check_media_and_menu_cleanup_2026_10_07.md

import Foundation

/// What one check concluded. `.notRun` carries WHY, so an unknown can
/// never read as OK (the GH #128 rule: "couldn't check" is not a verdict).
/// (An enum with an associated value ≈ a C++ std::variant whose one
/// alternative carries a string.)
public enum MediaCheckVerdict: Codable, Sendable, Equatable, Hashable {
    case ok
    case warning
    case problem
    case notRun(reason: String)

    /// Ordering for "worst wins": problem > warning > ok > not run.
    public var rank: Int {
        switch self {
        case .problem: return 3
        case .warning: return 2
        case .ok: return 1
        case .notRun: return 0
        }
    }

    public var word: String {
        switch self {
        case .ok: return "OK"
        case .warning: return "Warning"
        case .problem: return "Problem"
        case .notRun: return "Not run"
        }
    }
}

/// Which check a row reports. Raw values are persisted — never rename one.
public enum MediaCheckKind: String, Codable, Sendable, CaseIterable, Hashable {
    // Quick tier (seconds, any file size).
    case bitrate
    case frameRate
    case timestamps
    case avDuration
    case audioSamples
    case aspect
    case truncation
    case distinctFrames
    /// Sound and picture for the same moment stored side by side (2026-10-07).
    case layout
    // Full tier (decodes the whole file).
    case decode
    case black
    case freeze
    case sound
    /// Every sample decoded: dropouts, replayed buffers, clicks, timing gaps.
    case soundContinuity
    case interlace
    // Full tier, broadened 2026-10-07 ("do as much as possible").
    case packetTiming
    case keyframes
    case dataRate
    case sync
    case timecode
    case colour
    case loudness
    case dcOffset
    case channels
    case clipping

    /// The row's short title, in family words.
    public var title: String { Self.titles[self] ?? rawValue }

    /// Titles as data, not a growing switch: the list of checks keeps
    /// growing and each is one line here. A test pins that every case has
    /// one (the switch's exhaustiveness check, kept as a test).
    public static let titles: [MediaCheckKind: String] = [
        .bitrate: "Size for the picture",
        .frameRate: "Frame rate",
        .timestamps: "Timing",
        .avDuration: "Picture and sound lengths",
        .audioSamples: "Sound speed",
        .aspect: "Shape of the picture",
        .truncation: "Complete file",
        .distinctFrames: "Real frames vs repeats",
        .layout: "Sound stored beside picture",
        .decode: "Every frame decodes",
        .black: "Black stretches",
        .freeze: "Frozen picture",
        .sound: "Sound track",
        .soundContinuity: "Sound continuity",
        .interlace: "Interlacing",
        .packetTiming: "Timing, every packet",
        .keyframes: "Keyframes",
        .dataRate: "Data rate over time",
        .sync: "Sound and picture start together",
        .timecode: "Timecode track",
        .colour: "Colour labels",
        .loudness: "Loudness (EBU R128)",
        .dcOffset: "Sound centred on zero",
        .channels: "Left and right",
        .clipping: "Clipped stretches",
    ]

    /// The checks that need the full tier (decode / every packet).
    public static let fullTier: Set<MediaCheckKind> = [
        .decode, .black, .freeze, .sound, .soundContinuity, .interlace,
        .packetTiming, .keyframes, .dataRate, .sync, .timecode, .colour,
        .loudness, .dcOffset, .channels, .clipping,
    ]

    public var isFullTier: Bool { Self.fullTier.contains(self) }
}

/// One labelled number behind a sentence ("Stored frame rate" → "60,000 fps").
public struct MediaEvidence: Codable, Sendable, Equatable, Hashable {
    public var label: String
    public var value: String

    public init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

/// One row of the report card.
public struct MediaCheck: Codable, Sendable, Equatable, Identifiable {
    public var kind: MediaCheckKind
    public var verdict: MediaCheckVerdict
    /// Plain-English, one sentence.
    public var sentence: String
    public var evidence: [MediaEvidence]
    /// What to do about it ("" when nothing needs doing).
    public var fix: String

    public var id: MediaCheckKind { kind }

    public init(kind: MediaCheckKind, verdict: MediaCheckVerdict, sentence: String,
                evidence: [MediaEvidence] = [], fix: String = "") {
        self.kind = kind
        self.verdict = verdict
        self.sentence = sentence
        self.evidence = evidence
        self.fix = fix
    }

    public static func notRun(_ kind: MediaCheckKind, because reason: String) -> MediaCheck {
        MediaCheck(kind: kind, verdict: .notRun(reason: reason),
                   sentence: "Not checked — \(reason).")
    }
}

/// Where Repair… put this file's repaired copy (Rick 2026-10-08). Lives
/// on the ORIGINAL's card so Get Info can say "Repaired copy: …". Additive:
/// an optional on a synthesized-Codable struct decodes as absent from
/// older cards, and an older build ignores the key.
public struct MediaRepairLink: Codable, Sendable, Equatable {
    /// The repaired copy's catalog record.
    public var recordID: UUID
    public var path: String
    public var repairedAt: Date
    /// The fixes applied (`MediaRepairFix` raw values), in order.
    public var fixes: [String]

    public init(recordID: UUID, path: String, repairedAt: Date, fixes: [String]) {
        self.recordID = recordID
        self.path = path
        self.repairedAt = repairedAt
        self.fixes = fixes
    }
}

/// The whole card: a headline over one row per check.
public struct MediaReportCard: Codable, Sendable, Equatable {
    public enum Tier: String, Codable, Sendable {
        /// Header + packet samples + short frame windows (seconds).
        case quick
        /// Quick + a full decode of picture and sound.
        case full
    }

    public var tier: Tier
    public var checkedAt: Date
    /// The file's size when checked — a card for a different size is stale.
    public var fileSizeBytes: Int64
    /// The verdict sentence at the top of the card.
    public var headline: String
    public var checks: [MediaCheck]
    /// The repaired copy Repair… made from this file, if any (additive,
    /// 2026-10-08). A later Verify of this file carries it over.
    public var repairedCopy: MediaRepairLink?

    public init(tier: Tier, checkedAt: Date, fileSizeBytes: Int64,
                headline: String, checks: [MediaCheck], repairedCopy: MediaRepairLink? = nil) {
        self.tier = tier
        self.checkedAt = checkedAt
        self.fileSizeBytes = fileSizeBytes
        self.headline = headline
        self.checks = checks
        self.repairedCopy = repairedCopy
    }

    /// Worst row wins; a card whose every row was not run says not run.
    public var verdict: MediaCheckVerdict {
        let worst = checks.map(\.verdict).max { $0.rank < $1.rank }
        return worst ?? .notRun(reason: "no checks ran")
    }

    /// A quick check that found nothing wrong. It is NOT a clean bill of
    /// health — the quick tier never decodes the whole file — so it must
    /// never be worded or drawn like one (Rick 2026-10-07: a stuttering
    /// file was called fine after a quick check).
    public var isQuickPassOnly: Bool {
        tier == .quick && verdict == .ok
    }

    /// The card's one-word-ish verdict for summaries and logs: "OK" only
    /// when the full check ran; a quick pass says what it is.
    public var verdictWord: String {
        isQuickPassOnly ? "No problems found (quick check only)" : verdict.word
    }

    /// The headline a quick pass always carries.
    public static let quickPassHeadline =
        "No problems found in the quick check — run the full check to listen to every sample and decode every frame."

    /// What to show: a quick pass ALWAYS reads `quickPassHeadline`, even on
    /// a card persisted before 2026-10-07 whose stored headline said
    /// "Looks healthy (quick check …)".
    public var displayHeadline: String {
        isQuickPassOnly ? Self.quickPassHeadline : headline
    }

    /// True while the file on disk is still the size it was checked at.
    public func isCurrent(forSizeBytes size: Int64) -> Bool {
        size == fileSizeBytes
    }

    public func check(_ kind: MediaCheckKind) -> MediaCheck? {
        checks.first { $0.kind == kind }
    }
}
