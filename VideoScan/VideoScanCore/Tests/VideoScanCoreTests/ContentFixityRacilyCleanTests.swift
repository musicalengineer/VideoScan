// ContentFixityRacilyCleanTests.swift
// Codex closing pass 2026-10-26 F2: HFS+ reports mtime and ctime in whole
// seconds (zero nanoseconds). A file hashed and then rewritten in place
// with same-size bytes inside the same second keeps UUID, inode, size,
// mtime and ctime — the stored digest then "describes" different bytes.
// Git's racily-clean rule: a stored digest may stand in for the bytes only
// when the hash was taken at or after max(mtime, ctime) + the stamp's
// resolution (1 s when the volume reports zero nanoseconds).

import Foundation
import Testing
import VideoScanCore

@Suite("ContentFixity — racily clean stamps (HFS+ whole-second times)")
struct ContentFixityRacilyCleanTests {

    static let second: Int64 = 1_000_000_000
    static let t0: Int64 = 1_761_480_000 * second            // a whole second, zero ns

    static func stamp(mtime: Int64, ctime: Int64) -> FileIdentityStamp {
        FileIdentityStamp(device: 3, inode: 77, size: 4_096, mtimeNs: mtime, ctimeNs: ctime,
                          volumeUUID: "11111111-2222-3333-4444-555555555555")
    }

    static func hashed(at ns: Int64, _ s: FileIdentityStamp) -> ContentFixity {
        ContentFixity(digest: String(repeating: "a", count: 64), byteCount: s.size, stamp: s,
                      computedAt: Date(timeIntervalSince1970: Double(ns) / 1e9))
    }

    /// The HFS+ race: hashed in the same second the file was last written.
    /// An in-place same-size rewrite in that second leaves an identical
    /// stamp, so the stamp cannot vouch for the bytes.
    @Test func aWholeSecondStampHashedInItsOwnSecondIsAmbiguous() {
        let s = Self.stamp(mtime: Self.t0, ctime: Self.t0)
        let f = Self.hashed(at: Self.t0 + 400_000_000, s)
        #expect(!f.describesFileNow(s), "same-second hash on a whole-second volume must not stand in for the bytes")
    }

    @Test func aWholeSecondStampHashedAfterTheSecondEndedIsCurrent() {
        let s = Self.stamp(mtime: Self.t0, ctime: Self.t0)
        #expect(Self.hashed(at: Self.t0 + Self.second, s).describesFileNow(s))
    }

    /// ctime counts too: a later inode change in the hash's own second.
    @Test func theLaterOfMtimeAndCtimeDecides() {
        let s = Self.stamp(mtime: Self.t0 - 10 * Self.second, ctime: Self.t0)
        #expect(!Self.hashed(at: Self.t0 + 999_000_000, s).describesFileNow(s))
        #expect(Self.hashed(at: Self.t0 + Self.second, s).describesFileNow(s))
    }

    /// Nanosecond volumes (APFS): resolution is the reported one, so a
    /// hash taken after the write is current.
    @Test func aNanosecondStampHashedAfterTheWriteIsCurrent() {
        let s = Self.stamp(mtime: Self.t0 + 123_456_789, ctime: Self.t0 + 123_456_789)
        #expect(Self.hashed(at: Self.t0 + 200_000_000, s).describesFileNow(s))
        #expect(!Self.hashed(at: Self.t0 + 100_000_000, s).describesFileNow(s), "hashed before the last write")
    }
}
