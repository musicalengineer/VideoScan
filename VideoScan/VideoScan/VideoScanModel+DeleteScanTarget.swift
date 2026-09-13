import Foundation

// MARK: - VideoScanModel+DeleteScanTarget
//
// "Delete from list" — companion to §1B Retire Volume. Retire is the
// "drive going on the shelf, data is safely backed up" path; Delete is
// the "this entry was a mistake (orphan, typo, dangling mount that was
// never really a scan target)" path. Real-world driver: `/Volumes/rickb`
// shows up in the Volumes window with 0 catalog records — it's a
// dangling target from a one-time mount that should never have been
// added. Retire is wrong for it (nothing to back up); Delete from list
// is the right call.
//
// Important contract: this removes ONLY the volume from `scanTargets`
// and its parallel UserDefaults entries. Catalog records whose
// `fullPath` is under the deleted volume's `searchPath` are NOT
// touched. They become orphans (no scan-target context) but stay in
// the catalog for history. The UI confirmation alert tells the user
// this explicitly.

extension VideoScanModel {

    /// Remove a scan target from `scanTargets` and clear all of its
    /// per-path UserDefaults dictionaries (dates, phases, roles, trust,
    /// filesystem, mediaTech, purchaseYear, capacity, notes, retire
    /// fields). Catalog records are deliberately left intact.
    ///
    /// Idempotent: calling on a target that's already absent from
    /// `scanTargets` is a no-op (logged at debug level so we still see
    /// the breadcrumb).
    ///
    /// Foot-shooting guard: refuses to delete a target whose `role` is
    /// `.system` OR whose `searchPath` is `"/"` (the root volume). The
    /// Volumes window also disables the menu item for these — this is
    /// the model-level belt-and-suspenders.
    @discardableResult
    func deleteScanTarget(_ target: CatalogScanTarget) -> Bool {
        // Guard: never delete the system volume. The role check covers
        // the explicit case; the "/" path check is a defensive fallback
        // for installs where the role wasn't set yet.
        // Swift's `guard` early-return ~= C++ `if (cond) return false;`.
        guard target.role != .system, target.searchPath != "/" else {
            log("Delete refused: \(target.searchPath) is the system volume.")
            return false
        }

        // Count records still pointing at this path BEFORE we remove
        // the target so the log breadcrumb carries the orphan count.
        let orphanCount = Self.totalRecordsOn(
            volumeRootPath: target.searchPath, in: records
        )
        let displayName = VolumeReachability.displayLabel(forPath: target.searchPath)

        // Remove from the published array. The `ObjectIdentifier`
        // comparison handles the case where two targets share a
        // searchPath (shouldn't happen, but defensive).
        // Swift's `removeAll(where:)` ~= C++ `erase_if(vec, pred)`.
        let beforeCount = scanTargets.count
        scanTargets.removeAll { $0 === target }
        let removed = scanTargets.count < beforeCount

        if !removed {
            log("Delete: target \(target.searchPath) was not in scanTargets list (no-op).")
            return false
        }

        // Persist: rewrite both the path list AND the per-path
        // dictionaries from the updated `scanTargets`. `persistMetadata`
        // builds each dict by iterating `scanTargets` — so the deleted
        // path naturally falls out of every dict in one shot.
        persistScanTargets()
        persistScanDates()
        notifyTargetsChanged()

        log("Volume \(displayName) deleted from scan-targets list (had \(orphanCount) catalog records — kept as orphans).")
        return true
    }
}

// MARK: - Guarded record removal under a target root (2026-07-03)
//
// Safety net for the 2026-07-01 incident: removing two folder targets
// silently deleted 2,720 catalog records including dossier enrichment.
// Every record-removal scoped to a target's root now goes through ONE
// helper that (a) keeps records still covered by ANOTHER registered
// target's root (component-boundary PathScope — a folder target nested
// under a volume target does not own its records exclusively), (b) writes
// a catalog.pre-target-removal.<stamp>.json recovery snapshot before any
// removal larger than the threshold, degrading to NO removal if the
// snapshot cannot be written (same fail-safe contract as the scan-merge
// tripwire), and (c) emits one prominent log line carrying the count.
//
// Plan-then-execute (codex #1417, 2026-09-12): the removal is now two
// halves. `planTargetRemoval(for:)` computes the EXACT record-id set the
// scope owns right now; `removeCatalogRecords(plan:action:)` removes
// exactly that set. The old one-shot `removeCatalogRecords(underTargetRoot:
// action:)` is plan-then-execute in one call and is unchanged for its
// callers (resetTarget, the multi-select and retired-cleanup deletes).
// A confirmation UI plans at the gesture, shows the plan's count, carries
// the plan through the dialog and hands it back — so what was shown is
// what is removed, never what a coalesced projection said a second ago.

