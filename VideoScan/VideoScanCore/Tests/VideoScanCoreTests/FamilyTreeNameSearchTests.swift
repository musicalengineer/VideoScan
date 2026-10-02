import XCTest
@testable import VideoScanCore

/// The Family Tree tab's ranked name search (2026-09-26). Dimensions per
/// the feature-test checklist:
///   Logic     — tokenization, any-order prefix AND-match, fuzzy fallback,
///               ranking (exact > prefix > fuzzy; profile / recency /
///               unmatched tie-breakers), negatives, empty query
///   Scale     — 100k synthetic people: build once, keystroke budgets
///   Isolation — an overlay naming rows outside the table is ignored
///   Sensor    — a full exact name reaches at least what the substring
///               filter reached, with a same-named person on top
/// No media is opened, so no media-matrix dimension.
final class FamilyTreeNameSearchTests: XCTestCase {

    static let fixture = """
    0 HEAD
    0 @I1@ INDI
    1 NAME Mary Christina /O'Connor/
    1 SEX F
    1 BIRT
    2 DATE 12 MAY 1904
    1 _FSFTID MRYA-904
    0 @I2@ INDI
    1 NAME Mary /O'Connor/
    1 SEX F
    1 BIRT
    2 DATE ABT 1650
    1 _FSFTID MRYA-650
    0 @I3@ INDI
    1 NAME Gruffudd ap /Einion/
    1 SEX M
    1 BIRT
    2 DATE 1420
    0 @I4@ INDI
    1 NAME Richard Harding /Breen/
    1 SEX M
    1 BIRT
    2 DATE 21 FEB 1929
    0 @I5@ INDI
    1 NAME Richard /Breen/
    1 SEX M
    1 BIRT
    2 DATE 1959
    0 @I6@ INDI
    1 NAME John /Smith/
    1 SEX M
    1 BIRT
    2 DATE 1950
    0 @I7@ INDI
    1 NAME Ann Mc Gill
    1 SEX F
    1 BIRT
    2 DATE 1900
    0 @I8@ INDI
    1 NAME Mary /Lamb/
    1 SEX F
    0 @I9@ INDI
    1 NAME Zoë /Élan/
    1 SEX F
    1 _FSFTID GVQV-NW3
    0 TRLR
    """

    static let graph = GedcomFamilyGraph(gedcomText: fixture)
    static let search = FamilyTreeNameSearch(graph: graph)
    /// Ranking tests pass a fixed "today" so the recency slope is stable.
    static let year = 2026

    func ids(_ result: FamilyTreeNameSearch.Result) -> [String] {
        let index = Self.graph.index
        return result.hits.map { index.ids[Int(index.sidebarOrder[Int($0.row)])] }
    }

    func row(_ id: String) -> Int32 {
        Self.search.rowByOrdinal[Int(Self.graph.index.ordinal(of: id)!)]
    }

    // MARK: Tokenization

    func testQueryTokensFoldCaseDiacriticsApostrophesHyphensAndMc() {
        XCTAssertEqual(FamilyTreeNameSearch.queryTokens("Mary O'Connor"), ["mary", "oconnor"])
        XCTAssertEqual(FamilyTreeNameSearch.queryTokens("o'connor  MARY"), ["oconnor", "mary"])
        XCTAssertEqual(FamilyTreeNameSearch.queryTokens("Mary O\u{2019}Connor"), ["mary", "oconnor"])
        XCTAssertEqual(FamilyTreeNameSearch.queryTokens("Mc Gill"), ["mcgill"])
        XCTAssertEqual(FamilyTreeNameSearch.queryTokens("McGill"), ["mcgill"])
        XCTAssertEqual(FamilyTreeNameSearch.queryTokens("Ann Mc Gill"), ["ann", "mcgill"])
        XCTAssertEqual(FamilyTreeNameSearch.queryTokens("Mac Donald"), ["macdonald"])
        XCTAssertEqual(FamilyTreeNameSearch.queryTokens("Zoë Élan"), ["zoe", "elan"])
        XCTAssertEqual(FamilyTreeNameSearch.queryTokens("@I14@"), ["i14"])
        XCTAssertEqual(FamilyTreeNameSearch.queryTokens("GVQV-NW3"), ["gvqvnw3"])
        XCTAssertEqual(FamilyTreeNameSearch.queryTokens("Ann-Marie Smith-Jones"), ["annmarie", "smithjones"])
        XCTAssertEqual(FamilyTreeNameSearch.queryTokens("   "), [])
        XCTAssertEqual(FamilyTreeNameSearch.queryTokens("Mc"), ["mc"], "a trailing particle stays a token")
    }

