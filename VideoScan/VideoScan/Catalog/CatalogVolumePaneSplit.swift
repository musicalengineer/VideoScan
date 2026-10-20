// CatalogVolumePaneSplit.swift
// Where the Catalog's volumes / files divider sits (Rick 2026-10-20: "the
// catalog table gets the room, not the volumes pane").
//
//   First launch (nothing remembered): the volumes pane is sized to its
//   content — toolbar, header, rows, footer (`scanTargetsPaneAutoHeight`)
//   — but never more than 40 % of the split; the files table gets the rest.
//   After Rick drags the divider: that height is remembered (UserDefaults,
//   strict read) and restored every time the Catalog opens.
//   Window resizes: the volumes pane keeps its height; the files table
//   takes the change (the Finder's sidebar behaviour).
//
// Why AppKit at all: SwiftUI's `VSplitView` is NSSplitView-backed but has
// no divider-position API, and in practice it splits the space evenly
// whatever `idealHeight` says. So an empty probe view behind the top pane
// finds its enclosing NSSplitView and drives the divider through
// `setPosition(_:ofDividerAt:)`, the documented NSSplitView call. A drag is
// told apart from a programmatic move by the notification's
// "NSSplitViewDividerIndex" key, which AppKit sets only for user drags.
// If the probe ever cannot find its split (a future SwiftUI), nothing
// happens: the pane falls back to `idealHeight`, as before.
//
// (For Rick: `NSViewRepresentable` ≈ an adapter that lets a SwiftUI view
// own a plain AppKit NSView; the probe below draws nothing and takes no
// clicks — its only job is to look up the view tree, like walking parent
// pointers in C++.)

import AppKit
import SwiftUI

// MARK: - The rule (pure)

/// The volumes pane's height for a split of a given height. Pure, so the
/// policy is pinned by tests rather than by a running window.
enum CatalogVolumePaneHeight {
    /// The same floors the two panes' `.frame(minHeight:)` declare.
    static let minimumTop: CGFloat = 60
    static let minimumBottom: CGFloat = 100
    /// Content-fit never takes more than this share of the split.
    static let maximumContentShare: CGFloat = 0.40

    /// A remembered height wins (clamped so both panes keep their floors);
    /// otherwise the content's own height, capped at 40 % of the split.
    static func target(remembered: CGFloat?, contentFit: CGFloat, splitHeight: CGFloat) -> CGFloat {
        let wanted = remembered ?? min(contentFit, splitHeight * maximumContentShare)
        let ceiling = max(minimumTop, splitHeight - minimumBottom)
        return min(max(wanted, minimumTop), ceiling)
    }
}

// MARK: - The remembered height (UserDefaults, strict read)

/// Rick's last dragged height. Anything but a finite positive number reads
/// as "nothing remembered" (a poisoned value never pins the divider).
enum CatalogVolumePaneSetting {
    static let key = "catalog.volumePaneHeight"

    static func remembered(_ defaults: UserDefaults = .standard) -> CGFloat? {
        guard let number = defaults.object(forKey: key) as? NSNumber else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value > 0 else { return nil }
        return CGFloat(value)
    }

    static func remember(_ height: CGFloat, _ defaults: UserDefaults = .standard) {
        defaults.set(Double(height), forKey: key)
    }
}

// MARK: - The probe

/// Put on the TOP pane of the Catalog's root `VSplitView` as a background.
/// `contentFit` is the pane's content height (`scanTargetsPaneAutoHeight`).
struct CatalogVolumeSplitAnchor: NSViewRepresentable {
    let contentFit: CGFloat

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.contentFit = contentFit
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) {
        probe.contentFit = contentFit
    }

    /// Main-actor by inheritance (NSView ≈ "UI-thread only" in C++ terms).
    final class Probe: NSView {
        /// The key AppKit puts in the resize notification ONLY for a drag.
        private static let draggedDividerKey = "NSSplitViewDividerIndex"

        /// A new content height re-fits the pane — unless Rick has placed
        /// the divider himself, which then stays where he put it.
        var contentFit: CGFloat = 0 {
            didSet { if contentFit != oldValue { applyTarget() } }
        }
        private weak var split: NSSplitView?
        /// True while this probe moves the divider, so its own move is not
        /// mistaken for a resize it should answer.
        private var isPositioning = false

        /// Never the target of a click: the volumes table above it is.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            detach()
            guard window != nil else { return }
            // Next turn of the run loop: the split view has been laid out.
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }

        private func attach() {
            guard window != nil, split == nil, let found = enclosingVerticalStack() else { return }
            split = found
            NotificationCenter.default.addObserver(self, selector: #selector(splitDidResize(_:)),
                                                   name: NSSplitView.didResizeSubviewsNotification, object: found)
            applyTarget()
        }

        private func detach() {
            if let split {
                NotificationCenter.default.removeObserver(self, name: NSSplitView.didResizeSubviewsNotification,
                                                          object: split)
            }
            split = nil
        }

        /// The nearest NSSplitView above this probe that stacks its panes
        /// top-to-bottom (`isVertical == false` — AppKit's "vertical" names
        /// the DIVIDER) and whose first pane holds this probe.
        private func enclosingVerticalStack() -> NSSplitView? {
            var node = superview
            while let view = node {
                if let candidate = view as? NSSplitView, !candidate.isVertical,
                   let top = candidate.arrangedSubviews.first, isDescendant(of: top) {
                    return candidate
                }
                node = view.superview
            }
            return nil
        }

        @objc private func splitDidResize(_ note: Notification) {
            guard !isPositioning, let split else { return }
            if note.userInfo?[Self.draggedDividerKey] != nil {
                // Rick dragged it: remember where.
                if let top = split.arrangedSubviews.first {
                    CatalogVolumePaneSetting.remember(top.frame.height)
                }
            } else {
                // The window (or SwiftUI) resized the split: hold the pane.
                applyTarget()
            }
        }

        /// Move the divider to the rule's height, if it is not there already.
        private func applyTarget() {
            guard let split, let top = split.arrangedSubviews.first, split.arrangedSubviews.count > 1 else { return }
            let splitHeight = split.bounds.height
            guard splitHeight > 0, contentFit > 0 else { return }
            let target = CatalogVolumePaneHeight.target(remembered: CatalogVolumePaneSetting.remembered(),
                                                        contentFit: contentFit, splitHeight: splitHeight)
            guard abs(top.frame.height - target) >= 1 else { return }
            isPositioning = true
            split.setPosition(target, ofDividerAt: 0)
            isPositioning = false
        }
    }
}
