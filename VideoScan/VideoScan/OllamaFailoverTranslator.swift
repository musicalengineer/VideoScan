// OllamaFailoverTranslator.swift
// Try the Archivist's hosts in order until one answers (2026-08-12).
//
// Rick: the M5 is a laptop — "asleep, off premises, off battery" — and
// the Archivist hung whenever its brain went out of the house. The model
// now lives on the mains-powered M4, with the laptop as fallback. This
// type is the sequencing: walk `OllamaEndpoints.resolved(...)` in order,
// return the first real answer, and remember which host gave it.
//
// WHAT IT WILL AND WILL NOT RETRY. Only failures that are about a HOST
// justify moving to the next one: transport (asleep, off-network), 5xx,
// and model-unavailable. A `.badResponse` — the model replied with
// something unusable — is a property of the MODEL, and every host in the
// list runs the same model, so retrying would spend one timeout per host
// to collect the same garbage N times. See
// `NLTranslatorError.isRetryableOnAnotherHost`, which owns that call.
//
// WHAT IT REPORTS. `onResponder` fires with the host that actually
// answered. Without it a two-host fleet is indistinguishable from a
// one-host fleet right up until both are down, and "which machine
// answered me?" is exactly what Rick needs to know when the Archivist
// feels slow.
//
// TWO TIMEOUTS, NOT ONE. Each host is probed for liveness (3s) before
// being asked to generate (20s). codex flagged that a sleeping primary
// otherwise costs a full generation timeout per host before the fallback
// is reached — and that simply shrinking the one timeout would abort a
// HEALTHY M4 cold-loading a 21.9 GB model, reintroducing the very
// failure this file exists to prevent. Liveness is a round trip;
// generation is a computation; they deserve different budgets.
//
// Errors: if every host fails, the LAST error is thrown, with all the
// attempts summarized in its text — a bare "unreachable" naming only the
// final host would hide that the primary was asleep.

import Foundation

struct OllamaFailoverTranslator: NLQueryTranslating {

    /// Hosts to try, in order. Empty means the template's own host.
    var hosts: [String]

    /// Template carrying model, port, timeout, and transport. Its `host`
    /// is overridden per attempt.
    var template: OllamaQueryTranslator

    /// Called with the host that produced the answer.
    var onResponder: (@Sendable (String) -> Void)?

    /// Called for each failed host, so the console can show the walk
    /// rather than a silent pause while timeouts elapse.
    var onAttemptFailed: (@Sendable (String, Error) -> Void)?

    /// Probe each host's liveness before spending a generation timeout
    /// on it. ON by default — see the header. Disable only for a
    /// single-host setup where the extra round trip buys nothing.
    var probeBeforeRequest: Bool = true

    init(hosts: [String],
         template: OllamaQueryTranslator = OllamaQueryTranslator(),
         onResponder: (@Sendable (String) -> Void)? = nil,
         onAttemptFailed: (@Sendable (String, Error) -> Void)? = nil) {
        self.hosts = hosts
        self.template = template
        self.onResponder = onResponder
        self.onAttemptFailed = onAttemptFailed
    }

    var displayName: String {
        let first = hosts.first ?? template.host
        return hosts.count > 1
            ? "\(template.model) @ \(first) +\(hosts.count - 1)"
            : "\(template.model) @ \(first)"
    }

    func translate(_ text: String) async throws -> NLQuerySpec {
        try await walkHosts { attempt in
            try await attempt.translate(text)
        }
    }

    /// QueryAST-v2 uses the identical host order, probe, retry classifier,
    /// attempt reporting, and responder callback as the established v1 path.
    func translateAST(_ text: String) async throws -> ArchivistQueryAST {
        try await walkHosts { attempt in
            try await attempt.translateAST(text)
        }
    }

    private func walkHosts<Result>(
        _ request: (OllamaQueryTranslator) async throws -> Result
    ) async throws -> Result {
        let order = hosts.isEmpty ? [template.host] : hosts
        var attempts: [String] = []
        var lastError: Error = NLTranslatorError.unreachable("no hosts configured")

        for host in order {
            var attempt = template
            attempt.host = host

            // Liveness first. This is the whole answer to "an asleep
            // primary makes the app look hung": a dead host costs one
            // 3-second probe instead of a full 20-second generation
            // budget, while a LIVE but slow host — a cold 35B load — is
            // never cut off, because the probe passes and the long
            // timeout then applies to thinking only.
            if probeBeforeRequest, let down = await attempt.probeLiveness() {
                attempts.append("\(host): \(Self.shortReason(down))")
                onAttemptFailed?(host, down)
                lastError = down
                if Task.isCancelled { throw CancellationError() }
                continue
            }

            do {
                let spec = try await request(attempt)
                onResponder?(host)
                return spec
            } catch {
                attempts.append("\(host): \(Self.shortReason(error))")
                onAttemptFailed?(host, error)
                lastError = error

                // A cancelled task must not keep dialling the fleet.
                if error is CancellationError || Task.isCancelled {
                    throw CancellationError()
                }
                // Stop the walk on anything that would fail identically
                // everywhere — see the header.
                guard let nl = error as? NLTranslatorError else {
                    // UNCLASSIFIED errors do not fail over. An error we
                    // could not label is far more likely a bug in our own
                    // decoding than a sleeping machine, and spending one
                    // timeout per host to rediscover the same bug is the
                    // expensive wrong guess. Fail fast and loudly instead
                    // (defence in depth behind codex #315, which was
                    // exactly this hole: a raw DecodingError walking the
                    // whole fleet).
                    throw error
                }
                if !nl.isRetryableOnAnotherHost { throw nl }
            }
        }

        // Every host failed. Report the whole walk, not just the last leg.
        let summary = attempts.joined(separator: "; ")
        if let nl = lastError as? NLTranslatorError {
            switch nl {
            case .modelUnavailable:
                throw NLTranslatorError.modelUnavailable(summary)
            case .serverError(let status, _):
                throw NLTranslatorError.serverError(status: status, detail: summary)
            default:
                throw NLTranslatorError.unreachable(summary)
            }
        }
        throw NLTranslatorError.unreachable(summary)
    }

    private static func shortReason(_ error: Error) -> String {
        if let nl = error as? NLTranslatorError {
            switch nl {
            case .unreachable(let d): return "unreachable (\(d.prefix(60)))"
            case .serverError(let s, _): return "HTTP \(s)"
            case .modelUnavailable: return "model not loaded"
            case .badResponse(let d): return "bad response (\(d.prefix(60)))"
            }
        }
        return String(error.localizedDescription.prefix(60))
    }
}
