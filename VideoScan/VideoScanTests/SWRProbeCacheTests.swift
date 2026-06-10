// SWRProbeCacheTests.swift
// Pins the stale-while-revalidate state machine behind
// VolumeReachability.isReachable / displayLabel (perf fix 2026-06-10:
// the synchronous API must NEVER touch the filesystem on the caller's
// thread — a sleeping HDD / stale SMB mount was blocking the main thread
// for seconds on every 5 s cache expiry while scrolling the catalog).
//
// The state machine under test:
//   - UNKNOWN key  → missDefault returned immediately, probe scheduled
//   - FRESH entry  → cached value, NO probe
//   - STALE entry  → stale value returned immediately, ONE probe scheduled
//   - refresh      → probe result becomes the fresh value
//   - concurrent stale/miss queries for one key → probes coalesce to one
//   - invalidateAll → back to UNKNOWN semantics
//
// Every test constructs its own SWRProbeCache with an injected probe
// closure — no real volumes, no shared static state, parallel-suite safe.

import Testing
import Foundation
@testable import VideoScan

/// Thread-safe scripted probe: counts invocations and returns values from
/// a queue (last value repeats). Probes run on the cache's background
/// queue, so the counter needs real locking.
private final class ScriptedProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var script: [Bool]
    private(set) var callCount = 0
    /// Optional artificial latency, to hold a probe "in flight".
    var delay: TimeInterval = 0

    init(_ script: [Bool]) {
        precondition(!script.isEmpty)
        self.script = script
    }

    func probe(_ key: String) -> Bool {
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        lock.lock()
        defer { lock.unlock() }
        callCount += 1
        return script.count > 1 ? script.removeFirst() : script[0]
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return callCount
    }
}

@Suite("SWRProbeCache state machine")
struct SWRProbeCacheTests {

    private func makeCache(ttl: CFAbsoluteTime, probe: ScriptedProbe) -> SWRProbeCache<Bool> {
        SWRProbeCache<Bool>(
            label: "test.swr.\(UUID().uuidString)",
            ttl: ttl,
            probe: { probe.probe($0) }
        )
    }

    // MARK: Unknown key → optimistic default + background fill

    @Test func unknownKeyReturnsMissDefaultWithoutBlocking() {
        let probe = ScriptedProbe([false])
        let cache = makeCache(ttl: 10, probe: probe)

        // Probe will say false, but the synchronous answer must be the
        // optimistic default — the caller's thread never waits on the probe.
        #expect(cache.value(forKey: "/Volumes/X", missDefault: true) == true)

        cache.awaitPendingProbes()
        #expect(probe.count == 1, "Miss must schedule exactly one probe")
        // Now the honest answer is cached.
        #expect(cache.value(forKey: "/Volumes/X", missDefault: true) == false)
    }

    // MARK: Fresh hit → no probe

    @Test func freshHitDoesNotReprobe() {
        let probe = ScriptedProbe([true])
        let cache = makeCache(ttl: 10, probe: probe)

        _ = cache.value(forKey: "k", missDefault: true)
        cache.awaitPendingProbes()
        #expect(probe.count == 1)

        // Within TTL: repeated queries are pure cache hits.
        for _ in 0..<5 {
            #expect(cache.value(forKey: "k", missDefault: true) == true)
        }
        cache.awaitPendingProbes()
        #expect(probe.count == 1, "Fresh entries must not trigger probes")
    }

    // MARK: Stale hit → old value now, refreshed value later

    @Test func staleHitReturnsOldValueThenRefreshes() throws {
        // Script: first probe says false (drive offline), second says true
        // (drive woke up).
        let probe = ScriptedProbe([false, true])
        let cache = makeCache(ttl: 0.02, probe: probe)

        _ = cache.value(forKey: "k", missDefault: true)   // miss → probe #1
        cache.awaitPendingProbes()
        #expect(cache.value(forKey: "k", missDefault: true) == false)

        // Let the entry expire.
        Thread.sleep(forTimeInterval: 0.05)

        // STALE: must return the OLD value (false) immediately — never the
        // miss default, never a blocking re-probe — while refresh #2 runs.
        #expect(cache.value(forKey: "k", missDefault: true) == false,
                "Stale hit must serve the last known value")
        cache.awaitPendingProbes()
        #expect(probe.count == 2)
        #expect(cache.value(forKey: "k", missDefault: true) == true,
                "Refresh must install the new probe result")
    }

    // MARK: Coalescing — one probe per key, however many callers

    @Test func concurrentQueriesCoalesceToOneProbe() {
        let probe = ScriptedProbe([true])
        probe.delay = 0.15   // hold the probe in flight
        let cache = makeCache(ttl: 10, probe: probe)

        // Burst of queries while the first probe is still running — the
        // catalog table does exactly this (one call per visible row).
        for _ in 0..<20 {
            #expect(cache.value(forKey: "/Volumes/HDD", missDefault: true) == true)
        }
        cache.awaitPendingProbes()
        #expect(probe.count == 1, "In-flight probe must absorb all concurrent misses for its key")
    }

    @Test func distinctKeysProbeIndependently() {
        let probe = ScriptedProbe([true])
        let cache = makeCache(ttl: 10, probe: probe)

        _ = cache.value(forKey: "/Volumes/A", missDefault: true)
        _ = cache.value(forKey: "/Volumes/B", missDefault: true)
        cache.awaitPendingProbes()
        #expect(probe.count == 2, "Coalescing is per key, not global")
    }

    // MARK: invalidateAll → unknown-key semantics again

    @Test func invalidateAllRestoresMissSemantics() {
        let probe = ScriptedProbe([false])
        let cache = makeCache(ttl: 10, probe: probe)

        _ = cache.value(forKey: "k", missDefault: true)
        cache.awaitPendingProbes()
        #expect(cache.value(forKey: "k", missDefault: true) == false)

        cache.invalidateAll()
        // Back to optimistic default + a fresh probe.
        #expect(cache.value(forKey: "k", missDefault: true) == true)
        cache.awaitPendingProbes()
        #expect(probe.count == 2)
    }

    // MARK: Optional Value — a failed probe (nil) is a cached fact

    @Test func cachedNilBeatsMissDefault() {
        // Mirrors volumeNameCache: Value = String?, probe failure caches
        // nil, and a cached nil must NOT be confused with "never probed".
        let counter = ScriptedProbe([true])  // reused just for its counter
        let cache = SWRProbeCache<String?>(
            label: "test.swr.names.\(UUID().uuidString)",
            ttl: 10,
            probe: { key in
                _ = counter.probe(key)
                return nil   // resourceValues failed (offline volume)
            }
        )

        // Miss: default served, probe scheduled.
        #expect(cache.value(forKey: "/Volumes/Offline", missDefault: nil) == nil)
        cache.awaitPendingProbes()
        #expect(counter.count == 1)

        // Fresh cached nil: served WITHOUT a re-probe.
        #expect(cache.value(forKey: "/Volumes/Offline", missDefault: nil) == nil)
        cache.awaitPendingProbes()
        #expect(counter.count == 1, "Cached nil is fresh — no re-probe within TTL")
    }
}