    func testIndexTokensAlsoCarryTheJoinedPieces() {
        XCTAssertEqual(FamilyTreeNameSearch.indexTokens("Mary O'Connor"), ["mary", "oconnor", "o", "connor"])
        XCTAssertEqual(FamilyTreeNameSearch.indexTokens("Ann Mc Gill"), ["ann", "mcgill", "gill"])
        XCTAssertEqual(FamilyTreeNameSearch.indexTokens("Ann McGill"), ["ann", "mcgill", "gill"], "solid spelling indexes the same pieces")
        XCTAssertEqual(FamilyTreeNameSearch.indexTokens("MacDonald"), ["macdonald", "donald"])
        XCTAssertEqual(FamilyTreeNameSearch.indexTokens("Macy"), ["macy"], "too short a remainder to be a name")
        XCTAssertEqual(FamilyTreeNameSearch.indexTokens("GVQV-NW3"), ["gvqvnw3", "gvqv", "nw3"])
        XCTAssertEqual(FamilyTreeNameSearch.indexTokens("Richard"), ["richard"])
    }

    func testMaxDistanceBands() {
        XCTAssertEqual(FamilyTreeNameSearch.maxDistance(forLength: 1), 0)
        XCTAssertEqual(FamilyTreeNameSearch.maxDistance(forLength: 2), 0)
        XCTAssertEqual(FamilyTreeNameSearch.maxDistance(forLength: 3), 1)
        XCTAssertEqual(FamilyTreeNameSearch.maxDistance(forLength: 5), 1)
        XCTAssertEqual(FamilyTreeNameSearch.maxDistance(forLength: 6), 2)
        XCTAssertEqual(FamilyTreeNameSearch.maxDistance(forLength: 20), 2)
    }

    func testPrefixDistanceIsOptimalStringAlignmentOverPrefixes() {
        func d(_ q: String, _ t: String, _ maxD: Int) -> Bool {
            let qb = Array(q.utf8), tb = Array(t.utf8)
            var scratch = [Int32](repeating: 0, count: 3 * (qb.count + maxD + 1))
            return tb.withUnsafeBufferPointer { tp in
                scratch.withUnsafeMutableBufferPointer { s in
                    FamilyTreeNameSearch.prefixDistance(qb, tp, maxD: maxD, scratch: s)
                }
            }
        }
        XCTAssertTrue(d("grufudd", "gruffudd", 1), "one insertion")
        XCTAssertTrue(d("einon", "einion", 1))
        XCTAssertTrue(d("grufud", "gruffudd", 2), "typo + prefix")
        XCTAssertTrue(d("rikc", "rick", 1), "adjacent transposition counts one")
        XCTAssertFalse(d("rikc", "rick", 0))
        XCTAssertTrue(d("rick", "richard", 1), "prefix 'ric' is one edit away")
        XCTAssertFalse(d("mary", "john", 2))
        XCTAssertFalse(d("smith", "breen", 2))
        XCTAssertTrue(d("breen", "breen", 0))
        XCTAssertFalse(d("abcdefgh", "ab", 2), "a prefix that is too short cannot be within range")
    }

    // MARK: Stage 1 — any order, prefix per token

    func testFullNameInEitherOrderFindsMaryChristinaOConnor() {
        for query in ["Mary O'Connor", "mary oconnor", "o'connor mary", "O\u{2019}CONNOR Mary", "mary connor", "Mary Christina O'Connor"] {
            let result = Self.search.search(query, currentYear: Self.year)
            XCTAssertTrue(ids(result).contains("@I1@"), "'\(query)' → \(ids(result))")
            XCTAssertFalse(result.isApproximate, "'\(query)' is an exact hit")
        }
    }

