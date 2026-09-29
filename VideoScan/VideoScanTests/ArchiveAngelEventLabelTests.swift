// ArchiveAngelEventLabelTests.swift
// Rules v14 event labels in the Archive Angel (2026-09-29; the pure labeler
// is VideoScanCore's EventLabeler, pinned by EventLabelerTests):
//
//   LOGIC      Christmas on Dec 24 and Dec 25 is ONE event; a year-only
//              "xmas94" tape joins it; a family birthday ±3 days is one
//              event per person per year; a copy-era stamp keys nothing;
//              the multi-key claim; the policy keys (defaults, older
//              files, validation, typos); the Readiness "Occasion" fact.
//   PARITY     coverage.eventLabels OFF → every key is v13's day key byte
//              for byte and the picks are v13's; ON differs on the same
//              fixture (so the parity is not vacuous).
//   CACHE=WALK the evidence path and the walk agree with labels and
//              birthdays on.
//   SCALE      100k candidates labelled + the coverage pre-pass, off the
//              main actor, within the 1 s Debug budget.
//   ISOLATION  a test host's environment never reads the People tab; a
//              hand-edited UTC-midnight birthdate means its own day in any
//              process time zone; birthdays are dropped with labels off.
//   SENSOR     a batch never holds two picks sharing a labelled event key
//              when other events can fill it — walk and cache, 24 draws.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private let labelNow = Date(timeIntervalSince1970: 1_790_000_000)   // 2026-09-21

/// A dull dated video: its date and length (and stars) are all that score it.
private func clip(_ name: String, folder: String = "/Volumes/LaCie/Family", date: String?, minutes: Double = 30,
                  stars: Int = 0, size: Int64 = 10_000_000_000) -> ArchiveAngelCandidate {
    ArchiveAngelCandidate(filename: name, fullPath: folder + "/" + name, sizeBytes: size,
                          durationSeconds: minutes * 60, starRating: stars, userDate: date)
}

private func labelPolicy(labels: Bool, window: Int = 3, cap: Int = 2) -> AngelRecommendationPolicy {
    var p = AngelRecommendationPolicy.builtIn
    p.coverage.eventLabels = labels
    p.coverage.birthdayWindowDays = window
    p.coverage.maxPerYearPerBatch = cap
    return p
}

private func utcNoon(_ y: Int, _ m: Int, _ d: Int) -> Date {
    var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = 12
    return ArchiveAngelCandidate.utcCalendar.date(from: c)!
}

/// The labelled ("e:…") parts of a key.
private func labelled(_ key: String?) -> [String] {
    (key ?? "").split(separator: "|").map(String.init).filter { $0.hasPrefix("e:") }
}

/// Rules v13's key, computed here from the ONE date rule — the parity oracle.
private func v13Key(_ c: ArchiveAngelCandidate, now: Date) -> String {
    let r = RecordDateResolver.resolve(userDate: c.userDate, userDateConfidence: c.userDateConfidence,
                                       embeddedCreationDate: c.captureDate, originMake: c.originMake,
                                       originModel: c.deviceModel.isEmpty ? nil : c.deviceModel,
                                       originEncoder: c.originEncoder, inferredRecordDate: c.inferredRecordDate,
                                       inferredDateConfidence: c.inferredDateConfidence,
                                       inferredDateRange: c.inferredDateRange,
                                       filename: c.filename.isEmpty ? nil : c.filename, now: now)
    guard r.year != nil, r.precision == .day,
          r.source != .embedded || r.confidence >= ArchiveAngelEvent.dayKeyMinimumConfidence else { return "" }
    return "d:" + r.isoString
}

private let timmy = FamilyBirthday(name: "Timmy", born: EventDay(year: 1982, month: 4, day: 22))

