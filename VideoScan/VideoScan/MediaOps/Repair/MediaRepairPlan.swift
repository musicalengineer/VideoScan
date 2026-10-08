import Foundation

// MARK: - Repair… — which fixes a report card earns (Rick 2026-10-08)
//
// Get Info → Verify → Repair. Verify writes the card; Repair reads it and
// offers the fixes its rows earn. Pure: no SwiftUI, no model, no disk —
// the menu, the sheet and the tests all ask these functions.
//
// Design: docs/design/check_media_and_menu_cleanup_2026_10_07.md §9.

/// The fixes Repair… can run. Raw values are the `derivationKind` the
/// new record carries — never rename one. (A Swift enum with String raw
/// values ≈ a C++ `enum class` plus its to_string table in one place.)
enum MediaRepairFix: String, CaseIterable, Sendable, Identifiable {
    /// `ffmpeg -map 0 -c copy` into a new file: same packets, interleaved.
    case remux
    /// `mpdecimate` + re-time to the real frame rate (a re-encode).
    case removeRepeatedFrames
    /// The existing Balance Audio job (GH #116), re-homed here.
    case balanceAudio
    /// The existing Rebuild Audio Track job (GH #128), re-homed here.
    case rebuildAudio

    var id: String { rawValue }

    var title: String {
        switch self {
        case .remux: return "Re-wrap without re-encoding (lossless remux)"
        case .removeRepeatedFrames: return "Remove repeated frames"
        case .balanceAudio: return "Balance Audio"
        case .rebuildAudio: return "Rebuild Audio Track"
        }
    }

    /// What it does, in family words — shown under the button.
    var explanation: String {
        switch self {
        case .remux:
            return "Copies every picture and sound packet, unchanged, into a new file with sound and picture stored side by side. Nothing is re-encoded; VideoScan then proves every stream is identical."
        case .removeRepeatedFrames:
            return "Drops the stored copies of the same picture and re-times the real frames at their true rate, keeping the sound as it is. The picture has to be re-encoded (H.264 at a high-quality setting, CRF 16) — a new file, the original is never changed."
        case .balanceAudio:
            return "Copies the live sound channel to both speakers in a new file; the picture is copied exactly."
        case .rebuildAudio:
            return "Re-checks the sound and, when the damage is an old or unreadable sound format, writes a copy with the same picture and the sound converted to a modern lossless format."
        }
    }

    /// The card row this fix answers.
    var answers: MediaCheckKind {
        switch self {
        case .remux: return .layout
        case .removeRepeatedFrames: return .distinctFrames
        case .balanceAudio, .rebuildAudio: return .sound
        }
    }

    /// The full-tier rows Verify must re-run on the output to judge this
    /// fix (the quick tier already covers layout and repeated frames).
    var needsSoundPass: Bool { self == .balanceAudio || self == .rebuildAudio }
}

/// One fix offered on a card.
struct MediaRepairOffer: Equatable, Sendable, Identifiable {
    let fix: MediaRepairFix
    /// The card row this fix answers; nil = always available (remux).
    let answers: MediaCheckKind?
    /// nil = can run now; otherwise why not, in plain words.
    let unavailableReason: String?

    var id: MediaRepairFix { fix }
    var isAvailable: Bool { unavailableReason == nil }
}

/// What this session's sound diagnosis (Verify's full tier or Verify
/// Audio) says the sound fixes can do. Plain flags so the plan's tests
/// need no diagnosis.
struct MediaRepairSoundFacts: Equatable, Sendable {
    /// A channel-imbalance finding with the balance analysis attached.
    var canBalance = false
    /// An old / unreadable sound format finding.
    var canRebuild = false
    /// A diagnosis exists this session at all.
    var measured = false

    init(canBalance: Bool = false, canRebuild: Bool = false, measured: Bool = false) {
        self.canBalance = canBalance
        self.canRebuild = canRebuild
        self.measured = measured
    }

