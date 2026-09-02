// HallieNeuralPlaybackLedgerTests.swift
// codex #961 (2026-09-02): the speaker counted a chunk before reading it.
import AVFoundation
import XCTest
@testable import VideoScan

final class HallieNeuralPlaybackLedgerTests: XCTestCase {
    func testThreeChunksFinishOnTheLastCompletion() {
        var ledger = HallieNeuralPlaybackLedger()
        ledger.noteScheduled(); ledger.noteScheduled(); ledger.noteScheduled()
        XCTAssertFalse(ledger.notePlayed())
        XCTAssertFalse(ledger.noteSynthesisFinished())   // 1 of 3 played
        XCTAssertFalse(ledger.notePlayed())
        XCTAssertTrue(ledger.notePlayed())                // 3 of 3
    }

    func testPlayedBeforeSynthesisFinishedDoesNotEnd() {
        var ledger = HallieNeuralPlaybackLedger()
        ledger.noteScheduled()
        XCTAssertFalse(ledger.notePlayed(), "more chunks may still be coming")
        XCTAssertTrue(ledger.noteSynthesisFinished())
    }

    /// The #961 case: the FIRST chunk fails to load, nothing was accepted by
    /// the node, and the fallback must not wait for a completion.
    func testFirstChunkFailureCompletesImmediately() {
        var ledger = HallieNeuralPlaybackLedger()
        XCTAssertTrue(ledger.noteSynthesisFinished())
        XCTAssertTrue(ledger.isComplete)
    }

    /// A later chunk fails after two were accepted: playback ends when
    /// those two finish, not before.
    func testLateFailureWaitsOnlyForAcceptedChunks() {
        var ledger = HallieNeuralPlaybackLedger()
        ledger.noteScheduled(); ledger.noteScheduled()
        XCTAssertFalse(ledger.noteSynthesisFinished())
        XCTAssertFalse(ledger.notePlayed())
        XCTAssertTrue(ledger.notePlayed())
    }

    func testResidencyBudgetIsBounded() {
        let mono24k = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        let oneSecond = HallieNeuralResidency.bytes(frames: 24_000, format: mono24k)
        XCTAssertEqual(oneSecond, 96_000)
        XCTAssertTrue(HallieNeuralResidency.keepsResident(bytesSoFar: 0, chunkBytes: oneSecond * 50))
        let tenMinutes = oneSecond * 600
        XCTAssertTrue(HallieNeuralResidency.keepsResident(bytesSoFar: tenMinutes, chunkBytes: oneSecond * 50))
        XCTAssertFalse(HallieNeuralResidency.keepsResident(bytesSoFar: tenMinutes * 2, chunkBytes: oneSecond),
                       "a twenty-minute answer streams its tail from disk")
        let stereo48k = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        XCTAssertEqual(HallieNeuralResidency.bytes(frames: 48_000, format: stereo48k), 384_000,
                       "non-interleaved: bytes-per-frame is per channel")
    }

    /// Loading a chunk that is not a WAV throws BEFORE anything is counted.
    func testLoadChunkThrowsOnGarbage() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hallie-not-audio-\(UUID().uuidString).wav")
        try Data("not audio".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            _ = try await HallieSpeaker.loadChunk(at: url, residentSoFar: 0)
            XCTFail("expected a throw")
        } catch {
            // any error is right; the point is that no count was taken
        }
    }

    func testOverloadCounterStopIsIdempotentAndCountReadableAfterwards() throws {
        guard let device = HallieOutputBuffer.defaultOutputDevice() else {
            throw XCTSkip("no default output device on this machine")
        }
        let counter = HallieOutputBuffer.OverloadCounter(device: device)
        XCTAssertTrue(counter.installed)
        // The device may genuinely overload between init and stop (a build
        // is pinning the cores): the contract is that stop is idempotent
        // and the count is frozen and readable afterwards, not that it is 0.
        let first = counter.stop()
        XCTAssertFalse(counter.installed)
        XCTAssertEqual(counter.removalStatus, noErr)
        XCTAssertEqual(counter.stop(), first, "second stop is a no-op")
        XCTAssertEqual(counter.count, first, "count is readable after stop")
    }
}
