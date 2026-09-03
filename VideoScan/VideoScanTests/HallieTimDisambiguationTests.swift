import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

/// REGRESSION SENSORS for the two bugs that made Hallie unable to talk
/// about Rick's brother Tim (demo eval interim-20260902-2205, 2026-09-03):
///
///   (a) live/lv260902-004 "find videos of my brother tim" →
///       "I don't have any videos tagged with tim and Tim yet." One typed
///       term became TWO person terms differing only in case, and the
///       prose joiner said both.
///   (b) live/lv260902-023 "who are tim's parents" → "Which tim do you
///       mean?", and conjunction/cj008 "who is Tim's brother and how old
///       is Tim" → the same. Rick's brother Tim (b. 1960) and Rick's son
///       Timmy (b. 1996) have cross-contaminating alias lists — Tim's
///       profile lists "Timmy", Timmy's lists "Tim" — so a NAME match and
///       an ALIAS match tied and every question asked which one.
///
/// The fixtures below carry the REAL cross-alias shape and the real 36-year
/// birth gap. They are entirely synthetic: no profile.json, no UserDefaults,
/// no file on disk (ISOLATION dimension of the feature-test checklist).
///
/// The last test is the one that must never be "fixed" away: two people who
/// genuinely share a name STILL produce the which-one question.
struct HallieTimDisambiguationTests {

