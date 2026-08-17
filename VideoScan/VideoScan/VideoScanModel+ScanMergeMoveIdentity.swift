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
// Update Catalog (Rick 2026-08-17, branch feature/update-catalog) sharpened
// the rules — this file is the "cross-target identity relink at merge
// time" half of that door (VideoScanModel+UpdateCatalog.swift is the UI /
// preview half):
//   * identity = sizeBytes + partialMD5 (the SAME key duplicate detection
//     and identityKey(for:) already trust), PLUS contentHash when BOTH
//     sides carry one — two files with the same head/size but different
//     segmented signatures are never the same file;
//   * ambiguity is never guessed away: several missing records for one
//     new file, or several new files for one missing record, are left as
//     new + missing and reported as "ambiguous — review". Only STRUCTURAL
//     evidence disambiguates (same-root rename beats a cross-root match;
//     a unique, mutual, strictly-best trailing-path match — e.g. the same
//     filename — pairs files inside a group). The former lexicographic
//     tiebreak is gone;
//   * archive copies are app-managed: a record with derivationKind ==
//     archivePromotion, any record under the Master Archive root, and any
//     ADDED file under the Master Archive root never relink in either
//     direction. Retire witnesses (archiveStage == .manuallyDeleted) and
//     records under RETIRED targets are never candidates either — a shelf
//     drive being offline is not evidence its file moved;
//   * a relink stamps `originalFullPath` (first move only — historical
//     provenance, never overwritten) and appends a File Journey line
//     ("Reconcile <stamp>: Moved from <old> to <new> (relinked by Update
//     Catalog)") so the timeline tells the story.
//
// Mechanism (complete-scan merges only — partial merges never prune, so
// there is nothing to rescue): each ADDED file (path not previously in the
// catalog) is fingerprint-matched against:
//
//   (a) this merge's genuinely-gone set (same-root rename/move: the file
//       vanished here and appeared there within one scan), then
//   (b) catalog records OUTSIDE the scanned root whose file NO LONGER
//       exists on disk (cross-volume/root move — the old volume may not
//       have been rescanned yet, or may be unmounted).
//
// A candidate whose file STILL EXISTS on disk is a COPY, not a move — never
// adopted; the existing duplicate machinery owns that.
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
// ProbeOutcome(scanDerivedFrom:) → apply() round-trip (fullPath, directory,
// filename, scanContext/volume, size, dates, codecs…), then
// RescanPreservedFields re-asserts the enrichment taxonomy (dossier, tags,
// notes, dispositions, star, people) — the SAME two field lists every
// rescan already uses, no third list invented. The fresh record is not
// appended.
//
// Soft-deleted records (purgedAt != nil) are never candidates: adopting one
// would swallow the fresh record into a hidden row, making the moved file
// invisible in the catalog.
//
// Worst-case memory: one fingerprint per added file + one per candidate
// (~100 B each), grouped by fingerprint. At 100k added files that is
// ~10 MB transient, freed when the merge returns. The relink index is
// built ONCE per merge (dictionary grouping — O(n)); lookups are O(1).

private let moveIdentityLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "scanMerge")

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
    /// Segmented content signature when the fresh probe computed one;
    /// "" = unknown (never disqualifies, never confirms).
    var contentHash: String = ""
}

/// One gone/absent record offered to the matcher as a possible move source.
struct ScanMergeMoveCandidate: Sendable, Equatable {
    var path: String
    var fingerprint: ScanMergeFingerprint
    /// true → from this merge's genuinely-gone set (same-root rename/move);
    /// false → catalog-wide record outside the scanned root (cross-root move).
    var sameRoot: Bool
    /// The record's stored content signature; "" = never hashed.
    var contentHash: String = ""
}

/// One unresolved identity group: these added files and these missing
/// records share a fingerprint but no structural evidence says which is
/// which. Reported by the Update Catalog preview as "ambiguous — review";
/// the merge leaves them as new + missing (never guesses).
struct ScanMergeAmbiguity: Sendable, Equatable, Hashable {
    var addedPaths: [String]
    var candidatePaths: [String]
}

/// The matcher's full verdict: what to relink, and what it refused to guess.
struct ScanMergeMoveMatch: Sendable, Equatable {
    /// addedPath → candidatePath.
    var adoptions: [String: String] = [:]
    var ambiguous: [ScanMergeAmbiguity] = []
}

extension VideoScanModel {

    // MARK: - Pure matcher (nonisolated static, unit-tested directly)

    /// Backward-compatible wrapper: adoptions only. See
    /// `matchMovedFilesWithAmbiguity` for the rules.
    nonisolated static func matchMovedFiles(
        added: [ScanMergeAddedFile],
        candidates: [ScanMergeMoveCandidate]
    ) -> [String: String] {
        matchMovedFilesWithAmbiguity(added: added, candidates: candidates).adoptions
    }

