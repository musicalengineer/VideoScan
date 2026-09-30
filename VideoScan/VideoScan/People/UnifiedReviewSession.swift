// UnifiedReviewSession.swift
// Pure types + policy for the unified Review session (feature/unified-review,
// Rick-approved 2026-07-27 — docs/design/unified-review.md).
//
// ONE "Review <name>" entry point walks a single session:
//   phase 1 — sealed blind holdout rows (yes/no → sealed CSV only), then
//   phase 2 — pfConfirmRound candidates (4-tier → validation store + catalog).
//
// This file is the CONTRACT layer the sensors bite on. Three guarantees
// live here, enforced at the type level so a naive future merge of the two
// flows fails loudly instead of silently cross-contaminating:
//
//   1. BLINDNESS GATE — candidate scoring (prepareSetup/pfConfirmRound) may
//      run only in the candidate phases (`mayLoadCandidates`), and re-entering
//      the holdout phase requires purging all candidate state
//      (`mustPurgeCandidates`). For holdout rows, prediction data is never
//      LOADED, not merely hidden.
//   2. WRITE-SINK CUSTODY — ReviewWriteRouting.sink(item:answer:) is the only
//      decision point for where an answer goes. Holdout yes/no → sealed CSV,
//      candidate rating → validation store + catalog, mismatched pairing →
//      nil (caller drops the write and logs — never coerces). The two answer
//      schemas are distinct enum cases with NO conversion between them.
//   3. BACK NEVER CROSSES PHASES — holdout answers are editable only within
//      the holdout phase; from the candidate phase, Back stops at the first
//      candidate (`canGoBack`). Crossing back would re-present blind rows in
//      a session whose state now holds model scores.
//
// (Swift `enum` with associated values ≈ C++ tagged union / std::variant —
// the compiler forces an exhaustive switch, which is exactly what makes the
// custody router safe to extend.)

import Foundation

// MARK: - Unified item

/// One reviewable thing in the session queue — either a sealed blind holdout
/// row or a scored labeling candidate. The associated payloads deliberately
/// stay their original types: a holdout item structurally CANNOT carry a
/// score, and a candidate item never carries CSV plumbing.
enum ReviewItem: Equatable {
    case holdout(HoldoutReviewRow)
    case candidate(PersonCandidateScore)

    var fullPath: String {
        switch self {
        case .holdout(let row):       return row.fullPath
        case .candidate(let cand):    return cand.recordPath
        }
    }

    var filename: String {
        switch self {
        case .holdout(let row):       return row.filename
        case .candidate(let cand):    return cand.filename
        }
    }

    /// Blind items must never be rendered alongside prediction/score/signal
    /// data — the POI-leakage contract (team-channel 2026-07-25-1115).
    var isBlind: Bool {
        switch self {
        case .holdout:   return true
        case .candidate: return false
        }
    }
}

// MARK: - Answers (two schemas, no lossy mapping)

/// The two answer vocabularies. Holdout is yes/no (the sealed CSV's
/// vocabulary); candidates use the 4-tier ConfirmRating. There is DELIBERATELY
/// no initializer or function converting one to the other — the grading
/// contract requires the schemas to stay distinct.
enum ReviewAnswer: Equatable {
    /// "yes" / "no" — validity is enforced downstream by
    /// HoldoutReviewQueue.recordAnswer (strict write, lenient read).
    case holdoutConfirm(String)
    case rating(ConfirmRating)
}

// MARK: - Write-sink custody

/// Where an answer is allowed to land. Exactly one sink per legal pairing.
enum ReviewWriteSink: Equatable {
    /// HoldoutReviewQueue.recordAnswer → the sealed CSV. Nothing else —
    /// never validation labels, never catalog people tags.
    case sealedHoldoutCSV
    /// ValidationLabelStore.record + catalogWriteback. Nothing else —
    /// never the sealed CSV.
    case validationStoreAndCatalog
}

enum ReviewWriteRouting {

    /// The single custody decision. `nil` means the pairing is FORBIDDEN
    /// (a rating aimed at a blind row, or a yes/no aimed at a candidate) —
    /// the caller must drop the write and log, never "fix it up".
    static func sink(for item: ReviewItem, answer: ReviewAnswer) -> ReviewWriteSink? {
        switch (item, answer) {
        case (.holdout, .holdoutConfirm):
            return .sealedHoldoutCSV
        case (.candidate, .rating):
            return .validationStoreAndCatalog
        case (.holdout, .rating), (.candidate, .holdoutConfirm):
            return nil
        }
    }
}

// MARK: - Session phases

