// ArchiveDecadeRibbon.swift
// Archive tab — the horizontal decade ribbon (Rick 2026-10-06). Replaces
// the vertical DECADES rail: the Archive tab's one job is walking the
// family archive by decade, so the decades run across the top like the
// macOS Dock. As the pointer moves along the ribbon each decade grows with
// its nearness to the pointer (ArchiveRibbonMagnifier, max 1.6×). The
// selected decade sits under the tinted glass lens the tab strip uses.
//
// Dwell to zoom: rest on a decade for ~0.6 s and its ten years open as a
// smaller second row under it (years with no media dimmed). Click a year to
// go to it; leaving the ribbon collapses the row.
//
// Cost: the ribbon owns its hover state, so pointer motion re-renders the
// ribbon only — O(decades) per frame (about a dozen views), never the
// stream of cards below. Slot centres are arithmetic on a fixed slot
// width; the only geometry read is the ribbon's own width, once per resize.
//
// Glass is navigation-only: the ribbon's track is solid; only the lens on
// the selected decade is glass (through App/GlassCompat.swift).

import SwiftUI

struct ArchiveDecadeRibbon: View {
    let ticks: [ArchiveDecadeTick]
    /// The decade under the lens (nil until something is picked).
    let selectedID: Int?
    let onSelect: (Int) -> Void
    /// A year clicked in the dwell-zoom row.
    let onPickYear: (Int) -> Void

    /// Pointer x in the ribbon's content coordinates; nil when away.
    @State private var hoverX: Double?
    /// The decade slot under the pointer (drives the dwell timer).
    @State private var hoverIndex: Int?
    /// The decade whose years are open in the second row.
    @State private var zoomIndex: Int?
    /// The pending dwell. (For Rick: a `Task` here ≈ a cancellable
    /// one-shot timer; cancelling it before 0.6 s means it never fires.)
    @State private var dwellTask: Task<Void, Never>?
    /// Keyboard cursor (index into `ticks`) for ←/→ + Return.
    @State private var keyIndex: Int?
    /// Measured once per resize (onGeometryChange), sizes the slots.
    @State private var ribbonWidth: Double = 0
    /// Read-only: shows the keyboard cursor while the ribbon has focus.
    /// Nothing here ever WRITES focus (Rick's rule, Catalog fix 10/6).
    @FocusState private var isFocused: Bool

    static let minSlot: Double = 92
    static let edgePad: Double = 12
    /// Tall enough for a decade at the full 1.6× (scaled from the bottom).
    static let rowHeight: Double = 84
    static let yearRowHeight: Double = 34
    static let yearCellWidth: Double = 56
    static let dwell: Duration = .milliseconds(600)

