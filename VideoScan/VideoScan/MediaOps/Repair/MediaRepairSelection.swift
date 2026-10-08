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

    func recipe(balance: MediaRepairBalanceInput?) -> MediaRepairRecipe {
        MediaRepairRecipe(fixes: Array(chosen), balance: balance)
    }

    // MARK: What the plan does to each stream

    /// One line each for picture, sound and length — copied vs re-encoded,
    /// and the expected change (codex consult #4).
    static func streamLines(_ recipe: MediaRepairRecipe, picture: MediaRepairPicturePlan?) -> [String] {
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
