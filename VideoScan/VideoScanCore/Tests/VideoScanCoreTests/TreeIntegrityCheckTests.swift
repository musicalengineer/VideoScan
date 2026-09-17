// TreeIntegrityCheckTests.swift
//
// The regression sensor for the 2026-09-16 P1: a Refresh rebased onto one
// file and the promoted tree went from 39,250 people and two sources to
// 16,383 and one. Donna's entire line vanished from the active tree and
// every step in the chain reported success.
//
// These tests are written against THAT INCIDENT'S ACTUAL NUMBERS, so the
// day this stops failing on the real shape, someone has changed something
// that matters.
//
// Five dimensions:
//   1. Logic     — sources dropped, people lost, families lost, growth
//   2. Scale     — n/a (compares two manifests, not records)
//   3. Media     — n/a
//   4. Isolation — pure values; no store, no files, no defaults
//   5. Sensor    — the incident by its real counts, and the converse so it
//                  cannot pass by alarming at everything

import Foundation
import Testing
@testable import VideoScanCore

@Suite("Tree integrity — a tree must not quietly get smaller")
struct TreeIntegrityCheckTests {

    private typealias Manifest = FamilyGraphCompiledStore.Manifest

    private func manifest(people: Int, families: Int, sources: [String],
                          generation: String = "gen-test") -> Manifest {
        Manifest(schema: 3, codec: 6, index: 2, generation: generation, createdAt: Date(),
                 sources: sources.map { .init(fileName: $0, path: "/tmp/\($0)", size: 1,
                                              modifiedAt: Date(), key: $0, sha256: $0,
                                              droppedLineCount: 0) },
                 logicalSources: sources.map { .init(fileName: $0, sha256: $0, droppedLineCount: 0) },
                 peopleCount: people, familyCount: families, verification: [],
                 mergeReport: nil, localDroppedLineCount: 0, totalDroppedLineCount: 0)
    }

    /// Rick's tree as it stood: his pull plus Donna's.
    private var theRealTree: Manifest {
        manifest(people: 39_250, families: 24_935,
                 sources: ["familysearch-tree-20generations.ged",
                           "familysearch-donna-20generations.ged"])
    }

    /// What the broken Refresh promoted.
    private var whatTheBrokenRefreshPromoted: Manifest {
        manifest(people: 16_383, families: 10_387,
                 sources: ["familysearch-refreshed-20260917-001509.ged"])
    }

    // MARK: - 5. The incident, by its real numbers

    @Test func theSeptember16NarrowingIsAnAlarm() {
        let findings = TreeIntegrityCheck.compare(
            incoming: whatTheBrokenRefreshPromoted, against: theRealTree)

        #expect(TreeIntegrityCheck.hasAlarm(findings),
                "the tree lost 22,867 people and a whole source and nothing alarmed")

        let text = findings.map(\.message).joined(separator: " | ")
        #expect(text.contains("familysearch-donna-20generations.ged"),
                "the alarm must NAME the source that went missing: \(text)")
        #expect(text.contains("22,867"), "and say how many people were lost: \(text)")
    }

    /// Losing a source is an alarm even when the people count somehow
    /// holds — the source list is the tree's identity, not just its size.
    @Test func droppingASourceAlarmsEvenWithoutLosingPeople() {
        let findings = TreeIntegrityCheck.compare(
            incoming: manifest(people: 39_250, families: 24_935, sources: ["only-mine.ged"]),
            against: theRealTree)
        #expect(TreeIntegrityCheck.hasAlarm(findings))
    }

    // MARK: - 1. The ordinary cases, so the alarm means something

    @Test func aTreeThatGrowsIsNeverAnAlarm() {
        let findings = TreeIntegrityCheck.compare(
            incoming: manifest(people: 39_400, families: 25_000,
                               sources: ["familysearch-tree-20generations.ged",
                                         "familysearch-donna-20generations.ged"]),
            against: theRealTree)
        #expect(!TreeIntegrityCheck.hasAlarm(findings),
                Comment(rawValue: findings.map(\.message).joined()))
    }

    /// A refresh that merges a handful of upstream duplicates loses a few
    /// people legitimately. That is a warning to read, not an alarm.
    @Test func aSmallLossIsAWarningNotAnAlarm() {
        let findings = TreeIntegrityCheck.compare(
            incoming: manifest(people: 39_100, families: 24_900,
                               sources: ["familysearch-tree-20generations.ged",
                                         "familysearch-donna-20generations.ged"]),
            against: theRealTree)
        #expect(!TreeIntegrityCheck.hasAlarm(findings))
        #expect(findings.contains { $0.severity == .warning })
    }

    /// Just past the threshold: 10% is the line, so 11% must alarm.
    @Test func aLossPastTheThresholdAlarms() {
        let eleven = Int(Double(39_250) * 0.89)
        let findings = TreeIntegrityCheck.compare(
            incoming: manifest(people: eleven, families: 24_000,
                               sources: ["familysearch-tree-20generations.ged",
                                         "familysearch-donna-20generations.ged"]),
            against: theRealTree)
        #expect(TreeIntegrityCheck.hasAlarm(findings),
                "an 11% loss with no source change must still alarm")
    }

    @Test func theFirstCompileHasNothingToLoseAndSaysSo() {
        let findings = TreeIntegrityCheck.compare(incoming: theRealTree, against: nil)
        #expect(!TreeIntegrityCheck.hasAlarm(findings))
        #expect(findings.count == 1)
        #expect(findings[0].message.contains("First compiled tree"))
    }

    /// Families falling while people hold is its own signal — a merge that
    /// mangles FAM records without losing INDIs.
    @Test func familiesFallingAloneIsAWarning() {
        let findings = TreeIntegrityCheck.compare(
            incoming: manifest(people: 39_250, families: 20_000,
                               sources: ["familysearch-tree-20generations.ged",
                                         "familysearch-donna-20generations.ged"]),
            against: theRealTree)
        #expect(findings.contains { $0.severity == .warning && $0.message.contains("fewer families") })
    }
}
