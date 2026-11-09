// BackgroundQuitMarkerTests.swift — "Quit VideoScan Background" (Rick 2026-11-08).
//
//   LOGIC      a marker written in this boot reads active; one from another
//              boot reads stale and is removed; clear removes and returns it;
//              no file reads none.
//   ISOLATION  a torn file reads unreadable (the helper runs, says why) and
//              clear still removes it; no boot time → write throws, read says
//              noBootTime (run); a temp root, never App Support.
//   SCALE      not applicable: one small file per state root.
//   SENSOR     the real sysctl answers a positive boot time on this Mac.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("BackgroundQuitMarker")
struct BackgroundQuitMarkerTests {

    private func root() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("quit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func noFileReadsNone() throws {
        let store = BackgroundQuitStore(url: try root().appendingPathComponent("quit.json"), bootSeconds: { 100 })
        #expect(store.read() == .none)
        #expect(store.active() == nil)
        #expect(store.clear() == nil)
    }

    @Test func sameBootIsActive() throws {
        let store = BackgroundQuitStore(url: try root().appendingPathComponent("quit.json"), bootSeconds: { 100 })
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let m = try store.write(now: at)
        #expect(m == BackgroundQuitMarker(quitAt: at, bootSeconds: 100))
        #expect(store.read() == .active(m))
        #expect(store.active() == m, "read does not consume an active marker")
    }

    @Test func otherBootIsStaleAndRemoved() throws {
        let url = try root().appendingPathComponent("quit.json")
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let before = try BackgroundQuitStore(url: url, bootSeconds: { 100 }).write(now: at)
        let afterReboot = BackgroundQuitStore(url: url, bootSeconds: { 200 })
        #expect(afterReboot.read() == .stale(before))
        #expect(!FileManager.default.fileExists(atPath: url.path), "a stale marker is removed")
        #expect(afterReboot.read() == .none)
    }

    @Test func clearRemovesAndReturns() throws {
        let url = try root().appendingPathComponent("quit.json")
        let store = BackgroundQuitStore(url: url, bootSeconds: { 100 })
        let m = try store.write()
        #expect(store.clear() == m)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(store.active() == nil)
    }

    @Test func tornFileReadsUnreadableAndClears() throws {
        let url = try root().appendingPathComponent("quit.json")
        try Data("{\"quitAt\": \"2026-11".utf8).write(to: url)
        let store = BackgroundQuitStore(url: url, bootSeconds: { 100 })
        guard case .unreadable(let why) = store.read() else { Issue.record("expected unreadable"); return }
        #expect(why.contains("quit.json"))
        #expect(store.active() == nil, "a torn marker never keeps the helper down")
        #expect(store.clear() == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path), "clear removes a torn file too")
    }

    @Test func noBootTime() throws {
        let url = try root().appendingPathComponent("quit.json")
        try BackgroundQuitStore(url: url, bootSeconds: { 100 }).write()
        let blind = BackgroundQuitStore(url: url, bootSeconds: { nil })
        #expect(blind.read() == .noBootTime)
        #expect(blind.active() == nil)
        #expect(throws: QuitMarkerError.self) { try blind.write() }
    }

    @Test func writeCreatesTheStateRoot() throws {
        let url = try root().appendingPathComponent("not-yet/quit.json")
        try BackgroundQuitStore(url: url, bootSeconds: { 1 }).write()
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func quitWords() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let at = Date(timeIntervalSince1970: 1_794_188_460) // 2026-11-08 20:41 EST
        let m = BackgroundQuitMarker(quitAt: at, bootSeconds: 1)
        #expect(m.quitWords(now: at.addingTimeInterval(60), calendar: cal) == "20:41")
        #expect(m.quitWords(now: at.addingTimeInterval(86_400 * 2), calendar: cal) == "Nov 8, 20:41")
    }

    @Test func realBootTimeSensor() {
        let s = BackgroundQuitStore.currentBootSeconds()
        #expect((s ?? 0) > 1_600_000_000, "kern.boottime answered \(String(describing: s))")
    }
}
