import Foundation

// MARK: - RelocateReconcile
//
// Pre-flight phase for the Relocate Volume feature. Sorts catalog
// records under the source volume into five buckets BEFORE the copy
// engine walks them, so that manual deletes/moves/pre-copies AND
// existing duplicates on other volumes compose cleanly with the
// automated migration.
//
// Five buckets per record (record.fullPath is the catalog-recorded
// source path):
//   A. ready            — file at recorded path, hash still matches
//   B. manuallyDeleted  — gone; no size+hash match found anywhere
//   C. sourceSideMove   — found elsewhere on source by size+hash; path rewrite then migrate
//   D. adopted          — found at planned destination by size+hash; path rewrite, skip copy
//   E. safelyRedundant  — same (size, partialMD5) exists on a THIRD volume
//                         (not source, not dest); catalog-only mark-as-deleted
//                         with audit trail. The source file is never touched.
//
// Bucket E is gated by `skipDupsOnOtherVolumes` (default true). It's the
// critical "failing-drive escape hatch": Mini2TB has 741 records, 739
// duped on MyBook + InternalRaid + Seagate2TB. We don't want to copy
// those 739 onto LaCie — they're already safe elsewhere. Mark them as
// deleted in the catalog with a witness list and let Rick retire the
// drive without burning a full copy cycle.
//
// Preference order (highest wins): previouslyRelocated → adopted (D) →
// safelyRedundant (E) → ready (A) → sourceSideMove (C) → manuallyDeleted (B).
// Destination always wins over safely-redundant — if we already have a
// copy at the planned dest, that's better than marking deleted because
// it preserves the post-relocate catalog path the user expects.
// Safely-redundant wins over ready: the entire failing-drive motivation
// is to AVOID reading source files we have safe copies of elsewhere,
// even when the source still reads fine.
//
// Pure & injectable: the file lists (with sizes) are passed in, and
// the hash function is injectable. The real caller wraps an FS walk
// and FileHasher.partialMD5. See docs/relocate_volume_plan.md §1A.

struct ReconcileResult: Equatable {
    /// File present at recorded path, ready to copy. Records here are
    /// unmodified — the migration phase will rewrite paths on success.
    var ready: [VideoRecord]

    /// File missing from source AND dest; mark `.manuallyDeleted`,
    /// leave `fullPath` pointing at the (now-offline) original so
    /// Compare & Rescue can still see what was lost from where.
    var manuallyDeleted: [VideoRecord]

    /// File found at a different location on the source volume.
    /// Caller rewrites `rec.fullPath` to `newSourcePath` then sends
    /// the record through the normal copy pipeline.
    var sourceSideMoves: [(rec: VideoRecord, newSourcePath: String)]

    /// File already at the planned destination (Rick pre-copied during
    /// triage). Caller rewrites `rec.fullPath` to `destPath`, stamps
    /// provenance, skips the copy.
    var adopted: [(rec: VideoRecord, destPath: String)]

    /// Same (size, partialMD5) exists on a volume that is neither the
    /// source nor the destination. Catalog-only mutation — file on the
    /// failing source drive is NEVER touched. Witnesses list capped to
    /// keep notes / audit log small; full count carried separately.
    var safelyRedundant: [SafelyRedundantEntry]

    /// Records under `sourceVolumeRootPath` but already relocated once
    /// (`originalFullPath != nil`). Not classified further — caller's
    /// `skipAlreadyRelocated` option decides whether to retry.
    var previouslyRelocated: [VideoRecord]

    static func == (lhs: ReconcileResult, rhs: ReconcileResult) -> Bool {
        lhs.ready.map(\.id) == rhs.ready.map(\.id) &&
        lhs.manuallyDeleted.map(\.id) == rhs.manuallyDeleted.map(\.id) &&
        lhs.sourceSideMoves.map { $0.rec.id } == rhs.sourceSideMoves.map { $0.rec.id } &&
        lhs.sourceSideMoves.map(\.newSourcePath) == rhs.sourceSideMoves.map(\.newSourcePath) &&
        lhs.adopted.map { $0.rec.id } == rhs.adopted.map { $0.rec.id } &&
        lhs.adopted.map(\.destPath) == rhs.adopted.map(\.destPath) &&
        lhs.safelyRedundant.map { $0.rec.id } == rhs.safelyRedundant.map { $0.rec.id } &&
        lhs.safelyRedundant.map(\.witnesses) == rhs.safelyRedundant.map(\.witnesses) &&
        lhs.safelyRedundant.map(\.totalWitnessCount) == rhs.safelyRedundant.map(\.totalWitnessCount) &&
        lhs.previouslyRelocated.map(\.id) == rhs.previouslyRelocated.map(\.id)
    }
}

/// One safely-redundant entry: which record, where the copies live (capped),
/// and the total count of witnesses (so the UI can say "and N more").
struct SafelyRedundantEntry: Equatable {
    let rec: VideoRecord
    /// Witness `fullPath` values on volumes other than source + dest. Capped
    /// at `maxWitnessSample` (5) to keep audit-trail notes from ballooning.
    let witnesses: [String]
    /// Full witness count BEFORE the cap. UI: "and N more witnesses".
    let totalWitnessCount: Int

