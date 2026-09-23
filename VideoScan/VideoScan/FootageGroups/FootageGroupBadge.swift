// FootageGroupBadge.swift
// The catalog's footage-group chip (Find Similar Footage, 2026-09-23):
// "Same footage ×3" beside a file that is one of three files of the same
// footage, starred on the likely original. Never "copies" (QA 2026-09-23,
// the delete-safety principle): A/V halves, trims and transcodes are the
// same FOOTAGE, not deletable copies of each other. Reads only the record's own
// `footage` (O(1)) — safe in a table cell.

import SwiftUI
import VideoScanCore

struct FootageGroupBadge: View {
    let membership: FootageMembership

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: membership.rank == 0 ? "star.square.on.square" : "square.on.square")
                .font(.system(size: 8))
            Text(Self.text(membership))
                .font(.system(size: 9, weight: .medium))
        }
        .foregroundColor(.indigo)
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.indigo.opacity(0.12)))
        .lineLimit(1)
        .accessibilityLabel(Self.help(membership))
    }

    /// "Same footage ×3" (the group counts this file too).
    static func text(_ f: FootageMembership) -> String { "Same footage ×\(f.groupSize)" }

    /// Tooltip / accessibility sentence.
    static func help(_ f: FootageMembership) -> String {
        let who = f.rank == 0
            ? (f.originalInCatalog ? "This is the likely original." : "This is the best available — the camera original is probably not in the catalog.")
            : "This one is a \(f.role.label)."
        return "\(f.groupSize) files are probably the same footage (\(f.confidence.label)). \(who) Right-click → Find Similar Footage… to compare them; Show → One Per Footage hides the repeats. They are not all the same bytes — never delete on this alone."
    }
}
