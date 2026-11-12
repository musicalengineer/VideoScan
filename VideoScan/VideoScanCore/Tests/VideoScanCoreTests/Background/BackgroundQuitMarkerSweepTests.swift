// BackgroundQuitMarkerSweepTests.swift — Codex sweep 2026-11-09 (cycle #263,
// "Quit VideoScan Background"):
//   F2 P1  clear() called removeItem even when the read failed: a quit.json
//          that is a DIRECTORY had its contents removed recursively.
//   F3 P1  a removal that failed was reported as "cleared" (the app logged
//          "the helper starts again" while the marker kept it down).
//   F5 P2  kern.boottime moves when the clock is corrected: a same-boot
//          marker read as "stale" and the helper came back before a restart.
//   F6 P2  the read followed a symlink and loaded a file of any size.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("BackgroundQuitMarker — Codex sweep 11/09")
struct BackgroundQuitMarkerSweepTests {

    private func root() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("quit-sweep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("RED F2: quit.json is a directory → clear() removes nothing inside it and says why")
    func directoryIsNeverRemovedRecursively() throws {
        let url = try root().appendingPathComponent("quit.json")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let keep = url.appendingPathComponent("keep.mov")
        try Data("family".utf8).write(to: keep)
        let store = BackgroundQuitStore(url: url, bootSeconds: { 100 }, bootSession: { "S" })
        let outcome = store.clear()
        #expect(FileManager.default.fileExists(atPath: keep.path), "clear() removed a directory's contents")
        guard case .failed = outcome else { Issue.record("expected .failed, got \(outcome)"); return }
    }

    @Test("RED F3: a marker that cannot be removed is reported as failed, never cleared")
    func failedRemovalIsSaid() throws {
        let dir = try root()
        let url = dir.appendingPathComponent("quit.json")
        let store = BackgroundQuitStore(url: url, bootSeconds: { 100 }, bootSession: { "S" })
        try store.write()
        #expect(chmod(dir.path, 0o555) == 0)
        defer { _ = chmod(dir.path, 0o755) }
        let outcome = store.clear()
        #expect(FileManager.default.fileExists(atPath: url.path))
        guard case .failed(let why) = outcome else { Issue.record("expected .failed, got \(outcome)"); return }
        #expect(!why.isEmpty)
    }

    @Test("RED F5: the same boot session with a corrected clock (boot seconds moved) is still active")
    func clockCorrectionKeepsTheQuit() throws {
        let url = try root().appendingPathComponent("quit.json")
        let m = try BackgroundQuitStore(url: url, bootSeconds: { 100 }, bootSession: { "SESSION-A" }).write()
        let corrected = BackgroundQuitStore(url: url, bootSeconds: { 160 }, bootSession: { "SESSION-A" })
        #expect(corrected.read() == .active(m))
        let rebooted = BackgroundQuitStore(url: url, bootSeconds: { 160 }, bootSession: { "SESSION-B" })
        #expect(rebooted.read() == .stale(m))
    }

    @Test("RED F6: a symlinked marker and an oversized one read as unreadable (never followed, never loaded whole)")
    func symlinkAndOversizeAreRefused() throws {
        let dir = try root()
        let real = dir.appendingPathComponent("elsewhere.json")
        try BackgroundQuitStore(url: real, bootSeconds: { 100 }, bootSession: { "S" }).write()
        let url = dir.appendingPathComponent("quit.json")
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: real)
        let store = BackgroundQuitStore(url: url, bootSeconds: { 100 }, bootSession: { "S" })
        guard case .unreadable = store.read() else { Issue.record("a symlinked marker was followed: \(store.read())"); return }

        let big = dir.appendingPathComponent("big/quit.json")
        try FileManager.default.createDirectory(at: big.deletingLastPathComponent(), withIntermediateDirectories: true)
        let pad = String(repeating: "x", count: 1_000_000)
        try Data("{\"quitAt\":\"2026-11-08T20:41:00Z\",\"bootSeconds\":100,\"pad\":\"\(pad)\"}".utf8).write(to: big)
        let bigStore = BackgroundQuitStore(url: big, bootSeconds: { 100 }, bootSession: { "S" })
        guard case .unreadable = bigStore.read() else { Issue.record("a 1 MB marker was loaded: \(bigStore.read())"); return }
    }

    @Test("SENSOR: kern.bootsessionuuid answers on this Mac")
    func realBootSession() {
        #expect((BackgroundQuitStore.currentBootSession()?.count ?? 0) >= 32)
    }

    @Test("RED closing B1: a STALE marker (other boot) that cannot be removed is reported as failed, never cleared")
    func staleMarkerFailedRemovalIsSaid() throws {
        let dir = try root()
        let url = dir.appendingPathComponent("quit.json")
        try BackgroundQuitStore(url: url, bootSeconds: { 100 }, bootSession: { "SESSION-A" }).write()
        #expect(chmod(dir.path, 0o555) == 0)
        defer { _ = chmod(dir.path, 0o755) }
        let outcome = BackgroundQuitStore(url: url, bootSeconds: { 200 }, bootSession: { "SESSION-B" }).clear()
        #expect(FileManager.default.fileExists(atPath: url.path))
        guard case .failed = outcome else { Issue.record("expected .failed, got \(outcome)"); return }
    }
}
