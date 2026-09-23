// ArchiveAngelEvidenceStoreTests.swift
// Archive Angel Assessment sidecar — LOGIC (grade bands, candidate set,
// ranking, freshness, summaries), ISOLATION (injected temp directory;
// poisoned / wrong-version / malformed files ignored), SCALE (100k
// records save + load under a Debug ceiling).

import Foundation
import Testing
@testable import VideoScan

private func tempDir(_ label: String) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("test_angel_evidence_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func rec(_ score: Int, rejection: ArchiveAngelRejection? = nil,
                 lines: [String] = [], at: Date = Date()) -> ArchiveAngelEvidenceRecord {
    .init(score: score, lines: lines.map { .init(points: 1, line: $0) }, rejection: rejection,
          useCount: 0, lastUsed: nil, computedAt: at)
}

@Suite("Archive Angel Assessment — grade bands")
struct ArchiveAngelGradeTests {

    @Test("band edges", arguments: [
        (0, ArchiveAngelGrade.x), (1, .d), (24, .d), (25, .c), (59, .c),
        (60, .b), (99, .b), (100, .a), (250, .a), (-5, .x),
    ])
    func edges(score: Int, grade: ArchiveAngelGrade) {
        #expect(ArchiveAngelGrade.from(score: score) == grade)
    }

    @Test("a rejection is X regardless of score; eligible records grade by score")
    func rejectionIsX() {
        #expect(rec(140, rejection: .junk).grade == .x)
        #expect(rec(140).grade == .a)
        #expect(rec(72).isCandidate)
        #expect(!rec(40).isCandidate)
        #expect(rec(40).isEligible)
        #expect(!rec(40, rejection: .tooShort).isEligible)
    }

    @Test("summary lines")
    func summaries() {
        #expect(rec(72, lines: ["★★", "Donna (confirmed)", "Played 14 times", "extra"]).summary()
                == "AAA grade B (72) — ★★ · Donna (confirmed) · Played 14 times")
        #expect(rec(0, rejection: .pairedHalf).summary() == "AAA excluded — " + ArchiveAngelRejection.pairedHalf.rawValue)
        #expect(ArchiveAngelGrade.a.label == "ready")
        #expect(ArchiveAngelGrade.x.label == "excluded")
        #expect(ArchiveAngelGrade.a < ArchiveAngelGrade.d)
    }
}

@Suite("Archive Angel Assessment — store")
struct ArchiveAngelEvidenceStoreTests {

    @Test("candidate set is A+B; eligible ranking is score-desc over A–D")
    @MainActor
    func candidateSetAndRanking() {
        let store = ArchiveAngelEvidenceStore(directory: tempDir("rank"))
        let a = UUID(), b = UUID(), c = UUID(), d = UUID(), x = UUID()
        store.replace(with: .init(considered: 5, eligible: 4, records: [
            a: rec(120), b: rec(70), c: rec(30), d: rec(5), x: rec(0, rejection: .junk),
        ]))
        #expect(store.candidateIDs == [a, b])
        #expect(store.candidateCount == 2)
        #expect(store.eligibleCount == 4)
        #expect(store.rankedEligibleIDs() == [a, b, c, d])
        #expect(store.rejectionCounts() == [.junk: 1])
        #expect(store.gradeCounts() == [.a: 1, .b: 1, .c: 1, .d: 1, .x: 1])
        #expect(store.record(for: c)?.grade == .c)
        #expect(store.record(for: UUID()) == nil)
        store.clear()
        #expect(store.candidateIDs.isEmpty && !store.isLoaded)
    }