/// Outcome of a guarded target-scoped record removal.
struct TargetRecordRemovalOutcome {
    var removed = 0
    /// Records under the root that were KEPT because another registered
    /// scan target's root also covers them.
    var keptCoveredByOtherTargets = 0
    var snapshotPath: String?
    /// True when >threshold records should have been removed but the
    /// safety snapshot could not be written — nothing was removed.
    var degradedNoSnapshot = false
}

/// THE rule for which records a target-scoped removal owns — extracted
/// (codex #1393) so the guarded removal and the Catalog Options menu's
/// "Delete › <volume> (N)" count call the same predicate and can never
/// disagree. Pure value; build once per target, test many paths.
///
///   claims(path)      ⇔ under `root` at a component boundary (PathScope)
///                       AND not under any OTHER registered target root.
///   isUnderRoot(path) ⇔ the first half only — what `removeCatalogRecords`
///                       reports as "kept, covered by other target(s)"
///                       when `claims` is false.
///
/// Only the record's CURRENT `fullPath` is consulted, never its origin
/// path: removal never touched origin paths, so the count must not either.
struct TargetRemovalScope: Sendable {
    let root: PathScope.Root
    /// Every OTHER registered target root that could cover a record.
    /// Retired targets count: retire deliberately keeps records, so
    /// their roots still own them. A root equal to `root` (after
    /// normalization) is not "other".
    let otherRoots: [PathScope.Root]

    init(root: String, allTargetRoots: [String]) {
        let r = PathScope.Root(root)
        self.root = r
        self.otherRoots = allTargetRoots
            .map { PathScope.Root($0) }
            .filter { $0.normalized != r.normalized }
    }

    func isUnderRoot(_ path: String) -> Bool {
        root.contains(path)
    }

    func claims(_ path: String) -> Bool {
        claimsNormalized(PathScope.normalize(path))
    }

    /// `claims` for an already-normalized path (see
    /// `PathScope.Root.containsNormalized`) — the per-target projection
    /// normalizes each record path once for all targets.
    func claimsNormalized(_ p: String) -> Bool {
        guard root.containsNormalized(p) else { return false }
        return !otherRoots.contains { $0.containsNormalized(p) }
    }
}

/// The exact set a target-scoped removal will remove, computed at one
/// instant (codex #1417). A value type (~ a C++ struct passed by value):
/// a UI can hold it across a confirmation dialog and hand it back, and
/// the model can tell whether the catalog has drifted since.
///
/// `recordIDs` — not a count, not a predicate — is the contract: the
/// execute half removes THESE ids and nothing else. A record appended
/// under the root after planning is not in the set and is not removed.
struct TargetRemovalPlan: Equatable, Sendable {
    /// `CatalogScanTarget.id` the plan was made for.
    let targetID: UUID
    /// The target's `searchPath` at plan time. A Browse… re-point between
    /// plan and apply changes this; the apply half must notice.
    let root: String
    /// Exactly the records `TargetRemovalScope(root:allTargetRoots:)`
    /// claimed at plan time.
    let recordIDs: Set<UUID>
    /// Under the root but owned by another registered target — reported,
    /// never removed.
    let keptCoveredByOtherTargets: Int
    /// `catalogMutationRevision` at plan time. Equal at apply ⇒ nothing
    /// that could change the set has happened; unequal ⇒ re-plan and
    /// compare.
    let revision: UInt64

    var count: Int { recordIDs.count }

    /// Same target, same root, same ids — the shown count is still exact.
    /// (Two plans at different revisions can still be equivalent: a
    /// debounced save of an unrelated in-place edit bumps the revision
    /// without moving a single path.)
    func removesSameRecords(as other: TargetRemovalPlan) -> Bool {
        targetID == other.targetID && root == other.root && recordIDs == other.recordIDs
    }
}

