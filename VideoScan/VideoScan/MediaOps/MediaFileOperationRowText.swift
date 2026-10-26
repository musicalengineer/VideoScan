// MediaFileOperationRowText.swift — the MFO row's text column and its
// disclosure chevron, split out of MediaFileOperationRow.body (2026-10-26).
// Values in, no job reference: the row passes title, subtitle and the
// optional headline it already read.

import SwiftUI

/// Title over subtitle — or, when the finished job states one, its
/// headline: green, semibold, a size up when something was found (Find
/// Master's "FOUND this clip in 3 recordings (10 files)"), otherwise the
/// ordinary secondary line.
struct MediaFileOperationRowText: View {
    let title: String
    let subtitle: String
    let headline: MediaFileOperationHeadline?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 13, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                // Gauntlet flow 4 matches the balanced file's row
                // by this title text. Test-only.
                .accessibilityIdentifier("mfo.row.title")
            if let headline {
                Text(headline.text)
                    .font(.system(size: headline.isFound ? 15 : 11,
                                  weight: headline.isFound ? .semibold : .regular))
                    .foregroundStyle(headline.isFound ? Color.green : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(headline.text)
                    .accessibilityIdentifier("mfo.row.subtitle")
            } else {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityIdentifier("mfo.row.subtitle")
            }
        }
    }
}

/// The click affordance (Rick 2026-10-26): rows that expand carry ▸/▾.
/// The click itself stays on the row's whole summary area.
struct MediaFileOperationDisclosure: View {
    let isExpandable: Bool
    let isExpanded: Bool

    var body: some View {
        if isExpandable {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 10)
                .accessibilityIdentifier("mfo.row.disclosure")
        }
    }
}
