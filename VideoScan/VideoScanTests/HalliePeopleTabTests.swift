import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

/// The People tab as a knowledge source (Rick 2026-08-22): Hallie must know
/// the people most likely to be talking with her — by every name they go
/// by — even when the family tree stops before them.
struct HalliePeopleTabTests {
    typealias Tab = HallieTurnExecutor.PeopleTab
    typealias Profile = HallieTurnExecutor.ProfileSnapshot

    /// The real gallery's shape: brother and son cross-claim each other's name.
    private let tim = Profile(stableID: "tim", canonicalName: "Tim",
                              aliases: ["Mimmy", "Timmy", "Brother"], note: "Brother Tim")
    private let timmy = Profile(stableID: "timmy", canonicalName: "Timmy",
                                aliases: ["Tim", "Timmy"],
                                birthdate: Self.date(1965, 4, 22),
                                note: "Number four son, sometimes wears glasses")
    private let dad = Profile(stableID: "dad", canonicalName: "Dad",
                              aliases: ["Grampa Breen", "Dick", "Dad Breen"],
                              birthdate: Self.date(1898, 2, 19), note: "My father")

    /// A tree that ends in 1959 and names none of the three.
    private let tree = GedcomFamilyGraph(gedcomText: """
    0 HEAD
    0 @I1@ INDI
    1 NAME Rick /Breen/
    1 SEX M
    1 BIRT
    2 DATE 4 MAR 1959
    0 @I2@ INDI
    1 NAME Eileen Marie /Latta/
    1 SEX F
    1 BIRT
    2 DATE 31 AUG 1930
    0 TRLR
    """)

    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func records(taggedWith names: [String]) -> [ArchivistPresenceRecordSnapshot] {
        names.enumerated().map { index, name in
            ArchivistPresenceRecordSnapshot(
                fullPath: "/v/clip\(index).mov",
                confirmedPeople: [ConfirmedTag(name: name, confirmedAt: Date())])
        }
    }

    private func intent(_ question: String, people: [String],
                        operation: ArchivistQueryAST.Graph.Operation,
                        relation: ArchivistQueryAST.Graph.Relation? = nil) -> HallieTurnExecutor.Intent {
        HallieTurnExecutor.Intent(
            originalQuestion: question,
            ast: .graph(.init(people: people, operation: operation, relation: relation)))
    }

    // MARK: Spelling → profile

    @Test func theExactNameWinsWhenBrotherAndSonCrossClaimIt() {
        let profiles = [tim, timmy, dad]
        #expect(Tab.profile(claiming: "Timmy", in: profiles)?.stableID == "timmy")
        #expect(Tab.profile(claiming: "tim", in: profiles)?.stableID == "tim")
        #expect(Tab.profile(claiming: "Mimmy", in: profiles)?.stableID == "tim")
        #expect(Tab.profile(claiming: "dad breen", in: profiles)?.stableID == "dad")
        #expect(Tab.profile(claiming: "Grampa Breen", in: profiles)?.stableID == "dad")
        #expect(Tab.profile(claiming: "Matt", in: profiles) == nil)
    }

    @Test func anAliasClaimedByTwoProfilesStaysAmbiguous() {
        let a = Profile(stableID: "a", canonicalName: "Richard Sr", aliases: ["Dick"])
        let b = Profile(stableID: "b", canonicalName: "Richard Jr", aliases: ["Dick"])
        #expect(Tab.profile(claiming: "Dick", in: [a, b]) == nil)
    }

    // MARK: "who is Timmy?" — the tree stops in 1959, the People tab knows him

