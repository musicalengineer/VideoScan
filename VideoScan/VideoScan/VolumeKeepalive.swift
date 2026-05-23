// VolumeKeepalive.swift
// Prevents remote volumes from sleeping during long overnight scans by
// periodically stat()-ing the volume root. When the volume becomes
// unreachable, pauses the scan via PauseGate and polls until it returns.

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
            while !Task.isCancelled {
                let reachable = await Self.statVolume(volumePath)

                if !reachable {
                    let wasDown = await self.markDown()
                    if !wasDown {
                        log("  ⚠ Volume \(volumePath) unreachable — pausing scan, will retry every \(Int(recoveryPollInterval))s")
                        await pauseGate.pause()
                    }
                    try? await Task.sleep(for: .seconds(recoveryPollInterval))
                } else {
                    let wasDown = await self.markUp()
                    if wasDown {
                        log("  ✓ Volume \(volumePath) is back — resuming scan")
                        await pauseGate.resume()
                    }
                    try? await Task.sleep(for: .seconds(pollInterval))
                }
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