    var body: some View {
        let slot = slotWidth
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                decadeRow(slot: slot)
                if let zoomIndex, ticks.indices.contains(zoomIndex) {
                    yearRow(ticks[zoomIndex], index: zoomIndex, slot: slot)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            // `.local` = coordinates of the scrolled CONTENT, so slot
            // centres line up even when the ribbon scrolls sideways.
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let point): pointerMoved(to: point, slot: slot)
                case .ended: pointerLeft()
                }
            }
        }
        .frame(height: Self.rowHeight + (zoomIndex == nil ? 0 : Self.yearRowHeight))
        .frame(maxWidth: .infinity)
        // Solid track, not glass: the lens on the selected decade is the
        // ribbon's one piece of glass (no glass on glass).
        .background(Color(NSColor.controlBackgroundColor))
        .onGeometryChange(for: Double.self) { proxy in
            proxy.size.width
        } action: { width in
            ribbonWidth = width
        }
        .onDisappear { dwellTask?.cancel() }
        // (For Rick: `.focusable()` makes the ribbon a Tab stop; the key
        // handlers run only while it holds focus — like a widget's
        // keyPressEvent override.)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(.leftArrow) { moveKeyCursor(by: -1) }
        .onKeyPress(.rightArrow) { moveKeyCursor(by: 1) }
        .onKeyPress(.return) { commitKeyCursor() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Decades")
        .accessibilityIdentifier("archive.timeline.ribbon")
    }

    // MARK: Layout arithmetic (no per-item geometry)

    /// Slots share the measured width evenly, never narrower than
    /// `minSlot` (the ribbon scrolls sideways if they don't fit).
    private var slotWidth: Double {
        guard !ticks.isEmpty, ribbonWidth > 0 else { return Self.minSlot }
        return max(Self.minSlot, (ribbonWidth - 2 * Self.edgePad) / Double(ticks.count))
    }

    private var contentWidth: Double {
        2 * Self.edgePad + Double(ticks.count) * slotWidth
    }

    private func centreX(of index: Int, slot: Double) -> Double {
        Self.edgePad + (Double(index) + 0.5) * slot
    }

    private func slotIndex(atX x: Double, slot: Double) -> Int? {
        let i = Int(((x - Self.edgePad) / slot).rounded(.down))
        return ticks.indices.contains(i) ? i : nil
    }

    /// Where the bulge is centred: the pointer, else the keyboard cursor
    /// while the ribbon has focus, else nowhere (everything at 1×).
    private func bulgeX(slot: Double) -> Double? {
        if let hoverX { return hoverX }
        if isFocused, let keyIndex { return centreX(of: keyIndex, slot: slot) }
        return nil
    }

    private func scale(of index: Int, slot: Double, bulge: Double?) -> Double {
        guard let bulge else { return 1 }
        let distanceInSlots = (bulge - centreX(of: index, slot: slot)) / slot
        return ArchiveRibbonMagnifier.scale(distance: distanceInSlots,
                                            radius: ArchiveRibbonMagnifier.radiusInSlots)
    }

    // MARK: Hover + dwell

    private func pointerMoved(to point: CGPoint, slot: Double) {
        guard point.y <= Self.rowHeight else {
            // Down in the year row: hold the zoomed decade magnified while
            // a year is picked, and keep the row open.
            hoverX = zoomIndex.map { centreX(of: $0, slot: slot) }
            return
        }
        hoverX = point.x
        let index = slotIndex(atX: point.x, slot: slot)
        guard index != hoverIndex else { return }
        hoverIndex = index
        startDwell(on: index)
    }

    /// Restart the 0.6 s timer for the decade under the pointer. Moving
    /// to another decade replaces the open year row once the new dwell
    /// completes, so a slightly diagonal path down to a year never
    /// snaps it shut.
    private func startDwell(on index: Int?) {
        dwellTask?.cancel()
        guard let index, !ticks[index].isUndated else { return }
        dwellTask = Task { @MainActor in
            try? await Task.sleep(for: Self.dwell)
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.2)) { zoomIndex = index }
        }
    }

    /// Moving away collapses everything.
    private func pointerLeft() {
        dwellTask?.cancel()
        hoverIndex = nil
        withAnimation(.easeOut(duration: 0.2)) {
            hoverX = nil
            zoomIndex = nil
        }
    }

    // MARK: The decade row

    private func decadeRow(slot: Double) -> some View {
        let bulge = bulgeX(slot: slot)
        return HStack(spacing: 0) {
            ForEach(Array(ticks.enumerated()), id: \.element.id) { index, tick in
                slotView(tick, index: index, slot: slot,
                         scale: scale(of: index, slot: slot, bulge: bulge))
            }
        }
        .padding(.horizontal, Self.edgePad)
        .frame(height: Self.rowHeight)
    }

    private func slotView(_ tick: ArchiveDecadeTick, index: Int, slot: Double,
                          scale: Double) -> some View {
        let isSelected = tick.id == selectedID
        let showsKeyCursor = isFocused && keyIndex == index
        return VStack(spacing: 1) {
            Text(tick.label)
                .font(.system(size: 17, weight: tick.isGap ? .regular : .semibold))
            Text(tick.isGap ? "—" : "\(tick.count)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(labelColor(tick))
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background {
            if isSelected {
                Color.clear.vsGlassCapsule(tint: Color.accentColor.opacity(0.22))
            }
        }
        .overlay {
            if showsKeyCursor {
                Capsule().strokeBorder(Color.accentColor, lineWidth: 1.5)
            }
        }
        .scaleEffect(scale, anchor: .bottom)
        .frame(width: slot, height: Self.rowHeight - 8, alignment: .bottom)
        .contentShape(Rectangle())
        .onTapGesture { onSelect(tick.id) }
        .help(helpText(for: tick))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { onSelect(tick.id) }
        .accessibilityIdentifier("archive.timeline.decade.\(tick.id)")
    }

    private func labelColor(_ tick: ArchiveDecadeTick) -> Color {
        if tick.isUndated { return .orange }
        return tick.isGap ? .secondary : .primary
    }

    private func helpText(for tick: ArchiveDecadeTick) -> String {
        if tick.isUndated {
            return "Archived without a resolvable year. Set a date in the Inspector to file these in their year."
        }
        if tick.isGap {
            return "No media yet from the \(tick.label) — tapes in the attic?"
        }
        return "\(tick.count) archived from \(tick.id)–\(tick.id + 9)"
    }

    // MARK: The year row (dwell zoom)

    /// The decade's ten years, centred under its slot (clamped to the
    /// ribbon's ends). Years with no media are dimmed and inert.
    private func yearRow(_ tick: ArchiveDecadeTick, index: Int, slot: Double) -> some View {
        let rowWidth = Self.yearCellWidth * Double(tick.years.count)
        let width = max(contentWidth, rowWidth)
        let leading = min(max(0, centreX(of: index, slot: slot) - rowWidth / 2), width - rowWidth)
        return HStack(spacing: 0) {
            ForEach(tick.years, id: \.self) { year in
                yearCell(year, hasMedia: tick.yearsWithMedia.contains(year))
            }
        }
        .frame(width: rowWidth, height: Self.yearRowHeight)
        .offset(x: leading)
        .frame(width: width, height: Self.yearRowHeight, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("archive.timeline.years")
    }

    private func yearCell(_ year: Int, hasMedia: Bool) -> some View {
        Text(String(year))
            .font(.system(size: 14, weight: hasMedia ? .medium : .regular, design: .monospaced))
            .foregroundStyle(hasMedia ? Color.primary : Color.secondary.opacity(0.45))
            .frame(width: Self.yearCellWidth, height: Self.yearRowHeight - 6)
            .contentShape(Rectangle())
            .onTapGesture { if hasMedia { onPickYear(year) } }
            .help(hasMedia ? "Go to \(year)" : "Nothing archived from \(year) yet")
            .accessibilityAddTraits(hasMedia ? .isButton : [])
            .accessibilityIdentifier("archive.timeline.year.\(year)")
    }

    // MARK: Keyboard (←/→ move, Return selects)

    private func moveKeyCursor(by step: Int) -> KeyPress.Result {
        guard !ticks.isEmpty else { return .ignored }
        let start = keyIndex ?? ticks.firstIndex { $0.id == selectedID } ?? 0
        keyIndex = min(max(start + step, 0), ticks.count - 1)
        return .handled
    }

    private func commitKeyCursor() -> KeyPress.Result {
        guard let keyIndex, ticks.indices.contains(keyIndex) else { return .ignored }
        onSelect(ticks[keyIndex].id)
        return .handled
    }
}