    func testPrefixPerTokenAndPointerAndFamilySearchID() {
        // Both Marys prefix-match; the one whose whole name is covered leads.
        XCTAssertEqual(ids(Self.search.search("mar oc", currentYear: Self.year)), ["@I2@", "@I1@"])
        XCTAssertEqual(ids(Self.search.search("mar chr", currentYear: Self.year)), ["@I1@"])
        XCTAssertEqual(ids(Self.search.search("I5", currentYear: Self.year)), ["@I5@"])
        XCTAssertEqual(ids(Self.search.search("@I5@", currentYear: Self.year)), ["@I5@"])
        XCTAssertEqual(ids(Self.search.search("GVQV-NW3", currentYear: Self.year)), ["@I9@"])
        XCTAssertEqual(ids(Self.search.search("gvqv", currentYear: Self.year)), ["@I9@"])
        XCTAssertEqual(ids(Self.search.search("zoe elan", currentYear: Self.year)), ["@I9@"])
        XCTAssertEqual(ids(Self.search.search("Mc Gill", currentYear: Self.year)), ["@I7@"])
        XCTAssertEqual(ids(Self.search.search("mcgill ann", currentYear: Self.year)), ["@I7@"])
        XCTAssertEqual(ids(Self.search.search("gill", currentYear: Self.year)), ["@I7@"], "the piece after Mc is searchable")
    }

    func testEveryTokenMustMatchSomewhere() {
        // "mary smith": Marys exist and a Smith exists, but nobody is both.
        let result = Self.search.search("mary smith", currentYear: Self.year)
        XCTAssertEqual(ids(result), [], "\(ids(result))")
    }

    func testEmptyAndWhitespaceQueryReturnNothing() {
        XCTAssertEqual(Self.search.search("", currentYear: Self.year), .empty)
        XCTAssertEqual(Self.search.search("   \t", currentYear: Self.year), .empty)
        XCTAssertEqual(Self.search.search("'-", currentYear: Self.year), .empty, "joiners alone are no token")
    }

    // MARK: Stage 2 — fuzzy fallback

    func testMisspelledWelshNameStillFindsGruffuddApEinion() {
        let result = Self.search.search("Grufudd ap Einon", currentYear: Self.year)
        XCTAssertEqual(ids(result), ["@I3@"])
        XCTAssertTrue(result.isApproximate)
        XCTAssertTrue(result.includesCloseMatches)
        XCTAssertEqual(result.exactCount, 0)
    }

    func testFuzzyOnlyRunsWhenTheExactStageIsThin() {
        // "rick" is one edit from the prefix "ric" of Richard — a close
        // match, flagged as such.
        let rick = Self.search.search("rick", currentYear: Self.year)
        XCTAssertEqual(Set(ids(rick)), ["@I4@", "@I5@"])
        XCTAssertTrue(rick.isApproximate)
        // Two-letter tokens never fuzz.
        XCTAssertEqual(ids(Self.search.search("rk", currentYear: Self.year)), [])
        // A long token that is nowhere near anything stays a miss.
        XCTAssertEqual(ids(Self.search.search("nobodybythisname", currentYear: Self.year)), [])
        XCTAssertEqual(ids(Self.search.search("mary zebulon", currentYear: Self.year)), [], "the unmatched token is not forgiven")
    }

