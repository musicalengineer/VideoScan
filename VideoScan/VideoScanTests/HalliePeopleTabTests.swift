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

    /// Brother and son with distinct spellings — the content tests below
    /// are about what a profile SAYS, not about who owns a spelling.
    private let tim = Profile(stableID: "tim", canonicalName: "Tim",
                              aliases: ["Mimmy", "Brother"], note: "Brother Tim")
    private let timmy = Profile(stableID: "timmy", canonicalName: "Timmy",
                                aliases: ["Tim Jr", "Timmy"],
                                birthdate: Self.date(1965, 4, 22),
                                note: "Number four son, sometimes wears glasses")
    /// The real gallery's shape (Rick 2026-08-22): the brother lists
    /// "Timmy" as an alias and the son lists "Tim" — each claims the
    /// other's name. Used only by the identity tests.
    private let crossTim = Profile(stableID: "tim", canonicalName: "Tim",
                                   aliases: ["Timmy", "Mimmy"], note: "Brother Tim")
    private let crossTimmy = Profile(stableID: "timmy", canonicalName: "Timmy",
                                     aliases: ["Tim", "Tim Jr"],
                                     birthdate: Self.date(1965, 4, 22))
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

    /// Rule #778 AMENDED 2026-09-03 (Director — exact name wins, the People
    /// tab's own rule from 2026-08-22): a spelling claimed by two profiles
    /// belongs to the one NAMED it. Before this, "tim" was ambiguous
    /// because the brother is named Tim and the son aliases Tim, so every
    /// question about either brother or son asked which one.
    @Test func aCrossClaimedSpellingGoesToTheProfileNamedIt() {
        let profiles = [crossTim, crossTimmy, dad]
        #expect(Tab.claim("Timmy", in: profiles) == .one(crossTimmy))
        #expect(Tab.claim("tim", in: profiles) == .one(crossTim))
        #expect(Tab.claim("TIM", in: profiles) == .one(crossTim))
        #expect(Tab.profile(claiming: "Timmy", in: profiles)?.stableID == "timmy")
        #expect(Tab.profile(claiming: "Tim", in: profiles)?.stableID == "tim")
        // Unique spellings still resolve.
        #expect(Tab.profile(claiming: "Mimmy", in: profiles)?.stableID == "tim")
        #expect(Tab.profile(claiming: "Tim Jr", in: profiles)?.stableID == "timmy")
        #expect(Tab.profile(claiming: "dad breen", in: profiles)?.stableID == "dad")
        #expect(Tab.profile(claiming: "Grampa Breen", in: profiles)?.stableID == "dad")
        #expect(Tab.profile(claiming: "Matt", in: profiles) == nil)
        #expect(Tab.claim("Matt", in: profiles) == .none)
        // A chosen chip names the profile directly, bypassing resolution.
        #expect(Tab.claim("Timmy", selected: .profileStableID("timmy"), in: profiles) == .one(crossTimmy))
        #expect(Tab.claim("Timmy", selected: .profileStableID("gone"), in: profiles) == .none)
    }

    /// Mirror of ArchivistGraphExecutorTests.executorAndPersonResolverGiveOneVerdict
    /// for the People-tab path: with or without a tree, the executor's
    /// outcome for every spelling is exactly PersonResolver's verdict.
    @Test func peopleTabAndPersonResolverGiveOneVerdict() async throws {
        let other = Profile(stableID: "other", canonicalName: "Timothy", aliases: ["Mimmy"])
        let profiles = [crossTim, crossTimmy, other]
        let resolver = PersonResolver(people: profiles.map {
            ResolvablePerson(canonicalName: $0.canonicalName, aliases: $0.aliases)
        })
        let stableID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.canonicalName, $0.stableID) })
        for graph in [nil, tree] as [GedcomFamilyGraph?] {
            let context = HallieTurnExecutor.Context(profiles: profiles, graph: graph)
            for spelling in ["Tim", "Timmy", "Mimmy", "Timothy", "Tim Jr", "TIMMY", "Nobody"] {
                let label = Comment(rawValue: "\(spelling) tree=\(graph != nil)")
                let result = try await HallieTurnExecutor.execute(
                    .init(intent: intent("who is \(spelling)?", people: [spelling], operation: .biography)),
                    context: context)
                switch resolver.resolve(spelling) {
                case .ambiguous(let candidates):
                    #expect(result.outcome == .needsClarification, label)
                    // The question names the candidates: a which-one the
                    // listener cannot answer is itself a bug (2026-09-03).
                    #expect(result.prose == HallieProfileWhichOne.prose(
                        typed: spelling,
                        choices: candidates.map { .init(name: $0) }), label)
                    #expect(result.prose.contains(" or "), label)
                    #expect(result.clarification?.stage == .profileIdentity, label)
                    #expect(result.clarification?.candidates.map(\.id)
                            == candidates.map { .profileStableID(stableID[$0]!) }, label)
                    #expect(result.clarification?.candidates.map(\.label) == candidates, label)
                case .resolved(let canonicalName):
                    #expect(result.outcome == .answered, label)
                    #expect(result.clarification == nil, label)
                    #expect(result.prose.hasPrefix("\(canonicalName) is one of the people in the People tab"), label)
                case .unknown:
                    #expect(result.outcome == .declined, label)
                    #expect(result.clarification == nil, label)
                }
            }
        }
    }

    /// Picking a chip after "which one?" finishes the turn from that
    /// profile — with no tree (People-tab path) and with one (graph path).
    ///
    /// The ask is now driven by a spelling BOTH profiles only alias
    /// ("Bud"): since 2026-09-03 "Timmy" belongs outright to the profile
    /// named Timmy, so it no longer asks. Chip selection itself is
    /// unchanged, and still has to work.
    @Test func choosingAChipAfterWhichOneAnswersFromThatProfile() async throws {
        let brother = Profile(stableID: "tim", canonicalName: "Tim",
                              aliases: ["Timmy", "Mimmy", "Bud"], note: "Brother Tim")
        let son = Profile(stableID: "timmy", canonicalName: "Timmy",
                          aliases: ["Tim", "Tim Jr", "Bud"],
                          birthdate: Self.date(1965, 4, 22))
        for graph in [nil, tree] as [GedcomFamilyGraph?] {
            let context = HallieTurnExecutor.Context(profiles: [brother, son], graph: graph)
            let asked = try await HallieTurnExecutor.execute(
                .init(intent: intent("who is Bud?", people: ["Bud"], operation: .biography)),
                context: context)
            let pending = try #require(asked.clarification)
            #expect(asked.prose == "Which Bud do you mean — Tim or Timmy?")
            #expect(pending.candidates.map(\.label) == ["Tim", "Timmy"])
            let son = try await HallieTurnExecutor.continue(
                pending: pending, selecting: .profileStableID("timmy"), context: context)
            #expect(son.outcome == .answered)
            #expect(son.prose.hasPrefix("Timmy is one of the people in the People tab — also known as Tim, Tim Jr, Bud."))
            // House format (`HallieDateStyle`, 2026-09-03). These pinned
            // "22 Apr 1965" — the People tab's own abbreviated month, a
            // second date format in Hallie's answers and the reason "when
            // was Tim born" came back two different ways on two runs.
            #expect(son.prose.contains("was born 22 April 1965, according to the People profile"))
            let chosenBrother = try await HallieTurnExecutor.continue(
                pending: pending, selecting: .profileStableID("tim"), context: context)
            #expect(chosenBrother.outcome == .answered)
            #expect(chosenBrother.prose.hasPrefix("Tim is one of the people in the People tab — also known as Timmy, Mimmy, Bud."))
        }
    }

    @Test func anAliasClaimedByTwoProfilesStaysAmbiguous() {
        let a = Profile(stableID: "a", canonicalName: "Richard Sr", aliases: ["Dick"])
        let b = Profile(stableID: "b", canonicalName: "Richard Jr", aliases: ["Dick"])
        #expect(Tab.profile(claiming: "Dick", in: [a, b]) == nil)
    }

    // MARK: "who is Timmy?" — the tree stops in 1959, the People tab knows him

    @Test func biographyComesFromTheProfileWhenTheTreeHasNoEntry() async throws {
        let context = HallieTurnExecutor.Context(
            presenceRecords: records(taggedWith: ["Timmy", "Tim Jr", "Timmy", "Donna"]),
            profiles: [tim, timmy, dad], graph: tree)
        let result = try await HallieTurnExecutor.execute(
            .init(intent: intent("who is Timmy?", people: ["Timmy"], operation: .biography)),
            context: context)

        #expect(result.outcome == .answered)
        #expect(result.clarification == nil)
        #expect(result.prose.hasPrefix("Timmy is one of the people in the People tab — also known as Tim Jr."))
        #expect(result.prose.contains("was born 22 April 1965, according to the People profile"))
        // Tags under any of the profile's own names count.
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
        #expect(result.prose.hasPrefix("Tim is one of the people in the People tab — also known as Mimmy, Brother."))
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
        #expect(born.prose.hasPrefix("Dad was born 19 February 1898, according to the People profile."))

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
        #expect(result.prose.hasPrefix("Timmy is in the People tab (also known as Tim Jr), so I know the name — but I can't trace father for Timmy yet."))
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
                    "who's in the family?", "what people are in the people tab",
                    "tell me about the people in the catalog", "read their names",
                    "can you read their names for me"] {
            #expect(Tab.isRosterQuestion(yes), Comment(rawValue: yes))
        }
        for no in ["who do you know who was at the wedding?", "who is Timmy?", "what do you know",
                   "show me videos of the people on the cape", "who knows Donna?",
                   "who is in the family tree", "tell me about Tim in the catalog",
                   "find videos of the people in the catalog", "who is in New Hampshire.mov"] {
            #expect(!Tab.isRosterQuestion(no), Comment(rawValue: no))
        }
    }

    @Test func catalogRosterAndKnowledgeRosterAreDistinctIntents() {
        for question in [
            "tell me about the people in the catalog",
            "Tell me about people in catalog",
            "tell me about everyone in the catalog",
            "who do you know in the catalog?",
            "who is in the catalog?",
            "list the names in the People tab",
            "do you know the people in the people tab and can you read their names for me?",
            "Matt is my son. Tim is my brother. Do you know the people in the people tab and can you read their names for me?",
            "read their names",
        ] {
            #expect(Tab.rosterScope(for: question) == .catalog, Comment(rawValue: question))
        }
        for question in ["who do you know?", "list everyone you know", "who can I ask you about?"] {
            #expect(Tab.rosterScope(for: question) == .knowledge, Comment(rawValue: question))
        }
        for question in [
            "tell me about the people in the family tree",
            "who is Timmy?",
            "tell me about Donna in the catalog",
            "show me videos of people in the catalog",
            "find footage with everyone in the People tab",
            "which people in the catalog were at the Cape",
            "which people in the catalog were at the wedding in 1994",
            "who is in New Hampshire.mov",
            "list their names",
            "can you list their names",
            "tell me their names",
            "what are their names",
            "name them",
        ] {
            #expect(Tab.rosterScope(for: question) == nil, Comment(rawValue: question))
        }
    }

    @Test func rosterListsEveryProfileWithItsOtherNames() {
        let result = Tab.rosterAnswer(profiles: [timmy, dad, tim], graph: tree, cyberBrain: nil)
        #expect(result.route == .capability)
        #expect(result.outcome == .answered)
        #expect(result.prose.hasPrefix(
            "I know 3 people from the People tab: Dad (also Grampa Breen, Dick, Dad Breen); Tim (also Mimmy, Brother); Timmy (also Tim Jr)."))
        #expect(result.prose.contains("The family tree adds 2 more names, going up to people born in 1959."))
        #expect(result.prose.hasSuffix("Ask me about anyone by name."))
        #expect(result.basisLine == "Basis: People profiles (3); family tree (2 people); no model call.")

        let unreadable = Tab.rosterAnswer(profiles: nil, graph: nil, cyberBrain: nil)
        #expect(unreadable.outcome == .declined)
        let empty = Tab.rosterAnswer(profiles: [], graph: nil, cyberBrain: nil)
        #expect(empty.prose.contains("empty so far"))
    }

    @Test func catalogRosterNamesOnlyPeopleProfiles() throws {
        let privateTree = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I1@ INDI
        1 NAME Tree Only /Secret/
        0 TRLR
        """)
        let privateTold = try CyberBrainIndex(archive: CyberBrainArchive(
            archiveID: "fixture", displayName: "Fixture",
            people: [CyberBrainPerson(id: "private", canonicalName: "Told Only Secret")],
            sources: []))
        let result = Tab.rosterAnswer(
            profiles: [timmy, dad, tim], graph: privateTree,
            cyberBrain: privateTold, scope: .catalog)

        #expect(result.prose.hasPrefix(
            "The People-tab catalog roster has 3 people: Dad (also Grampa Breen, Dick, Dad Breen); Tim (also Mimmy, Brother); Timmy (also Tim Jr)."))
        #expect(!result.prose.contains("Tree Only Secret"))
        #expect(!result.prose.contains("Told Only Secret"))
        #expect(!result.prose.contains("family tree adds"))
        #expect(!result.prose.contains("family has told"))
        #expect(result.basisLine == "Basis: People profiles (3); catalog roster only — family-tree and family-told names not listed; no model call.")
        #expect(result.offeredActions == [.openPeopleTab])
    }

    @Test func catalogRosterOrderingIsStableAcrossInputOrderAndNameTies() throws {
        let a = Profile(stableID: "a", canonicalName: "Same Name", aliases: ["First Stable ID"])
        let z = Profile(stableID: "z", canonicalName: "Same Name", aliases: ["Last Stable ID"])
        let beta = Profile(stableID: "b", canonicalName: "Beta")
        let forward = Tab.rosterAnswer(
            profiles: [z, beta, a], graph: nil, cyberBrain: nil, scope: .catalog)
        let reverse = Tab.rosterAnswer(
            profiles: [a, beta, z], graph: nil, cyberBrain: nil, scope: .catalog)

        #expect(forward.prose == reverse.prose)
        let betaRange = try #require(forward.prose.firstRange(of: "Beta"))
        let firstStableIDRange = try #require(forward.prose.firstRange(of: "First Stable ID"))
        let lastStableIDRange = try #require(forward.prose.firstRange(of: "Last Stable ID"))
        #expect(betaRange.lowerBound < firstStableIDRange.lowerBound)
        #expect(firstStableIDRange.lowerBound < lastStableIDRange.lowerBound)
    }

    @Test func duplicateStableIDsProduceTheSameRosterInEitherInputOrder() {
        let first = Profile(
            stableID: "duplicate", canonicalName: "Zed",
            aliases: ["Third", "First"])
        let second = Profile(
            stableID: "duplicate", canonicalName: "Alpha",
            aliases: ["Second", "Fourth"])
        let forward = Tab.rosterAnswer(
            profiles: [first, second], graph: nil, cyberBrain: nil, scope: .catalog)
        let reverse = Tab.rosterAnswer(
            profiles: [second, first], graph: nil, cyberBrain: nil, scope: .catalog)

        #expect(forward.prose == reverse.prose)
        #expect(forward.prose.contains("Alpha (also First, Fourth, Second and 1 more)"))
    }

    @Test(.timeLimit(.minutes(1))) func hundredThousandProfileRosterIsBoundedAndDeterministic() {
        var profiles: [Profile] = []
        profiles.reserveCapacity(100_000)
        for index in (0..<100_000).reversed() {
            profiles.append(Profile(
                stableID: String(format: "id-%06d", index),
                canonicalName: String(format: "Person %06d", index),
                aliases: [String(format: "Alias %06d", index)]))
        }

        let start = ContinuousClock.now
        let result = Tab.rosterAnswer(
            profiles: profiles, graph: nil, cyberBrain: nil, scope: .catalog)
        let elapsed = ContinuousClock.now - start

        #expect(elapsed < .seconds(10), Comment(rawValue: "100k roster took \(elapsed)"))
        #expect(result.prose.contains("Person 000000 (also Alias 000000)"))
        #expect(result.prose.contains("Person 000023 (also Alias 000023)"))
        #expect(!result.prose.contains("Person 000024"))
        #expect(!result.prose.contains("Person 099999"))
        #expect(result.prose.contains("I read the first 24 alphabetically; 99976 more are in the People tab."))
        #expect(result.prose.count < 4_000, "answer text must stay bounded")
    }

    @Test func poisonedPreferencesCannotAddNamesToTheCatalogRoster() {
        let key = "HalliePeopleTabTests.poison.\(UUID().uuidString)"
        let defaults = UserDefaults.standard
        defaults.set(["Private Preferences Person", "Tree Only Secret"], forKey: key)
        defer { defaults.removeObject(forKey: key) }

        let result = Tab.rosterAnswer(
            profiles: [dad], graph: nil, cyberBrain: nil, scope: .catalog)
        #expect(result.prose.contains("Dad"))
        #expect(!result.prose.contains("Private Preferences Person"))
        #expect(!result.prose.contains("Tree Only Secret"))
        #expect(defaults.array(forKey: key)?.count == 2,
                "pure roster code must neither read nor mutate global preferences")
    }

    @Test func corruptHugeNamesAndAliasesStayInsideTheGraphemeSafeBudget() {
        let grapheme = "👨‍👩‍👧‍👦"
        let hugeName = String(repeating: grapheme, count: 20_000)
        let hugeAlias = String(repeating: "e\u{301}", count: 20_000)
        let profiles = (0..<24).map { index in
            Profile(
                stableID: String(format: "id-%02d", index),
                canonicalName: hugeName + String(format: "%02d", index),
                aliases: [hugeAlias + String(index)])
        }

        let result = Tab.rosterAnswer(
            profiles: profiles, graph: nil, cyberBrain: nil, scope: .catalog)

        #expect(result.prose.count < 1_600)
        #expect(result.prose.contains(String(repeating: grapheme, count: 79) + "…"))
        #expect(result.prose.contains("I read the first 8 alphabetically; 16 more are in the People tab."))
        #expect(!result.prose.contains(String(repeating: grapheme, count: 80)))
    }

    @Test func pronounNameFollowUpsDoNotStealSiblingOrPresenceMemory() {
        var siblingMemory = HallieTurnExecutor.ConversationMemory()
        let siblingIntent = intent(
            "who are Rick's siblings", people: ["Rick"],
            operation: .kinship, relation: .siblings)
        let siblingAnswer = HallieTurnExecutor.Result(
            route: .graph, outcome: .answered,
            prose: "Rick's siblings are Eileen and Tim.",
            basisLine: "Basis: family tree.",
            queryDescription: "shape=graph operation=kinship relation=siblings",
            citations: [], catalogPersonName: "Rick")
        siblingMemory.record(intent: siblingIntent, result: siblingAnswer)

        let afterSiblings = HallieTurnExecutor.preTranslation(
            question: "read their names", playAfterAnswer: false,
            memory: siblingMemory, isKnownPerson: { _ in false },
            rosterAnswer: { _ in self.rosterSentinel })
        guard case .translate = afterSiblings else {
            Issue.record("sibling pronoun should remain an ordinary follow-up, got \(afterSiblings)")
            return
        }

        var presenceMemory = HallieTurnExecutor.ConversationMemory()
        let presenceIntent = HallieTurnExecutor.Intent(
            originalQuestion: "show videos with Rick and Donna",
            ast: .presence(.init(people: ["Rick", "Donna"])))
        let presenceAnswer = HallieTurnExecutor.Result(
            route: .presence, outcome: .answered,
            prose: "I found one video.", basisLine: "Basis: catalog.",
            queryDescription: "shape=presence", citations: [
                .init(recordID: UUID(), fullPath: "/fixture/family.mov",
                      filename: "family.mov", playbackSeconds: nil, bases: []),
            ], catalogPersonName: nil, matchCount: 1)
        presenceMemory.record(intent: presenceIntent, result: presenceAnswer)

        for phrase in ["what are their names", "name them", "list their names"] {
            let afterPresence = HallieTurnExecutor.preTranslation(
                question: phrase, playAfterAnswer: false,
                memory: presenceMemory, isKnownPerson: { _ in false },
                rosterAnswer: { _ in self.rosterSentinel })
            guard case .translate = afterPresence else {
                Issue.record("\(phrase) should remain a presence/list follow-up, got \(afterPresence)")
                return
            }
        }
    }

    @Test func exactReadTheirNamesIsFreshOrMayRepeatAPriorRoster() {
        let fresh = HallieTurnExecutor.preTranslation(
            question: "read their names for me", playAfterAnswer: false,
            memory: .init(), isKnownPerson: { _ in false },
            rosterAnswer: { _ in self.rosterSentinel })
        guard case .answer(let freshAnswer) = fresh else {
            Issue.record("fresh exact phrase should be the catalog roster"); return
        }
        #expect(freshAnswer.prose == rosterSentinel.prose)

        var rosterMemory = HallieTurnExecutor.ConversationMemory()
        rosterMemory.record(
            intent: nil, result: rosterSentinel,
            question: "tell me about the people in the catalog")
        let repeated = HallieTurnExecutor.preTranslation(
            question: "read their names", playAfterAnswer: false,
            memory: rosterMemory, isKnownPerson: { _ in false },
            rosterAnswer: { _ in self.rosterSentinel })
        guard case .answer(let repeatedAnswer) = repeated else {
            Issue.record("exact phrase may repeat a prior roster"); return
        }
        #expect(repeatedAnswer.prose == rosterSentinel.prose)
    }

    @Test func rosterIsAnsweredBeforeTranslation() {
        let pre = HallieTurnExecutor.preTranslation(
            question: "tell me about the people in the catalog", playAfterAnswer: false,
            memory: .init(), isKnownPerson: { _ in false },
            rosterAnswer: { scope in
                Tab.rosterAnswer(profiles: [self.dad], graph: nil, cyberBrain: nil, scope: scope)
            })
        guard case .answer(let result) = pre else {
            Issue.record("expected a local answer, got \(pre)"); return
        }
        #expect(result.prose.hasPrefix("The People-tab catalog roster has 1 person: Dad"))
        #expect(result.offeredActions == [.openPeopleTab])
        // Without a roster closure (a client that doesn't supply one) the
        // question goes to the translator as before.
        let none = HallieTurnExecutor.preTranslation(
            question: "tell me about the people in the catalog", playAfterAnswer: false,
            memory: .init(), isKnownPerson: { _ in false })
        guard case .translate = none else { Issue.record("expected translate"); return }
    }

    private var rosterSentinel: HallieTurnExecutor.Result {
        Tab.rosterAnswer(profiles: [dad], graph: nil, cyberBrain: nil, scope: .catalog)
    }
}
