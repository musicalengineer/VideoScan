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
        let order = hosts.isEmpty ? [template.host] : hosts
        var attempts: [String] = []
        var lastError: Error = NLTranslatorError.unreachable("no hosts configured")

        for host in order {
            var attempt = template
            attempt.host = host
            do {
                let spec = try await attempt.translate(text)
                onResponder?(host)
                return spec
            } catch {
                attempts.append("\(host): \(Self.shortReason(error))")
                onAttemptFailed?(host, error)
                lastError = error

                // Stop the walk on anything that would fail identically
                // everywhere — see the header.
                if let nl = error as? NLTranslatorError, !nl.isRetryableOnAnotherHost {
                    throw nl
                }
                // Also stop if the caller cancelled: a cancelled task
                // must not keep dialling the rest of the fleet.
                if Task.isCancelled { throw CancellationError() }
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
