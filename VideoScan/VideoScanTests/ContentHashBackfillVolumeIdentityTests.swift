// ContentHashBackfillVolumeIdentityTests.swift
// REGRESSION GH #412: the file-signature backfill picked its rows by path
// prefix alone and wrote `FileHasher.segmentedHash(path:)` onto the record
// by id, with no check that the file it read is the record's file. A
// same-named file at the record's path on ANOTHER disk (two Macs'
// `/Users/rickb/Movies`, a remote mount of a known volume) was signed as
// the record's content. Rule 1 (a shown fact needs evidence), rule 6
// (identity is never the path alone).
//
// Fix: each read checks the OPENED file's volume UUID against the record's
// evidenced volume (`VolumeIdentity.agree`, the #401 rule); disagreement is
// refused, counted and logged, never written.
//
// The real temp file is on this Mac's Data volume; "another disk" is a
// record that names a different volume UUID — exactly what a record from
// the other Mac's boot disk carries.
//
// Red/green (before the fix → after):
//   recordOnAnotherVolumeIsNotSigned ........................ RED → green
//   recordWithNoVolumeEvidenceIsNotSigned ................... RED → green
//   recordOnThisVolumeIsSigned .............................. green → green
//   aRefusalIsCountedAndNamedInTheLog ....................... (new API) → green
//   hasherRefusesOnTheOpenedDescriptor ...................... (new API) → green

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@MainActor
@Suite("File signatures — signed only on the record's own volume (GH #412)", .serialized, .scratchCleanup)
struct ContentHashBackfillVolumeIdentityTests {

    private static let otherDisk = "0E0E0E0E-1111-2222-3333-444455556666"

    private static func file() throws -> URL {
        let dir = try TestScratch.unique("vs_sig412_")
        let url = dir.appendingPathComponent("clip.mov")
        try Data(repeating: 0x42, count: 64 * 1024).write(to: url)
        return url
    }

    private static func record(at url: URL, volumeUUID: String) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = url.path
        r.filename = url.lastPathComponent
        r.sizeBytes = 64 * 1024
        r.scanContext.volumeUUID = volumeUUID
        return r
    }

    private static func run(_ model: VideoScanModel, under dir: URL) async -> VideoScanModel.ContentHashBackfillResult {
        await model.runContentHashBackfill(pathPrefix: dir.path)
    }

    @Test("a record whose volume is another disk is not signed with the file at its path")
    func recordOnAnotherVolumeIsNotSigned() async throws {
        let url = try Self.file()
        let model = VideoScanModel()
        let rec = Self.record(at: url, volumeUUID: Self.otherDisk)
        model.records = [rec]

        _ = await Self.run(model, under: url.deletingLastPathComponent())

        #expect(rec.contentHash.isEmpty,
                "signed another disk's file as this record's content: \(rec.contentHash)")
    }

    @Test("a record with no volume evidence is not signed when the file's volume is known")
    func recordWithNoVolumeEvidenceIsNotSigned() async throws {
        let url = try Self.file()
        try #require(VolumeIdentity.uuid(forPath: url.path) != nil, "the temp volume reports a UUID")
        let model = VideoScanModel()
        let rec = Self.record(at: url, volumeUUID: "")
        model.records = [rec]

        _ = await Self.run(model, under: url.deletingLastPathComponent())

        #expect(rec.contentHash.isEmpty, "exactly one side knows its volume: the path must not decide (#401)")
    }

    @Test("control: a record on this file's volume is signed")
    func recordOnThisVolumeIsSigned() async throws {
        let url = try Self.file()
        let here = try #require(VolumeIdentity.uuid(forPath: url.path))
        let model = VideoScanModel()
        let rec = Self.record(at: url, volumeUUID: here)
        model.records = [rec]

        let result = await Self.run(model, under: url.deletingLastPathComponent())

        #expect(result.hashed == 1)
        #expect(rec.contentHash == FileHasher.segmentedHash(path: url.path))
        #expect(result.refusedOtherVolume == 0)
    }

    @Test("a refusal is counted (not as a failure) and named in the console log")
    func aRefusalIsCountedAndNamedInTheLog() async throws {
        let url = try Self.file()
        let model = VideoScanModel()
        model.records = [Self.record(at: url, volumeUUID: Self.otherDisk)]

        let result = await Self.run(model, under: url.deletingLastPathComponent())

        #expect(result.refusedOtherVolume == 1)
        #expect(result.failed == 0, "a refusal is a decision, not an I/O failure")
        #expect(result.hashed == 0)
        try await Task.sleep(nanoseconds: 400_000_000)   // console lines flush on a debounce
        let console = model.dashboard.consoleLines.joined(separator: "\n")
        #expect(console.contains("NOT signed") && console.contains(url.path) && console.contains(Self.otherDisk),
                "the refusal must name the file and both volumes; console:\n\(console)")
    }

    @Test("the hasher checks the volume of the descriptor it reads")
    func hasherRefusesOnTheOpenedDescriptor() throws {
        let url = try Self.file()
        let here = VolumeIdentity.uuid(forPath: url.path)
        #expect(FileHasher.segmentedHash(path: url.path, recordVolume: Self.otherDisk) == .otherVolume(found: here))
        #expect(FileHasher.segmentedHash(path: url.path, recordVolume: here)
                == .signed(FileHasher.segmentedHash(path: url.path)))
        #expect(FileHasher.segmentedHash(path: url.path + ".gone", recordVolume: here) == .unreadable)
    }
}
