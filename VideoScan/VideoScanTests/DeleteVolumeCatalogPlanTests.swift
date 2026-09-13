// DeleteVolumeCatalogPlanTests.swift
// Pins the plan-carry contract for Delete Volume Catalog (codex #1417,
// 2026-09-12). The coalesced `scanTargetFacts` projection is allowed to
// be a recompute window stale for the menu's row labels — but the
// destructive path must not trust it. The gesture plans EXACTLY
// (`planTargetRemoval(for:)`), the alert shows the plan's count, the
// confirmation hands the plan back, and `deleteCatalogForTarget(_:plan:)`
// removes that set or refuses with a fresh plan. Never more than shown.
//
//   1. NO CHANGE      — confirm removes exactly the planned ids and count.
//   2. APPEND         — a record appended under the root between plan and
//                       confirm ⇒ refused, nothing removed, fresh plan
//                       carries the new count; confirming the fresh plan
//                       then removes exactly it.
//   3. REPOINT        — Browse… between plan and confirm ⇒ refused, and
//                       the fresh plan describes the NEW root.
//   4. COVERAGE       — another target registered under the root between
//                       plan and confirm shrinks the set ⇒ refused (the
//                       shown count is no longer true either way).
//   4b. IDENTITY      — (codex #1431) the target removed from the list,
//                       replaced by a re-add of the same path, or a plan
//                       applied to a different target ⇒ CANCELLED (the
//                       prompt ends; never re-presented), nothing removed:
//                       deleteScanTarget's orphans stay orphans.
//   5. UNRELATED BUMP — a revision bump that moves no path (an unrelated
//                       save) still applies the shown plan: no needless
//                       re-confirm.
//   6. SCALE SENSOR   — 100k × 20: plan at the gesture within budget; an
//                       append between plan and confirm is refused there
//                       too.
//   7. SOURCE SENSORS — ContentView's alert applies the carried plan (the
//                       plan-taking overload), and both Delete gestures
//                       route through `presentDeleteVolumeCatalog(for:)`;
//                       the prompt's message is pure over the plan.

import Testing
import Foundation
@testable import VideoScan

@Suite(.serialized) @MainActor
struct DeleteVolumeCatalogPlanTests {

    private func makeRecord(_ fullPath: String) -> VideoRecord {
        let r = VideoRecord()
        r.filename = (fullPath as NSString).lastPathComponent
        r.fullPath = fullPath
        r.directory = (fullPath as NSString).deletingLastPathComponent
        r.sizeBytes = 1
        r.partialMD5 = "md5-\(fullPath)"
        return r
    }

