// ArchiveAngelCoverageTests.swift
// Rules v13 coverage (2026-09-26, docs/footage_groups_gap_plan_2026-09-26.md
// Stage 2, bounded by docs/codex-review-angel-coverage-2026-09-26.md).
// Rick: "If AA recommends 5 different versions of the same Thanksgiving
// 1994, rather than misc birthdays, trips, christmas from other years not
// yet archived, then AA is not working that well."
//
//   LOGIC     five Thanksgiving-1994 variants (five names, five folders,
//             one day) + four other years → ONE 1994 pick and the others;
//             the event key is the DAY and nothing coarser (false splits
//             AND false merges, unknown dates, month/year precision, a
//             conversion stamp); the per-year cap; soft relaxation when
//             years are scarce; the backlog bonus counts RECORDINGS (1,000
//             copies of one tape change nothing), skips junk / working
//             copies, and gives undated recordings no bonus;
//   CUTOFF    top 500 rows all 1994, four other years below the band — a
//             ten-row cap-two batch is ten diverse rows through BOTH the
//             cached and the walk paths, and both agree, under 16 id draws;
//   PARITY    coverage OFF = rules v12 end to end: ids, order, scores,
//             evidence lines, rejection and overflow counts, cache = walk;
//   FRESHNESS a catalog change since the sweep's snapshot declines the
//             cache with coverage on, not with it off;
//   SCALE     100k candidates through the coverage pre-pass ≤ 1 s Debug;
//   ISOLATION a poisoned or absent policy file → coverage defaults;
//   SENSOR    a batch of 10 never holds more than maxPerYearPerBatch of
//             one year WHEN other years can fill it, whatever the input
//             order.
// ArchiveAngelDurationBandTests (below) pins the duration band UNCHANGED.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private let testNow = Date(timeIntervalSince1970: 1_790_000_000)   // 2026-09-21

extension AngelRecommendationPolicy {
    /// Rules v12 behaviour: the built-in policy with every coverage rule off.
    static var coverageOff: AngelRecommendationPolicy {
        var p = AngelRecommendationPolicy.builtIn
        p.coverage = .off
        return p
    }
}

/// A dated, dull, unique video: no star, no people — only its date and
/// its length score it, so the coverage rules are what the tests see.
private func video(_ name: String, folder: String = "/Volumes/LaCie/Family", year: Int, month: Int = 6, day: Int = 15,
                   minutes: Double = 20, stars: Int = 0, dated: Bool = true,
                   archived: Bool = false, sizeBytes: Int64 = 10_000_000_000,
                   group: UUID? = nil, disposition: MediaDisposition = .unreviewed) -> ArchiveAngelCandidate {
    ArchiveAngelCandidate(filename: name, fullPath: folder + "/" + name, sizeBytes: sizeBytes,
                          durationSeconds: minutes * 60, starRating: stars, mediaDisposition: disposition,
                          userDate: dated ? String(format: "%04d-%02d-%02d", year, month, day) : nil,
                          hasArchivedDuplicate: archived, duplicateGroupID: group)
}

private func years(of picks: [ArchiveAngelPick]) -> [Int: Int] {
    var out: [Int: Int] = [:]
    for p in picks { if let y = p.candidate.resolvedEvent(now: testNow).year { out[y, default: 0] += 1 } }
    return out
}

private func utc(_ y: Int, _ m: Int, _ d: Int) -> Date {
    var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = 12
    return ArchiveAngelCandidate.utcCalendar.date(from: c)!
}

/// A seeded generator so a shuffle is reproducible (≈ std::mt19937 with a fixed seed).
private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func uuid() -> UUID {
        let a = next(), b = next()
        return UUID(uuid: (UInt8(a & 0xff), UInt8(a >> 8 & 0xff), UInt8(a >> 16 & 0xff), UInt8(a >> 24 & 0xff),
                           UInt8(a >> 32 & 0xff), UInt8(a >> 40 & 0xff), UInt8(a >> 48 & 0xff), UInt8(a >> 56 & 0xff),
                           UInt8(b & 0xff), UInt8(b >> 8 & 0xff), UInt8(b >> 16 & 0xff), UInt8(b >> 24 & 0xff),
                           UInt8(b >> 32 & 0xff), UInt8(b >> 40 & 0xff), UInt8(b >> 48 & 0xff), UInt8(b >> 56 & 0xff)))
    }
}

@MainActor
private func evidenceStore(_ records: [UUID: ArchiveAngelEvidenceRecord], now: Date,
                           catalogRevision: Int? = nil) -> ArchiveAngelEvidenceStore {
    let s = ArchiveAngelEvidenceStore(directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("test_angel_coverage_\(UUID().uuidString.prefix(8))"))
    s.replace(with: .init(computedAt: now.addingTimeInterval(-600), complete: true, considered: records.count,
                          eligible: records.count, records: records, catalogRevision: catalogRevision))
    return s
}

private func evidence(_ score: Int, year: Int?, now: Date) -> ArchiveAngelEvidenceRecord {
    var r = ArchiveAngelEvidenceRecord(score: score, lines: [.init(points: score, line: "why \(score)")], rejection: nil,
                                       useCount: 0, lastUsed: nil, computedAt: now)
    r.recommendation = .ready
    r.year = year
    return r
}

// MARK: - Logic

@Suite("Archive Angel coverage — one per day, the per-year share, the backlog bonus")
struct ArchiveAngelCoverageTests {

    // MARK: Event key — the DAY, nothing coarser