/// The unified session's phase ladder. `holdout` may be skipped entirely
/// (no pending queue → open straight into `candidateSetup`), and
/// `candidateSetup` can return to `holdout` via "Continue Reviewing"
/// (skipped rows / a reconnected drive) — WITH a candidate purge.
enum ReviewSessionPhase: Equatable {
    case holdout
    case candidateSetup
    case candidateLabeling
    case summary
}

enum ReviewSessionPolicy {

    /// BLINDNESS GATE: candidate scoring / candidate state may exist only in
    /// the candidate phases. While any holdout row can still be presented,
    /// prediction data is never loaded — not merely hidden.
    static func mayLoadCandidates(in phase: ReviewSessionPhase) -> Bool {
        switch phase {
        case .candidateSetup, .candidateLabeling, .summary:
            return true
        case .holdout:
            return false
        }
    }

    /// Entering a phase where candidate state is forbidden requires purging
    /// it first ("Continue Reviewing" back into the blind rows). The re-score
    /// on the next transition costs ~1–2 s; the hard never-LOADED guarantee
    /// is worth it (design note D1).
    static func mustPurgeCandidates(entering phase: ReviewSessionPhase) -> Bool {
        !mayLoadCandidates(in: phase)
    }

    /// BACK-ACROSS-PHASES rule (design note D2): Back is a within-phase
    /// affordance. In the candidate phase, index 0 has no Back — it must NOT
    /// cross into the answered holdout rows, regardless of how many exist.
    static func canGoBack(in phase: ReviewSessionPhase, index: Int) -> Bool {
        switch phase {
        case .holdout, .candidateLabeling:
            return index > 0
        case .candidateSetup, .summary:
            return false
        }
    }

    /// FULL-QUEUE candidate exclusion (blocker fix 2026-07-27; codex #35
    /// applied strictly). EVERY path in the active holdout queue — pending,
    /// skipped, in-flight, write-failed, or durably answered — is barred
    /// from pfConfirmRound output, positives and controls:
    ///   • pending/skipped/in-flight/write-failed rows must never surface
    ///     with signals/scores before durable blind grading, and
    ///   • even durably-answered rows are the SEALED EVAL SET — rating
    ///     them would land eval paths in validation labels and contaminate
    ///     the sampler's seed (QA item-8).
    /// The union of three views closes every window:
    ///   sessionQueue    — this sheet's in-memory copy (covers optimistic
    ///                     in-flight answers that disk hasn't committed);
    ///   diskQueue       — a fresh-from-disk load (covers external edits
    ///                     and rows a truncated memory copy lost);
    ///   discoveredQueue — the badge center's newest queue (covers
    ///                     candidates-only sessions where the queue is
    ///                     fully answered and pendingQueue returned nil).
    /// Paths release only when the active queue itself retires (a newer
    /// dated queue supersedes it, or it has no rows) — then all three
    /// sources stop carrying them.
    static func heldOutExclusionPaths(sessionQueue: HoldoutReviewQueue?,
                                      diskQueue: HoldoutReviewQueue?,
                                      discoveredQueue: HoldoutReviewQueue?) -> Set<String> {
        var paths = Set<String>()
        for q in [sessionQueue, diskQueue, discoveredQueue] {
            guard let q else { continue }
            paths.formUnion(q.rows.map(\.fullPath))
        }
        return paths
    }

    /// FAIL CLOSED (blocker fix 2026-07-27): when the holdout queue fails
    /// to load/reload, the session must NOT proceed to the candidate phase
    /// — with the queue unreadable we cannot know which paths are sealed.
    /// The sheet lands here, shows the load error, and offers retry or
    /// dismiss only. Pinned: this phase forbids candidate loading.
    static var phaseAfterQueueLoadFailure: ReviewSessionPhase { .holdout }

    /// Resolve the full-queue path set to a CONTENT-IDENTITY matcher
    /// (codex #39, 2026-07-27): blindness is about the media, not the
    /// pathname — a byte-identical or duplicate-group catalog record at a
    /// DIFFERENT path is the same held-out video and must be excluded too.
    /// One pass over `records` to derive identity keys for every held-out
    /// path that has a catalog record; catalog-miss paths keep exact-path
    /// exclusion only (see HeldOutIdentityMatcher's residual-gap note).
    static func heldOutIdentityMatcher(sessionQueue: HoldoutReviewQueue?,
                                       diskQueue: HoldoutReviewQueue?,
                                       discoveredQueue: HoldoutReviewQueue?,
                                       records: [VideoRecord]) -> HeldOutIdentityMatcher {
        HeldOutIdentityMatcher(
            heldOutPaths: heldOutExclusionPaths(sessionQueue: sessionQueue,
                                                diskQueue: diskQueue,
                                                discoveredQueue: discoveredQueue),
            records: records)
    }
}

