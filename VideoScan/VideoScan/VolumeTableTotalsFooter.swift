// VolumeTableTotalsFooter.swift
// The "TOTAL MEDIA" row pinned under the volume table (Rick, 2026-08-09,
// restyled 2026-08-10).
//
//     Volume      Status   Files Errors Media Size Scanned   Phase
//     LaCieWork…  Connected 6,892   32     2.64 TB  Aug 7   Cataloged
//     MediaExpa…  Connected   137    —     1.23 TB  Aug 7   Cataloged
//     ═══════════════════════════════════════════════════════════════
//                     TOTAL MEDIA      6.8 TB   3.8 TB UNIQUE
//                                      ^ under Media Size, so the
//                                        column visibly adds up
//
// ALWAYS VISIBLE, BY CONSTRUCTION. This view is a SIBLING of the `Table`
// inside scanTargetsPane's VStack, not a row inside it. That placement
// is the whole trick: it sits outside the table's scroll view, so it
// cannot scroll away no matter how many volumes are listed. Making it a
// real table row would also have made it selectable and sortable — a
// totals row would migrate into the middle of the list the moment you
// sorted by Media Size.
//
// ALIGNMENT IS MEASURED, NOT ASSUMED. `mediaSizeFrame` arrives from the
// Media Size cell itself via MediaSizeColumnFrameKey. The first attempt
// at this footer instead pinned the columns to fixed widths and computed
// offsets — which bunched the data columns at the left edge and cost the
// table its proportions. Measuring keeps the original resizable columns
// AND survives column drags and window resizes.
//
// COST. Pure layout over an already-computed `CatalogStorageTotals`
// value — no records touched, no O(n) work in this body. The arithmetic
// happens in CatalogStorageTotalsCalculator, off the view body, on the
// pane's existing catalog-change triggers.

import SwiftUI

struct VolumeTableTotalsFooter: View {

    let totals: CatalogStorageTotals

    /// Measured frame of the Media Size column, in the pane's coordinate
    /// space. `.zero` until the first layout pass reports it.
    var mediaSizeFrame: CGRect = .zero

    /// Set while the catalog is still being recomputed after a scan, so
    /// the numbers can visibly mark themselves stale rather than
    /// confidently displaying a figure that is about to change.
    var isStale: Bool = false

    // MARK: Derived geometry

    private var columnX: CGFloat {
        mediaSizeFrame.width > 0 ? mediaSizeFrame.minX : VolumeTableMetrics.fallbackMediaSizeX
    }

    private var columnWidth: CGFloat {
        mediaSizeFrame.width > 0 ? mediaSizeFrame.width : VolumeTableMetrics.fallbackMediaSizeWidth
    }

    /// Gross figure starts exactly at the Media Size column's content
    /// origin, so it reads as the sum of the numbers directly above it.
    /// UNIQUE follows one column-width later — i.e. at the next column
    /// boundary — which keeps the two figures from crowding each other
    /// no matter how wide the numbers get.
    private var uniqueOffset: CGFloat {
        max(columnWidth, VolumeTableMetrics.figureGap)
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(alignment: .firstTextBaseline, spacing: 0) {

                // "TOTAL MEDIA IN CATALOG:" — Rick's wording, and a
                // better label than the "TOTAL MEDIA" it replaced: the
                // figure covers every catalogued volume while the table
                // above defaults to a Connected filter, so the rows
                // routinely sum to LESS. "IN CATALOG" is what explains
                // that gap without a second line of chrome.
                //
                // Trailing-aligned so it butts up against the figure it
                // introduces, wherever measurement puts that figure.
                // Truncates rather than overlapping: no `fixedSize` here
                // — at narrow window widths the frame shrinks, and a
                // fixed-size single line would have drawn straight over
                // the gross number instead of ellipsizing.
                Text("TOTAL MEDIA IN CATALOG:")
                    .font(.system(size: 13, weight: .heavy))
                    .kerning(0.5)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: max(0, columnX - VolumeTableMetrics.labelGutter),
                           alignment: .trailing)
                    .padding(.trailing, VolumeTableMetrics.labelGutter)

                // Gross — sitting on the Media Size column origin.
                // `fixedSize` + `minWidth` (not a hard width): a figure
                // must never truncate, so if the number is wider than
                // the column it pushes UNIQUE right rather than being
                // clipped or overlapped.
                Text(totals.grossDisplay)
                    .font(.system(size: 19, weight: .bold, design: .monospaced))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(minWidth: uniqueOffset, alignment: .leading)

                // Unique. Same white as the gross figure (Rick
                // 2026-08-10) — the accent color read as a link.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(totals.uniqueDisplay)
                        .font(.system(size: 19, weight: .bold, design: .monospaced))
                        .foregroundColor(.primary)
                        .fixedSize()
                    Text("UNIQUE MEDIA")
                        .font(.system(size: 13, weight: .heavy))
                        .kerning(0.5)
                        .foregroundColor(.secondary)
                        .fixedSize()
                    // Regular weight, smaller: heavy across the full
                    // parenthetical shouted over the numbers. This is
                    // also the ONE element allowed to truncate — it is
                    // the least load-bearing text in the row.
                    Text("(\(totals.uniqueCaption))")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(-1)
                    // The only signpost that a full waterfall exists.
                    // With the captions gone the tooltip is the sole
                    // disclosure of what "unique" subtracted, and an
                    // invisible tooltip is no disclosure at all. Turns
                    // into a warning when the figure is an upper bound.
                    Image(systemName: totals.uniqueIsUpperBound
                          ? "exclamationmark.circle" : "info.circle")
                        .font(.system(size: 11))
                        .foregroundColor(totals.uniqueIsUpperBound ? .orange : .secondary)
                        .fixedSize()
                }
                .layoutPriority(1)

                Spacer(minLength: 8)

                if isStale {
                    Text("updating…")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(.trailing, 12)
                }
            }
            .padding(.vertical, 9)
            // The explanatory captions under both figures are gone at
            // Rick's request (2026-08-10) — they made the row busy. The
            // full waterfall still lives one hover away in the tooltip,
            // which is also where the "upper bound" caveat now surfaces
            // when duplicate coverage is thin, so removing the captions
            // costs disclosure but not honesty.
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.underPageBackgroundColor).opacity(0.5))
            .contentShape(Rectangle())
            .help(totals.breakdownTooltip)
            .opacity(isStale ? 0.55 : 1.0)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "Total media in catalog \(totals.grossDisplay). "
                + "\(totals.uniqueDisplay) unique media, \(totals.uniqueCaption)."
            )
            .accessibilityIdentifier("catalog.totalMediaFooter")
        }
    }

    /// Height the pane's auto-sizing math must reserve. Kept next to the
    /// layout it describes so the two stay in step.
    static let height: CGFloat = 40
}