    @Test func biographyComesFromTheProfileWhenTheTreeHasNoEntry() async throws {
        let context = HallieTurnExecutor.Context(
            presenceRecords: records(taggedWith: ["Timmy", "Tim", "Timmy", "Donna"]),
            profiles: [tim, timmy, dad], graph: tree)
        let result = try await HallieTurnExecutor.execute(
            .init(intent: intent("who is Timmy?", people: ["Timmy"], operation: .biography)),
            context: context)

        #expect(result.outcome == .answered)
        #expect(result.clarification == nil)
        #expect(result.prose.hasPrefix("Timmy is one of the people in the People tab — also known as Tim."))
        #expect(result.prose.contains("was born 22 Apr 1965, according to the People profile"))
        // "Tim" is an alias of Timmy, so the brother's tag counts too — that
        // is the gallery's own ambiguity, reported as the data says it.
        #expect(result.prose.contains("tagged in 3 catalog videos"))
        #expect(result.prose.contains("The note on the profile says: “Number four son, sometimes wears glasses” — that's a note, not something I've verified."))
        #expect(result.prose.contains("I couldn't match Timmy to a record in the family tree I have."))
        #expect(!result.prose.contains("goes up to people born"), "no max-birth-year reach claim (2026-08-26)")
        #expect(result.prose.hasSuffix("If you tell me more about Timmy — “let me tell you about Timmy” — I'll remember it."))
        #expect(!result.prose.contains("don't find"))
        #expect(result.basisLine.contains("People profile “Timmy”"))
        #expect(result.basisLine.contains("note — quoted, not verified"))
        #expect(result.catalogPersonName == "Timmy")
    }

    @Test func theBrotherIsAnsweredFromHisOwnProfileWithoutInventingADate() async throws {
        let context = HallieTurnExecutor.Context(
            presenceRecords: records(taggedWith: ["Donna"]), profiles: [tim, timmy], graph: tree)
        let result = try await HallieTurnExecutor.execute(
            .init(intent: intent("who is Tim?", people: ["Tim"], operation: .biography)),
            context: context)
        #expect(result.outcome == .answered)
        #expect(result.prose.hasPrefix("Tim is one of the people in the People tab — also known as Mimmy, Timmy, Brother."))
        #expect(!result.prose.contains("was born"))
        #expect(result.prose.contains("isn't tagged in any catalog videos yet"))
        #expect(result.prose.contains("“Brother Tim”"))

        // A client that supplied no catalog records (the shell's graph
        // context) must not claim "none tagged".
        let blind = try await HallieTurnExecutor.execute(
            .init(intent: intent("who is Tim?", people: ["Tim"], operation: .biography)),
            context: HallieTurnExecutor.Context(profiles: [tim, timmy], graph: tree))
        #expect(!blind.prose.contains("tagged"))
        #expect(!blind.basisLine.contains("catalog tags"))
    }

    @Test func birthDateComesFromTheProfileAndIsMissingHonestly() async throws {
        let context = HallieTurnExecutor.Context(profiles: [tim, timmy, dad], graph: tree)
        let born = try await HallieTurnExecutor.execute(
            .init(intent: intent("when was Dad born?", people: ["Dad"], operation: .birth)),
            context: context)
        #expect(born.outcome == .answered)
        #expect(born.prose.hasPrefix("Dad was born 19 Feb 1898, according to the People profile."))

        let unknown = try await HallieTurnExecutor.execute(
            .init(intent: intent("when was Tim born?", people: ["Tim"], operation: .birth)),
            context: context)
        #expect(unknown.outcome == .declined)
        #expect(unknown.prose.hasPrefix("The People profile for Tim doesn't record a birth date."))
    }

    @Test func kinshipDeclinesByNameInsteadOfNotFindingThePerson() async throws {
        let context = HallieTurnExecutor.Context(profiles: [tim, timmy], graph: tree)
        let result = try await HallieTurnExecutor.execute(
            .init(intent: intent("who is Timmy's father?", people: ["Timmy"],
                                 operation: .kinship, relation: .father)),
            context: context)
        #expect(result.outcome == .declined)
        #expect(result.prose.hasPrefix("Timmy is in the People tab (also known as Tim), so I know the name — but I can't trace father for Timmy yet."))
        #expect(result.prose.contains("I couldn't match Timmy to a record in the family tree I have."))
        #expect(!result.prose.contains("1959"), "no max-birth-year reach claim (2026-08-26)")
        #expect(!result.prose.contains("don't find"))
    }

