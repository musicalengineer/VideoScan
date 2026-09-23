// ContentFixityRemountReproTests.swift
// RED-FIRST reproduction of the 2026-09-23 fixity bug: a stamp taken on a
// volume, the volume remounted (macOS hands it a new st_dev), and the
// SAME untouched file then fails `describesFileNow` — on Rick's catalog
// 1,429 of 1,493 stamps. Written against the pre-fix public API only (the
// remount is simulated by rewriting `device` in the stamp's JSON), so the
// same file compiles and FAILS on 61d162d5 and passes with the fix.

import Foundation
import Testing
import VideoScanCore

@Suite("ContentFixity remount repro (2026-09-23)")
struct ContentFixityRemountReproTests {

    /// The stamp as the SAME file on the SAME volume would stat after a
    /// remount: every field equal except the device number.
    static func remounted(_ s: FileIdentityStamp, device: UInt64) throws -> FileIdentityStamp {
        let data = try JSONEncoder().encode(s)
        var obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj["device"] = device
        return try JSONDecoder().decode(FileIdentityStamp.self, from: JSONSerialization.data(withJSONObject: obj))
    }

    @Test func aRemountThatOnlyChangesTheDeviceNumberKeepsTheDigestCurrent() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fixity-remount-repro-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("tape.dv")
        try Data(repeating: 0x5A, count: 4096).write(to: file)

        let atHash = try #require(FileIdentityStamp.capture(path: file.path))
        let fixity = ContentFixity(digest: "ab", byteCount: atHash.size, stamp: atHash)
        let afterRemount = try Self.remounted(atHash, device: atHash.device &+ 7)

        #expect(fixity.describesFileNow(afterRemount),
                "same file, same volume, new st_dev after a remount — must still be current")
        #expect(fixity.stampMatches(afterRemount))
    }
}
