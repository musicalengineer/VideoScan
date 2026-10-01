// PersonOfTheDayTests.swift
// Person of the Day (Rick 2026-10-01) — the pure selection logic in Core:
// determinism for a fixed day, the anniversary preference, the rotation
// window, privacy, an empty tree, a tree with no photos, the day maths, the
// 100k scale budget and a poisoned recent-picks store (isolation).
//
// Every person here is synthetic (public repo): "Ada Testperson" and
// friends, invented places ("Exampletown, Samplecounty, Ireland").

import Foundation
import Testing
@testable import VideoScanCore

private typealias POTD = PersonOfTheDay

private func day(_ key: String) -> POTD.Day { POTD.Day(key: key)! }

/// A deceased ancestor with no anniversary on the test days.
private func ancestor(_ n: Int, line: TreeWalk.Line = .first, portrait: Bool = false, stories: Int = 0,
                      birth: String? = nil, death: String? = nil, place: String? = nil) -> POTD.Candidate {
    POTD.Candidate(id: "@I\(n)@", name: "Person\(n) Testperson", sex: n % 2 == 0 ? "F" : "M",
                   birthDate: birth ?? "\(1800 + n % 50)", deathDate: death ?? "\(1870 + n % 50)",
                   birthPlace: place, line: line, generation: 4, hasPortrait: portrait, storyCount: stories)
}

private let datesOnly: (POTD.Day) -> (POTD.Candidate) -> POTD.Life = { today in
    { POTD.lifeFromDates($0, today: today) }
}

@Suite("PersonOfTheDay")
struct PersonOfTheDayTests {

    // MARK: Determinism

    @Test func sameDaySameCandidatesSamePick() throws {
        let people = (1...200).map { ancestor($0) }
        let today = day("2026-10-01")
        let a = try #require(POTD.pick(from: people, on: today, history: .empty, life: datesOnly(today)))
        let b = try #require(POTD.pick(from: people, on: today, history: .empty, life: datesOnly(today)))
        #expect(a == b)
        // Input order does not matter: the shuffle is keyed on (day, id).
        let c = try #require(POTD.pick(from: people.reversed(), on: today, history: .empty, life: datesOnly(today)))
        #expect(c.personID == a.personID)
    }

    @Test func differentDaysRotateThroughDifferentPeople() {
        let people = (1...200).map { ancestor($0) }
        var seen = Set<String>()
        var d = day("2026-10-01")
        for _ in 0..<30 {
            if let p = POTD.pick(from: people, on: d, history: .empty, life: datesOnly(d)) { seen.insert(p.personID) }
            d = POTD.Day(year: d.year, month: d.month, day: d.day + 1) ?? POTD.Day(year: d.year, month: d.month + 1, day: 1)!
        }
        #expect(seen.count > 10, "30 days over 200 people should not keep landing on a few: \(seen.count)")
    }

    @Test func stableHashIsProcessIndependent() {
        // Pinned value: Swift's Hasher would differ on every run; this must not.
        #expect(POTD.stableHash(Array("2026-10-01|".utf8), "@I1@") == POTD.stableHash(Array("2026-10-01|".utf8), "@I1@"))
        #expect(POTD.stableHash(Array("2026-10-01|".utf8), "@I1@") != POTD.stableHash(Array("2026-10-02|".utf8), "@I1@"))
        #expect(POTD.stableHash(Array("2026-10-01|".utf8), "@I1@") != POTD.stableHash(Array("2026-10-01|".utf8), "@I2@"))
        // QA P3-5: the exact value, computed independently (Python FNV-1a +
        // splitmix64 finaliser) — any change to the hash moves every pick.
        #expect(POTD.stableHash(Array("2026-10-01|".utf8), "@I1@") == 0x6e1c_394d_b975_2589)
    }

    // MARK: Anniversaries

    @Test func birthAnniversaryBeatsPortraitsAndStories() throws {
        var people = (1...50).map { ancestor($0, portrait: true, stories: 3) }
        people.append(ancestor(999, line: .second, birth: "1 OCT 1812", death: "1880",
                               place: "Exampletown, Samplecounty, Ireland"))
        let today = day("2026-10-01")
        let p = try #require(POTD.pick(from: people, on: today, history: .empty, life: datesOnly(today)))
        #expect(p.personID == "@I999@")
        #expect(p.reason == .bornOnThisDay(yearsAgo: 214))
        #expect(p.whyToday == "Born 214 years ago today in Exampletown, Ireland")
        #expect(p.years == "1812–1880")
        #expect(p.birthPlace == "Exampletown, Samplecounty, Ireland")
        #expect(p.reason.isOnThisDay)
    }

