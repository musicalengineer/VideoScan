// BackgroundServiceControlTests.swift — Settings ▸ Background's heading and
// its one button (Rick 2026-11-09): "Background Content Analysis: <state>
// (<build date>)" with Start / Stop / Restart, replacing the checkbox.
//
//   LOGIC      each state offers one verb; each verb does one thing through
//              the store's engine (register / unregister), logged.
//   TRUTH      "running" only from the helper's answer; the build date is the
//              running helper's own, read from its build id.
//   ISOLATION  a viewer or a Debug build can Stop but never Start or Restart;
//              a failed Stop never goes on to Start.
//   SCALE / MEDIA  not applicable (one status reply, no media).
//   SENSOR     BackgroundSettingsSensorTests (the row uses the button).

import Foundation
import ServiceManagement
import Testing
import VideoScanCore
@testable import VideoScan

@MainActor
@Suite("BackgroundServiceStore — Start / Stop / Restart and the heading")
struct BackgroundServiceControlTests {

    typealias S = BackgroundServiceStoreTests
    typealias P = BackgroundServicePresentation
    typealias R = BackgroundServiceRegistrar

    static let old = "VideoScan Background 100 1794000000"
    static let new = "VideoScan Background 200 1794186000"
    /// Fixed words for a date, so the test does not depend on the locale.
    static let fmt: (Date) -> String = { "t\(Int($0.timeIntervalSince1970))" }

    static func control(enabled: Bool, launchd: SMAppService.Status?, service: ServiceStatus? = nil, problem: String? = nil,
                        refusal: String? = nil, bundled: String? = new, quit: BackgroundQuitMarker? = nil) -> P.Control {
        P.control(enabled: enabled, launchd: launchd, service: service, serviceProblem: problem, refusal: refusal,
                  bundledBuild: bundled, quit: quit, format: fmt)
    }

    static func running(build: String?) -> ServiceStatus {
        var s = S.serviceStatus()
        s.build = build
        return s
    }

    // MARK: Build date

    @Test("the build date is the build id's last field; anything else has none")
    func buildDate() {
        #expect(JobSchedule.buildDate(of: Self.new) == Date(timeIntervalSince1970: 1_794_186_000))
        #expect(JobSchedule.buildDate(of: "unknown") == nil)
        #expect(JobSchedule.buildDate(of: "b1") == nil)
        #expect(JobSchedule.buildDate(of: "VideoScan Background 200 0") == nil)
        #expect(JobSchedule.buildDate(of: "VideoScan Background 200 soon") == nil)
        #expect(JobSchedule.buildDate(of: "") == nil)
    }

    @Test("a real executable's build id round-trips to its modification time")
    func buildDateOfARealFile() throws {
        let exe = try #require(Bundle.main.executableURL)
        let mtime = try #require(try FileManager.default.attributesOfItem(atPath: exe.path)[.modificationDate] as? Date)
        let date = try #require(JobSchedule.buildDate(of: JobSchedule.buildID(executable: exe)))
        #expect(abs(date.timeIntervalSince(mtime)) < 1)
    }

    // MARK: The heading (truth)

    @Test("TRUTH: running, with the RUNNING helper's build date, offers Stop")
    func runningHeading() {
        let c = Self.control(enabled: true, launchd: .enabled, service: Self.running(build: Self.new))
        #expect(c.heading == "Background Content Analysis: running (built t1794186000)")
        #expect(c.action == .stop && !c.actionDisabled)
    }

