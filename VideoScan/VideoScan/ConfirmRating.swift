// ConfirmRating.swift
// 4-level Likert rating the user picks per candidate during the
// Confirm-Person workflow. Maps to a prior probability used both as
// the soft label for a future classifier AND as the policy for how
// the result writes back into the catalog:
//
//   .definitely → confirmedByUserPeople (ground truth, immutable by scans)
//   .likely     → suspectedPeople        (signal, not commitment)
//   .unsure     → no catalog mutation    (stored only in the label sidecar)
//   .unlikely   → no catalog mutation    (stored only in the label sidecar)
//
// Rick 2026-06-16. Decided after the catalog-signal experiment showed
// the catalog metadata had ~9.5× the recall of PF face inference —
// the Confirm verb gives the user a fast way to convert those signals
// into either ground truth or training data without watching every
// video to completion.

import SwiftUI

enum ConfirmRating: String, Codable, CaseIterable, Identifiable {
    case definitely = "Definitely"
    case likely     = "Likely"
    case unsure     = "Unsure"
    case unlikely   = "Unlikely"

    var id: String { rawValue }

    /// Prior probability the user assigns to "person is in this video"
    /// when they pick this rating. Becomes the soft label for the
    /// classifier later. Not a calibrated number — Rick's intuitive
    /// mapping (90/80/50/25); easy to retune once we see real label data.
    var prior: Double {
        switch self {
        case .definitely: return 0.90
        case .likely:     return 0.80
        case .unsure:     return 0.50
        case .unlikely:   return 0.25
        }
    }

    /// SF Symbol shown on the rating button.
    var symbol: String {
        switch self {
        case .definitely: return "checkmark.seal.fill"
        case .likely:     return "checkmark.circle"
        case .unsure:     return "questionmark.circle"
        case .unlikely:   return "xmark.circle"
        }
    }

    /// Color used for the button tint and the per-rating summary chips.
    var color: Color {
        switch self {
        case .definitely: return .green
        case .likely:     return .blue
        case .unsure:     return .secondary
        case .unlikely:   return .red
        }
    }

    /// Keyboard shortcut character. 1-4 left-to-right matches the
    /// button row order: Definitely (1) → Unlikely (4).
    var keyboardKey: Character {
        switch self {
        case .definitely: return "1"
        case .likely:     return "2"
        case .unsure:     return "3"
        case .unlikely:   return "4"
        }
    }

    /// One-line copy for the button label tooltip.
    var hint: String {
        switch self {
        case .definitely: return "Face/body visible in at least one frame"
        case .likely:     return "Probably visible — couldn't review every frame"
        case .unsure:     return "Can't tell from the preview"
        case .unlikely:   return "Not visible in any frame (audio/transcript mentions don't count)"
        }
    }

    /// True when this rating should write a positive tag back to the
    /// catalog (so search + dashboards pick it up immediately).
    /// `.definitely` writes confirmedByUserPeople; `.likely` writes
    /// suspectedPeople; the others write nothing.
    var writebackTier: WritebackTier {
        switch self {
        case .definitely: return .confirmed
        case .likely:     return .suspected
        case .unsure:     return .none
        case .unlikely:   return .none
        }
    }

    enum WritebackTier { case confirmed, suspected, none }
}
