// PersonFinderModel+Identity.swift
// Identity-plausibility annotation for person-finder results.
//
// Bridges three things that live in different places:
//   • the POI's identity priors (birthdate/deathdate/sex/hair/eyes,
//     stored on POIProfile — see PersonFinderTypes.swift),
//   • the catalog's per-file dossier evidence (inferred record date +
//     VLM scene captions, fetched via the identityEvidenceProvider
//     closure wired in ContentView),
//   • the pure scoring core pfIdentityCandidates (IdentityNarrowing.swift).
//
// The annotate pass runs on the MainActor AFTER a job's results are
// finalized — never in a view body (GH #104 rule). Cost per call: one
// batch catalog lookup + a few string scans per matched row; matched
// rows are typically tens-to-hundreds, so this is sub-millisecond
// per row. Worst-case memory: one [String: PFIdentityEvidence] dict
// holding a handful of caption strings per matched row — bounded by
// the results table size, not the catalog.

import Foundation
import os

private let identityLog = Logger(
    subsystem: "Rick-Breen.VideoScan",
    category: "identity"
)

/// Per-file evidence the catalog hands back for identity narrowing.
struct PFIdentityEvidence {
    /// `VideoRecord.inferredRecordDate` — pfInferRecordDate's output.
    let recordDate: Date?
    /// The VLM scene captions' text, in caption order.
    let sceneDescriptions: [String]
}

/// One path's plausibility verdict, computed off-main and merged back
/// into ClipResult rows on the MainActor.
struct PFPlausibilityScore: Sendable {
    let plausibility: Float?
    let reason: String?
}

extension PersonFinderModel {

    /// Compute and cache identity plausibility on every result row of
    /// `job`. Idempotent — safe to call again after results are replaced
    /// (e.g. post-compilation republish). Skips gracefully when:
    ///   • no evidence provider is wired yet (annotated later via the
    ///     provider's didSet),
    ///   • the job has no assigned POI, or the POI has no priors set,
    ///   • a file has no inferred date — that row gets a neutral
    ///     "no evidence" reason instead of a score.
    ///
    /// TWO-PHASE (perf-review fix 2026-07-09): scoring costs ~0.1 ms/row
    /// even after the IdentityNarrowing fast paths, and the provider
    /// didSet can burst 10 restored jobs at launch — done synchronously
    /// that froze the MainActor for seconds. Now:
    ///   Phase 1 (MainActor, sync): snapshot paths + evidence + prior —
    ///     all value types — and bump the job's annotation epoch.
    ///   Phase 2 (@concurrent): score off-main. REPO TRAP: `nonisolated
    ///     async` runs on the CALLER's actor in this codebase — the
    ///     helper MUST be @concurrent to actually leave the MainActor.
    ///   Phase 3 (MainActor): merge scores into job.results keyed by
    ///     videoPath with ONE assignment (single objectWillChange), and
    ///     only if no newer pass superseded this one (epoch check) — a
    ///     re-run/republish between phases can't get stale annotations
    ///     stomped over it.
    ///
    /// Callers (didSet sweep + lifecycle hooks) treat this fire-and-
    /// forget: the method returns before scores land and the Fit badges
    /// pop in a beat later. The returned Task is for tests/await-ers.
    @MainActor
    @discardableResult
    func annotateIdentityPlausibility(for job: ScanJob) -> Task<Void, Never>? {
        guard let provider = identityEvidenceProvider else { return nil }
        guard let profile = job.assignedProfile else { return nil }
        let prior = IdentityPrior(profile: profile)
        guard prior.hasAnySignal else { return nil }
        guard !job.results.isEmpty else { return nil }

        // Phase 1 — value snapshots only. ClipResult indices are NOT
        // captured: rows may be reordered/replaced while we're scoring,
        // so the merge below re-finds rows by videoPath.
        let paths = Set(job.results.map(\.videoPath))
        let evidence = provider(paths)
        job.identityAnnotationEpoch &+= 1
        let epoch = job.identityAnnotationEpoch
        let personName = profile.name

        // Task {} in a @MainActor context inherits the MainActor, so the
        // body below IS phase 3; only the @concurrent helper hops off.
        return Task { @MainActor [weak job] in
            let scores = await Self.pfScoreEvidenceOffMain(
                paths: paths, evidence: evidence, prior: prior
            )

            guard let job else { return }
            guard job.identityAnnotationEpoch == epoch else {
                identityLog.debug("Identity narrowing: pass for \(personName, privacy: .public) superseded mid-flight — dropping stale scores")
                return
            }
            // Merge by videoPath into a LOCAL copy, assign once (single
            // objectWillChange — commit 2930482's pattern). Rows added
            // after the snapshot have no entry and stay untouched.
            var annotated = job.results
            var scored = 0
            for i in annotated.indices {
                guard let s = scores[annotated[i].videoPath] else { continue }
                annotated[i].plausibility = s.plausibility
                annotated[i].plausibilityReason = s.reason
                if s.plausibility != nil { scored += 1 }
            }
            job.results = annotated
            identityLog.info("Identity narrowing: scored \(scored)/\(annotated.count) row(s) for \(personName, privacy: .public)")
        }
    }

    /// Phase 2 — pure scoring, off the MainActor. @concurrent (NOT
    /// `nonisolated async`, which would run on the caller's actor in
    /// this repo — see project_approachable_concurrency_trap).
    /// pfIdentityCandidates is nonisolated + pure, so the hop is clean;
    /// everything in and out is Sendable value types.
    @concurrent
    private static func pfScoreEvidenceOffMain(
        paths: Set<String>,
        evidence: [String: PFIdentityEvidence],
        prior: IdentityPrior
    ) async -> [String: PFPlausibilityScore] {
        var out: [String: PFPlausibilityScore] = [:]
        out.reserveCapacity(paths.count)
        for path in paths {
            guard let ev = evidence[path], let date = ev.recordDate else {
                // No triangulated date (or file not in catalog) — neutral,
                // visibly explained, never silently dropped.
                out[path] = PFPlausibilityScore(
                    plausibility: nil,
                    reason: "no date/scene evidence for this file"
                )
                continue
            }
            let candidates = pfIdentityCandidates(
                recordDate: date,
                sceneDescriptions: ev.sceneDescriptions,
                priors: [prior]
            )
            out[path] = PFPlausibilityScore(
                plausibility: candidates.first?.plausibility,
                reason: candidates.first?.reason
            )
        }
        return out
    }
}
