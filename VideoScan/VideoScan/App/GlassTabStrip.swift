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
//  blend like droplets. The track behind them is frosted material, not
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
        GlassEffectContainer(spacing: isLarge ? 14 : 10) {
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

    private func tabButton(_ item: Item) -> some View {
        let isSelected = selection == item.tag
        let isHovered = hoveredTag == item.tag && !isSelected
        return Button {
            withAnimation(reduceMotion ? .smooth(duration: 0.25)
                                       : .bouncy(duration: 0.45, extraBounce: 0.12)) {
                selection = item.tag
            }
        } label: {
            Label(item.label, systemImage: item.icon)
                .font(.system(size: fontSize, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .overlay(alignment: .topTrailing) {
                    badge(item.tag).offset(x: 6, y: -4)
                }
                .padding(.horizontal, isLarge ? 14 : 10)
                .padding(.vertical, isLarge ? 7 : 4)
                .background {
                    if isSelected {
                        Color.clear
                            .glassEffect(.regular.tint(Color.accentColor.opacity(0.30)).interactive(),
                                         in: .capsule)
                            .glassEffectID("selection", in: glassNS)
                    } else if isHovered {
                        Color.clear
                            .glassEffect(.regular.interactive(), in: .capsule)
                            .glassEffectID("hover", in: glassNS)
                    }
                }
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
