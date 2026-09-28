import Testing
import Foundation
@testable import VideoScan

// MARK: - PauseGate.toggle() is the USER's switch, whatever else holds the gate
// (night hardening 2026-09-26, coverage audit of 4b0c4079)
//
// 4b0c4079 turned the gate's single Bool into per-owner reasons and
// re-defined toggle() as "toggle the USER pause; return the user-pause
// state". Nothing pinned that definition: the only toggle() test
// (ScanEngineTests) runs on an otherwise-idle gate, where "toggle the user
// reason" and "toggle whatever isPaused says" are indistinguishable.
//
// The regression this guards: a toggle keyed off `isPaused` (the pre-fix
// shape). While memory pressure or a down volume holds the gate, isPaused
// is already true, so the user's Pause press would call resume(.user) — a
// no-op — and add NO user hold. The moment the volume came back or memory
// recovered, the work would run although the user had just paused it.
//
// Deterministic: reasons are added directly, no pressure polling, no sleeps.
// (C++ readers: `#expect(x)` is EXPECT_TRUE(x) — it records and continues;
// `await` on an actor property is a synchronous call through the actor's
// serial queue.)

@Suite struct PauseGateToggleReasonTests {

    @Test("toggle() while ANOTHER reason holds the gate adds the user hold, and that hold outlives the other reason",
          arguments: [PauseReason.memory, PauseReason.volume])
    func toggleWhileHeldByOtherReason_addsUserHold(other: PauseReason) async {
        let gate = PauseGate(pressureCheck: { false }, autoPause: false)
        let owner = UUID()
        await gate.pause(other, owner: owner)
        #expect(await gate.isPaused, "precondition: \(other) holds the gate")
        #expect(await !gate.isUserPaused, "precondition: no user hold yet")

        // The user presses Pause (the toggle button) while the gate is held.
        let userPausedAfterFirst = await gate.toggle()
        #expect(userPausedAfterFirst, "toggle() returns the USER-pause state: the press must register as a pause")
        #expect(await gate.isUserPaused)
        #expect(await gate.pauseReasons == [other, .user])

        // The other owner lets go (memory recovers / the share comes back).
        await gate.resume(other, owner: owner)
        #expect(await gate.isPaused, "the user's pause must survive the \(other) reason being released")
        #expect(await gate.pauseReasons == [.user])

        // The user presses Resume.
        let userPausedAfterSecond = await gate.toggle()
        #expect(!userPausedAfterSecond)
        #expect(await !gate.isPaused)
    }

    @Test("toggle() off does not release a reason it does not own")
    func toggleOff_leavesOtherReasonHeld() async {
        let gate = PauseGate(pressureCheck: { false }, autoPause: false)
        let owner = UUID()
        await gate.pause()                               // user pause first
        await gate.pause(.volume, owner: owner)          // then the share drops
        #expect(await gate.toggle() == false, "the user's Resume clears the user hold")
        #expect(await gate.isPaused, "…but the volume is still down: the gate stays paused")
        #expect(await gate.pauseReasons == [.volume])
        await gate.resume(.volume, owner: owner)
        #expect(await !gate.isPaused)
    }
}