    func testDigitTokensAndIDKeysNeverFuzz() {
        // A typed pointer / FamilySearch ID is exact or nothing …
        XCTAssertEqual(FamilyTreeNameSearch.maxDistance(for: "i14"), 0)
        XCTAssertEqual(FamilyTreeNameSearch.maxDistance(for: "gvqvnw3"), 0)
        XCTAssertEqual(FamilyTreeNameSearch.maxDistance(for: "mary"), 1)
        XCTAssertEqual(FamilyTreeNameSearch.maxDistance(for: "gruffudd"), 2)
        // … and an ID key is never a fuzzy candidate, even its letters-only
        // piece ("gvqv"), while a name key is.
        let keys = Self.search.keys
        XCTAssertFalse(Self.search.fuzzable[keys.firstIndex(of: "gvqv")!])
        XCTAssertFalse(Self.search.fuzzable[keys.firstIndex(of: "i5")!])
        XCTAssertTrue(Self.search.fuzzable[keys.firstIndex(of: "mary")!])
        XCTAssertTrue(Self.search.fuzzable[keys.firstIndex(of: "gruffudd")!])
        XCTAssertEqual(ids(Self.search.search("gvqx", currentYear: Self.year)), [], "no drifting onto an FSID")
        // A tree of pointer neighbours: "I14" reaches I14 alone, never I13/I15.
        let text = (13...15).map { "0 @I\($0)@ INDI\n1 NAME Person /Row\($0)/" }.joined(separator: "\n")
        let graph = GedcomFamilyGraph(gedcomText: text)
        let search = FamilyTreeNameSearch(graph: graph)
        let hits = search.search("I14", currentYear: Self.year)
        XCTAssertEqual(hits.hits.map { graph.index.ids[Int(graph.index.sidebarOrder[Int($0.row)])] }, ["@I14@"])
        XCTAssertFalse(hits.includesCloseMatches)
        XCTAssertEqual(search.search("Row14", currentYear: Self.year).hits.count, 1)
    }

    // MARK: Ranking

    func testExactBeatsPrefixBeatsFuzzy() {
        // "mary o'connor": both Marys exact; then "mary" prefix rows.
        let exact = Self.search.search("mary oconnor", currentYear: Self.year)
        XCTAssertEqual(exact.exactCount, 2)
        XCTAssertEqual(Set(ids(exact).prefix(2)), ["@I1@", "@I2@"])
        // "richard" exact on both Breens; "ric" prefix on both — same rows,
        // and a fuzzy "rikc" ranks them below any exact match of a second token.
        let scored = Self.search.search("richard breen", currentYear: Self.year)
        XCTAssertEqual(scored.hits.count, 2)
        XCTAssertGreaterThan(scored.hits[0].score, 2 * FamilyTreeNameSearch.Weight.exact - 0.6,
                             "two exact tokens ≈ 2×exact minus small tie-breakers")
        let fuzzy = Self.search.search("rikc breen", currentYear: Self.year)
        XCTAssertEqual(Set(ids(fuzzy)), ["@I4@", "@I5@"])
        XCTAssertLessThan(fuzzy.hits[0].score, scored.hits[1].score, "fuzzy+exact < exact+exact for every row")
    }

    func testPeopleTabProfileBeatsA1600sNamesake() {
        // Without a profile, "Mary O'Connor" IS the 1650 record's whole
        // name, so she leads Mary Christina (1904) despite her age …
        let plain = Self.search.search("Mary O'Connor", currentYear: Self.year)
        XCTAssertEqual(ids(plain).prefix(2).map { $0 }, ["@I2@", "@I1@"])
        // … but a People-tab profile on Mary Christina puts her first —
        // the 1600s namesake loses to the person Rick actually knows.
        let overlay = FamilyTreeNameSearch.Overlay(profileRows: [row("@I1@")])
        let biased = Self.search.search("Mary O'Connor", overlay: overlay, currentYear: Self.year)
        XCTAssertEqual(ids(biased).prefix(2).map { $0 }, ["@I1@", "@I2@"])
        // And a profile on the 1650 record keeps her first (nothing flips).
        let ancient = FamilyTreeNameSearch.Overlay(profileRows: [row("@I2@")])
        XCTAssertEqual(ids(Self.search.search("Mary O'Connor", overlay: ancient, currentYear: Self.year)).first, "@I2@")
        // Slightly: the tie-breakers' whole spread never lifts a fuzzy row
        // over a prefix one, nor a prefix row over an exact one.
        typealias W = FamilyTreeNameSearch.Weight
        let spread = (W.profile + W.recency / 2) + (W.recency / 2 + W.unmatchedCap)
        XCTAssertLessThan(spread, min(W.prefix - W.fuzzy, W.exact - W.prefix))
        // The People-tab profile also outweighs one uncovered name token:
        // "Mary O'Connor" leads with a profile's "Mary Christina O'Connor".
        let christina = FamilyTreeNameSearch.Overlay(profileRows: [row("@I1@")])
        XCTAssertEqual(ids(Self.search.search("Mary O'Connor", overlay: christina, currentYear: Self.year)).first, "@I1@")
        XCTAssertGreaterThan(W.profile, W.unmatchedFirst)
    }

