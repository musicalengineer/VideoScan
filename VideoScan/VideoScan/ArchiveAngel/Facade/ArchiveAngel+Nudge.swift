// ArchiveAngel+Nudge.swift
// The Archive tab's nudge ("It looks like N files are ready to be archived")
// as a reader of the ONE recommendation classifier (Consolidation S3a).
// ArchiveNudge.assess stays as the reference the parity test compares
// against; the view no longer calls it. S4 removes both with the Helper UI.

import Foundation
import OSLog
import VideoScanCore

private let nudgeLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "archiveAngel")

extension ArchiveAngel {

    /// The nudge over `records` under `rules` (default: the legacy nudge
    /// rules — exactly what ArchiveNudge.assess answers). Main actor: the
    /// records are read here, once; the classification is pure. Called by
    /// the Archive tab's memo once per catalog version, never per render.
    static func nudge(for records: [VideoRecord],
                      rules: AngelRecommendRules = .legacyNudge,
                      now: Date = Date()) -> ArchiveNudge {
        nudgeLog.info("nudge START — \(records.count) record(s)")
        let candidates = records.map { ArchiveAngelCandidate(recommendationFactsOf: $0) }
        let result = ArchiveAngelRecommendations.classify(candidates, rules: rules, now: now)
        let nudge = ArchiveNudge(recommendations: result)
        nudgeLog.info("nudge done — \(nudge.ready.count) ready, \(nudge.nearReady.count) need a date")
        return nudge
    }
}

extension ArchiveNudge {

    /// The nudge's two lists from a classifier result: Ready → ready,
    /// Needs a date → nearly ready, in the classifier's order.
    init(recommendations r: ArchiveAngelRecommendations.Result) {
        func row(_ e: ArchiveAngelRecommendations.Entry, needsDate: Bool) -> Candidate {
            Candidate(id: e.id, filename: e.filename, year: needsDate ? nil : e.year,
                      reasons: e.reasons, needsDate: needsDate, score: e.points)
        }
        self.init(ready: r.ready.map { row($0, needsDate: false) },
                  nearReady: r.needsDate.map { row($0, needsDate: true) })
    }
}