    @Test("TRUTH: 'running' is never said without the helper's answer")
    func neverRunningWithoutAnAnswer() {
        let quit = BackgroundQuitMarker(quitAt: Date(timeIntervalSince1970: 1_794_188_460), bootSeconds: 7)
        let cases: [P.Control] = [
            Self.control(enabled: true, launchd: .enabled),
            Self.control(enabled: true, launchd: .enabled, problem: "connection invalid"),
            Self.control(enabled: true, launchd: nil),
            Self.control(enabled: true, launchd: .notRegistered),
            Self.control(enabled: true, launchd: .requiresApproval),
            Self.control(enabled: true, launchd: .notFound),
            Self.control(enabled: true, launchd: .enabled, quit: quit),
            Self.control(enabled: false, launchd: .notRegistered),
            Self.control(enabled: false, launchd: .enabled, problem: "Operation not permitted"),
        ]
        for c in cases { #expect(!c.state.contains("running"), "\(c.heading)") }
    }

    @Test("stopped: this app's helper build is shown and Start is offered")
    func stoppedHeading() {
        let c = Self.control(enabled: false, launchd: .notRegistered)
        #expect(c.heading == "Background Content Analysis: stopped (this app's helper: built t1794186000)")
        #expect(c.action == .start && !c.actionDisabled)
        let noBuild = Self.control(enabled: false, launchd: .notRegistered, bundled: nil)
        #expect(noBuild.heading == "Background Content Analysis: stopped")
    }

    @Test("an older helper: both build dates, and Restart")
    func olderHeading() {
        let c = Self.control(enabled: true, launchd: .enabled, service: Self.running(build: Self.old))
        #expect(c.heading == "Background Content Analysis: running an older build (built t1794000000; this app's helper: built t1794186000)")
        #expect(c.action == .restart && !c.actionDisabled)
    }

    @Test("one verb per state")
    func verbTable() {
        let quit = BackgroundQuitMarker(quitAt: Date(timeIntervalSince1970: 1_794_188_460), bootSeconds: 7)
        #expect(Self.control(enabled: true, launchd: .enabled, quit: quit).action == .start, "quit from the menu bar")
        #expect(Self.control(enabled: true, launchd: .enabled, quit: quit).state == "stopped")
        #expect(Self.control(enabled: true, launchd: .notRegistered).action == .start, "launchd dropped it")
        #expect(Self.control(enabled: true, launchd: .enabled, problem: "x").action == .restart, "not answering")
        #expect(Self.control(enabled: true, launchd: .enabled, problem: "x").state == "not answering")
        #expect(Self.control(enabled: true, launchd: .enabled).action == .stop)
        #expect(Self.control(enabled: true, launchd: .requiresApproval).action == .stop)
        #expect(Self.control(enabled: true, launchd: nil).action == .stop)
        #expect(Self.control(enabled: false, launchd: .enabled, problem: "x").state == "Stop failed")
        #expect(Self.control(enabled: true, launchd: .enabled, service: Self.running(build: nil)).action == .stop,
                "a helper that names no build is not called older")
    }

