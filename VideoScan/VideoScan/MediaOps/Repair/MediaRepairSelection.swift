import Foundation

// MARK: - The Repair sheet's plan: which fixes are ticked, and what that
// means for each stream (Rick 2026-10-08; codex consult #4 / #8).
//
// "Every selected, justified fix": the boxes start at the app's
// recommendation (every fix the latest Verify earned), and a person who
// knows better can change them. Whatever is ticked becomes ONE recipe →
// one job → one new file. Pure value: the sheet draws it, tests pin it.
//
// Repair means making the file PLAY PROPERLY (picture and sound in step,
// a readable format). Improving a good file (denoise, stabilise, colour)
// is not repair and never appears here.

/// What "Repair Now" starts (pure; the sheet dispatches on it).
enum MediaRepairNow: Equatable {
    /// The one-pass MediaRepairJob writing ONE new file.
    case combined(MediaRepairRecipe)
    /// BalanceAudioJob (startBalanceAudio(fromDiagnosis:)): raw DV is
    /// re-read at its probed rate and written as QuickTime; several sound
    /// tracks keep only the program track.
    case dedicatedBalance
    /// Nothing runnable is ticked — Repair Now is disabled.
    case nothing
}

struct MediaRepairSelection: Equatable {
    let offers: [MediaRepairOffer]
    private(set) var chosen: Set<MediaRepairFix>

    /// Ticked by default: every available fix a card row asked for.
    init(offers: [MediaRepairOffer]) {
        self.offers = offers
        chosen = Set(offers.filter { $0.answers != nil && $0.isAvailable }.map(\.fix))
    }

    var recommended: Set<MediaRepairFix> {
        Set(offers.filter { $0.answers != nil && $0.isAvailable }.map(\.fix))
    }

    var isRecommendation: Bool { chosen == recommended }

    func isOn(_ fix: MediaRepairFix) -> Bool { chosen.contains(fix) }

    /// Unavailable fixes can't be ticked.
    mutating func set(_ fix: MediaRepairFix, on: Bool) {
        guard let offer = offers.first(where: { $0.fix == fix }), offer.isAvailable else { return }
        if on { chosen.insert(fix) } else { chosen.remove(fix) }
    }

    /// `soundFile` = the measured sound file Add sound reads (nil = none).
    func recipe(balance: MediaRepairBalanceInput?, soundFile: String? = nil) -> MediaRepairRecipe {
        MediaRepairRecipe(fixes: Array(chosen), balance: balance, soundFile: soundFile)
    }

    /// The plan Repair Now runs: Remove repeated frames rides it only once
    /// its picture check is ready (the other fixes never wait for it).
    func effectiveRecipe(balance: MediaRepairBalanceInput?, soundFile: String?, pictureReady: Bool) -> MediaRepairRecipe {
        var effective = self
        if !pictureReady { effective.set(.removeRepeatedFrames, on: false) }
        return effective.recipe(balance: balance, soundFile: soundFile)
    }

    /// What Repair Now starts. Balance Audio ticked ALONE on a sound
    /// layout the combined pass can't touch (raw DV, several sound
    /// tracks) runs the dedicated Balance Audio job — the one engine for
    /// that verb (CLAUDE.md rule 4) — instead of leaving Repair Now dead.
    /// Ticked with other fixes, the combined pass runs and the "Not in
    /// this pass" line says why balance is not in it.
    func repairNow(balance: MediaRepairBalanceInput?, soundFile: String?, pictureReady: Bool) -> MediaRepairNow {
        let recipe = effectiveRecipe(balance: balance, soundFile: soundFile, pictureReady: pictureReady)
        if !recipe.isEmpty { return .combined(recipe) }
        if chosen == [.balanceAudio], recipe.isDedicatedBalanceOnly { return .dedicatedBalance }
        return .nothing
    }

    // MARK: What the plan does to each stream

    /// The dedicated Balance Audio job, in the same three lines.
    static let dedicatedBalanceLines = [
        "Repair Now runs the Balance Audio job for this file's sound layout (raw DV, or several sound tracks).",
        "Picture: copied exactly \u{2014} not re-encoded. Raw DV is packaged as QuickTime (.mov).",
        "Sound: the live channel goes to both speakers; with several tracks only the one carrying sound is kept.",
        "Checked afterwards: the balanced copy is re-measured before it is kept.",
    ]

    /// One line each for picture, sound and length — copied vs re-encoded,
    /// and the expected change (codex consult #4).
    static func streamLines(_ recipe: MediaRepairRecipe, picture: MediaRepairPicturePlan?) -> [String] {
        if recipe.isDedicatedBalanceOnly { return dedicatedBalanceLines }
        guard !recipe.isEmpty else { return [] }
        var lines: [String] = []
        switch recipe.picture {
        case .copy:
            lines.append("Picture: copied exactly — not re-encoded.")
        case .removeRepeatedFrames:
            lines.append("Picture: re-encoded. " + (picture?.summary ?? "One picture per real frame at the file's own frame rate; the copy is shorter."))
        }
        switch recipe.sound {
        case .copy: lines.append("Sound: copied exactly — not re-encoded.")
        case .rebuild: lines.append("Sound: rebuilt as 24-bit PCM from what decodes (same sample rate and channels). It can't bring back sound that is missing.")
        case .balance: lines.append("Sound: the live channel goes to both speakers (re-encoded in the same kind of format).")
        case .addFrom(let path):
            lines.append("Sound: added from \((path as NSString).lastPathComponent) \u{2014} copied exactly, not re-encoded. The sound file is only read.")
        }
        if recipe.isLossless {
            lines.append("Length: the same, packet for packet. Sound is stored beside picture so it plays smoothly.")
        } else if recipe.picture == .copy {
            lines.append("Length: the same as the original.")
        }
        lines.append("Checked afterwards: \(MediaRepairEngine.verificationLevel).")
        return lines
    }
}
