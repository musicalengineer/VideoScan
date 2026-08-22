// ArchiveNudge.swift
// "It looks like 15 files are ready to be archived" — the gentle push under
// the progress bar (Rick 2026-08-21): files the catalog already knows are
// keepers, so promoting the next few is a choice, not a chore.
//
// A file is READY when every one of these is true:
//   • not archived yet, and not an extra copy of something (dup keeper or
//     unscored — never an "Extra copy");
//   • a human has vouched for it: marked Important, starred (2–3), or its
//     stage was set to Master / Ready;
//   • not junk (no junk disposition, low junk score);
//   • it has a date at least to the year (so it lands in the right place).
// NEAR-READY = the same, except the date is missing — one fact away.
//
// There is no "how often was it watched" signal in the catalog yet, so
// "frequently looked at" is not a criterion here; it is named in the
// docs as the obvious next signal.
//
// Pure: records in, a small list out. O(notYetArchived) once per records
// version (memoized by ArchiveView), never in body.

import Foundation
import VideoScanCore

struct ArchiveNudge: Equatable, Sendable {

    struct Candidate: Identifiable, Equatable, Sendable {
        let id: UUID
        let filename: String
        let year: Int?
        /// Why it qualifies, in the order a person would say it.
        let reasons: [String]
        let needsDate: Bool
    }

    let ready: [Candidate]
    let nearReady: [Candidate]

    static let empty = ArchiveNudge(ready: [], nearReady: [])
    static let listLimit = 25

    var isEmpty: Bool { ready.isEmpty && nearReady.isEmpty }

    /// Looser wording on purpose — it's a hunch from the catalog's own
    /// marks, not a verdict.
    var headline: String {
        switch (ready.count, nearReady.count) {
        case (0, 0):
            return "Nothing is waving its hand yet — star a keeper or mark it Important and it will show up here."
        case (let r, 0):
            return "It looks like \(r.formatted()) \(r == 1 ? "file is" : "files are") ready to be archived."
        case (0, let n):
            return "\(n.formatted()) \(n == 1 ? "keeper is" : "keepers are") nearly ready — \(n == 1 ? "it just needs" : "they just need") a date."
        case (let r, let n):
            return "It looks like \(r.formatted()) \(r == 1 ? "file is" : "files are") ready to be archived, and \(n.formatted()) more just need a date."
        }
    }

    /// Build from the not-yet-archived assets.
    static func assess(_ records: [VideoRecord]) -> ArchiveNudge {
        var ready: [Candidate] = []
        var near: [Candidate] = []
        for rec in records {
            guard let candidate = candidate(rec) else { continue }
            if candidate.needsDate { near.append(candidate) } else { ready.append(candidate) }
        }
        // Strongest vouching first, then name — stable and explainable.
        let order: (Candidate, Candidate) -> Bool = { a, b in
            if a.reasons.count != b.reasons.count { return a.reasons.count > b.reasons.count }
            return a.filename.localizedStandardCompare(b.filename) == .orderedAscending
        }
        return ArchiveNudge(ready: ready.sorted(by: order), nearReady: near.sorted(by: order))
    }

    static func candidate(_ rec: VideoRecord) -> Candidate? {
        guard rec.duplicateDisposition != .extraCopy else { return nil }
        switch rec.mediaDisposition {
        case .suspectedJunk, .confirmedJunk: return nil
        default: break
        }
        guard rec.junkScore < 50 else { return nil }

        var reasons: [String] = []
        if rec.mediaDisposition == .important { reasons.append("marked Important") }
        if rec.starRating >= 2 { reasons.append(String(repeating: "★", count: rec.starRating)) }
        if rec.archiveStage == .readyForArchive { reasons.append("stage: Ready") }
        else if rec.archiveStage == .masterAssigned { reasons.append("stage: Master") }
        if rec.duplicateDisposition == .keep { reasons.append("the copy to keep") }
        // Vouching is the gate; "the copy to keep" alone is not a reason to promote.
        let vouched = reasons.contains { $0 != "the copy to keep" }
        guard vouched else { return nil }

        let resolution = RecordDateResolver.resolve(
            userDate: rec.userDate,
            userDateConfidence: rec.userDateConfidence,
            embeddedCreationDate: rec.embeddedCreationDate,
            originMake: rec.originMake,
            originModel: rec.originModel,
            originEncoder: rec.originEncoder,
            inferredRecordDate: rec.inferredRecordDate,
            inferredDateConfidence: rec.inferredDateConfidence,
            filename: rec.filename.isEmpty ? nil : rec.filename)
        let needsDate = resolution.precision >= .decade
        let year = needsDate ? nil : resolution.year
        return Candidate(id: rec.id, filename: rec.filename, year: year,
                         reasons: reasons, needsDate: needsDate)
    }
}
