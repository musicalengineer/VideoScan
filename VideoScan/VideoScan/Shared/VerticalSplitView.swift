// VerticalSplitView.swift
// Wraps NSSplitView for jiggle-free vertical resizing.
// SwiftUI's DragGesture + .frame(height:) causes layout oscillation;
// NSSplitView handles divider dragging at the AppKit level.

import SwiftUI
import AppKit

/// A two-pane vertical split view backed by NSSplitView.
/// The top pane has a preferred initial height; the bottom gets the rest.
struct VerticalSplitView<Top: View, Bottom: View>: NSViewControllerRepresentable {
    let topMinHeight: CGFloat
    let topIdealHeight: CGFloat
    let topMaxHeight: CGFloat
    @ViewBuilder let top: () -> Top
    @ViewBuilder let bottom: () -> Bottom

    func makeNSViewController(context: Context) -> SplitViewController<Top, Bottom> {
        let vc = SplitViewController<Top, Bottom>()
        vc.topMinHeight = topMinHeight
        vc.topIdealHeight = topIdealHeight
        vc.topMaxHeight = topMaxHeight
        vc.installPanes(top: top(), bottom: bottom())
        return vc
    }

    func updateNSViewController(_ vc: SplitViewController<Top, Bottom>, context: Context) {
        // Push the latest topIdealHeight through so viewDidLayout can
        // re-apply it when the SwiftUI side learns the row count after
        // the first layout pass (Rick 2026-06-15).
        vc.topIdealHeight = topIdealHeight
        vc.updatePanes(top: top(), bottom: bottom())
    }
}

final class SplitViewController<Top: View, Bottom: View>: NSSplitViewController {
    var topMinHeight: CGFloat = 60
    var topIdealHeight: CGFloat = 200 {
        didSet {
            // Requests a re-layout so viewDidLayout fires and our
            // "growth + no user drag" branch can re-position the divider.
            view.needsLayout = true
        }
    }
    var topMaxHeight: CGFloat = 400

    private var topHosting: NSHostingController<AnyView>?
    private var bottomHosting: NSHostingController<AnyView>?
    private var didSetInitialPosition = false
    /// Last position we set programmatically. If the current divider sits
    /// at this value, the user hasn't dragged → safe to re-apply on growth.
    private var lastAppliedPos: CGFloat = -1

    func installPanes(top: Top, bottom: Bottom) {
        let topVC = NSHostingController(rootView: AnyView(top))
        let bottomVC = NSHostingController(rootView: AnyView(bottom))
        topHosting = topVC
        bottomHosting = bottomVC

        let topItem = NSSplitViewItem(viewController: topVC)
        topItem.minimumThickness = topMinHeight
        topItem.canCollapse = false
        // Hold preferred height until user drags
        topItem.holdingPriority = .defaultLow + 1

        let bottomItem = NSSplitViewItem(viewController: bottomVC)
        bottomItem.minimumThickness = 100
        bottomItem.canCollapse = false

        addSplitViewItem(topItem)
        addSplitViewItem(bottomItem)

        splitView.isVertical = false  // horizontal divider (top/bottom split)
        splitView.dividerStyle = .thin
    }

    func updatePanes(top: Top, bottom: Bottom) {
        topHosting?.rootView = AnyView(top)
        bottomHosting?.rootView = AnyView(bottom)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard splitView.frame.height > 0 else { return }

        let desiredPos = min(topIdealHeight, splitView.frame.height * 0.5)

        if !didSetInitialPosition {
            didSetInitialPosition = true
            splitView.setPosition(desiredPos, ofDividerAt: 0)
            lastAppliedPos = desiredPos
            return
        }

        // Re-apply when topIdealHeight grew AND the user hasn't dragged
        // since our last placement. We detect "no drag" by comparing the
        // current top-pane height to the last position we set — if they
        // match within a few pixels, layout hasn't been perturbed by a
        // user action.
        let currentTopHeight = splitView.subviews.first?.frame.height ?? 0
        let userDragged = abs(currentTopHeight - lastAppliedPos) > 4
        if !userDragged && desiredPos > currentTopHeight + 4 {
            splitView.setPosition(desiredPos, ofDividerAt: 0)
            lastAppliedPos = desiredPos
        }
    }
}