    @Test func deathAndMarriageAnniversariesCount() throws {
        let today = day("2026-03-04")
        let died = ancestor(1, birth: "1790", death: "4 MAR 1851", place: nil)
        let p = try #require(POTD.pick(from: [ancestor(2), died], on: today, history: .empty, life: datesOnly(today)))
        #expect(p.personID == died.id)
        #expect(p.reason == .diedOnThisDay(yearsAgo: 175))
        let married = POTD.Candidate(id: "@I7@", name: "Wed Testperson", birthDate: "1801", deathDate: "1866",
                                     marriageDates: ["4 MAR 1825"], line: .first)
        let q = try #require(POTD.pick(from: [ancestor(2), married], on: today, history: .empty, life: datesOnly(today)))
        #expect(q.personID == married.id)
        #expect(q.reason == .marriedOnThisDay(yearsAgo: 201))
        #expect(q.whyToday == "Married 201 years ago today")
    }

    @Test func qualifiedDatesNeverMakeAnAnniversary() {
        let c = POTD.Candidate(id: "@I1@", name: "Abt Testperson", birthDate: "ABT 1 OCT 1812", deathDate: "1880")
        #expect(POTD.anniversary(of: c, on: day("2026-10-01")) == nil)
        let y = POTD.Candidate(id: "@I2@", name: "Year Testperson", birthDate: "1812", deathDate: "1880")
        #expect(POTD.anniversary(of: y, on: day("2026-01-01")) == nil)
    }

    @Test func leapDayIsRememberedOnTheTwentyEighthInCommonYears() {
        let c = POTD.Candidate(id: "@I1@", name: "Leap Testperson", birthDate: "29 FEB 1904", deathDate: "1990")
        #expect(POTD.anniversary(of: c, on: day("2027-02-28")) != nil)
        #expect(POTD.anniversary(of: c, on: day("2028-02-28")) == nil)
        #expect(POTD.anniversary(of: c, on: day("2028-02-29")) != nil)
    }

    @Test func portraitTierBeatsPlainRotation() throws {
        var people = (1...100).map { ancestor($0) }
        people.append(ancestor(500, portrait: true))
        let today = day("2026-10-01")
        let p = try #require(POTD.pick(from: people, on: today, history: .empty, life: datesOnly(today)))
        #expect(p.personID == "@I500@")
        #expect(p.reason == .portrait)
        #expect(p.whyToday == "From the family's photographs")
    }

    // MARK: Rotation and stability

    @Test func rotationSkipsRecentPicksThenWaivesWhenExhausted() throws {
        let people = (1...5).map { ancestor($0) }
        let today = day("2026-10-10")
        let first = try #require(POTD.pick(from: people, on: today, history: .empty, life: datesOnly(today)))
        // Featured three days ago → skipped today.
        var h = POTD.History()
        h.record(first.personID, on: day("2026-10-07"))
        let second = try #require(POTD.pick(from: people, on: today, history: h, life: datesOnly(today)))
        #expect(second.personID != first.personID)
        // Outside the window (91 days ago, window 90) → eligible again.
        var old = POTD.History()
        old.record(first.personID, on: day("2026-07-11"))
        let again = try #require(POTD.pick(from: people, on: today, history: old, life: datesOnly(today)))
        #expect(again.personID == first.personID)
        // Everyone featured recently → rotation waived, still a pick.
        var all = POTD.History()
        for (i, c) in people.enumerated() { all.record(c.id, on: day("2026-10-0\(i + 1)")) }
        #expect(POTD.pick(from: people, on: today, history: all, life: datesOnly(today)) != nil)
    }

