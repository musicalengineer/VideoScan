// StewardEventGuessTests.swift
// The Same-footage card's event guess (Rick 2026-10-03: the steward should
// feel event-oriented) — StewardEventGuess.guess, one pure function.
//
// PUBLIC REPO: every name and date here is made up ("Alex", "Sam", "Jo").
//
// Logic only (pure; no disk, no defaults, no clock — the calendar is
// handed in, fixed to UTC so the suite reads the same on every Mac):
//   birthday on the day · the ±3-day window's edges · before the birth
//   year → no guess · N = 0 → "the day … was born" · several people → the
//   youngest N · a tie on it → no guess · a coarse or missing date → no
//   guess · each calendar anchor, Thanksgiving worked out for two years ·
//   a NAMED group ignores the guess · the guess rides on the built case.
// Scale: StewardScaleTests (StewardCaseBuilderTests.swift).
//
// Suites: StewardEventGuessTests · StewardFootageTitleTests

import Foundation
import Testing
@testable import VideoScan

private var utc: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    return c
}

private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
    utc.date(from: DateComponents(year: y, month: m, day: d, hour: 12)) ?? Date(timeIntervalSince1970: 0)
}

private func span(_ a: Date, _ b: Date? = nil) -> StewardEventGuess.DateSpan {
    StewardEventGuess.DateSpan(earliest: a, latest: b ?? a)
}

private let alex = StewardEventGuess.Person(displayName: "Alex", birthYear: 2005, birthMonth: 6, birthDay: 15)
private let sam = StewardEventGuess.Person(displayName: "Sam", birthYear: 1972, birthMonth: 6, birthDay: 16)
private let jo = StewardEventGuess.Person(displayName: "Jo", birthYear: 2005, birthMonth: 6, birthDay: 14)

private func guess(_ s: StewardEventGuess.DateSpan?, _ people: [StewardEventGuess.Person] = []) -> StewardEventGuess? {
    StewardEventGuess.guess(groupDateSpan: s, people: people, calendar: utc)
}

@Suite("Steward event guess — birthdays and calendar days, always as a question")
struct StewardEventGuessTests {

    // Birthdays

    @Test func aDateOnTheBirthdayIsTheNthBirthday() {
        let g = guess(span(day(2006, 6, 15)), [alex])
        #expect(g == StewardEventGuess(kind: .birthday, text: "Alex's 1st birthday"))
        #expect(g?.title == "Around Alex's 1st birthday?", "a guess always reads as a question")
        #expect(guess(span(day(2008, 6, 15)), [alex])?.text == "Alex's 3rd birthday")
        #expect(guess(span(day(2016, 6, 15)), [alex])?.text == "Alex's 11th birthday")
        #expect(guess(span(day(2027, 6, 15)), [alex])?.text == "Alex's 22nd birthday")
    }

    @Test func theWindowIsThreeDaysEitherSide() {
        #expect(StewardEventGuess.windowDays == 3)
        #expect(guess(span(day(2006, 6, 12)), [alex])?.text == "Alex's 1st birthday", "three days before")
        #expect(guess(span(day(2006, 6, 18)), [alex])?.text == "Alex's 1st birthday", "three days after")
        #expect(guess(span(day(2006, 6, 11)), [alex]) == nil, "four days before")
        #expect(guess(span(day(2006, 6, 19)), [alex]) == nil, "four days after")
    }

    @Test func footageFromBeforeThePersonWasBornIsNeverTheirBirthday() {
        #expect(guess(span(day(2004, 6, 15)), [alex]) == nil, "the year before the birth year")
        #expect(guess(span(day(1999, 6, 15)), [alex]) == nil)
        #expect(guess(span(day(2005, 6, 13)), [alex]) == nil, "two days before the birth is not 'the day Alex was born'")
    }