    func testTypingTheWholeNameBeatsAYoungerLongerNamedNamesake() {
        let text = """
        0 @I1@ INDI
        1 NAME Edith Margaret /Alden/
        1 BIRT
        2 DATE 2000
        0 @I2@ INDI
        1 NAME Edith /Alden/
        1 BIRT
        2 DATE 1650
        """
        let graph = GedcomFamilyGraph(gedcomText: text)
        let search = FamilyTreeNameSearch(graph: graph)
        let index = graph.index
        func ids(_ q: String) -> [String] {
            search.search(q, currentYear: Self.year).hits.map { index.ids[Int(index.sidebarOrder[Int($0.row)])] }
        }
        XCTAssertEqual(ids("Edith Alden"), ["@I2@", "@I1@"], "the whole name typed → that record first")
        XCTAssertEqual(ids("Edith"), ["@I1@", "@I2@"], "a partial name → both one token short; the younger leads")
        XCTAssertEqual(ids("Edith Margaret Alden"), ["@I1@"])
    }

    func testRecentBeatsAncientAndUnknownBirthIsNeutral() {
        // Richard Breen (1959) above Richard Harding Breen (1929): both
        // exact on "richard breen"; the younger AND shorter name leads.
        XCTAssertEqual(ids(Self.search.search("richard breen", currentYear: Self.year)), ["@I5@", "@I4@"])
        // "mary": Mary Lamb has no birth year (neutral, 0) — she sits between
        // Mary O'Connor 1904 (+) and Mary O'Connor 1650 (−), after the
        // unmatched-token penalty on the longer names is accounted for.
        let marys = Self.search.search("mary", currentYear: Self.year)
        let order = ids(marys)
        XCTAssertEqual(Set(order), ["@I1@", "@I2@", "@I8@"])
        XCTAssertLessThan(order.firstIndex(of: "@I8@")!, order.firstIndex(of: "@I2@")!, "unknown birth outranks 1650: \(order)")
        // The slope is gentle: 1904 vs 1650 differ by less than one tier.
        let s1 = marys.hits.first { $0.row == row("@I1@") }!.score
        let s2 = marys.hits.first { $0.row == row("@I2@") }!.score
        XCTAssertLessThan(s1 - s2, 1.0)
        XCTAssertGreaterThan(s1, s2)
    }

    func testTiesKeepSidebarOrder() {
        // Two rows scoring identically come back in sidebar (row) order.
        let text = """
        0 @I1@ INDI
        1 NAME Beta /Same/
        0 @I2@ INDI
        1 NAME Alpha /Same/
        0 @I3@ INDI
        1 NAME Gamma /Same/
        """
        let graph = GedcomFamilyGraph(gedcomText: text)
        let search = FamilyTreeNameSearch(graph: graph)
        let rows = search.search("same", currentYear: Self.year).hits.map(\.row)
        XCTAssertEqual(rows, [0, 1, 2])
        XCTAssertEqual(rows.map { graph.index.ids[Int(graph.index.sidebarOrder[Int($0)])] }, ["@I2@", "@I1@", "@I3@"])
    }

    // MARK: Overlay (People-tab aliases)

    func testNicknameAliasFindsTheBridgedRowAndCombinesWithNameTokens() {
        let overlay = FamilyTreeNameSearch.Overlay(
            profileRows: [row("@I5@")],
            aliasTokens: [row("@I5@"): ["rick", "dicky"]])
        // "rick" is now an EXACT alias hit on Richard Breen; Richard
        // Harding Breen only fuzzes in behind him.
        let rick = Self.search.search("rick", overlay: overlay, currentYear: Self.year)
        XCTAssertEqual(ids(rick).first, "@I5@")
        XCTAssertEqual(rick.exactCount, 1)
        XCTAssertTrue(rick.includesCloseMatches)
        XCTAssertFalse(rick.isApproximate)
        // Alias + surname from the record.
        let rickBreen = Self.search.search("rick breen", overlay: overlay, currentYear: Self.year)
        XCTAssertEqual(ids(rickBreen).first, "@I5@")
        XCTAssertEqual(ids(Self.search.search("dicky", overlay: overlay, currentYear: Self.year)), ["@I5@"])
    }

