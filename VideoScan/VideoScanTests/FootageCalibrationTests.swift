// FootageCalibrationTests.swift
// Find Similar Footage — READ-ONLY calibration against a COPY of a real
// catalog. Skipped unless the runner is given a copy explicitly:
//
//   TEST_RUNNER_FOOTAGE_CALIBRATION_CATALOG=/private/tmp/…/catalog.json \
//   TEST_RUNNER_FOOTAGE_CALIBRATION_OUT=/private/tmp/…/report.txt \
//   xcodebuild test … -only-testing:VideoScanTests/FootageCalibrationTests
//
// ISOLATION: it refuses any path inside "Application Support" (the live
// catalog), decodes the copy in memory, runs the pure core, and writes
// only the report file named by FOOTAGE_CALIBRATION_OUT. Nothing is saved.
// Like the app, it stats (never reads) each record carrying a stored
// whole-file digest, so "Identical" means what it means in the app
// (codex #1674 F1).

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@Suite("Find Similar Footage — calibration on a catalog COPY (opt-in)", .serialized)
@MainActor
struct FootageCalibrationTests {

    nonisolated static var catalogPath: String? {
        let p = ProcessInfo.processInfo.environment["FOOTAGE_CALIBRATION_CATALOG"] ?? ""
        return p.isEmpty ? nil : p
    }

    @Test("group a copy of the real catalog and write the report", .timeLimit(.minutes(2)),
          .enabled(if: FootageCalibrationTests.catalogPath != nil))
    func calibrate() async throws {
        let path = try #require(Self.catalogPath)
        try #require(!path.contains("Application Support"), "calibrate a COPY, never the live catalog")
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let snap = try dec.decode(CatalogSnapshot.self, from: data)
        let records = snap.records
        var byID: [UUID: VideoRecord] = [:]
        for r in records { byID[r.id] = r }
        for r in records {
            if let pid = r.pendingPairedWithID {
                r.pairedWith = byID[pid]
                r.pendingPairedWithID = nil
                if r.pairedWith == nil { r.pairGroupID = nil; r.pairConfidence = nil }
            }
        }
        let probes = records.compactMap { VideoScanModel.footageFixityProbe($0) }
        let current = await VideoScanModel.footageCurrentDigests(probes) ?? []
        let inputs = VideoScanModel.markCurrentDigests(records.map { FootageInput(record: $0) }, current: current)
        var out = "Find Similar Footage — calibration on \(path)\n"
        out += "records: \(records.count)\n"
        out += "stored whole-file digests: \(probes.count) usable, \(current.count) still current (stat)\n\n"

        let t0 = Date()
        let result = FootageGrouping.run(inputs)
        let elapsed = Date().timeIntervalSince(t0)
        let withHidden = FootageGrouping.run(inputs, options: .init(includeHidden: true))
        out += Self.statsBlock("VISIBLE records (purged / set aside / superseded excluded — what the app does)",
                               result, elapsed: elapsed)
        out += Self.statsBlock("ALL records (hidden included, for comparison)", withHidden, elapsed: nil)

        // Biggest groups.
        out += "\n== 12 biggest groups (visible) ==\n"
        for g in result.groups.prefix(12) { out += Self.describe(g, byID: byID, result: result) }

        // Known cases.
        out += "\n== Known cases ==\n"
        let known = ["RickGuitarGravity_etc_2024.mov", "RicksGuitars2024.mov", "RicksGuitars2024.mp4",
                     "DickyTheBoysDadBreen-1985.mp4", "DickyTheBoysDadBreen-1985-3.mp4",
                     "Christmas1990-Part3-47mins"]
        for r in records where known.contains(where: { r.filename.contains($0) }) {
            out += Self.memberLine(r, result.memberships[r.id], label: "visible")
            if result.memberships[r.id] == nil, let h = withHidden.memberships[r.id] {
                out += Self.memberLine(r, h, label: "with hidden")
            }
        }

        // 10 random Likely / Possible groups (seeded, reproducible).
        out += "\n== 10 random Likely / Possible groups (seed 2026) ==\n"
        var rng = CalibrationRNG(seed: 2026)
        // A/V-pair-only groups (the Avid MXF halves) dominate a plain draw;
        // they are listed by count, and the draw is from the rest.
        let avOnly: (FootageGrouping.Group) -> Bool = { g in
            g.reasons.keys.allSatisfy { [.sampledSignature, .recordedDigest, .sameFixity, .avPairHigh, .avPairWeak].contains($0) }
        }
        let likelyOrPossible = result.groups.filter { $0.confidence == .likely || $0.confidence == .possible }
        out += "(\(likelyOrPossible.filter(avOnly).count) of \(likelyOrPossible.count) Likely/Possible groups are A/V pairs + their copies; drawn from the other \(likelyOrPossible.filter { !avOnly($0) }.count))\n"
        var pool = likelyOrPossible.filter { !avOnly($0) }
        var picked: [FootageGrouping.Group] = []
        while picked.count < 10, !pool.isEmpty {
            picked.append(pool.remove(at: Int(rng.next() % UInt64(pool.count))))
        }
        for g in picked { out += Self.describe(g, byID: byID, result: result) }

        out += "\n== Possible groups (all, up to 30) ==\n"
        for g in result.groups.filter({ $0.confidence == .possible }).prefix(30) {
            out += Self.describe(g, byID: byID, result: result)
        }

        if let outPath = ProcessInfo.processInfo.environment["FOOTAGE_CALIBRATION_OUT"], !outPath.isEmpty,
           !outPath.contains("Application Support") {
            try out.write(toFile: outPath, atomically: true, encoding: .utf8)
        }
        print(out)
        #expect(result.stats.largestGroup <= FootageGrouping.defaultCap || result.groups.first?.confidence == .identical)
    }