// MARK: - Held-out content-identity matcher (codex #39)

/// Content-identity exclusion for the active holdout queue. Carries the
/// eval rows' identity KEYS — exact paths plus, for every held-out path
/// the catalog knows, the same duplicate-identity evidence the catalog's
/// own dedup uses (mirroring codex's sampler, which collapses same-bytes
/// and same-stem+size duplicates):
///
///   1. partialMD5        — byte-identical copies across volumes;
///   2. duplicateGroupID  — the DuplicateDetector's same-content verdict;
///   3. stem+size         — conservative fallback (lowercased filename
///                          minus extension, plus exact byte size). Only
///                          built/consulted for sizes > 0, so unknown-size
///                          records can't blanket-match each other.
///
/// RESIDUAL GAP (documented honestly, not pretended closed): a held-out
/// path with NO catalog record contributes only its exact path — we have
/// no evidence from which to derive its content identity, so an
/// un-cataloged copy of that video at another path cannot be recognized.
/// Closing that would require hashing at exclusion time (disk I/O in the
/// scoring path) — out of scope; the gap shrinks as cataloging coverage
/// grows.
///
/// Blindness contract: these are file-identity facts (path/hash/size),
/// the same carve-out as media metadata — no model/detection data.
/// Over-exclusion is safe (a wrongly excluded candidate just waits for
/// the queue to retire); under-exclusion is the breach.
struct HeldOutIdentityMatcher: Sendable, Equatable {
    let paths: Set<String>
    let md5s: Set<String>
    let dupGroupIDs: Set<UUID>
    /// "stem|sizeBytes" keys, lowercased stem, sizes > 0 only.
    let stemSizeKeys: Set<String>

    static let empty = HeldOutIdentityMatcher(paths: [], md5s: [],
                                              dupGroupIDs: [], stemSizeKeys: [])

    init(paths: Set<String>, md5s: Set<String>,
         dupGroupIDs: Set<UUID>, stemSizeKeys: Set<String>) {
        self.paths = paths
        self.md5s = md5s
        self.dupGroupIDs = dupGroupIDs
        self.stemSizeKeys = stemSizeKeys
    }

    /// Derive identity keys from the catalog records of the held-out
    /// paths. One O(records) pass; catalog-miss paths stay path-only.
    init(heldOutPaths: Set<String>, records: [VideoRecord]) {
        var md5s = Set<String>()
        var dgids = Set<UUID>()
        var stemSizes = Set<String>()
        if !heldOutPaths.isEmpty {
            for rec in records where heldOutPaths.contains(rec.fullPath) {
                if !rec.partialMD5.isEmpty { md5s.insert(rec.partialMD5) }
                if let dgid = rec.duplicateGroupID { dgids.insert(dgid) }
                if let key = Self.stemSizeKey(filename: rec.filename,
                                              sizeBytes: rec.sizeBytes) {
                    stemSizes.insert(key)
                }
            }
        }
        self.paths = heldOutPaths
        self.md5s = md5s
        self.dupGroupIDs = dgids
        self.stemSizeKeys = stemSizes
    }

    var isEmpty: Bool {
        paths.isEmpty && md5s.isEmpty && dupGroupIDs.isEmpty && stemSizeKeys.isEmpty
    }

    /// Is this candidate the same MEDIA as a held-out row? Path match
    /// always; identity evidence when the candidate has a catalog record.
    /// Deliberately independent of dedup ordering — every candidate is
    /// checked individually, so a surviving alias can't slip through.
    func matches(path: String, record: VideoRecord?) -> Bool {
        if paths.contains(path) { return true }
        guard let record else { return false }
        if !record.partialMD5.isEmpty, md5s.contains(record.partialMD5) { return true }
        if let dgid = record.duplicateGroupID, dupGroupIDs.contains(dgid) { return true }
        if let key = Self.stemSizeKey(filename: record.filename,
                                      sizeBytes: record.sizeBytes),
           stemSizeKeys.contains(key) { return true }
        return false
    }

    /// nil when size is unknown (≤ 0) — an unknown size is not identity
    /// evidence, and keying on it would let all size-0 records with a
    /// shared stem blanket-exclude each other.
    static func stemSizeKey(filename: String, sizeBytes: Int64) -> String? {
        guard sizeBytes > 0 else { return nil }
        let stem = (filename as NSString).deletingPathExtension.lowercased()
        guard !stem.isEmpty else { return nil }
        return "\(stem)|\(sizeBytes)"
    }
}