    @Test func theBirthYearItselfIsTheDayTheyWereBorn() {
        let g = guess(span(day(2005, 6, 15)), [alex])
        #expect(g == StewardEventGuess(kind: .bornDay, text: "the day Alex was born"))
        #expect(g?.title == "Around the day Alex was born?")
        #expect(guess(span(day(2005, 6, 17)), [alex])?.kind == .bornDay, "the days just after count")
    }

    @Test func severalPeopleTheYoungestNumberWins() {
        // 16 June 2006: Alex's 1st (the 15th, a day off) and Sam's 34th.
        #expect(guess(span(day(2006, 6, 16)), [sam, alex])?.text == "Alex's 1st birthday")
        #expect(guess(span(day(2006, 6, 16)), [alex, sam])?.text == "Alex's 1st birthday", "whatever the order")
        #expect(guess(span(day(2006, 6, 16)), [sam])?.text == "Sam's 34th birthday")
    }

    @Test func twoPeopleTiedOnTheYoungestNumberMeansNoGuessAtAll() {
        // Alex (15th) and Jo (14th) were both born in June 2005.
        #expect(guess(span(day(2006, 6, 15)), [alex, jo]) == nil)
        #expect(guess(span(day(2006, 6, 15)), [alex, jo, sam]) == nil, "an older match does not break the tie")
        // …and no calendar anchor is tried instead.
        let dec = StewardEventGuess.Person(displayName: "Alex", birthYear: 2005, birthMonth: 12, birthDay: 25)
        let dec2 = StewardEventGuess.Person(displayName: "Jo", birthYear: 2005, birthMonth: 12, birthDay: 24)
        #expect(guess(span(day(2006, 12, 25)), [dec, dec2]) == nil)
        // The same person listed twice is not a tie.
        #expect(guess(span(day(2006, 6, 15)), [alex, alex])?.text == "Alex's 1st birthday")
    }

    @Test func aBirthdayBeatsACalendarDay() {
        let christmasBaby = StewardEventGuess.Person(displayName: "Sam", birthYear: 2000, birthMonth: 12, birthDay: 25)
        #expect(guess(span(day(2006, 12, 25)), [christmasBaby])?.text == "Sam's 6th birthday")
        #expect(guess(span(day(2006, 12, 25)), [alex])?.text == "Christmas 2006")
    }

    @Test func aBirthdayNearNewYearIsFoundAcrossTheYearBoundary() {
        let newYearBaby = StewardEventGuess.Person(displayName: "Jo", birthYear: 2000, birthMonth: 1, birthDay: 2)
        #expect(guess(span(day(2003, 12, 30)), [newYearBaby])?.text == "Jo's 4th birthday", "2 January 2004 is three days on")
        let yearEndBaby = StewardEventGuess.Person(displayName: "Jo", birthYear: 2000, birthMonth: 12, birthDay: 30)
        #expect(guess(span(day(2004, 1, 2)), [yearEndBaby])?.text == "Jo's 3rd birthday", "30 December 2003 was three days back")
    }

    @Test func nobodyOlderThanTheCapAndNobodyWithoutAName() {
        #expect(StewardEventGuess.maxAge == 110)
        let longAgo = StewardEventGuess.Person(displayName: "Alex", birthYear: 1850, birthMonth: 6, birthDay: 15)
        #expect(guess(span(day(2006, 6, 15)), [longAgo]) == nil)
        let nameless = StewardEventGuess.Person(displayName: "   ", birthYear: 2005, birthMonth: 6, birthDay: 15)
        #expect(guess(span(day(2006, 6, 15)), [nameless]) == nil)
    }

    @Test func aPersonIsBuiltFromAStoredBirthdateInTheGivenCalendar() {
        let p = StewardEventGuess.Person(displayName: " Alex ", birthDate: day(2005, 6, 15), calendar: utc)
        #expect(p == alex)
    }

    // Coarse dates