/// A seeded generator (≈ std::mt19937 with a fixed seed).
private struct LabelRNG: RandomNumberGenerator {
    var state: UInt64
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

/// A mixed catalog: Christmas and Thanksgiving over several days, xmas
/// tapes with only a year, Timmy's birthday week, beach trips, and plenty
/// of ordinary days in many years so every batch CAN be filled without a
/// repeat. Shuffled by `seed`; scores tie often (the A4 case).
private func mixedCatalog(seed: UInt64) -> [ArchiveAngelCandidate] {
    var rng = LabelRNG(state: seed)
    var out: [ArchiveAngelCandidate] = []
    for y in [1990, 1994, 1998] {
        for d in 24...26 { out.append(clip("christmas_\(y)_\(d).mov", date: "\(y)-12-\(d)", minutes: 60, stars: 3)) }
        out.append(clip("xmas\(y % 100)_tape\(y % 7).mov", folder: "/Volumes/X9/Tapes", date: "\(y)", minutes: 60, stars: 3))
        for d in 20...25 { out.append(clip("timmy\(y)_\(d).mov", folder: "/Volumes/X9/Spring", date: "\(y)-04-\(d)", minutes: 45, stars: 3)) }
        for d in 1...4 { out.append(clip("shore\(y)-\(d).mov", folder: "/Volumes/LaCie/Beach", date: "\(y)-08-\(d + 10)", minutes: 45, stars: 3)) }
    }
    for (y, d) in [(1994, 24), (1998, 26)] { for k in -1...1 { out.append(clip("turkey\(y)_\(k + 1).mov", date: "\(y)-11-\(d + k)", minutes: 50, stars: 3)) } }
    for i in 0..<40 {
        let y = 1985 + i
        out.append(clip("tape\(i).dv", folder: "/Volumes/LaCie/Misc\(i % 3)", date: "\(y)-09-\(10 + i % 9)", minutes: 40, stars: 2))
    }
    out.shuffle(using: &rng)
    return out
}

// MARK: - Logic

@Suite("Archive Angel event labels — logic")
struct ArchiveAngelEventLabelTests {

    @Test("Christmas on Dec 24 and Dec 25 is ONE event (labels on), two days (labels off); the key keeps the day")
    func christmasAcrossDays() {
        let eve = clip("eve.mov", date: "1994-12-24"), day = clip("morning.mov", date: "1994-12-25")
        #expect(ArchiveAngelEvent.resolve(eve, now: labelNow).key == "e:christmas:1994|d:1994-12-24")
        #expect(ArchiveAngelEvent.resolve(day, now: labelNow).key == "e:christmas:1994|d:1994-12-25")
        var seen: Set<String> = []
        #expect(ArchiveAngelEvent.claim(ArchiveAngelEvent.resolve(eve, now: labelNow).key, in: &seen))
        #expect(!ArchiveAngelEvent.claim(ArchiveAngelEvent.resolve(day, now: labelNow).key, in: &seen), "same Christmas → held")

        // Through select: the better Christmas row stays, the other waits.
        var cands = [clip("eve.mov", date: "1994-12-24", stars: 3), clip("morning.mov", date: "1994-12-25", stars: 2)]
        for i in 0..<12 { cands.append(clip("other\(i).mov", date: "\(1980 + i)-09-1\(i % 9)", stars: 1)) }
        for labels in [true, false] {
            let p = labelPolicy(labels: labels, cap: 0)
            var c = cands
            ArchiveAngelEvent.applyCoverage(&c, policy: p, now: labelNow)
            let sel = ArchiveAngelScorer.select(c, count: 10, policy: p, now: labelNow)
            let names = Set(sel.picks.map(\.candidate.filename))
            #expect(names.contains("eve.mov"))
            #expect(names.contains("morning.mov") == !labels, "labels \(labels): \(names.sorted())")
            #expect((sel.rejected[.sameEventAsPick] ?? 0) == (labels ? 1 : 0))
        }
    }

