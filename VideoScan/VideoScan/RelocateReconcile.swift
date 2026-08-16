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
//                         (not source, not dest) AND at least one witness
//                         lives on a *safe* host volume (not retired, not
//                         unreliable); catalog-only mark-as-deleted with
//                         audit trail. The source file is never touched.
//
// Bucket E is gated by `skipDupsOnOtherVolumes` (default true). It's the
// critical "failing-drive escape hatch": Mini2TB has 741 records, 739
// duped on MyBook + InternalRaid + Seagate2TB. We don't want to copy
// those 739 onto LaCie — they're already safe elsewhere. Mark them as
// deleted in the catalog with a witness list and let Rick retire the
// drive without burning a full copy cycle.
//
// **Safety filter (added 2026-05-30):** Rick flagged that "backup on
// Mini2TB" isn't reassuring when Mini2TB itself is mid-retirement. A
// witness now must live on a *safe* host volume to count toward Bucket
// E classification — safe = host not retired AND trust != .unreliable.
// Witnesses on degraded volumes are still RECORDED (for the "see all
// matches" disclosure) but cannot by themselves justify classifying the
// record as safelyRedundant. If every witness is degraded, the record
// falls through to Bucket A (must be copied) — the conservative call.
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
//
// ── Sendable boundary (Seam D, VideoRecord-Sendable restructure,
// 2026-06-29) ───────────────────────────────────────────────────────
// The classify pass runs OFF the main actor (a `Task.detached` in
// `runRelocate` and in the RelocateSheet preview), because it does a
// full-volume FS walk + per-record partialMD5 disk reads. To keep the
// non-Sendable `VideoRecord` class off that boundary, the actual logic
// now lives in `reconcilePlan(...)`, which consumes a Sendable
// `[ReconcileRecordInput]` and emits a Sendable, id-keyed `ReconcilePlan`.
// The historical `reconcile(records: [VideoRecord], ...) -> ReconcileResult`
// entry point is preserved verbatim as a thin **main-actor adapter** so
// the existing (exhaustive) reconcile test-suite keeps proving behavior:
// it projects records → inputs, calls `reconcilePlan`, then re-materializes
// the plan against the live records via `materialize(_:scope:)`.
// `ReconcileResult` itself is unchanged (still VideoRecord-bearing) —
// callers map ids back to records on the actor that owns them.

// MARK: - VideoRecord-bearing result (consumed on the owning actor)

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
    /// source nor the destination, AND at least one witness lives on a
    /// safe host volume (see `WitnessSafety`). Catalog-only mutation —
    /// file on the failing source drive is NEVER touched. Witnesses
    /// list capped to keep notes / audit log small; full count carried
    /// separately.
    var safelyRedundant: [SafelyRedundantEntry]

    /// Records under `sourceVolumeRootPath` but already relocated once
    /// (`originalFullPath != nil`), short-circuited without further
    /// classification. Only populated when the run's `skipAlreadyRelocated`
    /// option is true (the default): with the option false the classify
    /// pass sends these records through the normal bucket cascade instead
    /// (force-retry, QA fix 2026-07-01), so this bucket comes back empty.
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

/// One witness and its host-volume safety attestation. The "is this
/// reassuring?" decision is computed by the caller (it knows the
/// project-wide role/trust taxonomy) and passed in via the resolver
/// closure. Sorted-ranked use of this struct lives in the summary sheet.
///
/// `Equatable` so `SafelyRedundantEntry`'s synthesized equality keeps
/// working; `Sendable` so it can ride out of the detached classify pass
/// on a `ReconcilePlan` (Seam D). `Codable`-free because the audit-trail
/// note keeps the path list in a flat, hand-tokenized format (see
/// `formatSafelyRedundantNote`).
struct SafeWitnessInfo: Equatable, Hashable, Sendable {
    let path: String
    /// Volume role from the host scan target, or `.unassigned` when the
    /// path doesn't resolve to a known target (the resolver should never
    /// crash on unknown paths — just hand back unassigned/unknown).
    let role: VolumeRole
    let trust: VolumeTrust
    /// Host volume retired (`CatalogScanTarget.isRetired`, i.e. `retiredAt`
    /// stamped). Retirement is a lifecycle event, not a role (taxonomy
    /// cleanup 2026-08-16) — so it rides alongside role/trust here.
    /// Defaulted so the memberwise init keeps its historical shape.
    var isRetired: Bool = false