    @Test("the event key is the DAY on its own (whatever the name or folder) when the day is a person's, a camera's or the dossier's")
    func dayKeyIgnoresNameAndFolder() {
        let a = ArchiveAngelCandidate(filename: "Thanksgiving 94.mov", fullPath: "/Volumes/LaCie/Exports/Thanksgiving 94.mov",
                                      userDate: "1994-11-24")
        let b = ArchiveAngelCandidate(filename: "turkey_day_edit.mp4", fullPath: "/Volumes/X9/Restored/turkey_day_edit.mp4",
                                      captureDate: utc(1994, 11, 24), originMake: "Sony")
        let c = ArchiveAngelCandidate(filename: "clip07.dv", fullPath: "/Users/rickb/Movies/clip07.dv",
                                      inferredRecordDate: utc(1994, 11, 24), inferredDateConfidence: 0.9)
        let ka = ArchiveAngelEvent.resolve(a, now: testNow), kb = ArchiveAngelEvent.resolve(b, now: testNow)
        let kc = ArchiveAngelEvent.resolve(c, now: testNow)
        #expect(ka.key == "d:1994-11-24" && kb.key == ka.key && kc.key == ka.key, "no false split across Exports / Restored / Movies")
        #expect(ka.year == 1994 && kb.year == 1994 && kc.year == 1994)
        let other = ArchiveAngelCandidate(filename: "Thanksgiving 94 part 2.mov", fullPath: "/Volumes/LaCie/Exports/Thanksgiving 94 part 2.mov",
                                          userDate: "1994-11-25")
        #expect(ArchiveAngelEvent.resolve(other, now: testNow).key == "d:1994-11-25", "no false merge: the next day is another event")
    }

    @Test("a year or a month is NOT an event: no key (a year is not a day; two 1994 tapes under DCIM must not become one thing) — the year still counts for the cap")
    func coarserDatesHaveNoKey() {
        let a = ArchiveAngelCandidate(filename: "tape 3.dv", fullPath: "/Volumes/LaCie/DCIM/tape 3.dv", userDate: "1994")
        let b = ArchiveAngelCandidate(filename: "tape 4.dv", fullPath: "/Volumes/LaCie/DCIM/tape 4.dv", userDate: "1994")
        let m = ArchiveAngelCandidate(filename: "june.dv", fullPath: "/Volumes/X9/Family/1994/june.dv", userDate: "1994-06")
        let f = ArchiveAngelCandidate(filename: "Westford_1994.mkv", fullPath: "/Volumes/X9/Imports/Westford_1994.mkv")
        for c in [a, b, m, f] {
            let r = ArchiveAngelEvent.resolve(c, now: testNow)
            #expect(r.key == "" && r.year == 1994, "\(c.filename): \(r)")
        }
        var rejected: [ArchiveAngelRejection: Int] = [:]
        let picks = [a, b, m, f].map { ArchiveAngelPick(candidate: $0, score: 10, evidence: []) }
        let cut = ArchiveAngelScorer.onePerEvent(picks, count: 4, rejected: &rejected, now: testNow)
        #expect(cut.picks.count == 4 && cut.heldBack == 0 && rejected.isEmpty, "year-only files never collapse")
    }

    @Test("a transcoder's stamp (no camera behind it) is a copy date, not an event; an undated file has no key and no year")
    func copyStampAndUndated() {
        let converted = ArchiveAngelCandidate(filename: "VHS tape 12.mov", fullPath: "/Volumes/X9/Converted_VHS_Tapes_2026/VHS tape 12.mov",
                                              captureDate: utc(2026, 4, 3), originEncoder: "Apple ProRes 422")
        let k = ArchiveAngelEvent.resolve(converted, now: testNow)
        #expect(k.key == "" && k.year == 2026, "\(k)")
        // The same stamp with a camera named IS the day it was shot.
        let shot = ArchiveAngelCandidate(filename: "clip.mov", fullPath: "/Volumes/X9/misc/clip.mov",
                                         deviceModel: "iPhone 6", captureDate: utc(2016, 4, 3))
        #expect(ArchiveAngelEvent.resolve(shot, now: testNow).key == "d:2016-04-03")
        // Conflicting conversion stamp vs a year in the name: the ONE date
        // rule files it under the name's year (rules v12) — a year, no key.
        let named = ArchiveAngelCandidate(filename: "DickyDonnaDancing1992.mov", fullPath: "/Volumes/X9/conv/DickyDonnaDancing1992.mov",
                                          captureDate: utc(2026, 4, 3), originEncoder: "Apple ProRes 422")
        #expect(ArchiveAngelEvent.resolve(named, now: testNow) == ("", 1992))
        let undated = ArchiveAngelCandidate(filename: "clip.mov", fullPath: "/Volumes/X9/misc/clip.mov")
        #expect(ArchiveAngelEvent.resolve(undated, now: testNow) == ("", nil))
    }

    // MARK: One per day

    @Test("Rick's case: five Thanksgiving-1994 variants (five names, five folders, one day) + four other years → exactly one 1994 pick and the four others")
    func fiveThanksgivings() {
        let variants = [
            video("Thanksgiving 1994.mov", folder: "/Volumes/LaCie/Holidays", year: 1994, month: 11, day: 24, minutes: 60),
            video("turkey day 94 edit.mp4", folder: "/Volumes/LaCie/iMovie Events/1994", year: 1994, month: 11, day: 24, minutes: 25),
            video("TG94_fixedup.mov", folder: "/Volumes/X9/Exports", year: 1994, month: 11, day: 24, minutes: 30),
            video("Nov 1994 dinner.dv", folder: "/Volumes/X9/Restored", year: 1994, month: 11, day: 24, minutes: 45),
            video("Grandma's thanksgiving.mov", folder: "/Users/rickb/Movies", year: 1994, month: 11, day: 24, minutes: 20),
        ]
        let others = [
            video("Christmas 1992.dv", year: 1992, month: 12, day: 25),
            video("Matt birthday 1996.dv", year: 1996, month: 3, day: 2),
            video("Cape trip 2001.mov", year: 2001, month: 7, day: 14),
            video("Reunion 2005.mov", year: 2005, month: 8, day: 20),
        ]
        let sel = ArchiveAngelScorer.select(variants + others, count: 9, policy: .builtIn, now: testNow)
        let names = sel.picks.map(\.candidate.filename)
        #expect(sel.picks.count == 9, "the batch is never left short: the four other years, one Thanksgiving, then the best variants top it up: \(names)")
        // Ask for five: one 1994 pick and the four other years, nothing topped up.
        let five = ArchiveAngelScorer.select(variants + others, count: 5, policy: .builtIn, now: testNow)
        #expect(years(of: five.picks) == [1994: 1, 1992: 1, 1996: 1, 2001: 1, 2005: 1], "\(five.picks.map(\.candidate.filename))")
        #expect(five.picks.first?.candidate.filename == "Thanksgiving 1994.mov", "the best-ranked variant (a whole tape) is the one kept")
        #expect(five.rejected[.sameEventAsPick] == 4)
        #expect(five.rejected[.yearCoverage] == nil)
        #expect(five.overflow == 0)
    }