    typealias Profile = HallieTurnExecutor.ProfileSnapshot
    typealias Tab = HallieTurnExecutor.PeopleTab

    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Calendar(identifier: .gregorian)
            .date(from: DateComponents(year: y, month: m, day: d))!
    }

    // MARK: Fixtures — the gallery's real shape, synthetic values

    /// Rick's brother. His alias list contains his nephew's name.
    private let brother = Profile(
        stableID: "tim", canonicalName: "Tim",
        aliases: ["Timmy", "Timothy"],
        birthdate: date(1960, 6, 11),
        kinships: [Kinship(relation: .sibling, relativeTo: .profileName("Rick Breen"))],
        sex: .male)

    /// Rick's son. His alias list contains his uncle's name.
    private let son = Profile(
        stableID: "timmy", canonicalName: "Timmy",
        aliases: ["Tim", "Tim Jr"],
        birthdate: date(1996, 4, 22),
        kinships: [Kinship(relation: .child, relativeTo: .profileName("Rick Breen"))],
        sex: .male)

    private let owner = Profile(
        stableID: "rick", canonicalName: "Rick Breen",
        aliases: ["Rick"], birthdate: date(1959, 3, 4), sex: .male)

    private var profiles: [Profile] { [owner, brother, son] }

    private let speakers = HallieTurnExecutor.Speakers(
        ownerName: "Rick Breen", archivistName: "Hallie Mae")

    /// A tree that knows the brother and his parents, and stops before the
    /// son — the real archive's shape.
    private let tree = GedcomFamilyGraph(gedcomText: """
    0 HEAD
    0 @I1@ INDI
    1 NAME Rick /Breen/
    1 SEX M
    1 BIRT
    2 DATE 4 MAR 1959
    1 FAMC @F1@
    0 @I2@ INDI
    1 NAME Tim /Breen/
    1 SEX M
    1 BIRT
    2 DATE 11 JUN 1960
    1 FAMC @F1@
    0 @I3@ INDI
    1 NAME Richard Harding /Breen/ Sr
    1 SEX M
    1 FAMS @F1@
    0 @I4@ INDI
    1 NAME Eileen Marie /Latta/
    1 SEX F
    1 FAMS @F1@
    0 @F1@ FAM
    1 HUSB @I3@
    1 WIFE @I4@
    1 CHIL @I1@
    1 CHIL @I2@
    0 TRLR
    """)

    private func context(graph: GedcomFamilyGraph? = nil,
                         records: [ArchivistPresenceRecordSnapshot] = [])
        -> HallieTurnExecutor.Context {
        HallieTurnExecutor.Context(
            presenceRecords: records, profiles: profiles,
            graph: graph, speakers: speakers)
    }

    // MARK: (a) one person is never two person terms

    /// The exact shape that produced "tagged with tim and Tim": the
    /// translator leaves the typed given name in the people list and the
    /// kinship binding adds the canonical spelling.
    @Test func myBrotherTimIsOnePersonTermNotTwo() {
        let overlay = FamilyKinshipOverlay(
            snapshots: profiles.map {
                ArchivistGraphProfileSnapshot(
                    stableID: $0.stableID, canonicalName: $0.canonicalName,
                    aliases: $0.aliases, kinships: $0.kinships, sex: $0.sex,
                    birthdate: $0.birthdate, deathdate: nil, uuid: $0.uuid,
                    treeIdentity: $0.treeIdentity)
            }, graph: nil)

        for typed in [["tim"], ["Tim"], ["TIM"], ["my brother"], ["me"], []] {
            let bound = HallieTurnExecutor.SpeakerKinship.rebind(
                people: typed, question: "find videos of my brother tim",
                speakers: speakers, graph: nil, kinshipOverlay: overlay)
            let label = Comment(rawValue: "\(typed) → \(bound.people)")
            #expect(bound.failure == nil, label)
            #expect(bound.people == ["Tim"], label)
        }
    }

    /// The same guarantee through the tree branch of the rebind.
    @Test func myBrotherTimIsOnePersonTermThroughTheTreeToo() {
        for typed in [["tim"], ["Tim"], ["my brother"], []] {
            let bound = HallieTurnExecutor.SpeakerKinship.rebind(
                people: typed, question: "find videos of my brother tim",
                speakers: speakers, graph: tree)
            #expect(bound.people == ["Tim Breen"],
                    Comment(rawValue: "\(typed) → \(bound.people)"))
        }
    }

    /// The renderer itself: whatever reaches it, a name is never said in
    /// two casings. Asserted on the JOINED PROSE, not on the internal set.
    @Test func noAnswerEverSaysOneNameInTwoCasings() {
        let queries = [
            "shape=presence person=tim person=Tim",
            "shape=presence person=Tim person=tim",
            "shape=presence person=tim person=TIM person=Tim",
            "shape=presence person=Tim person=Timmy",
        ]
        for query in queries {
            let answer = ArchivistPresenceAnswerComposer.noEvidenceAnswer(for: query)
            let label = Comment(rawValue: "\(query) → \(answer)")
            #expect(!answer.contains("tim and Tim"), label)
            #expect(!answer.contains("Tim and tim"), label)
            // A name may appear twice in ONE casing (the sentence names the
            // person twice by design); it may never appear in two.
            let words = answer.split(whereSeparator: { !$0.isLetter })
                .map(String.init)
            let casings = Dictionary(grouping: words, by: PersonResolver.normalize)
                .mapValues { Set($0).count }
            #expect(casings.values.allSatisfy { $0 == 1 }, label)
        }
        // Two genuinely different people are still both named.
        let two = ArchivistPresenceAnswerComposer.noEvidenceAnswer(
            for: "shape=presence person=Tim person=Timmy")
        #expect(two.contains("Tim and Timmy"))
    }

    /// The query itself carries one identity, so the per-record tag scan is
    /// not doubled either.
    @Test func duplicatePersonTermsCollapseInTheQuery() {
        let query = ArchivistPresenceQuery(
            .init(people: ["tim", "Tim", "TIM"]))
        #expect(query.description == "shape=presence person=tim")
    }

    // MARK: (b) exact name wins — the three eval questions

    /// live/lv260902-004. The whole turn: the decline names Tim once.
    @Test func findVideosOfMyBrotherTimNamesTimOnce() async throws {
        let result = try await HallieTurnExecutor.execute(
            .init(intent: .init(
                originalQuestion: "find videos of my brother tim",
                ast: .presence(.init(people: ["tim"])))),
            context: context(graph: tree))
        let label = Comment(rawValue: result.prose)
        #expect(!result.prose.contains("tim and Tim"), label)
        #expect(!result.prose.lowercased().contains("which"), label)
        #expect(result.prose.contains("Tim"), label)
    }

    /// live/lv260902-023 — the question that must simply be answered.
    @Test func whoAreTimsParentsAnswersWithoutAskingWhichTim() async throws {
        for typed in ["tim", "Tim", "TIM"] {
            let result = try await HallieTurnExecutor.execute(
                .graph(.init(people: [typed], operation: .kinship, relation: .parents)),
                context: context(graph: tree))
            let label = Comment(rawValue: "\(typed) → \(result.prose)")
            #expect(result.outcome == .answered, label)
            #expect(result.prose.contains("Richard Harding Breen Sr"), label)
            #expect(result.prose.contains("Eileen Marie Latta"), label)
            #expect(!result.prose.lowercased().contains("do you mean"), label)
        }
    }

    /// conjunction/cj008 as its two clauses: neither asks which Tim, and
    /// the age comes from the BROTHER's 1960 birthdate, not the son's 1996.
    @Test func timsBrotherAndTimsAgeBothResolveToTheBrother() async throws {
        let brotherOf = try await HallieTurnExecutor.execute(
            .graph(.init(people: ["Tim"], operation: .kinship, relation: .brother)),
            context: context(graph: tree))
        #expect(brotherOf.outcome == .answered, Comment(rawValue: brotherOf.prose))
        #expect(brotherOf.prose.contains("Rick Breen"),
                Comment(rawValue: brotherOf.prose))

        let age = try await HallieTurnExecutor.execute(
            .temporal(.init(subject: "Tim", operation: .age, reference: .currentSelection)),
            context: .init(
                profiles: profiles,
                selectedTemporalDate: .catalogCreation(
                    recordID: UUID(), fullPath: "/synthetic/2020-01-01.mov",
                    date: Self.date(2020, 1, 1)),
                speakers: speakers))
        let label = Comment(rawValue: age.prose)
        #expect(age.outcome == .answered, label)
        #expect(!age.prose.lowercased().contains("do you mean"), label)
        // 1960-06-11 → 2020-01-01 is 59, not the son's 23.
        #expect(age.prose.contains("59 years"), label)
    }

    /// The People-tab verdict underneath all three, for every casing.
    @Test func everyCasingOfTheCrossClaimedNamesResolves() {
        for spelling in ["tim", "Tim", "TIM"] {
            #expect(Tab.profile(claiming: spelling, in: profiles)?.stableID == "tim",
                    Comment(rawValue: spelling))
        }
        for spelling in ["timmy", "Timmy", "TIMMY"] {
            #expect(Tab.profile(claiming: spelling, in: profiles)?.stableID == "timmy",
                    Comment(rawValue: spelling))
        }
        // A spelling only ONE of them aliases still goes to that one.
        #expect(Tab.profile(claiming: "Timothy", in: profiles)?.stableID == "tim")
        #expect(Tab.profile(claiming: "Tim Jr", in: profiles)?.stableID == "timmy")
    }

    // MARK: The regression risk — real ambiguity must STILL ask

    /// Two people genuinely NAMED John. This is what disambiguation is for,
    /// it must survive the exact-name-wins rule, and the question has to
    /// tell them apart — "Which John do you mean?" on its own gives the
    /// listener nothing to choose between.
    @Test func twoProfilesTrulyNamedJohnStillAsk() async throws {
        let johns = [
            Profile(stableID: "john-elder", canonicalName: "John",
                    aliases: ["Jack"], birthdate: Self.date(1931, 2, 3)),
            Profile(stableID: "john-younger", canonicalName: "John",
                    aliases: ["Johnny"], birthdate: Self.date(1967, 8, 30)),
        ]
        #expect(Tab.claim("John", in: johns) == .ambiguous(johns))
        #expect(Tab.profile(claiming: "john", in: johns) == nil)

        for graph in [nil, tree] as [GedcomFamilyGraph?] {
            let result = try await HallieTurnExecutor.execute(
                .init(intent: .init(
                    originalQuestion: "who is john?",
                    ast: .graph(.init(people: ["john"], operation: .biography)))),
                context: .init(profiles: johns, graph: graph, speakers: speakers))
            let label = Comment(rawValue: "tree=\(graph != nil) → \(result.prose)")
            #expect(result.outcome == .needsClarification, label)
            #expect(result.prose
                    == "Which John do you mean — John (born 1931) or John (born 1967)?",
                    label)
            #expect(result.clarification?.candidates.map(\.id)
                    == [.profileStableID("john-elder"),
                        .profileStableID("john-younger")], label)
        }
    }

    /// And when nobody is NAMED the spelling, two alias claimants still ask
    /// — the narrowing removed a false tie, not the feature.
    @Test func aSpellingTwoProfilesOnlyAliasStillAsks() {
        let a = Profile(stableID: "a", canonicalName: "Richard Sr", aliases: ["Dick"])
        let b = Profile(stableID: "b", canonicalName: "Richard Jr", aliases: ["Dick"])
        // Ordered by canonical name: "Richard Jr" before "Richard Sr".
        #expect(Tab.claim("Dick", in: [a, b]) == .ambiguous([b, a]))
        #expect(Tab.profile(claiming: "Dick", in: [a, b]) == nil)
    }

    /// The which-one sentence never says one name in two casings either,
    /// and never echoes a lowercase typed name back at the family.
    @Test func theWhichOneQuestionIsWellFormed() {
        let prose = HallieProfileWhichOne.prose(
            typed: "tim",
            choices: [.init(name: "Tim", birthdate: Self.date(1960, 6, 11)),
                      .init(name: "Timmy", birthdate: Self.date(1996, 4, 22))])
        #expect(prose == "Which Tim do you mean — Tim or Timmy?")
        #expect(!prose.contains("Which tim"))

        // Shared name → the birth year is the discriminator.
        let shared = HallieProfileWhichOne.prose(
            typed: "john",
            choices: [.init(name: "John", birthdate: Self.date(1931, 2, 3)),
                      .init(name: "John", birthdate: Self.date(1967, 8, 30))])
        #expect(shared == "Which John do you mean — John (born 1931) or John (born 1967)?")

        // Shared name, no dates: fall back to whatever else tells them
        // apart rather than saying "John or John".
        let undated = HallieProfileWhichOne.prose(
            typed: "john",
            choices: [.init(name: "John", fallbackDetail: "john-a"),
                      .init(name: "John", fallbackDetail: "john-b")])
        #expect(undated == "Which John do you mean — John (john-a) or John (john-b)?")
    }
}