    /// Single combined safety score, used by the summary sheet to rank
    /// witnesses. Role dominates trust at the 10x weighting documented
    /// below. C++ analogue: a struct with a `<` operator that lexicographic-
    /// sorts on (role, trust). We pre-compute the int here so SwiftUI's
    /// sorted(by:) can compare ints, not run the switch each comparison.
    /// A retired host scores 0 on the role axis — same rank the old
    /// `.retired` role occupied.
    var safetyScore: Int { (isRetired ? 0 : roleScore) * 10 + trustScore }

    /// "Safe enough to count toward Bucket E classification." Conservative:
    /// a Cloud volume marked Unreliable is NOT safe, a RETIRED host is
    /// never safe (a shelved disk must never authorize a destructive
    /// disposition), and an Unassigned/Unknown volume IS safe by default
    /// (we don't punish a witness for never being categorized —
    /// fix-with-data, not rule-out). ONE definition: `VolumeSafety.isSafe`.
    var isSafe: Bool {
        VolumeSafety(role: role, trust: trust, isRetired: isRetired).isSafe
    }

    var roleScore: Int {
        switch role {
        case .cloud:      return 6
        case .archive:    return 5
        case .backup:     return 4
        case .workspace:  return 3
        case .system:     return 2
        case .unassigned: return 1
        }
    }

    var trustScore: Int {
        switch trust {
        case .reliable:   return 3
        case .aging:      return 2
        case .unknown:    return 1
        case .unreliable: return 0
        }
    }
}

/// One safely-redundant entry: which record, where the copies live (capped),
/// and the total count of witnesses (so the UI can say "and N more").
///
/// `safeWitnesses` is the rank-ordered subset that passed the safety filter.
/// `degradedWitnesses` is the rest (retired/unreliable hosts), kept for the
/// "show all matches" disclosure but never used to justify classification.
/// `witnesses` (string array) is what gets written into the audit-trail
/// note — keep it as path strings for backward-compatible parsing.
struct SafelyRedundantEntry: Equatable {
    let rec: VideoRecord
    /// Witness `fullPath` values on volumes other than source + dest. Capped
    /// at `maxWitnessSample` (5) to keep audit-trail notes from ballooning.
    /// Sorted by safety score descending so the audit log + summary sheet
    /// both lead with the safest witness.
    let witnesses: [String]
    /// Full witness count BEFORE the cap (safe + degraded). UI: "and N more
    /// witnesses".
    let totalWitnessCount: Int
    /// Safe witnesses with their host-volume attestations attached. Capped
    /// at `maxWitnessSample` and sorted highest safety score first. Drives
    /// the summary-sheet primary list.
    let safeWitnesses: [SafeWitnessInfo]
    /// Degraded witnesses (retired or unreliable hosts). Capped at
    /// `maxWitnessSample`. Hidden by default; surfaced under a "See all
    /// matches" disclosure.
    let degradedWitnesses: [SafeWitnessInfo]

    static func == (lhs: SafelyRedundantEntry, rhs: SafelyRedundantEntry) -> Bool {
        lhs.rec.id == rhs.rec.id
            && lhs.witnesses == rhs.witnesses
            && lhs.totalWitnessCount == rhs.totalWitnessCount
            && lhs.safeWitnesses == rhs.safeWitnesses
            && lhs.degradedWitnesses == rhs.degradedWitnesses
    }
}

/// One entry in the size-indexed file lists handed to `reconcile`.
struct ReconcileFileEntry: Equatable, Sendable {
    let path: String
    let size: Int64
}

/// A host volume's safety attestation for one witness path: role
/// (intent), trust (condition), retired (lifecycle). The three concerns
/// have three owners on `CatalogScanTarget`; this value snapshots them
/// together so the reconcile pass and every provenance view agree on ONE
/// `isSafe`. Swift `struct` ≈ C++ POD passed by value.
struct VolumeSafety: Equatable, Hashable, Sendable {
    let role: VolumeRole
    let trust: VolumeTrust
    /// `CatalogScanTarget.isRetired` of the host (retiredAt stamped).
    let isRetired: Bool

