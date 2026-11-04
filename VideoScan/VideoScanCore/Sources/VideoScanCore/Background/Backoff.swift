// Backoff.swift — VideoScanCore/Background
//
// The Mac's say over the helper: ONE actor with ONE published state, `.full`
// or `.paused(reason)`. The decision is the pure `BackoffPolicy.state(for:
// latchedThermal:)`; the actor adds the thermal hysteresis (paused at ≥
// serious, released only at nominal).
//
// Precedence, highest first:
//   1. thermal ≥ serious → paused(thermal)
//   2. memory warning/critical → paused(memory)  (finish the unit)
//   3. otherwise → full
//
// No keyboard / trickle backoff since 2026-11-04 (Rick: the Ultra is
// dedicated; the worker child runs at utility QoS so interactive apps win
// the CPU). `.trickle` stays in the enum only so a status payload from an
// older helper still decodes; nothing produces it.
//
// C++ reading: `actor` ≈ a class whose every method runs under one mutex,
// awaited rather than blocked on.

import Foundation

public enum BackoffState: Codable, Equatable, Sendable {
    case full
    /// Never produced since 2026-11-04; decodes an older helper's payload.
    case trickle
    case paused(reason: String)

    public static let thermalReason = "thermal"
    public static let memoryReason = "memory"
    public static let diskReason = "disk"

    public var words: String {
        switch self {
        case .full: return "full"
        case .trickle: return "trickle"
        case .paused(let reason): return "paused (\(reason))"
        }
    }

    public var isPaused: Bool {
        if case .paused = self { return true }
        return false
    }
}

public enum BackoffPolicy {
    /// The state for one sample. `latchedThermal` is true while a thermal
    /// pause is held waiting for `.nominal`.
    public static func state(for s: ActivitySample, latchedThermal: Bool = false) -> BackoffState {
        if s.thermalState >= .serious || (latchedThermal && s.thermalState != .nominal) {
            return .paused(reason: BackoffState.thermalReason)
        }
        if s.memoryPressure != .normal { return .paused(reason: BackoffState.memoryReason) }
        return .full
    }
}

public actor Backoff {
    private let source: any ActivitySource
    private var latchedThermal = false
    public private(set) var state: BackoffState = .full
    private var observers: [(BackoffState) -> Void] = []

    public init(source: any ActivitySource) {
        self.source = source
    }

    /// Re-read the Mac and publish the state. Called by the supervisor
    /// between units and by the status call.
    @discardableResult
    public func refresh() -> BackoffState {
        let sample = source.sample()
        let next = BackoffPolicy.state(for: sample, latchedThermal: latchedThermal)
        // Hysteresis: a thermal pause holds until the Mac is back to nominal.
        if case .paused(let reason) = next, reason == BackoffState.thermalReason {
            latchedThermal = true
        } else if sample.thermalState == .nominal {
            latchedThermal = false
        }
        if next != state {
            state = next
            for o in observers { o(next) }
        }
        return next
    }

    /// Called with every CHANGE of state (the log line "backoff → paused (thermal)").
    public func onChange(_ observer: @escaping @Sendable (BackoffState) -> Void) {
        observers.append(observer)
    }
}
