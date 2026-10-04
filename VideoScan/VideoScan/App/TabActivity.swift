//
//  TabActivity.swift
//  VideoScan
//
//  Keep-alive tabs (Rick 2026-10-04): the main window builds each tab once
//  and then HIDES it when you switch away instead of destroying it, so a
//  return visit is instant (a CPU profile showed every click rebuilding the
//  tab and re-running O(records) recounts on the main thread).
//
//  A hidden tab never gets onAppear/onDisappear again. That is the point
//  for work we WANT kept warm (Triage's rows, the steward's watcher stay
//  live while hidden — "build once, keep it in RAM"). Hooks that must stop
//  the moment the tab is not on screen (the Catalog spacebar key monitor,
//  Hallie's current-selection) use `onTabActiveChange` instead: it fires on real appear/disappear AND
//  when the tab is shown or hidden, and keeps the calls strictly paired.
//  Outside the main window (standalone windows) `isActiveTab` is always
//  true, so behaviour there is exactly onAppear/onDisappear.
//

import SwiftUI

extension EnvironmentValues {
    /// False while this view's tab is kept alive but hidden.
    @Entry var isActiveTab: Bool = true
}

extension View {
    /// onAppear/onDisappear that also follows keep-alive tab visibility.
    /// `appear` and `disappear` are always called in pairs.
    func onTabActiveChange(appear: @escaping () -> Void,
                           disappear: @escaping () -> Void) -> some View {
        modifier(TabActiveLifecycle(appear: appear, disappear: disappear))
    }
}

private struct TabActiveLifecycle: ViewModifier {
    let appear: () -> Void
    let disappear: () -> Void

    @Environment(\.isActiveTab) private var isActiveTab
    /// True between a delivered `appear` and its matching `disappear`.
    @State private var isLive = false

    func body(content: Content) -> some View {
        content
            .onAppear { setLive(isActiveTab) }
            .onDisappear { setLive(false) }
            .onChange(of: isActiveTab) { _, active in setLive(active) }
    }

    private func setLive(_ live: Bool) {
        guard live != isLive else { return }
        isLive = live
        if live { appear() } else { disappear() }
    }
}
