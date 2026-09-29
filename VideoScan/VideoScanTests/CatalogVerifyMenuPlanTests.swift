import Foundation
import Testing
@testable import VideoScan

// Stage-0 static triage R4 (2026-09-29). The Verify Video (and, same
// shape, Verify Audio) context-menu label counted the whole selection
// while the action ran only the verifiable rows: 3 selected, 1 audio-only,
// said "Verify Video (3 Files)" and started 2 jobs. CatalogVerifyMenuPlan
// carries the label, the rows to run and the disabled state as one value.
// Pure: the predicate is injected, no volume or file is touched.

@MainActor
@Suite("Catalog Verify menu — label counts what runs")
struct CatalogVerifyMenuPlanTests {

    private func records(_ n: Int) -> [VideoRecord] {
        (0..<n).map { i in
            let r = VideoRecord()
            r.fullPath = "/Volumes/T/clip\(i).mov"
            return r
        }
    }

    @Test func labelCountsOnlyTheRowsThatWillRun() {
        let recs = records(3)
        let skip = recs[2].id
        let plan = CatalogVerifyMenuPlan(verb: "Verify Video", selection: recs) { $0.id != skip }
        #expect(plan.runnable.count == 2)
        #expect(plan.label == "Verify Video (2 Files)")
        #expect(!plan.isDisabled)
    }

    @Test func oneRunnableOfManyHasNoCount() {
        let recs = records(3)
        let keep = recs[0].id
        let plan = CatalogVerifyMenuPlan(verb: "Verify Audio", selection: recs) { $0.id == keep }
        #expect(plan.label == "Verify Audio")
        #expect(plan.runnable.map(\.id) == [keep])
    }

    @Test func nothingRunnableIsDisabled() {
        let plan = CatalogVerifyMenuPlan(verb: "Verify Video", selection: records(4)) { _ in false }
        #expect(plan.isDisabled)
        #expect(plan.label == "Verify Video")
    }

    @Test func allRunnableCountsAll() {
        let plan = CatalogVerifyMenuPlan(verb: "Verify Video", selection: records(5)) { _ in true }
        #expect(plan.label == "Verify Video (5 Files)")
    }
}