    @Test func rotationWindowIsConfigurable() throws {
        let people = (1...5).map { ancestor($0) }
        let today = day("2026-10-10")
        let first = try #require(POTD.pick(from: people, on: today, history: .empty, life: datesOnly(today)))
        var h = POTD.History()
        h.record(first.personID, on: day("2026-10-07"))
        let short = POTD.Options(rotationDays: 2)
        let p = try #require(POTD.pick(from: people, on: today, history: h, options: short, life: datesOnly(today)))
        #expect(p.personID == first.personID, "3 days ago is outside a 2-day window")
    }

    @Test func todaysRecordedPickIsStableEvenWhenABetterOneAppears() throws {
        var people = (1...20).map { ancestor($0) }
        let today = day("2026-10-01")
        let morning = try #require(POTD.pick(from: people, on: today, history: .empty, life: datesOnly(today)))
        var h = POTD.History()
        h.record(morning.personID, on: today)
        people.append(ancestor(77, birth: "1 OCT 1850"))   // a tree refresh adds an anniversary
        let noon = try #require(POTD.pick(from: people, on: today, history: h, life: datesOnly(today)))
        #expect(noon.personID == morning.personID)
        // …and tomorrow the history's today-entry no longer pins anything.
        let tomorrow = day("2026-10-02")
        let next = try #require(POTD.pick(from: people, on: tomorrow, history: h, life: datesOnly(tomorrow)))
        #expect(next.personID != morning.personID)
    }

    // QA P3-3: a cancelled computation picks nothing and records nothing.
    @Test func cancelledServiceCallRecordsNothing() {
        let store = PersonOfTheDayMemoryStore()
        let service = PersonOfTheDayService(store: store)
        let people = (1...30).map { ancestor($0) }
        let r = service.todaysPick(from: people, isCancelled: { true }, life: datesOnly(service.today))
        #expect(r.pick == nil)
        #expect(store.saveCount == 0)
        #expect(store.load() == .empty)
    }

