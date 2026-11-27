// NewContentFinder.swift (VideoScanCore/Provenance)
// Which files that came into the catalog are NEW MEDIA — content the catalog
// has never seen — once Fill In Full Hashes has given them a whole-file
// SHA-256 (DECISIONS 2026-11-27: "the post-scan notice fires when Fill In Full
// Hashes lands content the catalog has never seen (identity is whole-file
// SHA-256)").
//
// The candidates are the PENDING records: files a scan merge added as genuine
// strangers (not re-seen at their path, not a moved file that took its old
// record along) and files added by hand. A scan does not read files whole, so
// a pending record usually has no digest yet; it waits.
//
// A pending record WITH a digest is decided once:
//   * NEW when no other record of the catalog holds that digest, no other
//     record holds the same SAMPLED identity (segmented contentHash, else
//     partialMD5 + size) while lacking a digest of its own (an older copy
//     never fully hashed — refuse rather than call a copy new), and the
//     digest was never offered before;
//   * otherwise SETTLED quietly (a copy of known content, or already offered).
// Several pending copies of one new content are ONE new media file.
// A pending record that left the catalog, or carries a removal marker, is
// dropped.
//
// PURE: no I/O, no clock. O(records) — one pass building the known sets, one
// over the pending; the 100k scale test times it.
// Memory: two hash sets of the catalog's digests and sampled keys
// (~100 B per record → 100k ≈ 10 MB), freed on return.
//
// (For Rick: a set-difference over the catalog — like a C++ pass building an
// unordered_set of "seen" keys, then filtering the queue against it.)

import Foundation

public enum NewContentFinder {

    public struct Outcome: Equatable, Sendable {
        /// New contents, in first-seen order (catalog order of their first
        /// pending record), each with every pending record that holds it.
        public var newContents: [NewContent] = []
        /// Pending ids decided this pass (new or not) or dropped — they leave the queue.
        public var settled: Set<UUID> = []
        /// Pending ids still without a whole-file digest — they stay queued.
        public var waiting: Set<UUID> = []
        /// How many pending files turned out to be copies of known content.
        public var copiesOfKnown = 0
        /// How many pending ids were dropped (gone from the catalog or removed).
        public var dropped = 0

        public init() {}
    }

    public struct NewContent: Equatable, Sendable {
        public var digest: String
        public var recordIDs: [UUID]

        public init(digest: String, recordIDs: [UUID]) {
            self.digest = digest
            self.recordIDs = recordIDs
        }
    }

    /// Decide every pending record that has a digest now.
    public static func evaluate(records: [VideoRecord], pending: Set<UUID>, offered: Set<String>) -> Outcome {
        var out = Outcome()
        guard !pending.isEmpty else { return out }
        var knownDigests = Set<String>()
        var knownSampled = Set<String>()
        var pendingRecords: [VideoRecord] = []
        for rec in records {
            if pending.contains(rec.id) {
                pendingRecords.append(rec)
                continue
            }
            if let digest = CatalogCommit.digest(of: rec) {
                knownDigests.insert(digest)
            } else if let key = sampledKey(rec) {
                knownSampled.insert(key)
            }
        }
        let present = Set(pendingRecords.map(\.id))
        let gone = pending.subtracting(present)
        out.dropped += gone.count
        out.settled.formUnion(gone)
        var index: [String: Int] = [:]
        for rec in pendingRecords {
            if rec.removal != nil {
                out.dropped += 1
                out.settled.insert(rec.id)
                continue
            }
            guard let digest = CatalogCommit.digest(of: rec) else {
                out.waiting.insert(rec.id)
                continue
            }
            out.settled.insert(rec.id)
            let sampledKnown = sampledKey(rec).map { knownSampled.contains($0) } ?? false
            if knownDigests.contains(digest) || offered.contains(digest) || sampledKnown {
                out.copiesOfKnown += 1
                continue
            }
            if let i = index[digest] {
                out.newContents[i].recordIDs.append(rec.id)
            } else {
                index[digest] = out.newContents.count
                out.newContents.append(NewContent(digest: digest, recordIDs: [rec.id]))
            }
        }
        return out
    }

    /// The sampled identity of a file that has no digest: the segmented
    /// content hash when it has one, else partialMD5 with the size; nil when
    /// neither is known (an empty value never matches anything).
    public static func sampledKey(_ rec: VideoRecord) -> String? {
        if !rec.contentHash.isEmpty { return "ch:\(rec.contentHash)" }
        if !rec.partialMD5.isEmpty, rec.sizeBytes > 0 { return "pm:\(rec.partialMD5):\(rec.sizeBytes)" }
        return nil
    }

    /// The scan merge's genuine strangers: fresh records at a path no record
    /// under the root held before, and not a moved file's new path (that one
    /// keeps its old record). `existingPaths` = the paths under the root
    /// before the merge; `adoptedNewPaths` = the move matcher's new paths.
    public static func strangers(targetRecords: [VideoRecord], existingPaths: Set<String>,
                                 adoptedNewPaths: Set<String>) -> [UUID] {
        targetRecords.compactMap { rec in
            existingPaths.contains(rec.fullPath) || adoptedNewPaths.contains(rec.fullPath) ? nil : rec.id
        }
    }
}
