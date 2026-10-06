// ArchiveDecadeRibbon.swift
// Archive tab — the horizontal decade ribbon (Rick 2026-10-06). Replaces
// the vertical DECADES rail: the Archive tab's one job is walking the
// family archive by decade, so the decades run across the top like the
// macOS Dock. As the pointer moves along the ribbon each decade grows with
// its nearness to the pointer (ArchiveRibbonMagnifier, max 1.6×). The
// selected decade sits under the tinted glass lens the tab strip uses.
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

    /// Pointer x in the ribbon's content coordinates; nil when away.
    @State private var hoverX: Double?
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

    var body: some View {
        let slot = slotWidth
        ScrollView(.horizontal, showsIndicators: false) {
            decadeRow(slot: slot)
        }
        .frame(height: Self.rowHeight)
        .frame(maxWidth: .infinity)
        // Solid track, not glass: the lens on the selected decade is the
        // ribbon's one piece of glass (no glass on glass).
        .background(Color(NSColor.controlBackgroundColor))
        .onGeometryChange(for: Double.self) { proxy in
            proxy.size.width
        } action: { width in
            ribbonWidth = width
        }
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

    private func centreX(of index: Int, slot: Double) -> Double {
        Self.edgePad + (Double(index) + 0.5) * slot
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

    // MARK: The row

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
        // `.local` = coordinates of this row, i.e. the scrolled CONTENT,
        // so slot centres above line up even when the ribbon scrolls.
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let point):
                hoverX = point.x
            case .ended:
                withAnimation(.easeOut(duration: 0.2)) { hoverX = nil }
            }
        }
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
