// CatalogCodex141ScopedBaselineTests.swift
// Codex cycle #141, finding 3 (docs/reviews/codex/
// codex-review-catalog-store-consistency-2026-10-25.md): a SCOPED save
// (`commitNow(ids:)` — the removal-marker door, `commitBeforeReplacing`)
// advanced a dirty sibling's per-field baseline to the committed value, so
// the sibling's next delta REMOVED what the other copy had added.
//
//   Step              Copy A      Copy B      B's baseline   Stored
//   both edited       {base,a}    {base,b}    {base}         {base}
//   save A only       {base,a}    {base,b}    {base,a} ←bug  {base,a}
//   save B            —           {base,b}    —              {base,b}  `a` lost
//
// The same baseline serves tags, people and backup attestations (every
// shared SET a copy writes as its own delta — CatalogSetDelta.swift), so the
// one test runs all three.
//
// Red/green (Debug, M4 Max):
//   scopedSavePreservesBothCopiesTagAdditions(tags)          RED  loaded {base,b}      → GREEN {a,b,base}
//   scopedSavePreservesBothCopiesTagAdditions(people)        RED  loaded {base,b}      → GREEN {a,b,base}
//   scopedSavePreservesBothCopiesTagAdditions(attestations)  RED  loaded {base,b}      → GREEN {a,b,base}
// Fix: CatalogCommitBaseline.share(_:onto:) — a copy with its OWN pending
// change to a group keeps its baseline for that group (its next delta is
// taken against what it actually saw); only a clean group takes the
// committed value and moves its baseline.
//
// Dimensions: LOGIC (the three sets, the scoped door then the full one;
// memory, reload and relaunch agree); ISOLATION (CutoverScene sandbox,
// never Application Support); SCALE in Core (CatalogCommitScaleTests —
// the pipeline is unchanged); MEDIA N/A; SENSOR N/A (no new seam).
//
// Suites (filter by SUITE): CatalogScopedSaveBaselineTests

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Catalog scoped save — a dirty sibling keeps its own baseline, so no copy's addition becomes a later removal (codex #141 F3)",
       .serialized)
@MainActor
struct CatalogScopedSaveBaselineTests {

    /// The three shared sets a copy writes as a delta.
    enum SharedSet: String, CaseIterable, Sendable {
        case tags, people, attestations

        /// Put the set named by `labels` onto `record`.
        func set(_ labels: [String], on record: VideoRecord) {
            switch self {
            case .tags:
                record.tags = labels
            case .people:
                record.confirmedByUserPeople = labels.map { ConfirmedTag(name: $0, confirmedAt: Self.stamp($0)) }
            case .attestations:
                record.backupAttestations = labels.map { BackupAttestation(kind: .drive, answer: .yes, label: $0, attestedAt: Self.stamp($0)) }
            }
        }

        /// The labels `record` shows for this set.
        func labels(of record: VideoRecord) -> Set<String> {
            switch self {
            case .tags: return Set(record.tags)
            case .people: return Set(record.confirmedByUserPeople.map(\.name))
            case .attestations: return Set(record.backupAttestations.compactMap(\.label))
            }
        }

        /// One fixed whole-second date per label (the people and attestation
        /// rows are matched on their stamp too).
        private static func stamp(_ label: String) -> Date {
            Date(timeIntervalSince1970: 1_790_500_000 + TimeInterval(label.utf8.reduce(0) { $0 + Int($1) }))
        }
    }

    @Test("codex #141 F3: A {base}→{base,a}, B {base}→{base,b}; save A ONLY (scoped), then save all → the store and every copy hold {base,a,b}; relaunch the same",
          arguments: SharedSet.allCases)
    func scopedSavePreservesBothCopiesTagAdditions(_ set: SharedSet) async throws {
        let scene = try CutoverScene.make("codex141_scoped_\(set.rawValue)")
        defer { scene.cleanup() }
        try await scene.launchOnSQLite()

        let a = try scene.record(.curatedConflictA)
        let b = try scene.record(.curatedConflictB)
        let committer = try scene.committer()

        set.set(["base"], on: a)
        set.set(["base"], on: b)
        try #require(committer.commitNow())
        #expect(set.labels(of: a) == ["base"])
        #expect(set.labels(of: b) == ["base"])

        set.set(["base", "a"], on: a)
        set.set(["base", "b"], on: b)
        try #require(committer.commitNow(ids: [a.id]), "the scoped door (removal markers, commitBeforeReplacing) saves A alone")
        #expect(set.labels(of: b) == ["base", "b"], "B's own pending edit is untouched by A's save")
        try #require(committer.commitNow(), "the full save then carries B")

        let expected: Set<String> = ["base", "a", "b"]
        let loadedA = try await scene.reloaded(.curatedConflictA)
        #expect(set.labels(of: loadedA) == expected, "catalog.sqlite after both saves: \(set.labels(of: loadedA).sorted())")
        let loadedB = try await scene.reloaded(.curatedConflictB)
        #expect(set.labels(of: loadedB) == expected)
        #expect(set.labels(of: a) == expected, "memory A shows the set the store ends with")
        #expect(set.labels(of: b) == expected, "memory B shows the set the store ends with")
        #expect(committer.changedRecordCount() == 0, "nothing is left dirty")

        try await scene.relaunch()
        #expect(set.labels(of: try scene.record(.curatedConflictA)) == expected)
        #expect(set.labels(of: try scene.record(.curatedConflictB)) == expected)
    }
}
