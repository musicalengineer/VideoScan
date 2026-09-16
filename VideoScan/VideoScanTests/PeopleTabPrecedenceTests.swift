// PeopleTabPrecedenceTests.swift
//
// THE LIVE MISS, 2026-09-13, session 7A7B536C (route=graph,
// outcome=needs-clarification, queryDescription "shape=graph
// operation=birth person=beth"):
//
//   Rick:   very good, now tell me about beth
//   Hallie: "The family tree has 2190 people named Beth (as Elizabeth) —
//            which one? Add a surname or a birth year…"
//            Basis: the family tree has 2190 people by the name "Beth";
//            none offered; nothing was looked up.
//   Rick:   Beth Breen Beth McAuliffe          (her maiden and married names)
//   Hallie: declined — "Checked: graph-query validation only; no family
//            source was consulted."
//
// Beth is Rick's SISTER. Her People profile is canonically "Elizabeth" and
// carries the alias "beth". The People-tab answer existed the whole time and
// was gated on `context.graph == nil` — profiles spoke only when NO tree was
// installed — so importing one tree silenced the People tab for every
// graph-route name. Rick's ruling of 2026-09-04 says the opposite: the
// People tab is the source of truth for the inner circle.
//
// Five dimensions (feature-test checklist):
//   1. Logic     — exact canonical wins; exact ALIAS wins; near miss does
//                  NOT win; two claimants ask which; no match falls through.
//   2. Scale     — n/a for the precedence itself (bounded by the PROFILE
//                  count, tens). The tree side is index-backed and only a
//                  COUNT is kept; the 20-namesake fixture exercises the same
//                  branch 2190 did.
//   3. Media     — n/a (no media files opened).
//   4. Isolation — every profile and tree is an in-memory fixture; nothing
//                  reads Application Support, UserDefaults or the POI store.
//                  `noTreeAtAll…` pins the no-tree world unchanged.
//   5. Sensor    — `theExactMatchRuleIsNotGatedOnTheAbsenceOfATree` and
//                  `aFuzzyNameNeverOutranksTheTree`. The first pins the bug
//                  itself: one `graph == nil` in a condition, which looked
//                  perfectly reasonable in isolation. The second pins the
//                  boundary that keeps a sister from shadowing an ancestor.
//
// The GEDCOM fixture is synthetic (2026-08-03 privacy policy) and mirrors
// the real shape: one owner, a pile of unrelated namesakes by the same given
// name, and one tree record that a profile can be pinned to.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

/// Rick first (so the tree's assumed root is NOT one of the namesakes — the
/// live 2190 had no anchor either), then twenty unrelated Elizabeths, one of
/// which carries a FamilySearch ID a profile can pin to.
private let crowdedTree: String = {
    var lines = ["0 HEAD", "0 @I1@ INDI", "1 NAME Richard Harding /Breen/ Jr",
                 "1 SEX M", "1 _FSFTID GVQV-NW3"]
    for index in 1...20 {
        lines += ["0 @E\(index)@ INDI",
                  "1 NAME Elizabeth /Stranger\(index)/",
                  "1 SEX F",
                  "1 BIRT",
                  "2 DATE \(1700 + index)"]
        if index == 7 { lines.append("1 _FSFTID ELIZ-007") }
    }
    lines.append("0 TRLR")
    return lines.joined(separator: "\n")
}()

/// The same crowd, all sharing ONE surname, so a full name ("Elizabeth
/// Breen") is as ambiguous in the tree as a given name is in `crowdedTree`.
private let sharedSurnameTree: String = {
    var lines = ["0 HEAD", "0 @I1@ INDI", "1 NAME Richard Harding /Breen/ Jr", "1 SEX M"]
    for index in 1...20 {
        lines += ["0 @B\(index)@ INDI", "1 NAME Elizabeth /Breen/", "1 SEX F",
                  "1 BIRT", "2 DATE \(1700 + index)"]
    }
    lines.append("0 TRLR")
    return lines.joined(separator: "\n")
}()

