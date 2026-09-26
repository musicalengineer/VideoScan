// VolumeKeepalive.swift
// Prevents remote volumes from sleeping during long overnight scans by
// periodically stat()-ing the volume root. When the volume becomes
// unreachable, pauses the scan via PauseGate and polls until it returns.
//
// The keepalive owns ONLY the gate's `.volume` pause reason (night QA
// 2026-09-25, M2): before, it called the gate's single pause()/resume(),
// so a network scan the user had paused resumed by itself after a share
// blip while its row still said Paused. A user Pause is the `.user` reason
// and survives the volume coming back.

import Foundation

actor VolumeKeepalive {
    private let volumePath: String
    private let pollInterval: TimeInterval
    private let recoveryPollInterval: TimeInterval
    private var keepaliveTask: Task<Void, Never>?
    private var isVolumeDown = false
    private let log: @Sendable (String) -> Void

    init(volumePath: String,
         pollInterval: TimeInterval = 30,
         recoveryPollInterval: TimeInterval = 5,
         log: @escaping @Sendable (String) -> Void) {
        self.volumePath = volumePath
        self.pollInterval = pollInterval
        self.recoveryPollInterval = recoveryPollInterval
        self.log = log
    }

    func start(pauseGate: PauseGate) {
        keepaliveTask?.cancel()
        keepaliveTask = Task { [volumePath, pollInterval, recoveryPollInterval, log] in
            // Whether THIS task currently holds the gate's volume reason.
            // Tracked locally (not via isVolumeDown) so the release below
            // happens in the same task as the pause — sequential, so it can
            // never race a pause still in flight. C++ analogy: an RAII guard
            // whose destructor runs when the worker thread's loop exits.
            var holdsVolumePause = false
            while !Task.isCancelled {
                let reachable = await Self.statVolume(volumePath)
                if Task.isCancelled { break }

                if !reachable {
                    let wasDown = await self.markDown()
                    if !wasDown {
                        log("  ⚠ Volume \(volumePath) unreachable — pausing scan, will retry every \(Int(recoveryPollInterval))s")
                    }
                    if !holdsVolumePause {
                        await pauseGate.pause(.volume)
                        holdsVolumePause = true
                    }
                    try? await Task.sleep(for: .seconds(recoveryPollInterval))
                } else {
                    let wasDown = await self.markUp()
                    if wasDown {
                        log("  ✓ Volume \(volumePath) is back — resuming scan")
                    }
                    if holdsVolumePause {
                        await pauseGate.resume(.volume)
                        holdsVolumePause = false
                    }
                    try? await Task.sleep(for: .seconds(pollInterval))
                }
            }
            // Stopped (scan finished, Stop, unmount-abort) while the volume
            // was still down: release our reason so a stale volume pause
            // cannot park the next scan on this target's gate forever. The
            // stopped scan's own waiters already returned on cancellation.
            if holdsVolumePause {
                await pauseGate.resume(.volume)
            }
        }
    }

    func stop() {
        keepaliveTask?.cancel()
        keepaliveTask = nil
    }

    var volumeIsDown: Bool { isVolumeDown }

    private func markDown() -> Bool {
        let was = isVolumeDown
        isVolumeDown = true
        return was
    }

    private func markUp() -> Bool {
        let was = isVolumeDown
        isVolumeDown = false
        return was
    }

    private static func statVolume(_ path: String) async -> Bool {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                var sb = stat()
                let result = stat(path, &sb) == 0
                cont.resume(returning: result)
            }
        }
    }
}
