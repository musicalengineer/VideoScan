// ArchiveAngelScorerTests.swift
// Archive Angel Stage 1 — LOGIC (floor reasons, evidence lines, ordering,
// caps, batch cut) + SCALE (100k candidates under a time budget). Pure
// core: no model, no disk, no defaults — ISOLATION is by construction.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Archive Angel scorer — hard floor")
struct ArchiveAngelFloorTests {

    @Test("a plain unarchived video is eligible")
    func plainEligible() {
        guard case .eligible = ArchiveAngelScorer.verdict(.init()) else {
            Issue.record("default candidate must be eligible"); return
        }
    }

    @Test("floor reasons", arguments: [
        (ArchiveAngelCandidate(streamTypeRaw: StreamType.audioOnly.rawValue), ArchiveAngelRejection.notVideo),
        (ArchiveAngelCandidate(archiveStage: .masterAssigned), .alreadyArchived),
        (ArchiveAngelCandidate(isOnMasterArchive: true), .alreadyArchived),
        (ArchiveAngelCandidate(hasArchivedDuplicate: true), .duplicateArchived),
        (ArchiveAngelCandidate(isPlayable: "No"), .notPlayable),
        (ArchiveAngelCandidate(isPlayable: "Codec unsupported"), .notPlayable),
        (ArchiveAngelCandidate(isPairedHalf: true), .pairedHalf),
        (ArchiveAngelCandidate(durationSeconds: 3), .tooShort),
        (ArchiveAngelCandidate(mediaDisposition: .confirmedJunk), .junk),
        (ArchiveAngelCandidate(mediaDisposition: .suspectedJunk), .suspectedJunk),
        (ArchiveAngelCandidate(junkScore: 5), .suspectedJunk),
        (ArchiveAngelCandidate(volumeOnline: false), .volumeOffline),
    ])
    func floor(candidate: ArchiveAngelCandidate, reason: ArchiveAngelRejection) {
        #expect(ArchiveAngelScorer.verdict(candidate) == .rejected(reason))
    }

    @Test("a star overrides machine junk evidence, never a human junk decision")
    func starsVersusJunk() {
        guard case .eligible = ArchiveAngelScorer.verdict(.init(starRating: 2, junkScore: 9)) else {
            Issue.record("rated file with high junkScore must stay eligible"); return
        }
        guard case .eligible = ArchiveAngelScorer.verdict(.init(starRating: 1, mediaDisposition: .suspectedJunk)) else {
            Issue.record("rated file suspected junk by machine must stay eligible"); return
        }
        #expect(ArchiveAngelScorer.verdict(.init(starRating: 3, mediaDisposition: .confirmedJunk)) == .rejected(.junk))
    }

    @Test("unmarked clips need a full minute; a star, a confirmed person, a note or a user date lowers the floor to 30 s")
    func unmarkedMinuteFloor() {
        #expect(ArchiveAngelScorer.verdict(.init(durationSeconds: 40)) == .rejected(.tooShort))
        #expect(ArchiveAngelScorer.verdict(.init(durationSeconds: 13, starRating: 3, confirmedPeople: ["Donna"])) == .rejected(.tooShort),
                "Donna-2.mov, 13 s, starred and tagged — Rick: not worth archiving")
        #expect(ArchiveAngelScorer.verdict(.init(durationSeconds: 59.9, detectedPeople: ["Donna"])) == .rejected(.tooShort),
                "a machine-only person tag is not a human mark")
        for marked in [ArchiveAngelCandidate(durationSeconds: 40, starRating: 1),
                       ArchiveAngelCandidate(durationSeconds: 40, confirmedPeople: ["Donna"]),
                       ArchiveAngelCandidate(durationSeconds: 40, hasUserNotes: true),
                       ArchiveAngelCandidate(durationSeconds: 40, userDate: "1994")] {
            guard case .eligible = ArchiveAngelScorer.verdict(marked) else {
                Issue.record("human-marked 40 s clip must stay eligible: \(marked)"); return
            }
        }
        guard case .eligible = ArchiveAngelScorer.verdict(.init(durationSeconds: 60)) else {
            Issue.record("60 s unmarked is the floor, inclusive"); return
        }
    }

    @Test("a marked thirty-second clip clears the floor; 29.9 s does not")
    func durationEdge() {
        guard case .eligible = ArchiveAngelScorer.verdict(.init(durationSeconds: 30, starRating: 3)) else {
            Issue.record("30 s is the marked floor, inclusive"); return
        }
        #expect(ArchiveAngelScorer.verdict(.init(durationSeconds: 29.9, starRating: 3)) == .rejected(.tooShort))
    }
}