/// What the plan-carrying apply did (codex #1417).
enum TargetRemovalPlanApplyResult: Equatable {
    /// The plan was executed as shown.
    case applied(removed: Int, snapshotPath: String?)
    /// Nothing was removed: the catalog changed between plan and apply in
    /// a way that alters the set (append under the root, re-point, a
    /// coverage change from another target). `currentPlan` is a fresh
    /// plan for the caller to re-confirm — never silently executed.
    case refusedStale(currentPlan: TargetRemovalPlan)
    /// Nothing was removed: the >threshold safety snapshot could not be
    /// written (the standing fail-safe degrade).
    case refusedNoSnapshot(wouldRemove: Int)
    /// Nothing was removed and the prompt is OVER — do not re-present
    /// (codex #1431). The target the plan was made for is not the one
    /// being applied to, or is no longer a registered scan target: it
    /// was removed from the list (its records are now orphans that
    /// `deleteScanTarget` deliberately kept) or replaced by a fresh
    /// registration of the same path (a different target with its own
    /// id). Re-planning against a stale target object would find the
    /// same ids under the same root and quietly delete the orphans, so
    /// this is a cancel, never a re-confirm. `reason` is the one-line
    /// message for the user.
    case cancelledTargetGone(reason: String)
}

extension VideoScanModel {

    /// Removals larger than this must land a recovery snapshot first.
    static let targetRemovalSnapshotThreshold = 50

    // MARK: Plan

    /// The exact removal set for `target` RIGHT NOW, by record id. One
    /// O(records) pass on the main actor — acceptable on an explicit
    /// destructive gesture (the Delete row / context-menu item), which is
    /// the only place a confirmation UI should call it. Never call from
    /// a view body; the non-destructive row labels read the cached
    /// `ScanTargetRecordFacts` projection instead.
    func planTargetRemoval(for target: CatalogScanTarget) -> TargetRemovalPlan {
        planTargetRemoval(targetID: target.id, root: target.searchPath)
    }

    /// `planTargetRemoval(for:)` for a root that may not belong to a
    /// registered target (the legacy `removeCatalogRecords(underTargetRoot:)`
    /// callers pass a bare path). `targetID` is only carried for
    /// bookkeeping; the scope is decided by `root` and the CURRENT
    /// `scanTargets` roots.
    func planTargetRemoval(targetID: UUID = UUID(), root: String) -> TargetRemovalPlan {
        // The same scope the Delete menu counts with (codex #1393).
        let scope = TargetRemovalScope(root: root,
                                       allTargetRoots: scanTargets.map(\.searchPath))
        var doomed = Set<UUID>()
        var kept = 0
        for rec in records where scope.isUnderRoot(rec.fullPath) {
            if scope.claims(rec.fullPath) {
                doomed.insert(rec.id)
            } else {
                kept += 1
            }
        }
        return TargetRemovalPlan(targetID: targetID,
                                 root: root,
                                 recordIDs: doomed,
                                 keptCoveredByOtherTargets: kept,
                                 revision: catalogMutationRevision)
    }

    // MARK: Execute

    /// Remove catalog records under `root`, honoring the coverage check,
    /// snapshot tripwire, and fail-safe degrade described above.
    /// `action` names the caller for the log trail ("reset",
    /// "delete catalog", …). Plan-then-execute in one call; the plan is
    /// never seen by a user, so there is nothing to carry.
    @discardableResult
    func removeCatalogRecords(underTargetRoot root: String, action: String) -> TargetRecordRemovalOutcome {
        removeCatalogRecords(plan: planTargetRemoval(root: root), action: action)
    }

