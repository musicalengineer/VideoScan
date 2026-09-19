// ArchiveAngelLoggingAndOrderTests.swift
// Audit P2 items (2026-09-19), under Rick's rule: "tests and LOGGING exist
// for any actions the app takes so we can track down issues and audit
// media journeys".

import Foundation
import Testing
@testable import VideoScan

@Suite("Archive Angel — every action logged; saves in order; notes once")
struct ArchiveAngelLoggingAndOrderTests {
    private func tempRoot(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("test_angel_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
    }

    /// A Skip's background save that lands AFTER a newer loop save must not
    /// overwrite it with the older snapshot.
    @Test func anOlderPlanSnapshotNeverOverwritesANewerOne() async throws {
        let root = tempRoot("order"); defer { try? FileManager.default.removeItem(at: root) }
        var plan = ArchiveAngelPlan(batchDir: root.appendingPathComponent("batch-o").path, requestedCount: 1,
                                    makeLossless: false, entries: [])
        plan.log = ["older"]
        let older = plan
        plan.log = ["older", "newer"]
        let writer = ArchiveAngelPlanWriter()
        #expect(try await writer.write(plan, generation: 2))
        #expect(try await writer.write(older, generation: 1) == false, "stale save dropped")
        #expect(try ArchiveAngelPlanStore.load(batchDir: plan.batchDir).log == ["older", "newer"])
        #expect(try await writer.write(older, generation: 3), "a newer generation writes")
    }

    @Test func aFailedSaveIsLoggedNotSwallowed() {
        var lines: [String] = []
        let plan = ArchiveAngelPlan(batchDir: "/dev/null/not-a-dir/batch-x", requestedCount: 1,
                                    makeLossless: false, entries: [])
        #expect(!ArchiveAngelPlanStore.saveLogged(plan, context: "testing", log: { lines.append($0) }))
        #expect(lines.count == 1 && lines[0].contains("could not save plan.json for batch-x (testing)"), "\(lines)")
    }

    @Test func whyAPickedFileCannotBePreparedIsNamed() {
        typealias J = ArchiveAngelJob
        #expect(J.unpreparableReason(recordPresent: true, sourceExists: true, sourcePath: "/v/a.mov") == nil)
        #expect(J.unpreparableReason(recordPresent: false, sourceExists: true, sourcePath: "/v/a.mov")?
                .contains("catalog record was removed") == true)
        #expect(J.unpreparableReason(recordPresent: true, sourceExists: false, sourcePath: "/v/a.mov")?
                .contains("isn't at /v/a.mov any more") == true)
    }

    @Test func aReviewNoteIsCarriedToTheCatalogOnce() {
        typealias S = ArchiveAngelReviewSheet
        #expect(S.mergedNotes(existing: "", adding: "Grandma's 80th") == "Grandma's 80th")
        let once = S.mergedNotes(existing: "Shot by Dad", adding: "Grandma's 80th")
        #expect(once == "Shot by Dad\nGrandma's 80th")
        #expect(S.mergedNotes(existing: once, adding: "Grandma's 80th") == once, "a retry adds nothing")
        #expect(S.mergedNotes(existing: once, adding: "  ") == once)
    }

    /// Sensor: the job and the promoter each have ONE log verb and no
    /// silent plan save.
    @Test func sensorOneLogVerbAndNoSwallowedSaves() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VideoScan")
        for file in ["ArchiveAngelJob.swift", "ArchiveAngelPromoter.swift", "ArchiveAngelReviewSheet.swift",
                     "ArchiveAngelReadyDisclosure.swift", "ArchiveView.swift", "ArchiveAngelPlan.swift"] {
            let src = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
            #expect(!src.contains("try? ArchiveAngelPlanStore.save("), "\(file): a swallowed plan save")
            #expect(!src.contains("try? save(plan)"), "\(file): a swallowed plan save")
            #expect(!src.contains("try? await Self.savePlanOffMain"), "\(file): a swallowed plan save")
        }
        let job = try String(contentsOf: dir.appendingPathComponent("ArchiveAngelJob.swift"), encoding: .utf8)
        #expect(!job.contains("model.log("), "every job line goes through note()")
    }
}