    static func == (lhs: SafelyRedundantEntry, rhs: SafelyRedundantEntry) -> Bool {
        lhs.rec.id == rhs.rec.id
            && lhs.witnesses == rhs.witnesses
            && lhs.totalWitnessCount == rhs.totalWitnessCount
    }
}

/// One entry in the size-indexed file lists handed to `reconcile`.
struct ReconcileFileEntry: Equatable {
    let path: String
    let size: Int64
}

enum RelocateReconcile {

    /// Maximum number of witness paths we keep per safely-redundant
    /// record. The total count is preserved separately on the entry,
    /// so audit trails stay bounded but the dashboard can still report
    /// the real witness depth. Swift's `Array.prefix` ≈ C++'s
    /// `std::vector::erase(begin+N, end)` but non-mutating.
    static let maxWitnessSample = 5

    /// Classify each in-scope record into one of the five buckets.
    ///
    /// - Parameter records: pre-filtered to records under `sourceVolumeRootPath`.
    /// - Parameter allCatalogRecords: the entire catalog. Used to detect
    ///   safely-redundant records by (size, partialMD5) match on volumes
    ///   other than source + destination. Pass `records` itself if no
    ///   cross-volume check is desired.
    /// - Parameter sourceVolumeRootPath: e.g. "/Volumes/Mini2TB".
    /// - Parameter destinationRoot: where the migration will write outputs.
    /// - Parameter sourceFiles: file enumeration of `sourceVolumeRootPath`.
    /// - Parameter destFiles: file enumeration of `destinationRoot` (may be empty).
    /// - Parameter skipDupsOnOtherVolumes: when true, enable Bucket E
    ///   classification. When false, records that would land in E fall
    ///   through to the A/C/B rules as before — preserves legacy behavior.
    /// - Parameter hash: returns partial-MD5 of a file at the given path.
    ///   Real caller injects `FileHasher.partialMD5(path:)`. Empty string
    ///   on read error.
    static func reconcile(
        records: [VideoRecord],
        allCatalogRecords: [VideoRecord],
        sourceVolumeRootPath: String,
        destinationRoot: URL,
        sourceFiles: [ReconcileFileEntry],
        destFiles: [ReconcileFileEntry],
        skipDupsOnOtherVolumes: Bool,
        hash: (String) -> String
    ) -> ReconcileResult {

        // Build size-indexed lookup tables. The whole point is to avoid
        // O(records × files) hashing — for each record we only consult
        // files that match its expected byte count.
        var sourceIndex: [Int64: [String]] = [:]
        for f in sourceFiles { sourceIndex[f.size, default: []].append(f.path) }
        var destIndex: [Int64: [String]] = [:]
        for f in destFiles { destIndex[f.size, default: []].append(f.path) }

        // Build the "other-volume witness" index: (sizeBytes, partialMD5) →
        // [fullPath on a third volume]. Excludes records whose fullPath lives
        // under sourceVolumeRootPath or under destinationRoot.path — those
        // aren't "other volumes" by definition. Only built when the rule is
        // enabled; otherwise we skip the whole pass.
        //
        // Memory: keyed on (Int64, String) tuple-as-struct; at ~64B/entry
        // and a worst-case catalog of ~50K records, this is a few MB. Bounded
        // by `allCatalogRecords.count`. No streaming concerns.
        var witnessIndex: [WitnessKey: [String]] = [:]
        if skipDupsOnOtherVolumes {
            let srcPrefix = sourceVolumeRootPath.hasSuffix("/")
                ? sourceVolumeRootPath
                : sourceVolumeRootPath + "/"
            let dstPrefix = destinationRoot.path.hasSuffix("/")
                ? destinationRoot.path
                : destinationRoot.path + "/"
            for other in allCatalogRecords {
                // Skip the source-volume records — they're the input set,
                // not witnesses. Skip dest-resident records — bucket D is
                // strictly preferred over E for those.
                if other.fullPath.hasPrefix(srcPrefix) { continue }
                if other.fullPath.hasPrefix(dstPrefix) { continue }
                // Skip records that lack the data we'd match on — no
                // hash or zero bytes is too weak a signal to declare safe.
                if other.partialMD5.isEmpty { continue }
                if other.sizeBytes <= 0 { continue }
                let key = WitnessKey(size: other.sizeBytes, md5: other.partialMD5)
                witnessIndex[key, default: []].append(other.fullPath)
            }
        }

        var ready: [VideoRecord] = []
        var manuallyDeleted: [VideoRecord] = []
        var sourceSideMoves: [(rec: VideoRecord, newSourcePath: String)] = []
        var adopted: [(rec: VideoRecord, destPath: String)] = []
        var safelyRedundant: [SafelyRedundantEntry] = []
        var previouslyRelocated: [VideoRecord] = []

        for rec in records {
            // Already-migrated records get short-circuited; caller
            // decides via skipAlreadyRelocated whether to retry.
            if rec.originalFullPath != nil {
                previouslyRelocated.append(rec)
                continue
            }

            // Bucket D: same content already at planned destination. Check
            // dest FIRST because Rick may have pre-copied during triage,
            // and we want the catalog to converge on the dest path he
            // expects — wins over both Bucket E (safelyRedundant) and
            // Bucket A (ready).
            let planned = VideoScanModel.rewrittenPath(
                forSourcePath: rec.fullPath,
                sourceRoot: sourceVolumeRootPath,
                destRoot: destinationRoot.path
            )
            if matchesHashByCandidate(planned, expectedHash: rec.partialMD5, hash: hash),
               fileSize(at: planned) == rec.sizeBytes {
                adopted.append((rec: rec, destPath: planned))
                continue
            }
            if let match = findMatch(rec: rec, candidatesBySize: destIndex, hash: hash) {
                adopted.append((rec: rec, destPath: match))
                continue
            }

            // Bucket E: catalog already knows the same content exists on a
            // volume that isn't source or dest. Wins over Bucket A — the
            // entire failing-drive motivation is to avoid reading source
            // files we have safe copies of elsewhere, even when the source
            // still reads fine. Gate: require a real hash AND a positive
            // byte count — never false-positive on empty signal. The toggle
            // (skipDupsOnOtherVolumes=false) leaves witnessIndex empty, so
            // this branch is a no-op when disabled.
            if !rec.partialMD5.isEmpty, rec.sizeBytes > 0 {
                let key = WitnessKey(size: rec.sizeBytes, md5: rec.partialMD5)
                if let allWitnesses = witnessIndex[key], !allWitnesses.isEmpty {
                    let sample = Array(allWitnesses.prefix(maxWitnessSample))
                    safelyRedundant.append(SafelyRedundantEntry(
                        rec: rec,
                        witnesses: sample,
                        totalWitnessCount: allWitnesses.count
                    ))
                    continue
                }
            }

            // Bucket A: file still at its recorded path. Verify by hash
            // when the catalog has one stored; size-only otherwise.
            if let bytes = fileSize(at: rec.fullPath),
               bytes == rec.sizeBytes {
                if rec.partialMD5.isEmpty || hash(rec.fullPath) == rec.partialMD5 {
                    ready.append(rec)
                    continue
                }
            }

            // Bucket C: same content moved elsewhere on the source.
            if let match = findMatch(rec: rec, candidatesBySize: sourceIndex, hash: hash),
               match != rec.fullPath {
                sourceSideMoves.append((rec: rec, newSourcePath: match))
                continue
            }

            // Bucket B: gone with no plausible match anywhere we can see.
            manuallyDeleted.append(rec)
        }

        return ReconcileResult(
            ready: ready,
            manuallyDeleted: manuallyDeleted,
            sourceSideMoves: sourceSideMoves,
            adopted: adopted,
            safelyRedundant: safelyRedundant,
            previouslyRelocated: previouslyRelocated
        )
    }

