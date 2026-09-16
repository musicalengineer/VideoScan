// AtomicFilePublishModeTests.swift
//
// Publishing must never WIDEN a file's permissions.
//
// FOUND BY codex, 2026-09-15, and runtime-confirmed rather than argued from
// source: create a 0600 destination, set umask 022, call the real
// AtomicFilePublish.write(.fullFsync) — the file came back 0644.
//
// The cause is inherent to the P0 fix and worth stating plainly, because the
// wrapper is otherwise exactly right. `FileManager.replaceItemAt` preserves
// the destination's attributes (documented in NSFileManager.h). We replaced
// it — it is RENAME_SWAP, which deadlocks Sandbox.kext — with "write a fresh
// temp, rename it over the top". A fresh inode is born with 0644 & ~umask,
// and the rename carries that mode onto the destination. Atomicity and
// durability were reviewed carefully; metadata preservation was not.
//
// Nobody lost data and no restricted sidecar is known to exist today. The
// point is that an atomic-save helper must not be a privilege-widening
// primitive, because the next caller will not think to check.
//
// Five dimensions:
//   1. Logic     — restrictive, permissive, executable, and brand-new files
//   2. Scale     — n/a (one stat + at most one chmod per publish)
//   3. Media     — n/a (no media opened)
//   4. Isolation — every case runs in its own scratch directory; umask is
//                  set and restored around the whole suite
//   5. Sensor    — the 0600 + umask 022 case IS the reproduction, kept
//                  permanently and asserted on both durability modes

import Foundation
import Testing
@testable import VideoScanCore

@Suite("AtomicFilePublish — publishing never widens permissions", .serialized)
struct AtomicFilePublishModeTests {

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtomicModeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func mode(of url: URL) throws -> UInt16 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let n = attrs[.posixPermissions] as? NSNumber else {
            throw Failure.noPermissions(url.path)
        }
        return n.uint16Value
    }

    private enum Failure: Error { case noPermissions(String) }

    /// Runs `body` with a known umask, then restores the process's own.
    /// umask is PROCESS-WIDE, which is why this suite is `.serialized`.
    private func withUmask(_ value: mode_t, _ body: () throws -> Void) rethrows {
        let previous = umask(value)
        defer { _ = umask(previous) }
        try body()
    }

    // MARK: - 1. The reproduction, both durability modes

    @Test(arguments: [AtomicFilePublish.Durability.fast, .fullFsync])
    func aRestrictedDestinationKeepsItsModeAcrossAPublish(
        _ durability: AtomicFilePublish.Durability
    ) throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("secrets.json")

        try withUmask(0o022) {
            try Data("first".utf8).write(to: dest)
            try #require(chmod(dest.path, 0o600) == 0)
            #expect(try mode(of: dest) == 0o600)

            try AtomicFilePublish.write(Data("second".utf8), to: dest, durability: durability)

            let after = try mode(of: dest)
            #expect(after == 0o600,
                    "publishing widened 0600 → \(String(after, radix: 8))")
            #expect(try Data(contentsOf: dest) == Data("second".utf8),
                    "the new bytes must still be published")
        }
    }

    // MARK: - 2. It preserves, it does not merely restrict

    /// The rule is "keep what was there", not "always clamp down". A
    /// deliberately group-readable file must not be narrowed either.
    @Test func aPermissiveDestinationIsNotNarrowedEither() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("shared.json")

        try withUmask(0o077) {                       // would otherwise force 0600
            try Data("first".utf8).write(to: dest)
            try #require(chmod(dest.path, 0o664) == 0)

            try AtomicFilePublish.write(Data("second".utf8), to: dest)

            #expect(try mode(of: dest) == 0o664)   // preserved, not clamped
        }
    }

    /// Odd-but-intentional bits survive too — this is `st_mode & 0o7777`,
    /// not a guess at which bits mattered.
    @Test func anExecutableBitSurvives() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("hook.sh")
        try Data("#!/bin/sh\n".utf8).write(to: dest)
        try #require(chmod(dest.path, 0o750) == 0)

        try AtomicFilePublish.write(Data("#!/bin/sh\ntrue\n".utf8), to: dest)

        #expect(try mode(of: dest) == 0o750)
    }

    // MARK: - 3. A new file has no prior intent to honour

    @Test func aBrandNewFileTakesTheProcessUmask() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("fresh.json")

        try withUmask(0o022) {
            try AtomicFilePublish.write(Data("hello".utf8), to: dest)
            let fresh = try mode(of: dest)
            #expect(fresh == 0o644,
                    "a new file should follow umask, got \(String(fresh, radix: 8))")
        }
    }

    // MARK: - 4. The low-level seam carries the same guarantee

    /// `publish(_:as:)` is public and some callers use it directly with a
    /// file they already wrote. The preservation lives in `publish`, not in
    /// `write`, precisely so those callers cannot miss it.
    @Test func thePublicPublishSeamPreservesTooNotJustWrite() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("payload.bin")
        let staged = dir.appendingPathComponent("staged.bin")

        try withUmask(0o022) {
            try Data("old".utf8).write(to: dest)
            try #require(chmod(dest.path, 0o600) == 0)
            try Data("new".utf8).write(to: staged)

            try AtomicFilePublish.publish(staged, as: dest)

            #expect(try mode(of: dest) == 0o600)
            #expect(try Data(contentsOf: dest) == Data("new".utf8))
        }
    }
}
