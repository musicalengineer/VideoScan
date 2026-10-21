// PreflightQAR2RedTests.swift
// QA round 2 on b29a15d08: RED tests authored by the reviewer.

import Foundation
import Testing
@testable import VideoScanCore

extension LaunchPreflightTests {

    /// LaunchPreflight.swift:289-303 — the 10-minute re-check
    /// (`includeQuickCheck: false`) builds a NEW situation from the fast
    /// checks alone, so a damaged catalog found by the launch quick_check
    /// stops holding edits ten minutes later, though nothing re-checked it.
    @Test func qaR2_fastOnlyRecheckMustNotLiftALaunchQuickCheckFault() async throws {
        var probe = FakePreflightProbe.healthy()
        probe.quickCheck = .problems(["Page 7: btreeInitPage() returns error code 11"], elapsed: .milliseconds(5))
        let launch = try await LaunchPreflight.run(Self.context, probe: probe)
        #expect(launch.hold == .edits)
        let recheck = try await LaunchPreflight.run(Self.context, probe: probe, includeQuickCheck: false)
        #expect(recheck.hold == .edits, "the damaged catalog is still damaged; the re-check lifted the hold (\(recheck.hold))")
        #expect(PreflightGate.decide(.edit, in: recheck.situation) != .go)
    }
}

@Suite("PreflightCancellation QA r2")
struct PreflightCancellationQAR2Tests {

    /// PreflightCancellation.swift:49-60 — an already-cancelled token runs the
    /// handler (sqlite3_interrupt) BEFORE the body, then runs the body anyway.
    /// SQLite drops an interrupt that arrives while no statement is active
    /// (sqlite3_step clears isInterrupted when nVdbeActive == 0), so the
    /// quick_check that follows runs to its full 5 s budget on quit.
    @Test func qaR2_alreadyCancelledTokenDoesNotRunTheBody() {
        let token = PreflightCancellation()
        token.cancel()
        var bodyRan = false
        try? token.whileRegistered({}) { bodyRan = true }
        #expect(!bodyRan, "a cancelled token still ran quick_check's body")
    }
}