    @Test("a year-only 'xmas94' tape is Christmas 1994 — one event with a Dec 25 1994 file, not with 1995")
    func yearOnlyNameJoins() {
        let tape = clip("xmas94_tape2.mov", folder: "/Volumes/X9/Tapes", date: "1994")
        let key = ArchiveAngelEvent.resolve(tape, now: labelNow).key
        #expect(key == "e:christmas:1994", "a year is not a day — only the occasion keys it")
        var seen: Set<String> = []
        #expect(ArchiveAngelEvent.claim(ArchiveAngelEvent.resolve(clip("x.mov", date: "1994-12-25"), now: labelNow).key, in: &seen))
        #expect(!ArchiveAngelEvent.claim(key, in: &seen))
        #expect(ArchiveAngelEvent.claim(ArchiveAngelEvent.resolve(clip("xmas95.mov", date: "1995"), now: labelNow).key, in: &seen))
        // A year-only file with no event word still has no key (v13's coarser-date rule).
        #expect(ArchiveAngelEvent.resolve(clip("tape 3.dv", date: "1994"), now: labelNow).key == "")
    }

    @Test("a family birthday (injected) ±3 days is one event per person per year; without birthdays the day stands alone")
    func birthdays() {
        let ctx = ArchiveAngelEventContext(coverage: .standard, birthdays: [timmy])
        let a = ArchiveAngelEvent.resolve(clip("a.mov", date: "1994-04-24"), now: labelNow, context: ctx).key
        let b = ArchiveAngelEvent.resolve(clip("b.mov", date: "1994-04-21"), now: labelNow, context: ctx).key
        #expect(a == "e:birthday:timmy:1994|d:1994-04-24")
        #expect(labelled(a) == labelled(b))
        #expect(ArchiveAngelEvent.resolve(clip("c.mov", date: "1994-04-26"), now: labelNow, context: ctx).key == "d:1994-04-26")
        #expect(ArchiveAngelEvent.resolve(clip("a.mov", date: "1994-04-24"), now: labelNow).key == "d:1994-04-24", "no birthdays injected")
        // Through the pre-pass: the birthdays argument reaches the keys.
        var cands = [clip("a.mov", date: "1994-04-24")]
        ArchiveAngelEvent.applyCoverage(&cands, policy: .builtIn, now: labelNow, birthdays: [timmy])
        #expect(cands[0].eventKey == a)
        let labels = ArchiveAngelEvent.labels(clip("a.mov", date: "1994-04-24"), now: labelNow, context: ctx)
        #expect(labels.map(\.reason) == ["2 days after Timmy's 12th birthday"])
    }

    @Test("a copy-era stamp (transcoder only) keys nothing and lends no year to a name word")
    func untrustedStamp() {
        let copy = ArchiveAngelCandidate(filename: "xmas_export.mov", fullPath: "/Volumes/X/xmas_export.mov",
                                         captureDate: utcNoon(2008, 12, 25), originEncoder: "Lavf58.29.100")
        #expect(ArchiveAngelEvent.resolve(copy, now: labelNow).key == "")
        let labels = ArchiveAngelEvent.labels(copy, now: labelNow, context: .builtIn)
        #expect(labels.map(\.event) == ["christmas"], "Readiness still says what the name says")
        #expect(labels.first?.year == nil && labels.first?.key == nil)
    }

    @Test("claim: a row is held when ANY of its events is taken; a held row claims nothing; an empty key never collapses")
    func claimSemantics() {
        var seen: Set<String> = []
        #expect(ArchiveAngelEvent.claim("a|b", in: &seen))
        #expect(!ArchiveAngelEvent.claim("b|c", in: &seen))
        #expect(ArchiveAngelEvent.claim("c", in: &seen), "the held row did not claim c")
        #expect(!ArchiveAngelEvent.claim("c", in: &seen))
        #expect(ArchiveAngelEvent.claim("", in: &seen) && ArchiveAngelEvent.claim("", in: &seen))
        #expect(seen == ["a", "b", "c"])
    }

