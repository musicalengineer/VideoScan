// HallieWebServerStartupTests.swift
//
// The listener start-up hand-off (strict-concurrency stage 1, 2026-09-22).
// Before: `failure`/`port` were written on the listener queue and read by the
// caller after a 5 s semaphore wait — on timeout the read raced a late
// `.failed`, and a listener that never became ready was kept without
// throwing. These pin the replacement without opening a socket: first outcome
// wins, a timeout closes the hand-off so a late outcome cannot land, and the
// timeout error says what happened.

import Foundation
import Testing
@testable import VideoScan

@Suite("Hallie web server start-up hand-off")
struct HallieWebServerStartupTests {

    private struct Boom: Error {}

    @Test func readyReportedBeforeTheWaitIsReturned() {
        let startup = HallieListenerStartup()
        #expect(startup.resolve(.ready(port: 8765)))
        let (outcome, _) = startup.finishWaiting(timeout: .seconds(5))
        guard case .ready(let port) = outcome else { Issue.record("expected ready, got \(String(describing: outcome))"); return }
        #expect(port == 8765)
    }

    @Test func failureIsReturnedToTheCaller() {
        let startup = HallieListenerStartup()
        #expect(startup.resolve(.failed(Boom())))
        let (outcome, _) = startup.finishWaiting(timeout: .seconds(5))
        guard case .failed(let error) = outcome else { Issue.record("expected failed, got \(String(describing: outcome))"); return }
        #expect(error is Boom)
    }

    @Test func theFirstOutcomeWins() {
        let startup = HallieListenerStartup()
        #expect(startup.resolve(.ready(port: 1)))
        #expect(!startup.resolve(.failed(Boom())), "a later outcome must not replace the first")
        let (outcome, _) = startup.finishWaiting(timeout: .seconds(5))
        guard case .ready(let port) = outcome else { Issue.record("expected ready"); return }
        #expect(port == 1)
    }

    @Test func aResolveFromTheListenerQueueWakesTheWaiter() {
        let startup = HallieListenerStartup()
        DispatchQueue(label: "test.listener").asyncAfter(deadline: .now() + .milliseconds(20)) {
            startup.note(state: "ready")
            startup.resolve(.ready(port: 4242))
        }
        let (outcome, lastState) = startup.finishWaiting(timeout: .seconds(10))
        guard case .ready(let port) = outcome else { Issue.record("expected ready"); return }
        #expect(port == 4242)
        #expect(lastState == "ready")
    }

    /// The race that was: nothing arrives in time, then `.failed` lands.
    /// The caller has already decided (nil = not ready); the late outcome is
    /// refused rather than written under it.
    @Test func aTimeoutClosesTheHandOffSoALateOutcomeCannotLand() {
        let startup = HallieListenerStartup()
        startup.note(state: "waiting(no network)")
        let (outcome, lastState) = startup.finishWaiting(timeout: .milliseconds(10))
        #expect(outcome == nil)
        #expect(lastState == "waiting(no network)")
        #expect(!startup.resolve(.failed(Boom())), "late .failed after the caller gave up must be refused")
        #expect(!startup.resolve(.ready(port: 9)), "late .ready after the caller gave up must be refused")
    }

    @Test func theTimeoutErrorNamesThePortTheWaitAndTheLastState() {
        let named = HallieWebServer.StartError.notReady(port: 8765, seconds: 5, lastState: "waiting(x)")
        let text = named.localizedDescription
        #expect(text.contains("port 8765"))
        #expect(text.contains("not ready after 5.0 s"))
        #expect(text.contains("waiting(x)"))
        #expect(text.contains("cancelled"))
        let ephemeral = HallieWebServer.StartError.notReady(port: 0, seconds: 0.5, lastState: "setup")
        #expect(ephemeral.localizedDescription.contains("an ephemeral port"))
    }
}