    @Test func withoutAnyTreeTheProfileStillAnswers() async throws {
        let context = HallieTurnExecutor.Context(profiles: [dad], graph: nil)
        let result = try await HallieTurnExecutor.execute(
            .init(intent: intent("who is Dad Breen?", people: ["Dad Breen"], operation: .biography)),
            context: context)
        #expect(result.outcome == .answered)
        #expect(result.prose.hasPrefix("Dad is one of the people in the People tab — also known as Grampa Breen, Dick, Dad Breen."))
        #expect(result.prose.contains("I don't have an imported family tree to place Dad in."))
    }

    @Test func someoneInNeitherPlaceStillGetsTheOldNotFoundOffer() async throws {
        let context = HallieTurnExecutor.Context(profiles: [tim, timmy], graph: tree)
        let result = try await HallieTurnExecutor.execute(
            .init(intent: intent("who is Matt?", people: ["Matt"], operation: .biography)),
            context: context)
        #expect(result.outcome == .declined)
        #expect(result.prose.contains("don't find"))
        #expect(result.prose.contains("let me tell you about Matt"))
    }

    // MARK: "who do you know?"

    @Test func rosterQuestionsAreRecognisedAndOrdinaryQuestionsAreNot() {
        for yes in ["who do you know?", "Hallie, who do you know about?", "Which people do you know",
                    "who is in the People tab", "who can I ask you about?", "list the people you know",
                    "who's in the family?", "what people are in the people tab"] {
            #expect(Tab.isRosterQuestion(yes), Comment(rawValue: yes))
        }
        for no in ["who do you know who was at the wedding?", "who is Timmy?", "what do you know",
                   "show me videos of the people on the cape", "who knows Donna?"] {
            #expect(!Tab.isRosterQuestion(no), Comment(rawValue: no))
        }
    }

    @Test func rosterListsEveryProfileWithItsOtherNames() {
        let result = Tab.rosterAnswer(profiles: [timmy, dad, tim], graph: tree, cyberBrain: nil)
        #expect(result.route == .capability)
        #expect(result.outcome == .answered)
        #expect(result.prose.hasPrefix(
            "I know 3 people from the People tab: Dad (also Grampa Breen, Dick, Dad Breen); Tim (also Mimmy, Timmy, Brother); Timmy (also Tim)."))
        #expect(result.prose.contains("The family tree adds 2 more names, going up to people born in 1959."))
        #expect(result.prose.hasSuffix("Ask me about anyone by name."))
        #expect(result.basisLine == "Basis: People profiles (3); family tree (2 people); no model call.")

        let unreadable = Tab.rosterAnswer(profiles: nil, graph: nil, cyberBrain: nil)
        #expect(unreadable.outcome == .declined)
        let empty = Tab.rosterAnswer(profiles: [], graph: nil, cyberBrain: nil)
        #expect(empty.prose.contains("empty so far"))
    }

    @Test func rosterIsAnsweredBeforeTranslation() {
        let pre = HallieTurnExecutor.preTranslation(
            question: "who do you know?", playAfterAnswer: false,
            memory: .init(), isKnownPerson: { _ in false },
            rosterAnswer: { Tab.rosterAnswer(profiles: [self.dad], graph: nil, cyberBrain: nil) })
        guard case .answer(let result) = pre else {
            Issue.record("expected a local answer, got \(pre)"); return
        }
        #expect(result.prose.hasPrefix("I know 1 person from the People tab: Dad"))
        // Without a roster closure (a client that doesn't supply one) the
        // question goes to the translator as before.
        let none = HallieTurnExecutor.preTranslation(
            question: "who do you know?", playAfterAnswer: false,
            memory: .init(), isKnownPerson: { _ in false })
        guard case .translate = none else { Issue.record("expected translate"); return }
    }
}
