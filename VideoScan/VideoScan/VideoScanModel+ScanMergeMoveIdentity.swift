import Foundation
import os

// MARK: - Scan-merge move/rename identity
//
// Feature (branch feature/move-rename-identity, 2026-07-02): a moved or
// renamed file keeps its catalog record IDENTITY. Before this, a complete
// rescan treated the old path as genuinely gone (prune) and the new path as
// a stranger (fresh record) — destroying the record's id, dossier fields
// (hours of Qwen + Whisper compute), user curation, and any pairedWith
// references other records held. Rick's driving case: 134 GB of
// digitized-tape .mkv masters on /Volumes/MediaExpansion will be MOVED
// cross-volume to /Volumes/LaCieWorkspace — transcripts, captions, and tags
// must follow the files.
//
// Mechanism (complete-scan merges only — partial merges never prune, so
// there is nothing to rescue): each ADDED file (path not previously in the
// catalog) is fingerprint-matched — key (partialMD5, sizeBytes), BOTH
// required non-empty/non-zero — against:
//
//   (a) this merge's genuinely-gone set (same-root rename/move: the file
//       vanished here and appeared there within one scan), then
//   (b) catalog records OUTSIDE the scanned root whose file NO LONGER
//       exists on disk (cross-volume/root move — the old volume may not
//       have been rescanned yet).
//
// A candidate whose file STILL EXISTS on disk is a COPY, not a move — never
// adopted; the existing duplicate machinery owns that. Fingerprint collisions
// (same partialMD5+size, different content) are the standing dup-detection
// assumption; no new hash is introduced.
//
// SAFETY DISCIPLINE (mirrors commitScanResults' hard-won invariants):
//   * The (b) existence stats are blocking I/O — they run on the SAME
//     detached task as the vanished-path sweep, so the merge keeps its ONE
//     suspension point. Only fingerprint-matched candidates are statted
//     (usually a handful of files, ~1 stat each — worst-case memory is a
//     [String: Bool] with one entry per matched candidate).
//   * Candidate paths are hoisted PRE-await as plain values; the MATCH
//     DECISIONS are re-derived POST-await against the current records array.
//     A candidate with no evidence (appeared during the await) or one whose
//     record left the catalog during the await is simply NOT matched — no
//     adoption without evidence, no resurrection.
//   * Moved adoptions are EXCLUDED from the genuinely-gone prune count
//     BEFORE the mass-deletion tripwire judges it: a whole-folder reorganize
//     is a relocation, not a deletion.
//
// Relocation semantics: the OLD record survives with its id (pairedWith
// references from other records keep resolving to the same instance). It
// adopts the fresh probe's technical fields via the canonical
// ProbeOutcome(scanDerivedFrom:) → apply() round-trip, then
// RescanPreservedFields re-asserts the enrichment taxonomy (dossier, tags,
// notes, dispositions) — the SAME two field lists every rescan already
// uses, no third list invented. The fresh record is not appended.
//
// Design note: the Manager-approved sketch allowed a cheap path ("if
// isWorthRestoring says nothing is worth keeping, a plain new record is
// fine"). Deliberately NOT taken: isWorthRestoring cannot see INCOMING
// references (another record's pairedWith / derivedFrom pointing at this
// id), so the cheap path could orphan a pair link to save a few field
// copies. Adoption is uniform and O(fields) — always adopt.
//
// Soft-deleted records (purgedAt != nil) are never candidates: adopting one
// would swallow the fresh record into a hidden row, making the moved file
// invisible in the catalog.

// MARK: - Value types (Sendable, so they can cross to the matcher/tests)

/// Identity fingerprint for move/rename matching — the SAME key duplicate
/// detection already trusts. Both components are required: a blank
/// partialMD5 (hashing skipped / I/O error) or a zero size must never match
/// anything, or every hash-less record would cross-adopt.
struct ScanMergeFingerprint: Hashable, Sendable {
    let partialMD5: String
    let sizeBytes: Int64

    var isViable: Bool { !partialMD5.isEmpty && sizeBytes > 0 }

    init(partialMD5: String, sizeBytes: Int64) {
        self.partialMD5 = partialMD5
        self.sizeBytes = sizeBytes
    }

    /// `// @MainActor: reads the mutable record — same convention as
    /// // RescanPreservedFields.init(from:).`
    @MainActor
    init(of rec: VideoRecord) {
        self.init(partialMD5: rec.partialMD5, sizeBytes: rec.sizeBytes)
    }
}

/// One ADDED file (path new to the catalog) offered to the matcher.
struct ScanMergeAddedFile: Sendable, Equatable {
    var path: String
    var fingerprint: ScanMergeFingerprint
}

/// One gone/absent record offered to the matcher as a possible move source.
struct ScanMergeMoveCandidate: Sendable, Equatable {
    var path: String
    var fingerprint: ScanMergeFingerprint
    /// true → from this merge's genuinely-gone set (same-root rename/move);
    /// false → catalog-wide record outside the scanned root (cross-root move).
    var sameRoot: Bool
}

