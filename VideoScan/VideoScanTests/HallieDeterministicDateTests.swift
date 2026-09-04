// HallieDeterministicDateTests.swift
//
// LIVE MISS (Rick, 2026-09-03, Release build of main, demo binary):
// "who are Tim's parents" →
//
//   "Tim's parents: Richard Harding Breen Sr (Dad in the People tab), born
//    feberuary 22 1929 in Boston, Suffolk, Massachusetts, United States,
//    died june 22 2008 in Brockton, Plymouth, Massachusetts, United States,
//    Eileen Latta (Ma in the People tab), born August 31 1930 in Chelsea,
//    Suffolk, Massachusetts, United States, died March 3, 2023 in
//    Stoughton, Norfolk, Massachusetts, United States."
//
// Four dates, four formats, one misspelled month — in one sentence, to be
// read out at a family demo. The claim Swift handed the model was correct
// and uniform. The model re-typed the dates; nothing checked.
//
// Contract pinned here:
//   1. ONE house format, "22 February 1929", from ONE formatter
//      (HallieDateStyle), used by every renderer.
//   2. A date inside a verified claim is exact evidence, like a filename:
//      alter it and the sentence is dropped as `.alteredDate`, and the
//      claim's own text comes back instead.
//   3. A correctly rendered date is NOT dropped. A false drop costs an
//      answer, so the negative cases here matter as much as the positives.
//
// Five dimensions (CLAUDE.md). Logic: below. Isolation: below — synthetic
// claims, an injected calendar, no UserDefaults. Sensor: the four-date
// live sentence, pinned verbatim at the bottom.
// SCALE DOES NOT APPLY — nothing here iterates `records`; the verifier
// runs over one composed answer of at most six sentences. A cost sensor is
// included anyway because the scanner is regex-based and runs per sentence.
// MEDIA MATRIX DOES NOT APPLY — no file is opened, no ffmpeg/ffprobe is
// invoked, no AVFoundation type is touched.
//
// Pure: no model, no network, no filesystem.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Hallie deterministic dates")
struct HallieDeterministicDateTests {

    // MARK: - Fixtures

    /// The live parents claim as `ArchivistGraphExecutor+KinshipOverlay`
    /// builds it: one claim carrying the whole card, dates rendered by
    /// `HallieBiographyCard.vitalsAside` → `HallieDateStyle`.
    private static let parentsClaim =
        "Tim's parents: Richard Harding Breen Sr (Dad in the People tab), "
        + "born 22 February 1929 in Boston, Suffolk, Massachusetts, United States, "
        + "died 22 June 2008 in Brockton, Plymouth, Massachusetts, United States, "
        + "Eileen Latta (Ma in the People tab), "
        + "born 31 August 1930 in Chelsea, Suffolk, Massachusetts, United States, "
        + "died 3 March 2023 in Stoughton, Norfolk, Massachusetts, United States."

    private func parentsPlan() -> HallieAnswerPlan {
        HallieAnswerPlan(
            route: .graph, shape: .fact, subject: "Tim Breen",
            claims: [.init(id: "c1", text: Self.parentsClaim,
                           evidenceIDs: ["@I2@", "@I3@"],
                           requiresCoverage: true)],
            fallbackText: Self.parentsClaim)
    }

    /// A two-claim biography whose c1 carries life dates, so a drop is
    /// answered by the life-dates restore rather than by the template.
    private func biographyPlan() -> HallieAnswerPlan {
        HallieAnswerPlan(
            route: .graph, shape: .biography, subject: "Eileen Latta",
            claims: [
                .init(id: "c1", text: "Eileen Latta was born 31 August 1930 in Chelsea and died 3 March 2023 in Stoughton."),
                .init(id: "c2", text: "Eileen Latta married Richard Harding Breen Sr."),
            ],
            fallbackText: "Eileen Latta was born 31 August 1930 in Chelsea and died 3 March 2023 in Stoughton. Eileen Latta married Richard Harding Breen Sr.")
    }

    private func verify(_ composed: String, _ plan: HallieAnswerPlan)
        -> HallieCompositionVerifier.Verification {
        HallieCompositionVerifier.verify(composed, plan: plan, personaName: "Hallie Mae")
    }

