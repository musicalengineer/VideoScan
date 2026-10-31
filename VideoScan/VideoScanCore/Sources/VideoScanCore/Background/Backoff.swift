// Backoff.swift — VideoScanCore/Background
//
// "It backs off while Rick works" (design §0.5, §3.5). ONE actor with ONE
// published state: `.full`, `.trickle`, `.paused(reason)`. The decision is
// the pure `BackoffPolicy.state(for:latchedThermal:)`; the actor adds the
// thermal hysteresis (paused at ≥ serious, released only at nominal) and
// the trickle cadence the supervisor sleeps between units.
//
// Precedence, highest first (the table in §3.5, resolved where rows meet):
//   1. thermal ≥ serious → paused(thermal)       (the Mac first)
//   2. memory warning/critical → paused(memory)  (finish the unit, unload)
//   3. night window → full                       (Rick asked for it)
//   4. screen locked → full                      (Rick is away)
//   5. app frontmost on an attended job → trickle
//   6. input within idleThreshold → trickle      (Rick is at the keyboard)
//   7. otherwise → full
//
// C++ reading: `actor` ≈ a class whose every method runs under one mutex,
// awaited rather than blocked on.

import Foundation

public enum BackoffState: Codable, Equatable, Sendable {
    case full
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
    /// Seconds of no input before Rick counts as away (design §3.5: 300 s).
    public static let defaultIdleThreshold: Double = 300

    /// The state for one sample. `latchedThermal` is true while a thermal
    /// pause is held waiting for `.nominal`.
    public static func state(for s: ActivitySample, idleThreshold: Double = defaultIdleThreshold,
                             latchedThermal: Bool = false) -> BackoffState {
        if s.thermalState >= .serious || (latchedThermal && s.thermalState != .nominal) {
            return .paused(reason: BackoffState.thermalReason)
        }
        if s.memoryPressure != .normal { return .paused(reason: BackoffState.memoryReason) }
        if s.nightWindow { return .full }
        if s.isScreenLocked { return .full }
        if s.appForegroundAttended { return .trickle }
        if s.secondsSinceLastInput < idleThreshold { return .trickle }
        return .full
    }
}

public actor Backoff {
    private let source: any ActivitySource
    private let idleThreshold: Double
    /// Seconds between units while trickling (design §6 sensor 3: ≤ 1 unit
    /// per 5 s with recent input). Injected so tests run in milliseconds.
    public let trickleInterval: Duration
    private var latchedThermal = false
    public private(set) var state: BackoffState = .full
    private var observers: [(BackoffState) -> Void] = []

    public init(source: any ActivitySource, idleThreshold: Double = BackoffPolicy.defaultIdleThreshold,
                trickleInterval: Duration = .seconds(5)) {
        self.source = source
        self.idleThreshold = idleThreshold
        self.trickleInterval = trickleInterval
    }

    /// Re-read the Mac and publish the state. Called by the supervisor
    /// between units and by the status call.
    @discardableResult
    public func refresh() -> BackoffState {
        let sample = source.sample()
        let next = BackoffPolicy.state(for: sample, idleThreshold: idleThreshold, latchedThermal: latchedThermal)
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

    /// Called with every CHANGE of state (the log line "backoff → trickle").
    public func onChange(_ observer: @escaping @Sendable (BackoffState) -> Void) {
        observers.append(observer)
    }
}
