// ActivitySource.swift — VideoScanCore/Background
//
// What `Backoff` looks at, as plain values. The helper's
// `SystemActivitySource` fills them from ProcessInfo.thermalState and a
// memory-pressure DispatchSource; tests hand in a `FakeActivitySource`.
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

/// One reading of the Mac. Since 2026-11-04 only the Mac's own limits count
/// (thermal, memory): there is no keyboard backoff (Rick: the Ultra is
/// dedicated to this work; the worker runs at utility QoS instead).
public struct ActivitySample: Equatable, Sendable {
    public var thermalState: ThermalLevel
    public var memoryPressure: MemoryPressureLevel

    public init(thermalState: ThermalLevel = .nominal, memoryPressure: MemoryPressureLevel = .normal) {
        self.thermalState = thermalState
        self.memoryPressure = memoryPressure
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
