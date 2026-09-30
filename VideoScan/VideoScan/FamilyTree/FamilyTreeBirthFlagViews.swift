// FamilyTreeBirthFlagViews.swift
// GH #229: the birth-country flag on a person card — ONE place, KISS (Rick
// 2026-09-30): a 14-pt flag centred in the card's header row, between the
// sex glyph and the refresh/root chips. The portrait is the photo, or the
// plain placeholder when there is none; the flag is never drawn on or as
// the portrait (on the photo it covered faces; as the portrait it doubled
// the header flag). Emoji Text at a fixed size — no bundled image assets —
// with the country as the accessibility label and the "shown under today's
// flag" tooltip. The view computes nothing: the flag arrives as a value
// (`model.birthFlag(for:)`, one dictionary lookup per card).

import SwiftUI
import VideoScanCore

/// The flag in the card's header row.
struct FamilyTreeBirthFlagBadge: View {
    let flag: FamilyTreeBirthFlag

    var body: some View {
        // Sits on the card's own background in the header row, so no
        // material backing is needed (it had one while it sat on photos).
        Text(flag.emoji)
            .font(.system(size: 14))
            .help(flag.tooltip)
            .accessibilityLabel(flag.accessibilityLabel)
            .accessibilityIdentifier("tree.person.flagBadge")
    }
}