    /// Match added files to gone/absent candidates by fingerprint. NEVER
    /// guesses: a pairing is made only on evidence, everything else in a
    /// fingerprint group is reported as ambiguous.
    ///
    /// Per fingerprint group (independent of every other group):
    ///   0. a (added, candidate) pair is COMPATIBLE unless both carry a
    ///      contentHash and the hashes differ;
    ///   1. same-root candidates are tried first (a rename in place beats a
    ///      cross-volume match), then cross-root candidates — each tier
    ///      sees only the added files the previous tier left unmatched;
    ///   2. inside a tier, pairs are made when either
    ///        (i)  exactly one added file and exactly one compatible
    ///             candidate remain — content identity is unique, or
    ///        (ii) an added file's strictly-best trailing-path match (≥ 1
    ///             shared trailing component, e.g. the same filename) is
    ///             unique AND that candidate's strictly-best added file is
    ///             the same one (mutual best) — a subtree that moved keeps
    ///             its shape;
    ///      repeated until nothing more pairs;
    ///   3. whatever is left with BOTH unmatched added files and unmatched
    ///      candidates in the group is one `ScanMergeAmbiguity`.
    /// Determinism: the outcome depends only on the set of inputs, never
    /// on their order — there is no lexicographic tiebreak any more.
    ///
    /// `// nonisolated static ≈ a free function in C++ — pure, no actor hop,
    /// // trivially unit-testable (same shape as gatherScanMergeExistenceEvidence).`
    nonisolated static func matchMovedFilesWithAmbiguity(
        added: [ScanMergeAddedFile],
        candidates: [ScanMergeMoveCandidate]
    ) -> ScanMergeMoveMatch {
        var result = ScanMergeMoveMatch()
        guard !added.isEmpty, !candidates.isEmpty else { return result }
        // Index built ONCE — O(n) grouping, then O(1) per lookup.
        let candidatesByFP = Dictionary(grouping: candidates, by: \.fingerprint)
        // Deterministic group order so the ambiguity list is stable for
        // display/tests (does not influence pairing decisions).
        let addedGroups = Dictionary(grouping: added, by: \.fingerprint)
        for fp in addedGroups.keys.sorted(by: { ($0.partialMD5, $0.sizeBytes) < ($1.partialMD5, $1.sizeBytes) }) {
            guard let addedGroup = addedGroups[fp], let candGroup = candidatesByFP[fp] else { continue }
            var remainingAdded = addedGroup
            var unmatchedCandidates: [ScanMergeMoveCandidate] = []
            for tier in [true, false] {   // same-root first, then cross-root
                let tierCands = candGroup.filter { $0.sameRoot == tier }
                guard !tierCands.isEmpty else { continue }
                let (pairs, leftoverCands) = pairWithinTier(added: remainingAdded, candidates: tierCands)
                for (a, c) in pairs {
                    result.adoptions[a] = c
                }
                let matchedAdded = Set(pairs.map(\.0))
                remainingAdded.removeAll { matchedAdded.contains($0.path) }
                unmatchedCandidates.append(contentsOf: leftoverCands)
            }
            // Ambiguity = leftovers that are actually COMPATIBLE with each
            // other (a candidate vetoed by contentHash on every side is not
            // "ambiguous", it is simply a different file).
            let ambAdded = remainingAdded.filter { a in
                unmatchedCandidates.contains { Self.relinkCompatible(a, $0) }
            }
            let ambCands = unmatchedCandidates.filter { c in
                remainingAdded.contains { Self.relinkCompatible($0, c) }
            }
            if !ambAdded.isEmpty && !ambCands.isEmpty {
                result.ambiguous.append(ScanMergeAmbiguity(
                    addedPaths: ambAdded.map(\.path).sorted(),
                    candidatePaths: ambCands.map(\.path).sorted()))
            }
        }
        return result
    }