@Suite("Archive Angel scorer — evidence")
struct ArchiveAngelEvidenceTests {

    private func lines(_ c: ArchiveAngelCandidate, now: Date = Date()) -> (Int, [String]) {
        guard case .eligible(let score, let ev) = ArchiveAngelScorer.verdict(c, now: now) else { return (-1, []) }
        return (score, ev.map(\.line))
    }

    @Test("every point has a printed reason")
    func everyPointPrints() {
        let c = ArchiveAngelCandidate(starRating: 3, confirmedPeople: ["Donna"], detectedPeople: ["Tim"],
                                      hasUserNotes: true, tagCount: 2, hasCaptions: true,
                                      inferredRecordDate: Date(timeIntervalSince1970: 0), inferredDateConfidence: 0.92,
                                      formatAtRisk: true, audioProblem: "channel imbalance", isOnlyCopy: true, useCount: 14)
        guard case .eligible(let score, let ev) = ArchiveAngelScorer.verdict(c) else { Issue.record("eligible"); return }
        #expect(score == ev.map(\.points).reduce(0, +))
        #expect(ev.allSatisfy { !$0.line.isEmpty })
        let text = ev.map(\.line).joined(separator: "\n")
        #expect(text.contains("★★★"))
        #expect(text.contains("Donna (confirmed)"))
        #expect(text.contains("Looks like Tim (machine)"))
        #expect(text.contains("Played 14 times"))
        #expect(text.contains("Has notes, 2 tags, people, captions, date, rating"))
        #expect(text.contains("Dated 1970-01-01 (consensus 0.92)"))
        #expect(text.contains("At-risk format"))
        #expect(text.contains("only copy"))
        #expect(text.contains("Audio: channel imbalance — will balance"))
    }

    @Test("stars dominate: ★★★ alone outranks a fully tagged, dated, played ★★")
    func starsDominate() {
        let best = lines(.init(starRating: 3)).0
        let rich = lines(.init(starRating: 2, confirmedPeople: ["A", "B", "C"],
                               hasUserNotes: true, tagCount: 3, hasCaptions: true, hasOCRText: true,
                               userDate: "1994", useCount: 100)).0
        #expect(best == 105)   // ★★★ + richness "rating"
        #expect(rich > best, "richness should still add up past ★★★ alone — \(rich)")
        #expect(lines(.init(starRating: 3)).0 > lines(.init(starRating: 2, confirmedPeople: ["A"])).0)
    }

    @Test("people caps: confirmed at 75, machine at 24; confirmed names are not double counted")
    func peopleCaps() {
        let confirmed = lines(.init(confirmedPeople: ["A", "B", "C", "D", "E"]))
        #expect(confirmed.0 == 75 + 5)   // + richness "people"
        let machine = lines(.init(detectedPeople: ["A", "B", "C", "D"], suspectedPeople: ["A", "E"]))
        #expect(machine.0 == 24)
        let both = lines(.init(confirmedPeople: ["Donna"], detectedPeople: ["Donna"]))
        #expect(!both.1.contains { $0.hasPrefix("Looks like") })
    }

    @Test("play history is logarithmic and capped; a recent play adds the bonus")
    func playHistory() {
        #expect(lines(.init(useCount: 1)).0 == 4)
        #expect(lines(.init(useCount: 7)).0 == 12)
        #expect(lines(.init(useCount: 100_000)).0 == 40)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let recent = lines(.init(useCount: 1, lastUsed: now.addingTimeInterval(-86_400)), now: now)
        #expect(recent.0 == 9)
        #expect(recent.1.first?.hasPrefix("Played once, last on ") == true)
        let stale = lines(.init(useCount: 1, lastUsed: now.addingTimeInterval(-400 * 86_400)), now: now)
        #expect(stale.0 == 4)
    }

    @Test("date evidence: user date > confident inferred > uncertain inferred > camera")
    func dateEvidence() {
        #expect(lines(.init(userDate: "1994-11-24")).1.contains("Dated 1994-11-24 (yours)"))
        let d = Date(timeIntervalSince1970: 786_000_000)
        #expect(lines(.init(inferredRecordDate: d, inferredDateConfidence: 0.8)).0 == 20 + 5)
        #expect(lines(.init(inferredRecordDate: d, inferredDateConfidence: 0.55)).0 == 5 + 5)
        #expect(lines(.init(hasEmbeddedDate: true)).1.contains("Dated by the camera"))
    }