    @Test("an ordinary day with no label keeps v13's key exactly")
    func ordinaryDay() {
        #expect(ArchiveAngelEvent.resolve(clip("clip.mov", date: "1994-08-14"), now: labelNow).key == "d:1994-08-14")
    }

    @Test("policy: eventLabels ON and a 3-day window by default; a v13 file loads with them; bad window refused; typo noted")
    func policyKeys() throws {
        #expect(AngelCoverageRules.standard.eventLabels && AngelCoverageRules.standard.birthdayWindowDays == 3)
        #expect(!AngelCoverageRules.off.eventLabels)
        let v13 = Data(#"{"onePerEvent": true, "maxPerYearPerBatch": 2, "backlogBonusMax": 20, "backlogMinimumUnarchived": 10}"#.utf8)
        let old = try JSONDecoder().decode(AngelCoverageRules.self, from: v13)
        #expect(old == .standard, "a policy written before v14 reads with today's labels")

        func load(_ json: String) -> (Result<AngelRecommendationPolicy, AngelRecommendationPolicy.LoadFailure>, [String]) {
            var notes: [String] = []
            let r = AngelRecommendationPolicy.decodeValidated(from: URL(fileURLWithPath: "/tmp/p.json"),
                                                              read: { _ in Data(json.utf8) }, notes: { notes = $0 })
            return (r, notes)
        }
        let off = load(#"{"schemaVersion": 2, "coverage": {"eventLabels": false, "birthdayWindowDays": 7}}"#)
        let offPolicy = try off.0.get()
        #expect(!offPolicy.coverage.eventLabels && offPolicy.coverage.birthdayWindowDays == 7)
        let wide = load(#"{"schemaVersion": 2, "coverage": {"birthdayWindowDays": 15}}"#)
        if case .failure(.invalid(let problems)) = wide.0 {
            #expect(problems.contains { $0.hasPrefix("coverage.birthdayWindowDays = 15") })
        } else {
            Issue.record("a 15-day window must be refused: \(wide.0)")
        }
        let typo = load(#"{"schemaVersion": 2, "coverage": {"eventLabel": false}}"#)
        #expect((try? typo.0.get())?.coverage.eventLabels == true, "the typo is ignored, the default applies")
        #expect(typo.1.contains { $0.contains("coverage.eventLabel") }, "and named: \(typo.1)")
    }

    @Test("Readiness: the Occasion fact groups reasons by occasion; the batch-limit sentence names occasions")
    func readiness() {
        let labels = EventLabeler.labels(day: EventDay(year: 1994, month: 12, day: 25), year: 1994,
                                         filename: "xmas morning.mov", fullPath: "/Volumes/X/Family/xmas morning.mov",
                                         birthdays: [FamilyBirthday(name: "Noel", born: EventDay(year: 1990, month: 12, day: 26))])
        #expect(ArchiveAngelReadinessExplanation.occasionValue(labels)
                == "Christmas 1994 (Dec 25 — Christmas; file name says 'xmas'), Noel's birthday 1994 (1 day before Noel's 4th birthday)")
        var f = ArchiveAngelRowFacts(id: UUID(), filename: "xmas morning.mov", fullPath: "/Volumes/X/Family/xmas morning.mov", kind: .ready)
        #expect(!ArchiveAngelReadinessExplanation.make(f).facts.contains { $0.label == "Occasion" }, "no labels → no Occasion line")
        f.occasions = labels
        let facts = ArchiveAngelReadinessExplanation.make(f).facts
        #expect(Array(facts.map(\.label).prefix(3)) == ["Date", "Occasion", "Sound"])
        #expect(ArchiveAngelReadinessExplanation.sentence(forReason: ArchiveAngelRejection.sameEventAsPick.rawValue)?
                    .contains("same day or occasion") == true)
    }
}

// MARK: - Parity

@Suite("Archive Angel event labels — parity with rules v13")
struct ArchiveAngelEventLabelParityTests {

    @Test("labels OFF: every key is v13's day key byte for byte and the picks equal v13's; labels ON differs on the same catalog")
    func offIsV13() {
        for seed in UInt64(1)...6 {
            let base = mixedCatalog(seed: seed * 104_729)
            let off = labelPolicy(labels: false)
            var offCands = base
            ArchiveAngelEvent.applyCoverage(&offCands, policy: off, now: labelNow, birthdays: [timmy])
            #expect(offCands.allSatisfy { $0.eventKey == v13Key($0, now: labelNow) }, "seed \(seed)")
            // v13's picks: the same pass with the oracle's keys written in.
            var v13Cands = base
            ArchiveAngelEvent.applyCoverage(&v13Cands, policy: off, now: labelNow)
            for i in v13Cands.indices { v13Cands[i].eventKey = v13Key(v13Cands[i], now: labelNow) }
            let a = ArchiveAngelScorer.select(offCands, count: 10, policy: off, now: labelNow, byClass: true)
            let b = ArchiveAngelScorer.select(v13Cands, count: 10, policy: off, now: labelNow, byClass: true)
            #expect(a == b, "seed \(seed): \(a.picks.map(\.candidate.filename)) vs \(b.picks.map(\.candidate.filename))")

            let on = labelPolicy(labels: true)
            var onCands = base
            ArchiveAngelEvent.applyCoverage(&onCands, policy: on, now: labelNow, birthdays: [timmy])
            #expect(onCands.contains { $0.eventKey != v13Key($0, now: labelNow) }, "the fixture exercises the labels")
        }
    }
}

// MARK: - Cache = walk

@Suite("Archive Angel event labels — the cache and the walk agree")
@MainActor
struct ArchiveAngelEventLabelCacheTests {

    @Test("with labels and a birthday on, the evidence path's picks are the walk's, id for id, over 8 draws")
    func cacheEqualsWalk() {
        let policy = labelPolicy(labels: true)
        let events = ArchiveAngelEventContext(coverage: policy.coverage, birthdays: [timmy])
        for seed in UInt64(1)...8 {
            var rng = LabelRNG(state: seed &* 7_919)
            var all = mixedCatalog(seed: seed)
            for i in all.indices { all[i].id = rng.uuid() }
            var records: [UUID: ArchiveAngelEvidenceRecord] = [:]
            var live: [UUID: ArchiveAngelCandidate] = [:]
            for c in all {
                guard case .eligible(let score, _) = ArchiveAngelScorer.verdict(c, policy: policy, now: labelNow) else { continue }
                var r = ArchiveAngelEvidenceRecord(score: score, lines: [.init(points: score, line: "why")], rejection: nil,
                                                   useCount: 0, lastUsed: nil, computedAt: labelNow)
                r.recommendation = .ready
                r.year = ArchiveAngelEvent.resolve(c, now: labelNow).year
                records[c.id] = r
                live[c.id] = c
            }
            let store = ArchiveAngelEvidenceStore(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("test_angel_labels_\(UUID().uuidString.prefix(8))"))
            store.replace(with: .init(computedAt: labelNow.addingTimeInterval(-600), complete: true, considered: records.count,
                                      eligible: records.count, records: records))
            let cached = ArchiveAngelJob.selectFromEvidence(store: store, count: 10, now: labelNow, policy: policy,
                                                            birthdays: [timmy]) { live[$0] }
            // The walk over the SAME stored scores (the cache carries the sweep's).
            let picks = live.values.map { ArchiveAngelPick(candidate: $0, score: records[$0.id]?.score ?? 0, evidence: []) }
            var rejected: [ArchiveAngelRejection: Int] = [:]
            let ranked = ArchiveAngelScorer.onePerFamily(ArchiveAngelScorer.sortedByRank(picks), rejected: &rejected)
            let cut = ArchiveAngelScorer.coverageCut(ranked, coverage: policy.coverage, count: 10, rejected: &rejected,
                                                     now: labelNow, events: events)
            let walked = ArchiveAngelScorer.withFreshSlots(cut.picks, count: 10, weights: policy.weights)
            if let cached {
                #expect(cached.selection.picks.map(\.candidate.id) == walked.map(\.candidate.id),
                        "seed \(seed): \(cached.selection.picks.map(\.candidate.filename)) vs \(walked.map(\.candidate.filename))")
            }
            // Either way, the walk's batch holds each labelled occasion once.
            let keys = walked.flatMap { labelled(ArchiveAngelEvent.resolve($0.candidate, now: labelNow, context: events).key) }
            #expect(Set(keys).count == keys.count, "seed \(seed): \(keys.sorted())")
        }
    }
}

// MARK: - Scale

@Suite("Archive Angel event labels — scale")
struct ArchiveAngelEventLabelScaleTests {