    static func statsBlock(_ title: String, _ r: FootageGrouping.Result, elapsed: TimeInterval?) -> String {
        let s = r.stats
        var t = "== \(title) ==\n"
        t += "considered \(s.considered) of \(s.inputs); groups \(s.groups); members \(s.members); largest \(s.largestGroup)\n"
        t += "by confidence: " + FootageConfidence.allCases.map { "\($0.label) \(s.groupsByConfidence[$0] ?? 0)" }
            .joined(separator: " · ") + "\n"
        t += "original not in catalog: \(s.originalNotInCatalog) groups\n"
        t += "edges generated: " + FootageGrouping.Reason.allCases.compactMap { r in
            s.edgesByReason[r].map { "\(r.rawValue) \($0)" } }.joined(separator: ", ") + "\n"
        t += "links accepted: " + FootageGrouping.Reason.allCases.compactMap { r in
            s.acceptedByReason[r].map { "\(r.rawValue) \($0)" } }.joined(separator: ", ") + "\n"
        t += "refused: cap \(s.refusedByCap), possible-chain \(s.refusedPossibleChain), person \(s.refusedByPerson), "
            + "sampled-hash conflicts \(s.sampledConflicts), full-hash conflicts \(s.fullHashConflicts), "
            + "different dates \(s.refusedByDate)\n"
        t += "name window: \(s.windowExamined) candidates examined\n"
        if let e = elapsed { t += String(format: "grouping time: %.3f s (Debug)\n", e) }
        return t + "\n"
    }

    static func describe(_ g: FootageGrouping.Group, byID: [UUID: VideoRecord],
                         result: FootageGrouping.Result) -> String {
        var t = "- \(g.memberIDs.count) files, \(g.confidence.label)"
            + (g.originalInCatalog ? "" : ", original NOT in catalog")
            + " — links: " + g.reasons.sorted { $0.key < $1.key }.map { "\($0.key.rawValue)×\($0.value)" }
                .joined(separator: " ") + "\n"
        for id in g.memberIDs.prefix(6) {
            guard let r = byID[id], let m = result.memberships[id] else { continue }
            t += "    [\(m.rank)] \(m.role.label): \(r.filename)  (\(VolumeReachability.displayLabel(forPath: r.fullPath)), "
                + String(format: "%.2f s", r.durationSeconds) + ")\n"
            if let first = m.evidence.first(where: { !$0.hasPrefix("likely original") }) ?? m.evidence.first {
                t += "        · \(first)\n"
            }
        }
        if g.memberIDs.count > 6 { t += "    … \(g.memberIDs.count - 6) more\n" }
        return t
    }

    static func memberLine(_ r: VideoRecord, _ m: FootageMembership?, label: String) -> String {
        guard let m else { return "  \(r.filename) [\(r.fullPath)] (\(label)): NOT GROUPED\n" }
        return "  \(r.filename) [\(r.fullPath)] (\(label)): group \(m.groupID.uuidString.prefix(8)) size \(m.groupSize) "
            + "\(m.confidence.label) role=\(m.role.label) rank=\(m.rank) originalInCatalog=\(m.originalInCatalog)\n"
            + m.evidence.map { "      · \($0)\n" }.joined()
    }
}

private struct CalibrationRNG {
    private var state: UInt64
    init(seed: UInt64) { state = seed | 1 }
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
}
