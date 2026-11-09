// ArchiveAngelSelectFromEvidenceCharacterizationTests.swift
// CHARACTERIZATION ONLY (refactor/angel-select-from-evidence, 2026-11-08):
// pins EVERYTHING `ArchiveAngelJob.selectFromEvidence` answers — the picks in
// order, the overflow, every refusal count, the projections made, the
// computedAt, and when it declines (nil → the job walks) — over 240 seeded
// synthetic evidence files, so splitting the pick into its concepts (the
// band, the past-band arms, the live copy group, the effective class, the
// finish) can be shown to change nothing. The golden file was recorded on the
// unchanged code (dc: `refactor/angel-select-from-evidence`, first commit)
// and is compared line by line.
//
// The scenarios are drawn to reach every branch the pick has: coverage on
// and off (year cap, one per event), copy groups with a Keep, an in-flight
// member, an oversized group (> maxLiveGroupMembers → walk), rows gone or
// newly under a floor live, rows already in a batch, fresh and proposed
// files (the explore arm), thin and stale evidence (attention revision,
// catalog revision, launch token), and counts from 1 to 30.
//
// Re-record (only on purpose, with the reason in the commit): delete the
// golden file and run the suite twice — the first run writes it and fails.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("ArchiveAngelJob.selectFromEvidence — characterization (240 seeded scenarios, golden)", .serialized)
@MainActor
struct ArchiveAngelSelectFromEvidenceCharacterizationTests {

    struct RNG {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func int(_ n: Int) -> Int { Int(next() % UInt64(max(1, n))) }
        mutating func chance(_ percent: Int) -> Bool { int(100) < percent }
        mutating func uuid() -> UUID {
            let a = next(), b = next()
            return withUnsafeBytes(of: (a, b)) { UUID(uuid: $0.load(as: uuid_t.self)) }
        }
    }

    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    static let scenarioCount = 240