    @Test("freshness needs a COMPLETE file within the window")
    @MainActor
    func freshness() {
        let store = ArchiveAngelEvidenceStore(directory: tempDir("fresh"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(!store.isFresh(within: 3600, now: now))
        store.replace(with: .init(computedAt: now.addingTimeInterval(-600), complete: true))
        #expect(store.isFresh(within: 3600, now: now))
        #expect(!store.isFresh(within: 300, now: now))
        store.replace(with: .init(computedAt: now, complete: false))
        #expect(!store.isFresh(within: 3600, now: now), "a checkpoint is never fresh")
    }

    @Test("round-trips through disk atomically; load ignores wrong version + malformed JSON")
    @MainActor
    func roundTripAndPoison() async throws {
        let dir = tempDir("rt")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ArchiveAngelEvidenceStore(directory: dir)
        let id = UUID()
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        store.replace(with: .init(computedAt: at, complete: true, considered: 3, eligible: 1,
                                  records: [id: rec(88, lines: ["★★"], at: at)]))
        #expect(await store.save())
        #expect(FileManager.default.fileExists(atPath: store.fileURL.path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(".evidence.json.tmp").path))

        let again = ArchiveAngelEvidenceStore(directory: dir)
        await again.load()
        #expect(again.file == store.file)
        #expect(again.candidateIDs == [id])
        #expect(again.record(for: id)?.grade == .b)

        // Wrong store version → ignored.
        var poisoned = try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as! [String: Any]
        poisoned["storeVersion"] = 99
        try JSONSerialization.data(withJSONObject: poisoned).write(to: store.fileURL)
        let v99 = ArchiveAngelEvidenceStore(directory: dir)
        await v99.load()
        #expect(!v99.isLoaded)

        // Assessed under older scorer rules → ignored (the sweep re-derives).
        #expect(await store.save())
        var oldRules = try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as! [String: Any]
        oldRules["rulesVersion"] = ArchiveAngelScorer.rulesVersion - 1
        try JSONSerialization.data(withJSONObject: oldRules).write(to: store.fileURL)
        let stale = ArchiveAngelEvidenceStore(directory: dir)
        #expect(await stale.load() == false)
        #expect(!stale.isLoaded)
        // No stamp at all (pre-9/10 file) → ignored too.
        oldRules.removeValue(forKey: "rulesVersion")
        try JSONSerialization.data(withJSONObject: oldRules).write(to: store.fileURL)
        let unstamped = ArchiveAngelEvidenceStore(directory: dir)
        #expect(await unstamped.load() == false)

        // Malformed → ignored.
        try Data("{not json".utf8).write(to: store.fileURL)
        let bad = ArchiveAngelEvidenceStore(directory: dir)
        await bad.load()
        #expect(!bad.isLoaded)

        // Missing directory → save creates it; empty store → save is a no-op.
        let fresh = ArchiveAngelEvidenceStore(directory: dir.appendingPathComponent("deeper/still"))
        #expect(await fresh.save() == false)
    }

    @Test("SENSOR (codex #1345; floor 2026-09-21; S3b 2026-09-22): a v8, v9 or v10 sidecar is ignored (v10 noted for the old → new log); v11 loads")
    @MainActor
    func staleV6SidecarIgnored() async throws {
        let dir = tempDir("v6")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ArchiveAngelEvidenceStore(directory: dir)
        let id = UUID()
        store.replace(with: .init(computedAt: Date(timeIntervalSince1970: 1_700_000_000), complete: true,
                                  considered: 1, eligible: 1, records: [id: rec(110)]))
        #expect(await store.save())
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as! [String: Any]
        #expect(json["rulesVersion"] as? Int == 11, "this sensor pins the bump; re-pin it on the next rules change")

        json["rulesVersion"] = 8
        try JSONSerialization.data(withJSONObject: json).write(to: store.fileURL)
        let v8 = ArchiveAngelEvidenceStore(directory: dir)
        #expect(await v8.load() == false)
        #expect(!v8.isLoaded && v8.candidateIDs.isEmpty, "a v8 grade must never reach a badge")

        json["rulesVersion"] = 9
        try JSONSerialization.data(withJSONObject: json).write(to: store.fileURL)
        let v9 = ArchiveAngelEvidenceStore(directory: dir)
        #expect(await v9.load() == false, "a v9 sidecar was graded under the 60 s floor")
        #expect(!v9.isLoaded && v9.candidateIDs.isEmpty)

        // S3b (Rick 2026-09-22): v10 graded archiveStage Ready/Master as
        // "already archived" and had no classes — ignored, but remembered
        // so the first v11 sweep logs old → new counts once.
        json["rulesVersion"] = 10
        try JSONSerialization.data(withJSONObject: json).write(to: store.fileURL)
        let v10 = ArchiveAngelEvidenceStore(directory: dir)
        #expect(await v10.load() == false)
        #expect(!v10.isLoaded && v10.candidateIDs.isEmpty)
        #expect(v10.olderRules?.rulesVersion == 10)
        #expect(v10.olderRules?.grades == [.a: 1])

        json["rulesVersion"] = 11
        try JSONSerialization.data(withJSONObject: json).write(to: store.fileURL)
        let v11 = ArchiveAngelEvidenceStore(directory: dir)
        #expect(await v11.load())
        #expect(v11.candidateIDs == [id])
        #expect(v11.olderRules == nil)

        // A real v8 file (records without `familySkips`) fails to decode even
        // with the number forged: the shape itself is the guard. (A
        // `[UUID: Record]` encodes as a flat array of alternating key and
        // value entries, not a JSON object.)
        guard var records = json["records"] as? [Any] else { Issue.record("records shape: \(type(of: json["records"]))"); return }
        var stripped = 0
        for i in records.indices {
            guard var r = records[i] as? [String: Any], r["familySkips"] != nil else { continue }
            r.removeValue(forKey: "familySkips")
            records[i] = r
            stripped += 1
        }
        #expect(stripped == 1)
        json["records"] = records
        try JSONSerialization.data(withJSONObject: json).write(to: store.fileURL)
        #expect(await ArchiveAngelEvidenceStore(directory: dir).load() == false)
    }

    @Test("codex 2026-09-20 #5/#6: the attention stamp and familySkips round-trip through disk")
    @MainActor
    func attentionStampRoundTrips() async throws {
        let dir = tempDir("stamp")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ArchiveAngelEvidenceStore(directory: dir)
        let id = UUID()
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        var r = rec(80, at: at)
        r.familySkips = 1.5
        store.replace(with: .init(computedAt: at, complete: true, considered: 1, eligible: 1, records: [id: r],
                                  attentionRevision: 42, attentionLastEventAt: at.addingTimeInterval(-300)))
        #expect(store.attentionRevision == 42)
        #expect(await store.save())
        let again = ArchiveAngelEvidenceStore(directory: dir)
        #expect(await again.load())
        #expect(again.attentionRevision == 42)
        #expect(again.attentionLastEventAt == at.addingTimeInterval(-300))
        #expect(again.record(for: id)?.familySkips == 1.5)
        #expect(again.file == store.file)
    }

    @Test("codex #1345: revision bumps when the same candidate set is republished with a different grade")
    @MainActor
    func revisionFollowsGradeNotMembership() {
        let store = ArchiveAngelEvidenceStore(directory: tempDir("rev"))
        let a = UUID(), b = UUID()
        let r0 = store.revision
        store.replace(with: .init(considered: 2, eligible: 2, records: [a: rec(120), b: rec(70)]))
        let r1 = store.revision
        #expect(r1 != r0)
        #expect(store.candidateIDs == [a, b])
        // Same A+B membership, but `a` slips from A to B and its summary changes.
        store.replace(with: .init(considered: 2, eligible: 2, records: [a: rec(80, lines: ["★★"]), b: rec(70)]))
        #expect(store.candidateIDs == [a, b], "membership unchanged — the filter publisher would stay silent")
        #expect(store.revision != r1, "…so rows must have their own signal")
        #expect(store.record(for: a)?.grade == .b)
        let r2 = store.revision
        store.clear()
        #expect(store.revision != r2, "forgetting everything is a change too")
    }

    @Test("SCALE: 100k records save + load under 2 s (Debug ceiling)")
    @MainActor
    func scale() async {
        let dir = tempDir("scale")
        defer { try? FileManager.default.removeItem(at: dir) }
        var records: [UUID: ArchiveAngelEvidenceRecord] = [:]
        records.reserveCapacity(100_000)
        let at = Date()
        for i in 0..<100_000 {
            records[UUID()] = i % 7 == 0
                ? rec(0, rejection: .tooShort, at: at)
                : rec(i % 160, lines: ["line one", "line two"], at: at)
        }
        let store = ArchiveAngelEvidenceStore(directory: dir)
        let started = ContinuousClock.now
        store.replace(with: .init(computedAt: at, considered: 100_000, eligible: 85_000, records: records))
        #expect(await store.save())
        let again = ArchiveAngelEvidenceStore(directory: dir)
        await again.load()
        let elapsed = ContinuousClock.now - started
        #expect(again.file?.records.count == 100_000)
        #expect(elapsed < PerformanceLane.debugCeiling(.seconds(2)), "100k save+load took \(elapsed)")
    }
}