    @Test func serviceRecordsOncePerDayAndUsesTheInjectedClock() throws {
        let store = PersonOfTheDayMemoryStore()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let noon = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 12))!
        let service = PersonOfTheDayService(store: store, calendar: calendar, now: { noon })
        let people = (1...30).map { ancestor($0) }
        let life = datesOnly(service.today)
        let a = try #require(service.todaysPick(from: people, life: life).pick)
        let b = try #require(service.todaysPick(from: people, life: life).pick)
        #expect(a == b)
        #expect(store.saveCount == 1)
        #expect(store.load().entry(on: day("2026-10-01"))?.personID == a.personID)
        #expect(a.day == day("2026-10-01"))
        let opener = try #require(service.opener(from: people, life: life))
        #expect(opener.hasPrefix("Today's person is \(a.name)"))
    }

    // MARK: Privacy

    @Test func livingPrivatePeopleAreNeverFeatured() {
        let today = day("2026-10-01")
        let living = POTD.Candidate(id: "@I1@", name: "Cousin Testperson", birthDate: "1 OCT 1980",
                                    birthPlace: "Exampletown, Ireland", line: .first)
        #expect(POTD.pick(from: [living], on: today, history: .empty, life: datesOnly(today)) == nil)
    }

    @Test func livingInnerCircleOnlyOnTheirBirthdayAndWithNoPrivateDetails() throws {
        let today = day("2026-10-01")
        let home = POTD.Candidate(id: "@I1@", name: "Home Testperson", birthDate: "1 OCT 1960",
                                  birthPlace: "Exampletown, Samplecounty, Ireland", isInnerCircle: true)
        let p = try #require(POTD.pick(from: [home], on: today, history: .empty, life: datesOnly(today)))
        #expect(p.isLiving)
        #expect(p.reason == .birthday)
        #expect(p.years == nil)
        #expect(p.birthPlace == nil)
        #expect(p.whyToday == "Birthday today")
        #expect(!POTD.opener(for: p).contains("1960"))
        // Not their birthday → not featured at all.
        let other = day("2026-10-02")
        #expect(POTD.pick(from: [home], on: other, history: .empty, life: datesOnly(other)) == nil)
    }

    @Test func deceasedAnniversaryIsPreferredOverALivingBirthday() throws {
        let today = day("2026-10-01")
        let home = POTD.Candidate(id: "@I1@", name: "Home Testperson", birthDate: "1 OCT 1960", isInnerCircle: true)
        let old = ancestor(2, birth: "1 OCT 1850")
        let p = try #require(POTD.pick(from: [home, old], on: today, history: .empty, life: datesOnly(today)))
        #expect(p.personID == old.id)
    }

    @Test func lifeIsAskedLazilyBestFirst() throws {
        let today = day("2026-10-01")
        let people = (1...1_000).map { ancestor($0) }
        var asked = 0
        _ = POTD.pick(from: people, on: today, history: .empty) { c in
            asked += 1
            return POTD.lifeFromDates(c, today: today)
        }
        #expect(asked == 1, "the top-ranked deceased person settles it; asked \(asked)")
    }

    @Test func undisplayableNamesAreSkipped() throws {
        let today = day("2026-10-01")
        let blank = POTD.Candidate(id: "@I1@", name: "  ?  ", birthDate: "1 OCT 1800", deathDate: "1870")
        let unknown = POTD.Candidate(id: "@I2@", name: "Unknown", birthDate: "1 OCT 1800", deathDate: "1870")
        #expect(POTD.pick(from: [blank, unknown], on: today, history: .empty, life: datesOnly(today)) == nil)
    }

    // MARK: Edges

    @Test func emptyTreeHasNoPick() {
        let today = day("2026-10-01")
        #expect(POTD.pick(from: [], on: today, history: .empty, life: datesOnly(today)) == nil)
        let service = PersonOfTheDayService(store: PersonOfTheDayMemoryStore())
        let result = service.todaysPick(from: [], life: { _ in .deceased })
        #expect(result.pick == nil)
    }

    @Test func treeWithNoPhotosStillPicksSomeoneFromBothSides() {
        var people = (1...40).map { ancestor($0, line: .first) }
        people += (41...80).map { ancestor($0, line: .second) }
        var lines = Set<TreeWalk.Line>()
        var d = day("2026-10-01")
        for _ in 0..<14 {
            if let p = POTD.pick(from: people, on: d, history: .empty, life: datesOnly(d)) {
                #expect(p.reason == .rotation)
                lines.insert(p.line)
            }
            d = POTD.Day(year: d.year, month: d.month, day: d.day + 1)!
        }
        #expect(lines == [.first, .second], "alternating days draw from both sides: \(lines)")
    }

    @Test func openerReadsNaturally() {
        let c = POTD.Candidate(id: "@I1@", name: "Ada Testperson", sex: "F", birthDate: "1 OCT 1812",
                               deathDate: "1880", birthPlace: "Exampletown, Samplecounty, Ireland",
                               relation: "the owner's 3rd-great-grandmother")
        let today = day("2026-10-01")
        let p = POTD.feature(c, today: today, life: .deceased)!
        #expect(POTD.opener(for: p) ==
                "Today's person is Ada Testperson (1812–1880), the owner's 3rd-great-grandmother. Born 214 years ago today in Exampletown, Ireland.")
    }

    @Test func shortPlaceKeepsTownAndTellingRegion() {
        #expect(POTD.shortPlace("Exampletown, Samplecounty, Ireland") == "Exampletown, Ireland")
        #expect(POTD.shortPlace("Sampleville, Middlecounty, Massachusetts, United States") == "Sampleville, Massachusetts")
        #expect(POTD.shortPlace("Exampletown, Ireland") == "Exampletown, Ireland")
        #expect(POTD.shortPlace("   ") == nil)
        #expect(POTD.shortPlace(nil) == nil)
    }

    // MARK: Day maths

    @Test func dayKeysAndOrdinals() {
        #expect(day("1970-01-01").ordinal == 0)
        #expect(day("2000-03-01").ordinal - day("2000-02-28").ordinal == 2)   // 2000 is a leap year
        #expect(day("1900-03-01").ordinal - day("1900-02-28").ordinal == 1)   // 1900 is not
        #expect(day("2026-10-01").key == "2026-10-01")
        #expect(POTD.Day(key: "2026-13-01") == nil)
        #expect(POTD.Day(key: "2026-02-30") == nil)
        #expect(POTD.Day(key: "26-10-01") == nil)
        #expect(POTD.Day(key: "2026-10-01T00") == nil)
        #expect(POTD.Day(key: "２０２６-10-01") == nil)
    }
}

// MARK: - Scale (100k candidates, time budget)

