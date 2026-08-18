// HallieGroundedComposer.swift
// Plan → phrase → verify. One optional local-model call that turns an
// approved HallieAnswerPlan into Hallie's own words, followed by the
// deterministic verifier that drops anything the plan does not support.
// The model call is a closure so tests inject a fake and production wires
// the same Ollama transport the translator uses. On any failure — model
// down, slow, garbage, every sentence dropped — the plan's fallback text is
// used and the answer is never delayed past the budget.

import Foundation
import os

private let composerLog = Logger(subsystem: "Rick-Breen.VideoScan",
                                 category: "HallieComposer")

/// Who wrote the displayed prose. Recorded on the Result and in the
/// transcript log so a bubble can always be traced to template or model.
enum HallieComposedBy: String, Sendable, Equatable {
    case template
    case model
}

/// The user setting behind "Let Hallie phrase answers in her own words".
enum HallieCompositionSettings {
    static let key = "archivist.composeWithModel"

    /// Default ON: a local brain is what the app already starts for
    /// translation, so phrasing rides on the same call path. The shell is
    /// OFF unless `--compose` because it is a diagnostic surface.
    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) == nil ? true : defaults.bool(forKey: key)
    }

    static func setEnabled(_ enabled: Bool, _ defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: key)
    }

    static let personaNameKey = "archivist.name"
    static let defaultPersonaName = "Hallie Mae"

    static func personaName(_ defaults: UserDefaults = .standard) -> String {
        let stored = defaults.string(forKey: personaNameKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? defaultPersonaName : stored
    }
}

struct HallieGroundedComposer: Sendable {

    /// (system prompt, user prompt) → plain text. Throws for transport /
    /// model failure. Production: `OllamaFailoverTranslator.composePlainText`.
    typealias ModelCall = @Sendable (_ system: String, _ user: String) async throws -> String

    /// One prior exchange shown to the composer for continuity. Text only —
    /// exactly what the user typed and what Hallie displayed; no hidden facts.
    struct HistoryTurn: Sendable, Equatable {
        let user: String
        let assistant: String
    }

    struct Outcome: Sendable, Equatable {
        /// What the bubble / shell shows (tags stripped).
        let displayText: String
        /// What the transcript log records (tags kept when the model wrote it).
        let transcriptText: String
        let composedBy: HallieComposedBy
        let dropped: [HallieCompositionVerifier.Dropped]
        /// One-line diagnostic: "model" or why the template was used.
        let note: String

        static func template(_ plan: HallieAnswerPlan, note: String) -> Outcome {
            Outcome(displayText: plan.fallbackText,
                    transcriptText: plan.fallbackText,
                    composedBy: .template,
                    dropped: [],
                    note: note)
        }
    }

    var personaName: String
    var modelCall: ModelCall
    /// Wall-clock budget for the whole phrasing step. Past it, the template
    /// answer ships and the model call is cancelled — a slow brain must never
    /// delay a ready answer.
    var timeoutSeconds: Double = 6
    /// Prior turns offered to the model (most recent last).
    static let historyTurns = 3

    init(personaName: String, timeoutSeconds: Double = 6, modelCall: @escaping ModelCall) {
        self.personaName = personaName
        self.timeoutSeconds = timeoutSeconds
        self.modelCall = modelCall
    }

    /// Phrase the plan, verify, and decide. Never throws; never exceeds the
    /// budget by more than scheduling jitter.
    func compose(
        plan: HallieAnswerPlan,
        history: [HistoryTurn]
    ) async -> Outcome {
        guard plan.isComposable else {
            return .template(plan, note: "template: fixed route")
        }
        let system = Self.systemPrompt(personaName: personaName)
        let user = Self.userPrompt(plan: plan, history: history)
        let raw: String
        do {
            raw = try await withTimeout(seconds: timeoutSeconds) {
                try await modelCall(system, user)
            }
        } catch is TimeoutError {
            composerLog.notice("compose timeout after \(self.timeoutSeconds, privacy: .public)s; template used")
            return .template(plan, note: "template: model timeout")
        } catch {
            composerLog.notice("compose failed: \(error.localizedDescription, privacy: .public); template used")
            return .template(plan, note: "template: model error")
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .template(plan, note: "template: empty model reply")
        }
        let verification = HallieCompositionVerifier.verify(
            trimmed, plan: plan, personaName: personaName)
        if !verification.dropped.isEmpty {
            let reasons = verification.dropped.map(\.reason.rawValue).joined(separator: ",")
            composerLog.notice("verifier dropped \(verification.dropped.count, privacy: .public) sentence(s): \(reasons, privacy: .public)")
        }
        guard !verification.kept.isEmpty else {
            return .template(plan, note: "template: no sentence survived verification")
        }
        return Outcome(
            displayText: verification.displayText,
            transcriptText: verification.transcriptText,
            composedBy: .model,
            dropped: verification.dropped,
            note: "model")
    }

    // MARK: - Prompts

    /// The persona and the hard rules. `personaName` is the only identity
    /// baked in; the family facts arrive solely in the user prompt's claims.
    static func systemPrompt(personaName: String) -> String {
        """
        You are \(personaName), the family archivist. Warm, brief, plain words, \
        no flourish; you are talking to an older reader who wants a straight \
        answer. You are given an approved list of numbered claims about this \
        family and a short recent conversation. Phrase those claims in your own \
        voice.

        HARD RULES:
        - Use ONLY the given claims. Never add a date, name, place, number, \
        relationship, or event that is not in a claim.
        - Every sentence must end with the claim IDs it rests on, in square \
        brackets, like [c1] or [c2][c3]. A sentence with no tag will be discarded.
        - Do not mention the IDs any other way; the bracket tags are enough.
        - If the claims say there is no evidence, say so plainly.
        - Keep it short: at most 3 sentences for a list of items, at most 6 for \
        a biography.
        - Plain text only. No headings, bullets, markdown, or preamble.
        """
    }

    static func userPrompt(plan: HallieAnswerPlan, history: [HistoryTurn]) -> String {
        var lines: [String] = []
        let recent = history.suffix(historyTurns)
        if !recent.isEmpty {
            lines.append("Recent conversation:")
            for turn in recent {
                lines.append("User: \(turn.user)")
                lines.append("You: \(turn.assistant)")
            }
            lines.append("")
        }
        if let subject = plan.subject, !subject.isEmpty {
            lines.append("Subject: \(subject)")
        }
        lines.append("Answer shape: \(plan.shape.rawValue) (at most \(plan.maxSentences) sentences)")
        if !plan.counts.isEmpty {
            lines.append("Numbers: " + plan.counts.map { "\($0.label) = \($0.value)" }
                .joined(separator: "; "))
        }
        lines.append("Approved claims:")
        for claim in plan.claims {
            lines.append("[\(claim.id)] \(claim.text)")
        }
        lines.append("")
        lines.append("Write the answer now, tagging every sentence with its claim IDs.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Timeout

    struct TimeoutError: Error {}

    /// Race the operation against a timer; the loser is cancelled. Swift's
    /// structured-concurrency equivalent of `std::future::wait_for` plus
    /// cancellation of the worker.
    private func withTimeout<T: Sendable>(
        seconds: Double,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                throw TimeoutError()
            }
            guard let first = try await group.next() else { throw TimeoutError() }
            group.cancelAll()
            return first
        }
    }
}