extension VideoScanModel {

    // MARK: - Pure matcher (nonisolated static, unit-tested directly)

    /// Match added files to gone/absent candidates by fingerprint, with
    /// DETERMINISTIC safe-side ambiguity rules. Returns addedPath → candidatePath.
    ///
    /// Ambiguity rules (each fingerprint group is independent; a greedy
    /// assignment over pairs sorted by the rules below resolves BOTH
    /// directions of ambiguity with one mechanism):
    ///   1. same-root (genuinely-gone) candidates beat catalog-wide ones —
    ///      a rename in place beats a cross-volume match;
    ///   2. longer common trailing path components (…/family/xmas/t.mkv
    ///      moving keeps its subtree shape) beat shorter;
    ///   3. lexicographic (candidate path, then added path) for determinism.
    /// Multiple added files matching one candidate (file copied, original
    /// deleted — or two identical captures): exactly ONE adopts; the rest
    /// land as normal new records (dup detection already models copies).
    ///
    /// `// nonisolated static ≈ a free function in C++ — pure, no actor hop,
    /// // trivially unit-testable (same shape as gatherScanMergeExistenceEvidence).`
    nonisolated static func matchMovedFiles(
        added: [ScanMergeAddedFile],
        candidates: [ScanMergeMoveCandidate]
    ) -> [String: String] {
        guard !added.isEmpty, !candidates.isEmpty else { return [:] }
        let candidatesByFP = Dictionary(grouping: candidates, by: \.fingerprint)
        var adoptions: [String: String] = [:]
        for (fp, addedGroup) in Dictionary(grouping: added, by: \.fingerprint) {
            guard let candGroup = candidatesByFP[fp] else { continue }
            // Score every (added, candidate) pair, then assign greedily in
            // rule order. Groups are small in practice (identical-fingerprint
            // sets), so the quadratic pairing is negligible.
            struct Pair {
                let addedPath: String
                let candPath: String
                let sameRoot: Bool
                let suffix: Int
            }
            var pairs: [Pair] = []
            for a in addedGroup {
                for c in candGroup {
                    pairs.append(Pair(addedPath: a.path, candPath: c.path,
                                      sameRoot: c.sameRoot,
                                      suffix: commonTrailingComponents(a.path, c.path)))
                }
            }
            pairs.sort { l, r in
                if l.sameRoot != r.sameRoot { return l.sameRoot }
                if l.suffix != r.suffix { return l.suffix > r.suffix }
                if l.candPath != r.candPath { return l.candPath < r.candPath }
                return l.addedPath < r.addedPath
            }
            var usedAdded = Set<String>()
            var usedCandidates = Set<String>()
            for p in pairs where !usedAdded.contains(p.addedPath) && !usedCandidates.contains(p.candPath) {
                adoptions[p.addedPath] = p.candPath
                usedAdded.insert(p.addedPath)
                usedCandidates.insert(p.candPath)
            }
        }
        return adoptions
    }

    /// Count of matching trailing path components ("/a/family/t.mkv" vs
    /// "/b/family/t.mkv" → 2). The matcher's rule-2 tiebreak.
    nonisolated static func commonTrailingComponents(_ a: String, _ b: String) -> Int {
        let ac = a.split(separator: "/")
        let bc = b.split(separator: "/")
        var n = 0
        var i = ac.count - 1
        var j = bc.count - 1
        while i >= 0 && j >= 0 && ac[i] == bc[j] {
            n += 1
            i -= 1
            j -= 1
        }
        return n
    }

    // MARK: - Off-actor existence evidence for (b) candidates

    /// Stat the outside-root move candidates. Runs on the SAME detached task
    /// as `gatherScanMergeExistenceEvidence` (the merge's one suspension
    /// point covers both sweeps). Pure function of the filesystem, keyed by
    /// path so the post-await re-derivation consumes it with the same
    /// no-evidence-means-no-adoption discipline as the prune evidence.
    nonisolated static func gatherMoveCandidateExistenceEvidence(
        paths: [String]
    ) -> [String: Bool] {
        guard !paths.isEmpty else { return [:] }
        let fm = FileManager.default
        var exists = [String: Bool](minimumCapacity: paths.count)
        for path in paths {
            exists[path] = fm.fileExists(atPath: path)
        }
        return exists
    }

    // MARK: - Pre-await hoist (values only)