    private func compose(_ plan: HallieAnswerPlan, _ reply: String) async
        -> HallieGroundedComposer.Outcome {
        await HallieGroundedComposer(personaName: "Hallie Mae") { _, _ in reply }
            .compose(plan: plan, history: [])
    }

    // MARK: - 1. One house format, one formatter

    /// The format is chosen, not invented: it is what the golden answers
    /// already pin. If someone changes `houseFormat`, this fails first.
    @Test func houseFormatIsDayMonthNameYear() {
        #expect(HallieDateStyle.houseFormat == "d MMMM yyyy")
        #expect(HallieDateStyle.spoken("22 FEB 1929") == "22 February 1929")
        #expect(HallieDateStyle.spoken("BEF 29 NOV 1717") == "before 29 November 1717")
        #expect(HallieDateStyle.spoken("ABT 1633") == "about 1633")
        // Ancestry's spelling, straight out of Rick's tree (George Breen).
        #expect(HallieDateStyle.spoken("Abt. 10 Aug 1898") == "about 10 August 1898")
        #expect(HallieDateStyle.spoken("Abt 1464") == "about 1464")
        #expect(HallieDateStyle.spoken("BET 1700 AND 1710") == "between 1700 and 1710")
        // No readable year is not a date we may state.
        #expect(HallieDateStyle.spoken("sometime in the war") == nil)
        #expect(HallieDateStyle.spoken(nil) == nil)
    }

