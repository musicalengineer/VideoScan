// ActivitySource.swift — VideoScanCore/Background
//
// What `Backoff` looks at (design §3.5 table), as plain values. The helper's
// `SystemActivitySource` fills them from CGEventSource, CGSession,
// ProcessInfo.thermalState and a memory-pressure DispatchSource; tests hand
// in a `FakeActivitySource`. Core itself never imports CoreGraphics.
//
// C++ reading: a sensor interface with one `sample()` — the policy is a pure
// function of the sample, so the policy is testable without a Mac.

import Foundation

/// ProcessInfo.ThermalState without importing it here (the raw strings are
/// what the status payload carries).
public enum ThermalLevel: String, Codable, Sendable, Comparable {
    case nominal, fair, serious, critical

    private var rank: Int {
        switch self {
        case .nominal: return 0
        case .fair: return 1
        case .serious: return 2
        case .critical: return 3
        }
    }
    public static func < (lhs: ThermalLevel, rhs: ThermalLevel) -> Bool { lhs.rank < rhs.rank }
}

/// DispatchSource.MemoryPressureEvent, as words.
public enum MemoryPressureLevel: String, Codable, Sendable {
    case normal, warning, critical
}

/// One reading of the Mac.
public struct ActivitySample: Equatable, Sendable {
    /// Seconds since the last keyboard or mouse event in the login session.
    public var secondsSinceLastInput: Double
    /// CGSSessionScreenIsLocked — Rick is away.
    public var isScreenLocked: Bool
    public var thermalState: ThermalLevel
    public var memoryPressure: MemoryPressureLevel
    /// The app is frontmost with a Rick-attended job running (XPC heartbeat).
    public var appForegroundAttended: Bool
    /// Inside the nightly window (or the CLI's `--full`): run full-out.
    public var nightWindow: Bool

    public init(secondsSinceLastInput: Double = .infinity, isScreenLocked: Bool = false,
                thermalState: ThermalLevel = .nominal, memoryPressure: MemoryPressureLevel = .normal,
                appForegroundAttended: Bool = false, nightWindow: Bool = false) {
        self.secondsSinceLastInput = secondsSinceLastInput
        self.isScreenLocked = isScreenLocked
        self.thermalState = thermalState
        self.memoryPressure = memoryPressure
        self.appForegroundAttended = appForegroundAttended
        self.nightWindow = nightWindow
    }
}

public protocol ActivitySource: Sendable {
    func sample() -> ActivitySample
}

/// A scripted source for tests: returns the current `sample`, settable.
public final class FakeActivitySource: ActivitySource, @unchecked Sendable {
    private let lock = NSLock()
    private var current: ActivitySample

    public init(_ sample: ActivitySample = ActivitySample()) { self.current = sample }

    public func sample() -> ActivitySample {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    public func set(_ sample: ActivitySample) {
        lock.lock(); defer { lock.unlock() }
        current = sample
    }

    public func update(_ change: (inout ActivitySample) -> Void) {
        lock.lock(); defer { lock.unlock() }
        change(&current)
    }
}
