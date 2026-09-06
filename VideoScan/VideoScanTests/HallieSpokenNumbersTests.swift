import Foundation
import Testing
@testable import VideoScan

/// Rick, 2026-09-06, on hearing his father's birth date read aloud:
/// "the way she pronounced it was '1 february 19-9'".
///
/// "21 February 1929" reached kokoro-tts as digits and lost both instances
/// of "twenty" — 2.35 s of audio against 3.17 s for the same date in words.
/// These pin the words we now choose ourselves, on both speech paths, with
/// the on-screen text untouched.
@Suite("Numbers, said the way a person says them")
struct HallieSpokenNumbersTests {

    // MARK: the reported failure

    @Test func theDateThatStartedThisReadsInFull() {
        #expect(HallieSpokenNumbers.spoken("was born 21 February 1929.")
                == "was born the twenty-first of February, nineteen twenty-nine.")
    }

    @Test func theOtherLiveDatesFromTodaysSession() {
        #expect(HallieSpokenNumbers.spoken("died 25 June 2008")
                == "died the twenty-fifth of June, two thousand eight")
        #expect(HallieSpokenNumbers.spoken("born 31 August 1930")
                == "born the thirty-first of August, nineteen thirty")
        #expect(HallieSpokenNumbers.spoken("born 4 March 1959")
                == "born the fourth of March, nineteen fifty-nine")
    }

    // MARK: years read as years

    /// 1929 is "nineteen twenty-nine", never "one thousand nine hundred
    /// twenty-nine". The century-pair reading is what makes a date sound
    /// like a date.
    @Test func yearsUseTheCenturyPairReading() {
        #expect(HallieSpokenNumbers.words(year: 1929) == "nineteen twenty-nine")
        #expect(HallieSpokenNumbers.words(year: 1994) == "nineteen ninety-four")
        #expect(HallieSpokenNumbers.words(year: 1860) == "eighteen sixty")
    }

    /// The habits English actually has, which is why this is a table and
    /// not an algorithm.
    @Test func theIrregularYearsFollowEnglishNotArithmetic() {
        #expect(HallieSpokenNumbers.words(year: 1900) == "nineteen hundred")
        #expect(HallieSpokenNumbers.words(year: 1905) == "nineteen oh five")
        #expect(HallieSpokenNumbers.words(year: 2000) == "two thousand")
        #expect(HallieSpokenNumbers.words(year: 2005) == "two thousand five")
        #expect(HallieSpokenNumbers.words(year: 2024) == "two thousand twenty-four")
    }

    @Test func aBareYearInProseIsStillExpanded() {
        #expect(HallieSpokenNumbers.spoken("Cape Cod in 1993 with Donna")
                == "Cape Cod in nineteen ninety-three with Donna")
    }

    // MARK: what must NOT be touched

    /// A file name is a name. Speaking "Cape_nineteen ninety-three.mov"
    /// would be worse than the bug this fixes.
    @Test func fileNamesAreLeftAlone() {
        for name in ["Cape_1993.mov", "Christmas1990-part1-35mins.m4v",
                     "TimmyGolfing-1965.mov", "Franklin_1990_p216.mkv"] {
            #expect(HallieSpokenNumbers.spoken(name) == name, Comment(rawValue: name))
        }
    }

    /// Counts read fine as digits and are none of this rule's business.
    /// A general number expander would find far more ways to be wrong.
    @Test func countsAndSmallNumbersAreLeftAlone() {
        #expect(HallieSpokenNumbers.spoken("123 videos") == "123 videos")
        #expect(HallieSpokenNumbers.spoken("5 children") == "5 children")
        #expect(HallieSpokenNumbers.spoken("22.7 GB") == "22.7 GB")
    }

    /// Out-of-range numbers that merely look like years.
    @Test func numbersOutsideTheYearRangeAreLeftAlone() {
        #expect(HallieSpokenNumbers.spoken("2400 records") == "2400 records")
        #expect(HallieSpokenNumbers.spoken("880 files") == "880 files")
    }

    /// A day out of range is not a day.
    @Test func animpossibleDayIsNotTreatedAsADate() {
        let text = "45 February 1929"
        #expect(!HallieSpokenNumbers.spoken(text).contains("of February"),
                Comment(rawValue: HallieSpokenNumbers.spoken(text)))
    }

    // MARK: the pieces

    @Test func ordinalsCoverEveryDayOfAMonth() {
        #expect(HallieSpokenNumbers.ordinal(day: 1) == "first")
        #expect(HallieSpokenNumbers.ordinal(day: 2) == "second")
        #expect(HallieSpokenNumbers.ordinal(day: 3) == "third")
        #expect(HallieSpokenNumbers.ordinal(day: 4) == "fourth")
        #expect(HallieSpokenNumbers.ordinal(day: 12) == "twelfth")
        #expect(HallieSpokenNumbers.ordinal(day: 20) == "twentieth")
        #expect(HallieSpokenNumbers.ordinal(day: 21) == "twenty-first")
        #expect(HallieSpokenNumbers.ordinal(day: 25) == "twenty-fifth")
        #expect(HallieSpokenNumbers.ordinal(day: 30) == "thirtieth")
        #expect(HallieSpokenNumbers.ordinal(day: 31) == "thirty-first")
        // Every day of every month produces words, never a stray digit.
        for day in 1...31 {
            // Computed outside the macro: `contains(where:)` is `rethrows`,
            // and inside #expect that reads as a throwing call.
            let said = HallieSpokenNumbers.ordinal(day: day)
            let hasDigit = said.contains { $0.isNumber }
            #expect(!hasDigit, Comment(rawValue: "day \(day) → \(said)"))
        }
    }

    // MARK: it runs on the real speech path

    /// The seam that already turns "Sr" into "Senior" — both engines go
    /// through it, and the displayed text never does.
    @Test func theSpeechPathExpandsNumbersAndKeepsExpandingSuffixes() {
        let said = HallieSpeaker.spokenText(
            "Richard Harding Breen Sr was born 21 February 1929.")
        #expect(said.contains("Senior"), Comment(rawValue: said))
        #expect(said.contains("the twenty-first of February, nineteen twenty-nine"),
                Comment(rawValue: said))
        #expect(!said.contains("1929"), Comment(rawValue: said))
    }
}
