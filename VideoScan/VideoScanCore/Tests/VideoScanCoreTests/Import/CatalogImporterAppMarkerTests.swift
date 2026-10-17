// CatalogImporterAppMarkerTests.swift
// End to end for Rick's first real dry run (2026-10-17 17:52:41, refused by
// the importer's reading of catalog-audit.json, not by his data): the
// poisoned fixture's audit marker REWRITTEN in the app's exact shape
// (CatalogAuditRunRecord / CatalogAuditRowResult: counts, finishedAt,
// marked, outcome, partial, startedAt, rows[{id, result, detail?, seenOn?}],
// ISO-8601 dates) and the app's exact words, with and without the
// `catalogGeneration` the app records from this fix on. The dry run must
// pass with the same landings the fixture's own marker gives.
//
// The marker the app writes TODAY also lacks `judgedPath` on non-present
// rows (N1); that is the one refusal left after these two fixes, pinned
// here so the next dispatch knows exactly what remains.
// One condition per #expect.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("CatalogImporter — the marker the app writes")
struct CatalogImporterAppMarkerTests {

    typealias Shape = PoisonedCatalogFixture.Shape
    typealias F = PoisonedCatalogFixture

    static let linkDetail = "not at its path, but that is not proof here: a link in the path — not provable — not marked"
    static let olderMarkerNote = "audit generation not recorded (older marker); accepted by time order"

    /// The fixture's audit answers in the app's words. `judgedPath` is the
    /// N1 key the app does not write yet; `withJudgedPath` adds it.
    static func appRows(withJudgedPath: Bool) -> [CatalogJSONValue] {
        var rows: [CatalogJSONValue] = []
        var seen = Set<String>()
        for shape in Shape.allCases {
            let id = F.id(shape)
            guard seen.insert(id).inserted else { continue }
            var row: [String: CatalogJSONValue] = ["id": .string(id)]
            switch shape {
            case .neverSeen:
                continue                                           // no answer: never seen by an audit
            case .deadLink:
                row["result"] = .string("couldNotCheck")
                row["detail"] = .string(linkDetail)
            case .changedSize:
                row["result"] = .string("changed")
                row["detail"] = .string("on disk 1 KB, the catalog says 4 KB")
                row["seenOn"] = .object(["volumeUUID": .string(F.volumeUUID), "mountFrom": .string("/dev/disk9s1"),
                                         "seenAt": .string(CatalogJSONDate(unixSeconds: F.seenAt).text)])
            case .tombstonedWithDigest:
                row["result"] = .string("stillMissing")
                row["detail"] = .string("already marked Missing (in the Trash)")
            default:
                row["result"] = .string("present")
            }
            if withJudgedPath, row["result"] != .string("present") { row["judgedPath"] = .string(F.path(shape)) }
            rows.append(.object(row))
        }
        return rows
    }

    /// catalog-audit.json exactly as `CatalogAuditRunMarker.persist` writes it
    /// (sorted keys, ISO-8601 dates, counts keyed by the app's words).
    static func appMarker(withJudgedPath: Bool, catalogGeneration: Int?) throws -> Data {
        let rows = appRows(withJudgedPath: withJudgedPath)
        var counts: [String: CatalogJSONValue] = [:]
        var tally: [String: Int] = [:]
        for row in rows { tally[row.objectValue?["result"]?.stringValue ?? "", default: 0] += 1 }
        for (word, n) in tally { counts[word] = .int(Int64(n)) }
        counts["planned"] = .int(Int64(rows.count))
        var body: [String: CatalogJSONValue] = [
            "startedAt": .string(CatalogJSONDate(unixSeconds: F.auditStartedAt).text),
            "finishedAt": .string(CatalogJSONDate(unixSeconds: F.auditFinishedAt).text),
            "outcome": .string("completed"), "partial": .bool(false), "counts": .object(counts),
            "marked": .int(1), "rows": .array(rows),
        ]
        if let catalogGeneration { body["catalogGeneration"] = .int(Int64(catalogGeneration)) }
        return try CatalogJSONValue.makeEncoder().encode(CatalogJSONValue.object(body))
    }

