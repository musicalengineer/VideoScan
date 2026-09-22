// CatalogDuplicatesMenuTests.swift
// Regression tests for the "Delete Duplicates on Volume… flashes and won't
// let me pick a volume" bug (Rick 2026-09-22, Release b334247b).
//
// Root cause: SwiftUI re-syncs a toolbar Menu's NSMenu whenever the view
// CONTAINING the menu re-evaluates its body, and an open submenu collapses
// when that happens. The Duplicates menu sat inline in CatalogToolbar, which
// re-evaluated on every model publish and every CatalogView re-render —
// and CatalogView re-rendered at 4 Hz while any Media File Operation ran
// (it subscribed to MediaFileOperationsCenter just to start jobs).
//
// Suites (filter by SUITE name — -only-testing at method granularity runs
// zero Swift Testing tests):
//   CatalogDuplicatesMenuEquatableTests      — logic: == compares values,
//                                              never closures; titles
//   CatalogDuplicatesMenuIsolationTests      — isolation: neither the menu
//                                              nor CatalogView subscribes
//                                              to the model / the center
//   CatalogDuplicatesMenuSubmenuSensorTests  — sensor: a REAL NSMenu opened
//                                              in the test host, submenu
//                                              opened with the keyboard,
//                                              parent re-rendered 4×/s; the
//                                              submenu must stay open. A
//                                              control case proves the
//                                              harness still detects the
//                                              pre-fix collapse.
//
// Swift Testing for a C++ reader: `@Suite struct` ≈ a GTest fixture class,
// `@Test func` ≈ TEST_F, `#expect` ≈ EXPECT_TRUE (records and continues),
// `#require` ≈ ASSERT_TRUE (stops the test).

import Testing
import Foundation
import SwiftUI
import AppKit
import Combine
@testable import VideoScan

// MARK: - Logic

@Suite("CatalogDuplicatesMenu — equality and titles")
@MainActor
struct CatalogDuplicatesMenuEquatableTests {

    private func menu(isReadOnly: Bool = false, isAnalyzing: Bool = false, isDeleting: Bool = false,
                      isDisabled: Bool = false, hasSelection: Bool = false,
                      volumes: [CatalogDuplicatesMenu.Volume] = [.init(path: "/Volumes/SanDisk", count: 12)],
                      cleanUp: Bool = false, hint: String? = nil,
                      tag: Int = 0) -> CatalogDuplicatesMenu {
        // `tag` only changes what the closures capture — it must never
        // affect equality.
        CatalogDuplicatesMenu(isReadOnly: isReadOnly, isAnalyzing: isAnalyzing, isDeleting: isDeleting,
                              isDisabled: isDisabled, hasSelection: hasSelection, volumes: volumes,
                              alsoCleanUpWorkingCopies: cleanUp, reanalyzeHint: hint,
                              onFindDuplicates: { _ = tag },
                              onFindDuplicatesOfSelected: { _ = tag },
                              onDeleteDuplicates: { _, _ in _ = tag },
                              onSetAlsoCleanUpWorkingCopies: { _ in _ = tag })
    }

    /// The whole point: a parent re-render hands over FRESH closures with
    /// the same values, and the menu must compare equal so SwiftUI skips it.
    @Test func freshClosuresWithSameValuesAreEqual() {
        #expect(menu(tag: 1) == menu(tag: 2))
    }

    /// Every value the menu shows must break equality, or the menu would go
    /// stale (the negative side of the test above).
    @Test func everyShownValueBreaksEquality() {
        let base = menu()
        #expect(base != menu(isReadOnly: true))
        #expect(base != menu(isAnalyzing: true))
        #expect(base != menu(isDeleting: true))
        #expect(base != menu(isDisabled: true))
        #expect(base != menu(hasSelection: true))
        #expect(base != menu(volumes: []))
        #expect(base != menu(volumes: [.init(path: "/Volumes/SanDisk", count: 13)]))
        #expect(base != menu(volumes: [.init(path: "/Volumes/LaCie", count: 12)]))
        #expect(base != menu(volumes: [.init(path: "/Volumes/SanDisk", count: 12),
                                       .init(path: "/Volumes/X9", count: 1)]))
        #expect(base != menu(cleanUp: true))
        #expect(base != menu(hint: "Settings changed — run Find Duplicates again"))
    }

    @Test func volumeTitlesNameTheDriveAndPluralise() {
        #expect(CatalogDuplicatesMenu.title(for: .init(path: "/Volumes/SanDisk", count: 12)) == "SanDisk — 12 files")
        #expect(CatalogDuplicatesMenu.title(for: .init(path: "/Volumes/SanDisk", count: 1)) == "SanDisk — 1 file")
    }
}

// MARK: - Isolation

@Suite("CatalogDuplicatesMenu — observation isolation")
@MainActor
struct CatalogDuplicatesMenuIsolationTests {