    @Test("duration sweet band is 2 min – 2 h")
    func sweetBand() {
        #expect(lines(.init(durationSeconds: 119)).0 == 0)
        #expect(lines(.init(durationSeconds: 120)).0 == 10)
        #expect(lines(.init(durationSeconds: 7200)).0 == 10)
        #expect(lines(.init(durationSeconds: 7201)).0 == 0)
        #expect(lines(.init(durationSeconds: 5400)).1 == ["1 h 30 min"])
    }
}

@Suite("Archive Angel scorer — selection")
struct ArchiveAngelSelectionTests {

    @Test("takes the top N, reports overflow and rejection counts by reason")
    func batchCut() {
        var cands: [ArchiveAngelCandidate] = []
        for i in 0..<30 { cands.append(.init(filename: "c\(i).mov", starRating: i % 4)) }
        cands.append(.init(filename: "junk.mov", mediaDisposition: .confirmedJunk))
        cands.append(.init(filename: "tiny.mov", durationSeconds: 1))
        cands.append(.init(filename: "tiny2.mov", durationSeconds: 2))
        let sel = ArchiveAngelScorer.select(cands, count: 7)
        #expect(sel.picks.count == 7)
        #expect(sel.overflow == 23)
        #expect(sel.rejected[.junk] == 1)
        #expect(sel.rejected[.tooShort] == 2)
        #expect(sel.rejectedTotal == 3)
        #expect(sel.picks.allSatisfy { $0.candidate.starRating == 3 })
        #expect(sel.picks.map(\.score) == sel.picks.map(\.score).sorted(by: >))
    }

    @Test("ties break oldest date first, then larger file, then name")
    func tieBreak() {
        let old = Date(timeIntervalSince1970: 600_000_000)
        let new = Date(timeIntervalSince1970: 900_000_000)
        let cands = [
            ArchiveAngelCandidate(filename: "b.mov", sizeBytes: 10, inferredRecordDate: new, inferredDateConfidence: 0.9),
            ArchiveAngelCandidate(filename: "a.mov", sizeBytes: 10, inferredRecordDate: new, inferredDateConfidence: 0.9),
            ArchiveAngelCandidate(filename: "c.mov", sizeBytes: 99, inferredRecordDate: new, inferredDateConfidence: 0.9),
            ArchiveAngelCandidate(filename: "d.mov", sizeBytes: 1, inferredRecordDate: old, inferredDateConfidence: 0.9),
        ]
        let names = ArchiveAngelScorer.select(cands, count: 4).picks.map(\.candidate.filename)
        #expect(names == ["d.mov", "c.mov", "a.mov", "b.mov"])
    }

    @Test("count 0 and empty input are safe")
    func degenerate() {
        #expect(ArchiveAngelScorer.select([], count: 25).picks.isEmpty)
        let sel = ArchiveAngelScorer.select([.init(starRating: 3)], count: 0)
        #expect(sel.picks.isEmpty)
        #expect(sel.overflow == 1)
    }

    @Test("SCALE: 100k candidates select in under 2 s (Debug ceiling, widened on hosted runners)")
    func scale() {
        var cands: [ArchiveAngelCandidate] = []
        cands.reserveCapacity(100_000)
        let base = Date(timeIntervalSince1970: 700_000_000)
        for i in 0..<100_000 {
            cands.append(.init(filename: "v\(i).mov", sizeBytes: Int64(i), durationSeconds: Double(i % 9000),
                               starRating: i % 4, junkScore: i % 7,
                               confirmedPeople: i % 5 == 0 ? ["Donna"] : [],
                               detectedPeople: i % 3 == 0 ? ["Tim", "Matt"] : [],
                               hasUserNotes: i % 11 == 0, tagCount: i % 4,
                               inferredRecordDate: base.addingTimeInterval(Double(i) * 3600),
                               inferredDateConfidence: Float(i % 100) / 100, useCount: i % 50))
        }
        let started = ContinuousClock.now
        let sel = ArchiveAngelScorer.select(cands, count: 50)
        let elapsed = ContinuousClock.now - started
        #expect(sel.picks.count == 50)
        #expect(elapsed < PerformanceLane.debugCeiling(.seconds(2)), "100k select took \(elapsed)")
    }
}
