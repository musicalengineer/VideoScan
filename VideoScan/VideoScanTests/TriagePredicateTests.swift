// TriagePredicateTests.swift
// Pure-logic tests for the triage disposition + queue predicates:
//
//   pfTriageDisposition(_:requireBackupForJunk:)
//   pfTriageQueueRecords(from:includeUnbackedJunk:)
//   pfTriageBandCounts(from:)
//
// Lifted from CatalogQueriesTests.swift (Rick 2026-06-17) — these
// suites are about the triage classification logic, not catalog
// search queries; the original file was over the 1000-line cap.
//
// Regression issue tag preserved on each test: #66.

import Testing
import Foundation
@testable import VideoScan

struct TriageDispositionTests {

    private func record(
        junkScore: Int = 50,
        backupCount: Int = 0,
        archiveStage: ArchiveStage = .none
    ) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = "/v/clip.mov"
        r.junkScore = junkScore
        r.archiveStage = archiveStage
        r.backupDestinations = (0..<backupCount).map {
            BackupEntry(name: "Backup\($0)", kind: .local, date: .now)
        }
        return r
    }

    // regression: #66 — junkScore <= autoKeepBelow → autoKeep
    @Test func lowScoreYieldsAutoKeep() {
        let r = record(junkScore: 10)
        #expect(pfTriageDisposition(r) == .autoKeep)
    }

    // regression: #66 — junkScore at boundary (= 30) is autoKeep (inclusive)
    @Test func autoKeepBoundaryIsInclusive() {
        let r = record(junkScore: 30)
        #expect(pfTriageDisposition(r) == .autoKeep)
    }

    // regression: #66 — Middle band → queue (human review)
    @Test func middleBandYieldsQueue() {
        let r = record(junkScore: 50)
        #expect(pfTriageDisposition(r) == .queue)
    }

    // regression: #66 — junkScore >= autoJunkAbove + verified backup → autoJunk
    @Test func highScoreWithBackupYieldsAutoJunk() {
        let r = record(junkScore: 80, backupCount: 2)
        #expect(pfTriageDisposition(r) == .autoJunk)
    }

    // regression: #66 — Backup gate: high score WITHOUT backup → junkButNotBackedUp (safety)
    @Test func highScoreWithoutBackupNotAutoJunked() {
        let r = record(junkScore: 80, backupCount: 0)
        #expect(pfTriageDisposition(r) == .junkButNotBackedUp)
    }

    // regression: #66 — One backup is not enough; need 2-locations rule
    @Test func singleBackupNotEnough() {
        let r = record(junkScore: 80, backupCount: 1)
        #expect(pfTriageDisposition(r) == .junkButNotBackedUp)
    }

    // regression: #66 — archiveStage = .healthy satisfies the backup gate
    @Test func healthyArchiveStageSatisfiesGate() {
        let r = record(junkScore: 80, backupCount: 0, archiveStage: .healthy)
        #expect(pfTriageDisposition(r) == .autoJunk)
    }

    // regression: #66 — `requireBackupForJunk: false` skips the safety gate
    @Test func disablingGateAllowsRiskyAutoJunk() {
        let r = record(junkScore: 90, backupCount: 0)
        #expect(pfTriageDisposition(r, requireBackupForJunk: false) == .autoJunk)
    }
}

struct TriageQueueTests {

    private func record(_ path: String, junkScore: Int, backupCount: Int = 0) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = path
        r.filename = (path as NSString).lastPathComponent
        r.junkScore = junkScore
        r.backupDestinations = (0..<backupCount).map {
            BackupEntry(name: "B\($0)", kind: .local, date: .now)
        }
        return r
    }

    // regression: #66 — Triage queue surfaces only borderline records
    @Test func queueSurfacesOnlyBorderline() {
        let recs = [
            record("/v/keeper.mov", junkScore: 5),     // autoKeep (filtered out)
            record("/v/borderline.mov", junkScore: 50),// queue (kept)
            record("/v/junk.mov", junkScore: 90, backupCount: 2), // autoJunk (filtered)
        ]
        let queue = pfTriageQueueRecords(from: recs)
        #expect(queue.count == 1)
        #expect(queue.first?.filename == "borderline.mov")
    }

    // regression: #66 — junkButNotBackedUp included by default (visibility for safety)
    @Test func includesUnbackedJunkByDefault() {
        let recs = [
            record("/v/risky.mov", junkScore: 90, backupCount: 0)
        ]
        let queue = pfTriageQueueRecords(from: recs)
        #expect(queue.count == 1)
    }

    // regression: #66 — Setting includeUnbackedJunk: false hides them
    @Test func canHideUnbackedJunk() {
        let recs = [
            record("/v/risky.mov", junkScore: 90, backupCount: 0)
        ]
        let queue = pfTriageQueueRecords(from: recs, includeUnbackedJunk: false)
        #expect(queue.isEmpty)
    }

    // regression: #66 — Band counts split a mixed catalog correctly
    @Test func bandCountsAggregate() {
        let recs = [
            record("/v/keep1.mov", junkScore: 5),
            record("/v/keep2.mov", junkScore: 25),
            record("/v/maybe.mov", junkScore: 50),
            record("/v/junk.mov", junkScore: 85, backupCount: 2),
            record("/v/risky.mov", junkScore: 90, backupCount: 0),
        ]
        let counts = pfTriageBandCounts(from: recs)
        #expect(counts.autoKeep == 2)
        #expect(counts.queue == 1)
        #expect(counts.autoJunk == 1)
        #expect(counts.junkButNotBackedUp == 1)
        #expect(counts.total == 5)
    }
}