    @Test func aCoarseOrMissingDateGivesNoGuess() {
        #expect(guess(nil, [alex]) == nil)
        #expect(StewardEventGuess.maxSpanDays == 14)
        #expect(guess(span(day(2006, 6, 1), day(2006, 6, 30)), [alex]) == nil, "a month-wide span is too coarse")
        #expect(guess(span(day(2006, 1, 1), day(2006, 12, 31)), [alex]) == nil, "a year-wide span")
        #expect(guess(span(day(2006, 6, 8), day(2006, 6, 22)), [alex])?.text == "Alex's 1st birthday",
                "fourteen days wide is still fine — the midpoint is the 15th")
        #expect(guess(span(day(2006, 6, 8), day(2006, 6, 23)), [alex]) == nil, "fifteen days is not")
    }

    /// A year-only date never reaches the guess: the builder hands in only
    /// day-precise dates (StewardCaseBuilder.dates).
    @Test func aYearOnlyDateIsNotDayPreciseSoNoGuessIsMade() {
        let dates = StewardCaseBuilder.dates(userDate: "2006", inferred: nil, inferredIsARange: false,
                                             embedded: nil, created: nil, calendar: utc)
        #expect(dates.best != nil && dates.dayPrecise == nil)
        let g = UUID()
        let q = StewardCaseBuilder.build(
            inputs: (0..<2).map { StewardInput(fullPath: "/Volumes/X9/a\($0).mov", footageGroupID: g, footageStrength: 1,
                                               bestDate: day(2006, 1, 1), dayPreciseDate: nil) },
            volumes: [], mountedRoots: ["/", "/Volumes/X9"], alsoCleanUpWorkingCopies: false,
            people: [StewardEventGuess.Person(displayName: "Alex", birthYear: 2005, birthMonth: 1, birthDay: 1)], calendar: utc)
        #expect(q.cases.first?.eventGuess == nil)
        #expect(q.cases.first?.title == "2 clips on 1 drive — likely the same footage · Jan 2006")
    }

    // Calendar anchors

    @Test func christmasNewYearFourthOfJulyAndHalloween() {
        #expect(guess(span(day(2006, 12, 24)))?.text == "Christmas 2006")
        #expect(guess(span(day(2006, 12, 25))) == StewardEventGuess(kind: .christmas, text: "Christmas 2006"))
        #expect(guess(span(day(2006, 12, 26))) == nil)
        #expect(guess(span(day(2006, 12, 31))) == StewardEventGuess(kind: .newYear, text: "New Year's 2007"))
        #expect(guess(span(day(2007, 1, 1)))?.text == "New Year's 2007")
        #expect(guess(span(day(2007, 1, 2))) == nil)
        #expect(guess(span(day(1998, 7, 4))) == StewardEventGuess(kind: .fourthOfJuly, text: "Fourth of July 1998"))
        #expect(guess(span(day(1998, 7, 5))) == nil)
        #expect(guess(span(day(2011, 10, 31))) == StewardEventGuess(kind: .halloween, text: "Halloween 2011"))
        #expect(guess(span(day(2011, 10, 30))) == nil)
        #expect(guess(span(day(2011, 3, 9))) == nil, "an ordinary day")
    }

    @Test func thanksgivingIsTheFourthThursdayOfNovemberGiveOrTakeADay() {
        // 2006: 1 November was a Wednesday → Thursdays 2, 9, 16, 23.
        #expect(StewardEventGuess.thanksgivingDay(year: 2006, calendar: utc) == 23)
        // 2012: 1 November was a Thursday → Thursdays 1, 8, 15, 22.
        #expect(StewardEventGuess.thanksgivingDay(year: 2012, calendar: utc) == 22)
        // 2019: 1 November was a Friday → Thursdays 7, 14, 21, 28 (the latest it can be).
        #expect(StewardEventGuess.thanksgivingDay(year: 2019, calendar: utc) == 28)

        #expect(guess(span(day(2006, 11, 23))) == StewardEventGuess(kind: .thanksgiving, text: "Thanksgiving 2006"))
        #expect(guess(span(day(2006, 11, 22)))?.text == "Thanksgiving 2006", "the day before")
        #expect(guess(span(day(2006, 11, 24)))?.text == "Thanksgiving 2006", "the day after")
        #expect(guess(span(day(2006, 11, 21))) == nil && guess(span(day(2006, 11, 25))) == nil)
        #expect(guess(span(day(2012, 11, 22)))?.text == "Thanksgiving 2012")
        #expect(guess(span(day(2012, 11, 29))) == nil, "the FIFTH Thursday of November 2012 is not Thanksgiving")
    }

    @Test func ordinalsReadRight() {
        #expect([1, 2, 3, 4, 11, 12, 13, 21, 22, 23, 101, 110].map(StewardEventGuess.ordinal)
                == ["1st", "2nd", "3rd", "4th", "11th", "12th", "13th", "21st", "22nd", "23rd", "101st", "110th"])
    }
}

