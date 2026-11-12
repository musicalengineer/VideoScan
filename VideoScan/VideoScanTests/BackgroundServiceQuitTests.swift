// BackgroundServiceQuitTests.swift — the app's half of "Quit VideoScan
// Background" (Rick 2026-11-08; Core: BackgroundQuitMarker).
//
// The helper's Quit writes a marker and exits 0. Without the app's half,
// VideoScan's status poll (every 10 min, every 5 s with Settings open) would
// connect to the Mach service and launchd would start the helper again.
//
//   LOGIC      a marker → the poll does not ask the helper; opening VideoScan
//              (start) clears it and says so; turning the checkbox on clears it.
//   TRUTH      the Settings line says "quit from its menu bar at …", never
//              "running" and never "not answering"; no green dot.
//   ISOLATION  a viewer's line and a disabled store ignore the marker; the
//              real file store in a temp root, never App Support.
//   SCALE      not applicable (one small file).

import Foundation
import ServiceManagement
import Testing
import VideoScanCore
@testable import VideoScan

@MainActor
@Suite("BackgroundServiceStore — Quit from the helper's menu bar")
struct BackgroundServiceQuitTests {

    typealias S = BackgroundServiceStoreTests
    static let marker = BackgroundQuitMarker(quitAt: Date(timeIntervalSince1970: 1_794_188_460), bootSeconds: 7)

    @Test("RED→GREEN: a quit marker stops the poll from asking the helper (asking would make launchd start it)")
    func pollDoesNotAskWhileQuit() async {
        let (store, r) = S.make(enabled: true, agent: S.FakeAgent(.enabled))
        store.readQuit = { Self.marker }
        await store.refresh()
        #expect(r.statusAsks == 0)
        #expect(store.quit == Self.marker)
        #expect(store.service == nil && store.serviceProblem == nil)
    }

    @Test("no marker: the poll asks as before")
    func pollAsksWithoutMarker() async {
        let (store, r) = S.make(enabled: true, agent: S.FakeAgent(.enabled))
        await store.refresh()
        #expect(r.statusAsks == 1)
        #expect(store.quit == nil)
    }

    @Test("off: the marker is not read into the line")
    func disabledIgnoresMarker() async {
        let (store, _) = S.make(enabled: false, agent: S.FakeAgent(.notRegistered))
        store.readQuit = { Self.marker }
        await store.refresh()
        #expect(store.quit == nil)
    }

    @Test("opening VideoScan clears the marker, says so once, and then asks the helper")
    func startClears() async {
        let (store, r) = S.make(enabled: true, agent: S.FakeAgent(.enabled))
        var markerOnDisk: BackgroundQuitMarker? = Self.marker
        store.readQuit = { markerOnDisk }
        store.clearQuit = { defer { markerOnDisk = nil }; return markerOnDisk.map { .cleared($0) } ?? .nothing }
        store.start()
        store.stop()
        #expect(markerOnDisk == nil)
        #expect(r.lines.filter { $0.contains("quit from its menu bar") && $0.contains("VideoScan opened") }.count == 1, "\(r.lines)")
        await store.refresh()
        #expect(r.statusAsks >= 1)
    }

    @Test("Codex sweep 11/09 F3: a marker that could not be removed is said — never 'the helper starts again'")
    func failedClearIsSaid() {
        let (store, r) = S.make(enabled: true, agent: S.FakeAgent(.enabled))
        store.clearQuit = { .failed("Permission denied") }
        store.start()
        store.stop()
        #expect(r.lines.contains { $0.contains("could not be cleared") && $0.contains("Permission denied") && $0.contains("stays down") }, "\(r.lines)")
        #expect(!r.lines.contains { $0.contains("starts again") }, "\(r.lines)")
    }

    @Test("no marker at launch: nothing is logged about Quit")
    func startWithoutMarkerIsSilent() {
        let (store, r) = S.make(enabled: true, agent: S.FakeAgent(.enabled))
        store.start()
        store.stop()
        #expect(!r.lines.contains { $0.contains("quit") }, "\(r.lines)")
    }

    @Test("turning it on (Start) clears the marker")
    func checkboxOnClears() {
        let (store, r) = S.make(enabled: false, agent: S.FakeAgent(.notRegistered))
        var markerOnDisk: BackgroundQuitMarker? = Self.marker
        store.clearQuit = { defer { markerOnDisk = nil }; return markerOnDisk.map { .cleared($0) } ?? .nothing }
        store.setEnabled(true)
        #expect(markerOnDisk == nil)
        #expect(r.lines.contains { $0.contains("Start was pressed") }, "\(r.lines)")
    }

    @Test("TRUTH: the line says quit, with the time and how to start it; no green dot, never 'running'")
    func presentation() {
        let l = BackgroundServicePresentation.lines(enabled: true, launchd: .enabled, service: nil, serviceProblem: nil,
                                                    lastNote: nil, quit: Self.marker)
        #expect(l.helper.contains("quit from its menu bar at"))
        #expect(l.helper.contains("starts again when VideoScan next opens"))
        #expect(!l.helper.contains("running") && !l.helper.contains("not answering"))
        #expect(!l.helperIsUp)
        #expect(l.job == BackgroundServicePresentation.quitJobLine)
    }

    @Test("a viewer's lines ignore the marker")
    func viewerIgnoresQuit() {
        let l = BackgroundServicePresentation.lines(enabled: true, launchd: .enabled, service: nil, serviceProblem: nil,
                                                    lastNote: nil, viewer: true, quit: Self.marker)
        #expect(l.job == BackgroundServicePresentation.viewerJob)
        #expect(!l.helper.contains("quit"))
    }

    @Test("end to end on the real file store (temp root): helper writes → poll holds off → launch clears the file")
    func realStore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bgquit-\(UUID().uuidString)", isDirectory: true)
        let file = BackgroundQuitStore.beside(stateRoot: root)
        try file.write()  // what the helper's Quit does
        let (store, r) = S.make(enabled: true, agent: S.FakeAgent(.enabled))
        store.readQuit = { file.active() }
        store.clearQuit = { file.clear() }
        await store.refresh()
        #expect(r.statusAsks == 0 && store.quit != nil)
        store.start()
        store.stop()
        #expect(!FileManager.default.fileExists(atPath: file.url.path))
        #expect(store.quit == nil)
    }
}
