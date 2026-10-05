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
    /// Per-tab click counter — drives the icon's one-shot bounce, so only
    /// the tab you just picked bounces (not the one you left).
    @State private var bounceTicks: [Int: Int] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isLarge: Bool { fontSize >= 16 }

    var body: some View {
        // Two layers with identical layout (Rick 2026-10-04: label text
        // vanished under the lens). A GlassEffectContainer composites its
        // glass ABOVE the content it holds, so the glass layer carries only
        // invisible copies of the labels (for size) and the real, clickable
        // labels sit on top, outside the container.
        ZStack {
            VSGlassContainer(spacing: isLarge ? 14 : 10) {
                HStack(spacing: 4) {
                    ForEach(items, id: \.tag) { item in
                        glassSlot(item)
                    }
                }
            }
            .allowsHitTesting(false)
            // Animate the GLASS only (Rick 2026-10-04: clicks felt stodgy).
            // withAnimation around the selection write animated the whole
            // tab swap — the outgoing tab's teardown and the new tab's
            // build (a 100k-row Table) all ran inside the animated
            // transaction. Scoped here, content switches instantly and only
            // the lens and hover bubble move.
            .animation(reduceMotion ? .smooth(duration: 0.25)
                                    : .bouncy(duration: 0.45, extraBounce: 0.12),
                       value: selection)
            .animation(.smooth(duration: 0.2), value: hoveredTag)

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
        return Label {
            Text(item.label)
        } icon: {
            // Vibrant system colours on glass, never a custom tint (Apple HIG;
            // an accent icon on the accent-tinted lens lost contrast in dark
            // mode). The icon bounces once when picked — no layout change,
            // so the glass layer's hidden copy still matches exactly.
            Image(systemName: item.icon)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .symbolEffect(.bounce.up, options: .speed(1.4), value: bounceTicks[item.tag, default: 0])
        }
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
                        .vsGlassCapsule(tint: Color.accentColor.opacity(0.22))
                        .vsGlassID("selection", in: glassNS)
                } else if isHovered {
                    Color.clear
                        .vsGlassCapsule()
                        .vsGlassID("hover", in: glassNS)
                }
            }
    }

    private func tabButton(_ item: Item) -> some View {
        Button {
            if selection != item.tag, !reduceMotion {
                bounceTicks[item.tag, default: 0] += 1
            }
            selection = item.tag
        } label: {
            tabLabel(item)
                .contentShape(Capsule())
        }
        .buttonStyle(GlassTabPressStyle(reduceMotion: reduceMotion))
        .onHover { hovering in
            if hovering {
                hoveredTag = item.tag
            } else if hoveredTag == item.tag {
                hoveredTag = nil
            }
        }
        // XCUITest hook: e.g. "tab.Catalog".
        .accessibilityIdentifier("tab.\(item.label)")
    }
}

/// A tab press dips the label slightly and springs back — the tactile half
/// of the glass (the glass layer itself takes no clicks).
private struct GlassTabPressStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.55), value: configuration.isPressed)
    }
}

extension GlassTabStrip where Badge == EmptyView {
    init(selection: Binding<Int>, items: [Item], fontSize: Double) {
        self.init(selection: selection, items: items, fontSize: fontSize) { _ in EmptyView() }
    }
}