    @Test("with onePerEvent off the five variants all pass (rules v12)")
    func onePerEventOff() {
        let variants = (0..<5).map { video("tg\($0).mov", folder: "/Volumes/X9/f\($0)", year: 1994, month: 11, day: 24) }
        let sel = ArchiveAngelScorer.select(variants, count: 9, policy: .coverageOff, now: testNow)
        #expect(sel.picks.count == 5)
        #expect(sel.rejected[.sameEventAsPick] == nil)
    }

    @Test("SCARCE DAYS: everything shot on one day → the day rule relaxes and fills the batch, counting only what it still holds back")
    func sameDayTopsUp() {
        let variants = (1...6).map { video("tg\($0).mov", folder: "/Volumes/X9/f\($0)", year: 1994, month: 11, day: 24, minutes: Double(10 + $0)) }
        let sel = ArchiveAngelScorer.select(variants, count: 4, policy: .builtIn, now: testNow)
        #expect(sel.picks.map(\.candidate.filename) == ["tg6.mov", "tg5.mov", "tg4.mov", "tg3.mov"], "rank order, longest first")
        #expect(sel.rejected[.sameEventAsPick] == 2)
    }

    // MARK: The per-year share

    @Test("a batch holds at most maxPerYearPerBatch (2) of one year when other years can fill it; the rest are held back and counted")
    func yearCapHonoured() {
        var cands: [ArchiveAngelCandidate] = []
        for d in 1...6 { cands.append(video("2010-\(d).mov", year: 2010, month: 5, day: d, minutes: 60)) }   // whole tapes: the top scores
        for d in 1...3 { cands.append(video("2011-\(d).mov", year: 2011, month: 5, day: d, minutes: 20)) }
        for d in 1...2 { cands.append(video("2012-\(d).mov", year: 2012, month: 5, day: d, minutes: 20)) }
        let sel = ArchiveAngelScorer.select(cands, count: 6, policy: .builtIn, now: testNow)
        #expect(sel.picks.count == 6)
        #expect(years(of: sel.picks) == [2010: 2, 2011: 2, 2012: 2], "\(sel.picks.map(\.candidate.filename))")
        #expect(sel.rejected[.yearCoverage] == 5, "four 2010 tapes and one 2011 file wait for a later batch")
        #expect(sel.picks.prefix(2).allSatisfy { $0.candidate.filename.hasPrefix("2010") }, "the rank order is untouched: 2010's two whole tapes lead")
    }

    @Test("SCARCE YEAR (Manager 2026-09-26: relax, a partial batch reads as nothing to do): one year only → the best held-back rows top it up, in rank order; only the rest are counted")
    func yearCapTopsUp() {
        let cands = (1...6).map { video("2010-\($0).mov", year: 2010, month: 5, day: $0, minutes: Double(10 + $0)) }
        let sel = ArchiveAngelScorer.select(cands, count: 4, policy: .builtIn, now: testNow)
        #expect(sel.picks.count == 4)
        #expect(sel.picks.map(\.candidate.filename) == ["2010-6.mov", "2010-5.mov", "2010-4.mov", "2010-3.mov"])
        #expect(sel.rejected[.yearCoverage] == 2)
        #expect(sel.overflow == 0)
    }

