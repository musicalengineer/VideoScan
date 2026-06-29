import Testing
import Foundation
@testable import VideoScan

// MARK: - RelocateReconcilePlanMappingTests
//
// Seam D (VideoRecord-Sendable restructure, 2026-06-29) pins the two new
// boundary mappings introduced when the reconcile classify pass was made
// Sendable-in / Sendable-out:
//
//   1. `VideoRecord.asReconcileInput` — the field projection built on the
//      main actor before crossing into the detached task. Must carry EXACTLY
//      the fields the classify pass reads (id, fullPath, partialMD5,
//      sizeBytes, originalFullPath) and nothing it could accidentally
//      depend on.
//   2. `RelocateReconcile.materialize(_:scope:)` — the result-application
//      mapping that re-hydrates an id-keyed `ReconcilePlan` into a
//      VideoRecord-bearing `ReconcileResult` back on the owning actor.
//      Must preserve per-bucket order, carry the computed path-rewrite
//      values (sourceSideMove `newSourcePath`, adopted `destPath`) and the
//      Bucket-E witness payload, and resolve every id to the SAME record
//      instance.
//
// The exhaustive bucket-logic coverage lives in RelocateReconcileTests
// (which drive the `reconcile([VideoRecord])` adapter that now delegates
// to reconcilePlan + materialize). These tests guard only the new mapping
// seams so a future change to either projection can't silently misroute
// a file move/delete.

@MainActor
struct RelocateReconcilePlanMappingTests {

    private func rec(_ name: String,
                     path: String,
                     size: Int64 = 1024,
                     md5: String = "abc123",
                     originalFullPath: String? = nil) -> VideoRecord {
        let r = VideoRecord()
        r.filename = name
        r.fullPath = path
        r.sizeBytes = size
        r.partialMD5 = md5
        r.originalFullPath = originalFullPath
        return r
    }

    // MARK: - asReconcileInput field extraction

    // regression: seam D — the Sendable projection must mirror exactly the
    // fields the off-actor classify pass reads. Drift here (a field that
    // stops being copied) would silently change bucket classification on a
    // real run while every VideoRecord-level test still passed.
    @Test func asReconcileInput_carriesExactlyTheClassifyFields() {
        let r = rec("clip.mxf",
                    path: "/Volumes/Mini2TB/a/clip.mxf",
                    size: 4096,
                    md5: "HASH-XYZ",
                    originalFullPath: "/Volumes/Old/clip.mxf")
        let input = r.asReconcileInput
        #expect(input.id == r.id)
        #expect(input.fullPath == r.fullPath)
        #expect(input.partialMD5 == r.partialMD5)
        #expect(input.sizeBytes == r.sizeBytes)
        #expect(input.originalFullPath == r.originalFullPath)
    }

    // regression: seam D — a never-relocated record projects nil
    // originalFullPath (drives the previouslyRelocated bucket gate).
    @Test func asReconcileInput_nilOriginalFullPathPreserved() {
        let r = rec("fresh.mxf", path: "/Volumes/Mini2TB/fresh.mxf")
        #expect(r.asReconcileInput.originalFullPath == nil)
    }

    // MARK: - materialize: per-bucket id → record mapping