    @Test("100k candidates labelled (holidays, name words, 20 birthdays) + the coverage pre-pass, OFF the main actor, ≤ 1 s Debug",
          .timeLimit(.minutes(1)))
    func hundredThousand() async {
        let elapsed = await Task.detached(priority: .userInitiated) { () -> (Duration, Int, Int, Duration) in
            var cands: [ArchiveAngelCandidate] = []
            cands.reserveCapacity(100_000)
            let names = ["xmas94_tape2.mov", "Christmas Morning.mov", "tape7.dv", "Vacation beach.mov", "IMG_1995.MOV",
                         "Timmy bday party.mov", "clip.mov", "Thanksgiving dinner.dv", "capetown.mov", "recital.m4v"]
            let folders = ["Family", "Christmas 1994", "Cape Cod", "Misc", "DCIM"]
            var birthdays: [FamilyBirthday] = []
            for p in 0..<20 { birthdays.append(FamilyBirthday(name: "P\(p)", born: EventDay(year: 1930 + p * 3, month: 1 + p % 12, day: 1 + p))) }
            var group = UUID()
            for i in 0..<100_000 {
                if i % 3 == 0 { group = UUID() }
                // Half the names unique (the per-pass name memo must not be what makes the budget).
                let name = i % 2 == 0 ? names[i % names.count] : "\(i)_" + names[i % names.count]
                let y = 1985 + i % 35
                let date: String? = i % 4 == 0 ? "\(y)"
                    : (i % 4 == 1 ? String(format: "%04d-%02d-%02d", y, 1 + i % 12, 1 + i % 28)
                                  : (i % 4 == 2 ? String(format: "%04d-12-%02d", y, 23 + i % 5) : nil))
                cands.append(ArchiveAngelCandidate(
                    filename: name, fullPath: "/Volumes/V\(i % 5)/\(folders[i % folders.count])/\(i % 400)/" + name,
                    sizeBytes: 5_000_000_000, durationSeconds: Double(30 + i % 4000), userDate: date,
                    duplicateGroupID: i < 30_000 ? group : nil,
                    captureDate: i % 7 == 0 ? Date(timeIntervalSince1970: Double(i) * 500) : nil,
                    originMake: i % 3 == 0 ? "Sony" : nil))
            }
            let clock = ContinuousClock()
            // Reference only (not budgeted): the same pass with labels off = rules v13's cost.
            var reference = cands
            let refStart = clock.now
            ArchiveAngelEvent.applyCoverage(&reference, policy: labelPolicy(labels: false), now: labelNow, birthdays: birthdays)
            let v13 = clock.now - refStart
            let started = clock.now
            ArchiveAngelEvent.applyCoverage(&cands, policy: .builtIn, now: labelNow, birthdays: birthdays)
            let took = clock.now - started
            let labelledCount = cands.filter { !labelled($0.eventKey).isEmpty }.count
            let unkeyed = cands.filter { $0.eventKey == nil }.count
            return (took, labelledCount, unkeyed, v13)
        }.value
        print("[angel-labels] 100k labelled pre-pass in \(elapsed.0) (labels off: \(elapsed.3)) · \(elapsed.1) labelled")
        #expect(elapsed.0 <= PerformanceLane.loadAwareDebugCeiling(.seconds(1)), "100k labelled pre-pass took \(elapsed.0)")
        #expect(elapsed.1 > 30_000, "the fixture labels a real share (\(elapsed.1))")
        #expect(elapsed.2 == 0)
    }
}

// MARK: - Isolation

@Suite("Archive Angel event labels — isolation")
struct ArchiveAngelEventLabelIsolationTests {

