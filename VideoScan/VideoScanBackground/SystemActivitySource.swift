// SystemActivitySource.swift — VideoScan Background
//
// The real Mac behind `Backoff` (design §3.5 table): seconds since the last
// keyboard/mouse event (CGEventSource), the lock screen
// (CGSessionCopyCurrentDictionary), ProcessInfo.thermalState and a
// memory-pressure DispatchSource. Core never imports CoreGraphics; this is
// the one file that does.
//
// `appForegroundAttended` is the XPC heartbeat from the app (design §3.5
// row 2); the app does not send it yet, so it reads false — the policy for
// it is already tested in Core (BackoffPolicyTests).

import CoreGraphics
import Foundation
import VideoScanCore

final class SystemActivitySource: ActivitySource, @unchecked Sendable {
    private let lock = NSLock()
    private var memoryPressure: MemoryPressureLevel = .normal
    private var pressureSource: DispatchSourceMemoryPressure?
    private let nightWindow: Bool

    init(nightWindow: Bool) {
        self.nightWindow = nightWindow
    }

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
        return ActivitySample(secondsSinceLastInput: Self.secondsSinceLastInput(),
                              isScreenLocked: Self.isScreenLocked(),
                              thermalState: Self.thermalLevel(ProcessInfo.processInfo.thermalState),
                              memoryPressure: pressure,
                              appForegroundAttended: false,
                              nightWindow: nightWindow)
    }

    /// The smallest "seconds since" over the input event types a person
    /// produces. (`kCGAnyInputEventType` is a C macro Swift does not import
    /// as a `CGEventType` case; the minimum over the real types is the same
    /// number and cannot trip an unrepresentable raw value.)
    static func secondsSinceLastInput() -> Double {
        let types: [CGEventType] = [.keyDown, .flagsChanged, .mouseMoved, .leftMouseDown, .rightMouseDown,
                                    .otherMouseDown, .scrollWheel, .leftMouseDragged]
        return types.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? .infinity
    }

    static func isScreenLocked() -> Bool {
        guard let dictionary = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if let locked = dictionary["CGSSessionScreenIsLocked"] as? Bool { return locked }
        if let locked = dictionary["CGSSessionScreenIsLocked"] as? Int { return locked != 0 }
        return false
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
