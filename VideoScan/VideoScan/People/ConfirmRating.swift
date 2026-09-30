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
    /// Visible-but-not-the-subject. Used when the person appears in a
    /// crowd or background of a family gathering for ~seconds out of
    /// minutes. Technically a positive ("she IS in the frame") but a
    /// noisy training signal — these videos would teach a classifier
    /// "any face at a gathering = Donna" if used as positives. We
    /// surface the label so the user can mark accurately, but it does
    /// NOT mutate the catalog and the classifier training pass
    /// EXCLUDES these from the positive set. Rick 2026-06-17.
    case cameo      = "Cameo"
    case no         = "No"
    // Deprecated v1 cases — kept in the enum so JSON labels from
    // earlier rounds still decode. NOT shown in the UI's button list.
    case unsure     = "Unsure"
    case unlikely   = "Unlikely"

    /// The cases the UI offers, in left-to-right order. Skip is a
    /// separate affordance, not a rating.
    static var userFacing: [ConfirmRating] { [.definitely, .likely, .cameo, .no] }

    var id: String { rawValue }

    /// Backward-compat decoder so v1 labels with "Unsure"/"Unlikely"
    /// raw values decode cleanly. New labels are one of the
    /// userFacing four via the UI.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "Definitely": self = .definitely
        case "Likely":     self = .likely
        case "Cameo":      self = .cameo
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
    /// when they pick this rating. Cameo is technically a yes-prior
    /// but the classifier training pass excludes them, so the prior
    /// reflects "visual presence" not "training weight."
    var prior: Double {
        switch self {
        case .definitely: return 0.90
        case .likely:     return 0.75
        case .cameo:      return 0.70  // present, but not the subject
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
        case .cameo:      return "person.2.fill"  // one of many
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
        case .cameo:      return .orange
        case .no:         return .red
        case .unsure:     return .secondary
        case .unlikely:   return .red
        }
    }

    /// Keyboard shortcut character. 1/2/3/4 left-to-right.
    var keyboardKey: Character {
        switch self {
        case .definitely: return "1"
        case .likely:     return "2"
        case .cameo:      return "3"
        case .no:         return "4"
        case .unsure:     return "?"
        case .unlikely:   return "?"
        }
    }

    /// One-line tooltip copy.
    var hint: String {
        switch self {
        case .definitely: return "Face/body visible, she's a subject"
        case .likely:     return "Probably a subject — couldn't review every frame"
        case .cameo:      return "Visible but not the focus (e.g. one of many at a gathering)"
        case .no:         return "Not visible in any frame (audio mentions don't count)"
        case .unsure:     return "Couldn't decide (legacy rating)"
        case .unlikely:   return "Probably not visible (legacy rating)"
        }
    }

    /// Catalog writeback tier.
    ///   .confirmed → confirmedByUserPeople (ground truth)
    ///   .suspected → suspectedPeople (signal)
    ///   .rejected  → rejectedPeople (negative)
    ///   .none      → no catalog mutation (Cameo and legacy cases).
    ///                Cameo intentionally doesn't elevate the record in
    ///                search; the label exists in the sidecar so the
    ///                classifier training pass knows to EXCLUDE these
    ///                from the positive set (noisy positives would
    ///                pollute training).
    var writebackTier: WritebackTier {
        switch self {
        case .definitely: return .confirmed
        case .likely:     return .suspected
        case .cameo:      return .none
        case .no:         return .rejected
        case .unsure:     return .none
        case .unlikely:   return .none
        }
    }

    enum WritebackTier { case confirmed, suspected, rejected, none }
}