    static var goldenURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ArchiveAngel/select_from_evidence.golden.txt")
    }

    /// One scenario → one line: what the pick answered, ids as their index
    /// in the scenario's draw order.
    static func run(seed: UInt64) -> String {
        var rng = RNG(state: seed &* 0x2545_F491_4F6C_DD1D)
        let n = 20 + rng.int(180)
        var ids: [UUID] = []
        var records: [UUID: ArchiveAngelEvidenceRecord] = [:]
        var live: [UUID: ArchiveAngelCandidate] = [:]
        let classes: [ArchiveAngelRecommendationClass] = [.ready, .ready, .ready, .needsDate, .worthALook, .worthALook,
                                                          .notNow, .anotherCopy, .excluded]
        var groupKey: String?
        var groupLeft = 0
        var groupID: UUID?
        let oversized = rng.chance(4)
        var eligible = 0
        for i in 0..<n {
            let id = rng.uuid()
            ids.append(id)
            // Copy groups: runs of 2–4 consecutive records (one run of 70 when oversized).
            if groupLeft == 0, rng.chance(15) || (oversized && i == 5) {
                groupLeft = oversized && i == 5 ? 70 : 2 + rng.int(3)
                groupKey = "g:\(seed):\(i)"
                groupID = rng.uuid()
            }
            let inGroup = groupLeft > 0
            if groupLeft > 0 { groupLeft -= 1 }
            let rejected = rng.chance(8)
            let score = rejected ? 0 : rng.int(160)
            var r = ArchiveAngelEvidenceRecord(score: score, lines: [ArchiveAngelEvidence(points: score, line: "s\(i)")],
                                               rejection: rejected ? .tooShort : nil, useCount: 0, lastUsed: nil,
                                               computedAt: now, timesProposed: rng.chance(30) ? 1 + rng.int(3) : 0,
                                               familySkips: rng.chance(10) ? 1 : 0)
            if !rejected { eligible += 1 }
            r.recommendation = rejected ? .excluded : (inGroup && rng.chance(50) ? .anotherCopy : classes[rng.int(classes.count)])
            r.copyKey = inGroup ? groupKey : nil
            r.year = rng.chance(85) ? 1990 + rng.int(6) : nil
            records[id] = r
            // Live: most project; some are gone, some now fall under a floor.
            guard !rng.chance(5) else { continue }
            let year = r.year ?? 1990
            let date = Date(timeIntervalSince1970: TimeInterval((year - 1970) * 365 * 86_400 + rng.int(300) * 86_400))
            live[id] = ArchiveAngelCandidate(id: id, filename: "v\(i)_\(rng.int(4)).mov",
                                             fullPath: "/Volumes/T/f\(rng.int(6))/v\(i).mov",
                                             durationSeconds: rng.chance(4) ? 30 : 600 + Double(rng.int(6_000)),
                                             starRating: rng.int(4), confirmedPeople: rng.chance(30) ? ["Donna"] : [],
                                             inferredRecordDate: date, inferredDateConfidence: 0.9,
                                             duplicateGroupID: inGroup ? groupID : nil,
                                             attention: rng.chance(20) ? ArchiveAngelAttention(proposed: [now.addingTimeInterval(-86_400)]) : .none,
                                             captureDate: date,
                                             duplicateGroupCount: inGroup ? 3 : 0,
                                             duplicateDisposition: inGroup && rng.chance(30) ? .keep : .none)
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("angel-sfe-char-\(seed)-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ArchiveAngelEvidenceStore(directory: dir)
        let thin = rng.chance(5)
        store.replace(with: ArchiveAngelEvidenceFile(computedAt: now.addingTimeInterval(-3_600), complete: true,
                                                     considered: n, eligible: thin ? 0 : eligible, records: records,
                                                     attentionRevision: 4, attentionLastEventAt: now.addingTimeInterval(-7_200),
                                                     catalogRevision: 9, catalogLaunchToken: "L1"))
        var policy = AngelRecommendationPolicy.builtIn
        switch rng.int(4) {
        case 0: policy.coverage = .off
        case 1: policy.coverage.maxPerYearPerBatch = 1 + rng.int(3); policy.coverage.onePerEvent = false
        case 2: policy.coverage.onePerEvent = true; policy.coverage.maxPerYearPerBatch = 0
        default: break                                  // the built-in coverage rules
        }
        if rng.chance(20) { policy.weights.freshShare = 0.5 }
        let count = 1 + rng.int(30)
        let excluding = Set(ids.filter { _ in rng.chance(6) })
        let staleAttention = rng.chance(5)
        let staleCatalog = rng.chance(5)
        let otherLaunch = rng.chance(3)
        let pick = ArchiveAngelJob.selectFromEvidence(
            store: store, count: count, now: now, policy: policy, excluding: excluding,
            attentionChangedAt: staleAttention ? now : nil, attentionRevision: staleAttention ? 5 : 4,
            catalogRevision: staleCatalog ? 10 : 9, launchToken: otherLaunch ? "L2" : "L1",
            project: { live[$0] })
        let index = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        guard let pick else { return "seed \(seed) n=\(n) count=\(count): nil" }
        let picks = pick.selection.picks.map { "\(index[$0.candidate.id] ?? -1):\($0.score)" }.joined(separator: ",")
        let refused = pick.selection.rejected.sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        return "seed \(seed) n=\(n) count=\(count): picks [\(picks)] overflow \(pick.selection.overflow) "
            + "rejected [\(refused)] projections \(pick.projections) at \(pick.computedAt.timeIntervalSince1970)"
    }

    @Test func everyScenarioAnswersAsRecorded() throws {
        let lines = (1...UInt64(Self.scenarioCount)).map { Self.run(seed: $0) }
        let url = Self.goldenURL
        guard let golden = try? String(contentsOf: url, encoding: .utf8) else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            Issue.record("golden recorded at \(url.path) — run again to compare")
            return
        }
        let expected = golden.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        #expect(expected.count == lines.count)
        for (got, want) in zip(lines, expected) where got != want {
            Issue.record("changed:\n  was: \(want)\n  now: \(got)")
        }
    }

    /// The golden must exercise what it claims to (a scenario mix that only
    /// ever declined, or never declined, would pin little).
    @Test func theScenariosReachDeclinesPicksAndRefusals() {
        let lines = (1...UInt64(Self.scenarioCount)).map { Self.run(seed: $0) }
        let declined = lines.filter { $0.hasSuffix(": nil") }.count
        #expect(declined >= 20 && declined <= Self.scenarioCount - 60, "declined \(declined) of \(lines.count)")
        for reason in ["duplicateOfPick", "inAnotherBatch", "notRecommendedNow", "tooShort"] {
            #expect(lines.contains { $0.contains(reason + "=") }, "no scenario refused a row as \(reason)")
        }
    }
}
