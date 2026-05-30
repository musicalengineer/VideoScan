import Foundation

// MARK: - RelocateReconcile
//
// Pre-flight phase for the Relocate Volume feature. Sorts catalog
// records under the source volume into four buckets BEFORE the copy
// engine walks them, so that manual deletes/moves/pre-copies Rick has
// done during triage compose cleanly with the automated migration.
//
// Four buckets per record (record.fullPath is the catalog-recorded
// source path):
//   A. ready          — file at recorded path, hash still matches
//   B. manuallyDeleted — gone; no size+hash match found anywhere
//   C. sourceSideMove — found elsewhere on source by size+hash; path rewrite then migrate
//   D. adopted        — found at planned destination by size+hash; path rewrite, skip copy
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
        lhs.previouslyRelocated.map(\.id) == rhs.previouslyRelocated.map(\.id)
    }
}

/// One entry in the size-indexed file lists handed to `reconcile`.
struct ReconcileFileEntry: Equatable {
    let path: String
    let size: Int64
}

enum RelocateReconcile {

    /// Classify each in-scope record into one of the four buckets.
    ///
    /// - Parameter records: pre-filtered to records under `sourceVolumeRootPath`.
    /// - Parameter sourceVolumeRootPath: e.g. "/Volumes/Mini2TB".
    /// - Parameter destinationRoot: where the migration will write outputs.
    /// - Parameter sourceFiles: file enumeration of `sourceVolumeRootPath`.
    /// - Parameter destFiles: file enumeration of `destinationRoot` (may be empty).
    /// - Parameter hash: returns partial-MD5 of a file at the given path.
    ///   Real caller injects `FileHasher.partialMD5(path:)`. Empty string
    ///   on read error.
    static func reconcile(
        records: [VideoRecord],
        sourceVolumeRootPath: String,
        destinationRoot: URL,
        sourceFiles: [ReconcileFileEntry],
        destFiles: [ReconcileFileEntry],
        hash: (String) -> String
    ) -> ReconcileResult {

        // Build size-indexed lookup tables. The whole point is to avoid
        // O(records × files) hashing — for each record we only consult
        // files that match its expected byte count.
        var sourceIndex: [Int64: [String]] = [:]
        for f in sourceFiles { sourceIndex[f.size, default: []].append(f.path) }
        var destIndex: [Int64: [String]] = [:]
        for f in destFiles { destIndex[f.size, default: []].append(f.path) }

        var ready: [VideoRecord] = []
        var manuallyDeleted: [VideoRecord] = []
        var sourceSideMoves: [(rec: VideoRecord, newSourcePath: String)] = []
        var adopted: [(rec: VideoRecord, destPath: String)] = []
        var previouslyRelocated: [VideoRecord] = []

        for rec in records {
            // Already-migrated records get short-circuited; caller
            // decides via skipAlreadyRelocated whether to retry.
            if rec.originalFullPath != nil {
                previouslyRelocated.append(rec)
                continue
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

            // Bucket D: same content already at planned destination. Check
            // dest first because Rick may have pre-copied during triage,
            // and we want to avoid hashing the source side if we already
            // have a match upstream.
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
            previouslyRelocated: previouslyRelocated
        )
    }

    // MARK: - Internals

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