    /// One tier of the matcher (see rules 0 + 2 above). Returns the pairs
    /// made and the candidates left unmatched.
    private nonisolated static func pairWithinTier(
        added: [ScanMergeAddedFile],
        candidates: [ScanMergeMoveCandidate]
    ) -> (pairs: [(String, String)], leftoverCandidates: [ScanMergeMoveCandidate]) {
        var pairs: [(String, String)] = []
        var openAdded = added
        var openCands = candidates
        let compatible = Self.relinkCompatible
        var progressed = true
        while progressed && !openAdded.isEmpty && !openCands.isEmpty {
            progressed = false
            // Rule (i): unique identity — one added, one compatible candidate.
            if openAdded.count == 1 {
                let a = openAdded[0]
                let compat = openCands.filter { compatible(a, $0) }
                if compat.count == 1 {
                    pairs.append((a.path, compat[0].path))
                    openAdded.removeAll()
                    openCands.removeAll { $0.path == compat[0].path }
                    break
                }
            }
            // Rule (ii): mutual, unique, strictly-best trailing-path match.
            // suffix ≥ 1 required (at least the filename agrees).
            var claimed: [(String, String)] = []
            var usedCands = Set<String>()
            for a in openAdded {
                var best: ScanMergeMoveCandidate?
                var bestScore = 0
                var tie = false
                for c in openCands where compatible(a, c) {
                    let s = commonTrailingComponents(a.path, c.path)
                    if s > bestScore { best = c; bestScore = s; tie = false }
                    else if s == bestScore && s > 0 { tie = true }
                }
                guard let c = best, !tie, !usedCands.contains(c.path) else { continue }
                // Mutual: is `a` also c's unique strictly-best added file?
                var reverseBest = 0
                var reverseTie = false
                var reverseWinner: String?
                for other in openAdded where compatible(other, c) {
                    let s = commonTrailingComponents(other.path, c.path)
                    if s > reverseBest { reverseBest = s; reverseWinner = other.path; reverseTie = false }
                    else if s == reverseBest && s > 0 { reverseTie = true }
                }
                guard !reverseTie, reverseWinner == a.path else { continue }
                claimed.append((a.path, c.path))
                usedCands.insert(c.path)
            }
            if !claimed.isEmpty {
                progressed = true
                pairs.append(contentsOf: claimed)
                let ca = Set(claimed.map(\.0))
                openAdded.removeAll { ca.contains($0.path) }
                openCands.removeAll { usedCands.contains($0.path) }
            }
        }
        return (pairs, openCands)
    }

    /// Rule 0: a pair is compatible unless BOTH carry a content signature
    /// and the signatures differ.
    nonisolated static func relinkCompatible(_ a: ScanMergeAddedFile, _ c: ScanMergeMoveCandidate) -> Bool {
        a.contentHash.isEmpty || c.contentHash.isEmpty || a.contentHash == c.contentHash
    }

    /// Count of matching trailing path components ("/a/family/t.mkv" vs
    /// "/b/family/t.mkv" → 2). The matcher's structural-evidence measure.
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

    // MARK: - Relink protection (app-managed / retired trees)

    /// Snapshot of the paths the relinker must never touch: the Master
    /// Archive root and every RETIRED target's searchPath. Taken once per
    /// merge (cheap — a handful of strings), applied via component-boundary
    /// PathScope.contains.
    struct RelinkProtectedRoots: Sendable {
        /// Normalized roots (no trailing slash), never "" or "/".
        var roots: [String]

        init(roots: [String]) {
            self.roots = roots.map(PathScope.normalize).filter { !$0.isEmpty && $0 != "/" }
        }

        /// Component-boundary containment; the path is normalized ONCE
        /// (this runs per record in the merge derivation).
        nonisolated func contains(_ path: String) -> Bool {
            guard !roots.isEmpty else { return false }
            let p = PathScope.normalize(path)
            return roots.contains { p == $0 || p.hasPrefix($0 + "/") }
        }
    }

    func relinkProtectedRoots() -> RelinkProtectedRoots {
        var roots: [String] = []
        if let arc = masterArchiveRootPath { roots.append(arc) }
        for t in scanTargets where t.isRetired && !t.searchPath.isEmpty {
            roots.append(t.searchPath)
        }
        return RelinkProtectedRoots(roots: roots)
    }

    /// True when `rec` may never be a relink SOURCE: soft-deleted, an
    /// archive copy, a retire witness, or living under a protected tree.
    func isRelinkProtectedCandidate(_ rec: VideoRecord, protected: RelinkProtectedRoots) -> Bool {
        if rec.purgedAt != nil { return true }
        if rec.derivationKind == ArchivePromotion.derivationKind { return true }
        if rec.archiveStage == .manuallyDeleted { return true }
        return protected.contains(rec.fullPath)
    }

