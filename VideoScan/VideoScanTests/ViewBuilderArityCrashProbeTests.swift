import Testing
import SwiftUI
@testable import VideoScan

// PROBE (overnight 2026-10-04, GH #273): adding an 11th top-level element to
// ArchiveView.recordContextMenu made `AnyView(self.recordContextMenu(for:))`
// SIGSEGV on every launch, inside tuple_initializeWithCopy → initializeWithCopy
// for Button. 10 → 11 elements is where @ViewBuilder leaves its fixed-arity
// buildBlock overloads for the parameter-pack one. These copy 10- and
// 11-element builder tuples of Buttons (each capturing state, like the real
// menu) through AnyView. A crash here is a toolchain/runtime bug, not ours.

@MainActor
private struct MenuHost {
    let ids: [UUID]
    var title = "x"

    @ViewBuilder func ten() -> some View {
        Button(title) { _ = ids }; Divider(); Button(title) { _ = ids }
        if ids.count == 1 { Button(title) { _ = ids } }
        Button(title) { _ = ids }; Button(title) { _ = ids }
        if !ids.isEmpty { Button(title) { _ = ids } }
        if ids.count > 5 { Button(title) { _ = ids } }
        Button(title) { _ = ids }; Divider()
    }

    @ViewBuilder func eleven() -> some View {
        Menu("Show in People tab") { Button(title) { _ = ids } }
        Divider()
        Button(title) { _ = ids }; Divider(); Button(title) { _ = ids }
        if ids.count == 1 { Button(title) { _ = ids } }
        Button(title) { _ = ids }; Button(title) { _ = ids }
        if !ids.isEmpty { Button(title) { _ = ids } }
        if ids.count > 5 { Button(title) { _ = ids } }
        Button(title) { _ = ids }
    }
}

@Suite("PROBE — @ViewBuilder 10 vs 11 elements through AnyView")
@MainActor
struct ViewBuilderArityCrashProbeTests {
    @Test func tenElementsCopyThroughAnyView() {
        let host = MenuHost(ids: [UUID()])
        var views: [AnyView] = []
        for _ in 0..<200 { views.append(AnyView(host.ten())) }
        let copies = views.map { $0 }
        #expect(copies.count == 200)
    }

    @Test func elevenElementsCopyThroughAnyView() {
        let host = MenuHost(ids: [UUID()])
        var views: [AnyView] = []
        for _ in 0..<200 { views.append(AnyView(host.eleven())) }
        let copies = views.map { $0 }
        #expect(copies.count == 200)
    }

    /// The real shape: a closure stored in a child view returns the AnyView,
    /// and SwiftUI builds it during layout of a hosted view.
    @Test func elevenElementsBuiltDuringLayoutInAHostingView() {
        let host = MenuHost(ids: [UUID()])
        let make: (Set<UUID>) -> AnyView = { _ in AnyView(host.eleven()) }
        let view = VStack {
            ForEach(0..<50, id: \.self) { i in
                Text("card \(i)").contextMenu { make([]) }
            }
        }
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 2_000)
        hosting.layoutSubtreeIfNeeded()
        #expect(hosting.fittingSize.height > 0)
    }
}
