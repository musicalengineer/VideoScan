import Testing
import Foundation
import SwiftUI
import AppKit
import Combine
@testable import VideoScan

// MARK: - Dashboard subscription hot-path proof
//
// Question: does removing `@EnvironmentObject var dashboard: DashboardState`
// from a view actually stop dashboard mutations from re-rendering it?
//
// Background: the original Matt-scan sample showed PersonFinderView.body at
// 166 invocations in 30s — the dominant SwiftUI hot path. The view never
// read dashboard.* in its body; the `@EnvironmentObject` declaration was
// pure subscription overhead. This test proves mechanically that removing
// the declaration eliminates the propagation.
//
// Method: mount two synthetic views (otherwise identical) in offscreen
// NSHostingViews, hammer DashboardState with 100 updates, count body
// invocations. The subscribed view re-renders proportionally; the
// unsubscribed view doesn't re-render at all.

@MainActor
final class BodyCounter {
    private var n: Int = 0
    func bump() { n += 1 }
    var count: Int { n }
}

private struct SubscribedView: View {
    @EnvironmentObject var dashboard: DashboardState  // ← the subscription
    let counter: BodyCounter
    var body: some View {
        counter.bump()
        return Color.clear
    }
}

private struct UnsubscribedView: View {
    // No dashboard declaration. Mirrors the PersonFinderView fix.
    let counter: BodyCounter
    var body: some View {
        counter.bump()
        return Color.clear
    }
}

@MainActor
struct DashboardSubscriptionHotPathTests {

    /// Mount a SwiftUI view in an offscreen NSWindow so SwiftUI actually
    /// drives its render loop, and return the window so we can keep it
    /// retained for the test's duration.
    private static func mountOffscreen<V: View>(_ view: V) -> NSWindow {
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        // orderOut keeps the window retained but offscreen — render loop
        // still fires for state changes, which is what we want to measure.
        window.orderOut(nil)
        hosting.layoutSubtreeIfNeeded()
        return window
    }

    /// Pump the main runloop to let SwiftUI process pending invalidations.
    private static func pumpRunloop(seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    @Test func subscribedViewReRendersOnDashboardWrites() async throws {
        let dashboard = DashboardState()
        let counter = BodyCounter()
        let view = SubscribedView(counter: counter).environmentObject(dashboard)
        let window = Self.mountOffscreen(view)

        // Let initial mount settle.
        Self.pumpRunloop(seconds: 0.2)
        let baseline = counter.count

        // Hammer one of the dashboard's @Published props 100 times.
        for i in 0..<100 {
            dashboard.visionFPS = Double(i)
            // Yield so SwiftUI can process each invalidation in its own
            // runloop tick (otherwise SwiftUI coalesces sames-tick writes
            // into one re-render — which would hide the symptom).
            await Task.yield()
            Self.pumpRunloop(seconds: 0.005)
        }
        Self.pumpRunloop(seconds: 0.3)

        let afterCount = counter.count - baseline
        LivePreviewPublishBenchmarkTests.logLine("SUBSCRIBED view body calls after 100 dashboard writes: \(afterCount)")
        _ = window  // keep alive

        // The subscribed view must re-render. Threshold is intentionally
        // generous — SwiftUI's coalescing may collapse some writes, but
        // not all of them.
        #expect(afterCount >= 10, "Subscribed view should re-render many times — got \(afterCount)")
    }

    @Test func unsubscribedViewDoesNotReRenderOnDashboardWrites() async throws {
        let dashboard = DashboardState()
        let counter = BodyCounter()
        // No environmentObject — view doesn't observe dashboard at all.
        let view = UnsubscribedView(counter: counter)
        let window = Self.mountOffscreen(view)

        Self.pumpRunloop(seconds: 0.2)
        let baseline = counter.count

        for i in 0..<100 {
            dashboard.visionFPS = Double(i)
            await Task.yield()
            Self.pumpRunloop(seconds: 0.005)
        }
        Self.pumpRunloop(seconds: 0.3)

        let afterCount = counter.count - baseline
        LivePreviewPublishBenchmarkTests.logLine("UNSUBSCRIBED view body calls after 100 dashboard writes: \(afterCount)")
        _ = window

        // The unsubscribed view MUST NOT re-render from dashboard writes.
        // Exactly 0 expected, but 1-2 allowed for SwiftUI's internal
        // bookkeeping ticks unrelated to the dashboard.
        #expect(afterCount <= 2, "Unsubscribed view should not re-render from dashboard writes — got \(afterCount)")
    }
}
