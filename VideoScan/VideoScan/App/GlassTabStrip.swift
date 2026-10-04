//
//  GlassTabStrip.swift
//  VideoScan
//
//  The app's one tab-strip look (Rick 2026-10-04, macOS 27 refresh). Used by
//  the main window's tab bar and by sub-tab bars (People ▸ Find Person /
//  Identify Family) so every level of navigation reads the same. Glass is
//  for navigation only — content keeps solid backing for senior-readable
//  contrast.
//
//  Phase 2 ("wiggly liquid", Rick 2026-10-04): the selected tab sits under a
//  real Liquid Glass lens that FLOWS to the next tab with a little bounce,
//  and hovering another tab raises a faint glass bubble there. Both live in
//  one GlassEffectContainer, so when the bubble is next to the lens the two
//  blend like droplets. Text sits on a layer above the glass. The track
//  behind them is frosted material, not
//  glass — Apple's guidance is no glass-on-glass (glass can't sample glass).
//  Reduce Motion drops the bounce.
//

import SwiftUI

struct GlassTabStrip<Badge: View>: View {
    typealias Item = (label: String, icon: String, tag: Int)

    @Binding var selection: Int
    let items: [Item]
    let fontSize: Double
    /// Per-tab overlay at the label's top-trailing corner (status dots).
    @ViewBuilder var badge: (Int) -> Badge

    @Namespace private var glassNS
    @State private var hoveredTag: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isLarge: Bool { fontSize >= 16 }

    var body: some View {
        // Two layers with identical layout (Rick 2026-10-04: label text
        // vanished under the lens). A GlassEffectContainer composites its
        // glass ABOVE the content it holds, so the glass layer carries only
        // invisible copies of the labels (for size) and the real, clickable
        // labels sit on top, outside the container.
        ZStack {
            GlassEffectContainer(spacing: isLarge ? 14 : 10) {
                HStack(spacing: 4) {
                    ForEach(items, id: \.tag) { item in
                        glassSlot(item)
                    }
                }
            }
            .allowsHitTesting(false)

            HStack(spacing: 4) {
                ForEach(items, id: \.tag) { item in
                    tabButton(item)
                }
            }
        }
        .padding(isLarge ? 5 : 3)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.10), radius: 8, y: 2)
    }

    private func tabLabel(_ item: Item) -> some View {
        let isSelected = selection == item.tag
        return Label(item.label, systemImage: item.icon)
            .font(.system(size: fontSize, weight: isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? .primary : .secondary)
            .overlay(alignment: .topTrailing) {
                badge(item.tag).offset(x: 6, y: -4)
            }
            .padding(.horizontal, isLarge ? 14 : 10)
            .padding(.vertical, isLarge ? 7 : 4)
    }

    /// The glass under one tab: the lens if selected, the hover bubble if
    /// pointed at, nothing otherwise. Same ids across tabs, so the shapes
    /// flow from tab to tab instead of blinking.
    private func glassSlot(_ item: Item) -> some View {
        let isSelected = selection == item.tag
        let isHovered = hoveredTag == item.tag && !isSelected
        return tabLabel(item)
            .hidden()
            .background {
                if isSelected {
                    Color.clear
                        .glassEffect(.regular.tint(Color.accentColor.opacity(0.30)), in: .capsule)
                        .glassEffectID("selection", in: glassNS)
                } else if isHovered {
                    Color.clear
                        .glassEffect(.regular, in: .capsule)
                        .glassEffectID("hover", in: glassNS)
                }
            }
    }

    private func tabButton(_ item: Item) -> some View {
        Button {
            withAnimation(reduceMotion ? .smooth(duration: 0.25)
                                       : .bouncy(duration: 0.45, extraBounce: 0.12)) {
                selection = item.tag
            }
        } label: {
            tabLabel(item)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.smooth(duration: 0.2)) {
                if hovering {
                    hoveredTag = item.tag
                } else if hoveredTag == item.tag {
                    hoveredTag = nil
                }
            }
        }
        // XCUITest hook: e.g. "tab.Catalog".
        .accessibilityIdentifier("tab.\(item.label)")
    }
}

extension GlassTabStrip where Badge == EmptyView {
    init(selection: Binding<Int>, items: [Item], fontSize: Double) {
        self.init(selection: selection, items: items, fontSize: fontSize) { _ in EmptyView() }
    }
}
