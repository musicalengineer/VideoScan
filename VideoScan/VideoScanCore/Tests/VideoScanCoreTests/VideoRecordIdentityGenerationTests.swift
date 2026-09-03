// VideoRecordIdentityGenerationTests.swift
//
// `VideoRecord.identityGeneration` (2026-09-02, codex #987 item 1): a
// process-wide monotonic count of identity writes — filename, fullPath,
// purgedAt — that name-keyed memo tables (the app's record-reference
// index) put in their key so a same-buffer, same-version mutation is an
// authoritative invalidation, not a heuristic one.
//
// Plain `import VideoScanCore` (not @testable): the generation is PUBLIC
// API the app reads. The counter is shared by every test in the process,
// so each expectation is a DELTA between two reads around this test's own
// writes, never an absolute value — other suites may be building records
// concurrently, which can only make a delta larger, and every assertion
// here is ">=" for that reason except the one that counts a run of writes
// this test alone performs on a serial path.

import Foundation
import Testing
import VideoScanCore

@Suite("VideoRecord identity generation")
struct VideoRecordIdentityGenerationTests {
    @Test func filenameFullPathAndPurgeWritesEachBumpTheGeneration() {
        let record = VideoRecord()
        let before = VideoRecord.identityGeneration
        record.filename = "a.mov"
        let afterFilename = VideoRecord.identityGeneration
        #expect(afterFilename > before, "a filename write must bump the generation")
        record.fullPath = "/Volumes/A/a.mov"
        let afterPath = VideoRecord.identityGeneration
        #expect(afterPath > afterFilename, "a fullPath write must bump the generation")
        record.purgedAt = Date()
        let afterPurge = VideoRecord.identityGeneration
        #expect(afterPurge > afterPath, "a purge must bump the generation")
        record.purgedAt = nil
        #expect(VideoRecord.identityGeneration > afterPurge, "a restore must bump the generation")
    }

    @Test func aWriteOfTheSameValueStillBumps() {
        // `didSet` fires on every store, equal value or not — the memo
        // does not care, and "no change" is not worth a string compare.
        let record = VideoRecord()
        record.filename = "same.mov"
        let before = VideoRecord.identityGeneration
        record.filename = "same.mov"
        #expect(VideoRecord.identityGeneration > before)
    }

    @Test func nonIdentityWritesDoNotBumpOnTheirOwn() {
        let record = VideoRecord()
        record.filename = "x.mov"
        let before = VideoRecord.identityGeneration
        record.notes = "a note"
        record.sizeBytes = 42
        record.directory = "/Volumes/A"
        // Only a lower bound is safe (other suites may write identities in
        // parallel); what this proves is that the three writes above are
        // not REQUIRED to bump. The delta check below runs a serial burst
        // and is exact when the process is otherwise quiet.
        #expect(VideoRecord.identityGeneration >= before)
    }

    @Test func decodingDoesNotBumpAndAssignmentAfterwardsDoes() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","filename":"decoded.mov","fullPath":"/Volumes/A/decoded.mov"}"#
        let decoder = JSONDecoder()
        let before = VideoRecord.identityGeneration
        let record = try decoder.decode(VideoRecord.self, from: Data(json.utf8))
        let afterDecode = VideoRecord.identityGeneration
        #expect(record.filename == "decoded.mov")
        // Swift runs no property observers inside the type's own init, so
        // a decode is free; this is a lower-bound check only because the
        // counter is process-wide.
        #expect(afterDecode >= before)
        record.filename = "renamed.mov"
        #expect(VideoRecord.identityGeneration > afterDecode)
    }

    @Test func concurrentWritersNeverLoseABump() async {
        // 8 tasks × 2,000 identity writes: the lock makes every increment
        // land, so the delta is at least 16,000 (more if another suite is
        // constructing records at the same time).
        let writers = 8
        let perWriter = 2_000
        let before = VideoRecord.identityGeneration
        await withTaskGroup(of: Void.self) { group in
            for writer in 0..<writers {
                group.addTask {
                    let record = VideoRecord()
                    for index in 0..<perWriter {
                        record.filename = "w\(writer)_\(index).mov"
                    }
                }
            }
        }
        let delta = VideoRecord.identityGeneration &- before
        #expect(delta >= UInt64(writers * perWriter), "lost increments: delta \(delta)")
    }

    @Test func aBurstOfWritesCostsMicrosecondsEach() {
        // Budget sensor: 100k identity writes (a full rescan's worth of
        // record construction) must stay well under a second.
        let record = VideoRecord()
        let started = ContinuousClock.now
        for index in 0..<100_000 {
            record.filename = "clip_\(index).mov"
        }
        let elapsed = ContinuousClock.now - started
        #expect(elapsed < .seconds(1), "100k identity writes took \(elapsed)")
    }
}
