// VolumeColumnAnchors.swift
// Measured volume-table column origins, kept OUT of CatalogView's state —
// the 2026-10-11 resize-crash fix.
//
// THE BUG. The Media Size / Scanned / Phase cells measure themselves
// (GeometryReader → VolumeColumnFramesKey) so the TOTAL MEDIA footer and
// the catalog-ops group can line up under their columns. Until this fix:
//   1. the measurement landed in `@State volumeColumnFrames` on
//      CatalogView, so every new measurement — every layout pass of a
//      live resize, and every scroll of the volume table (the frame's y
//      moved) — re-ran the WHOLE Catalog window body: toolbar, both
//      tables, every banner;
//   2. the measured x positions fed MINIMUM widths (`.frame(minWidth:)`
//      on the volume-ops group, fixed `.frame(width:)` / `minWidth:` in
//      the footer). The pane's minimum width is the window's minimum
//      width (NSHostingView turns it into Auto Layout constraints), so a
//      column that moved during layout changed the window's constraints
//      during layout. AppKit then needs another Update Constraints pass,
//      which lays the table out again, which moves the column … Since the
//      2026-10-06 VSplitView change put both panes in ONE hosting view,
//      that loop runs inside a single window layout. Under catalog churn
//      it beachballed; at 22:53 on 2026-10-11 it hit AppKit's cap ("more
//      Update Constraints in Window passes than there are views") and the
//      app crashed.
//
// THE FIX, in three parts, each of which breaks the loop on its own:
//   • this object holds the frames, and only the two small views that
//     position against them observe it (`VolumeColumnLeadingReserve`,
//     `AnchoredVolumeTableTotalsFooter`) — a new measurement re-renders a
//     spacer and a footer row, not the window;
//   • frames keep only x + width, snapped to whole points, behind a
//     one-point dead band — so sub-pixel jitter (even across a .5
//     rounding boundary) and vertical scrolling publish nothing;
//   • the anchored positions only ever take SLACK — they never raise a
//     minimum width (`frame(maxWidth:)` + layout priority; the footer row
//     reports a zero minimum), so a column moving can no longer change
//     the window's constraints.
//
// (For Rick: an ObservableObject held in `@State` is like a shared_ptr
// the parent owns but never subscribes to — only the children that take
// it as `@ObservedObject` are woken when it publishes.)

import SwiftUI
import Combine

@MainActor
final class VolumeColumnAnchors: ObservableObject {

    /// Snapped column frames keyed by `VolumeColumnID` (x + width only).
    @Published private(set) var frames: [String: CGRect] = [:]

    /// Test hook: how many times `frames` actually published.
    private(set) var publishCount = 0

    /// Fold in a fresh measurement. Publishes only when a column really
    /// moved (`isMeaningfulChange`) — the guard that keeps a layout pass
    /// from scheduling another. Returns whether it published.
    @discardableResult
    func update(_ measured: [String: CGRect]) -> Bool {
        guard !measured.isEmpty, Self.isMeaningfulChange(from: frames, to: measured) else { return false }
        frames = Self.snapped(measured)
        publishCount += 1
        return true
    }

    /// Whole points, x + width only. The consumers read `minX` and
    /// `width > 0`; y and height change on every scroll and must not
    /// count as a new measurement.
    nonisolated static func snapped(_ measured: [String: CGRect]) -> [String: CGRect] {
        measured.mapValues { r in
            CGRect(x: r.minX.rounded(), y: 0, width: r.width.rounded(), height: 0)
        }
    }

    /// A dead band, not just rounding: a value wobbling across a .5
    /// boundary (412.4 ↔ 412.5) would flip its ROUNDED value every pass —
    /// the sensor caught exactly that, 5,000 publishes in 10,000 passes. A
    /// change counts only when a column appears/disappears or its x or
    /// width moves by a full point or more from what is published.
    nonisolated static func isMeaningfulChange(from published: [String: CGRect],
                                               to measured: [String: CGRect]) -> Bool {
        guard Set(published.keys) == Set(measured.keys) else { return true }
        for (key, new) in measured {
            guard let old = published[key] else { return true }
            if abs(new.minX - old.minX) >= 1 || abs(new.width - old.width) >= 1 { return true }
        }
        return false
    }

    /// Where the catalog-ops group starts: the Phase column's measured
    /// origin, minus the toolbar row's 16pt horizontal padding so the
    /// button's leading edge — not its container — lands on the column.
    /// Falls back to a constant until the table publishes a measurement.
    var catalogGroupOriginX: CGFloat { Self.catalogGroupOriginX(frames: frames) }

    nonisolated static func catalogGroupOriginX(frames: [String: CGRect]) -> CGFloat {
        let phase = frames[VolumeColumnID.phase] ?? .zero
        let x = phase.width > 0
            ? phase.minX
            : VolumeTableMetrics.fallbackMediaSizeX + 210
        return max(0, x - 16)
    }
}

/// Reserves the volume-ops group's width up to the Phase column so the
/// catalog-ops group starts on it (Rick 2026-08-12) — using SLACK only.
/// `frame(maxWidth:)` with no minimum: the group is as wide as the anchor
/// when there is room, as wide as its own content when that is wider
/// (the verbs push the catalog group right rather than being clipped),
/// and its MINIMUM is its content's minimum — never the measured anchor.
/// Layout priority 1 hands it the row's slack before the trailing Spacer.
struct VolumeColumnLeadingReserve: ViewModifier {
    @ObservedObject var anchors: VolumeColumnAnchors

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: anchors.catalogGroupOriginX, alignment: .leading)
            .layoutPriority(1)
    }
}

/// The TOTAL MEDIA footer, observing the anchors itself so a column move
/// re-renders this row only. The outer flexible frame reports a ZERO
/// minimum and ideal width: the footer's column-aligned figures can never
/// make the window's minimum wider (on a very narrow window they run off
/// the trailing edge instead of forcing the window open).
struct AnchoredVolumeTableTotalsFooter: View {
    @ObservedObject var anchors: VolumeColumnAnchors
    let totals: CatalogStorageTotals
    var archivedBytes: Int64?
    var archivedHelp: String = ""
    var showAgainModel: VideoScanModel?

    var body: some View {
        VolumeTableTotalsFooter(totals: totals,
                                columnFrames: anchors.frames,
                                archivedBytes: archivedBytes,
                                archivedHelp: archivedHelp,
                                showAgainModel: showAgainModel)
            .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, alignment: .leading)
    }
}
