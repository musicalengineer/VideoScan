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
        // A reply whose only sentence opened with a bare surname is dropped
        // whole by the verifier (`.bareSurnameOpening`), but the plan's own
        // lead sentence can stand in for it — that is the same repair
        // `restoringSubjectAndLifeDates` makes when the opening survives
        // unnamed. Fall back to the template only when neither applies.
        guard !verification.kept.isEmpty
                || Self.subjectLeadCanStandIn(for: verification, plan: plan) else {
            return .template(plan, note: "template: no sentence survived verification")
        }
        var notes: [String] = []
        let counted = Self.restoringCountSentence(verification, plan: plan)
        if counted.kept.count != verification.kept.count { notes.append("count sentence restored") }
        let restored = Self.restoringSubjectAndLifeDates(counted, plan: plan, notes: &notes)
        return Outcome(
            displayText: restored.displayText,
            transcriptText: restored.transcriptText,
            composedBy: .model,
            dropped: restored.dropped,
            note: notes.isEmpty ? "model" : "model (\(notes.joined(separator: "; ")))")
    }

    /// A biography or kinship answer must open with the subject's full name
    /// and must keep the subject's life dates. Live 2026-08-26: "tell me
    /// about richard harding breen sr" → "He was the son of George Breen and
    /// Muriel Lamb …" — the name never appeared and the verifier had dropped
    /// the dates sentence; earlier "Mc Gill is the great-great-grandfather …"
    /// opened with a mangled bare surname.
    ///
    /// Two deterministic repairs, both drawn only from the plan:
    ///   1. Every life-dates claim no kept sentence cites is re-inserted
    ///      verbatim (tagged) at the front. Facts are ground truth; only the
    ///      model's wording of them was untrusted.
    ///   2. If the first sentence still does not name the subject in full, the
    ///      plan's lead sentence (`subjectLeadSentence`) goes in front. When the
    ///      model's opening cited nothing beyond what the lead carries it is
    ///      replaced (dropped as `.subjectNotNamed`); otherwise it is kept
    ///      behind the lead, where "He …" now has an antecedent.
    /// List answers are untouched; they have no subject to name.
    static func restoringSubjectAndLifeDates(
        _ verification: HallieCompositionVerifier.Verification,
        plan: HallieAnswerPlan,
        notes: inout [String]
    ) -> HallieCompositionVerifier.Verification {
        guard plan.shape == .biography || plan.shape == .fact,
              let subject = plan.subject, !subject.isEmpty else { return verification }
        // The verifier may already have removed the bare-surname opening
        // (`.bareSurnameOpening`, 4c801a4a). When that emptied the answer the
        // lead sentence still has to go in — otherwise the whole reply is
        // lost to the template. Whichever rule fired first keeps its reason.
        let openingAlreadyDropped = verification.kept.isEmpty
            && verification.dropped.contains { $0.reason == .bareSurnameOpening }
        guard !verification.kept.isEmpty || openingAlreadyDropped else { return verification }
        typealias Sentence = HallieCompositionVerifier.Sentence
        var kept = verification.kept
        var dropped = verification.dropped

        let cited = Set(kept.flatMap(\.claimIDs))
        let missingDates = plan.lifeDatesClaims.filter { !cited.contains($0.id) }
        if !missingDates.isEmpty {
            let restored = missingDates.map {
                Sentence(display: $0.text, tagged: $0.text + " [\($0.id)]", claimIDs: [$0.id])
            }
            kept = restored + kept
            notes.append("life dates restored: \(missingDates.map(\.id).joined(separator: ","))")
        }

        let firstNamesSubject = kept.first.map { HallieAnswerPlan.names(subject, in: $0.display) } ?? false
        if !firstNamesSubject, let lead = plan.subjectLeadSentence {
            let leadSentence = Sentence(
                display: lead.text,
                tagged: lead.claimIDs.isEmpty
                    ? lead.text + " [template]"
                    : lead.text + " [\(lead.claimIDs.joined(separator: "]["))]",
                claimIDs: lead.claimIDs)
            if let first = kept.first {
                let redundant = !first.claimIDs.isEmpty
                    && Set(first.claimIDs).isSubset(of: Set(lead.claimIDs))
                if redundant {
                    dropped.append(.init(text: first.tagged, reason: .subjectNotNamed))
                    kept.removeFirst()
                    notes.append("opening replaced by subject lead")
                } else {
                    notes.append("subject lead prepended")
                }
            } else {
                // Nothing kept: the verifier already dropped the opening.
                notes.append("opening replaced by subject lead")
            }
            kept.insert(leadSentence, at: 0)
        } else if openingAlreadyDropped, !kept.isEmpty {
            // Life dates alone re-opened the answer with the subject's name.
            notes.append("opening replaced by subject lead")
        }
        return HallieCompositionVerifier.Verification(kept: kept, dropped: dropped)
    }

    /// True when the verifier kept nothing but dropped a bare-surname
    /// opening that `restoringSubjectAndLifeDates` can replace with the
    /// plan's subject lead (biography/kinship shapes with a subject only).
    static func subjectLeadCanStandIn(
        for verification: HallieCompositionVerifier.Verification,
        plan: HallieAnswerPlan
    ) -> Bool {
        guard plan.shape == .biography || plan.shape == .fact,
              let subject = plan.subject, !subject.isEmpty,
              verification.kept.isEmpty,
              verification.dropped.contains(where: { $0.reason == .bareSurnameOpening })
        else { return false }
        return plan.subjectLeadSentence != nil
            || !plan.lifeDatesClaims.isEmpty
    }

    /// One app-log line per dropped sentence, so a "dropped 1" in the
    /// transcript summary can always be traced to which claim and why.
    /// Format: `[hallie-phrase] dropped: <claim ids> — reason: <reason> — "<text>"`,
    /// truncated to 200 characters.
    static let droppedLogLineLimit = 200

    static func droppedLogLines(
        _ dropped: [HallieCompositionVerifier.Dropped],
        plan: HallieAnswerPlan
    ) -> [String] {
        dropped.map { item in
            let ids = HallieCompositionVerifier.claimTags(in: item.text)
            let line = "[hallie-phrase] dropped: \(plan.describeClaimIDs(ids)) — reason: "
                + "\(item.reason.rawValue) — \"\(item.text)\""
            guard line.count > droppedLogLineLimit else { return line }
            return String(line.prefix(droppedLogLineLimit - 1)) + "…"
        }
    }

    /// A list answer must say how many. The model sometimes phrases only
    /// the examples ("Two examples are Clip 01.dv and MyGirl.mov") and the
    /// verifier, which only removes, cannot notice what is MISSING — so
    /// "How many videos include Donna?" came back without a number (codex
    /// corpus, 2026-08-21). When no kept sentence rests on the count claim
    /// c1, the template's own count sentence is put back in front,
    /// tagged, exactly as a claim. Nothing is invented: c1 is the plan.
    static func restoringCountSentence(
        _ verification: HallieCompositionVerifier.Verification,
        plan: HallieAnswerPlan
    ) -> HallieCompositionVerifier.Verification {
        guard plan.shape == .list,
              let count = plan.claims.first, count.id == "c1",
              !verification.kept.contains(where: { $0.claimIDs.contains("c1") }) else {
            return verification
        }
        let sentence = HallieCompositionVerifier.Sentence(
            display: count.text, tagged: count.text + " [c1]", claimIDs: ["c1"])
        return HallieCompositionVerifier.Verification(
            kept: [sentence] + verification.kept, dropped: verification.dropped)
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
        - Answer ONLY the current question from the claims below. Never restate, \
        summarize, or refer back to earlier turns — the recent conversation is \
        there for context (who "he" or "there" means), never as material to \
        repeat.
        - Never say you lack evidence or don't know: you are only asked to \
        phrase claims that are already established.
        - Call files by their names (e.g. "Cape_1993.mov"); never write \
        "Item 1" or "claim 2" — those are labels for you, not for the reader.
        - Speak about the family plainly, the way a person would: prefer "there \
        are 21 clips of Donna at the Cape" over "I found 21 catalog items \
        matching that".
        - A claim marked (as told by NAME) is that person's own account: voice \
        it as attributed testimony — "According to NAME, …" or "NAME \
        remembers …" — never as bare fact. When such an account describes a \
        person's character or appearance, include one warm sentence of it in a \
        biography; families want their people described, not just dated.
        - When a Subject is given, your FIRST sentence must state the subject's \
        full name exactly as written in Subject. Never open with "He", "She", \
        "They", or a surname alone.
        - Keep the subject's birth and death dates and birthplace from the \
        claims; they are the facts the reader wants first.
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
        if plan.shape == .list {
            lines.append("The items are shown to the reader as a list under your answer, "
                         + "so do not enumerate them; give the count and mention at most "
                         + "two by name.")
        }
        if !plan.counts.isEmpty {
            lines.append("Numbers: " + plan.counts.map { "\($0.label) = \($0.value)" }
                .joined(separator: "; "))
        }
        lines.append("Approved claims:")
        for claim in plan.claims {
            if let teller = claim.attribution {
                lines.append("[\(claim.id)] (as told by \(teller)) \(claim.text)")
            } else {
                lines.append("[\(claim.id)] \(claim.text)")
            }
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
