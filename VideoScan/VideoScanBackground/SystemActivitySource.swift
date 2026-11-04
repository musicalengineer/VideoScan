// SystemActivitySource.swift — VideoScan Background
//
// The real Mac behind `Backoff`: ProcessInfo.thermalState and a
// memory-pressure DispatchSource. No keyboard / lock-screen reading since
// 2026-11-04 (Rick: no energy backoff on the Ultra; the worker runs at
// utility QoS instead).

import Foundation
import VideoScanCore

final class SystemActivitySource: ActivitySource, @unchecked Sendable {
    private let lock = NSLock()
    private var memoryPressure: MemoryPressureLevel = .normal
    private var pressureSource: DispatchSourceMemoryPressure?

    func start() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical],
                                                             queue: DispatchQueue(label: "VideoScan.Background.memory", qos: .utility))
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            let event = source.data
            let level: MemoryPressureLevel = event.contains(.critical) ? .critical : event.contains(.warning) ? .warning : .normal
            self.lock.lock()
            self.memoryPressure = level
            self.lock.unlock()
        }
        source.resume()
        pressureSource = source
    }

    func sample() -> ActivitySample {
        lock.lock()
        let pressure = memoryPressure
        lock.unlock()
        return ActivitySample(thermalState: Self.thermalLevel(ProcessInfo.processInfo.thermalState), memoryPressure: pressure)
    }

    static func thermalLevel(_ state: ProcessInfo.ThermalState) -> ThermalLevel {
        switch state {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .serious
        }
    }
}
