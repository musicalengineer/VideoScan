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

    /// Measured column frames, keyed by `VolumeColumnID`, in the pane's
    /// coordinate space. Empty until the first layout pass reports.
    var columnFrames: [String: CGRect] = [:]

    // MARK: Type scale
    //
    // The LABELS match the volume-name cell exactly — 15pt medium SF
    // Mono, the style every data cell in the table above uses (Rick
    // 2026-08-11: "the text I am talking about… not the sum totals").
    // At 10pt they read as chrome bolted under the table; at the table's
    // own size they read as part of it.
    //
    // Figures stay the same family and size but go one weight heavier,
    // which is the whole hierarchy: identical typeface keeps the footer
    // in the table's optical register, while semibold + `.primary`
    // against the labels' `.secondary` keeps the numbers the thing your
    // eye lands on. SF Mono's fixed advance also holds the three figures
    // aligned under their columns for free.
    //
    // The trailing parenthetical is the exception — deliberately left
    // small. At 15pt mono it is ~380pt of text and would push the row
    // past the window on anything but a maximized display.
    private static let figureFont = Font.system(size: 15, weight: .semibold, design: .monospaced)
    private static let labelFont = Font.system(size: 15, weight: .medium, design: .monospaced)
    private static let captionFont = Font.system(size: 11, weight: .regular)

    /// Set while the catalog is still being recomputed after a scan, so
    /// the numbers can visibly mark themselves stale rather than
    /// confidently displaying a figure that is about to change.
    var isStale: Bool = false

    // MARK: Derived geometry

    /// Content origin of a measured column, falling back to the
    /// screenshot-fitted constant only until the first layout arrives.
    private func columnX(_ id: String, fallback: CGFloat) -> CGFloat {
        let f = columnFrames[id] ?? .zero
        return f.width > 0 ? f.minX : fallback
    }

    private var mediaSizeX: CGFloat {
        columnX(VolumeColumnID.mediaSize, fallback: VolumeTableMetrics.fallbackMediaSizeX)
    }
    /// Scanned/Phase fallbacks are derived from the Media Size anchor so
    /// that even the unmeasured first frame keeps the figures in order
    /// and non-overlapping.
    private var scannedX: CGFloat {
        max(columnX(VolumeColumnID.scanned,
                    fallback: mediaSizeX + VolumeTableMetrics.fallbackMediaSizeWidth),
            mediaSizeX + 60)
    }
    private var phaseX: CGFloat {
        max(columnX(VolumeColumnID.phase, fallback: scannedX + 100), scannedX + 60)
    }

    /// One figure per column: gross under Media Size, online under
    /// Scanned, unique under Phase (Rick 2026-08-11). Each cell spans
    /// exactly to the next anchor, so the three figures line up with the
    /// data above them and read as a column rather than a sentence.
    /// The row's cells live in separate properties, not inline in `body`.
    ///
    /// Not style: the inline version was ONE ~70-line ViewBuilder
    /// expression with ~35 chained modifiers, and Swift's type-checker
    /// could not solve it inside its time limit on GitHub's virtualised
    /// M1 — "unable to type-check this expression in reasonable time",
    /// 2026-08-30. It compiled fine on the M4 Max, so the failure was
    /// invisible locally and only appeared when CI came back after eleven
    /// weeks down. SwiftUI's generic composition makes inference cost grow
    /// super-linearly with the number of chained modifiers in one
    /// expression; splitting gives the solver several small problems
    /// instead of one large one.
    ///
    /// A @ViewBuilder property used inside an HStack produces the same
    /// TupleView the inline code did, so layout and behaviour are
    /// unchanged. Do not re-inline these to "tidy up".

    /// "TOTAL CATALOG" — trailing-aligned against the figure it
    /// introduces. Truncates rather than overlapping when the window
    /// narrows.
    @ViewBuilder private var totalCatalogLabel: some View {
        Text("TOTAL CATALOG")
            .font(Self.labelFont)
            .foregroundColor(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(width: max(0, mediaSizeX - VolumeTableMetrics.labelGutter),
                   alignment: .trailing)
            .padding(.trailing, VolumeTableMetrics.labelGutter)
    }

    /// Gross — on the Media Size origin, totalling the column directly
    /// above it. `fixedSize` + `minWidth`: a figure must never truncate,
    /// so an unusually wide number pushes the next cell right instead of
    /// being clipped.
    @ViewBuilder private var grossFigure: some View {
        Text(totals.grossDisplay)
            .font(Self.figureFont)
            .foregroundColor(.primary)
            .lineLimit(1)
            .fixedSize()
            .frame(minWidth: max(0, scannedX - mediaSizeX), alignment: .leading)
    }

    /// ONLINE NOW — on the Scanned origin. Shown only when it differs from
    /// the catalog total; on a day when every drive is plugged in, a third
    /// identical number is noise.
    @ViewBuilder private var onlineFigure: some View {
        if totals.onlineBytes != totals.grossBytes {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("ONLINE")
                    .font(Self.labelFont)
                    .foregroundColor(.secondary)
                    .fixedSize()
                Text(totals.onlineDisplay)
                    .font(Self.figureFont)
                    .foregroundColor(.primary)
                    .fixedSize()
            }
            .frame(minWidth: max(0, phaseX - scannedX), alignment: .leading)
        }
    }

    /// UNIQUE — on the Phase origin (Rick's request).
    @ViewBuilder private var uniqueFigure: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(totals.uniqueDisplay)
                .font(Self.figureFont)
                .foregroundColor(.primary)
                .fixedSize()
            Text("UNIQUE")
                .font(Self.labelFont)
                .foregroundColor(.secondary)
                .fixedSize()
            // The one element allowed to truncate — least load-bearing
            // text in the row.
            Text("(\(totals.uniqueCaption))")
                .font(Self.captionFont)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(-1)
            // The only signpost that a full waterfall exists — with the
            // captions gone the tooltip is the sole disclosure of what
            // "unique" subtracted, and an invisible tooltip is no
            // disclosure at all. Becomes a warning when the figure is an
            // upper bound.
            Image(systemName: totals.uniqueIsUpperBound
                  ? "exclamationmark.circle" : "info.circle")
                .font(.system(size: 10))
                .foregroundColor(totals.uniqueIsUpperBound ? .orange : .secondary)
                .fixedSize()
        }
        .layoutPriority(1)
    }

    @ViewBuilder private var stalePill: some View {
        if isStale {
            Text("updating…")
                .font(Self.captionFont)
                .foregroundColor(.secondary)
                .padding(.trailing, 12)
        }
    }

    private var accessibilitySentence: String {
        "Total media in catalog \(totals.grossDisplay). "
            + "Online now \(totals.onlineDisplay). "
            + "\(totals.uniqueDisplay) unique media, \(totals.uniqueCaption)."
            + (totals.manuallyDeletedCaption.map { " \($0)." } ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(alignment: .firstTextBaseline, spacing: 0) {
                totalCatalogLabel
                grossFigure
                onlineFigure
                uniqueFigure
                Spacer(minLength: 8)
                stalePill
            }
            .padding(.top, 7)
            .padding(.bottom, totals.manuallyDeletedCaption == nil ? 7 : 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.underPageBackgroundColor).opacity(0.5))
            .contentShape(Rectangle())
            .help(totals.breakdownTooltip)
            .opacity(isStale ? 0.55 : 1.0)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilitySentence)
            .accessibilityIdentifier("catalog.totalMediaFooter")

            // Honesty caption (Rick 2026-08-18): the gross figure now
            // EXCLUDES records marked Manually Deleted, to agree with
            // the catalog view — but Migrate's safely-redundant rule
            // marks without touching the file, so those bytes are very
            // often still occupying a drive. Say so, under the figure
            // they were removed from, in the footer's caption register.
            // Absent entirely when there is nothing to disclose, so the
            // common case pays no height for it.
            if let caption = totals.manuallyDeletedCaption {
                Text(caption)
                    .font(Self.captionFont)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, mediaSizeX)
                    .padding(.bottom, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(NSColor.underPageBackgroundColor).opacity(0.5))
                    .opacity(isStale ? 0.55 : 1.0)
                    .accessibilityIdentifier("catalog.totalMediaFooter.manuallyDeleted")
            }
        }
        // Gap between the summary band and the catalog toolbar
        // below it (Rick 2026-08-11: the middle of the window reads
        // as crammed). Applied OUTSIDE the background so it is real
        // whitespace, not a taller tinted band.
        .padding(.bottom, 10)
    }

    /// Height the pane's auto-sizing math must reserve. Kept next to the
    /// layout it describes so the two stay in step.
    static let height: CGFloat = 48
    /// Extra height when the manually-deleted caption line is showing.
    static let captionLineHeight: CGFloat = 16

    /// Height for a given totals value — the pane's auto-size math calls
    /// this so the caption line never squeezes a volume row off screen.
    static func height(for totals: CatalogStorageTotals) -> CGFloat {
        height + (totals.manuallyDeletedCaption == nil ? 0 : captionLineHeight)
    }
}
