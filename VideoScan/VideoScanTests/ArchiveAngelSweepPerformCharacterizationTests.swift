// ArchiveAngelSweepPerformCharacterizationTests.swift
// CHARACTERIZATION ONLY (refactor/angel-sweep-perform, 2026-11-08): pins what
// `ArchiveAngelSweep.perform` writes and says today, so splitting it into its
// steps (park → snapshot → floor pass → score the eligible → checkpoint →
// classify → publish) can be shown to change nothing. Written and seen green
// on the unchanged code first. ArchiveAngelSweepTests already pins scale, the
// log contract's line count, busy-parking and the cadence; this file pins the
// rest of the run's observable output:
//   • each record's evidence by path: floor-rejected (reason, the safety
//     reason beside it, a policy rule's own words), eligible (score and plays
//     written back), and a hand-built policy with no safety floors;
//   • play history asked only for files that cleared the floors, never when
//     none did;
//   • the evidence file's stamps (attention, catalog, counts, time);
//   • the classifier's verdicts written onto every record;
//   • the partial file's doubling schedule (complete = false);
//   • the done status, the "evidence not saved" refusal, the once-only
//     migration line, the "you are working" park, and a run disabled while
//     parked (no snapshot, nothing written).
// Isolated: injected store directory, injected play history and clock.

import Foundation
import os
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("ArchiveAngelSweep.perform — characterization", .serialized)
@MainActor
struct ArchiveAngelSweepPerformCharacterizationTests {

    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    static let played = Date(timeIntervalSince1970: 1_780_000_000)

