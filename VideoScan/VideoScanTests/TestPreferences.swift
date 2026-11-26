// TestPreferences.swift — test support: the ONE way a test touches preferences.
//
// WHY (2026-11-25): Rick's real `archivist.ollamaHosts` read "poison.invalid".
// A hosted test's `UserDefaults.standard` IS the app's real domain
// (Rick-Breen.VideoScan), and the sealed home does not move it: cfprefsd writes
// the REAL user's ~/Library/Preferences whatever HOME / CFFIXED_USER_HOME say
// (measured 2026-11-25 — a suite written with both pointed at a scratch home
// landed in ~/Library/Preferences). Five tests set that key to "poison.invalid"
// and restored it in a `defer`. Suites run in parallel, so the snapshot/restore
// pairs crossed: A saved nil and set the poison; B saved A's poison as its
// "prior"; A removed it; B "restored" the poison — on disk, for good.
//
// So a test never writes `.standard` (TestDefaultsWriteSensorTests holds that).
// It has three tools instead:
//
//   * `overriding(_:body)` — a value every read in this process sees for the
//     length of `body`, put in the VOLATILE argument domain: in memory, highest
//     precedence in every UserDefaults search list (`.standard` and suites
//     alike), never written to any plist. Overrides of one key nest and cross
//     safely: each key keeps a stack of live overrides, and leaving one removes
//     ITS entry, whatever order the overlapping scopes end in — the crossed
//     snapshot/restore above cannot happen. ≈ C++: a scoped, ref-counted
//     override layer over a config map; RAII, and nothing reaches the disk.
//   * `scratch(_:)` — a throwaway persistent suite for code that takes its
//     `UserDefaults` (most does: `OllamaEndpoints`, `ScanTargetPersistence`, …).
//     Its name is unique per call; the caller `remove()`s it in a `defer`.
//   * `persistedAppValue(forKey:)` — a READ of the host's on-disk value, for a
//     test proving the code under test did not write the real domain.
//
// Memory: one small dictionary per live override; the argument domain is the
// launch arguments plus the live overrides (a handful of keys).

import Foundation

enum TestPreferences {

    /// The live overrides, guarded by `lock`. ≈ C++: a mutex-guarded static.
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        /// key → (scope token, value), innermost last.
        var stacks: [String: [(token: UUID, value: any Sendable)]] = [:]
        /// key → the argument-domain value before its first live override
        /// (a launch argument); absent when there was none.
        var underlying: [String: Any] = [:]     // plist values; guarded by `lock`
    }
    private static let state = State()

    /// A process-wide, in-memory override of `values` for the length of `body`.
    static func overriding<T>(_ values: [String: any Sendable], _ body: () throws -> T) rethrows -> T {
        let token = push(values)
        defer { pop(token, keys: Array(values.keys)) }
        return try body()
    }

    /// The async form (≈ the same RAII scope around a coroutine).
    static func overriding<T>(_ values: [String: any Sendable],
                              isolation: isolated (any Actor)? = #isolation,
                              _ body: () async throws -> T) async rethrows -> T {
        let token = push(values)
        defer { pop(token, keys: Array(values.keys)) }
        return try await body()
    }

    /// The scope as an explicit token, for a test that needs two scopes to
    /// overlap in a chosen order. `end()` exactly once.
    struct Scope {
        fileprivate let token: UUID
        fileprivate let keys: [String]
        func end() { TestPreferences.pop(token, keys: keys) }
    }

    static func begin(_ values: [String: any Sendable]) -> Scope {
        Scope(token: push(values), keys: Array(values.keys))
    }

    private static func push(_ values: [String: any Sendable]) -> UUID {
        let token = UUID()
        state.lock.withLock {
            let current = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            for (key, value) in values {
                if state.stacks[key, default: []].isEmpty {
                    state.underlying[key] = current[key]
                }
                state.stacks[key, default: []].append((token, value))
            }
            publish(Array(values.keys))
        }
        return token
    }

    fileprivate static func pop(_ token: UUID, keys: [String]) {
        state.lock.withLock {
            for key in keys {
                state.stacks[key]?.removeAll { $0.token == token }
            }
            publish(keys)
        }
    }

    /// Write `keys`' effective values into the argument domain. Caller holds the lock.
    private static func publish(_ keys: [String]) {
        var domain = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        for key in keys {
            if let top = state.stacks[key]?.last {
                domain[key] = top.value
            } else {
                state.stacks[key] = nil
                if let under = state.underlying.removeValue(forKey: key) {
                    domain[key] = under
                } else {
                    domain.removeValue(forKey: key)
                }
            }
        }
        // setVolatileDomain refuses a name that already exists: replace it.
        UserDefaults.standard.removeVolatileDomain(forName: UserDefaults.argumentDomain)
        UserDefaults.standard.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
    }

    // MARK: - Scratch suites

    /// A throwaway persistent suite (unique name, empty on arrival).
    struct Scratch {
        let name: String
        let defaults: UserDefaults
        /// The suite's own on-disk dictionary — what was really persisted.
        var persisted: [String: Any] { defaults.persistentDomain(forName: name) ?? [:] }
        func remove() { defaults.removePersistentDomain(forName: name) }
    }

    static func scratch(_ label: String) -> Scratch {
        let name = "VideoScanTests.\(label).\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            preconditionFailure("could not create test defaults suite \(name)")
        }
        defaults.removePersistentDomain(forName: name)
        return Scratch(name: name, defaults: defaults)
    }

    // MARK: - Reading the real domain (never writing it)

    /// The test host's own domain — the app's bundle identifier.
    static var appDomain: String { Bundle.main.bundleIdentifier ?? "" }

    /// The value the host's preferences plist holds for `key` — overrides and
    /// the registration domain excluded. Read-only.
    static func persistedAppValue(forKey key: String) -> Any? {
        UserDefaults.standard.persistentDomain(forName: appDomain)?[key]
    }

    /// `persistedAppValue` for several keys, as a comparable dictionary.
    static func persistedAppValues(forKeys keys: [String]) -> NSDictionary {
        let domain = UserDefaults.standard.persistentDomain(forName: appDomain) ?? [:]
        return NSDictionary(dictionary: domain.filter { keys.contains($0.key) })
    }
}