    @Test("ISOLATION: a viewer or a Debug build is offered Stop, never Restart, and Start is disabled")
    func refusedBuildsOnlyStop() {
        let quit = BackgroundQuitMarker(quitAt: Date(timeIntervalSince1970: 1_794_188_460), bootSeconds: 7)
        for refusal in [R.viewerRefusal, R.debugBuildRefusal] {
            #expect(Self.control(enabled: true, launchd: .enabled, service: Self.running(build: Self.old), refusal: refusal).action == .stop)
            #expect(Self.control(enabled: true, launchd: .enabled, problem: "x", refusal: refusal).action == .stop)
            #expect(Self.control(enabled: true, launchd: .enabled, refusal: refusal, quit: quit).action == .stop,
                    "a quit marker must not hide Stop where Start is refused")
            let off = Self.control(enabled: false, launchd: .notRegistered, refusal: refusal)
            #expect(off.action == .start && off.actionDisabled)
        }
    }

    // MARK: The verbs

    @Test("Start from stopped: registers once, persists true, logs the press, then asks the helper")
    func startFromStopped() async {
        let agent = S.FakeAgent(.notRegistered)
        let (store, r) = S.make(enabled: false, agent: agent)
        #expect(store.control.action == .start)
        await store.perform(.start)
        #expect(store.enabled && agent.registerCalls == 1 && r.persisted == [true])
        #expect(r.lines.first == "background service: Start pressed in Settings", "\(r.lines)")
        #expect(r.statusAsks >= 1 && store.service != nil)
        #expect(store.control.state == "running" && store.control.action == .stop)
        #expect(!store.busy)
    }

    @Test("Stop: unregisters once, persists false, and stays stopped across a refresh")
    func stopStaysStopped() async {
        let agent = S.FakeAgent(.enabled)
        let (store, r) = S.make(enabled: true, agent: agent)
        await store.refresh()
        let asksBefore = r.statusAsks
        await store.perform(.stop)
        #expect(!store.enabled && agent.unregisterCalls == 1 && r.persisted == [false])
        #expect(r.lines.contains("background service: Stop pressed in Settings"), "\(r.lines)")
        await store.refresh()
        #expect(r.statusAsks == asksBefore, "a stopped helper is never asked (asking would start it)")
        #expect(store.control.state == "stopped" && store.control.action == .start)
    }

    @Test("Restart: unregister, then register, in that order, once each")
    func restart() async {
        let agent = S.FakeAgent(.enabled)
        let (store, r) = S.make(enabled: true, agent: agent, status: .success(Self.running(build: Self.old)))
        store.bundledHelperBuild = { Self.new }
        store.restartPause = .milliseconds(1)
        await store.refresh()
        #expect(store.control.action == .restart)
        await store.perform(.restart)
        #expect(agent.unregisterCalls == 1 && agent.registerCalls == 1)
        #expect(r.persisted == [false, true] && store.enabled)
        let unregistered = try? #require(r.lines.firstIndex { $0.contains("unregistered") })
        let registered = try? #require(r.lines.firstIndex { $0.contains(": registered") })
        if let unregistered, let registered { #expect(unregistered < registered, "\(r.lines)") }
        #expect(r.lines.contains("background service: Restart pressed in Settings"))
    }

    @Test("ISOLATION: Restart whose Stop fails does not go on to Start, and says so")
    func restartStopsAtAFailedStop() async {
        final class StuckAgent: BackgroundAgentService {
            var registerCalls = 0
            var status: SMAppService.Status = .enabled
            func register() throws { registerCalls += 1 }
            func unregister() throws { throw Refusal("Operation not permitted") }
        }
        let agent = StuckAgent()
        let (store, r) = S.make(enabled: true, agent: S.FakeAgent(.enabled))
        store.agent = { agent }
        store.restartPause = .milliseconds(1)
        await store.perform(.restart)
        #expect(agent.registerCalls == 0)
        #expect(r.lines.contains { $0.contains("Restart stopped at Stop") && $0.contains("Operation not permitted") }, "\(r.lines)")
        #expect(store.control.state == "Stop failed")
    }

    @Test("ISOLATION: Restart where Start is refused never unregisters what it could not register again")
    func restartRefusedTouchesNothing() async {
        let agent = S.FakeAgent(.enabled)
        let (store, r) = S.make(enabled: true, agent: agent, readOnly: true)
        await store.perform(.restart)
        #expect(agent.unregisterCalls == 0 && agent.registerCalls == 0 && r.persisted.isEmpty)
        #expect(store.lastNote == R.viewerRefusal)
    }

    @Test("Start after a menu bar Quit: clears the marker, registers nothing new, and asks the helper again")
    func startAfterMenuBarQuit() async {
        let agent = S.FakeAgent(.enabled)
        let (store, r) = S.make(enabled: true, agent: agent)
        var markerOnDisk: BackgroundQuitMarker? = BackgroundQuitMarker(quitAt: Date(timeIntervalSince1970: 1_794_188_460), bootSeconds: 7)
        store.readQuit = { markerOnDisk }
        store.clearQuit = { defer { markerOnDisk = nil }; return markerOnDisk }
        await store.refresh()
        #expect(r.statusAsks == 0 && store.control.action == .start)
        await store.perform(.start)
        #expect(markerOnDisk == nil && agent.registerCalls == 0 && r.persisted.isEmpty)
        #expect(r.statusAsks == 1 && store.control.state == "running")
        #expect(r.lines.contains { $0.contains("Start was pressed") }, "\(r.lines)")
    }

    @Test("Start when launchd dropped the registration: registers again without touching the flag")
    func startReregisters() async {
        let agent = S.FakeAgent(.notRegistered)
        let (store, r) = S.make(enabled: true, agent: agent)
        await store.refresh()
        #expect(store.control.action == .start)
        await store.perform(.start)
        #expect(agent.registerCalls == 1 && r.persisted.isEmpty && store.launchdStatus == .enabled)
    }

    @Test("a second press while one is in flight does nothing")
    func oneAtATime() async {
        let agent = S.FakeAgent(.enabled)
        let (store, _) = S.make(enabled: true, agent: agent, status: .success(Self.running(build: Self.old)))
        store.restartPause = .milliseconds(100)
        let first = Task { await store.perform(.restart) }
        try? await S.settle { store.busy }
        await store.perform(.stop)
        await first.value
        #expect(agent.unregisterCalls == 1 && agent.registerCalls == 1 && store.enabled, "the Stop pressed mid-Restart was dropped")
    }
}
