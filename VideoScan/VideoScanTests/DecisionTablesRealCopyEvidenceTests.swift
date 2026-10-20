// DecisionTablesRealCopyEvidenceTests.swift
// OPT-IN evidence against COPIES of a real catalog.sqlite and
// ignored-content.json (schema v1.11: footage_likeness, the ignore list in
// catalog.sqlite). A no-op unless
// `~/Library/Logs/VideoScan/decision-tables-evidence/request.json` exists:
//   {"database": "<a .backup COPY of catalog.sqlite>",
//    "ignored": "<a COPY of ignored-content.json>", "output": "<result .json>"}
// Everything happens in a sandbox copy of those copies; nothing else is read
// or written. Reports: the ignore-list import (counts in = out), the split
// (multi-digest groups before → after, pairs by strength and source, files
// that LEFT a group and kept nothing — must be 0), and Verify after (red
// findings, the yellow likeness items, tier 5's result).

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Decision tables — real-catalog COPY evidence (opt-in)", .serialized)
@MainActor
struct DecisionTablesRealCopyEvidence {

    struct Request: Decodable { var database: String; var ignored: String?; var output: String }

    @Test(.timeLimit(.minutes(20)))
    func evidence() async throws {
        let requestURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/VideoScan/decision-tables-evidence/request.json")
        guard let data = try? Data(contentsOf: requestURL) else { return }   // opt-in
        let request = try JSONDecoder().decode(Request.self, from: data)
        let scene = try CutoverScene.make("decision_evidence"); defer { scene.cleanup() }
        let fm = FileManager.default
        for name in try fm.contentsOfDirectory(atPath: scene.folder.path) { try fm.removeItem(at: scene.folder.appendingPathComponent(name)) }
        try fm.copyItem(at: URL(fileURLWithPath: request.database), to: scene.databaseURL)
        if let ignored = request.ignored {
            try fm.copyItem(at: URL(fileURLWithPath: ignored), to: scene.folder.appendingPathComponent(IgnoredContentStore.filename))
        }
        try scene.writeLatch()
        let model = scene.model
        model.records = model.loadCatalogAtLaunch()
        model.masterArchive = model.catalogStore.masterArchive
        #expect(model.catalogCutover.isSQLiteAuthority)
        _ = await model.ignoredContentStore.load()
        var result: [String: Any] = ["ignoredLiveAfterLaunch": model.ignoredContentStore.count]
        result["ignoredLog"] = scene.sandbox.catalogLogText().components(separatedBy: "\n").filter { $0.contains("Ignored content:") }
        result["ignoredTable"] = try await ignoredCounts(model)

        let before = groups(model.records)
        let multi = before.filter { digests($0.value) > 1 }
        result["multiDigestGroupsBefore"] = multi.count
        result["dupGroupsBefore"] = before.count
        let outcome = model.splitDuplicateGroupsByFullDigest()
        result["split"] = String(describing: outcome)
        let reloaded = try await scene.sqliteLoad().records.filter { $0.removal == nil }
        let after = groups(reloaded)
        result["multiDigestGroupsAfter"] = after.filter { digests($0.value) > 1 }.count
        result["dupGroupsAfter"] = after.count
        let pairs = try await likeness(model)
        result["pairs"] = pairs.count
        result["pairsBy"] = Dictionary(grouping: pairs, by: { "\($0.likeness.strength)/\($0.likeness.source)" }).mapValues(\.count)
        result["lost"] = lost(multi, reloaded: reloaded, pairs: pairs)
        result["splitLog"] = scene.sandbox.catalogLogText().components(separatedBy: "\n")
            .filter { $0.contains("Split duplicate groups: START") || $0.contains("Split duplicate groups: OUTCOME") }

        let job = VerifyCatalogJob(model: model)
        job.eventsForTesting = []
        job.start()
        await job.task?.value
        if let report = job.report {
            result["verifyRedFindings"] = report.findings.filter(\.needsDecision).count
            result["verifyRedByRule"] = Dictionary(grouping: report.findings.filter(\.needsDecision), by: \.rule).mapValues(\.count)
            result["verifyDigestsAgree"] = report.findings.filter { $0.rule == "duplicateGroupDigestsAgree" }.count
            result["verifyPossibleSameFootage"] = report.findings.filter { $0.rule == "possibleSameFootage" }.count
            result["tier5"] = report.tier(5).map { "\($0.result) · needsDecision \($0.needsDecision) · \($0.summary)" } ?? "none"
            let facts = IntegrityReportFacts.from(report: report)
            result["integrityRow"] = ["needsDecision": facts.needsDecision, "unverified": facts.unverified,
                                      "unverifiedWords": facts.unverifiedWords ?? "", "decisionWords": facts.decisionWords ?? ""]
        }
        let out = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: URL(fileURLWithPath: request.output))
    }

    private func groups(_ rows: [VideoRecord]) -> [UUID: [VideoRecord]] {
        var out: [UUID: [VideoRecord]] = [:]
        for r in rows where r.removal == nil { if let g = r.duplicateGroupID { out[g, default: []].append(r) } }
        return out.filter { $0.value.count > 1 }
    }

    private func digests(_ members: [VideoRecord]) -> Int { Set(members.compactMap { VideoScanModel.storedFullDigest($0) }).count }

    /// Files of an old multi-digest group that are in NO copies group after,
    /// whose content has NO pair, and that are not a different length from
    /// the old keeper — what the split would have lost. Must be 0.
    private func lost(_ multi: [UUID: [VideoRecord]], reloaded: [VideoRecord],
                      pairs: [CatalogRow.FootageLikenessReview]) -> [String: Any] {
        let byID = Dictionary(reloaded.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var paired = Set<String>()
        for p in pairs { paired.insert(p.likeness.digestA); paired.insert(p.likeness.digestB) }
        var lostFiles: [String] = [], differentLength = 0, stillCopies = 0, kept = 0
        for (_, members) in multi {
            let keeper = members.first { $0.duplicateDisposition == .keep } ?? members[0]
            for m in members {
                guard let now = byID[m.id] else { continue }
                if now.duplicateGroupID != nil { stillCopies += 1; continue }
                if let d = VideoScanModel.storedFullDigest(now)?.lowercased(), paired.contains(d) { kept += 1; continue }
                if abs(m.durationSeconds - keeper.durationSeconds) > DuplicateLikeness.durationToleranceLoose { differentLength += 1; continue }
                lostFiles.append(m.filename)
            }
        }
        return ["stillCopies": stillCopies, "keptAsPair": kept, "differentLength": differentLength, "lost": lostFiles.count,
                "lostSamples": Array(lostFiles.prefix(10))]
    }

    private func likeness(_ model: VideoScanModel) async throws -> [CatalogRow.FootageLikenessReview] {
        let repository = try #require(model.catalogCutover.committer?.repository)
        return try await repository.read { reader in
            var out: [CatalogRow.FootageLikenessReview] = []
            try reader.footageLikenessReviews { out.append($0) }
            return out
        }
    }

    private func ignoredCounts(_ model: VideoScanModel) async throws -> [String: Int] {
        let repository = try #require(model.catalogCutover.committer?.repository)
        let counts = try await repository.read { try $0.ignoredCounts() }
        return ["rows": counts.rows, "putBack": counts.putBack, "live": counts.live]
    }
}