    @Test("a test host's environment never reads the People tab; the façade under test holds no birthdays")
    @MainActor
    func testHostReadsNoProfiles() async {
        #expect(AngelEnvironment.familyBirthdaysReader(isTestHost: true)().isEmpty)
        #expect(AngelEnvironment.app.isTestHost, "this suite runs under the test host")
        #expect(AngelEnvironment.app.familyBirthdays().isEmpty)
        let birthdays = await ArchiveAngel.readBirthdaysOffMain(AngelEnvironment.app.familyBirthdays)
        #expect(birthdays.isEmpty)
    }

    @Test("POISONED time zone: a hand-edited UTC-midnight birthdate is its own day in any process zone; a picker's local time reads locally")
    func birthdateDay() {
        var kiritimati = Calendar(identifier: .gregorian)
        kiritimati.timeZone = TimeZone(identifier: "Pacific/Kiritimati")!      // UTC+14
        var honolulu = Calendar(identifier: .gregorian)
        honolulu.timeZone = TimeZone(identifier: "Pacific/Honolulu")!          // UTC−10
        let handEdited = ISO8601DateFormatter().date(from: "1930-08-31T00:00:00Z")!
        for cal in [kiritimati, honolulu] {
            #expect(AngelFamilyBirthdays.day(of: handEdited, local: cal) == EventDay(year: 1930, month: 8, day: 31))
        }
        // The DatePicker stores a local time on the chosen day (here 09:30 in Honolulu).
        var c = DateComponents(); c.year = 1982; c.month = 4; c.day = 22; c.hour = 9; c.minute = 30
        let picked = honolulu.date(from: c)!
        #expect(AngelFamilyBirthdays.day(of: picked, local: honolulu) == EventDay(year: 1982, month: 4, day: 22))
        let people = AngelFamilyBirthdays.from([(name: " Ma ", born: handEdited, died: nil), (name: "No date", born: nil, died: nil),
                                                (name: "", born: handEdited, died: nil)], local: honolulu)
        #expect(people == [FamilyBirthday(name: "Ma", born: EventDay(year: 1930, month: 8, day: 31))])
    }

