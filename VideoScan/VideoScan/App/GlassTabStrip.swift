//
//  GlassTabStrip.swift
//  VideoScan
//
//  The app's one tab-strip look (Rick 2026-10-04, macOS 27 refresh): tabs
//  in a floating Liquid Glass capsule, the selected one riding a tinted
//  capsule that slides between tabs. Used by the main window's tab bar and
//  by sub-tab bars (People ▸ Find Person / Identify Family) so every level
//  of navigation reads the same. Glass is for navigation only — content
//  keeps solid backing for senior-readable contrast.
//

import SwiftUI

struct GlassTabStrip<Badge: View>: View {
    typealias Item = (label: String, icon: String, tag: Int)

    @Binding var selection: Int
    let items: [Item]
    let fontSize: Double
    /// Per-tab overlay at the label's top-trailing corner (status dots).
    @ViewBuilder var badge: (Int) -> Badge

    @Namespace private var selectionNS

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items, id: \.tag) { item in
                tabButton(item)
            }
        }
        .padding(fontSize >= 16 ? 5 : 3)
        .glassEffect(.regular, in: .capsule)
    }

    private func tabButton(_ item: Item) -> some View {
        let isSelected = selection == item.tag
        return Button {
            withAnimation(.smooth(duration: 0.3)) { selection = item.tag }
        } label: {
            Label(item.label, systemImage: item.icon)
                .font(.system(size: fontSize, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .overlay(alignment: .topTrailing) {
                    badge(item.tag).offset(x: 6, y: -4)
                }
                .padding(.horizontal, fontSize >= 16 ? 14 : 10)
                .padding(.vertical, fontSize >= 16 ? 7 : 4)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(Color.accentColor.opacity(0.18))
                            .matchedGeometryEffect(id: "selectedTab", in: selectionNS)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // XCUITest hook: e.g. "tab.Catalog".
        .accessibilityIdentifier("tab.\(item.label)")
    }
}

extension GlassTabStrip where Badge == EmptyView {
    init(selection: Binding<Int>, items: [Item], fontSize: Double) {
        self.init(selection: selection, items: items, fontSize: fontSize) { _ in EmptyView() }
    }
}
