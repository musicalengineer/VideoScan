import Testing
import Foundation
@testable import VideoScan

// MARK: - Regression test for the half-iconified sheet-dismiss hang
//
// Bug history (2026-06-02): clicking "Delete Permanently" in the
// DeleteConfirmedJunkConfirmSheet started the sheet dismiss animation,
// got partway through (a small rounded "iconified" stub visible mid-
// collapse), then froze. Cause: the Button's action did synchronous
// work — model.records.filter, VideoScanModel.splitByReachability —
// BEFORE scheduling the async Task. SwiftUI only schedules the
// dismiss animation after the button's action returns, so the inline
// sync work delayed dismiss past the next display refresh window and
// the animation deadlocked partway through.
//
// Fix: extracted the closure body into JunkDeleteAction.makeOnAct,
// which schedules the work inside `Task { @MainActor in ... }` and
// returns immediately. The test below catches the regression
// structurally — any future change that moves the filter or
// splitByReachability back inline will push the closure's return time
// past the 5 ms threshold and fail the test.
//
// TDD verification (Rick's red-green-red discipline): reverting
// `Task { @MainActor in` to inline sync work makes
// `onActReturnsBeforeAnyWork` fail.

@MainActor
struct JunkDeleteActionRegressionTests {

    /// Build a fat catalog of confirmed-junk records so the inline
    /// filter + splitByReachability would be measurably slow if a
    /// regression moves them back to sync. N=10,000 chosen to make
    /// any reasonable inline iteration take >>5 ms; well under that
    /// when properly deferred to a Task.
    private static func fatModel(recordCount: Int = 10_000) -> VideoScanModel {
        let model = VideoScanModel()
        var recs: [VideoRecord] = []
        recs.reserveCapacity(recordCount)
        for i in 0..<recordCount {
            let r = VideoRecord()
            // Internal paths so splitByReachability doesn't hit
            // /Volumes reachability probes — those have a cache but
            // can vary in latency. Internal paths take the fast branch
            // and still expose any "this loop is on main" regression.
            r.fullPath = "/tmp/junk-action-regression-\(i).mov"
            r.filename = "junk-action-regression-\(i).mov"
            r.directory = "/tmp"
            r.ext = "MOV"
            r.mediaDisposition = .confirmedJunk
            r.sizeBytes = 1_000
            recs.append(r)
        }
        model.records = recs
        return model
    }

    @Test func onActReturnsBeforeAnyWork() async throws {
        let model = Self.fatModel()

        // Flag flipped from inside the deferred Task. If the regression
        // moves work back to sync, this would be true on return — the
        // closure would have done the filter + splitByReachability +
        // started the Task before returning. With proper deferral, the
        // Task hasn't been scheduled yet when onAct returns.
        let probe = ProbeRef()

        let onAct = JunkDeleteAction.makeOnAct(model: model) { _, _, _ in
            probe.fired = true
        }

        let startedAt = CFAbsoluteTimeGetCurrent()
        onAct(.permanent)
        let elapsed = CFAbsoluteTimeGetCurrent() - startedAt

        // Threshold: 5 ms is plenty for the closure to schedule a Task
        // and return, but not enough for an inline filter of 10k records
        // (≈100–500 µs each scan = 1–5 ms minimum) plus splitByReachability.
        // If the regression returns, elapsed climbs into double-digit ms.
        #expect(elapsed < 0.005,
                "onAct took \(String(format: "%.3f", elapsed * 1000))ms — should be <5ms; sync work likely crept back into the closure")

        // Sanity: the deferred work eventually runs and onComplete fires.
        // With an empty target set after the filter (all records' files
        // don't exist so they hit alreadyMissing), the Task completes
        // quickly. 2s gives generous slack for slow CI runners.
        let deadline = Date().addingTimeInterval(2.0)
        while !probe.fired && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(probe.fired, "onAct's deferred Task didn't fire onComplete within 2s")
    }

    @Test func onActSchedulesWorkOnMainActor() async throws {
        // The Task runs at @MainActor explicitly so subsequent UI state
        // writes from onComplete are safe without further hopping.
        // Verifying this structurally by calling onAct and then having
        // onComplete do a @MainActor-required mutation; if the Task
        // weren't on MainActor, this would either crash or warn at
        // runtime under strict concurrency.
        let model = VideoScanModel()
        var didMutateOnMain = false
        let onAct = JunkDeleteAction.makeOnAct(model: model) { _, _, _ in
            // If this closure body ran off MainActor, mutating @State on
            // a view would be a violation. We test the simpler invariant:
            // the closure receives the MainActor context.
            MainActor.assertIsolated()
            didMutateOnMain = true
        }
        onAct(.permanent)
        try await Task.sleep(for: .seconds(1))
        #expect(didMutateOnMain, "onComplete didn't fire on MainActor as expected")
    }
}

/// Tiny reference holder so the test can observe a flag flip from
/// inside the deferred Task without dealing with capture-list ceremony.
@MainActor
final class ProbeRef {
    var fired: Bool = false
}