    init(diagnosis: AudioVerifyDiagnosis?) {
        guard let diagnosis else { return }
        measured = true
        for finding in diagnosis.findings {
            switch finding {
            case .channelImbalance: canBalance = diagnosis.balanceAnalysis != nil
            case .unsupportedCodec: canRebuild = true
            default: break
            }
        }
    }
}

/// How Repair… shows in the row menu.
enum MediaRepairMenuState: Equatable {
    /// No current card: Repair… runs the quick Verify first.
    case verifyFirst
    /// The card has `count` fixes for its problems.
    case ready(count: Int)
    case disabled(help: String)

    var isEnabled: Bool {
        if case .disabled = self { return false }
        return true
    }

    var help: String {
        switch self {
        case .verifyFirst: return "Not verified yet — Repair runs a quick Verify first, then shows what it can fix. Your original is never changed."
        case .ready: return "Show this file's report card and the fixes it offers. Every fix writes a NEW file; your original is never changed."
        case .disabled(let why): return why
        }
    }
}

enum MediaRepairPlan {

    static let protectedSoundReason =
        "This file is on a protected drive, and this fix writes its copy next to the original — copy the file somewhere else first."

    /// The fixes `card` earns, in card order, then remux as always
    /// available when no row asked for it. O(rows).
    static func offers(for card: MediaReportCard, sound: MediaRepairSoundFacts,
                       originalProtected: Bool) -> [MediaRepairOffer] {
        var offers = card.checks.compactMap { offer(for: $0, sound: sound, originalProtected: originalProtected) }
        if !offers.contains(where: { $0.fix == .remux }) {
            offers.append(MediaRepairOffer(fix: .remux, answers: nil, unavailableReason: nil))
        }
        return offers
    }

    /// The fix one row earns, if any.
    static func offer(for check: MediaCheck, sound: MediaRepairSoundFacts,
                      originalProtected: Bool) -> MediaRepairOffer? {
        switch (check.kind, check.verdict) {
        case (.layout, .problem), (.layout, .warning):
            return MediaRepairOffer(fix: .remux, answers: .layout, unavailableReason: nil)
        case (.distinctFrames, .problem):
            return MediaRepairOffer(fix: .removeRepeatedFrames, answers: .distinctFrames, unavailableReason: nil)
        case (.sound, .problem) where sound.canRebuild || !sound.measured:
            // Unmeasured this session: the existing Repair Damaged Audio
            // path re-checks first and only rebuilds the format class.
            return soundOffer(.rebuildAudio, originalProtected: originalProtected)
        case (.sound, .warning) where sound.canBalance:
            return soundOffer(.balanceAudio, originalProtected: originalProtected)
        default:
            return nil
        }
    }

    private static func soundOffer(_ fix: MediaRepairFix, originalProtected: Bool) -> MediaRepairOffer {
        MediaRepairOffer(fix: fix, answers: .sound,
                         unavailableReason: originalProtected ? protectedSoundReason : nil)
    }

    /// Repair… in the row menu. `card` is the record's card (nil = never
    /// verified); a card for a different file size is stale = no card.
    static func menuState(card: MediaReportCard?, fileSizeBytes: Int64, sound: MediaRepairSoundFacts,
                          reachable: Bool, selectionCount: Int) -> MediaRepairMenuState {
        guard selectionCount == 1 else {
            return .disabled(help: "Repair works on one file at a time — select a single file.")
        }
        guard reachable else {
            return .disabled(help: "The file's drive isn't connected.")
        }
        guard let card, card.isCurrent(forSizeBytes: fileSizeBytes) else { return .verifyFirst }
        let fixes = offers(for: card, sound: sound, originalProtected: false).filter { $0.answers != nil }
        guard !fixes.isEmpty else {
            return .disabled(help: "The last Verify found nothing Repair can fix. Run a full Verify to look deeper.")
        }
        return .ready(count: fixes.count)
    }
}