    init(role: VolumeRole, trust: VolumeTrust, isRetired: Bool = false) {
        self.role = role
        self.trust = trust
        self.isRetired = isRetired
    }

    /// Neutral answer for a path that resolves to no known scan target:
    /// unassigned/unknown/not-retired — counts as *safe* by default.
    static let unknown = VolumeSafety(role: .unassigned, trust: .unknown)

    /// THE definition of a safe host (codex R1-B2): not retired AND not
    /// unreliable. Role no longer participates — `.retired` is gone from
    /// `VolumeRole` (2026-08-16); a shelved disk is identified only by
    /// its `retiredAt` stamp and must never authorize a destructive
    /// disposition.
    var isSafe: Bool { !isRetired && trust != .unreliable }
}

/// Caller-supplied resolver from a witness `fullPath` to its host volume's
/// safety attestation. The real model implementation walks `scanTargets`
/// to find the prefix match; tests inject a synthetic dictionary. Returns
/// `VolumeSafety.unknown` when the path doesn't resolve to a known
/// volume — neutral default that keeps the witness *safe* (the role/trust
/// scoring counts unassigned/unknown as low-but-not-zero).
typealias VolumeSafetyResolver = @Sendable (String) -> VolumeSafety

// MARK: - Sendable boundary types (Seam D)

/// Sendable projection of the only `VideoRecord` fields the classify pass
/// reads. Built on the main actor; safe to capture into the detached
/// reconcile task. `id` is the key the result is re-materialized against.
///
/// Swift's `struct` value semantics ≈ a C++ POD passed by value — there is
/// no shared reference for another actor to race on.
struct ReconcileRecordInput: Sendable, Equatable, Identifiable {
    let id: UUID
    let fullPath: String
    let partialMD5: String
    let sizeBytes: Int64
    /// Non-nil ⇒ already relocated once (drives the previouslyRelocated bucket).
    let originalFullPath: String?
}

/// Sendable, id-keyed classification produced by `reconcilePlan`. Mirrors
/// `ReconcileResult` one-for-one but references records by `UUID` instead
/// of by the non-Sendable `VideoRecord`. `materialize(_:scope:)` turns this
/// back into a `ReconcileResult` on the actor that owns the records.
struct ReconcilePlan: Sendable, Equatable {
    var readyIDs: [UUID] = []
    var manuallyDeletedIDs: [UUID] = []
    var sourceSideMoves: [SourceSideMovePlan] = []
    var adopted: [AdoptedPlan] = []
    var safelyRedundant: [SafelyRedundantPlanEntry] = []
    var previouslyRelocatedIDs: [UUID] = []
}

/// Bucket C plan entry: record id + its new in-source path.
struct SourceSideMovePlan: Sendable, Equatable {
    let id: UUID
    let newSourcePath: String
}

/// Bucket D plan entry: record id + the destination path it was found at.
struct AdoptedPlan: Sendable, Equatable {
    let id: UUID
    let destPath: String
}

/// Bucket E plan entry: record id + the witness audit data. Identical
/// payload to `SafelyRedundantEntry` minus the `VideoRecord` reference.
struct SafelyRedundantPlanEntry: Sendable, Equatable {
    let id: UUID
    let witnesses: [String]
    let totalWitnessCount: Int
    let safeWitnesses: [SafeWitnessInfo]
    let degradedWitnesses: [SafeWitnessInfo]
}

// MARK: - VideoRecord projection / re-materialization

extension VideoRecord {
    /// Capture the Sendable subset the reconcile classify pass needs.
    /// Reads `VideoRecord` fields, so call it on the actor that owns the
    /// record (the main actor) before crossing into the detached task.
    var asReconcileInput: ReconcileRecordInput {
        ReconcileRecordInput(
            id: id,
            fullPath: fullPath,
            partialMD5: partialMD5,
            sizeBytes: sizeBytes,
            originalFullPath: originalFullPath
        )
    }
}

enum RelocateReconcile {