    /// ISOLATION — the formatter must not read the machine's locale or time
    /// zone. A reader whose Mac is set to French, or to Tokyo, still gets
    /// the family's own wording, because a localized month name would not
    /// match the claim and the verifier would then drop honest sentences.
    @Test func houseFormatIgnoresSystemLocaleAndTimeZone() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // 1960-06-21T12:00:00Z
        let tim = Date(timeIntervalSince1970: -300_715_200)
        #expect(HallieDateStyle.spoken(tim, calendar: calendar) == "21 June 1960")

        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        #expect(HallieDateStyle.spoken(tim, calendar: tokyo) == "21 June 1960")
    }

    /// Every renderer that states a family date goes through the one
    /// formatter. `birthText` was "d MMM yyyy" ("21 Jun 1960") until
    /// 2026-09-03 — the second format, and the reason "when was Tim born"
    /// answered "June 21, 1960" one run and "21 June 1960" the next.
    @Test func everyRendererAgreesOnTheHouseFormat() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let tim = Date(timeIntervalSince1970: -300_715_200)
        // `birthText` renders in the machine's own time zone, so the DAY is
        // not pinned here — the FORMAT is: a month spelled out in full,
        // never the "Jun" abbreviation it used to emit.
        let profileText = HallieTurnExecutor.PeopleTab.birthText(tim)
        #expect(!profileText.contains("Jun "))
        let spellsMonthInFull = HallieDateStyle.longMonths.contains { profileText.contains($0) }
        #expect(spellsMonthInFull, Comment(rawValue: profileText))
        #expect(HallieBiographyCard.spokenDate("21 JUN 1960") == "21 June 1960")
        #expect(HallieDateStyle.spoken(tim, calendar: calendar) == "21 June 1960")
    }

    /// FOUR DATES, ONE FORMAT. The complaint in one assertion: whatever the
    /// answer says, every date in it is rendered the same way.
    @Test func fourDatesInOneAnswerAreFormattedIdentically() {
        let dates = HallieDateStyle.occurrences(in: Self.parentsClaim)
        #expect(dates.count == 4, Comment(rawValue: "\(dates)"))
        let allRealMonths = dates.allSatisfy { $0.namesARealMonth }
        #expect(allRealMonths)
        // Same shape every time: <day> <MonthName> <year>, single space,
        // no comma, month spelled out. The DAY's digit width is not pinned
        // ("3 March 2023" is one digit, "31 August 1930" is two) — the
        // ORDER and the spelling are what the reader sees as a format.
        let shapes = dates.map { date -> String in
            date.text.split(separator: " ").map { part -> String in
                if part.allSatisfy(\.isNumber) { return part.count == 4 ? "YEAR" : "DAY" }
                return HallieDateStyle.longMonths.contains(String(part)) ? "MONTH" : "?\(part)"
            }.joined(separator: " ")
        }
        #expect(Set(shapes) == ["DAY MONTH YEAR"], Comment(rawValue: "\(shapes)"))
    }

    // MARK: - 2. A sensor per corruption shape

    /// THE LIVE MISS, verbatim. Every corruption at once.
    @Test func liveFourFormatAnswerIsRejected() async {
        let plan = parentsPlan()
        let live = "Tim's parents: Richard Harding Breen Sr (Dad in the People tab), "
            + "born feberuary 22 1929 in Boston, Suffolk, Massachusetts, United States, "
            + "died june 22 2008 in Brockton, Plymouth, Massachusetts, United States, "
            + "Eileen Latta (Ma in the People tab), "
            + "born August 31 1930 in Chelsea, Suffolk, Massachusetts, United States, "
            + "died March 3, 2023 in Stoughton, Norfolk, Massachusetts, United States. [c1]"
        let verified = verify(live, plan)
        #expect(verified.kept.isEmpty, Comment(rawValue: verified.displayText))
        #expect(verified.dropped.first?.reason == .alteredDate)

        // And the reader is not punished for the model's spelling: the
        // deterministic card ships instead, in one format.
        let outcome = await compose(plan, live)
        #expect(outcome.displayText == Self.parentsClaim)
        #expect(!outcome.displayText.lowercased().contains("feberuary"))
    }

    /// MISSPELLED MONTH — lowercase, so the pre-existing `leak` rule never
    /// looked at it (`leak` only inspects CAPITALIZED words). This is the
    /// hole the bug walked through.
    @Test func misspelledMonthIsCaught() {
        let v = verify("Eileen Latta was born 31 agust 1930 in Chelsea [c1].", biographyPlan())
        #expect(v.dropped.first?.reason == .alteredDate)
        // Capitalized misspelling too.
        let capitalized = verify(
            "Eileen Latta was born 31 Agust 1930 in Chelsea [c1].", biographyPlan())
        #expect(capitalized.dropped.first?.reason == .alteredDate)
        // The live spelling.
        #expect(HallieDateStyle.occurrences(in: "born feberuary 22 1929 in Boston")
            .map(\.namesARealMonth) == [false])
    }

    /// WRONG SEPARATOR — the same day, punctuated differently. Caught
    /// because the reader sees a fourth format on the page, which is the
    /// whole complaint.
    @Test func wrongSeparatorIsCaught() {
        #expect(verify("Eileen Latta was born 31 August, 1930 [c1].", biographyPlan())
            .dropped.first?.reason == .alteredDate)
        #expect(verify("Eileen Latta was born 31-8-1930 [c1].", biographyPlan())
            .dropped.first?.reason == .alteredDate)
        #expect(verify("Eileen Latta was born 1930-08-31 [c1].", biographyPlan())
            .dropped.first?.reason == .alteredDate)
    }

    /// REORDERED DAY/MONTH — "August 31, 1930" for "31 August 1930". Same
    /// day, different house. Rejected: one format everywhere.
    @Test func reorderedDayAndMonthIsCaught() {
        #expect(verify("Eileen Latta was born on August 31, 1930 [c1].", biographyPlan())
            .dropped.first?.reason == .alteredDate)
        #expect(verify("Eileen Latta was born on August 31 1930 [c1].", biographyPlan())
            .dropped.first?.reason == .alteredDate)
    }

    /// CHANGED YEAR — the one that actually matters for truth. A person
    /// born in 1930 must never be said to be born in 1931, and this is the
    /// case where being dropped is not merely tidier but necessary.
    @Test func changedYearIsCaughtAndTheTruthIsRestored() async {
        let plan = biographyPlan()
        let wrong = "Eileen Latta was born 31 August 1931 in Chelsea and died 3 March 2023 in Stoughton [c1]. "
            + "Eileen Latta married Richard Harding Breen Sr [c2]."
        let verified = verify(wrong, plan)
        #expect(verified.dropped.map(\.reason) == [.alteredDate])

        let outcome = await compose(plan, wrong)
        #expect(!outcome.displayText.contains("1931"))
        #expect(outcome.displayText.contains("31 August 1930"))
    }

    /// A changed DAY is a changed fact too, and is caught by the same rule.
    @Test func changedDayIsCaught() {
        #expect(verify("Eileen Latta was born 30 August 1930 [c1].", biographyPlan())
            .dropped.first?.reason == .alteredDate)
    }

    /// PRECISION LOSS — dropping the day. Exactly the filename rule's
    /// reasoning: `2006-xx-xx_Rick.mov` may not become `Rick.mov`, and
    /// "31 August 1930" may not become "August 1930".
    @Test func droppedDayIsCaught() {
        #expect(verify("Eileen Latta was born in August 1930 [c1].", biographyPlan())
            .dropped.first?.reason == .alteredDate)
    }

    /// A date belonging to a claim this sentence did NOT cite is not
    /// vouched — same rule the year/number/name leaks already follow.
    @Test func dateFromAnUncitedClaimIsNotVouched() {
        #expect(verify("Eileen Latta married Richard Harding Breen Sr on 3 March 2023 [c2].",
                       biographyPlan()).dropped.first?.reason == .alteredDate)
    }

    /// THE OTHER LIVE SHAPE (Manager, 2026-09-03, same demo binary).
    /// "tell me about Ma" came back "born August 31, 1930" and "died March
    /// 3, 2023" — internally CONSISTENT with each other, but still not the
    /// house format, and still not what the claim said.
    ///
    /// Worth pinning because the contrast between the two routes is
    /// misleading: it is NOT that one renderer hands the model raw date
    /// text and the other does not. Both hand over "31 August 1930".
    /// The biography route drifted to one alternative format and the
    /// kinship route drifted to four — the same unconstrained re-typing,
    /// differing only in how far it wandered. One rule catches both.
    @Test func biographyRouteReformattingIsCaughtToo() async {
        let plan = biographyPlan()
        let live = "Eileen Latta was born August 31, 1930 in Chelsea "
            + "and died March 3, 2023 in Stoughton [c1]. "
            + "She married Richard Harding Breen Sr [c2]."
        let verified = verify(live, plan)
        #expect(verified.dropped.map(\.reason) == [.alteredDate])

        let outcome = await compose(plan, live)
        #expect(outcome.displayText.contains("31 August 1930"))
        #expect(outcome.displayText.contains("3 March 2023"))
        #expect(!outcome.displayText.contains("August 31, 1930"))
        #expect(!outcome.displayText.contains("March 3, 2023"))
    }

    // MARK: - 3. Negatives — a false drop costs an answer

    /// THE NEGATIVE THAT MATTERS. A correctly rendered date is kept, in
    /// every position and with ordinary prose around it.
    @Test func correctlyRenderedDatesAreNotDropped() async {
        let plan = biographyPlan()
        let good = "Eileen Latta was born 31 August 1930 in Chelsea and died 3 March 2023 in Stoughton [c1]. "
            + "She married Richard Harding Breen Sr [c2]."
        let verified = verify(good, plan)
        #expect(verified.dropped.isEmpty, Comment(rawValue: "\(verified.dropped)"))
        #expect(verified.kept.count == 2)

        let outcome = await compose(plan, good)
        #expect(outcome.composedBy == .model)
        #expect(outcome.dropped.isEmpty)

        // The live card, phrased faithfully, survives whole.
        let parents = verify(Self.parentsClaim + " [c1]", parentsPlan())
        #expect(parents.dropped.isEmpty, Comment(rawValue: "\(parents.dropped)"))
        #expect(parents.kept.count == 1)
    }

    /// A bare year is NOT a date for this rule. "died in 1906 in
    /// Chattanooga" is one fact, already guarded by `leakedYear`; treating
    /// it as a date would drop honest sentences wholesale.
    @Test func bareYearsAreLeftToTheExistingYearRule() {
        let plan = HallieAnswerPlan(
            route: .graph, shape: .biography, subject: "David T. McGill",
            claims: [.init(id: "c1", text: "David T. McGill was born in 1843 in Kentucky and died in 1906 in Chattanooga.")],
            fallbackText: "David T. McGill was born in 1843 in Kentucky and died in 1906 in Chattanooga.")
        let v = verify("David T. McGill was born in 1843 in Kentucky and died in 1906 in Chattanooga [c1].", plan)
        #expect(v.dropped.isEmpty, Comment(rawValue: "\(v.dropped)"))
        #expect(HallieDateStyle.occurrences(in: "born in 1843 in Kentucky").isEmpty)
    }

    /// A raw GEDCOM date in a claim vouches for its HOUSE rendering and
    /// nothing else. The expansion is honest — no new fact, only the month
    /// spelled the one way Hallie spells it. Reformatting is not.
    @Test func gedcomClaimVouchesForTheHouseRenderingOnly() {
        let plan = HallieAnswerPlan(
            route: .graph, shape: .biography, subject: "Ellen Breen",
            claims: [.init(id: "c1", text: "The imported family tree records 12 MAR 1920 as Ellen Breen's birth date.")],
            fallbackText: "The imported family tree records 12 MAR 1920 as Ellen Breen's birth date.")
        #expect(verify("Ellen Breen was born 12 March 1920 [c1].", plan).dropped.isEmpty)
        #expect(verify("Ellen Breen was born 12 MAR 1920 [c1].", plan).dropped.isEmpty)
        #expect(verify("Ellen Breen was born on March 12, 1920 [c1].", plan)
            .dropped.first?.reason == .alteredDate)
    }

    /// A filename that happens to contain digits is not a date, and a
    /// sentence about media is untouched by this rule.
    @Test func mediaSentencesAreUntouched() {
        let plan = HallieAnswerPlan(
            route: .presence, shape: .list,
            claims: [.init(id: "c1", text: "I found 2 catalog items matching that."),
                     .init(id: "c2", text: "One of them is Cape_12_1994.mov.")],
            fallbackText: "I found 2 catalog items matching that.")
        let v = verify("There are 2 of them, and one is Cape_12_1994.mov [c1][c2].", plan)
        #expect(v.dropped.isEmpty, Comment(rawValue: "\(v.dropped)"))
    }

    /// The month slot holding an ordinary lowercase word is NOT called a
    /// corrupted date — that is the model dropping the month, which the
    /// year rule owns. Being conservative here is what keeps the rule from
    /// becoming trigger-happy.
    @Test func anOrdinaryWordInTheMonthSlotIsNotAMisspelledMonth() {
        #expect(HallieDateStyle.occurrences(in: "he was born 22 1929").isEmpty)
        #expect(HallieDateStyle.occurrences(in: "there were 12 of them in 1994").isEmpty)
    }

    // MARK: - The biography route (live 2026-09-03 evening)

    /// "tell me about Dad" — the 6-claim `HallieBiographyCard` plan, with
    /// the People-tab alias in the lead name exactly as `leadName` builds
    /// it, and the live corrupted sentence.
    private func dadBiographyPlan() -> HallieAnswerPlan {
        let vitals = "Richard Harding Breen Sr (Dad in the People tab) was born "
            + "22 February 1929 in Boston, Suffolk, Massachusetts, United States and died "
            + "22 June 2008 in Brockton, Plymouth, Massachusetts, United States."
        let texts = [
            vitals,
            "He was the child of George Breen and Muriel Lamb; his recorded grandparents were Edith Lucy Parker and Frederick Burton Lamb.",
            "He had 1 recorded sibling, Beth Breen.",
            "He was married to Eileen Latta (married 14 June 1952).",
            "He had 4 recorded children, Richard Harding Breen Jr, Tim Breen, Dan Breen and Mark Breen.",
            "His family tree includes 12578 recorded ancestors across 18 generations and 2 recorded descendants across 2 generations.",
        ]
        return HallieAnswerPlan(
            route: .graph, shape: .biography,
            subject: "Richard Harding Breen Sr",
            claims: texts.enumerated().map {
                .init(id: "c\($0 + 1)", text: $1, evidenceIDs: ["@I2@"],
                      requiredPersonNames: $0 == 0 ? ["Richard Harding Breen Sr"] : [],
                      requiresCoverage: true)
            },
            fallbackText: texts.joined(separator: " "))
    }

    /// THE LIVE BIOGRAPHY SENTENCE, verbatim. Reported 2026-09-03 evening as
    /// reaching the reader with no drop line at all.
    @Test func liveBiographyVitalsSentenceIsRejected() async {
        let plan = dadBiographyPlan()
        let live = "Richard Harding Breen Sr (Dad in the People tab) was born "
            + "feberuary 22 1929 in Boston, Suffolk, Massachusetts, United States and died "
            + "June 22 2008 in Brockton, Plymouth, Massachusetts, United States. [c1]"
        let verified = verify(live, plan)
        #expect(verified.dropped.map(\.reason) == [.alteredDate],
                Comment(rawValue: "kept=\(verified.kept.map(\.display)) dropped=\(verified.dropped)"))
    }

    /// The whole turn, through the composer, with the other five claims
    /// phrased faithfully — the shape the live answer actually had.
    @Test func liveBiographyTurnShipsTheHouseFormatDates() async {
        let plan = dadBiographyPlan()
        let live = "Richard Harding Breen Sr (Dad in the People tab) was born "
            + "feberuary 22 1929 in Boston, Suffolk, Massachusetts, United States and died "
            + "June 22 2008 in Brockton, Plymouth, Massachusetts, United States. [c1] "
            + "He was the child of George Breen and Muriel Lamb; his recorded grandparents were Edith Lucy Parker and Frederick Burton Lamb. [c2] "
            + "He had 1 recorded sibling, Beth Breen. [c3] "
            + "He was married to Eileen Latta (married 14 June 1952). [c4] "
            + "He had 4 recorded children, Richard Harding Breen Jr, Tim Breen, Dan Breen and Mark Breen. [c5] "
            + "His family tree includes 12578 recorded ancestors across 18 generations and 2 recorded descendants across 2 generations. [c6]"
        let outcome = await compose(plan, live)
        #expect(!outcome.displayText.lowercased().contains("feberuary"),
                Comment(rawValue: outcome.displayText))
        #expect(!outcome.displayText.contains("June 22 2008"))
        #expect(outcome.displayText.contains("22 February 1929"))
        #expect(outcome.displayText.contains("22 June 2008"))
    }

    // MARK: - Free-text dates STORED IN THE TREE (live 2026-09-03 evening)

    /// THE VISIBLE HALF OF THE DEMO BUG, and it was never the model.
    ///
    /// The compiled tree stores Rick's father's dates as the literal
    /// strings "feberuary 22 1929" and "june 22 2008" (verified in
    /// tree.vsft: `@I2@Richard Harding Breen Sr@F2@feberuary 22 1929june
    /// 22 2008`), and Eileen Latta's as "Aug 31 1930" and "March 3, 2023".
    /// The turn is recorded `composedBy: template`, so no model and no
    /// verifier was ever in that sentence's path — `spoken` simply handed
    /// unrecognised text straight through. Four stored shapes became four
    /// shapes on the page.
    @Test func freeTextDatesStoredInTheTreeAreSpokenInTheHouseFormat() {
        // Rick's father, exactly as the tree stores him.
        #expect(HallieDateStyle.spoken("feberuary 22 1929") == "22 February 1929")
        #expect(HallieDateStyle.spoken("june 22 2008") == "22 June 2008")
        // Eileen Latta, exactly as the tree stores her.
        #expect(HallieDateStyle.spoken("Aug 31 1930") == "31 August 1930")
        #expect(HallieDateStyle.spoken("March 3, 2023") == "3 March 2023")
    }

    /// All four, in one card, now read the same way — the complaint that
    /// started this, measured on the real stored values.
    @Test func theParentsCardsFourStoredDatesRenderIdentically() {
        let stored = ["feberuary 22 1929", "june 22 2008", "Aug 31 1930", "March 3, 2023"]
        let spoken = stored.compactMap { HallieDateStyle.spoken($0) }
        #expect(spoken == ["22 February 1929", "22 June 2008", "31 August 1930", "3 March 2023"])
        let shapes = spoken.map { text -> String in
            text.split(separator: " ").map { part -> String in
                if part.allSatisfy(\.isNumber) { return part.count == 4 ? "YEAR" : "DAY" }
                return HallieDateStyle.longMonths.contains(String(part)) ? "MONTH" : "?\(part)"
            }.joined(separator: " ")
        }
        #expect(Set(shapes) == ["DAY MONTH YEAR"], Comment(rawValue: "\(shapes)"))
    }

    /// A misspelled month is re-spelled only when exactly ONE month is
    /// within a two-character slip. Day, month and year VALUES are never
    /// altered — this is spelling, not correction of the record.
    @Test func onlyAnUnambiguousMonthMisspellingIsRespelled() {
        #expect(HallieDateStyle.monthNamed("feberuary") == "February")
        #expect(HallieDateStyle.monthNamed("feburary") == "February")
        #expect(HallieDateStyle.monthNamed("septmber") == "September")
        #expect(HallieDateStyle.monthNamed("march") == "March")
        #expect(HallieDateStyle.monthNamed("sept") == "September")
        // Not a month, and not close enough to guess at.
        #expect(HallieDateStyle.monthNamed("boston") == nil)
        #expect(HallieDateStyle.monthNamed("tuesday") == nil)
        // The values themselves are untouched.
        #expect(HallieDateStyle.spoken("feberuary 22 1929") == "22 February 1929")
        #expect(HallieDateStyle.spoken("feberuary 23 1929") == "23 February 1929")
    }

    /// NEGATIVES — everything that is not one unambiguous date is left
    /// exactly as it was. These are all real shapes from Rick's tree.
    @Test func rangesAndUnreadableDatesAreLeftAlone() {
        // Ranges are two dates; the word-by-word path still owns them.
        #expect(HallieDateStyle.spoken("BET 1700 AND 1710") == "between 1700 and 1710")
        #expect(HallieDateStyle.spoken("from 26 March 1574 to 13 May 1574")
            == "from 26 March 1574 to 13 May 1574")
        #expect(HallieDateStyle.spoken("before 26 May 1580 or arround 1584")
            == "before 26 May 1580 or arround 1584")
        #expect(HallieDateStyle.spoken("ABT 1445       1496") == "about 1445 1496")
        // Precision is preserved, never invented.
        #expect(HallieDateStyle.spoken("ABT 1633") == "about 1633")
        // Ancestry's spelling, straight out of Rick's tree (George Breen).
        #expect(HallieDateStyle.spoken("Abt. 10 Aug 1898") == "about 10 August 1898")
        #expect(HallieDateStyle.spoken("Abt 1464") == "about 1464")
        #expect(HallieDateStyle.spoken("Oct 1621") == "October 1621")
        #expect(HallieDateStyle.spoken("1824") == "1824")
        #expect(HallieDateStyle.spoken("BEF 29 NOV 1717") == "before 29 November 1717")
        #expect(HallieDateStyle.spoken("28 FEB 1629") == "28 February 1629")
        #expect(HallieDateStyle.spoken("10 December 1553") == "10 December 1553")
        // No readable year is still not a date.
        #expect(HallieDateStyle.spoken("sometime in the war") == nil)
    }

    /// The verifier and the renderer must agree: a house-format date the
    /// renderer now produces is one the scanner recognises, so a claim
    /// built from a normalised free-text date still vouches for itself.
    @Test func normalizedStoredDatesStillVouchForTheirOwnClaim() {
        let vitals = "Richard Harding Breen Sr was born "
            + (HallieDateStyle.spoken("feberuary 22 1929") ?? "?")
            + " in Boston and died " + (HallieDateStyle.spoken("june 22 2008") ?? "?")
            + " in Brockton."
        let plan = HallieAnswerPlan(
            route: .graph, shape: .biography, subject: "Richard Harding Breen Sr",
            claims: [.init(id: "c1", text: vitals)], fallbackText: vitals)
        #expect(verify(vitals + " [c1]", plan).dropped.isEmpty)
        #expect(vitals.contains("22 February 1929"))
        #expect(vitals.contains("22 June 2008"))
    }

    // MARK: - Evidence for a SEPARATE bug (not fixed here)

    /// NOT A DATE TEST. Recorded here because the investigation of
    /// 2026-09-03 turned it up and the next person should not have to
    /// re-derive it.
    ///
    /// The live log shows `leakedName` dropping a CORRECT life-dates
    /// sentence four times (18:52, 19:20, 20:10, 20:47). The obvious
    /// hypothesis — "the sentence was dropped because it names the claim's
    /// own subject" — is FALSE, and this pins that so nobody spends the
    /// evening on it: a sentence naming its own subject, with the claim's
    /// own date and places, is kept.
    ///
    /// What the real trigger is cannot be determined from the log, because
    /// `[hallie-phrase] dropped:` records the reason but NOT the offending
    /// token and NOT the claim text. That is the fix worth making first,
    /// and it is a log-format change, so it needs Rick.
    @Test func aSentenceNamingItsOwnSubjectIsNotDroppedAsALeakedName() {
        let vitals = "Richard Harding Breen Sr was born 22 February 1929 in "
            + "Boston, Suffolk, Massachusetts, United States and died 22 June 2008 in "
            + "Brockton, Plymouth, Massachusetts, United States."
        let plan = HallieAnswerPlan(
            route: .graph, shape: .biography, subject: "Richard Harding Breen Sr",
            claims: [.init(id: "c1", text: vitals, evidenceIDs: ["@I2@"], requiresCoverage: true)],
            fallbackText: vitals)
        let kept = verify(vitals + " [c1]", plan)
        #expect(kept.dropped.isEmpty, Comment(rawValue: "\(kept.dropped)"))

        // Narrowing the trigger: a capitalized word the claim does not
        // carry — the shape a model produces when it helpfully expands a
        // place ("Plymouth County") — IS a leakedName, correctly.
        let embellished = "Richard Harding Breen Sr was born 22 February 1929 in "
            + "Boston, Suffolk, Massachusetts, United States and died 22 June 2008 in "
            + "Brockton, Plymouth County, Massachusetts, United States. [c1]"
        #expect(verify(embellished, plan).dropped.first?.reason == .leakedName)

        // And the date rule does not shadow it: a leak still reads as a
        // leak, which matters because `leakedName` withholds the claim and
        // `.alteredDate` does not.
        #expect(verify(embellished, plan).dropped.map(\.reason) == [.leakedName])
    }

    // MARK: - 4. Logging — the trail must name the new reason

    /// The reason code appears in the existing `[hallie-phrase] dropped:`
    /// line, beside `alteredFilename`, so the next investigation has the
    /// same trail this one had.
    @Test func aDroppedDateIsLoggedInTheExistingStyle() {
        let plan = parentsPlan()
        let dropped = [HallieCompositionVerifier.Dropped(
            text: "born feberuary 22 1929 [c1].", reason: .alteredDate)]
        let lines = HallieGroundedComposer.droppedLogLines(dropped, plan: plan)
        #expect(lines.count == 1)
        #expect(lines[0].hasPrefix("[hallie-phrase] dropped: c1 (life dates) — reason: alteredDate — "),
                Comment(rawValue: lines[0]))
    }

    /// An altered date is NOT a leak: the fact is one we hold, typed wrong,
    /// so the claim stays owed and the plan's own text comes back. A leak
    /// would be withheld.
    @Test func anAlteredDateIsNotTreatedAsALeak() {
        #expect(!HallieGroundedComposer.leakReasons.contains(.alteredDate))
        #expect(HallieGroundedComposer.leakReasons.contains(.alteredFilename))
    }

    // MARK: - 5. Cost sensor

    /// SCALE DOES NOT APPLY in the CLAUDE.md sense — nothing here iterates
    /// `records`. But the scanner is regex-based and runs once per composed
    /// sentence, so this pins that it stays cheap enough to be invisible in
    /// a turn. Budget is deliberately loose; it is a smoke alarm, not a
    /// benchmark.
    @Test func scannerCostStaysNegligiblePerAnswer() {
        let plan = parentsPlan()
        let answer = Self.parentsClaim + " [c1]"
        let start = Date()
        for _ in 0..<200 { _ = verify(answer, plan) }
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 4.0, Comment(rawValue: "200 verifications took \(elapsed)s"))
    }
}
