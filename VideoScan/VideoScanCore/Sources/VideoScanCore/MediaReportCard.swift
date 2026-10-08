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
    // Full tier (decodes the whole file).
    case decode
    case black
    case freeze
    case sound
    case interlace

    /// The row's short title, in family words.
    public var title: String {
        switch self {
        case .bitrate: return "Size for the picture"
        case .frameRate: return "Frame rate"
        case .timestamps: return "Timing"
        case .avDuration: return "Picture and sound lengths"
        case .audioSamples: return "Sound speed"
        case .aspect: return "Shape of the picture"
        case .truncation: return "Complete file"
        case .distinctFrames: return "Real frames vs repeats"
        case .decode: return "Every frame decodes"
        case .black: return "Black stretches"
        case .freeze: return "Frozen picture"
        case .sound: return "Sound track"
        case .interlace: return "Interlacing"
        }
    }

    public var isFullTier: Bool {
        switch self {
        case .decode, .black, .freeze, .sound, .interlace: return true
        default: return false
        }
    }
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

    public init(tier: Tier, checkedAt: Date, fileSizeBytes: Int64,
                headline: String, checks: [MediaCheck]) {
        self.tier = tier
        self.checkedAt = checkedAt
        self.fileSizeBytes = fileSizeBytes
        self.headline = headline
        self.checks = checks
    }

    /// Worst row wins; a card whose every row was not run says not run.
    public var verdict: MediaCheckVerdict {
        let worst = checks.map(\.verdict).max { $0.rank < $1.rank }
        return worst ?? .notRun(reason: "no checks ran")
    }

    /// True while the file on disk is still the size it was checked at.
    public func isCurrent(forSizeBytes size: Int64) -> Bool {
        size == fileSizeBytes
    }

    public func check(_ kind: MediaCheckKind) -> MediaCheck? {
        checks.first { $0.kind == kind }
    }
}
