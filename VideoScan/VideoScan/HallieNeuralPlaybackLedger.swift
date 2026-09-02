// HallieNeuralPlaybackLedger.swift
// The bookkeeping that decides when Bella's playback is OVER, pulled out of
// HallieSpeaker so it can be table-tested (codex #961, 2026-09-02): the
// speaker used to count a chunk as scheduled BEFORE reading it, so a failed
// read left it waiting for a completion that could never arrive — Hallie
// stayed "speaking" and the Apple continuation never started.
//
// C++ readers: a value type with three ints' worth of state and no I/O.
// The speaker owns one per answer and resets it on teardown.

import AVFoundation

struct HallieNeuralPlaybackLedger: Equatable {
    private(set) var scheduled = 0
    private(set) var played = 0
    private(set) var synthesisFinished = false

    /// Call ONLY once the player node has accepted the chunk.
    mutating func noteScheduled() { scheduled += 1 }

    /// A chunk finished playing. True when that completion ends the answer.
    @discardableResult
    mutating func notePlayed() -> Bool {
        played += 1
        return isComplete
    }

    /// No more chunks will be scheduled (normal end, or a later chunk
    /// failed and Apple reads the rest). True when nothing is still owed —
    /// including the case where NOTHING was ever scheduled.
    @discardableResult
    mutating func noteSynthesisFinished() -> Bool {
        synthesisFinished = true
        return isComplete
    }

    var isComplete: Bool { synthesisFinished && played >= scheduled }
}

/// How much synthesized audio may sit in memory at once. Bella's WAVs are
/// 24 kHz mono Float32 ≈ 96 KB per second of speech, so the 64 MB budget is
/// about eleven minutes of continuous talking; a longer answer streams the
/// remainder from disk (the pre-9/02 path) instead of growing without
/// bound (codex #961).
enum HallieNeuralResidency {
    static let budgetBytes = 64 << 20

    static func bytes(frames: Int64, format: AVAudioFormat) -> Int {
        let asbd = format.streamDescription.pointee
        let perFrame = Int(asbd.mBytesPerFrame) * (format.isInterleaved ? 1 : Int(format.channelCount))
        return Int(frames) * max(perFrame, 1)
    }

    static func keepsResident(bytesSoFar: Int, chunkBytes: Int, budget: Int = budgetBytes) -> Bool {
        bytesSoFar + chunkBytes <= budget
    }
}