    /// A model whose catalog store writes into a throwaway directory —
    /// never the user's Application Support (same convention as
    /// TargetRemovalSafetyTests).
    private func makeModel() throws -> (VideoScanModel, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vs-delplan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: tmp)
        model.scanTargets.removeAll()
        model.records = []
        return (model, tmp)
    }

    private func paths(_ model: VideoScanModel) -> Set<String> {
        Set(model.records.map(\.fullPath))
    }

    // MARK: - 1. No change: exactly the plan

    @Test func noChangeRemovesExactlyThePlannedSet() throws {
        let (model, tmp) = try makeModel()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let a = CatalogScanTarget(searchPath: "/Volumes/A")
        let b = CatalogScanTarget(searchPath: "/Volumes/B")
        model.scanTargets = [a, b]
        let aRecs = (0..<3).map { makeRecord("/Volumes/A/clip\($0).mov") }
        let bRec = makeRecord("/Volumes/B/other.mov")
        model.records = aRecs + [bRec]
        a.phase = .cataloged
        a.lastScannedDate = Date()

        let plan = model.planTargetRemoval(for: a)
        #expect(plan.count == 3)
        #expect(plan.recordIDs == Set(aRecs.map(\.id)))
        #expect(plan.root == "/Volumes/A")
        #expect(plan.keptCoveredByOtherTargets == 0)

        let result = model.deleteCatalogForTarget(a, plan: plan)
        #expect(result == .applied(removed: 3, snapshotPath: nil))
        #expect(paths(model) == ["/Volumes/B/other.mov"])
        #expect(a.phase == .noCatalog)
        #expect(a.lastScannedDate == nil)
    }

    // MARK: - 2. Append between plan and confirm

    @Test func appendUnderRootBetweenPlanAndConfirmIsRefusedThenReplanned() throws {
        let (model, tmp) = try makeModel()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let a = CatalogScanTarget(searchPath: "/Volumes/A")
        model.scanTargets = [a]
        let first = makeRecord("/Volumes/A/clip0.mov")
        model.records = [first]
        a.phase = .cataloged
        let scannedAt = Date()
        a.lastScannedDate = scannedAt

        // The gesture: the user sees "Delete 1 catalog record(s)".
        let plan = model.planTargetRemoval(for: a)
        #expect(plan.count == 1)

        // A live-reload / scan batch lands a second file under the root
        // while the alert is up. (records.didSet bumps the revision.)
        let second = makeRecord("/Volumes/A/clip1.mov")
        model.records.append(second)

        // Confirm: the model must NOT remove 2 when 1 was shown.
        let result = model.deleteCatalogForTarget(a, plan: plan)
        guard case .refusedStale(let current) = result else {
            Issue.record("expected .refusedStale, got \(result)")
            return
        }
        #expect(model.records.count == 2, "a refused plan removes nothing")
        #expect(a.phase == .cataloged, "a refused plan leaves target state untouched")
        #expect(a.lastScannedDate == scannedAt)
        #expect(current.count == 2, "the fresh plan carries the live count")
        #expect(current.recordIDs == [first.id, second.id])

        // Re-confirm the fresh plan: exactly those two, no more.
        let again = model.deleteCatalogForTarget(a, plan: current)
        #expect(again == .applied(removed: 2, snapshotPath: nil))
        #expect(model.records.isEmpty)
        #expect(a.phase == .noCatalog)
    }

    // MARK: - 3. Repoint between plan and confirm

    @Test func repointBetweenPlanAndConfirmIsRefused() throws {
        let (model, tmp) = try makeModel()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let a = CatalogScanTarget(searchPath: "/Volumes/A")
        model.scanTargets = [a]
        let aRec = makeRecord("/Volumes/A/clip.mov")
        let bRecs = (0..<4).map { makeRecord("/Volumes/B/big\($0).mov") }
        model.records = [aRec] + bRecs

        let plan = model.planTargetRemoval(for: a)
        #expect(plan.count == 1)

        // Browse… moves the target to a root with FOUR records.
        #expect(model.repointScanTarget(a, to: "/Volumes/B"))

        let result = model.deleteCatalogForTarget(a, plan: plan)
        guard case .refusedStale(let current) = result else {
            Issue.record("expected .refusedStale, got \(result)")
            return
        }
        #expect(model.records.count == 5, "nothing removed under either root")
        #expect(current.root == "/Volumes/B")
        #expect(current.count == 4)
        #expect(current.recordIDs == Set(bRecs.map(\.id)))
    }

    /// Same as above but with the revision pinned: even if nothing else
    /// bumped `catalogMutationRevision`, a root mismatch alone refuses.
    @Test func rootMismatchAloneRefusesEvenAtTheSameRevision() throws {
        let (model, tmp) = try makeModel()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let a = CatalogScanTarget(searchPath: "/Volumes/A")
        model.scanTargets = [a]
        model.records = [makeRecord("/Volumes/A/clip.mov"), makeRecord("/Volumes/B/clip.mov")]
        let plan = model.planTargetRemoval(for: a)
        // Bypass repointScanTarget's publish on purpose — a plan whose
        // root is not the target's current root is never honest.
        a.searchPath = "/Volumes/B"
        #expect(plan.revision == model.catalogMutationRevision, "precondition: revision did not move")
        let result = model.deleteCatalogForTarget(a, plan: plan)
        guard case .refusedStale(let current) = result else {
            Issue.record("expected .refusedStale, got \(result)")
            return
        }
        #expect(current.root == "/Volumes/B")
        #expect(model.records.count == 2)
    }

    // MARK: - 4. Coverage change between plan and confirm

    @Test func coverageChangeBetweenPlanAndConfirmIsRefused() throws {
        let (model, tmp) = try makeModel()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let volume = CatalogScanTarget(searchPath: "/Volumes/A")
        model.scanTargets = [volume]
        let top = makeRecord("/Volumes/A/top.mov")
        let nested = makeRecord("/Volumes/A/Sub/deep.mov")
        model.records = [top, nested]

        let plan = model.planTargetRemoval(for: volume)
        #expect(plan.count == 2)

        // A folder target under the volume is registered while the alert
        // is up: the volume no longer owns /Sub exclusively.
        model.scanTargets.append(CatalogScanTarget(searchPath: "/Volumes/A/Sub"))

        let result = model.deleteCatalogForTarget(volume, plan: plan)
        guard case .refusedStale(let current) = result else {
            Issue.record("expected .refusedStale, got \(result)")
            return
        }
        #expect(model.records.count == 2)
        #expect(current.count == 1)
        #expect(current.recordIDs == [top.id])
        #expect(current.keptCoveredByOtherTargets == 1)
    }

    // MARK: - 4b. Target identity (codex #1431)

    /// The target is removed from the list while the alert is open.
    /// `deleteScanTarget` keeps its records as orphans; a re-plan against
    /// the stale object would find the same ids under the same root and
    /// delete those orphans. Must CANCEL — never re-present.
    @Test func targetRemovedBetweenPlanAndConfirmIsCancelled() throws {
        let (model, tmp) = try makeModel()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let a = CatalogScanTarget(searchPath: "/Volumes/A")
        let b = CatalogScanTarget(searchPath: "/Volumes/B")
        model.scanTargets = [a, b]
        model.records = [makeRecord("/Volumes/A/clip.mov"), makeRecord("/Volumes/B/clip.mov")]
        a.phase = .cataloged

        let plan = model.planTargetRemoval(for: a)
        #expect(plan.count == 1)

        #expect(model.deleteScanTarget(a), "precondition: removed from the list")
        #expect(model.records.count == 2, "precondition: deleteScanTarget keeps records as orphans")

        let result = model.deleteCatalogForTarget(a, plan: plan)
        guard case .cancelledTargetGone(let reason) = result else {
            Issue.record("expected .cancelledTargetGone, got \(result)")
            return
        }
        #expect(reason.contains("no longer in the scan-targets list"))
        #expect(model.records.count == 2, "the orphans survive")
        #expect(a.phase == .cataloged, "stale target object untouched")
    }

    /// Remove-and-re-add of the same path: a DIFFERENT target with its own
    /// id now owns the root. The old plan must not apply to either object.
    @Test func targetReplacedBySameRootRegistrationIsCancelled() throws {
        let (model, tmp) = try makeModel()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let old = CatalogScanTarget(searchPath: "/Volumes/A")
        model.scanTargets = [old]
        model.records = [makeRecord("/Volumes/A/clip.mov")]
        let plan = model.planTargetRemoval(for: old)
        #expect(plan.count == 1)

        #expect(model.deleteScanTarget(old))
        let replacement = CatalogScanTarget(searchPath: "/Volumes/A")
        model.scanTargets.append(replacement)
        #expect(replacement.id != old.id)

        // Stale object: its id is no longer registered.
        guard case .cancelledTargetGone = model.deleteCatalogForTarget(old, plan: plan) else {
            Issue.record("stale object must be cancelled"); return
        }
        // New object, old plan: id mismatch.
        guard case .cancelledTargetGone = model.deleteCatalogForTarget(replacement, plan: plan) else {
            Issue.record("old plan on the replacement must be cancelled"); return
        }
        #expect(model.records.count == 1, "nothing removed by either attempt")
        #expect(replacement.phase == .noCatalog && replacement.lastScannedDate == nil,
                "replacement target state never touched")
    }

    /// A plan for A applied to B — same-root or not — is cancelled.
    @Test func targetIDMismatchIsCancelled() throws {
        let (model, tmp) = try makeModel()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let a = CatalogScanTarget(searchPath: "/Volumes/A")
        let b = CatalogScanTarget(searchPath: "/Volumes/B")
        model.scanTargets = [a, b]
        model.records = [makeRecord("/Volumes/A/clip.mov"), makeRecord("/Volumes/B/clip.mov")]
        let planA = model.planTargetRemoval(for: a)
        let result = model.deleteCatalogForTarget(b, plan: planA)
        guard case .cancelledTargetGone(let reason) = result else {
            Issue.record("expected .cancelledTargetGone, got \(result)"); return
        }
        #expect(reason.contains("different volume"))
        #expect(model.records.count == 2)
    }

    /// The registered entry for the id must be THIS object — a same-id
    /// impostor (should never happen; belt and suspenders) is cancelled.
    @Test func registeredObjectMustBeTheAppliedObject() throws {
        let (model, tmp) = try makeModel()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let a = CatalogScanTarget(searchPath: "/Volumes/A")
        model.scanTargets = [a]
        model.records = [makeRecord("/Volumes/A/clip.mov")]
        let plan = model.planTargetRemoval(for: a)
        let impostor = CatalogScanTarget(searchPath: "/Volumes/A")
        // Not registered, but claims the same id via the plan.
        let forged = TargetRemovalPlan(targetID: impostor.id, root: plan.root, recordIDs: plan.recordIDs,
                                       keptCoveredByOtherTargets: 0, revision: plan.revision)
        guard case .cancelledTargetGone = model.deleteCatalogForTarget(impostor, plan: forged) else {
            Issue.record("unregistered object must be cancelled"); return
        }
        #expect(model.records.count == 1)
    }

    // MARK: - 5. Unrelated revision bump still applies the shown plan

    @Test func unrelatedRevisionBumpStillAppliesTheShownPlan() throws {
        let (model, tmp) = try makeModel()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let a = CatalogScanTarget(searchPath: "/Volumes/A")
        model.scanTargets = [a]
        let recs = (0..<2).map { makeRecord("/Volumes/A/clip\($0).mov") }
        model.records = recs + [makeRecord("/Volumes/Elsewhere/x.mov")]

        let plan = model.planTargetRemoval(for: a)
        #expect(plan.count == 2)
        // A debounced save of an unrelated in-place edit lands: the
        // revision moves, no path does.
        model.noteCatalogMutated()
        #expect(plan.revision != model.catalogMutationRevision, "precondition: revision moved")

        let result = model.deleteCatalogForTarget(a, plan: plan)
        #expect(result == .applied(removed: 2, snapshotPath: nil),
                "same ids from the same root ⇒ the shown count was still exact; no re-confirm loop")
        #expect(paths(model) == ["/Volumes/Elsewhere/x.mov"])
    }

    // MARK: - 6. Scale sensor

    /// 100k × 20 (Debug budget; the gesture is explicit so O(records)
    /// is the accepted cost — but it must stay a single pass).
    @Test func planAtTheGestureStaysWithinBudgetAtScaleAndRefusesAnAppend() throws {
        let (model, tmp) = try makeModel()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let targets = (0..<20).map { CatalogScanTarget(searchPath: "/Volumes/Perf\($0)") }
        model.scanTargets = targets
        model.records = (0..<100_000).map { i in
            makeRecord("/Volumes/Perf\(i % 20)/dir\(i % 37)/clip\(i).mov")
        }
        let victim = targets[3]

        let start = Date()
        let plan = model.planTargetRemoval(for: victim)
        let elapsed = Date().timeIntervalSince(start)
        print("planTargetRemoval 100k×20: \(String(format: "%.3f", elapsed)) s")
        #expect(plan.count == 5_000)
        #expect(elapsed < 1.0, "one O(records) pass at the gesture (got \(elapsed)s)")

        model.records.append(makeRecord("/Volumes/Perf3/late/arrival.mov"))
        let result = model.deleteCatalogForTarget(victim, plan: plan)
        guard case .refusedStale(let current) = result else {
            Issue.record("expected .refusedStale, got \(result)")
            return
        }
        #expect(current.count == 5_001)
        #expect(model.records.count == 100_001, "nothing removed")
    }

    // MARK: - 7. Source sensors + prompt text

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ rel: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(rel), encoding: .utf8)
    }

    @Test func contentViewAlertAppliesTheCarriedPlan() throws {
        let cv = try source("VideoScan/VideoScan/ContentView.swift")
        #expect(cv.contains("presenting: deleteVolumeCatalogPrompt"),
                "the alert must present the carried prompt, not a bare target")
        #expect(cv.contains("confirmDeleteVolumeCatalog(prompt)"))
        #expect(!cv.contains("scanTargetFacts[target.id]?.records"),
                "the alert must never read the coalesced projection for its count")
        // Only the plan-taking overload may be called from view code; the
        // one-arg live entry is for the unconfirmed bulk paths.
        let pane = try source("VideoScan/VideoScan/CatalogView+ScanTargetsPane.swift")
        #expect(pane.contains("model.deleteCatalogForTarget(prompt.target, plan: prompt.plan)"))
        #expect(pane.contains("model.planTargetRemoval(for: target)"))
        #expect(!cv.contains("model.deleteCatalogForTarget(target)"),
                "ContentView must not call the unplanned overload")
    }

    @Test func bothDeleteGesturesRouteThroughThePlanningPresenter() throws {
        let pane = try source("VideoScan/VideoScan/CatalogView+ScanTargetsPane.swift")
        let table = try source("VideoScan/VideoScan/CatalogView+VolumeTable.swift")
        #expect(pane.contains("presentDeleteVolumeCatalog(for: target)"), "Catalog Options › Delete row")
        #expect(table.contains("presentDeleteVolumeCatalog(for: first)"), "volume context menu › Delete Catalog (single)")
        for stale in ["deleteVolumeCatalogTarget", "showDeleteVolumeCatalogConfirm"] {
            #expect(!pane.contains(stale) && !table.contains(stale),
                    "\(stale) is the pre-#1417 target-only state; must be gone")
        }
    }

    @Test func promptMessageIsPureOverThePlan() {
        let target = CatalogScanTarget(searchPath: "/Volumes/A")
        let plan = TargetRemovalPlan(targetID: target.id, root: "/Volumes/A",
                                     recordIDs: [UUID(), UUID()],
                                     keptCoveredByOtherTargets: 1, revision: 7)
        let fresh = DeleteVolumeCatalogPrompt(target: target, plan: plan, replacedStalePlan: nil)
        #expect(fresh.message.contains("Delete 2 catalog record(s)"))
        #expect(fresh.message.contains("1 record(s) under this path also belong to another scan target"))
        #expect(!fresh.message.contains("changed while this was open"))

        let stale = TargetRemovalPlan(targetID: target.id, root: "/Volumes/A",
                                      recordIDs: [UUID()], keptCoveredByOtherTargets: 0, revision: 5)
        let replan = DeleteVolumeCatalogPrompt(target: target, plan: plan, replacedStalePlan: stale)
        #expect(replan.message.contains("was 1 record(s), now 2"))
        #expect(replan.message.contains("Nothing was deleted"))
    }

    @Test func plansAreEquivalentByIdsAndRootNotByRevision() {
        let id = UUID()
        let ids: Set<UUID> = [UUID(), UUID()]
        let p1 = TargetRemovalPlan(targetID: id, root: "/Volumes/A", recordIDs: ids, keptCoveredByOtherTargets: 0, revision: 1)
        let p2 = TargetRemovalPlan(targetID: id, root: "/Volumes/A", recordIDs: ids, keptCoveredByOtherTargets: 0, revision: 9)
        let p3 = TargetRemovalPlan(targetID: id, root: "/Volumes/B", recordIDs: ids, keptCoveredByOtherTargets: 0, revision: 1)
        #expect(p1.removesSameRecords(as: p2))
        #expect(!p1.removesSameRecords(as: p3))
        #expect(p1 != p2, "Equatable still sees the revision; equivalence is the narrower question")
    }
}