    static func scene(withJudgedPath: Bool, catalogGeneration: Int?) throws -> ImporterScene {
        let scene = try ImporterScene.make()
        try scene.overwrite(F.auditFileName, with: try appMarker(withJudgedPath: withJudgedPath, catalogGeneration: catalogGeneration))
        return scene
    }

    @Test func theAppsMarkerWithoutAGenerationPassesTheDryRunByTimeOrder() async throws {
        let scene = try Self.scene(withJudgedPath: true, catalogGeneration: nil)
        defer { scene.remove() }
        let dry = await scene.run(mode: .dryRun)
        let report = try #require(dry.outcome.dryRunReport, Comment(rawValue: "\(dry.outcome)"))
        #expect(report.reconciliation.rowsQuarantine == 12)
        #expect(report.reconciliation.quarantineByReason == ["auditCouldNotCheck": 1, "auditNeverSeen": 1, "noWholeFileDigest": 1, "auditChanged": 1,
                                                             "duplicateId": 2, "fixityDisagree": 1, "tier5Finding": 4, "referenceMovie": 1])
        #expect(report.reconciliation.auditResults == 15)
        #expect(report.reconciliation.line.hasSuffix(Self.olderMarkerNote))
        #expect(scene.sink.lines.last == "OUTCOME dry run passed — nothing written · " + report.reconciliation.line)
    }

    @Test func theAppsMarkerWithItsGenerationPassesTheDryRunWithoutTheNote() async throws {
        let scene = try Self.scene(withJudgedPath: true, catalogGeneration: F.generation)
        defer { scene.remove() }
        let dry = await scene.run(mode: .dryRun)
        let report = try #require(dry.outcome.dryRunReport, Comment(rawValue: "\(dry.outcome)"))
        #expect(report.reconciliation.rowsQuarantine == 12)
        #expect(!report.reconciliation.line.contains("older marker"))
    }

    @Test func theAppsMarkerAtAnotherGenerationIsRefused() async throws {
        let scene = try Self.scene(withJudgedPath: true, catalogGeneration: F.generation + 1)
        defer { scene.remove() }
        let dry = await scene.run(mode: .dryRun)
        #expect(dry.outcome.refusalKinds == [.auditGenerationMismatch])
    }

    @Test func theAppsMarkerLandsEveryRowWithTheAppsWord() async throws {
        let scene = try Self.scene(withJudgedPath: true, catalogGeneration: F.generation)
        defer { scene.remove() }
        let run = await scene.run()
        try #require(run.outcome.reconciliation != nil, Comment(rawValue: "\(run.outcome)"))
        let results = try await scene.read { reader -> [CatalogRow.AuditResult] in
            var out: [CatalogRow.AuditResult] = []
            try reader.auditResults(run: run.runID) { out.append($0) }
            return out
        }
        let trashed = try #require(results.first { $0.jsonRowID == F.id(.tombstonedWithDigest) })
        #expect(trashed.result == .gone)
        #expect(trashed.detail == .object(["detail": .string("already marked Missing (in the Trash)"), "word": .string("stillMissing")]))
        let deadLink = try #require(results.first { $0.jsonRowID == F.id(.deadLink) })
        #expect(deadLink.result == .link)
    }

    /// What is left for the writer: the app's rows carry no `judgedPath`.
    @Test func theMarkerTheAppWritesTodayIsRefusedOnlyForTheJudgedPath() async throws {
        let scene = try Self.scene(withJudgedPath: false, catalogGeneration: nil)
        defer { scene.remove() }
        let dry = await scene.run(mode: .dryRun)
        #expect(dry.outcome.refusalKinds == [.unrepresentableSidecarEntry, .unrepresentableSidecarEntry, .unrepresentableSidecarEntry])
        #expect(dry.outcome.refusals.allSatisfy { $0.words.contains("names no judged path") })
    }
}