    // regression: seam D — materialize must route every id back to the SAME
    // record instance, preserve per-bucket order, and carry the computed
    // path-rewrite values for the source-move and adopt buckets unchanged.
    @Test func materialize_routesEveryBucketToItsRecord_preservingOrderAndPaths() {
        let r1 = rec("ready1.mxf", path: "/Volumes/Mini2TB/ready1.mxf")
        let r2 = rec("ready2.mxf", path: "/Volumes/Mini2TB/ready2.mxf")
        let del = rec("gone.mxf", path: "/Volumes/Mini2TB/gone.mxf")
        let moved = rec("moved.mxf", path: "/Volumes/Mini2TB/old/moved.mxf")
        let adoptd = rec("pre.mxf", path: "/Volumes/Mini2TB/pre.mxf")
        let redundant = rec("dup.mxf", path: "/Volumes/Mini2TB/dup.mxf")
        let prev = rec("done.mxf",
                       path: "/Volumes/LaCie/done.mxf",
                       originalFullPath: "/Volumes/Mini2TB/done.mxf")
        let scope = [r1, r2, del, moved, adoptd, redundant, prev]

        let witness = SafeWitnessInfo(path: "/Volumes/MyBook/dup.mxf",
                                      role: .archive, trust: .reliable)
        var plan = ReconcilePlan()
        // Intentionally interleave order so we prove order is preserved
        // per-bucket, not by overall sequence.
        plan.readyIDs = [r2.id, r1.id]   // reversed on purpose
        plan.manuallyDeletedIDs = [del.id]
        plan.sourceSideMoves = [SourceSideMovePlan(id: moved.id,
                                                   newSourcePath: "/Volumes/Mini2TB/sorted/moved.mxf")]
        plan.adopted = [AdoptedPlan(id: adoptd.id, destPath: "/Volumes/LaCie/pre.mxf")]
        plan.safelyRedundant = [SafelyRedundantPlanEntry(
            id: redundant.id,
            witnesses: [witness.path],
            totalWitnessCount: 3,
            safeWitnesses: [witness],
            degradedWitnesses: []
        )]
        plan.previouslyRelocatedIDs = [prev.id]

        let result = RelocateReconcile.materialize(plan, scope: scope)

        // ready: order from the plan (reversed), mapped to the SAME instances.
        #expect(result.ready.map(\.id) == [r2.id, r1.id])
        #expect(result.ready.first === r2)
        #expect(result.ready.last === r1)

        #expect(result.manuallyDeleted.map(\.id) == [del.id])

        // source-side move: record + computed new path both carried through.
        #expect(result.sourceSideMoves.count == 1)
        #expect(result.sourceSideMoves.first?.rec === moved)
        #expect(result.sourceSideMoves.first?.newSourcePath == "/Volumes/Mini2TB/sorted/moved.mxf")

        // adopted: record + dest path carried through.
        #expect(result.adopted.count == 1)
        #expect(result.adopted.first?.rec === adoptd)
        #expect(result.adopted.first?.destPath == "/Volumes/LaCie/pre.mxf")

        // safely redundant: record + full witness payload carried through.
        #expect(result.safelyRedundant.count == 1)
        #expect(result.safelyRedundant.first?.rec === redundant)
        #expect(result.safelyRedundant.first?.witnesses == [witness.path])
        #expect(result.safelyRedundant.first?.totalWitnessCount == 3)
        #expect(result.safelyRedundant.first?.safeWitnesses == [witness])

        #expect(result.previouslyRelocated.map(\.id) == [prev.id])
        #expect(result.previouslyRelocated.first === prev)
    }

    // regression: seam D — an id the plan references but that is absent from
    // `scope` is dropped rather than crashing. Can't happen on a real run
    // (every bucketed id comes from scope), but the mapping must be
    // defensive: a lost record must never abort a relocate batch.
    @Test func materialize_dropsUnknownIDsGracefully() {
        let present = rec("here.mxf", path: "/Volumes/Mini2TB/here.mxf")
        var plan = ReconcilePlan()
        plan.readyIDs = [present.id, UUID()]   // second id not in scope
        let result = RelocateReconcile.materialize(plan, scope: [present])
        #expect(result.ready.map(\.id) == [present.id])
    }

    // regression: seam D — the adapter (reconcile over [VideoRecord]) and the
    // explicit reconcilePlan → materialize composition must agree. Proves the
    // adapter introduced no behavioral skew for the path-rewrite buckets.
    @Test func adapterEqualsPlanThenMaterialize_forSourceMove() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vs-recon-map-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Catalog path is /old/, real file lives at /sorted/ (a source move).
        let r = rec("clip.mov",
                    path: tmp.appendingPathComponent("old/clip.mov").path,
                    size: 4096, md5: "HASH-C")
        let movedPath = tmp.appendingPathComponent("sorted/clip.mov").path
        let dest = URL(fileURLWithPath: "/tmp/no-dest")
        let sourceFiles = [ReconcileFileEntry(path: movedPath, size: 4096)]
        let hash: (String) -> String = { $0 == movedPath ? "HASH-C" : "" }

        let viaAdapter = RelocateReconcile.reconcile(
            records: [r], allCatalogRecords: [r],
            sourceVolumeRootPath: tmp.path, destinationRoot: dest,
            sourceFiles: sourceFiles, destFiles: [],
            skipDupsOnOtherVolumes: false, hash: hash
        )
        let plan = RelocateReconcile.reconcilePlan(
            records: [r.asReconcileInput], witnesses: [r.asReconcileInput],
            sourceVolumeRootPath: tmp.path, destinationRoot: dest,
            sourceFiles: sourceFiles, destFiles: [],
            skipDupsOnOtherVolumes: false, hash: hash
        )
        let viaPlan = RelocateReconcile.materialize(plan, scope: [r])

        #expect(viaAdapter == viaPlan)
        #expect(viaAdapter.sourceSideMoves.first?.newSourcePath == movedPath)
        #expect(viaAdapter.sourceSideMoves.first?.rec.id == r.id)
    }
}
