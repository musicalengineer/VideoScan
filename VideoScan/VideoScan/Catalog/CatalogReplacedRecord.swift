// CatalogReplacedRecord.swift
// What happens to the record a job's output REPLACES at its path (cutover
// B2.4, codex B2.3 finding "placeRecord purges a replaced row's curation").
// One sentence: a job's output never takes a person's stars, notes, tags,
// people, date, place, attestations or music out of the catalog.
//
//   same whole-file digest (the same bytes) → the new record INHERITS every
//     curated value it lacks; where both hold a different value the new
//     one (the job just copied it from the live source) is kept and the old
//     one is named in the log — it also stays in `row_knowledge`. Then the
//     old id is purged: the bytes, and now the curation, live on in the
//     new row;
//   different or unknown digest (Balance Audio's fresh probe, a Repair) →
//     the old record is KEPT: removed from the catalog with reason
//     `replacedAtPath` (a disk fact — the file at that path is no longer
//     those bytes), its curated values intact, and one log line names them.
//
// (For Rick: the copy-constructor half of "replace at key" — move the
// user's annotations to the new element when it is provably the same
// content; otherwise archive the old element instead of destroying it.)

import Foundation
import VideoScanCore

@MainActor
enum CatalogReplacedRecord {

    /// Both records name a whole-file digest, and it is the same.
    static func sameContent(_ old: VideoRecord, _ new: VideoRecord) -> Bool {
        guard let was = CatalogCommit.digest(of: old), let now = CatalogCommit.digest(of: new) else { return false }
        return was == now
    }

    /// `heir` takes every curated value it lacks from `old`. Returns the
    /// words for the groups where both held DIFFERENT values (heir's kept).
    @discardableResult
    static func inherit(from old: VideoRecord, onto heir: VideoRecord) -> [String] {
        let blank = CatalogSharedCurated(VideoRecord())
        let was = CatalogSharedCurated(old)
        let now = CatalogSharedCurated(heir)
        var differing: [String] = []
        for group in CatalogSharedCurated.Group.allCases where !was.same(group, as: blank) {
            if now.same(group, as: blank) {
                was.apply(group, to: heir)
            } else if !now.same(group, as: was) {
                differing.append(contentsOf: words(for: [group], of: old))
            }
        }
        if heir.setAsideReason == nil { heir.setAsideReason = old.setAsideReason }
        return differing
    }

    /// "stars 2, notes 'the lake house', tags Gold" — the curated values
    /// `record` carries, in the person's words; "no curated values" when none.
    static func describe(_ record: VideoRecord) -> String {
        let blank = CatalogSharedCurated(VideoRecord())
        let mine = CatalogSharedCurated(record)
        let groups = CatalogSharedCurated.Group.allCases.filter { !mine.same($0, as: blank) }
        let words = words(for: groups, of: record)
        return words.isEmpty ? "no curated values" : words.joined(separator: ", ")
    }

    private static func words(for groups: [CatalogSharedCurated.Group], of r: VideoRecord) -> [String] {
        groups.map { group in
            switch group {
            case .stars: return "stars \(r.starRating)"
            case .notes: return "notes '\(r.userNotes)'"
            case .disposition: return "disposition \(r.mediaDisposition.rawValue)"
            case .tags: return "tags " + r.tags.joined(separator: " · ")
            case .people: return "people " + (r.confirmedByUserPeople.map(\.name) + r.rejectedPeople.map { "not \($0)" }).joined(separator: " · ")
            case .date: return "date \(r.userDate ?? "?")"
            case .place: return "place \(r.userPlace ?? "?")"
            case .attestations: return "\(r.backupAttestations.count) backup attestation(s)"
            case .music: return "family music"
            }
        }
    }
}
