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
        /// How strongly the catalog vouches (Important 3, each star 1,
        /// stage Ready 2 / Master 1) — orders the list and picks the copy.
        let score: Int
    }

    let ready: [Candidate]
    let nearReady: [Candidate]

    static let empty = ArchiveNudge(ready: [], nearReady: [])
    /// A nudge, not an inventory: the few most likely to be ready.
    static let listLimit = 15

    var isEmpty: Bool { ready.isEmpty && nearReady.isEmpty }

    /// The rows the panel shows — ready first (strongest vouching first),
    /// then the nearly-ready to fill up to the limit. Never the whole list.
    var shortlist: [Candidate] {
        Array((ready + nearReady).prefix(Self.listLimit))
    }

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

    /// Build from the not-yet-archived assets. One entry per recording:
    /// copies of the same content (a duplicate group) collapse to the
    /// chosen keeper, or — when no keeper was chosen yet — to the
    /// best-vouched copy, so the list never nags about the same tape
    /// three times (Rick 2026-08-21: "filter out all the copies").
    static func assess(_ records: [VideoRecord]) -> ArchiveNudge {
        // Strongest vouching first, then name — stable and explainable.
        // Strongest vouching first; among equals the OLDER recording first
        // (the heritage tapes are the point of the archive, and the
        // 2026 fixtures should not crowd out Cape Cod 1993); then name.
        let order: (Candidate, Candidate) -> Bool = { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.year != b.year { return (a.year ?? .max) < (b.year ?? .max) }
            return a.filename.localizedStandardCompare(b.filename) == .orderedAscending
        }
        var singles: [Candidate] = []
        // Files with no dup group yet can still be the same tape under a
        // camera's default name on four cards ("00000.MTS" ×4): same
        // name and same length is treated as one recording here.
        var byGroup: [String: (keeper: Candidate?, best: Candidate?, copies: Int)] = [:]
        for rec in records {
            guard let candidate = candidate(rec) else { continue }
            let key: String
            if let group = rec.duplicateGroupID, rec.duplicateGroupCount > 1 {
                key = "group:" + group.uuidString
            } else if !rec.filename.isEmpty, rec.durationSeconds > 0 {
                key = "name:\(rec.filename.lowercased())|\(Int(rec.durationSeconds.rounded()))"
            } else {
                singles.append(candidate)
                continue
            }
            var entry = byGroup[key] ?? (nil, nil, 0)
            entry.copies += 1
            if rec.duplicateDisposition == .keep, entry.keeper == nil {
                entry.keeper = candidate
            }
            if entry.best.map({ order(candidate, $0) }) ?? true { entry.best = candidate }
            byGroup[key] = entry
        }
        var all = singles
        for entry in byGroup.values {
            guard let chosen = entry.keeper ?? entry.best else { continue }
            all.append(Candidate(id: chosen.id, filename: chosen.filename, year: chosen.year,
                                 reasons: chosen.reasons
                                    + (entry.copies > 1 ? ["\(entry.copies) copies — this one"] : []),
                                 needsDate: chosen.needsDate, score: chosen.score))
        }
        let ready = all.filter { !$0.needsDate }.sorted(by: order)
        let near = all.filter { $0.needsDate }.sorted(by: order)
        return ArchiveNudge(ready: ready, nearReady: near)
    }

    static func candidate(_ rec: VideoRecord) -> Candidate? {
        guard rec.duplicateDisposition != .extraCopy else { return nil }
        switch rec.mediaDisposition {
        case .suspectedJunk, .confirmedJunk: return nil
        default: break
        }
        guard rec.junkScore < 50 else { return nil }

        var reasons: [String] = []
        var score = 0
        if rec.mediaDisposition == .important { reasons.append("marked Important"); score += 3 }
        if rec.starRating >= 2 { reasons.append(String(repeating: "★", count: rec.starRating)); score += rec.starRating }
        if rec.archiveStage == .readyForArchive { reasons.append("stage: Ready"); score += 2 }
        else if rec.archiveStage == .masterAssigned { reasons.append("stage: Master"); score += 1 }
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
                         reasons: reasons, needsDate: needsDate, score: score)
    }
}
