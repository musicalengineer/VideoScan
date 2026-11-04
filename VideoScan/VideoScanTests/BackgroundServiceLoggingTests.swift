// BackgroundServiceLoggingTests.swift — Codex 11/03 F6 (LOGGING) for
// Settings ▸ Background: every problem the two lines can show is also in the
// log — once when it appears, once when its words change, once when it
// clears — never once per 5 s poll. Plus F3's words on the Settings job line
// (a waiting era job says "waiting", not "running").
//
// Dimensions: LOGIC (failure → repeated failure → recovery = exactly two
// lines; launchd states; the registration gate; the count's recovery names
// the catalog), TRUTH (the Settings job line reads the snapshot's own wait).

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
        await store.refresh(recount: false)
        await store.refresh(recount: false)
        answer = .success(T.serviceStatus())
        await store.refresh(recount: false)
        await store.refresh(recount: false)
        #expect(r.lines == ["background service: VideoScan Background: enabled · not answering (connection invalid)",
                            "background service: cleared — VideoScan Background: enabled · not answering (connection invalid)"],
                "\(r.lines)")
    }

    @Test("F6: a CHANGED reason is one more line; launchd's approval wait and 'missing from this build' are logged once each")
    func launchdStatesAreLogged() async {
        let agent = T.FakeAgent(.requiresApproval)
        let (store, r) = T.make(enabled: true, agent: agent)
        await store.refresh(recount: false)
        await store.refresh(recount: false)
        agent.status = .notFound
        await store.refresh(recount: false)
        #expect(r.lines.count == 2, "\(r.lines)")
        #expect(r.lines[0].contains("waiting for your approval"))
        #expect(r.lines[1].contains("missing from this build"))
    }

    @Test("F6: the registration gate is logged once when it shows, not every poll")
    func gateIsLoggedOnce() async {
        let agent = T.FakeAgent(.notRegistered)
        let (store, r) = T.make(enabled: false, agent: agent, readOnly: true)
        await store.refresh(recount: false)
        await store.refresh(recount: false)
        #expect(r.lines == ["background service: the checkbox cannot turn it on here — \(BackgroundServiceRegistrar.viewerRefusal)"],
                "\(r.lines)")
    }

    @Test("F6: count failure → failure → recovery = two lines; the recovery names the catalog it read")
    func countRecoveryNamesThePath() async {
        let agent = T.FakeAgent(.enabled)
        var work: Result<BackgroundWorkCount, Refusal> = .failure(Refusal("/x/catalog.sqlite: no such table: files"))
        let (store, r) = T.make(enabled: true, agent: agent, status: .success(T.serviceStatus(jobs: [T.eraJob(.running)])))
        store.countWork = { _ in work }
        await store.refresh(recount: true)
        await store.refresh(recount: true)
        work = .success(BackgroundWorkCount(filesLeft: 7, foregroundRun: nil, catalogPath: "/x/catalog.sqlite"))
        await store.refresh(recount: true)
        let count = r.lines.filter { $0.hasPrefix("content analysis count:") }
        #expect(count == ["content analysis count: FAILED — /x/catalog.sqlite: no such table: files",
                          "content analysis count: recovered — 7 file(s) left for the era job in /x/catalog.sqlite"], "\(r.lines)")
    }

    @Test("F6: the production count's refusal names the catalog it tried")
    func countRefusalNamesThePath() throws {
        let dir = try BackgroundCountFixture.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = dir.appendingPathComponent("catalog.sqlite")
        try Data("not sqlite".utf8).write(to: db)
        guard case .failure(let r) = BackgroundServiceStore.count(catalogURL: db, stateRoot: dir, knownJobs: [], now: Date()) else {
            Issue.record("garbage must not count"); return
        }
        #expect(r.words.contains(db.path), "\(r.words)")
    }

    @Test("F3 TRUTH: the Settings job line says the snapshot's wait, never 'running'")
    func settingsSaysWaiting() {
        var era = T.eraJob(.running, done: 0)
        era.waiting = EraJob.deferWords
        let lines = T.lines(enabled: true, launchd: .enabled, service: T.serviceStatus(jobs: [era]))
        #expect(lines.job == "Machine era (8B): 0 of 4,709 · waiting — you're at the Mac (the model loads when you step away)")
        #expect(!lines.job.hasSuffix("running"))
    }
}