    // MARK: - Internals

    /// Composite key for the witness index. Swift `struct` with `Hashable`
    /// auto-synthesis ≈ a C++ struct that you'd need to hand-write
    /// `operator==` and `std::hash` specialization for.
    private struct WitnessKey: Hashable {
        let size: Int64
        let md5: String
    }

    private static func fileSize(at path: String) -> Int64? {
        var sb = stat()
        guard stat(path, &sb) == 0 else { return nil }
        return Int64(sb.st_size)
    }

    /// Among the size-indexed candidates whose byte count equals
    /// `rec.sizeBytes`, return the first whose hash matches
    /// `rec.partialMD5`. Returns nil if catalog has no stored hash AND
    /// more than one same-sized candidate exists (ambiguous — refuse
    /// to guess; safer to fall through to manuallyDeleted).
    private static func findMatch(rec: VideoRecord,
                                  candidatesBySize: [Int64: [String]],
                                  hash: (String) -> String) -> String? {
        guard let candidates = candidatesBySize[rec.sizeBytes], !candidates.isEmpty else {
            return nil
        }
        if rec.partialMD5.isEmpty {
            // Without a stored hash, only auto-accept when there's
            // exactly one size match — otherwise we'd be guessing.
            return candidates.count == 1 ? candidates[0] : nil
        }
        for path in candidates where hash(path) == rec.partialMD5 {
            return path
        }
        return nil
    }

    /// Quick check: does `path` exist with `expectedHash`? Returns true
    /// when expectedHash is non-empty and the file's hash matches.
    /// Returns false when expectedHash is empty (we don't auto-adopt
    /// without a hash to verify against on a single-candidate check).
    private static func matchesHashByCandidate(_ path: String,
                                               expectedHash: String,
                                               hash: (String) -> String) -> Bool {
        guard FileManager.default.fileExists(atPath: path),
              !expectedHash.isEmpty else { return false }
        return hash(path) == expectedHash
    }
}