@Suite("Steward Same-footage title — a name, else a guess, else the description")
struct StewardFootageTitleTests {
    private let description = "12 clips on 3 drives — likely the same footage · Jun 2006"
    private let birthday = StewardEventGuess(kind: .birthday, text: "Alex's 1st birthday")

    @Test func aNamedGroupIgnoresTheGuess() {
        let lines = StewardFootageTitle.lines(name: "The garden party", guess: birthday, description: description)
        #expect(lines == .init(title: "The garden party", caption: description, isGuess: false))
        #expect(!lines.title.contains("?"))
    }

    @Test func withNoNameTheGuessIsTheTitleAndSaysItIsAGuess() {
        let lines = StewardFootageTitle.lines(name: nil, guess: birthday, description: description)
        #expect(lines.title == "Around Alex's 1st birthday?" && lines.isGuess)
        #expect(lines.caption == "a guess from the date · " + description)
        #expect(StewardFootageTitle.lines(name: "   ", guess: birthday, description: description).isGuess, "a blank name is no name")
    }

    @Test func withNeitherTheDescriptionIsTheTitle() {
        #expect(StewardFootageTitle.lines(name: nil, guess: nil, description: description)
                == .init(title: description, caption: nil, isGuess: false))
    }

    /// End to end through the builder: twelve clips dated around a first
    /// birthday get the guess as their title and keep the plain description.
    @Test func theBuiltCaseCarriesTheGuessAndThePlainDescription() throws {
        let g = UUID()
        let inputs = (0..<12).map { i in
            StewardInput(fullPath: "/Volumes/\(["X9", "LaCie", "SanDisk"][i % 3])/tape\(i).mov", footageGroupID: g,
                         footageStrength: 1, footageRank: i, bestDate: day(2006, 6, 14 + i % 3), dayPreciseDate: day(2006, 6, 14 + i % 3))
        }
        let q = StewardCaseBuilder.build(inputs: inputs, volumes: [], mountedRoots: ["/", "/Volumes/X9", "/Volumes/LaCie", "/Volumes/SanDisk"],
                                         alsoCleanUpWorkingCopies: false, people: [alex, sam], calendar: utc)
        let c = try #require(q.cases.first)
        #expect(c.title == "Around Alex's 1st birthday?")
        #expect(c.eventGuess == birthday)
        #expect(c.plainDescription == "12 clips on 3 drives — likely the same footage · Jun 2006")
        #expect(c.detail == "a guess from the date · 12 clips on 3 drives — likely the same footage · Jun 2006")
        // With nobody in the People tab the same group is just described.
        let plain = StewardCaseBuilder.build(inputs: inputs, volumes: [], mountedRoots: ["/"], alsoCleanUpWorkingCopies: false,
                                             people: [], calendar: utc)
        #expect(plain.cases.first?.title == c.plainDescription)
    }
}