    /// Type names of every stored property, via reflection. `Mirror` ≈ a
    /// runtime field walk; property wrappers show up as their wrapper type
    /// (e.g. `EnvironmentObject<VideoScanModel>` for `_model`).
    private func storedPropertyTypes(of value: Any) -> [String: String] {
        var out: [String: String] = [:]
        for child in Mirror(reflecting: value).children {
            out[child.label ?? "?"] = String(describing: type(of: child.value))
        }
        return out
    }

    /// The menu is value-only: no wrapper that subscribes to anything.
    @Test func menuObservesNothing() {
        let m = CatalogDuplicatesMenu(isReadOnly: false, isAnalyzing: false, isDeleting: false,
                                      isDisabled: false, hasSelection: false, volumes: [],
                                      alsoCleanUpWorkingCopies: false, reanalyzeHint: nil,
                                      onFindDuplicates: {}, onFindDuplicatesOfSelected: {},
                                      onDeleteDuplicates: { _, _ in }, onSetAlsoCleanUpWorkingCopies: { _ in })
        let observing = storedPropertyTypes(of: m).filter { _, type in
            type.contains("EnvironmentObject") || type.contains("ObservedObject") || type.contains("StateObject")
        }
        #expect(observing.isEmpty, "CatalogDuplicatesMenu must not observe any object — found \(observing)")
    }

    /// CatalogView must not SUBSCRIBE to the Media File Operations center:
    /// the center re-broadcasts job progress at 4 Hz and every CatalogView
    /// re-render rebuilt the toolbar. It holds a non-observing reference.
    @Test func catalogViewDoesNotSubscribeToTheCenter() {
        let types = storedPropertyTypes(of: CatalogView())
        let subscribing = types.filter { _, type in
            type.contains("MediaFileOperationsCenter")
                && (type.contains("EnvironmentObject") || type.contains("ObservedObject") || type.contains("StateObject"))
        }
        #expect(subscribing.isEmpty, "CatalogView subscribes to MediaFileOperationsCenter again: \(subscribing)")
        // Positive counterweight: the non-observing reference is there, so
        // the Delete Duplicates buttons can still start jobs.
        #expect(types.values.contains { $0.contains("Environment<Optional<MediaFileOperationsCenter>>") },
                "CatalogView lost its non-observing center reference: \(types.filter { $0.value.contains("Environment<") })")
    }
}

// MARK: - Sensor: a real open submenu under parent re-renders

/// Drives parent re-renders. `@Published` ≈ a field whose setter notifies
/// observers.
@MainActor
private final class SubmenuSensorTicker: ObservableObject {
    @Published var n = 0
}

/// The PRE-FIX shape: the menu inline in a body that re-evaluates.
private struct InlineDuplicatesToolbar: View {
    let tick: Int
    let volumes: [CatalogDuplicatesMenu.Volume]
    let onDelete: (String, Int) -> Void
    var body: some View {
        HStack {
            Text("status \(tick)")
            Menu {
                Button("Find Duplicates") {}
                Divider()
                Menu("Delete Duplicates on Volume…") {
                    ForEach(volumes, id: \.path) { v in
                        Button(CatalogDuplicatesMenu.title(for: v)) { onDelete(v.path, v.count) }
                    }
                }
            } label: { Label("Duplicates", systemImage: "doc.on.doc") }
            .menuStyle(.borderlessButton)
        }
    }
}

/// The FIXED shape, exactly as CatalogToolbar builds it: the real
/// CatalogDuplicatesMenu behind `.equatable()`, beside a status text that
/// changes every tick, with fresh closures every render.
private struct FixedDuplicatesToolbar: View {
    let tick: Int
    let volumes: [CatalogDuplicatesMenu.Volume]
    let onDelete: (String, Int) -> Void
    var body: some View {
        HStack {
            Text("status \(tick)")
            CatalogDuplicatesMenu(isReadOnly: false, isAnalyzing: false, isDeleting: false,
                                  isDisabled: false, hasSelection: false, volumes: volumes,
                                  alsoCleanUpWorkingCopies: false, reanalyzeHint: nil,
                                  onFindDuplicates: {}, onFindDuplicatesOfSelected: { _ = tick },
                                  onDeleteDuplicates: onDelete, onSetAlsoCleanUpWorkingCopies: { _ in })
            .equatable()
        }
    }
}

private struct SubmenuSensorHost: View {
    @ObservedObject var ticker: SubmenuSensorTicker
    let fixed: Bool
    var body: some View {
        let n = ticker.n
        let volumes: [CatalogDuplicatesMenu.Volume] = [.init(path: "/Volumes/SanDisk", count: 12),
                                                       .init(path: "/Volumes/X9", count: 3)]
        // A fresh closure every render, like CatalogView's onDeleteDuplicates.
        let onDelete: (String, Int) -> Void = { _, _ in _ = n }
        if fixed {
            FixedDuplicatesToolbar(tick: n, volumes: volumes, onDelete: onDelete)
        } else {
            InlineDuplicatesToolbar(tick: n, volumes: volumes, onDelete: onDelete)
        }
    }
}

@Suite("CatalogDuplicatesMenu — submenu survives re-renders (sensor)", .serialized)
@MainActor
struct CatalogDuplicatesMenuSubmenuSensorTests {