@Suite("PersonOfTheDayScale")
struct PersonOfTheDayScaleTests {

    /// Measured 2026-10-01, M4 Max, Debug (swift test): 2.0 s total for
    /// 100k — 1.8 s of it building the candidates (three GEDCOM date
    /// parses each), 0.2 s scoring + sorting + picking. Budget ≈ 3×.
    static let budget: Duration = .seconds(6)

    @Test func hundredThousandCandidatesWithinBudget() throws {
        let months = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]
        let lines: [TreeWalk.Line] = [.first, .second, .both, .none]
        let clock = ContinuousClock()
        let start = clock.now
        var people: [PersonOfTheDay.Candidate] = []
        people.reserveCapacity(100_000)
        for i in 0..<100_000 {
            let birth = "\(1 + i % 28) \(months[i % 12]) \(1700 + i % 280)"
            let death = i % 3 == 0 ? nil : "\(1 + (i / 7) % 28) \(months[(i / 5) % 12]) \(1760 + i % 260)"
            people.append(PersonOfTheDay.Candidate(
                id: "@I\(i)@", name: "Person\(i) Testperson", sex: i % 2 == 0 ? "F" : "M",
                birthDate: birth, deathDate: death, birthPlace: "Town\(i % 400), Samplecounty, Ireland",
                marriageDates: i % 4 == 0 ? ["\(1 + i % 28) JUN \(1725 + i % 280)"] : [],
                line: lines[i % 4], generation: i % 20, hasPortrait: i % 997 == 0, storyCount: i % 1_009 == 0 ? 2 : 0,
                isInnerCircle: i < 4))
        }
        let built = clock.now
        let today = PersonOfTheDay.Day(key: "2026-10-01")!
        var history = PersonOfTheDay.History()
        for k in 1...90 { history.record("@I\(k * 11)@", on: PersonOfTheDay.Day(year: 2026, month: 9, day: 1 + k % 30) ?? today) }
        let p = try #require(PersonOfTheDay.pick(from: people, on: today, history: history) {
            PersonOfTheDay.lifeFromDates($0, today: today)
        })
        let elapsed = clock.now - start
        print("[potd-scale] 100k: build \(built - start), total \(elapsed); pick \(p.personID) \(p.reason) (\(TimingBudget.loadDescription()))")
        #expect(p.reason.isOnThisDay, "with 100k day-precise dates someone has an anniversary today")
        let ceiling = TimingBudget.loadAwareDebugCeiling(Self.budget)
        #expect(elapsed < ceiling, "100k Person of the Day took \(elapsed), ceiling \(ceiling)")
    }
}

// MARK: - Isolation (a poisoned recent-picks store)

@Suite("PersonOfTheDayIsolation")
struct PersonOfTheDayIsolationTests {

