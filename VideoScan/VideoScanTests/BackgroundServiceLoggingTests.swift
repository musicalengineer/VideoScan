// BackgroundServiceLoggingTests.swift — Codex 11/03 F6 (LOGGING) for
// Settings ▸ Background: every problem the two lines can show is also in the
// log — once when it appears, once when its words change, once when it
// clears — never once per 5 s poll. (F3's "waiting" words went with the
// keyboard backoff: no helper since 2026-11-04 waits.)
//
// Dimensions: LOGIC (failure → repeated failure → recovery = exactly two
// lines; launchd states; the registration gate).

import Foundation
import ServiceManagement
import Testing
import VideoScanCore
@testable import VideoScan

@MainActor
@Suite("Background store — problems reach the log once per change")
struct BackgroundServiceLoggingTests {
    typealias T = BackgroundServiceStoreTests

    @Test("RED 11/03 F6: XPC not answering → not answering again → answering = exactly two log lines, with the reason")
    func notAnsweringIsLoggedOnAppearAndClear() async {
        let agent = T.FakeAgent(.enabled)
        var answer: Result<ServiceStatus, Refusal> = .failure(Refusal("connection invalid"))
        let (store, r) = T.make(enabled: true, agent: agent)
        store.askStatus = { answer }
        await store.refresh()
        await store.refresh()
        answer = .success(T.serviceStatus())
        await store.refresh()
        await store.refresh()
        #expect(r.lines == ["background service: VideoScan Background: enabled · not answering (connection invalid)",
                            "background service: cleared — VideoScan Background: enabled · not answering (connection invalid)"],
                "\(r.lines)")
    }

    @Test("F6: a CHANGED reason is one more line; launchd's approval wait and 'missing from this build' are logged once each")
    func launchdStatesAreLogged() async {
        let agent = T.FakeAgent(.requiresApproval)
        let (store, r) = T.make(enabled: true, agent: agent)
        await store.refresh()
        await store.refresh()
        agent.status = .notFound
        await store.refresh()
        #expect(r.lines.count == 2, "\(r.lines)")
        #expect(r.lines[0].contains("waiting for your approval"))
        #expect(r.lines[1].contains("missing from this build"))
    }

    @Test("F6: the registration gate is logged once when it shows, not every poll")
    func gateIsLoggedOnce() async {
        let agent = T.FakeAgent(.notRegistered)
        let (store, r) = T.make(enabled: false, agent: agent, readOnly: true)
        await store.refresh()
        await store.refresh()
        #expect(r.lines == ["background service: Start is refused here — \(BackgroundServiceRegistrar.viewerRefusal)"],
                "\(r.lines)")
    }
}