    /// True when a freshly scanned file may never ADOPT an existing record
    /// (it lives inside the Master Archive — the archive is app-managed;
    /// a Master Archive rescan may still catalog it as a fresh record).
    func isRelinkProtectedAddedPath(_ path: String, protected: RelinkProtectedRoots) -> Bool {
        guard let arc = masterArchiveRootPath else { return false }
        return PathScope.contains(path, within: arc)
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
        let protected = relinkProtectedRoots()
        var existingPathsUnderRoot = Set<String>()
        for rec in records where PathScope.contains(rec.fullPath, within: root) {
            existingPathsUnderRoot.insert(rec.fullPath)
        }
        var addedFingerprints = Set<ScanMergeFingerprint>()
        for rec in targetRecords where !existingPathsUnderRoot.contains(rec.fullPath) {
            guard !isRelinkProtectedAddedPath(rec.fullPath, protected: protected) else { continue }
            let fp = ScanMergeFingerprint(of: rec)
            if fp.isViable { addedFingerprints.insert(fp) }
        }
        guard !addedFingerprints.isEmpty else { return [] }
        var paths: [String] = []
        for rec in records {
            guard !PathScope.contains(rec.fullPath, within: root),
                  !isRelinkProtectedCandidate(rec, protected: protected) else { continue }
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
    /// path), then run the pure matcher. Returns adoptions (addedPath →
    /// candidatePath) plus the ambiguities the matcher refused to guess.
    ///
    /// - Parameter genuinelyGone: the evidence-backed gone set (pool (a) —
    ///   their files are already proven off-disk by the prune sweep).
    /// - Parameter outsideRootCandidateExists: stat evidence for pool (b),
    ///   keyed by path. Only an EXPLICIT `false` (statted, gone) qualifies a
    ///   candidate; absent (appeared during the await, never statted) or
    ///   `true` (still on disk → a copy) means never adopt.
    func deriveMoveMatch(
        root: String,
        targetRecords: [VideoRecord],
        existingPathsUnderRoot: Set<String>,
        genuinelyGone: [VideoRecord],
        outsideRootCandidateExists: [String: Bool]
    ) -> ScanMergeMoveMatch {
        let protected = relinkProtectedRoots()
        var added: [ScanMergeAddedFile] = []
        for rec in targetRecords where !existingPathsUnderRoot.contains(rec.fullPath) {
            guard !isRelinkProtectedAddedPath(rec.fullPath, protected: protected) else { continue }
            let fp = ScanMergeFingerprint(of: rec)
            if fp.isViable {
                added.append(ScanMergeAddedFile(path: rec.fullPath, fingerprint: fp,
                                                contentHash: rec.contentHash))
            }
        }
        guard !added.isEmpty else { return ScanMergeMoveMatch() }

        var candidates: [ScanMergeMoveCandidate] = []
        for rec in genuinelyGone where !isRelinkProtectedCandidate(rec, protected: protected) {
            let fp = ScanMergeFingerprint(of: rec)
            if fp.isViable {
                candidates.append(ScanMergeMoveCandidate(path: rec.fullPath, fingerprint: fp,
                                                         sameRoot: true, contentHash: rec.contentHash))
            }
        }
        for rec in records {
            guard !PathScope.contains(rec.fullPath, within: root),
                  outsideRootCandidateExists[rec.fullPath] == false,
                  !isRelinkProtectedCandidate(rec, protected: protected) else { continue }
            let fp = ScanMergeFingerprint(of: rec)
            if fp.isViable {
                candidates.append(ScanMergeMoveCandidate(path: rec.fullPath, fingerprint: fp,
                                                         sameRoot: false, contentHash: rec.contentHash))
            }
        }
        guard !candidates.isEmpty else { return ScanMergeMoveMatch() }
        return Self.matchMovedFilesWithAmbiguity(added: added, candidates: candidates)
    }

    /// Adoptions-only convenience (kept for the existing call shape and
    /// tests): see `deriveMoveMatch`.
    func deriveMoveAdoptions(
        root: String,
        targetRecords: [VideoRecord],
        existingPathsUnderRoot: Set<String>,
        genuinelyGone: [VideoRecord],
        outsideRootCandidateExists: [String: Bool]
    ) -> [String: String] {
        deriveMoveMatch(root: root, targetRecords: targetRecords,
                        existingPathsUnderRoot: existingPathsUnderRoot,
                        genuinelyGone: genuinelyGone,
                        outsideRootCandidateExists: outsideRootCandidateExists).adoptions
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
    ///
    /// Update Catalog additions: `originalFullPath` / `originVolume` are
    /// stamped on the FIRST move only (historical provenance — never
    /// overwritten), and one File Journey line is appended so the record's
    /// timeline shows the relink.
    func adoptMovedRecord(old: VideoRecord, fresh: VideoRecord) {
        let oldPath = old.fullPath
        let oldVolume = old.volumeName
        let keep = RescanPreservedFields(from: old)
        old.apply(ProbeOutcome(scanDerivedFrom: fresh))
        keep.apply(to: old)
        if old.originalFullPath == nil {
            old.originalFullPath = oldPath
            old.originVolume = oldVolume
        }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "Reconcile \(stamp): Moved from \(oldPath) to \(old.fullPath) (relinked by Update Catalog)"
        old.notes = old.notes.isEmpty ? line : old.notes + "\n" + line
        moveIdentityLog.info("Relinked \(oldPath, privacy: .public) → \(old.fullPath, privacy: .public)")
    }
}