    /// Paths play history was asked about, in call order (one array per call).
    final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [[String]] = []
        func note(_ paths: [String]) { lock.withLock { calls.append(paths) } }
        var all: [[String]] { lock.withLock { calls } }
    }

    static func tempDir(_ tag: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("test_angel_perform_\(tag)_\(UUID().uuidString.prefix(8))", isDirectory: true)
    }

    static func makeSweep(_ candidates: [ArchiveAngelCandidate], dir: URL,
                          policy: AngelRecommendationPolicy = .builtIn,
                          asked: Asked = Asked(), sliceSize: Int = 500, checkpointEvery: Int = 5_000,
                          log: @escaping @MainActor (String) -> Void = { _ in },
                          playHistory: (@Sendable ([String]) async -> [String: ArchiveAngelPlayHistory.Reading])? = nil)
        -> ArchiveAngelSweep {
        let sweep = ArchiveAngelSweep(store: ArchiveAngelEvidenceStore(directory: dir))
        var cfg = ArchiveAngelSweep.Configuration(candidates: { candidates }, isExternallyBusy: { false })
        let stamp = Self.played
        cfg.playHistory = playHistory ?? { paths in
            asked.note(paths)
            var out: [String: ArchiveAngelPlayHistory.Reading] = [:]
            for p in paths where p.contains("played") { out[p] = .init(useCount: 7, lastUsed: stamp) }
            return out
        }
        cfg.policy = policy
        cfg.attentionState = { (7, Date(timeIntervalSince1970: 1_700_000_000)) }
        cfg.catalogState = { ("launch-token", 42) }
        let clock = Self.now
        cfg.now = { clock }
        cfg.sliceSize = sliceSize
        cfg.checkpointEvery = checkpointEvery
        cfg.pausePollMilliseconds = 20
        cfg.quietSeconds = 0
        cfg.log = log
        sweep.configure(cfg, enabled: true)
        return sweep
    }

    static func good(_ name: String) -> ArchiveAngelCandidate {
        ArchiveAngelCandidate(filename: "\(name).mov", fullPath: "/Volumes/T/\(name).mov",
                              sizeBytes: 2_000_000_000, durationSeconds: 1_800, starRating: 3,
                              confirmedPeople: ["Donna"], inferredRecordDate: Date(timeIntervalSince1970: 700_000_000),
                              inferredDateConfidence: 0.9)
    }

    // MARK: evidence per record

    @Test func eachRecordsEvidenceByPath() async throws {
        let dir = Self.tempDir("paths")
        defer { try? FileManager.default.removeItem(at: dir) }
        let eligible = Self.good("played_christmas")
        let unplayed = Self.good("easter")
        var shortOffline = Self.good("short_offline"); shortOffline.durationSeconds = 30; shortOffline.volumeOnline = false
        var archived = Self.good("archived"); archived.isOnMasterArchive = true
        var outtake = Self.good("outtake_reel")
        outtake.filename = "outtake_reel.mov"
        var policy = AngelRecommendationPolicy.builtIn
        let rule = AngelRule(id: "outtakes", kind: .match,
                             when: [.init(field: .filename, op: .contains, value: .string("outtake"))],
                             line: "Outtakes stay out")
        policy.floors.insert(rule, at: 0)
        let asked = Asked()
        let all = [eligible, unplayed, shortOffline, archived, outtake]
        let sweep = Self.makeSweep(all, dir: dir, policy: policy, asked: asked)
        await sweep.runAndWait(reason: "test")
        let file = try #require(sweep.store.file)

        let e = try #require(file.records[eligible.id])
        #expect(e.rejection == nil && e.safetyRejection == nil && e.excludedBy == nil)
        #expect(e.useCount == 7 && e.lastUsed == Self.played, "plays written back")
        var withPlays = eligible; withPlays.useCount = 7; withPlays.lastUsed = Self.played
        guard case .eligible(let score, let lines) = ArchiveAngelScorer.verdict(withPlays, policy: policy, now: Self.now) else {
            Issue.record("expected eligible"); return
        }
        #expect(e.score == score && e.lines == lines, "scored on the candidate WITH its plays")
        #expect(e.computedAt == Self.now && e.timesProposed == 0 && e.familySkips == 0)

        let u = try #require(file.records[unplayed.id])
        #expect(u.rejection == nil && u.useCount == 0 && u.lastUsed == nil)

        let s = try #require(file.records[shortOffline.id])
        #expect(s.rejection == .tooShort, "the first floor in policy order is the reason")
        #expect(s.safetyRejection == .volumeOffline, "the safety floor rides beside it")
        #expect(s.excludedBy == nil && s.score == 0 && s.lines.isEmpty && s.useCount == 0)
        #expect(s.grade == .x)

        let a = try #require(file.records[archived.id])
        #expect(a.rejection == .alreadyArchived && a.safetyRejection == .alreadyArchived)

        let o = try #require(file.records[outtake.id])
        #expect(o.rejection == .policyRule && o.excludedBy == "Outtakes stay out" && o.safetyRejection == nil)

        #expect(asked.all.flatMap { $0 } == [eligible.fullPath, unplayed.fullPath],
                "play history only for files that cleared the floors, in order")
        #expect(file.eligible == 2 && file.considered == 5 && file.records.count == 5)
    }

    @Test func playHistoryIsNotAskedWhenNothingClearsTheFloors() async {
        let dir = Self.tempDir("noplays")
        defer { try? FileManager.default.removeItem(at: dir) }
        var a = Self.good("a"); a.durationSeconds = 10
        var b = Self.good("b"); b.volumeOnline = false
        let asked = Asked()
        let sweep = Self.makeSweep([a, b], dir: dir, asked: asked)
        await sweep.runAndWait(reason: "test")
        #expect(asked.all.isEmpty)
        #expect(sweep.store.file?.eligible == 0 && sweep.store.file?.considered == 2)
    }

    @Test func aPolicyWithoutSafetyFloorsStillNeverRecommendsAnOfflineFile() async throws {
        let dir = Self.tempDir("nosafety")
        defer { try? FileManager.default.removeItem(at: dir) }
        var policy = AngelRecommendationPolicy.builtIn
        policy.floors = []
        var offline = Self.good("offline"); offline.volumeOnline = false
        var short = Self.good("short"); short.durationSeconds = 30
        let sweep = Self.makeSweep([offline, short], dir: dir, policy: policy)
        await sweep.runAndWait(reason: "test")
        let file = try #require(sweep.store.file)
        let o = try #require(file.records[offline.id])
        #expect(o.rejection == .volumeOffline && o.safetyRejection == .volumeOffline && o.excludedBy == nil)
        let s = try #require(file.records[short.id])
        #expect(s.rejection == nil, "no tooShort floor in this policy")
    }

    // MARK: the file

    @Test func theEvidenceFileIsStampedWithTheSnapshotsState() async throws {
        let dir = Self.tempDir("stamps")
        defer { try? FileManager.default.removeItem(at: dir) }
        let sweep = Self.makeSweep([Self.good("one"), Self.good("two")], dir: dir)
        await sweep.runAndWait(reason: "test")
        let file = try #require(sweep.store.file)
        #expect(file.complete)
        #expect(file.computedAt == Self.now)
        #expect(file.attentionRevision == 7)
        #expect(file.attentionLastEventAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(file.catalogRevision == 42 && file.catalogLaunchToken == "launch-token")
        #expect(file.policyFingerprint == sweep.store.policyFingerprint)
        #expect(FileManager.default.fileExists(atPath: sweep.store.fileURL.path))
        guard case .done(let summary, let at) = sweep.status else { Issue.record("\(sweep.status)"); return }
        #expect(summary == "scored 2 · \(sweep.store.candidateCount.formatted()) candidates")
        #expect(at == Self.now)
    }

    @Test func theClassifiersVerdictsAreWrittenOntoEveryRecord() async throws {
        let dir = Self.tempDir("classify")
        defer { try? FileManager.default.removeItem(at: dir) }
        var twinA = Self.good("twin_a"); twinA.contentKey = "h:abc"; twinA.duplicateGroupID = UUID()
        var twinB = Self.good("twin_b"); twinB.contentKey = "h:abc"; twinB.duplicateGroupID = twinA.duplicateGroupID
        twinA.duplicateGroupCount = 2; twinB.duplicateGroupCount = 2
        var undated = Self.good("undated"); undated.inferredRecordDate = nil; undated.inferredDateConfidence = nil
        var short = Self.good("short"); short.durationSeconds = 30
        let all = [twinA, twinB, undated, short, Self.good("plain")]
        let sweep = Self.makeSweep(all, dir: dir)
        await sweep.runAndWait(reason: "test")
        let file = try #require(sweep.store.file)
        // The classifier's own answer over the same inputs (no plays: no path says "played").
        var bare = file.records
        for id in bare.keys {
            bare[id]?.recommendation = nil; bare[id]?.reasons = nil; bare[id]?.year = nil
            bare[id]?.copies = nil; bare[id]?.copyKey = nil
        }
        let expected = ArchiveAngelRecommendations.classify(all, evidence: bare, rules: AngelRecommendationPolicy.builtIn.recommend,
                                                            now: Self.now)
        #expect(expected.verdicts.count == all.count)
        for (i, c) in all.enumerated() {
            let v = expected.verdicts[i]
            let rec = try #require(file.records[c.id])
            #expect(rec.recommendation == v.kind, "\(c.filename)")
            #expect(rec.reasons == (v.reasons.isEmpty ? nil : v.reasons), "\(c.filename)")
            #expect(rec.year == v.year, "\(c.filename)")
            #expect(rec.copies == (v.copies > 1 ? v.copies : nil), "\(c.filename)")
            #expect(rec.copyKey == v.copyKey, "\(c.filename)")
        }
        #expect(file.records.values.allSatisfy { $0.recommendation != nil }, "every record gets its class")
        #expect(sweep.store.classCounts() == expected.counts)
    }

    // MARK: checkpoints

    @Test func thePartialFileIsSavedOnADoublingSchedule() async {
        let dir = Self.tempDir("checkpoint")
        defer { try? FileManager.default.removeItem(at: dir) }
        let all = (0..<1_000).map { Self.good("c\($0)") }
        let seen = OSAllocatedUnfairLock<[String]>(initialState: [])
        let url = dir.appendingPathComponent(ArchiveAngelEvidenceStore.filename)
        let sweep = Self.makeSweep(all, dir: dir, sliceSize: 100, checkpointEvery: 200, playHistory: { _ in
            // What is on disk as each slice asks for its plays.
            let line: String
            if let data = try? Data(contentsOf: url),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                line = "\(obj["considered"] ?? "?")/\(obj["complete"] ?? "?")"
            } else {
                line = "none"
            }
            seen.withLock { $0.append(line) }
            return [:]
        })
        await sweep.runAndWait(reason: "test")
        #expect(seen.withLock { $0 } == ["none", "none", "200/0", "200/0", "400/0", "400/0", "400/0", "400/0", "800/0", "800/0"],
                "saved at 200, then each time the count doubled (400, 800); never at the end of the last slice")
        #expect(sweep.store.file?.complete == true && sweep.store.file?.considered == 1_000)
    }

    // MARK: outcomes

    @Test func anUnsavableFileIsSaidInTheStatusAndTheLog() async throws {
        let parent = Self.tempDir("unsavable")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let blocker = parent.appendingPathComponent("not-a-dir")
        try Data("x".utf8).write(to: blocker)
        var lines: [String] = []
        let sweep = Self.makeSweep([Self.good("one")], dir: blocker.appendingPathComponent("evidence"),
                                   log: { lines.append($0) })
        await sweep.runAndWait(reason: "test")
        guard case .done(let summary, _) = sweep.status else { Issue.record("\(sweep.status)"); return }
        #expect(summary.hasSuffix(" · (evidence not saved)"), "\(summary)")
        #expect(lines.last?.hasSuffix(" (evidence NOT saved)") == true, "\(lines)")
        #expect(sweep.store.file?.complete == true, "the grades are still published in memory")
    }

    @Test func theMigrationLineIsLoggedOnceAfterARulesChange() async {
        let dir = Self.tempDir("migration")
        defer { try? FileManager.default.removeItem(at: dir) }
        var lines: [String] = []
        let sweep = Self.makeSweep([Self.good("one"), Self.good("two")], dir: dir, log: { lines.append($0) })
        sweep.store.olderRules = (rulesVersion: 3, grades: [.a: 1])
        await sweep.runAndWait(reason: "first")
        #expect(lines.count == 3, "\(lines)")
        #expect(lines.last?.hasPrefix("Archive Angel: recommendation rules v3 → v\(ArchiveAngelScorer.rulesVersion) — before: ") == true,
                "\(lines)")
        #expect(sweep.store.olderRules == nil)
        lines.removeAll()
        await sweep.runAndWait(reason: "second")
        #expect(lines.count == 2, "\(lines)")
    }

    @Test func interactionParksWithItsOwnReason() async {
        let dir = Self.tempDir("interaction")
        defer { try? FileManager.default.removeItem(at: dir) }
        let sweep = ArchiveAngelSweep(store: ArchiveAngelEvidenceStore(directory: dir))
        var cfg = ArchiveAngelSweep.Configuration(candidates: { [Self.good("one")] }, isExternallyBusy: { false })
        cfg.playHistory = { _ in [:] }
        cfg.quietSeconds = 0.4
        cfg.pausePollMilliseconds = 20
        sweep.configure(cfg, enabled: true)
        sweep.noteInteraction()
        sweep.run(reason: "test")
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(sweep.status == .paused(reason: "you are working"))
        for _ in 0..<100 {
            if case .done = sweep.status { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        guard case .done = sweep.status else { Issue.record("\(sweep.status)"); return }
    }

    @Test func disabledWhileParkedTakesNoSnapshotAndWritesNothing() async {
        let dir = Self.tempDir("cancel")
        defer { try? FileManager.default.removeItem(at: dir) }
        let snapshots = OSAllocatedUnfairLock(initialState: 0)
        let sweep = ArchiveAngelSweep(store: ArchiveAngelEvidenceStore(directory: dir))
        var cfg = ArchiveAngelSweep.Configuration(candidates: { snapshots.withLock { $0 += 1 }; return [Self.good("one")] },
                                                  isExternallyBusy: { true })
        cfg.pausePollMilliseconds = 20
        sweep.configure(cfg, enabled: true)
        sweep.run(reason: "test")
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(sweep.status == .paused(reason: "another job is using the catalog"))
        sweep.setEnabled(false)
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(sweep.status == .disabled)
        #expect(snapshots.withLock { $0 } == 0)
        #expect(!sweep.store.isLoaded)
        #expect(!FileManager.default.fileExists(atPath: sweep.store.fileURL.path))
    }
}
