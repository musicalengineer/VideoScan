// FootageLikenessStore.swift
// The footage likeness catalog.sqlite holds (schema v1.11,
// `footage_likeness`), in memory, by content — for the inspector's "Same
// footage as (possible)" lines. Read when catalog.sqlite becomes the
// authority (CatalogAuthorityFlip) and again after a split records pairs.
// catalog.sqlite is the truth; this is a read-only projection of it — the
// one writer of the table is the split, through the session's committer.
//
// EVIDENCE ONLY: a pair is "the duplicate check found these two contents
// alike". It is never a decision and never delete eligibility — nothing on
// a delete path reads this type (SameFootageSensorTests). A person answers
// a pair with the existing footage decisions (same / notSame on the two
// files); "not the same" suppresses it, "same" makes it a footage link.
//
// Memory: two index entries per pair (~250 B each with their strings) —
// a few thousand pairs today, ~50 MB at 100k pairs. Replaced whole on a
// read; never grows without a read or a split behind it.
//
// (For Rick: a multimap content-hash → edges, rebuilt from the table; a
// `final class` because the model holds ONE and the views read it.)

import Foundation
import VideoScanCore

@MainActor
final class FootageLikenessStore {

    /// One pair, from one content's side.
    struct Pair: Sendable, Equatable {
        /// The OTHER content of the pair.
        var otherDigest: String
        var reasons: String
        /// 'weak' | 'anchored'.
        var strength: String
        /// 'duplicateCheck' | 'oldGroup'.
        var source: String

        var isWeak: Bool { strength == DuplicateGroupDigestSplit.LikenessPair.Strength.weak.rawValue }
    }

    private var byDigest: [String: [Pair]] = [:]
    /// Pairs held (each counted once).
    private(set) var count = 0
    /// Bumped on every change — a memo key, never observed by a body.
    private(set) var revision = 0

    /// The pairs `digest` is in (lowercase lookup); empty when none.
    func pairs(of digest: String) -> [Pair] { byDigest[digest.lowercased()] ?? [] }

    /// Replace everything with the rows read from catalog.sqlite.
    func replace(with rows: [CatalogRow.FootageLikeness]) {
        byDigest.removeAll(keepingCapacity: true)
        count = 0
        absorb(rows)
    }

    /// Add rows just recorded (a pair already held is not added twice).
    func absorb(_ rows: [CatalogRow.FootageLikeness]) {
        for row in rows {
            guard !(byDigest[row.digestA]?.contains { $0.otherDigest == row.digestB } ?? false) else { continue }
            byDigest[row.digestA, default: []].append(Pair(otherDigest: row.digestB, reasons: row.reasons,
                                                           strength: row.strength, source: row.source))
            byDigest[row.digestB, default: []].append(Pair(otherDigest: row.digestA, reasons: row.reasons,
                                                           strength: row.strength, source: row.source))
            count += 1
        }
        revision &+= 1
    }

    /// Read every pair from `repository` (off the main actor) and replace.
    /// nil = read; else the words why not (the store is left as it was).
    @discardableResult
    func load(from repository: any CatalogRepository) async -> String? {
        do {
            let rows = try await repository.read { reader -> [CatalogRow.FootageLikeness] in
                var out: [CatalogRow.FootageLikeness] = []
                try reader.footageLikenessReviews { out.append($0.likeness) }
                return out
            }
            replace(with: rows)
            return nil
        } catch {
            return String(describing: error)
        }
    }
}