    @Test("maxPerYearPerBatch 0 = no cap; rows with no year are never capped (no year to spread them over — rules v12 for every undated row)")
    func capOffAndUndated() {
        var p = AngelRecommendationPolicy.builtIn
        p.coverage.maxPerYearPerBatch = 0
        let dated = (1...5).map { video("2010-\($0).mov", year: 2010, month: 5, day: $0) }
        let undated = (1...5).map { video("u\($0).mov", year: 0, dated: false) }
        #expect(ArchiveAngelScorer.select(dated, count: 5, policy: p, now: testNow).picks.count == 5)
        let sel = ArchiveAngelScorer.select(dated + undated, count: 7, policy: .builtIn, now: testNow)
        #expect(sel.picks.count == 7)
        #expect(sel.picks.filter { $0.candidate.resolvedEvent(now: testNow).year == nil }.count == 5, "undated rows all pass")
        #expect(years(of: sel.picks) == [2010: 2])
        #expect(sel.rejected[.yearCoverage] == 3)
        let ten = ArchiveAngelScorer.select(dated + undated, count: 10, policy: .builtIn, now: testNow)
        #expect(ten.picks.count == 10 && ten.rejected[.yearCoverage] == nil, "a batch of ten: every held-back row tops it up")
        // All undated: nothing to spread — rules v12, to the row.
        let allUndated = ArchiveAngelScorer.select(undated, count: 3, policy: .builtIn, now: testNow)
        let v12 = ArchiveAngelScorer.select(undated, count: 3, policy: .coverageOff, now: testNow)
        #expect(allUndated.picks.map(\.candidate.id) == v12.picks.map(\.candidate.id) && allUndated.overflow == v12.overflow
                && allUndated.rejected == v12.rejected)
    }

    // MARK: The backlog bonus — unique recordings

    @Test("the bonus counts RECORDINGS: 1,000 copies of one 1994 tape change nothing (codex D3); the deep-backlog year's file outranks the thin year's")
    func backlogCountsRecordingsNotFiles() {
        // 2010: twelve recordings to archive, two archived → 20 × 12/14 ≈ 17 points.
        // 2011: three to archive, twenty archived → under the minimum, no bonus.
        var cands: [ArchiveAngelCandidate] = []
        for d in 1...12 { cands.append(video("2010-\(d).mov", year: 2010, month: 3, day: d)) }
        for d in 1...2 { cands.append(video("2010-arch-\(d).mov", year: 2010, month: 4, day: d, archived: true)) }
        for d in 1...3 { cands.append(video("2011-\(d).mov", year: 2011, month: 3, day: d)) }
        for d in 1...20 { cands.append(video("2011-arch-\(d).mov", year: 2011, month: 4, day: d, archived: true)) }
        let table = ArchiveAngelEvent.applyCoverage(&cands, policy: .builtIn, now: testNow)
        #expect(table.years[2010] == .init(unarchived: 12, archived: 2), "\(table)")
        #expect(table.years[2011] == .init(unarchived: 3, archived: 20))
        let deep = cands.first { $0.filename == "2010-1.mov" }!
        let thin = cands.first { $0.filename == "2011-1.mov" }!
        guard case .eligible(let deepScore, let deepLines) = ArchiveAngelScorer.verdict(deep, policy: .builtIn, now: testNow),
              case .eligible(let thinScore, let thinLines) = ArchiveAngelScorer.verdict(thin, policy: .builtIn, now: testNow) else {
            Issue.record("both eligible"); return
        }
        #expect(deepScore == 50 + 17, "date 20 + richness 5 + long scene 25 + backlog 17: \(deepLines.map(\.line))")
        #expect(thinScore == 50, "\(thinLines.map(\.line))")
        #expect(deepLines.contains { $0.line == "Fills a gap — 2010 has 12 videos still to archive and 2 archived" && $0.points == 17 })
        #expect(!thinLines.contains { $0.line.hasPrefix("Fills a gap") })
        #expect(ArchiveAngelReadinessExplanation.sentence(forEvidenceLine: deepLines.last!.line)
                == "It helps fill a gap in the archive: 2010 has 12 videos still to archive and 2 archived.")
        // Now import 1,000 copies of ONE 2010 tape (one duplicate group).
        let g = UUID()
        var flooded = cands
        for i in 0..<1000 { flooded.append(video("copy-\(i).mov", folder: "/Volumes/X\(i % 7)/copies", year: 2010, month: 3, day: 1, group: g)) }
        let after = ArchiveAngelEvent.applyCoverage(&flooded, policy: .builtIn, now: testNow)
        #expect(after.years[2010] == .init(unarchived: 13, archived: 2), "one more RECORDING, not a thousand: \(after.years[2010]!)")
        #expect(after.recordings == table.recordings + 1)
        // Same recording archived once → the whole group is archived material.
        var archivedGroup = cands
        for i in 0..<5 { archivedGroup.append(video("dup-\(i).mov", year: 2010, month: 3, day: 2, archived: i == 3, group: g)) }
        let arch = ArchiveAngelEvent.applyCoverage(&archivedGroup, policy: .builtIn, now: testNow)
        #expect(arch.years[2010] == .init(unarchived: 12, archived: 3))
    }

    @Test("junk, the Angel's working copies, Live Photo halves, gone files and clips under the floor are not backlog; undated recordings have their own bucket and earn nothing")
    func backlogExcludesNoiseAndUndated() {
        var cands: [ArchiveAngelCandidate] = []
        for d in 1...10 { cands.append(video("ok-\(d).mov", year: 2003, month: 2, day: d)) }
        cands.append(video("junk.mov", year: 2003, month: 3, day: 1, disposition: .confirmedJunk))
        cands.append(video("maybe-junk.mov", year: 2003, month: 3, day: 2, disposition: .suspectedJunk))
        cands.append(video("short.mov", year: 2003, month: 3, day: 3, minutes: 1))
        var working = video("working.vs.archive.mov", year: 2003, month: 3, day: 4); working.isAngelWorkingCopy = true
        cands.append(working)
        var gone = video("gone.mov", year: 2003, month: 3, day: 5); gone.archiveStage = .manuallyDeleted
        cands.append(gone)
        cands.append(ArchiveAngelCandidate(filename: "jpegvideocomplement_7.mov", fullPath: "/Volumes/X/p/jpegvideocomplement_7.mov",
                                           durationSeconds: 180, userDate: "2003-03-06"))
        for d in 1...12 { cands.append(video("undated-\(d).mov", year: 0, dated: false)) }
        let table = ArchiveAngelEvent.applyCoverage(&cands, policy: .builtIn, now: testNow)
        #expect(table.years[2003] == .init(unarchived: 10, archived: 0), "\(table)")
        #expect(table.unknownDate == .init(unarchived: 12, archived: 0))
        let undated = cands.first { $0.filename == "undated-1.mov" }!
        #expect(undated.yearUnarchived == 0 && undated.yearArchived == 0 && undated.eventYear == nil)
        guard case .eligible(_, let lines) = ArchiveAngelScorer.verdict(undated, policy: .builtIn, now: testNow) else { Issue.record("eligible"); return }
        #expect(!lines.contains { $0.line.hasPrefix("Fills a gap") }, "twelve undated recordings earn no bonus")
        #expect(ArchiveAngelEvent.summaryLine(table).contains("undated 12 to archive"))
    }

    @Test("the bonus is off with backlogBonusMax 0, never fires without the pre-pass, and its kind is a signal — a floor with it is refused")
    func backlogBonusSwitches() throws {
        let c = video("x.mov", year: 2010, minutes: 20)
        #expect(c.yearUnarchived == 0 && c.yearArchived == 0 && c.eventKey == nil)
        guard case .eligible(let score, _) = ArchiveAngelScorer.verdict(c, policy: .builtIn, now: testNow) else { Issue.record("eligible"); return }
        #expect(score == 50, "date 20 + richness 5 + long scene 25 — no pre-pass, no bonus")
        var primed = c
        primed.eventYear = 2010; primed.yearUnarchived = 40; primed.yearArchived = 40
        #expect(ArchiveAngelScorer.backlogBonusLine(primed, coverage: .standard)?.points == 10, "half the year archived → half the bonus")
        #expect(ArchiveAngelScorer.backlogBonusLine(primed, coverage: .off) == nil)
        primed.yearUnarchived = 9
        #expect(ArchiveAngelScorer.backlogBonusLine(primed, coverage: .standard) == nil, "under backlogMinimumUnarchived")
        var floors = AngelRecommendationPolicy.builtIn
        floors.floors.append(AngelRule(id: "wrongPlace", kind: .backlogBonus))
        #expect(floors.validationProblems().contains { $0.contains("backlogBonus") && $0.contains("does not belong in floors") })
        var disabled = AngelRecommendationPolicy.builtIn
        disabled.signals = disabled.signals.map { r in var r = r; if r.id == "backlogBonus" { r.enabled = false }; return r }
        var deep = video("y.mov", year: 2010, minutes: 20)
        deep.eventYear = 2010; deep.yearUnarchived = 100; deep.yearArchived = 0
        guard case .eligible(let off, _) = ArchiveAngelScorer.verdict(deep, policy: disabled, now: testNow) else { Issue.record("eligible"); return }
        #expect(off == 50, "the signal switched off by id")
    }

    // MARK: Determinism

    @Test("the same set in any input order gives the same picks (the passes read the ranked order, never the input order)")
    func inputOrderIndependent() {
        var cands: [ArchiveAngelCandidate] = []
        for y in [1990, 1994, 1994, 1994, 2003, 2003, 2003, 2010, 2010, 2010, 2010] {
            cands.append(video("\(y)-\(cands.count).mov", year: y, month: 3, day: (cands.count % 27) + 1, minutes: Double(15 + cands.count)))
        }
        let baseline = ArchiveAngelScorer.select(cands, count: 6, policy: .builtIn, now: testNow).picks.map(\.candidate.filename)
        var generator = SplitMix(seed: 7)
        for _ in 0..<10 {
            cands.shuffle(using: &generator)
            let again = ArchiveAngelScorer.select(cands, count: 6, policy: .builtIn, now: testNow).picks.map(\.candidate.filename)
            #expect(again == baseline)
        }
    }
}