    func testOverlayNamingRowsOutsideTheTableIsIgnored() {
        // Isolation: a stale overlay (rows from another tree) must neither
        // crash nor change the result.
        let poisoned = FamilyTreeNameSearch.Overlay(
            profileRows: [-1, 9_999],
            aliasTokens: [-1: ["mary"], 9_999: ["mary"]])
        XCTAssertEqual(Self.search.search("Mary O'Connor", overlay: poisoned, currentYear: Self.year),
                       Self.search.search("Mary O'Connor", currentYear: Self.year))
    }

    // MARK: Sensor — the substring filter's exact-name reach is kept

    func checkExactNamesReachAtLeastTheSubstringRows(_ graph: GedcomFamilyGraph, sample: Int, label: String) {
        let index = graph.index
        let search = FamilyTreeNameSearch(graph: graph)
        var checked = 0
        for row in stride(from: 0, to: index.sidebarOrder.count, by: max(1, index.sidebarOrder.count / sample)) {
            let person = graph.people[index.ids[Int(index.sidebarOrder[Int(row)])]]!
            let name = person.name
            guard !FamilyTreeNameSearch.queryTokens(name).isEmpty else { continue }
            let old = Set(index.sidebarRows(containing: name.lowercased()))
            let result = search.search(name, currentYear: Self.year)
            let new = Set(result.hits.map(\.row))
            XCTAssertTrue(old.isSubset(of: new), "\(label) '\(name)': substring rows \(old.subtracting(new)) lost")
            XCTAssertFalse(result.isApproximate, "\(label) '\(name)' must be an exact hit")
            // The top row is a same-named person (not necessarily this one:
            // namesakes tie-break on profile / birth year / name length).
            let top = graph.people[index.ids[Int(index.sidebarOrder[Int(result.hits[0].row)])]]!
            XCTAssertEqual(FamilyTreeNameSearch.queryTokens(top.name).sorted(),
                           FamilyTreeNameSearch.queryTokens(name).sorted(), "\(label) '\(name)' top row")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0)
    }

    func testExactNameSensorOnTheFixture() {
        checkExactNamesReachAtLeastTheSubstringRows(Self.graph, sample: 9, label: "fixture")
    }

    // MARK: Scale — 100k synthetic people

    static let big: (graph: GedcomFamilyGraph, search: FamilyTreeNameSearch, buildMS: Double) = {
        let graph = GedcomFamilyGraph(gedcomText: GedcomSyntheticPedigree.gedcom(people: 100_000))
        _ = graph.index
        let clock = ContinuousClock()
        let start = clock.now
        let search = FamilyTreeNameSearch(graph: graph)
        let ms = TimingBudget.seconds(clock.now - start) * 1_000
        return (graph, search, ms)
    }()

    /// Median of five timings, in milliseconds.
    func medianMS(_ body: () -> Void) -> Double {
        let clock = ContinuousClock()
        var samples: [Double] = []
        for _ in 0..<5 {
            let start = clock.now
            body()
            samples.append(TimingBudget.seconds(clock.now - start) * 1_000)
        }
        return samples.sorted()[2]
    }

