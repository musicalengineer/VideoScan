import Foundation
import VideoScanCore

// MARK: - Diagnostic banners (Rick 2026-10-10)
//
// "After Verify on a picture with no sound, the summary says it as plain
// text. It should be a prominent diagnostic flag I can't miss."
//
// One value type for every surface that flags a file — the Verify job's
// row and detail, the report card, Get Info: a severity (info / warning /
// error), an SF Symbol, a bold headline, ONE line saying what to do next,
// and at most one action. DiagnosticBannerView draws it; this file only
// decides it. Pure: plain values in, a banner out — the tests pin it.
//
// Today only the sound check is wired ("No sound"); any Verify warning can
// build a banner the same way later (a builder per concern, like
// `noSound` below — not a growing switch).

/// How loud a banner is. (A Swift enum ≈ a C++ `enum class`.)
enum DiagnosticSeverity: Equatable, Sendable {
    case info, warning, error

    /// A report-card verdict's severity: problem → error, warning → warning.
    init?(verdict: MediaCheckVerdict) {
        switch verdict {
        case .problem: self = .error
        case .warning: self = .warning
        case .ok, .notRun: return nil
        }
    }
}

/// The one thing a banner's button does.
enum DiagnosticAction: Equatable, Sendable {
    /// Open the Repair sheet (the one repair door) with this prefill.
    case repair(MediaRepairPrefill)

    var title: String {
        switch self {
        case .repair: return CatalogRowMenuText.repair
        }
    }
}

struct DiagnosticBanner: Equatable, Sendable, Identifiable {
    /// Stable per concern ("sound.noSound"), so a list keeps its identity.
    let id: String
    let severity: DiagnosticSeverity
    let symbol: String
    let headline: String
    /// One line: what is known, and what to do next.
    let nextStep: String
    let action: DiagnosticAction?
}

// MARK: - "No sound"

extension DiagnosticBanner {

    static let noSoundID = "sound.noSound"
    static let noSoundHeadline = "No sound"
    static let noSoundSymbol = "speaker.slash.fill"
    static let noSoundUnknownStep = "No matching sound found yet \u{2014} Repair\u{2026} can look for one."

    /// The "No sound" banner for a file, or nil when the file has sound,
    /// is the picture half of a known pair, or is silent film from before
    /// 1980 (SoundPresencePolicy decided all three; this only reads it).
    ///
    /// `card` = the file's Verify card (its Sound track row is the policy's
    /// row); `presence` = a live assessment (Get Info's probe), which wins
    /// over a card written before the rule existed. Either flags it.
    /// `advice` = where the sound is (SoundCopyFinder); nil = not looked up.
    static func noSound(recordID: UUID, card: MediaReportCard?, presence: SoundPresence? = nil,
                        advice: SoundCopyAdvice?) -> DiagnosticBanner? {
        let flagged = (presence?.isWarning ?? false)
            || (card.map(CheckMediaRules.hasNoSoundRow) ?? false)
        guard flagged else { return nil }
        return DiagnosticBanner(id: noSoundID, severity: .warning, symbol: noSoundSymbol,
                                headline: noSoundHeadline, nextStep: noSoundStep(advice),
                                action: .repair(MediaRepairPrefill(recordID: recordID, advice: advice)))
    }

    /// The next step, from what the lookup found. Only a measured length
    /// match says "probably"; a "may be" asks for a full Verify first.
    static func noSoundStep(_ advice: SoundCopyAdvice?) -> String {
        switch advice {
        case .combine(let p)?:
            return "Its sound is probably \(p.audio.filename) (\(p.shortReason)). Use Repair\u{2026} to add it."
        case .maybeCombine(let p)?:
            return "Its sound may be \(p.audio.filename) (\(p.shortReason)). Run a full Verify first, then Repair\u{2026} can add it."
        case .watch(let c)?:
            return "A copy with sound is \(c.filename) (\(c.volume)) \u{2014} watch that one, or Repair\u{2026} can look for this one's sound."
        case .connect(let c)?:
            return "A copy with sound is on \(c.volume), which is not connected: \(c.filename)."
        case .none?, nil:
            return noSoundUnknownStep
        }
    }
}

// MARK: - The Verify job, counted

/// "2 of 5 have no sound" — the collapsed row's chip for a multi-file
/// Verify. Counted once from the job's items; O(items).
struct NoSoundSummary: Equatable {
    let affected: Int
    let total: Int

    init(affected: Int, total: Int) {
        self.affected = affected
        self.total = total
    }

    init(_ items: [CheckMediaItem]) {
        self.init(affected: items.filter { $0.hasNoSound }.count, total: items.count)
    }

    /// nil when no file is affected.
    var chipText: String? {
        guard affected > 0 else { return nil }
        return "\(affected) of \(total) \(affected == 1 ? "has" : "have") no sound"
    }
}

extension CheckMediaItem {

    /// The file's Verify card says it has no sound and should.
    var hasNoSound: Bool {
        if case .checked(let card) = outcome { return CheckMediaRules.hasNoSoundRow(card) }
        return false
    }

    /// This file's banner in the job's row / detail, if any.
    var banner: DiagnosticBanner? {
        guard case .checked(let card) = outcome else { return nil }
        return DiagnosticBanner.noSound(recordID: id, card: card, advice: soundAdvice)
    }
}