// MARK: - Coverage beyond the cutoff (cached path) + cache/walk parity

@Suite("Archive Angel coverage — beyond the band: the cached pick reads on for other years and agrees with the walk", .serialized)
@MainActor
struct ArchiveAngelCoverageCutoffTests {

    /// Top 500 rows all 1994 (distinct days, scores 200 down to 101 in
    /// bands of five equal scores), then four other years below them
    /// (scores 100 down), ids drawn from `seed`.
    private func fixture(seed: UInt64, now: Date) -> (ArchiveAngelEvidenceStore, [ArchiveAngelCandidate], [UUID: ArchiveAngelCandidate]) {
        var rng = SplitMix(seed: seed)
        var records: [UUID: ArchiveAngelEvidenceRecord] = [:]
        var live: [UUID: ArchiveAngelCandidate] = [:]
        var all: [ArchiveAngelCandidate] = []
        func add(_ c: ArchiveAngelCandidate, score: Int, year: Int) {
            var c = c
            c.id = rng.uuid()
            records[c.id] = evidence(score, year: year, now: now)
            live[c.id] = c
            all.append(c)
        }
        for i in 0..<500 {
            add(video("tg-\(i).mov", folder: "/Volumes/X/\(i % 13)", year: 1994, month: 1 + i % 12, day: 1 + i % 28,
                      minutes: 60, stars: 3, sizeBytes: 10_000_000_000 + Int64(i)), score: 200 - i / 5, year: 1994)
        }
        for (y, year) in [1990, 1998, 2004, 2011].enumerated() {
            for i in 0..<6 {
                add(video("\(year)-\(i).mov", year: year, month: 2, day: 1 + i, minutes: 20, stars: 2,
                          sizeBytes: 9_000_000_000 + Int64(i)), score: 100 - y * 6 - i, year: year)
            }
        }
        return (evidenceStore(records, now: now), all, live)
    }

    /// `select` minus the scoring: the stored score per row, the ONE rank
    /// order, then the walk's post-band passes and the fresh slots.
    private func storedWalk(_ all: [ArchiveAngelCandidate], store: ArchiveAngelEvidenceStore, count: Int,
                            policy: AngelRecommendationPolicy, now: Date) -> [ArchiveAngelPick] {
        let picks = all.map { ArchiveAngelPick(candidate: $0, score: store.record(for: $0.id)?.score ?? 0, evidence: []) }
        var rejected: [ArchiveAngelRejection: Int] = [:]
        let ranked = ArchiveAngelScorer.sortedByRank(picks)
        let cut = ArchiveAngelScorer.coverageCut(ranked, coverage: policy.coverage, count: count, rejected: &rejected, now: now)
        return ArchiveAngelScorer.withFreshSlots(cut.picks, count: count, weights: policy.weights)
    }

