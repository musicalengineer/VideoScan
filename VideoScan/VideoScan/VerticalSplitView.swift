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
        vc.updatePanes(top: top(), bottom: bottom())
    }
}

final class SplitViewController<Top: View, Bottom: View>: NSSplitViewController {
    var topMinHeight: CGFloat = 60
    var topIdealHeight: CGFloat = 200
    var topMaxHeight: CGFloat = 400

    private var topHosting: NSHostingController<AnyView>?
    private var bottomHosting: NSHostingController<AnyView>?
    private var didSetInitialPosition = false

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
        if !didSetInitialPosition && splitView.frame.height > 0 {
            didSetInitialPosition = true
            let pos = min(topIdealHeight, splitView.frame.height * 0.5)
            splitView.setPosition(pos, ofDividerAt: 0)
        }
    }
}
