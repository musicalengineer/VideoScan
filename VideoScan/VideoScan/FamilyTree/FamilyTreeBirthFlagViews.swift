// FamilyTreeBirthFlagViews.swift
// GH #229: the two ways a person card draws its birth-country flag.
//   • No photo → `FamilyTreeBirthFlagPlaceholder`: the flag IS the portrait,
//     large and centred in the 58-pt photo slot, for every generation (the
//     deep ancestors are exactly the ones without photos).
//   • A photo → `FamilyTreeBirthFlagBadge`: a 14-pt flag in the portrait's
//     lower-right corner on a thin material so it reads on any photo.
// Both are emoji Text at a fixed size — no bundled image assets — with the
// country as the accessibility label and the "shown under today's flag"
// tooltip. Neither view computes anything: the flag arrives as a value
// (`model.birthFlag(for:)`, one dictionary lookup per card).

import SwiftUI
import VideoScanCore

/// The flag as the portrait when there is no photo.
struct FamilyTreeBirthFlagPlaceholder: View {
    let flag: FamilyTreeBirthFlag
    /// The card's per-sex accent, so the slot matches the other placeholders.
    let accent: Color

    var body: some View {
        ZStack {
            Circle()
                .fill(accent.opacity(0.22))
            Text(flag.emoji)
                .font(.system(size: 34))
        }
        .frame(width: 58, height: 58)
        .help(flag.tooltip)
        .accessibilityLabel(flag.accessibilityLabel)
        .accessibilityIdentifier("tree.person.flagPlaceholder")
    }
}

/// The small corner badge over a photo.
struct FamilyTreeBirthFlagBadge: View {
    let flag: FamilyTreeBirthFlag

    var body: some View {
        Text(flag.emoji)
            .font(.system(size: 14))
            .padding(2)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.black.opacity(0.25), lineWidth: 0.5))
            .help(flag.tooltip)
            .accessibilityLabel(flag.accessibilityLabel)
            .accessibilityIdentifier("tree.person.flagBadge")
    }
}