    /// Remove a scratch file's potd-<UUID> directory (QA nit).
    private func removeScratch(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("potd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(PersonOfTheDayFileStore.fileName)
    }

    private let people = (1...30).map { ancestor($0) }
    private let today = day("2026-10-01")

    @Test func garbageFileLoadsEmptyAndThePickStillWorks() throws {
        let url = try scratch()
        defer { removeScratch(url) }
        try Data([0xFF, 0x00, 0x7B, 0x22]).write(to: url)
        let store = PersonOfTheDayFileStore(url: url)
        #expect(store.load() == .empty)
        let clean = POTD.pick(from: people, on: today, history: .empty, life: datesOnly(today))
        let poisoned = POTD.pick(from: people, on: today, history: store.load(), life: datesOnly(today))
        #expect(clean == poisoned)
    }

    @Test func wrongShapeAndOversizedFilesLoadEmpty() throws {
        let url = try scratch()
        defer { removeScratch(url) }
        try Data(#"{"version": "x", "entries": {"a": 1}}"#.utf8).write(to: url)
        #expect(PersonOfTheDayFileStore(url: url).load() == .empty)
        try Data(repeating: 0x20, count: PersonOfTheDayFileStore.maximumBytes + 1).write(to: url)
        #expect(PersonOfTheDayFileStore(url: url).load() == .empty)
        // A directory where the file should be.
        let dirURL = try scratch()
        defer { removeScratch(dirURL) }
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        #expect(PersonOfTheDayFileStore(url: dirURL).load() == .empty)
    }

    @Test func badRowsAreDroppedGoodRowsSurvive() throws {
        let url = try scratch()
        defer { removeScratch(url) }
        let json = """
        {"version": 1, "entries": [
          {"day": "2026-09-30", "personID": "@I3@"},
          {"day": "not-a-day", "personID": "@I4@"},
          {"day": "2026-09-29", "personID": "   "},
          {"day": 20260928, "personID": "@I5@"},
          {"day": "2026-09-30", "personID": "@I6@"},
          {"personID": "@I7@"},
          {"day": "2026-09-27", "personID": "@I8@"}
        ]}
        """
        try Data(json.utf8).write(to: url)
        let h = PersonOfTheDayFileStore(url: url).load()
        #expect(h.entries == [.init(day: "2026-09-30", personID: "@I3@"), .init(day: "2026-09-27", personID: "@I8@")])
        #expect(h.recentIDs(before: today, withinDays: 90) == ["@I3@", "@I8@"])
    }

    @Test func futureDaysAreIgnoredForRotationAndStability() throws {
        let first = try #require(POTD.pick(from: people, on: today, history: .empty, life: datesOnly(today)))
        var h = POTD.History()
        h.record(first.personID, on: day("2027-01-01"))          // a clock that went backwards
        h.record("@I999@", on: day("2026-10-02"))                 // tomorrow, someone not in the tree
        let p = try #require(POTD.pick(from: people, on: today, history: h, life: datesOnly(today)))
        #expect(p.personID == first.personID)
    }

    @Test func todaysEntryNamingSomeoneGoneOrPrivateIsIgnored() throws {
        let clean = try #require(POTD.pick(from: people, on: today, history: .empty, life: datesOnly(today)))
        var h = POTD.History()
        h.record("@I-not-in-tree@", on: today)
        #expect(POTD.pick(from: people, on: today, history: h, life: datesOnly(today)) == clean)
        // Today's entry names a living private person (poisoned on purpose).
        let living = POTD.Candidate(id: "@ILIVE@", name: "Living Testperson", birthDate: "1990")
        var h2 = POTD.History()
        h2.record(living.id, on: today)
        let p = try #require(POTD.pick(from: people + [living], on: today, history: h2, life: datesOnly(today)))
        #expect(p.personID != living.id)
    }

    @Test func hugeHistoryIsCappedAndStaysFast() throws {
        var raw: [POTD.History.Entry] = []
        var d = day("2000-01-01")
        for i in 0..<10_000 {
            raw.append(.init(day: d.key, personID: "@I\(i % 50)@"))
            d = POTD.Day(year: d.year, month: d.month, day: d.day + 1)
                ?? POTD.Day(year: d.year, month: d.month + 1, day: 1)
                ?? POTD.Day(year: d.year + 1, month: 1, day: 1)!
        }
        let h = POTD.History(entries: raw)
        #expect(h.entries.count == POTD.Options().historyLimit)
        #expect(h.entries.first?.day == raw.last?.day, "newest kept first")
        let url = try scratch()
        defer { removeScratch(url) }
        let store = PersonOfTheDayFileStore(url: url)
        try store.save(h)
        let reloaded = store.load()
        #expect(reloaded == h)
        let size = try #require((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue)
        #expect(size < PersonOfTheDayFileStore.maximumBytes)
    }

    @Test func serviceWritesOnlyToTheInjectedStore() throws {
        let url = try scratch()
        defer { removeScratch(url) }
        let service = PersonOfTheDayService(store: PersonOfTheDayFileStore(url: url), now: { Date(timeIntervalSince1970: 1_790_000_000) })
        let r = service.todaysPick(from: people, life: datesOnly(service.today))
        #expect(r.pick != nil)
        #expect(r.saved)
        #expect(FileManager.default.fileExists(atPath: url.path))
        // An unwritable location: the pick survives, `saved` says so.
        let bad = PersonOfTheDayService(store: PersonOfTheDayFileStore(url: URL(fileURLWithPath: "/dev/null/nope/potd.json")))
        let r2 = bad.todaysPick(from: people, life: datesOnly(bad.today))
        #expect(r2.pick != nil)
        #expect(!r2.saved)
    }
}