    /// Maximum number of witness paths we keep per safely-redundant
    /// record. The total count is preserved separately on the entry,
    /// so audit trails stay bounded but the dashboard can still report
    /// the real witness depth. Swift's `Array.prefix` ≈ C++'s
    /// `std::vector::erase(begin+N, end)` but non-mutating.
    static let maxWitnessSample = 5

    /// Convenience: a resolver that always says (unassigned, unknown) —
    /// used by tests that don't care about the safety filter, and by
    /// the model when it falls back to legacy behavior. Treats every
    /// witness as safe-by-default (Bucket E permissive).
    static let permissiveResolver: VolumeSafetyResolver = { _ in
        VolumeSafety.unknown
    }

    // MARK: - Main-actor adapter (preserves the historical signature)

    /// Classify each in-scope record into one of the five buckets and
    /// return a VideoRecord-bearing `ReconcileResult`.
    ///
    /// As of Seam D (2026-06-29) this is a thin adapter over the Sendable
    /// `reconcilePlan(...)`: it projects the records to `ReconcileRecordInput`
    /// values, runs the classification, and re-materializes the id-keyed
    /// plan against the same `records`. Behavior is byte-identical to the
    /// pre-Seam-D implementation — the existing reconcile test-suite drives
    /// this entry point and proves it. Call this only on the actor that
    /// owns the records; the off-actor callers use `reconcilePlan` directly.
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
    /// - Parameter skipAlreadyRelocated: when true (default), records with
    ///   `originalFullPath != nil` short-circuit into `previouslyRelocated`
    ///   without further classification. When false (force-retry), they
    ///   re-enter the normal bucket cascade so a salvage-failed record can
    ///   be re-attempted; the cascade's dest-first check means a record
    ///   whose copy already sits verified at the destination classifies as
    ///   adopted rather than being re-copied. (QA fix 2026-07-01 — the
    ///   option used to be consumed nowhere, making it a silent no-op.)
    /// - Parameter resolveVolumeSafety: maps a witness path to its host
    ///   volume's `VolumeSafety`. Bucket E now requires at least one
    ///   witness on a *safe* host (not retired AND trust != .unreliable).
    ///   Pass `permissiveResolver` for the legacy permissive behavior.
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
        skipAlreadyRelocated: Bool = true,
        resolveVolumeSafety: VolumeSafetyResolver = permissiveResolver,
        hash: (String) -> String
    ) -> ReconcileResult {
        let plan = reconcilePlan(
            records: records.map(\.asReconcileInput),
            witnesses: allCatalogRecords.map(\.asReconcileInput),
            sourceVolumeRootPath: sourceVolumeRootPath,
            destinationRoot: destinationRoot,
            sourceFiles: sourceFiles,
            destFiles: destFiles,
            skipDupsOnOtherVolumes: skipDupsOnOtherVolumes,
            skipAlreadyRelocated: skipAlreadyRelocated,
            resolveVolumeSafety: resolveVolumeSafety,
            hash: hash
        )
        return materialize(plan, scope: records)
    }

    /// Re-hydrate a Sendable `ReconcilePlan` into a VideoRecord-bearing
    /// `ReconcileResult` by mapping each id back to the live record in
    /// `scope`. Order within every bucket is preserved (plan arrays are
    /// already in classify-iteration order; `compactMap` is order-stable).
    /// Records the plan can't resolve (should be impossible — every bucketed
    /// id came from `scope`) are dropped rather than crashing.
    ///
    /// Call on the actor that owns `scope` (the main actor). All bucket
    /// entries reference *scope* records only — witnesses never appear in a
    /// bucket — so a `scope`-only lookup table is sufficient.
    static func materialize(_ plan: ReconcilePlan,
                            scope: [VideoRecord]) -> ReconcileResult {
        var byID: [UUID: VideoRecord] = [:]
        byID.reserveCapacity(scope.count)
        for rec in scope { byID[rec.id] = rec }   // last-wins on dup id (UUIDs are unique)

        return ReconcileResult(
            ready: plan.readyIDs.compactMap { byID[$0] },
            manuallyDeleted: plan.manuallyDeletedIDs.compactMap { byID[$0] },
            sourceSideMoves: plan.sourceSideMoves.compactMap { entry in
                byID[entry.id].map { (rec: $0, newSourcePath: entry.newSourcePath) }
            },
            adopted: plan.adopted.compactMap { entry in
                byID[entry.id].map { (rec: $0, destPath: entry.destPath) }
            },
            safelyRedundant: plan.safelyRedundant.compactMap { entry in
                byID[entry.id].map { rec in
                    SafelyRedundantEntry(
                        rec: rec,
                        witnesses: entry.witnesses,
                        totalWitnessCount: entry.totalWitnessCount,
                        safeWitnesses: entry.safeWitnesses,
                        degradedWitnesses: entry.degradedWitnesses
                    )
                }
            },
            previouslyRelocated: plan.previouslyRelocatedIDs.compactMap { byID[$0] }
        )
    }

    // MARK: - Sendable classify core (runs off the main actor)

    /// Pure, Sendable-in/Sendable-out classification. Identical bucket logic
    /// to the historical `reconcile`, but it neither reads nor returns a
    /// `VideoRecord` — it works on `ReconcileRecordInput` values and emits an
    /// id-keyed `ReconcilePlan`. This is what the detached reconcile task
    /// calls, keeping the non-Sendable catalog class off the actor boundary.
    ///
    /// - Parameter records: in-scope record projections (under source root).
    /// - Parameter witnesses: projections of the entire catalog, used to
    ///   build the (size, partialMD5) → other-volume witness index for
    ///   Bucket E. Pass `records` itself for no cross-volume check.
    /// All other parameters match `reconcile`.
    /// - Parameter progress: optional per-record progress sink
    ///   `(done, total)` — called every `progressStride` records plus once
    ///   at completion (2026-07-06, Rick's rule: any op that can outlive
    ///   ~15 s shows honest progress, ESPECIALLY behind a modal). Invoked
    ///   on the caller's thread; callers hop to the main actor themselves.
    static func reconcilePlan(
        records: [ReconcileRecordInput],
        witnesses: [ReconcileRecordInput],
        sourceVolumeRootPath: String,
        destinationRoot: URL,
        sourceFiles: [ReconcileFileEntry],
        destFiles: [ReconcileFileEntry],
        skipDupsOnOtherVolumes: Bool,
        skipAlreadyRelocated: Bool = true,
        resolveVolumeSafety: VolumeSafetyResolver = permissiveResolver,
        hash: (String) -> String,
        progress: ((_ done: Int, _ total: Int) -> Void)? = nil
    ) -> ReconcilePlan {

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
        // by `witnesses.count`. No streaming concerns.
        var witnessIndex: [WitnessKey: [String]] = [:]
        if skipDupsOnOtherVolumes {
            let srcPrefix = sourceVolumeRootPath.hasSuffix("/")
                ? sourceVolumeRootPath
                : sourceVolumeRootPath + "/"
            let dstPrefix = destinationRoot.path.hasSuffix("/")
                ? destinationRoot.path
                : destinationRoot.path + "/"
            for other in witnesses {
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

        var plan = ReconcilePlan()

        let progressStride = 25
        var processed = 0

        for rec in records {
            if let progress, processed % progressStride == 0 {
                progress(processed, records.count)
            }
            processed += 1
            // Already-migrated records (originalFullPath != nil — success
            // provenance from a prior hop) short-circuit ONLY when the
            // skipAlreadyRelocated option is on (the default). With the
            // option off (force-retry), they fall through into the normal
            // bucket cascade: a record whose copy is already verified at
            // the planned destination adopts (Bucket D, dest-first — never
            // re-copied), a genuinely salvage-failed one whose source now
            // reads lands in ready (Bucket A) and gets re-attempted, and
            // every safety gate below (hash-verified adoption, Bucket E
            // safe-witness filter) applies unchanged. Previously the
            // short-circuit was unconditional, which made the option a
            // silent no-op AND left these records uncounted so the
            // progress bar stalled short of its total (QA 2026-07-01).
            if skipAlreadyRelocated, rec.originalFullPath != nil {
                plan.previouslyRelocatedIDs.append(rec.id)
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
                plan.adopted.append(AdoptedPlan(id: rec.id, destPath: planned))
                continue
            }
            if let match = findMatch(sizeBytes: rec.sizeBytes,
                                     partialMD5: rec.partialMD5,
                                     candidatesBySize: destIndex,
                                     hash: hash) {
                plan.adopted.append(AdoptedPlan(id: rec.id, destPath: match))
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
            //
            // **Safety filter:** classification only fires when at least
            // one witness lives on a safe host volume. Degraded witnesses
            // (retired or unreliable host) are retained on the entry for
            // the disclosure but cannot by themselves justify Bucket E.
            if !rec.partialMD5.isEmpty, rec.sizeBytes > 0 {
                let key = WitnessKey(size: rec.sizeBytes, md5: rec.partialMD5)
                if let allWitnesses = witnessIndex[key], !allWitnesses.isEmpty {
                    // Resolve every witness once. The resolver result is
                    // bound to its path here so the sort below has the
                    // host attestation in hand.
                    let attested = allWitnesses.map { p -> SafeWitnessInfo in
                        let s = resolveVolumeSafety(p)
                        return SafeWitnessInfo(path: p, role: s.role, trust: s.trust, isRetired: s.isRetired)
                    }
                    // Sorted highest-safety-first. Stable on equal scores
                    // (Swift's sorted is stable in practice on small N).
                    let ranked = attested.sorted { $0.safetyScore > $1.safetyScore }
                    let safe = ranked.filter { $0.isSafe }
                    let degraded = ranked.filter { !$0.isSafe }

                    // Hard gate — at least one safe witness required.
                    // If safe.isEmpty we DON'T `continue` (that'd skip
                    // the A/C/B fallthrough below); we just refuse to
                    // classify as Bucket E and let the rest of the
                    // cascade decide.
                    if !safe.isEmpty {
                        let safeCapped = Array(safe.prefix(maxWitnessSample))
                        let degradedCapped = Array(degraded.prefix(maxWitnessSample))
                        let auditPaths = safeCapped.map(\.path)
                        plan.safelyRedundant.append(SafelyRedundantPlanEntry(
                            id: rec.id,
                            witnesses: auditPaths,
                            totalWitnessCount: allWitnesses.count,
                            safeWitnesses: safeCapped,
                            degradedWitnesses: degradedCapped
                        ))
                        continue
                    }
                    // Otherwise: fall through to A/C/B. The conservative
                    // call — must copy.
                }
            }

            // Bucket A: file still at its recorded path. Verify by hash
            // when the catalog has one stored; size-only otherwise.
            if let bytes = fileSize(at: rec.fullPath),
               bytes == rec.sizeBytes {
                if rec.partialMD5.isEmpty || hash(rec.fullPath) == rec.partialMD5 {
                    plan.readyIDs.append(rec.id)
                    continue
                }
            }

            // Bucket C: same content moved elsewhere on the source.
            if let match = findMatch(sizeBytes: rec.sizeBytes,
                                     partialMD5: rec.partialMD5,
                                     candidatesBySize: sourceIndex,
                                     hash: hash),
               match != rec.fullPath {
                plan.sourceSideMoves.append(SourceSideMovePlan(id: rec.id, newSourcePath: match))
                continue
            }

            // Bucket B: gone with no plausible match anywhere we can see.
            plan.manuallyDeletedIDs.append(rec.id)
        }

        progress?(records.count, records.count)
        return plan
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
    /// `sizeBytes`, return the first whose hash matches `partialMD5`.
    /// Returns nil if catalog has no stored hash AND more than one
    /// same-sized candidate exists (ambiguous — refuse to guess; safer
    /// to fall through to manuallyDeleted).
    private static func findMatch(sizeBytes: Int64,
                                  partialMD5: String,
                                  candidatesBySize: [Int64: [String]],
                                  hash: (String) -> String) -> String? {
        guard let candidates = candidatesBySize[sizeBytes], !candidates.isEmpty else {
            return nil
        }
        if partialMD5.isEmpty {
            // Without a stored hash, only auto-accept when there's
            // exactly one size match — otherwise we'd be guessing.
            return candidates.count == 1 ? candidates[0] : nil
        }
        for path in candidates where hash(path) == partialMD5 {
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
