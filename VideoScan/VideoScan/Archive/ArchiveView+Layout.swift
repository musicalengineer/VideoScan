import SwiftUI

// MARK: - Archive tab: vertical layout policy
//
// Bug 2026-09-24 (Rick): the Archive header ("128 verified · 2,508 to go"
// progress bar) and the top of the sidebar collage disappeared under the
// window's title/tab bar. Root cause: the right pane (`fileList`) was a plain
// VStack — toolbar, progress bar, ArchiveAngelStrip, timeline — and the
// strip's turndown (ten 90–130 pt senior-friendly rows, plus "Show 10 more")
// has NO height bound. When the VStack's minimum height exceeded the window,
// the HSplitView grew past the window and SwiftUI centred the overflow, so
// BOTH panes lost their top (and bottom) edges. Hide Tab Bar could not help:
// the chrome was never the culprit.
//
// Two rules keep the header on screen whatever the Angel shows:
//   1. The Angel strip lives in a HuggingScrollRegion: as tall as its
//      content up to a cap (a share of the pane), then it scrolls.
//   2. Each split pane is framed minHeight 0 / maxHeight ∞ / alignment .top,
//      so any future overflow clips at the BOTTOM, never under the chrome.
// ArchivePaneLayoutTests pins both (logic + source sensor).

/// Pure numbers for the Archive pane's Angel region. No SwiftUI state.
enum ArchivePaneLayout {
    /// The Angel region may use at most this share of the right pane's
    /// height; the rest stays with the header and the timeline.
    static let angelMaxFraction: CGFloat = 0.6
    /// A usable window onto the list even in a short pane (about one and a
    /// half rows plus the strip's own header line).
    static let angelMinCap: CGFloat = 200

    /// The tallest the Angel region may be in a pane `paneHeight` tall.
    /// Before the first measurement (0) the floor applies.
    static func angelRegionCap(paneHeight: CGFloat) -> CGFloat {
        guard paneHeight.isFinite, paneHeight > 0 else { return angelMinCap }
        return max(angelMinCap, (paneHeight * angelMaxFraction).rounded(.down))
    }

    /// Hug the content when it is short; stop at the cap when it is tall.
    static func regionHeight(contentHeight: CGFloat, cap: CGFloat) -> CGFloat {
        guard contentHeight.isFinite, contentHeight > 0 else { return 0 }
        return min(contentHeight, max(0, cap))
    }
}

/// A vertical ScrollView that is only as tall as its content, up to
/// `maxHeight`, then scrolls.
///
/// C++ analogy: a plain `ScrollView` is "greedy" — like a widget whose size
/// policy is Expanding, it takes every point the parent offers, which would
/// leave a blank gap under a short strip. Here we measure the content's
/// natural height (the ScrollView proposes an unbounded height to its child,
/// so the measurement is the child's ideal size) and pin the frame to
/// min(content, cap). `onGeometryChange` is the observer callback; the
/// `@State` it writes is view-owned storage that survives re-renders.
struct HuggingScrollRegion<Content: View>: View {
    let maxHeight: CGFloat
    let content: Content

    @State private var contentHeight: CGFloat = 0

    init(maxHeight: CGFloat, @ViewBuilder content: () -> Content) {
        self.maxHeight = maxHeight
        self.content = content()
    }

    var body: some View {
        ScrollView(.vertical) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { newHeight in
                    contentHeight = newHeight
                }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: ArchivePaneLayout.regionHeight(contentHeight: contentHeight, cap: maxHeight))
    }
}