    static let submenuTitle = "Delete Duplicates on Volume…"

    /// What the top menu had highlighted at each re-render tick.
    struct Trace {
        var openedBeforeTicks = false
        var highlightedPerTick: [String] = []
        var topMenuEndedEarly = false
    }

    private func findPopup(_ v: NSView) -> NSPopUpButton? {
        if let p = v as? NSPopUpButton { return p }
        for s in v.subviews { if let p = findPopup(s) { return p } }
        return nil
    }

    /// Post an arrow key into the app's own event queue — the menu's
    /// tracking loop reads it like a real key press. No TCC needed
    /// (NSApp.postEvent never leaves the process).
    private func arrow(_ keyCode: UInt16, _ functionKey: Int, window: NSWindow) {
        let chars = String(UnicodeScalar(UInt32(functionKey))!)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                        timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil,
                                        characters: chars, charactersIgnoringModifiers: chars,
                                        isARepeat: false, keyCode: keyCode) {
                NSApp.postEvent(e, atStart: false)
            }
        }
    }

    /// Open the Duplicates menu for real, walk the keyboard to the
    /// submenu (Down until it is highlighted, then Right opens it), then
    /// re-render the parent 8 times at 4 Hz — the center's forwarding
    /// rate — sampling what the top menu has highlighted after each.
    /// `performClick` blocks inside AppKit's menu-tracking loop; the timer
    /// is added in `.common` mode so it fires during tracking (≈ a
    /// callback registered for every run-loop mode, including the one a
    /// modal menu runs in).
    private func trace(fixed: Bool) async throws -> Trace {
        let ticker = SubmenuSensorTicker()
        let host = NSHostingView(rootView: SubmenuSensorHost(ticker: ticker, fixed: fixed))
        let window = NSWindow(contentRect: NSRect(x: 240, y: 240, width: 520, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        host.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(300))
        let popup = try #require(findPopup(host), "no NSPopUpButton backs the SwiftUI Menu any more")

        var result = Trace()
        var phase = 0          // 0 = walking Down to the item, 1 = opened, 2 = re-rendering
        var downPresses = 0
        var rerenders = 0
        var cancelled = false
        let endObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification, object: popup.menu, queue: nil) { _ in
            MainActor.assumeIsolated { if !cancelled { result.topMenuEndedEarly = true } }
        }
        defer { NotificationCenter.default.removeObserver(endObserver) }
        let timer = Timer(timeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated {
                let highlighted = popup.menu?.highlightedItem?.title ?? "-"
                switch phase {
                case 0:
                    // Walk down one item per tick until the submenu item is
                    // highlighted (disabled items and dividers are skipped by
                    // AppKit), then Right opens it. Give up after 8 presses.
                    if highlighted == Self.submenuTitle {
                        arrow(124, NSRightArrowFunctionKey, window: window)
                        phase = 1
                    } else if downPresses < 8 {
                        arrow(125, NSDownArrowFunctionKey, window: window)
                        downPresses += 1
                    } else {
                        cancelled = true
                        popup.menu?.cancelTracking()
                    }
                case 1:
                    result.openedBeforeTicks = highlighted == Self.submenuTitle
                        && popup.menu?.highlightedItem?.submenu != nil
                    ticker.n += 1
                    phase = 2
                default:
                    if rerenders < 8 {
                        result.highlightedPerTick.append(highlighted)
                        ticker.n += 1
                        rerenders += 1
                    } else {
                        cancelled = true
                        popup.menu?.cancelTracking()
                    }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        popup.performClick(nil)
        timer.invalidate()
        return result
    }

    /// THE sensor: with the fixed shape, 8 parent re-renders at 4 Hz leave
    /// the "Delete Duplicates on Volume…" submenu open.
    @Test func fixedMenuKeepsSubmenuOpenThroughParentRerenders() async throws {
        let t = try await trace(fixed: true)
        try #require(t.openedBeforeTicks,
                     "harness could not open the submenu with the keyboard — no evidence either way")
        #expect(!t.topMenuEndedEarly, "the Duplicates menu closed by itself")
        #expect(t.highlightedPerTick.count == 8)
        #expect(t.highlightedPerTick.allSatisfy { $0 == Self.submenuTitle },
                "submenu collapsed under parent re-renders: \(t.highlightedPerTick)")
    }

    /// CONTROL: the pre-fix inline shape collapses at the first re-render.
    /// If this starts failing, SwiftUI stopped resetting open menus on
    /// re-render and the sensor above no longer proves anything — revisit
    /// rather than delete.
    @Test func inlineMenuCollapsesUnderParentRerendersControl() async throws {
        let t = try await trace(fixed: false)
        try #require(t.openedBeforeTicks,
                     "harness could not open the submenu with the keyboard — no evidence either way")
        #expect(t.highlightedPerTick.contains { $0 != Self.submenuTitle },
                "inline menu no longer collapses on re-render (SwiftUI behaviour changed?): \(t.highlightedPerTick)")
    }
}