    @Test("CUTOFF: top 500 rows all 1994, four other years below the band → a ten-row cap-two batch is ten diverse rows from the cache AND the walk, identical, under 16 id draws, without reading the 500")
    func tenDiverseThroughBothPaths() {
        let now = testNow
        var reference: [String]?
        for seed in UInt64(1)...16 {
            let (store, all, live) = fixture(seed: seed * 7_919, now: now)
            var projected = 0
            let cached = ArchiveAngelJob.selectFromEvidence(store: store, count: 10, now: now, policy: .builtIn) { id in
                projected += 1
                return live[id]
            }
            let cachedNames = cached?.selection.picks.map(\.candidate.filename) ?? []
            #expect(cachedNames.count == 10, "seed \(seed): \(cachedNames)")
            #expect(years(of: cached?.selection.picks ?? []) == [1994: 2, 1990: 2, 1998: 2, 2004: 2, 2011: 2], "seed \(seed): \(cachedNames)")
            #expect(projected < 60, "seed \(seed): the 1994 rows past the band are skipped by their evidence year, never projected (\(projected))")
            // The walk's post-band passes over the SAME stored scores (the
            // cache carries the sweep's scores; a live walk rescores) — the
            // reference the cache must reproduce, id for id, in order.
            let expected = storedWalk(all, store: store, count: 10, policy: .builtIn, now: now)
            #expect(cached?.selection.picks.map(\.candidate.id) == expected.map(\.candidate.id), "seed \(seed): cache \(cachedNames) vs walk \(expected.map(\.candidate.filename))")
            // And the live walk, with the sweep's pre-pass, is ten diverse rows too.
            var cands = all
            ArchiveAngelEvent.applyCoverage(&cands, policy: .builtIn, now: now)
            let walked = ArchiveAngelScorer.select(cands, count: 10, policy: .builtIn, now: now, byClass: true)
            #expect(years(of: walked.picks) == [1994: 2, 1990: 2, 1998: 2, 2004: 2, 2011: 2], "seed \(seed): \(walked.picks.map(\.candidate.filename))")
            if let reference { #expect(cachedNames == reference, "seed \(seed): a different draw picked differently") } else { reference = cachedNames }
        }
    }

    @Test("SCARCE YEAR from the cache: everything 1994 → the cache would have to top up from rows it skipped, so it declines and the walk fills the batch")
    func scarceYearDeclinesCache() {
        let now = testNow
        var rng = SplitMix(seed: 3)
        var records: [UUID: ArchiveAngelEvidenceRecord] = [:]
        var live: [UUID: ArchiveAngelCandidate] = [:]
        var all: [ArchiveAngelCandidate] = []
        for i in 0..<40 {
            var c = video("tg-\(i).mov", year: 1994, month: 1 + i % 12, day: 1 + i % 28, minutes: Double(20 + i))
            c.id = rng.uuid()
            records[c.id] = evidence(150 - i, year: 1994, now: now)
            live[c.id] = c
            all.append(c)
        }
        let store = evidenceStore(records, now: now)
        #expect(ArchiveAngelJob.selectFromEvidence(store: store, count: 10, now: now, policy: .builtIn) { live[$0] } == nil)
        let walked = ArchiveAngelScorer.select(all, count: 10, policy: .builtIn, now: now)
        #expect(walked.picks.count == 10 && walked.rejected[.yearCoverage] == 30)
        // Coverage off: the cache stands, as in rules v12.
        #expect(ArchiveAngelJob.selectFromEvidence(store: store, count: 10, now: now, policy: .coverageOff) { live[$0] }?.selection.picks.count == 10)
    }

    @Test("PARITY: with coverage OFF the cache and the walk give the same ids, order and rejection counts on the cutoff fixture (rules v12)")
    func parityOffCacheEqualsWalk() {
        let now = testNow
        let (store, all, live) = fixture(seed: 99, now: now)
        let cached = ArchiveAngelJob.selectFromEvidence(store: store, count: 10, now: now, policy: .coverageOff) { live[$0] }
        let expected = storedWalk(all, store: store, count: 10, policy: .coverageOff, now: now)
        #expect(cached?.selection.picks.map(\.candidate.id) == expected.map(\.candidate.id))
        #expect(cached?.selection.picks.allSatisfy { $0.candidate.resolvedEvent(now: now).year == 1994 } == true, "v12: the ten best are all 1994")
        let walked = ArchiveAngelScorer.select(all, count: 10, policy: .coverageOff, now: now, byClass: true)
        #expect(walked.rejected[.yearCoverage] == nil && walked.rejected[.sameEventAsPick] == nil)
        #expect(cached?.selection.rejected[.yearCoverage] == nil && cached?.selection.rejected[.sameEventAsPick] == nil)
    }

    @Test("FRESHNESS: a catalog change since the sweep's snapshot declines the cache with coverage on — not with it off, not when nothing changed, not for an unstamped file")
    func catalogRevisionGuard() {
        let now = testNow
        let (stamped, _, live) = fixture(seed: 5, now: now)
        stamped.replace(with: .init(computedAt: now.addingTimeInterval(-600), complete: true, considered: stamped.consideredCount,
                                    eligible: stamped.eligibleCount, records: stamped.file!.records, catalogRevision: 5))
        #expect(ArchiveAngelJob.selectFromEvidence(store: stamped, count: 10, now: now, policy: .builtIn, catalogRevision: 6) { live[$0] } == nil)
        #expect(ArchiveAngelJob.selectFromEvidence(store: stamped, count: 10, now: now, policy: .builtIn, catalogRevision: 5) { live[$0] } != nil)
        #expect(ArchiveAngelJob.selectFromEvidence(store: stamped, count: 10, now: now, policy: .coverageOff, catalogRevision: 6) { live[$0] } != nil)
        let (unstamped, _, live2) = fixture(seed: 6, now: now)
        #expect(unstamped.catalogRevision == nil)
        #expect(ArchiveAngelJob.selectFromEvidence(store: unstamped, count: 10, now: now, policy: .builtIn, catalogRevision: 3) { live2[$0] } == nil,
                "unstamped reads as revision 0 — older than a catalog that has changed")
        #expect(ArchiveAngelJob.selectFromEvidence(store: unstamped, count: 10, now: now, policy: .builtIn, catalogRevision: 0) { live2[$0] } != nil)
        // The sweep stamps what the façade hands it.
        var stampedByFile = ArchiveAngelEvidenceFile(computedAt: now, catalogRevision: 42)
        #expect(stampedByFile.catalogRevision == 42)
        stampedByFile.catalogRevision = nil
        #expect(stampedByFile.catalogRevision == nil)
    }
}

// MARK: - Parity, end to end

@Suite("Archive Angel coverage — parity: coverage OFF is rules v12 end to end")
struct ArchiveAngelCoverageParityTests {