    /// Remove EXACTLY `plan.recordIDs` — the ids that are still present;
    /// an id already gone is simply not there to remove. Does NOT
    /// re-derive the set from the root: that is the caller's job via
    /// `applyTargetRemoval(plan:action:)`, which decides whether a stale
    /// plan is still honest. Snapshot tripwire and log trail unchanged.
    @discardableResult
    func removeCatalogRecords(plan: TargetRemovalPlan, action: String) -> TargetRecordRemovalOutcome {
        let root = plan.root
        var outcome = TargetRecordRemovalOutcome()
        outcome.keptCoveredByOtherTargets = plan.keptCoveredByOtherTargets
        let doomed = plan.recordIDs

        guard !doomed.isEmpty else {
            if outcome.keptCoveredByOtherTargets > 0 {
                log("Target \(action) (\(root)): removed 0 record(s) — all \(outcome.keptCoveredByOtherTargets) under this root are still covered by other scan target(s).")
            }
            return outcome
        }

        if doomed.count > Self.targetRemovalSnapshotThreshold {
            outcome.snapshotPath = snapshotCatalog(prefix: "pre-target-removal")
            if outcome.snapshotPath == nil {
                // FAIL SAFE: no recovery copy → no destruction. Mirrors the
                // scan-merge tripwire degrade.
                outcome.degradedNoSnapshot = true
                log("""
                  ⚠️⚠️ TARGET \(action.uppercased()) DEGRADED — \(root)
                  This would remove \(doomed.count) catalog record(s), but the pre-removal safety snapshot could NOT be written.
                  NOTHING was removed. Fix the catalog directory and retry to remove for real.
                  """)
                appLog.write("TARGET \(action.uppercased()) (DEGRADED): could not write catalog.pre-target-removal snapshot; kept all \(doomed.count) record(s) under \(root)")
                return outcome
            }
        }

        let before = records.count
        records.removeAll { doomed.contains($0.id) }
        outcome.removed = before - records.count

        // (b) THE one prominent line — count first, context after.
        let keptNote = outcome.keptCoveredByOtherTargets > 0
            ? " — kept \(outcome.keptCoveredByOtherTargets) record(s) still covered by other scan target(s)"
            : ""
        let snapNote = outcome.snapshotPath.map { " — recovery snapshot: \($0)" } ?? ""
        log("⚠️ Target \(action): removed \(outcome.removed) catalog record(s) under \(root)\(keptNote)\(snapNote)")
        appLog.write("Target \(action) (\(root)): removed \(outcome.removed) record(s), kept \(outcome.keptCoveredByOtherTargets) covered by other targets\(snapNote)")
        return outcome
    }

    /// Apply a plan a user has confirmed (codex #1417). The rule: never
    /// remove more — or other — than the plan the user saw.
    ///
    ///   • Revision unchanged since the plan ⇒ execute the plan.
    ///   • Revision moved ⇒ re-plan against the live catalog. If the fresh
    ///     plan removes the same ids from the same root, the shown count
    ///     was still exact ⇒ execute. Otherwise refuse and hand the fresh
    ///     plan back for a new confirmation.
    ///   • `target.searchPath` no longer equals `plan.root` (Browse…
    ///     re-point) ⇒ refuse the same way, whatever the revision says.
    ///
    /// Callers that reset target state around the removal (see
    /// `deleteCatalogForTarget(_:plan:)`) must do so only on `.applied`.
    func applyTargetRemoval(plan: TargetRemovalPlan,
                            target: CatalogScanTarget,
                            action: String) -> TargetRemovalPlanApplyResult {
        // Identity first (codex #1431): the plan is for ONE registered
        // target. Same id as the object being applied to, and that id is
        // still registered as this very object. A stale object whose
        // registration was removed (or replaced by a re-add of the same
        // path) fails here — its records are orphans now, not this
        // target's to delete.
        let label = VolumeReachability.displayLabel(forPath: plan.root)
        guard target.id == plan.targetID else {
            let reason = "Delete cancelled: the confirmation was for a different volume than \(label). Nothing was deleted."
            log("Target \(action) (\(plan.root)): \(reason)")
            return .cancelledTargetGone(reason: reason)
        }
        guard let registered = scanTargets.first(where: { $0.id == plan.targetID }),
              registered === target else {
            let reason = "Delete cancelled: \(label) is no longer in the scan-targets list. Its catalog records were kept as orphans; nothing was deleted."
            log("Target \(action) (\(plan.root)): \(reason)")
            return .cancelledTargetGone(reason: reason)
        }
        let rootMoved = target.searchPath != plan.root
        if rootMoved || plan.revision != catalogMutationRevision {
            let current = planTargetRemoval(for: target)
            if rootMoved || !current.removesSameRecords(as: plan) {
                log("Target \(action) (\(plan.root)): refused — catalog changed since the confirmation was shown (planned \(plan.count) record(s), now \(current.count) under \(current.root)). Nothing removed; confirm again.")
                return .refusedStale(currentPlan: current)
            }
        }
        let outcome = removeCatalogRecords(plan: plan, action: action)
        if outcome.degradedNoSnapshot {
            return .refusedNoSnapshot(wouldRemove: plan.count)
        }
        return .applied(removed: outcome.removed, snapshotPath: outcome.snapshotPath)
    }
}
