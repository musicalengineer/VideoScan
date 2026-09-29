// OllamaStructuredOutputCapability.swift
// What each ollama endpoint told us about its own build (2026-09-03).
//
// Split out of OllamaQueryTranslator.swift because it is a different
// thing with a different lifetime: the translator is a value copied per
// request and per host, this is one shared, mutable, process-scoped fact
// about the fleet. See `OllamaQueryTranslator.requestContent` for the
// recovery this memo makes cheap, and
// OllamaStructuredOutputFallbackTests.swift for the incident it came
// from — Rick's M4, two days before a family demo, unable to answer
// anything because its Homebrew ollama could not honour `format:`.

import Foundation

/// Which ollama endpoints have already told us their build cannot honour
/// `format:`.
///
/// PURPOSE: cost, not correctness. The fallback in `requestContent`
/// recovers a 501 on its own, but the doomed round trip is not free —
/// Rick's server log shows the refused request still prefilling the
/// prompt, ~700–840 ms burned per attempt, twice per host once the
/// connection retry joins in. Remembering the answer makes that a
/// once-per-run cost instead of a once-per-question cost.
///
/// DELIBERATELY IN MEMORY ONLY. Nothing here is persisted — no
/// UserDefaults, no file — so a fresh process re-probes every host. That
/// is the whole safety story for the case that matters: Rick upgrades
/// Homebrew, or ships the missing dylib, and the very next launch uses
/// structured output again with nothing to clear. A memo that outlived
/// the process could silently keep a healthy host degraded forever, and
/// no one would think to look here.
///
/// (C++ analogy: an `actor` is a class whose every method body is
/// implicitly wrapped in a lock on its own mutex — callers `await`
/// instead of blocking. It is how Swift gives you a data-race-free
/// mutable singleton without writing the locking yourself.)
actor OllamaStructuredOutputCapability {

    /// Process-wide default. Injectable on the translator so tests get a
    /// fresh, isolated instance and never inherit another test's memo.
    static let shared = OllamaStructuredOutputCapability()

    /// Keyed by full chat-endpoint URL, not by bare hostname: the same
    /// machine can serve two ollama builds on two ports, and a capability
    /// learned from one must not be attributed to the other.
    private var unsupportedEndpoints: Set<String> = []

    init() {}

    func isUnsupported(_ endpoint: String) -> Bool {
        unsupportedEndpoints.contains(endpoint)
    }

    /// Records the endpoint and reports whether this was the FIRST time.
    /// The caller logs only on `true`, which is what keeps one clear line
    /// per host out of one line per turn.
    @discardableResult
    func recordUnsupported(_ endpoint: String) -> Bool {
        unsupportedEndpoints.insert(endpoint).inserted
    }

    func forget(_ endpoint: String) { unsupportedEndpoints.remove(endpoint) }
    func reset() { unsupportedEndpoints.removeAll() }
}