    /// PRE-await: paths of catalog records OUTSIDE the scanned root that
    /// fingerprint-match one of this scan's added files — the ONLY paths the
    /// detached sweep needs to stat for cross-root move detection. Hoisted
    /// as plain strings; nothing here survives past the post-await
    /// re-derivation except as stat evidence keyed by path.
    func hoistOutsideRootMoveCandidatePaths(
        root: String,
        targetRecords: [VideoRecord]
    ) -> [String] {
        var existingPathsUnderRoot = Set<String>()
        for rec in records where PathScope.contains(rec.fullPath, within: root) {
            existingPathsUnderRoot.insert(rec.fullPath)
        }
        var addedFingerprints = Set<ScanMergeFingerprint>()
        for rec in targetRecords where !existingPathsUnderRoot.contains(rec.fullPath) {
            let fp = ScanMergeFingerprint(of: rec)
            if fp.isViable { addedFingerprints.insert(fp) }
        }
        guard !addedFingerprints.isEmpty else { return [] }
        var paths: [String] = []
        for rec in records {
            guard !PathScope.contains(rec.fullPath, within: root),
                  rec.purgedAt == nil else { continue }
            let fp = ScanMergeFingerprint(of: rec)
            if fp.isViable && addedFingerprints.contains(fp) {
                paths.append(rec.fullPath)
            }
        }
        return paths
    }

    // MARK: - Post-await derivation + adoption (main actor, no suspension)

    /// POST-await: re-derive the added set and both candidate pools from the
    /// CURRENT records array (same re-derivation discipline as the prune
    /// path), then run the pure matcher. Returns addedPath → candidatePath.
    ///
    /// - Parameter genuinelyGone: the evidence-backed gone set (pool (a) —
    ///   their files are already proven off-disk by the prune sweep).
    /// - Parameter outsideRootCandidateExists: stat evidence for pool (b),
    ///   keyed by path. Only an EXPLICIT `false` (statted, gone) qualifies a
    ///   candidate; absent (appeared during the await, never statted) or
    ///   `true` (still on disk → a copy) means never adopt.
    func deriveMoveAdoptions(
        root: String,
        targetRecords: [VideoRecord],
        existingPathsUnderRoot: Set<String>,
        genuinelyGone: [VideoRecord],
        outsideRootCandidateExists: [String: Bool]
    ) -> [String: String] {
        var added: [ScanMergeAddedFile] = []
        for rec in targetRecords where !existingPathsUnderRoot.contains(rec.fullPath) {
            let fp = ScanMergeFingerprint(of: rec)
            if fp.isViable {
                added.append(ScanMergeAddedFile(path: rec.fullPath, fingerprint: fp))
            }
        }
        guard !added.isEmpty else { return [:] }

        var candidates: [ScanMergeMoveCandidate] = []
        for rec in genuinelyGone where rec.purgedAt == nil {
            let fp = ScanMergeFingerprint(of: rec)
            if fp.isViable {
                candidates.append(ScanMergeMoveCandidate(path: rec.fullPath, fingerprint: fp, sameRoot: true))
            }
        }
        for rec in records {
            guard !PathScope.contains(rec.fullPath, within: root),
                  rec.purgedAt == nil,
                  outsideRootCandidateExists[rec.fullPath] == false else { continue }
            let fp = ScanMergeFingerprint(of: rec)
            if fp.isViable {
                candidates.append(ScanMergeMoveCandidate(path: rec.fullPath, fingerprint: fp, sameRoot: false))
            }
        }
        guard !candidates.isEmpty else { return [:] }
        return Self.matchMovedFiles(added: added, candidates: candidates)
    }

    /// Apply the adoptions: each surviving OLD record follows its file —
    /// path + technical fields from the fresh probe, enrichment kept, id
    /// untouched. Old instances are looked up by their CURRENT (old) path;
    /// there are no suspension points between derivation and here, so they
    /// are guaranteed present (the guards are belt-and-suspenders).
    /// Returns the number of records that followed their files.
    @discardableResult
    func applyMoveAdoptions(
        _ adoptions: [String: String],
        targetRecords: [VideoRecord]
    ) -> Int {
        guard !adoptions.isEmpty else { return 0 }
        let freshByPath = Dictionary(targetRecords.map { ($0.fullPath, $0) },
                                     uniquingKeysWith: { first, _ in first })
        let wantedOldPaths = Set(adoptions.values)
        var oldByPath: [String: VideoRecord] = [:]
        for rec in records where wantedOldPaths.contains(rec.fullPath) {
            oldByPath[rec.fullPath] = rec
        }
        var applied = 0
        for (newPath, oldPath) in adoptions {
            guard let old = oldByPath[oldPath], let fresh = freshByPath[newPath] else { continue }
            adoptMovedRecord(old: old, fresh: fresh)
            applied += 1
        }
        return applied
    }

    /// The relocation itself: snapshot the old record's enrichment (the
    /// existing RescanPreservedFields taxonomy), stamp the fresh probe's
    /// technical fields over it (the existing ProbeOutcome apply list, via
    /// the inverse lift), then re-assert the enrichment — which also puts
    /// the USER's notes back over the probe's diagnostic notes. The old
    /// instance keeps its id, pair/duplicate fields, avid metadata, and
    /// relocate provenance untouched.
    func adoptMovedRecord(old: VideoRecord, fresh: VideoRecord) {
        let keep = RescanPreservedFields(from: old)
        old.apply(ProbeOutcome(scanDerivedFrom: fresh))
        keep.apply(to: old)
    }
}
