//
//  PromoteProgressReporter.swift
//  VideoScan
//
//  Throttled, phase-aware progress text for the Promote job: "Copying X ·
//  47 of 69 GB · 187 MB/s · ~2 min" / "Verifying X · …". A 69 GB VHS
//  capture posts ~70k 1 MB chunk callbacks per pass; this reduces that to
//  ~4 UI updates per second and computes rate/ETA per phase. Thread-safe
//  (called from the copy thread), no main-actor state.
//

import Foundation

final class PromoteProgressReporter: @unchecked Sendable {
    struct Tick {
        let doneText: String
        let totalText: String
        let rateText: String
        let etaText: String
    }

    private let lock = NSLock()
    private var phase: ArchivePromoteEngine.ProgressPhase?
    private var phaseStart = Date()
    private var lastPost = Date.distantPast
    private let minInterval: TimeInterval

    init(minInterval: TimeInterval = 0.25) { self.minInterval = minInterval }

    /// Returns a tick to display, or nil when throttled. Always returns a
    /// tick on a phase change and on completion of a phase.
    func tick(phase: ArchivePromoteEngine.ProgressPhase, done: Int64, fileBytes: Int64) -> Tick? {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        if self.phase != phase {
            self.phase = phase
            phaseStart = now
            lastPost = .distantPast
        }
        let complete = done >= fileBytes
        guard complete || now.timeIntervalSince(lastPost) >= minInterval else { return nil }
        lastPost = now
        let elapsed = max(0.001, now.timeIntervalSince(phaseStart))
        let rate = Double(done) / elapsed                       // bytes/s
        let remaining = max(0, fileBytes - done)
        let eta = rate > 0 ? Double(remaining) / rate : 0
        let fmt = ByteCountFormatter(); fmt.countStyle = .file
        let etaText: String
        if complete || eta < 1 { etaText = "" }
        else if eta < 90 { etaText = " · ~\(Int(eta.rounded())) s" }
        else { etaText = " · ~\(Int((eta / 60).rounded())) min" }
        return Tick(doneText: fmt.string(fromByteCount: done),
                    totalText: fmt.string(fromByteCount: fileBytes),
                    rateText: fmt.string(fromByteCount: Int64(rate)) + "/s",
                    etaText: etaText)
    }
}