@Suite("Hallie — an exact People-tab match outranks a tree full of namesakes", .serialized)
struct PeopleTabPrecedenceTests {
    typealias Exec = HallieTurnExecutor

    private let graph = GedcomFamilyGraph(gedcomText: crowdedTree)

    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var dc = DateComponents()
        dc.year = y; dc.month = m; dc.day = d; dc.hour = 12
        dc.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: dc) ?? .distantPast
    }

    /// Rick's sister as the People tab actually holds her: canonical
    /// "Elizabeth", alias "beth", no tree pin (she is one of the nine living
    /// relatives Rick keeps OUT of the tree).
    private static let beth = Exec.ProfileSnapshot(
        stableID: "beth", canonicalName: "Elizabeth", aliases: ["beth"],
        birthdate: date(1962, 2, 25),
        note: "Rick's sister. She married into the McAuliffes.",
        sex: .female, surname: "McAuliffe", maidenName: "Breen",
        notInFamilyTree: true)

    private static let rick = Exec.ProfileSnapshot(
        stableID: "rick", canonicalName: "Rick", aliases: ["Richard"],
        birthdate: date(1959, 3, 4), sex: .male,
        treeIdentity: .familySearchID("GVQV-NW3"))

    private func context(profiles: [Exec.ProfileSnapshot],
                         graph: GedcomFamilyGraph?) -> Exec.Context {
        Exec.Context(profiles: profiles, graph: graph,
                     speakers: .init(ownerName: "Rick Breen",
                                     archivistName: "Hallie Mae",
                                     archivistPersonName: nil))
    }

    private var liveContext: Exec.Context {
        context(profiles: [Self.rick, Self.beth], graph: graph)
    }

    /// The live shape: a bare given name on the graph route. The session
    /// recorded operation=birth for "tell me about beth"; biography is the
    /// same fork, so both are exercised.
    private func ask(_ typed: String,
                     operation: ArchivistQueryAST.Graph.Operation = .biography,
                     in context: Exec.Context) async throws -> Exec.Result {
        try await Exec.execute(
            .init(intent: .init(
                originalQuestion: "tell me about \(typed)",
                ast: .graph(.init(people: [typed], operation: operation)))),
            context: context)
    }

    /// Second turn: continue the ACTUAL returned clarification with one of
    /// the candidate IDs it actually offered, the way the UI does.
    private func pick(_ candidate: Exec.Candidate,
                      after first: Exec.Result,
                      typed: String,
                      in context: Exec.Context) async throws -> Exec.Result {
        // The real continuation API the UI uses — it validates the token,
        // the stage and that the candidate is still current, so this
        // exercises the whole second turn rather than a hand-built Request.
        let clarification = try #require(first.clarification)
        return try await Exec.continue(pending: clarification,
                                       selecting: candidate.id,
                                       context: context)
    }

    // MARK: - GH #186: the second turn, and the corrected question

    /// FINDING 1 (codex). Picking an offered PROFILE chip must land on that
    /// profile's answer. It used to walk straight back into the tree crowd:
    /// resolveSelectedProfile expands the profile's canonical name
    /// ("Elizabeth") into every tree namesake, and the precedence rule then
    /// refused to help because `selectedIdentity != nil`. "Which Beth?" →
    /// pick Beth → "which of 2,190 Elizabeths?" — a loop that lands on the
    /// exact question this whole rule exists to stop asking.
    @Test func pickingAnOfferedProfileChipAnswersFromThatProfile() async throws {
        let twin = Exec.ProfileSnapshot(
            stableID: "beth-2", canonicalName: "Elizabeth",
            aliases: ["beth"], birthdate: Self.date(1971, 3, 3))
        let ctx = context(profiles: [Self.rick, Self.beth, twin], graph: graph)

        let first = try await ask("beth", in: ctx)
        #expect(first.outcome == .needsClarification, Comment(rawValue: first.prose))
        let candidates = try #require(first.clarification?.candidates)
        #expect(candidates.count == 2, "two profiles own the spelling")

        let chosen = try #require(candidates.first)
        let second = try await pick(chosen, after: first, typed: "beth", in: ctx)

        #expect(second.outcome != .needsClarification,
                Comment(rawValue: "asked again instead of answering: \(second.prose)"))
        #expect(!second.prose.contains("Which Elizabeth"),
                Comment(rawValue: second.prose))
        #expect(!second.prose.lowercased().contains("family tree has"),
                Comment(rawValue: "fell back into the namesake crowd: \(second.prose)"))
    }

    /// FINDING 2 (codex). "Where was Beth born?" arrives from the model as
    /// `.birth`; ArchivistGraphQuery's field guards correct it to
    /// `.birthPlace`. The fallback passed the RAW payload, so a birthplace
    /// question was answered with a birthday and reported as answered —
    /// the same class the 2026-09-07 guards were added to stop, on a path
    /// that did not exist yet. Driven through `execute`, not the
    /// initializer, because that is how it escaped the first time.
    @Test func aBirthplaceQuestionMisreadAsBirthIsStillAnsweredAsAPlace() async throws {
        let r = try await Exec.execute(
            .init(intent: .init(
                originalQuestion: "where was Beth born?",
                ast: .graph(.init(people: ["beth"], operation: .birth)))),
            context: liveContext)

        // The two branches of PeopleTab.answer are unmistakable, so assert
        // on THEM rather than on a guessed substring. An earlier version of
        // this test looked for "1965"/"born on" — neither string appears in
        // either branch, so it passed with the fix REMOVED. It proved
        // nothing, which is the failure mode this whole day has been about.
        //
        //   .birth       → "… was born <date>, according to the People profile."
        //   .birthPlace  → "… doesn't record a place — it only carries a birth date."
        #expect(!r.prose.contains("was born"),
                Comment(rawValue: "answered the birth DATE to a \"where\" question: \(r.prose)"))
        // Plain ASCII apostrophe: unlike most prose in this file, THAT
        // string is written with ' and not \u{2019}. Asserting the
        // typographic one silently never matches.
        #expect(r.prose.contains("doesn't record a place"),
                Comment(rawValue: "expected the honest no-place answer, got: \(r.prose)"))
        #expect(r.outcome == .declined,
                Comment(rawValue: "a place it does not have must not report as answered"))
    }

    // MARK: - 1. The live miss

    @Test func tellMeAboutBethNoLongerAsksWhichOfTwentyStrangers() async throws {
        let r = try await ask("beth", in: liveContext)

        // The wrong answer, gone.
        #expect(r.outcome != .needsClarification, Comment(rawValue: r.prose))
        #expect(!r.prose.contains("which one?"), Comment(rawValue: r.prose))
        #expect(!r.basisLine.contains("none offered"), Comment(rawValue: r.basisLine))
        #expect(!r.basisLine.contains("nothing was looked up"), Comment(rawValue: r.basisLine))

        // The right one: his sister, from her profile.
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        #expect(r.prose.contains("Elizabeth"), Comment(rawValue: r.prose))
        #expect(r.prose.contains("Rick's sister"), Comment(rawValue: r.prose))
        #expect(r.basisLine.contains("People profile"), Comment(rawValue: r.basisLine))
    }

    /// The operation the model actually chose that evening.
    @Test func theSameMissUnderTheBirthOperationAlsoReachesHerProfile() async throws {
        let r = try await ask("beth", operation: .birth, in: liveContext)
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        #expect(r.prose.contains("25 February 1962"), Comment(rawValue: r.prose))
        #expect(!r.prose.contains("which one?"), Comment(rawValue: r.prose))
    }

    /// An exact CANONICAL match wins for the same reason an alias does.
    @Test func anExactCanonicalNameWinsOverTheTreesNamesakes() async throws {
        let r = try await ask("Elizabeth", in: liveContext)
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        #expect(r.prose.contains("Rick's sister"), Comment(rawValue: r.prose))
        #expect(!r.prose.contains("Stranger"), Comment(rawValue: r.prose))
    }

    // MARK: - 2. The ancestor stays reachable

    /// Rick asks about close family AND distant tree people. The People tab
    /// naming the person must never make the tree's namesakes invisible —
    /// the answer says how many there are and how to get one.
    @Test func theAnswerStillNamesTheTreesNamesakesAndTheWayBack() async throws {
        let r = try await ask("beth", in: liveContext)
        // The same words, and the same count, the which-one would have used.
        #expect(r.prose.contains("20 people named Beth (as Elizabeth)"),
                Comment(rawValue: r.prose))
        #expect(r.prose.contains("surname or a birth year"), Comment(rawValue: r.prose))
        #expect(r.basisLine.contains("20 namesakes"), Comment(rawValue: r.basisLine))
        // And it must not claim a lookup that never happened.
        #expect(!r.prose.contains("I couldn't match"), Comment(rawValue: r.prose))
    }

    /// With no namesake at all the pre-existing wording is untouched.
    @Test func withNoNamesakesTheOldTreeSentenceIsUnchanged() {
        #expect(Exec.PeopleTab.treeSentence(for: "Elizabeth", typed: nil, graph: graph)
                == "I couldn't match Elizabeth to a record in the family tree I have.")
        #expect(Exec.PeopleTab.treeSentence(for: "Elizabeth", graph: nil)
                == "I don't have an imported family tree to place Elizabeth in.")
    }

    // MARK: - 3. A pinned profile makes the TREE answer, it does not bypass it

    @Test func aPinnedProfileIsAnsweredFromTheTreeRecordItIsPinnedTo() async throws {
        let pinned = Exec.ProfileSnapshot(
            stableID: "beth", canonicalName: "Elizabeth", aliases: ["beth"],
            sex: .female, treeIdentity: .familySearchID("ELIZ-007"))
        let r = try await ask("beth", in: context(profiles: [Self.rick, pinned], graph: graph))

        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        #expect(r.prose.contains("Stranger7"), Comment(rawValue: r.prose))
        #expect(!r.prose.contains("which one?"), Comment(rawValue: r.prose))
    }

    /// The verdict itself, at the seam: a pin resolves to the tree person.
    @Test func thePrecedenceVerdictForAPinnedProfileIsTheTreePerson() {
        let pinned = Exec.ProfileSnapshot(
            stableID: "beth", canonicalName: "Elizabeth", aliases: ["beth"],
            treeIdentity: .familySearchID("ELIZ-007"))
        #expect(Exec.PeopleTab.precedence(typed: "beth", profiles: [pinned], graph: graph)
                == .treePerson(gedcomPersonID: "@E7@", profileName: "Elizabeth"))
    }

    /// A pin the installed tree cannot resolve fails CLOSED — the profile
    /// answers from itself rather than the precedence inventing a record.
    @Test func aStalePinFallsBackToTheProfileAndNeverGuessesARecord() {
        let stale = Exec.ProfileSnapshot(
            stableID: "beth", canonicalName: "Elizabeth", aliases: ["beth"],
            treeIdentity: .familySearchID("GONE-999"))
        #expect(Exec.PeopleTab.precedence(typed: "beth", profiles: [stale], graph: graph)
                == .profile(stale))
    }

    // MARK: - 4. The boundary: anything less than exact falls through

    /// SENSOR. "Bess" is not a spelling Beth's profile owns. Recovering it
    /// onto her and letting her outrank the tree is exactly how a sister
    /// starts shadowing a legitimate ancestor.
    @Test func aFuzzyNameNeverOutranksTheTree() {
        #expect(Exec.PeopleTab.precedence(
            typed: "Bess", profiles: [Self.beth], graph: graph) == .none)
        #expect(Exec.PeopleTab.precedence(
            typed: "Elizabet", profiles: [Self.beth], graph: graph) == .none)
        // The fuzzy claim still recovers it — the two must stay different.
        if case .none = Exec.PeopleTab.claim("Elizabet", in: [Self.beth]) {
            Issue.record("the fuzzy claim should still recover a near miss")
        }
    }

    /// SENSOR, and the one that caught this change over-reaching while it
    /// was being written (it broke `profileAliasBridgesToGedcomWith…` and
    /// `noCyberBrainKeepsProfileAndGedcomPath`).
    ///
    /// A FEW tree namesakes are a real choice: Hallie can put both of them
    /// in front of Rick and he picks. An unpinned profile must NOT swallow
    /// that — this is exactly how a sister starts shadowing an ancestor.
    /// The precedence is for the case where the tree could only hand the
    /// question back.
    @Test func aTreeThatCanOfferARealChoiceStillOffersIt() async throws {
        let twoOnly = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I1@ INDI
        1 NAME Richard Harding /Breen/ Jr
        1 SEX M
        0 @E1@ INDI
        1 NAME Elizabeth /Older/
        1 SEX F
        1 BIRT
        2 DATE 1881
        0 @E2@ INDI
        1 NAME Elizabeth /Younger/
        1 SEX F
        1 BIRT
        2 DATE 1904
        0 TRLR
        """)
        let r = try await ask("Elizabeth", in: context(profiles: [Self.beth], graph: twoOnly))

        #expect(r.outcome == .needsClarification, Comment(rawValue: r.prose))
        #expect(r.prose.hasPrefix("Which Elizabeth do you mean"), Comment(rawValue: r.prose))
        #expect(r.clarification?.candidates.count == 2)
        #expect(!r.prose.contains("Rick's sister"), Comment(rawValue: r.prose))
    }

    /// The whole tree behaviour for an unclaimed name, byte for byte.
    @Test func aNameNoProfileClaimsFallsThroughToTodaysTreeBehaviour() async throws {
        let withProfiles = try await ask("Elizabeth Stranger3", in: liveContext)
        let withoutProfiles = try await ask(
            "Elizabeth Stranger3", in: context(profiles: [], graph: graph))
        #expect(withProfiles.prose == withoutProfiles.prose, Comment(rawValue: withProfiles.prose))
        #expect(withProfiles.basisLine == withoutProfiles.basisLine,
                Comment(rawValue: withProfiles.basisLine))
        #expect(withProfiles.outcome == withoutProfiles.outcome)
    }

    /// And the namesake clarification itself still happens for a name the
    /// People tab has no opinion about — the tree route is not disabled.
    @Test func aTreeOnlyGivenNameStillAsksWhichOne() async throws {
        let crowded = GedcomFamilyGraph(gedcomText: crowdedTree
            .replacingOccurrences(of: "Elizabeth /Stranger", with: "Muriel /Stranger"))
        let r = try await ask("Muriel", in: context(profiles: [Self.beth], graph: crowded))
        #expect(r.outcome == .needsClarification, Comment(rawValue: r.prose))
        #expect(r.prose.contains("20 people named Muriel"), Comment(rawValue: r.prose))
    }

    // MARK: - 5. Two profiles owning one spelling

    /// A spelling ONE profile names and another only lists as an alias is
    /// not ambiguous — exact name wins (Director, 2026-09-03). Pinned here
    /// because it is the rule that decides how often the which-one below is
    /// even reachable.
    @Test func aNamedProfileStillBeatsAnAliasOfTheSameSpelling() async throws {
        let cousinBeth = Exec.ProfileSnapshot(
            stableID: "beth-cousin", canonicalName: "Beth",
            birthdate: Self.date(1978, 4, 9), sex: .female)
        let r = try await ask(
            "beth", in: context(profiles: [Self.beth, cousinBeth], graph: graph))
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        #expect(r.prose.hasPrefix("Beth is one of the people"), Comment(rawValue: r.prose))
    }

    /// Two profiles that own "Elizabeth Breen" with EQUAL strength — each
    /// derives it from its own family-name fields. The tree route cannot
    /// see derived full names, so it goes to the tree and finds twenty
    /// Elizabeth Breens; the People side must ask its own question rather
    /// than let the tree's namesake path answer for it.
    @Test func twoProfilesSharingASpellingAskTheProfileSideWhichOne() async throws {
        let breenTree = GedcomFamilyGraph(gedcomText: sharedSurnameTree)
        let sister = Exec.ProfileSnapshot(
            stableID: "sister", canonicalName: "Elizabeth",
            birthdate: Self.date(1962, 2, 25), sex: .female, surname: "Breen")
        let aunt = Exec.ProfileSnapshot(
            stableID: "aunt", canonicalName: "Liz", aliases: ["Elizabeth"],
            birthdate: Self.date(1931, 8, 3), sex: .female, surname: "Breen")

        let verdict = Exec.PeopleTab.precedence(
            typed: "Elizabeth Breen", profiles: [sister, aunt], graph: breenTree)
        #expect(verdict == .ambiguous([sister, aunt]), Comment(rawValue: "\(verdict)"))

        let r = try await ask(
            "Elizabeth Breen", in: context(profiles: [sister, aunt], graph: breenTree))
        #expect(r.outcome == .needsClarification, Comment(rawValue: r.prose))
        #expect(r.prose.hasPrefix("Which Elizabeth Breen do you mean"),
                Comment(rawValue: r.prose))
        // The PROFILE side asked, not the tree's 2190-namesake path.
        #expect(r.basisLine.contains("People profiles"), Comment(rawValue: r.basisLine))
        #expect(!r.prose.contains("20 people named"), Comment(rawValue: r.prose))
        #expect(r.clarification?.stage == .profileIdentity)
    }

    // MARK: - 6. Isolation: no tree installed behaves exactly as before

    @Test func noTreeAtAllKeepsWorkingExactlyAsItDoesToday() async throws {
        let r = try await ask("beth", in: context(profiles: [Self.beth], graph: nil))
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        #expect(r.prose.contains("Rick's sister"), Comment(rawValue: r.prose))
        #expect(r.prose.contains("I don't have an imported family tree to place Elizabeth in."),
                Comment(rawValue: r.prose))
        #expect(r.basisLine.contains("family tree (no entry for Elizabeth)"),
                Comment(rawValue: r.basisLine))
    }

    /// With no tree the FUZZY claim still answers, as it always has — there
    /// is nothing for a recovered spelling to outrank.
    @Test func withNoTreeANearMissIsStillRecoveredToTheProfile() async throws {
        let r = try await ask("Elizabet", in: context(profiles: [Self.beth], graph: nil))
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        #expect(r.prose.contains("Elizabeth"), Comment(rawValue: r.prose))
    }

    // MARK: - 7. THE SENSOR on the gate itself

    /// The entire bug was one condition: `context.graph == nil` in front of
    /// the People-tab branch. It read perfectly reasonably in isolation. A
    /// refactor that re-gates the rule behind "no tree installed" would make
    /// `precedence` agree with and without a graph — so pin that it does
    /// NOT depend on a tree being absent, and that the same verdict survives
    /// an installed one.
    @Test func theExactMatchRuleIsNotGatedOnTheAbsenceOfATree() {
        let withoutTree = Exec.PeopleTab.precedence(
            typed: "beth", profiles: [Self.beth], graph: nil)
        let withTree = Exec.PeopleTab.precedence(
            typed: "beth", profiles: [Self.beth], graph: graph)
        #expect(withoutTree == .profile(Self.beth))
        #expect(withTree == .profile(Self.beth),
                "a People profile that answers with no tree must still answer with one")
    }

    /// The negative half of the sensor: no profiles ⇒ no opinion, tree or
    /// no tree. (Swift's `??` on an optional array ≈ a null-guarded default.)
    @Test func anEmptyOrUnreadableGalleryHasNoOpinion() {
        #expect(Exec.PeopleTab.precedence(typed: "beth", profiles: [], graph: graph) == .none)
        #expect(Exec.PeopleTab.precedence(typed: "beth", profiles: nil, graph: graph) == .none)
        #expect(Exec.PeopleTab.precedence(typed: "  ", profiles: [Self.beth], graph: graph) == .none)
    }
}

// MARK: - The follow-up: maiden and married in one breath

@Suite("Hallie — “Beth Breen Beth McAuliffe” is one sister, said twice", .serialized)
struct PeopleTabDoubleNameTests {
    typealias Exec = HallieTurnExecutor

    private let graph = GedcomFamilyGraph(gedcomText: crowdedTree)

    private static let beth = Exec.ProfileSnapshot(
        stableID: "beth", canonicalName: "Elizabeth", aliases: ["beth"],
        note: "Rick's sister. She married into the McAuliffes.",
        sex: .female, surname: "McAuliffe", maidenName: "Breen")

    private static let tim = Exec.ProfileSnapshot(
        stableID: "tim", canonicalName: "Tim", sex: .male, surname: "Breen")

    private func context(_ profiles: [Exec.ProfileSnapshot]) -> Exec.Context {
        Exec.Context(profiles: profiles, graph: graph,
                     speakers: .init(ownerName: "Rick Breen",
                                     archivistName: "Hallie Mae",
                                     archivistPersonName: nil))
    }

    private func ask(_ people: [String],
                     operation: ArchivistQueryAST.Graph.Operation = .biography,
                     in context: Exec.Context) async throws -> Exec.Result {
        try await Exec.execute(
            .init(intent: .init(
                originalQuestion: people.joined(separator: " "),
                ast: .graph(.init(people: people, operation: operation)))),
            context: context)
    }

    /// Both spellings are Beth's derived full-name forms, so they are one
    /// person — not the "I wasn't sure which person you meant" decline.
    @Test func twoSpellingsOfOneProfileCollapseToThatPerson() async throws {
        let r = try await ask(["Beth Breen", "Beth McAuliffe"], in: context([Self.beth]))
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        #expect(!r.prose.contains("I wasn't sure which person you meant"),
                Comment(rawValue: r.prose))
        #expect(r.prose.contains("Rick's sister"), Comment(rawValue: r.prose))
        // The rewrite is VISIBLE, never silent.
        #expect(r.basisLine.contains("as one person"), Comment(rawValue: r.basisLine))
    }

    /// SENSOR. Two names that mean two people keep today's honest decline.
    @Test func twoNamesThatMeanTwoPeopleStillDecline() async throws {
        let r = try await ask(["Beth McAuliffe", "Tim Breen"],
                              in: context([Self.beth, Self.tim]))
        #expect(r.outcome == .declined, Comment(rawValue: r.prose))
        #expect(r.prose.contains("I wasn't sure which person you meant"),
                Comment(rawValue: r.prose))
    }

    /// A name the People tab cannot vouch for is never collapsed, however
    /// close it looks to the other one.
    @Test func aNameTheProfilesDoNotOwnIsNeverCollapsed() {
        let payload = ArchivistQueryAST.Graph(
            people: ["Beth Breen", "Bess McAuliffe"], operation: .biography)
        #expect(Exec.collapsedDoubleName(payload, context: context([Self.beth])) == nil)
    }

    @Test func oneNameAndRepeatedNamesAreLeftAlone() {
        let single = ArchivistQueryAST.Graph(people: ["Beth Breen"], operation: .biography)
        #expect(Exec.collapsedDoubleName(single, context: context([Self.beth])) == nil)
        let repeated = ArchivistQueryAST.Graph(
            people: ["Beth Breen", "beth breen"], operation: .biography)
        #expect(Exec.collapsedDoubleName(repeated, context: context([Self.beth])) == nil)
    }

    /// A two-person RELATIONSHIP question is untouched: it takes two names
    /// legitimately, and the collapse runs after that branch has returned.
    @Test func aRelationshipQuestionStillTakesTwoNames() async throws {
        let r = try await ask(["Beth McAuliffe", "Tim Breen"],
                              operation: .relationship,
                              in: context([Self.beth, Self.tim]))
        #expect(!r.basisLine.contains("as one person"), Comment(rawValue: r.basisLine))
    }
}
