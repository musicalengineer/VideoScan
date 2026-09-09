// ArchiveAngelEvidencePickTests.swift
// Archive Angel Assessment → Angel job: the job picks from FRESH, COMPLETE
// evidence with enough eligible records and re-checks the floor per pick;
// anything else → nil (the caller walks). Plus the catalog filter's
// encode/decode round trip for the new Show ▸ Archive candidates case.

import Foundation
import Testing
@testable import VideoScan

@Suite("Archive Angel — picks from evidence")
struct ArchiveAngelEvidencePickTests {

    private func rec(_ score: Int, rejection: ArchiveAngelRejection? = nil, at: Date) -> ArchiveAngelEvidenceRecord {
        .init(score: score, lines: [.init(points: score, line: "why \(score)")], rejection: rejection,
              useCount: 0, lastUsed: nil, computedAt: at)
    }

    @MainActor
    private func store(fresh: Bool = true, complete: Bool = true,
                       records: [UUID: ArchiveAngelEvidenceRecord], now: Date) -> ArchiveAngelEvidenceStore {
        let s = ArchiveAngelEvidenceStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("test_angel_pick_\(UUID().uuidString.prefix(8))"))
        let at = fresh ? now.addingTimeInterval(-1800) : now.addingTimeInterval(-3 * 86_400)
        s.replace(with: .init(computedAt: at, complete: complete, considered: records.count,
                              eligible: records.values.filter { $0.isEligible }.count, records: records))
        return s
    }

    @Test("fresh + enough → top N by stored score, projecting only the ranked heads")
    @MainActor
    func picksFromFresh() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let a = UUID(), b = UUID(), c = UUID(), d = UUID(), x = UUID()
        let s = store(records: [a: rec(150, at: now), b: rec(90, at: now), c: rec(40, at: now),
                                d: rec(10, at: now), x: rec(0, rejection: .junk, at: now)], now: now)
        var projected: [UUID] = []
        let pick = ArchiveAngelJob.selectFromEvidence(store: s, count: 2, now: now) { id in
            projected.append(id)
            return ArchiveAngelCandidate(id: id)
        }
        #expect(pick != nil)
        #expect(pick?.selection.picks.map(\.candidate.id) == [a, b])
        #expect(pick?.selection.picks.map(\.score) == [150, 90])
        #expect(pick?.selection.picks.first?.evidence.first?.line == "why 150")
        #expect(projected == [a, b], "only the ranked heads are projected — never a full walk")
        #expect(pick?.projections == 2)
        #expect(pick?.selection.overflow == 2)
        #expect(pick?.selection.rejected == [.junk: 1])
        #expect(pick?.computedAt == s.computedAt)
    }

    @Test("a pick that fails the floor NOW is skipped and counted; the next head fills in")
    @MainActor
    func refloorsAtPickTime() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let a = UUID(), b = UUID(), c = UUID()
        let s = store(records: [a: rec(150, at: now), b: rec(90, at: now), c: rec(40, at: now)], now: now)
        let pick = ArchiveAngelJob.selectFromEvidence(store: s, count: 2, now: now) { id in
            // `a` was archived since the assessment.
            ArchiveAngelCandidate(id: id, archiveStage: id == a ? .masterAssigned : .none)
        }
        #expect(pick?.selection.picks.map(\.candidate.id) == [b, c])
        #expect(pick?.selection.rejected[.alreadyArchived] == 1)
    }

    @Test("nil → walk: stale, incomplete, too thin, count 0, or a vanished record")
    @MainActor
    func fallsBackToWalk() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let a = UUID(), b = UUID()
        let two = [a: rec(150, at: now), b: rec(90, at: now)]
        #expect(ArchiveAngelJob.selectFromEvidence(store: store(fresh: false, records: two, now: now),
                                                   count: 1, now: now) { .init(id: $0) } == nil)
        #expect(ArchiveAngelJob.selectFromEvidence(store: store(complete: false, records: two, now: now),
                                                   count: 1, now: now) { .init(id: $0) } == nil)
        #expect(ArchiveAngelJob.selectFromEvidence(store: store(records: two, now: now),
                                                   count: 3, now: now) { .init(id: $0) } == nil)
        #expect(ArchiveAngelJob.selectFromEvidence(store: store(records: two, now: now),
                                                   count: 0, now: now) { .init(id: $0) } == nil)
        // Both records vanished from the catalog → not a full batch → walk.
        #expect(ArchiveAngelJob.selectFromEvidence(store: store(records: two, now: now),
                                                   count: 2, now: now) { _ in nil } == nil)
    }
}

@Suite("Archive Angel — catalog filter")
struct ArchiveAngelCatalogFilterTests {

    @Test("Show ▸ Archive candidates round-trips through the persisted filter string and has words + icon")
    func roundTrip() {
        let encoded = CatalogShowingSummary.encode([.archiveCandidates, .notYetArchived])
        #expect(CatalogShowingSummary.decode(encoded) == [.archiveCandidates, .notYetArchived])
        #expect(CatalogShowingSummary.words(for: .archiveCandidates) == "Archive Angel candidates")
        #expect(CatalogViewFilter.archiveCandidates.icon == "sparkles")
        #expect(CatalogViewFilter.allCases.contains(.archiveCandidates))
    }

    @Test("the filter predicate is a Set lookup over grades A+B")
    @MainActor
    func predicate() {
        let store = ArchiveAngelEvidenceStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("test_angel_filter_\(UUID().uuidString.prefix(8))"))
        let a = UUID(), c = UUID()
        store.replace(with: .init(records: [
            a: .init(score: 120, lines: [], rejection: nil, useCount: 0, lastUsed: nil, computedAt: Date()),
            c: .init(score: 30, lines: [], rejection: nil, useCount: 0, lastUsed: nil, computedAt: Date()),
        ]))
        let ids = store.candidateIDs
        #expect(ids.contains(a))
        #expect(!ids.contains(c))
        #expect(!ids.contains(UUID()))
    }
}
