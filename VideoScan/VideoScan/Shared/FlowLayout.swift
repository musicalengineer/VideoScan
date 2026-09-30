// FlowLayout.swift
// Chips that wrap instead of being crushed.
//
// Rick photographed the Family Tree inspector for "John Johannes Lord
// Viscount Strangford, High Sheriff of Essex, Assistant to King Henry VIII
// Smythe" (2026-09-07). The "Said as" row is one capsule per name word in a
// plain HStack; sixteen capsules in a ~300pt inspector were compressed until
// each label wrapped to ONE CHARACTER PER LINE. It read as a bar chart.
//
// An HStack cannot wrap, so no amount of spacing tuning fixes it — the row
// needs a layout that starts a new line when the next item will not fit.
// SwiftUI's `Layout` protocol (macOS 13+, which is this app's floor) is
// exactly that, and it keeps the call site an ordinary ForEach.

import SwiftUI

/// Left-aligned wrapping row. Items keep their ideal size; when the next one
/// would overflow the proposed width, it starts a new line.
struct FlowLayout: Layout {
    var horizontalSpacing: CGFloat = 6
    var verticalSpacing: CGFloat = 6

    /// Where each subview lands, and how tall the whole thing is, for one
    /// proposed width. Computed once and used by both sizing and placement so
    /// the two can never disagree.
    private struct Arrangement {
        var offsets: [CGPoint]
        var size: CGSize
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> Arrangement {
        // An unconstrained width (a lone chip inside a ScrollView that has not
        // been measured yet) must not become a negative row budget.
        let limit = width.isFinite && width > 0 ? width : .greatestFiniteMagnitude
        var offsets: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            // Wrap before placing, never after: the first item on a line is
            // placed even when it is wider than the limit, so an
            // unexpectedly long chip is clipped rather than sent into an
            // infinite loop of empty lines.
            if x > 0, x + size.width > limit {
                x = 0
                y += lineHeight + verticalSpacing
                lineHeight = 0
            }
            offsets.append(CGPoint(x: x, y: y))
            x += size.width + horizontalSpacing
            widest = max(widest, x - horizontalSpacing)
            lineHeight = max(lineHeight, size.height)
        }
        return Arrangement(offsets: offsets,
                           size: CGSize(width: min(widest, limit), height: y + lineHeight))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        return arrange(subviews, width: proposal.width ?? .greatestFiniteMagnitude).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let arrangement = arrange(subviews, width: bounds.width)
        for (index, subview) in subviews.enumerated() {
            let offset = arrangement.offsets[index]
            subview.place(
                at: CGPoint(x: bounds.minX + offset.x, y: bounds.minY + offset.y),
                anchor: .topLeading,
                proposal: .unspecified)
        }
    }
}
