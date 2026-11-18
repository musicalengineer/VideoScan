// ArchiveAngelBalancedProof.swift
// Prepare's last stage, REPORT ONLY (2026-11-18; DECISIONS 2026-11-17: "Nothing
// may trash or delete on the proof's word until the next slice has had the dry
// run on real pairs and its own Codex review"). Workflow, in Rick's words:
// "every balanced copy Prepare makes should be proven and the verdict recorded,
// while the proof DECIDES NOTHING".
//
// After every row of the batch is prepared, each balanced copy THIS batch made
// is handed, with its original, to `BalancedCopyProof.measure`. The engine's
// own START and OUTCOME lines go through the job's one log verb, and one plain
// line is kept on the row (`ArchiveAngelPlan.Entry.balancedCopyProof`, in the
// batch's plan.json) for the review sheet. Nothing else changes: readiness,
// what Promote takes, the Angel's holds, the gates and every Trash offer read
// none of it (ArchiveAngelBalancedProofSensorTests pins that from the source;
// ArchiveAngelBalancedProofTests pins it by running each outcome).
//
// What is NOT proven here: a balanced copy Prepare REUSED (an existing linked
// `_balanced` file elsewhere) — it was not made by this batch, may sit on
// another drive, and reading it is a separate decision.
//
// Shape: pure helpers on an empty enum (≈ a C++ namespace of free functions);
// the loop that runs them lives in ArchiveAngelJob (it owns the plan, the log
// verb and Stop).
//
// Memory: one note per row — two lines capped at `lineLimit` /
// `detailLimit` characters (≈ 5 KB a row, ≤ 50 rows a batch ≈ 250 KB worst
// case in plan.json). The proof's own bound (under 4 MiB) is in
// BalancedCopyProofMeasure.swift.

import Foundation
import VideoScanCore

extension ArchiveAngelPlan {

    /// What the balanced-copy proof said about one row's balanced copy —
    /// shown in Review, read by NOTHING that decides. Plain strings only, so
    /// an older build reading a newer plan.json can never fail on an unknown
    /// enum word (synthesized Codable throws on one).
    struct BalancedProofNote: Codable, Sendable, Equatable {
        /// "proven the same" · "same content" · "not proven" · "could not check".
        var verdict: String
        /// The one Review line ("Balanced copy: same content — differs in: …").
        var line: String
        /// Every named difference, one sentence each, " | " between; "" when none.
        var detail: String
        var checkedAt: Date
    }
}

enum ArchiveAngelBalancedProof {

    /// The two files one proof reads.
    struct Pair: Sendable, Equatable {
        var original: String
        var balanced: String
    }

    /// The proof, as the job calls it. Production: the engine. Tests inject
    /// one outcome, a throw, a hang (Stop) or missing tools.
    typealias Prover = @Sendable (_ original: String, _ balanced: String) async throws -> BalancedCopyProof.Outcome

    static let engine: Prover = { original, balanced in
        await BalancedCopyProof.measure(original: original, balanced: balanced)
    }

    /// Caps on the kept strings (plan.json stays bounded whatever a tool printed).
    static let lineLimit = 600
    static let detailLimit = 4000

    /// The files to prove for one row: a READY row whose Balance Audio step
    /// MADE a copy in this batch (done, with an output in the buffer). nil
    /// otherwise — no balance, a failed or skipped one, or a reused copy
    /// (`existingPath`, no output of this batch).
    static func pair(for entry: ArchiveAngelPlan.Entry, batchDir: String) -> Pair? {
        guard entry.status == .ready else { return nil }
        let step = entry.step(.balanceAudio)
        guard step.state == .done, let rel = step.outputRelPath, !rel.isEmpty else { return nil }
        let balanced = rel.hasPrefix("/") ? rel : URL(fileURLWithPath: batchDir).appendingPathComponent(rel).path
        return Pair(original: entry.sourcePath, balanced: balanced)
    }

    /// Every row to prove, in plan order. O(entries).
    static func work(in plan: ArchiveAngelPlan) -> [(id: UUID, filename: String, pair: Pair)] {
        plan.entries.compactMap { e in pair(for: e, batchDir: plan.batchDir).map { (e.id, e.filename, $0) } }
    }

    /// Run `prover` on `pair` off the main actor. Never throws: a throw is
    /// "could not check" with its words, and a check that was stopped proves
    /// nothing whatever the prover returned (the engine's own rule).
    #if compiler(>=6.2)
    @concurrent
    #endif
    static func outcome(of pair: Pair, by prover: Prover) async -> BalancedCopyProof.Outcome {
        let outcome: BalancedCopyProof.Outcome
        do {
            outcome = try await prover(pair.original, pair.balanced)
        } catch is CancellationError {
            return .couldNotCheck("the check was stopped")
        } catch {
            return .couldNotCheck("the check failed: \(error.localizedDescription)")
        }
        return Task.isCancelled ? .couldNotCheck("the check was stopped") : outcome
    }

    /// The row's note for an outcome. Pure.
    static func note(for outcome: BalancedCopyProof.Outcome, at when: Date = Date()) -> ArchiveAngelPlan.BalancedProofNote {
        let verdict: String, line: String
        var detail = ""
        switch outcome {
        case .proven:
            verdict = "proven the same"
            line = "Balanced copy: proven the same"
        case .sameContent(_, let differs):
            var kinds: [String] = []
            for d in differs where !kinds.contains(d.kind.rawValue) { kinds.append(d.kind.rawValue) }
            verdict = "same content"
            line = "Balanced copy: same content — differs in: " + kinds.joined(separator: ", ")
            detail = differs.map(BalancedCopyProof.sentence).joined(separator: " | ")
        case .notProven(let why):
            verdict = "not proven"
            line = "Balanced copy: not proven: " + why.message
        case .couldNotCheck(let reason):
            verdict = "could not check"
            line = "Balanced copy: could not check: " + reason
        }
        return .init(verdict: verdict, line: capped(line, lineLimit), detail: capped(detail, detailLimit), checkedAt: when)
    }

    /// One line of at most `limit` characters, with "…" when cut.
    static func capped(_ text: String, _ limit: Int) -> String {
        let one = BalancedCopyProof.singleLine(text)
        return one.count <= limit ? one : String(one.prefix(limit - 1)) + "…"
    }

    /// Written once when the setting is off and there was something to prove.
    static func offLine(count: Int) -> String {
        "balanced copy proof: OFF — \(count) balanced cop\(count == 1 ? "y" : "ies") made by this batch not checked "
            + "(Archive Angel ▸ \(ArchiveAngelSettings.proveBalancedCopiesTitle) is off); nothing else changes"
    }

    /// The progress line while one proof runs.
    static func progressLine(position: Int, of total: Int, filename: String) -> String {
        "Proving balanced copy \(position) of \(total) — \(filename) (report only; reads both files in full)"
    }
}
