// FolderChevronStyle.swift
// The folder view's disclosure chevrons, bright enough to see on the dark
// theme (Rick 2026-10-19: "the chevron is nearly invisible").
//
// SwiftUI's `DisclosureTableRow` draws the system's outline chevron and
// offers no way to size or colour it. This invisible background view finds
// the NSOutlineView behind the folder Table and gives each disclosure
// button a bolder, larger template chevron in the label colour. It does the
// usual `outlineView(_:didAdd:forRow:)` customisation, from outside, because
// SwiftUI owns the delegate. It re-applies after a scroll, a twist or a SwiftUI
// update, because rows are recycled. If a future macOS changes the
// view tree, nothing breaks: the chevrons just go back to the system's.
//
// (For Rick: NSViewRepresentable ≈ a C++ adapter that hosts an AppKit
// object inside the SwiftUI tree; the Coordinator is its long-lived state.)

import AppKit
import SwiftUI

struct FolderChevronStyle: NSViewRepresentable {
    /// Changes whenever the rows change, so SwiftUI calls updateNSView.
    let revision: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.anchor = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.scheduleRestyle()
    }

    @MainActor
    final class Coordinator {
        weak var anchor: NSView?
        private weak var outline: NSOutlineView?
        /// Written only on the main actor (watch); read once more in deinit,
        /// when nothing else can reach the coordinator.
        private nonisolated(unsafe) var observers: [NSObjectProtocol] = []

        static let collapsed = chevron("chevron.right")
        static let expanded = chevron("chevron.down")

        private static func chevron(_ name: String) -> NSImage? {
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .bold)
            let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
            image?.isTemplate = true
            return image
        }

        /// One run-loop turn later, so the outline has laid out its rows.
        func scheduleRestyle() {
            DispatchQueue.main.async { [weak self] in self?.restyle() }
        }

        private func restyle() {
            guard let outline = findOutline() else { return }
            let visible = outline.rows(in: outline.visibleRect)
            for row in visible.location..<(visible.location + visible.length) {
                guard let rowView = outline.rowView(atRow: row, makeIfNecessary: false) else { continue }
                Self.styleButtons(in: rowView)
            }
        }

        private static func styleButtons(in view: NSView) {
            for sub in view.subviews {
                if let button = sub as? NSButton,
                   button.identifier == NSOutlineView.disclosureButtonIdentifier {
                    if button.image !== collapsed {
                        button.image = collapsed
                        button.alternateImage = expanded
                        button.contentTintColor = .labelColor
                    }
                } else {
                    styleButtons(in: sub)
                }
            }
        }

        /// The outline view this background sits behind: the nearest
        /// ancestor that holds one. Found once, then watched.
        private func findOutline() -> NSOutlineView? {
            if let outline { return outline }
            var node = anchor?.superview
            while let n = node {
                if let found = Self.firstOutline(under: n) {
                    outline = found
                    watch(found)
                    return found
                }
                node = n.superview
            }
            return nil
        }

        private static func firstOutline(under view: NSView) -> NSOutlineView? {
            if let o = view as? NSOutlineView { return o }
            for sub in view.subviews {
                if let o = firstOutline(under: sub) { return o }
            }
            return nil
        }

        private func watch(_ outline: NSOutlineView) {
            let center = NotificationCenter.default
            let restyle: @Sendable (Notification) -> Void = { [weak self] _ in
                Task { @MainActor in self?.scheduleRestyle() }
            }
            if let clip = outline.enclosingScrollView?.contentView {
                clip.postsBoundsChangedNotifications = true
                observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main, using: restyle))
            }
            for name in [NSOutlineView.itemDidExpandNotification, NSOutlineView.itemDidCollapseNotification] {
                observers.append(center.addObserver(forName: name, object: outline, queue: .main, using: restyle))
            }
        }

        deinit {
            for o in observers { NotificationCenter.default.removeObserver(o) }
        }
    }
}