    @Test("labels OFF drops injected birthdays: the context carries none")
    func offDropsBirthdays() {
        #expect(ArchiveAngelEventContext(coverage: .off, birthdays: [timmy]).birthdays.isEmpty)
        #expect(ArchiveAngelEventContext(coverage: .standard, birthdays: [timmy]).birthdays == [timmy])
    }
}

// MARK: - Sensor

@Suite("Archive Angel event labels — sensor")
struct ArchiveAngelEventLabelSensorTests {

    @Test("SENSOR: with labels on, a batch of 10 never holds two picks sharing a labelled event key when other events can fill it — 24 draws")
    func neverTwoOfOneOccasion() {
        let policy = labelPolicy(labels: true, cap: 0)
        for seed in UInt64(1)...24 {
            var cands = mixedCatalog(seed: seed &* 2_654_435_761)
            ArchiveAngelEvent.applyCoverage(&cands, policy: policy, now: labelNow, birthdays: [timmy])
            let sel = ArchiveAngelScorer.select(cands, count: 10, policy: policy, now: labelNow, byClass: true)
            #expect(sel.picks.count == 10)
            let keys = sel.picks.flatMap { labelled($0.candidate.eventKey) }
            #expect(Set(keys).count == keys.count, "seed \(seed): \(sel.picks.map(\.candidate.filename))")
        }
    }
}
