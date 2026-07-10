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

extension PersonFinderModel {

    /// Compute and cache identity plausibility on every result row of
    /// `job`. Idempotent — safe to call again after results are replaced
    /// (e.g. post-compilation republish). Skips gracefully when:
    ///   • no evidence provider is wired yet (annotated later via the
    ///     provider's didSet),
    ///   • the job has no assigned POI, or the POI has no priors set,
    ///   • a file has no inferred date — that row gets a neutral
    ///     "no evidence" reason instead of a score.
    @MainActor
    func annotateIdentityPlausibility(for job: ScanJob) {
        guard let provider = identityEvidenceProvider else { return }
        guard let profile = job.assignedProfile else { return }
        let prior = IdentityPrior(profile: profile)
        guard prior.hasAnySignal else { return }
        guard !job.results.isEmpty else { return }

        let paths = Set(job.results.map(\.videoPath))
        let evidence = provider(paths)

        var scored = 0
        for i in job.results.indices {
            let path = job.results[i].videoPath
            guard let ev = evidence[path], let date = ev.recordDate else {
                // No triangulated date (or file not in catalog) — neutral,
                // visibly explained, never silently dropped.
                job.results[i].plausibility = nil
                job.results[i].plausibilityReason = "no date/scene evidence for this file"
                continue
            }
            // pfIdentityCandidates is pure + synchronous — calling it here
            // on the MainActor is fine at results-table scale.
            let candidates = pfIdentityCandidates(
                recordDate: date,
                sceneDescriptions: ev.sceneDescriptions,
                priors: [prior]
            )
            job.results[i].plausibility = candidates.first?.plausibility
            job.results[i].plausibilityReason = candidates.first?.reason
            scored += 1
        }
        identityLog.info("Identity narrowing: scored \(scored)/\(job.results.count) row(s) for \(profile.name, privacy: .public)")
    }
}