    @Test("PARITY: with coverage off the ids, order, scores, evidence lines, rejection and overflow counts of a frozen fixture are the rules-v12 literals")
    func parityWithCoverageOff() {
        let fixture = [
            video("d.mov", year: 1995, day: 4, minutes: 4),                           // date 20 + richness 5                     = 25
            video("c.mov", year: 1995, day: 3, minutes: 10, stars: 1),                // ★ 10 + date 20 + richness 10 + scene 10  = 50
            video("b.mov", year: 1995, day: 2, minutes: 20, stars: 2),                // ★★ 40 + date 20 + richness 10 + long 25  = 95
            video("a.mov", year: 1995, day: 1, minutes: 60, stars: 3),                // ★★★ 100 + date 20 + richness 10 + tape 60 = 190
            ArchiveAngelCandidate(filename: "e.mov", fullPath: "/Volumes/X/e.mov", sizeBytes: 10_000_000_000,
                                  durationSeconds: 240),                             // nothing to say                           = 0
            video("tiny.mov", year: 1995, day: 5, minutes: 1),                        // the 2-minute floor
            video("junk.mov", year: 1995, day: 6, disposition: .confirmedJunk),
        ]
        let sel = ArchiveAngelScorer.select(fixture, count: 4, policy: .coverageOff, now: testNow)
        #expect(sel.picks.map(\.candidate.filename) == ["a.mov", "b.mov", "c.mov", "d.mov"])
        #expect(sel.picks.map(\.score) == [190, 95, 50, 25])
        #expect(sel.picks[0].evidence.map(\.line) == ["You rated it best (★★★)", "Has date, rating", "Dated 1995-06-01 (yours)",
                                                      "Runs 1 h 0 min — likely a whole tape", "New to you — never proposed"])
        #expect(sel.picks[3].evidence.map(\.line) == ["Has date", "Dated 1995-06-04 (yours)", "New to you — never proposed"])
        #expect(sel.rejected == [.tooShort: 1, .junk: 1])
        #expect(sel.overflow == 1)
        let keys = ArchiveAngelScorer.sortedByRank(sel.picks).map { ArchiveAngelScorer.RankKey($0.candidate, score: $0.score) }
        #expect(keys.map(\.filename) == ["a.mov", "b.mov", "c.mov", "d.mov"])
        // The same fixture under the default policy: one year (five days)
        // and one undated row. 1995 keeps its two best (a, b); the undated
        // bucket keeps e; c tops the batch of four up; d is held for a
        // later batch. Scores and the rank order are untouched.
        let on = ArchiveAngelScorer.select(fixture, count: 4, policy: .builtIn, now: testNow)
        #expect(on.picks.map(\.candidate.filename) == ["a.mov", "b.mov", "c.mov", "e.mov"])
        #expect(on.picks.map(\.score) == [190, 95, 50, 0])
        #expect(on.rejected == [.tooShort: 1, .junk: 1, .yearCoverage: 1])
        #expect(on.overflow == 0)
    }
}

// MARK: - Sensor

@Suite("Archive Angel coverage — sensor: a batch never holds more than its per-year share when other years can fill it")
struct ArchiveAngelCoverageSensorTests {

    @Test("SENSOR: 40 files over 8 years, batches of 10, twenty shuffles — never more than maxPerYearPerBatch of one year, and always a full batch")
    func batchOfTenNeverOverfull() {
        var cands: [ArchiveAngelCandidate] = []
        for y in 1990...1997 {
            for d in 1...5 { cands.append(video("\(y)-\(d).mov", year: y, month: 4, day: d, minutes: Double(10 + (y * d) % 60))) }
        }
        let cap = AngelRecommendationPolicy.builtIn.coverage.maxPerYearPerBatch
        var generator = SplitMix(seed: 42)
        for round in 0..<20 {
            cands.shuffle(using: &generator)
            let sel = ArchiveAngelScorer.select(cands, count: 10, policy: .builtIn, now: testNow)
            #expect(sel.picks.count == 10, "round \(round)")
            let perYear = years(of: sel.picks)
            #expect(perYear.values.max() ?? 0 <= cap, "round \(round): \(perYear)")
            #expect(perYear.count >= 5, "round \(round): ten picks spread over at least five years: \(perYear)")
        }
    }
}

// MARK: - Isolation

@Suite("Archive Angel coverage — isolation: a poisoned or absent policy file falls back to the coverage defaults", .serialized)
@MainActor
struct ArchiveAngelCoverageIsolationTests {

