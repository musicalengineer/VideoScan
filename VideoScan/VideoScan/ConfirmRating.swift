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
    case no         = "No"
    // Deprecated v1 cases — kept in the enum so JSON labels from
    // earlier rounds still decode. NOT shown in the UI's button list
    // (see `userFacing` below). Rick 2026-06-16: the 4-tier proved
    // confused; three buckets aligned with the three catalog tiers
    // (confirmed/suspected/rejected) is the right shape.
    case unsure     = "Unsure"
    case unlikely   = "Unlikely"

    /// The three cases the UI offers. Skip is a separate affordance,
    /// not a rating — it doesn't persist anything.
    static var userFacing: [ConfirmRating] { [.definitely, .likely, .no] }

    var id: String { rawValue }

    /// Backward-compat decoder so v1 labels with "Unsure"/"Unlikely"
    /// raw values decode cleanly. New labels can only be Definitely /
    /// Likely / No via the UI.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "Definitely": self = .definitely
        case "Likely":     self = .likely
        case "No":         self = .no
        case "Unsure":     self = .unsure
        case "Unlikely":   self = .unlikely
        default:
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Unknown ConfirmRating raw value: \(raw)"
            )
        }
    }

    /// Prior probability the user assigns to "person is in this video"
    /// when they pick this rating. Becomes the soft label for the
    /// classifier later. Calibrated to Rick's intuitive sense.
    var prior: Double {
        switch self {
        case .definitely: return 0.90
        case .likely:     return 0.75
        case .no:         return 0.05
        case .unsure:     return 0.50 // legacy
        case .unlikely:   return 0.25 // legacy
        }
    }

    /// SF Symbol shown on the rating button.
    var symbol: String {
        switch self {
        case .definitely: return "checkmark.seal.fill"
        case .likely:     return "checkmark.circle"
        case .no:         return "xmark.circle.fill"
        case .unsure:     return "questionmark.circle"
        case .unlikely:   return "xmark.circle"
        }
    }

    /// Color used for the button tint and the per-rating summary chips.
    var color: Color {
        switch self {
        case .definitely: return .green
        case .likely:     return .blue
        case .no:         return .red
        case .unsure:     return .secondary
        case .unlikely:   return .red
        }
    }

    /// Keyboard shortcut character. 1/2/3 matches the button row order
    /// for the three user-facing cases.
    var keyboardKey: Character {
        switch self {
        case .definitely: return "1"
        case .likely:     return "2"
        case .no:         return "3"
        case .unsure:     return "?"
        case .unlikely:   return "?"
        }
    }

    /// One-line tooltip copy.
    var hint: String {
        switch self {
        case .definitely: return "Face/body visible in at least one frame"
        case .likely:     return "Probably visible — couldn't review every frame"
        case .no:         return "Not visible in any frame (audio mentions don't count)"
        case .unsure:     return "Couldn't decide (legacy rating)"
        case .unlikely:   return "Probably not visible (legacy rating)"
        }
    }

    /// Catalog writeback tier. `.confirmed` writes confirmedByUserPeople
    /// (ground truth); `.suspected` writes suspectedPeople (signal);
    /// `.rejected` writes rejectedPeople (negative ground truth — used
    /// by future PF scans as a suppression list and by the classifier
    /// as a true-negative training example). `.none` is for the legacy
    /// .unsure / .unlikely cases which don't mutate the catalog.
    var writebackTier: WritebackTier {
        switch self {
        case .definitely: return .confirmed
        case .likely:     return .suspected
        case .no:         return .rejected
        case .unsure:     return .none
        case .unlikely:   return .none
        }
    }

    enum WritebackTier { case confirmed, suspected, rejected, none }
}
