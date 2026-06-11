import Testing
import Foundation
@testable import VideoScan

// MARK: - ScanJob live-knob concurrency tests
//
// Added 2026-06-11 alongside the concurrency-hygiene pass that replaced
// `nonisolated(unsafe) var previewRate` (which leaned on ARM64 word
// atomicity) with an OSAllocatedUnfairLock-backed property. These tests
// pin the contract the scan loop depends on:
//   - previewRate is readable/writable from off-main contexts (the scan
//     loop polls it each frame via a @Sendable closure),
//   - concurrent writers + readers don't crash or tear, and
//   - a value written on the main actor is visible to a subsequent
//     off-main read (lock acquire/release gives the happens-before edge).
// TSan isn't in the CI loop, so at minimum the API behavior is pinned.
//
// C++ analogy: this is the classic "hammer one mutex-guarded int from N
// threads, assert every observed value is one somebody actually wrote".

struct ScanJobKnobConcurrencyTests {

    @MainActor
    private func makeJob() -> ScanJob {
        ScanJob(searchPath: "/tmp/ScanJobKnobConcurrencyTests")
    }

    /// Default must survive the lock-backed rewrite (was a stored `= 5`).
    @Test func previewRateDefaultIsFive() async {
        let job = await makeJob()
        #expect(job.previewRate == 5)
    }

    /// Main-actor write → off-main read, the production direction
    /// (RealtimeFaceDetectionWindow slider writes, scan loop polls).
    @Test func previewRateMainWriteVisibleOffMain() async {
        let job = await makeJob()
        await MainActor.run { job.previewRate = 12 }
        // Mirror the production access pattern: JobLifecycle hands the
        // engines `previewRateFn: { job.previewRate }` as a @Sendable
        // closure invoked from the (off-main) scan loop.
        let previewRateFn: @Sendable () -> Int = { job.previewRate }
        let read = await Task.detached { previewRateFn() }.value
        #expect(read == 12)
    }

    /// Concurrent writers and readers must not crash, and readers must
    /// only ever observe values some writer actually stored (no tearing,
    /// no out-of-thin-air values).
    @Test func previewRateConcurrentReadWriteIsSafe() async {
        let job = await makeJob()
        let iterations = 2_000
        let written = Set(1...64)

        await withTaskGroup(of: Void.self) { group in
            // Two writer tasks cycling through known values.
            for offset in [1, 33] {
                group.addTask {
                    for i in 0..<iterations {
                        job.previewRate = (i % 32) + offset
                    }
                }
            }
            // Two reader tasks validating every observation.
            for _ in 0..<2 {
                group.addTask {
                    for _ in 0..<iterations {
                        let v = job.previewRate
                        #expect(v == 5 || written.contains(v))
                    }
                }
            }
        }
        // Terminal state is whatever a writer last stored — must be sane.
        #expect(written.contains(job.previewRate))
    }
}
