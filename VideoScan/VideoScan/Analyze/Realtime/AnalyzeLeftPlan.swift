// AnalyzeLeftPlan.swift — "Analyze the N left" (Rick 2026-11-06, watching the
// Realtime Content Analysis window: "a button that says 'do another 88 files'
// … why wouldn't it just do those while I'm watching … one way or another,
// do them").
//
// What the button runs, from the coverage report the Content line reads —
// nothing new runs: each step is an AnalyzeRunner.runNow, the SAME entry point
// the Content Analysis panel's rows and Update use (rule 4). Every engine works
// only on its own unstamped files (the dossier batch skips what is analyzed or
// cannot be decoded — DossierPoolStatus, the rule the counts read), so the
// steps cover exactly the N files the Content line counts.
//
//   N      = the Content line's grey N (files with at least one counted
//            analysis left, else analyzer-file pairs for a report with no
//            per-file tally) — `CatalogStatusLinesPolicy.content` reads `files`.
//   steps  = each content analyzer with work left, registry order; the three
//            dossier stages are ONE engine, so they are one step per drive
//            that holds their work (a file under no scan target → one
//            catalog-wide step, as Update runs it).
//
// Pure value; O(analyzers + drives). (For Rick: a plan struct built from a
// snapshot, like a command list a C++ UI hands its worker.)

import Foundation

struct AnalyzeLeftPlan: Equatable, Sendable {

    struct Step: Equatable, Sendable {
        var cycler: AnalyzeCycler
        /// A scan-target root, or nil for the engine's catalog-wide run.
        var volume: String?
    }

    /// The number on the button — the Content line's N.
    var files = 0
    var steps: [Step] = []
    /// "Scene Captions 70 · Transcribe 10" — what is left, per analyzer.
    var breakdown = ""

    var isEmpty: Bool { files == 0 || steps.isEmpty }

    /// The engines a step starts (the store watches them to know when the run ends).
    var cyclers: Set<AnalyzeCycler> { Set(steps.map(\.cycler)) }

    static let dossierStages: [AnalyzeCycler] = [.sceneCaptions, .ocr, .transcribe]

    static func make(_ report: AnalyzeCoverageReport) -> AnalyzeLeftPlan {
        var plan = AnalyzeLeftPlan()
        guard report.computedAt.timeIntervalSince1970 > 0 else { return plan }
        let analyzers = AnalyzeCoverageReport.contentAnalyzers
        let pairs = analyzers.reduce(0) { $0 + report.counts($1).remaining }
        plan.files = report.contentFiles.remaining > 0 ? report.contentFiles.remaining : pairs
        guard plan.files > 0 else { return plan }
        plan.breakdown = analyzers.compactMap { c -> String? in
            let n = report.counts(c).remaining
            return n > 0 ? "\(c.title) \(n.formatted())" : nil
        }.joined(separator: " · ")

        var dossierDone = false
        for c in analyzers where report.counts(c).remaining > 0 {
            guard dossierStages.contains(c) else {
                plan.steps.append(Step(cycler: c, volume: nil))
                continue
            }
            guard !dossierDone else { continue }
            dossierDone = true
            plan.steps += dossierSteps(report)
        }
        return plan
    }

    /// One dossier step per drive holding dossier work; catalog-wide when
    /// some of it is under no scan target (no root to hand the engine).
    private static func dossierSteps(_ report: AnalyzeCoverageReport) -> [Step] {
        var roots = Set<String>()
        for c in dossierStages {
            for (root, k) in report.byVolume[c] ?? [:] where k.remaining > 0 { roots.insert(root) }
        }
        if roots.isEmpty || roots.contains(AnalyzeCoverageCalculator.otherRoot) {
            return [Step(cycler: .sceneCaptions, volume: nil)]
        }
        return roots.sorted().map { Step(cycler: .sceneCaptions, volume: $0) }
    }

    // MARK: Words (the button and its help; the truth test reads them)

    var buttonTitle: String {
        isEmpty ? "Nothing left to analyze" : "Analyze the \(files.formatted()) left"
    }

    var help: String {
        guard !isEmpty else {
            return "Nothing left to analyze on connected drives — the same count as Catalog Status ▸ Content"
        }
        return "Runs the analyzers with work left — \(breakdown) — through the same engines as Content Analysis "
            + "(\(files.formatted()) = Catalog Status ▸ Content's count). Pause and Stop work as usual."
    }
}