    func testHundredThousandPeopleBuildAndTokenMatchWithinBudget() throws {
        let big = Self.big
        let loadBefore = TimingBudget.sampleLoad()
        XCTAssertEqual(big.search.rowCount, 100_000)
        XCTAssertGreaterThan(big.search.keys.count, 1_000, "pointers and FSIDs give a real key table")
        // Token AND-match keystrokes: a full name, a narrowing pair, and
        // the broadest single letter.
        var hits = 0
        let full = medianMS { hits = big.search.search("mary breen").hits.count }
        XCTAssertGreaterThan(hits, 10)
        let pair = medianMS { _ = big.search.search("richard bre"); _ = big.search.search("richard bree") } / 2
        var broad = 0
        let letter = medianMS { broad = big.search.search("a").hits.count }
        XCTAssertGreaterThan(broad, 5_000)
        print("SCALE[\(TimingBudget.isDebugBuild ? "Debug" : "Release")] 100k name search: build \(Int(big.buildMS)) ms; "
              + "'mary breen' \(full) ms (\(hits) rows); keystroke pair \(pair) ms; 'a' \(letter) ms (\(broad) rows)")
        // Release budget from the spec (≤ 30 ms); Debug gets a coarse 400 ms.
        // Strict on a quiet machine; a busy-machine miss within 3× skips
        // with the load named (GH #208, TimingBudget.judge).
        let budget: Duration = TimingBudget.isDebugBuild ? .milliseconds(400) : .milliseconds(30)
        try assertTimingJudgements([
            TimingBudget.judgeNow("100k name search 'mary breen'", budget: budget,
                                  measured: .milliseconds(full), loadBefore: loadBefore),
            TimingBudget.judgeNow("100k name search keystroke pair", budget: budget,
                                  measured: .milliseconds(pair), loadBefore: loadBefore),
            TimingBudget.judgeNow("100k name search single letter (~\(broad) rows)", budget: budget * 2,
                                  measured: .milliseconds(letter), loadBefore: loadBefore),
        ])
    }

    func testHundredThousandPeopleFuzzyFallbackWithinBudget() throws {
        let big = Self.big
        let loadBefore = TimingBudget.sampleLoad()
        var result = FamilyTreeNameSearch.Result.empty
        // Misspelled both tokens: nothing exact, so the fuzzy stage runs.
        let fuzzy = medianMS { result = big.search.search("Elizabth Bradfrod") }
        XCTAssertTrue(result.isApproximate, "\(result.exactCount) exact / \(result.hits.count) hits")
        XCTAssertGreaterThan(result.hits.count, 0)
        XCTAssertLessThanOrEqual(result.hits.count, FamilyTreeNameSearch.fuzzyCap)
        let index = big.graph.index
        let top = big.graph.people[index.ids[Int(index.sidebarOrder[Int(result.hits[0].row)])]]!
        XCTAssertTrue(top.name.contains("Elizabeth") && top.name.contains("Bradford"), top.name)
        // One long garbage token: the fuzzy scan runs and finds nothing.
        let miss = medianMS { result = big.search.search("qwzxvbnmk") }
        XCTAssertEqual(result.hits.count, 0)
        print("SCALE[\(TimingBudget.isDebugBuild ? "Debug" : "Release")] 100k fuzzy: 'Elizabth Bradfrod' \(fuzzy) ms; miss \(miss) ms")
        let budget: Duration = TimingBudget.isDebugBuild ? .milliseconds(1_500) : .milliseconds(150)
        try assertTimingJudgements([
            TimingBudget.judgeNow("100k fuzzy fallback", budget: budget,
                                  measured: .milliseconds(fuzzy), loadBefore: loadBefore),
            TimingBudget.judgeNow("100k fuzzy miss", budget: budget,
                                  measured: .milliseconds(miss), loadBefore: loadBefore),
        ])
    }

    func testExactNameSensorOn100k() {
        checkExactNamesReachAtLeastTheSubstringRows(Self.big.graph, sample: 300, label: "100k")
    }

    func testBuildIsDeterministic() {
        let a = FamilyTreeNameSearch(graph: Self.graph)
        let b = FamilyTreeNameSearch(graph: Self.graph)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.keys, a.keys.sorted())
        XCTAssertEqual(Set(a.keys).count, a.keys.count, "keys are unique")
        XCTAssertEqual(a.rowByOrdinal.count, Self.graph.people.count)
        for row in 0..<a.rowCount {
            XCTAssertEqual(Int(a.rowByOrdinal[Int(Self.graph.index.sidebarOrder[row])]), row)
        }
    }
}