    @Test("POISONED: garbage, a bad coverage number, or a missing file → coverage == .standard, never a half-read rule",
          arguments: ["not json", #"{"schemaVersion": 2, "coverage": {"maxPerYearPerBatch": -1}}"#,
                      #"{"schemaVersion": 2, "coverage": {"backlogBonusMax": 99999}}"#, "ABSENT"])
    func poisonedFallsBack(text: String) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("angel-coverage-iso-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("policy.json")
        if text != "ABSENT" { try Data(text.utf8).write(to: url) }
        let loaded = AngelRecommendationPolicy.load(overrideURL: url, bundledURL: nil)
        #expect(loaded.source == .builtIn)
        #expect(loaded.policy.coverage == .standard)
        #expect(loaded.policy.coverage.maxPerYearPerBatch == 2 && loaded.policy.coverage.onePerEvent)
        if text != "ABSENT" { #expect(loaded.notices.first?.contains("refused") == true, "\(loaded.notices)") }
    }
}

// MARK: - Scale

@Suite("Archive Angel coverage — scale")
struct ArchiveAngelCoverageScaleTests {

    @Test("100k candidates through the coverage pre-pass (dates, recordings, the per-year table) ≤ 1 s Debug", .timeLimit(.minutes(1)))
    func prePassAtScale() {
        var cands: [ArchiveAngelCandidate] = []
        cands.reserveCapacity(100_000)
        let names = ["Rick-and-Matt-11-19-2005.m4v", "Westford_1994.mkv", "Christmas1995Etc.mkv", "tape7.dv",
                     "Vacation 2003-07-04 beach.mov", "IMG_1995.MOV", "June 1994 cookout.dv", "clip.mov"]
        var group = UUID()
        for i in 0..<100_000 {
            if i % 3 == 0 { group = UUID() }
            let name = names[i % names.count]
            cands.append(ArchiveAngelCandidate(
                filename: name, fullPath: "/Volumes/V\(i % 5)/Family/\(1990 + i % 30)/\(i % 400)/" + name,
                sizeBytes: 5_000_000_000, durationSeconds: Double(30 + i % 4000),
                userDate: i % 5 == 0 ? "\(1990 + i % 30)-0\(1 + i % 9)-1\(i % 9)" : (i % 7 == 0 ? "\(1990 + i % 30)" : nil),
                inferredRecordDate: i % 11 == 0 ? Date(timeIntervalSince1970: Double(i) * 1000) : nil,
                inferredDateConfidence: i % 22 == 0 ? 0.9 : 0.4,
                hasArchivedDuplicate: i % 9 == 0,
                duplicateGroupID: i < 30_000 ? group : nil,
                captureDate: i % 4 == 0 ? Date(timeIntervalSince1970: Double(i) * 500) : nil,
                originMake: i % 3 == 0 ? "Sony" : nil))
        }
        let clock = ContinuousClock()
        let started = clock.now
        let table = ArchiveAngelEvent.applyCoverage(&cands, policy: .builtIn, now: testNow)
        let elapsed = clock.now - started
        print("[angel-coverage] 100k pre-pass in \(elapsed) · \(ArchiveAngelEvent.summaryLine(table))")
        #expect(elapsed <= PerformanceLane.loadAwareDebugCeiling(.seconds(1)), "100k pre-pass took \(elapsed)")
        #expect(cands.allSatisfy { $0.eventKey != nil }, "every candidate carries a key (empty when it has no day)")
        #expect(table.years.count > 20)
        #expect(table.recordings == 10_000 + 70_000, "30k grouped rows in threes + 70k solo")
        #expect(cands.contains { $0.yearUnarchived > 0 })
    }
}

// MARK: - The duration band, pinned unchanged (codex review, acceptance gate "Duration policy")

@Suite("Archive Angel duration band — every edge pinned (rules v13 changes nothing here)")
struct ArchiveAngelDurationBandTests {

    private func score(_ seconds: Double, policy: AngelRecommendationPolicy = .builtIn) -> (rejection: ArchiveAngelRejection?, points: Int, lines: [String]) {
        let c = ArchiveAngelCandidate(sizeBytes: 10_000_000_000, durationSeconds: seconds)
        switch ArchiveAngelScorer.verdict(c, policy: policy, now: testNow) {
        case .rejected(let r): return (r, 0, [])
        case .eligible(let s, let lines): return (nil, s, lines.map(\.line))
        }
    }

    @Test("60 / 120 / 300 / 900 / 1800 / 3600 / 7200 s: the automatic floor at 2 min, the explicit floor at 60 s, the tiers, and no ceiling")
    func edges() {
        #expect(score(0).rejection == .tooShort, "a missing duration is too short")
        #expect(score(59).rejection == .tooShort && score(60).rejection == .tooShort && score(119).rejection == .tooShort)
        #expect(score(120).rejection == nil && score(120).points == 0 && score(120).lines.isEmpty, "2 min: eligible, no length line")
        #expect(score(299).points == 0 && score(300).points == 10 && score(300).lines == ["Runs 5 min 0 s — a full scene"])
        #expect(score(899).points == 10 && score(900).points == 25)
        #expect(score(1799).points == 25 && score(1800).points == 45)
        #expect(score(3599).points == 45 && score(3600).points == 60)
        #expect(score(7200).points == 60 && score(7200).lines == ["Runs 2 h 0 min — likely a whole tape"])
        #expect(score(3 * 3600).points == 60 && score(6 * 3600).points == 60, "no ceiling — a two-tape capture is still the whole thing")
        let explicit = AngelRecommendationPolicy.builtIn.forExplicitPicks()
        #expect(score(59, policy: explicit).rejection == .tooShort)
        #expect(score(60, policy: explicit).rejection == nil && score(60, policy: explicit).points == 0, "an explicit 60 s pick passes and earns nothing")
        #expect(ArchiveAngelScorer.durationTier(299) == nil && ArchiveAngelScorer.durationTier(300)?.points == 10)
        #expect(ArchiveAngelScorer.durationTier(7200)?.points == 60)
    }

    @Test("SENSOR: non-finite durations — NaN passes the floor and earns nothing; +∞ is read as a whole tape but fails the bitrate floor; a negative value is too short")
    func nonFinite() {
        #expect(score(.nan).rejection == nil && score(.nan).points == 0, "NaN compares false everywhere: eligible, no length line")
        #expect(score(.infinity).rejection == .proxyStream, "bytes ÷ ∞ = 0 kbit/s")
        #expect(ArchiveAngelScorer.durationTier(.infinity)?.points == 60)
        #expect(score(-1).rejection == .tooShort)
        #expect(ArchiveAngelScorer.durationTier(.nan) == nil)
    }

    @Test("the band's edges are the policy keys they always were; the tiers must rise; the defaults are today's numbers")
    func edgesArePolicyKeys() {
        let w = ArchiveAngelWeights.standard
        #expect(w.minimumDurationSeconds == 120 && w.explicitPickMinimumDurationSeconds == 60)
        #expect(w.sceneSeconds == 300 && w.longSceneSeconds == 900 && w.halfTapeSeconds == 1800 && w.wholeTapeSeconds == 3600)
        #expect(w.durationScene == 10 && w.durationLongScene == 25 && w.durationHalfTape == 45 && w.durationWholeTape == 60)
        var p = AngelRecommendationPolicy.builtIn
        p.weights.sceneSeconds = 2000
        #expect(p.validationProblems().contains { $0.contains("duration tiers must rise") })
        var longer = AngelRecommendationPolicy.builtIn
        longer.weights.minimumDurationSeconds = 300
        #expect(score(240, policy: longer).rejection == .tooShort && score(300, policy: longer).points == 10)
    }
}
