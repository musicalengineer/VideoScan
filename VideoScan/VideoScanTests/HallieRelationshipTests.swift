import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

/// Sensors for the 2026-08-18 fix: Hallie failed the softball "how am I
/// related to you?" (log evidence: translator emitted
/// `{"people":["you"],"operation":"kinship","relation":"sel…"}` and the strict
/// decoder rejected it). Three layers are pinned here — the wire contract
/// (`relationship` operation), pronoun binding (I/you → owner/archivist),
/// and the executor answer over a synthetic tree (no real family data —
/// 2026-08-03 privacy policy).
@MainActor
@Suite("Hallie relationship + pronoun binding", .serialized)
struct HallieRelationshipTests {

    // MARK: Fixture: Rick Breen → father Al → mother Grace → mother Hallie Mae

    /// Synthetic tree, Breen-shaped: Rick Breen's great-grandmother is
    /// "Hallie May McGill" (tree spelling differs from her display name
    /// "Hallie Mae" on purpose — that is Rick's real situation). Rick's wife
    /// Dawn Field; son Tim; uncle Bob → cousin Cara.
    private static let familyTree = """
    0 HEAD
    0 @I1@ INDI
    1 NAME Hallie May /McGill/
    1 SEX F
    1 BIRT
    2 DATE 1876
    1 DEAT
    2 DATE 1908
    1 FAMS @F1@
    0 @I2@ INDI
    1 NAME John /Latta/
    1 SEX M
    1 FAMS @F1@
    0 @I3@ INDI
    1 NAME Grace /Latta/
    1 SEX F
    1 FAMC @F1@
    1 FAMS @F2@
    0 @I4@ INDI
    1 NAME Peter /Breen/
    1 SEX M
    1 FAMS @F2@
    0 @I5@ INDI
    1 NAME Al /Breen/
    1 SEX M
    1 FAMC @F2@
    1 FAMS @F3@
    0 @I6@ INDI
    1 NAME Bob /Breen/
    1 SEX M
    1 FAMC @F2@
    1 FAMS @F4@
    0 @I7@ INDI
    1 NAME Mae /Lake/
    1 SEX F
    1 FAMS @F3@
    0 @I8@ INDI
    1 NAME Rick /Breen/
    1 SEX M
    1 FAMC @F3@
    1 FAMS @F5@
    0 @I9@ INDI
    1 NAME Dawn /Field/
    1 SEX F
    1 FAMS @F5@
    0 @I10@ INDI
    1 NAME Tim /Breen/
    1 SEX M
    1 FAMC @F5@
    0 @I11@ INDI
    1 NAME Cara /Breen/
    1 SEX F
    1 FAMC @F4@
    0 @I12@ INDI
    1 NAME Zed /Solo/
    1 SEX M
    0 @F1@ FAM
    1 HUSB @I2@
    1 WIFE @I1@
    1 CHIL @I3@
    0 @F2@ FAM
    1 HUSB @I4@
    1 WIFE @I3@
    1 CHIL @I5@
    1 CHIL @I6@
    0 @F3@ FAM
    1 HUSB @I5@
    1 WIFE @I7@
    1 CHIL @I8@
    0 @F4@ FAM
    1 HUSB @I6@
    1 CHIL @I11@
    0 @F5@ FAM
    1 HUSB @I8@
    1 WIFE @I9@
    1 CHIL @I10@
    0 TRLR
    """

    private var graph: GedcomFamilyGraph {
        GedcomFamilyGraph(gedcomText: Self.familyTree)
    }

    private let speakers = HallieTurnExecutor.Speakers(
        ownerName: "Rick Breen", archivistName: "Hallie Mae")

    private func relationship(_ a: String, _ b: String) -> HallieTurnExecutor.Intent {
        HallieTurnExecutor.Intent(
            originalQuestion: "how is \(a) related to \(b)?",
            ast: .graph(.init(people: [a, b], operation: .relationship)))
    }

    private func decode(_ json: String) throws -> ArchivistQueryAST.TranslatorDecoding {
        try ArchivistQueryAST.decodeTranslatorOutput(Data(json.utf8))
    }

    // MARK: 1. Wire contract

    @Test func strictDecoderAcceptsRelationshipWithExactlyTwoPeople() throws {
        let ast = try JSONDecoder().decode(
            ArchivistQueryAST.self,
            from: Data(#"{"shape":"graph","payload":{"people":["me","you"],"operation":"relationship"}}"#.utf8))
        #expect(ast == .graph(.init(people: ["me", "you"], operation: .relationship)))
        let encoded = try JSONEncoder().encode(ast)
        #expect(try JSONDecoder().decode(ArchivistQueryAST.self, from: encoded) == ast)
    }

    @Test(arguments: [
        #"{"shape":"graph","payload":{"people":["you"],"operation":"relationship"}}"#,
        #"{"shape":"graph","payload":{"people":["a","b","c"],"operation":"relationship"}}"#,
        #"{"shape":"graph","payload":{"people":[],"operation":"relationship"}}"#,
        // relation/side never accompany relationship
        #"{"shape":"graph","payload":{"people":["a","b"],"operation":"relationship","relation":"father"}}"#,
        #"{"shape":"graph","payload":{"people":["a","b"],"operation":"relationship","side":"maternal"}}"#,
    ])
    func strictDecoderRejectsWrongPeopleCountsAndExtras(json: String) {
        #expect(throws: DecodingError.self, Comment(rawValue: json)) {
            try JSONDecoder().decode(ArchivistQueryAST.self, from: Data(json.utf8))
        }
    }

    @Test func tolerantDecoderKeepsPronounsInPeople() throws {
        // "you" and "me" are stopwords for keyword search; as PEOPLE they
        // must survive (2026-08-18 log: people:["you"]).
        let decoded = try decode(
            #"{"shape":"graph","payload":{"people":["me","you"],"operation":"relationship"}}"#)
        #expect(decoded.ast == .graph(.init(people: ["me", "you"], operation: .relationship)))
        #expect(decoded.notes.isEmpty)
        let kinship = try decode(
            #"{"shape":"graph","payload":{"people":["me"],"operation":"kinship","relation":"father"}}"#)
        #expect(kinship.ast == .graph(.init(people: ["me"], operation: .kinship, relation: .father)))
    }

    @Test func tolerantDecoderRewritesKinshipSelfToRelationship() throws {
        // The live failure's shape, with both people present: kinship +
        // relation "self" means the symmetric question.
        let decoded = try decode(
            #"{"shape":"graph","payload":{"people":["me","you"],"operation":"kinship","relation":"self"}}"#)
        #expect(decoded.ast == .graph(.init(people: ["me", "you"], operation: .relationship)))
        #expect(decoded.notes.contains { $0.contains("relationship operation") })
        // With only ONE person the second party is never invented: still
        // rejected, with the clear "exactly two people" reason.
        #expect(throws: (any Error).self) {
            try decode(#"{"shape":"graph","payload":{"people":["you"],"operation":"kinship","relation":"self"}}"#)
        }
    }

    @Test func translatorPromptTeachesTheNewOperation() {
        let prompt = OllamaQueryTranslator.astSystemPrompt
        #expect(prompt.contains(#""how am I related to you?""#))
        #expect(prompt.contains(#"{"shape":"graph","payload":{"people":["me","you"],"operation":"relationship"}}"#))
        #expect(prompt.contains(#""how is Donna related to Thankful Pratt?""#))
        #expect(prompt.contains(#""what's Timmy to Hallie Mae?""#))
        #expect(prompt.contains(#""who is my father?""#))
    }

    // MARK: 2. Pronoun binding (pure)

    @Test func pronounsBindToOwnerAndArchivist() {
        let bound = HallieTurnExecutor.bindPronouns(
            ["me", "you"], speakers: speakers)
        #expect(bound.people == ["Rick Breen", "Hallie Mae"])
        #expect(bound.unbound.isEmpty)
        #expect(bound.bindings.map(\.note) == ["'me' = Rick Breen", "'you' = Hallie Mae"])
        #expect(bound.bindings.map(\.role) == [.owner, .archivist])

        for word in ["I", "my", "myself", "Mine", "me?"] {
            #expect(HallieTurnExecutor.bindPronouns([word], speakers: speakers).people == ["Rick Breen"], Comment(rawValue: word))
        }
        for word in ["you", "Your", "yourself", "hallie", "Hallie Mae", "the archivist"] {
            #expect(HallieTurnExecutor.bindPronouns([word], speakers: speakers).people == ["Hallie Mae"], Comment(rawValue: word))
        }
        // Real names pass through untouched, in place.
        let mixed = HallieTurnExecutor.bindPronouns(["donna", "my"], speakers: speakers)
        #expect(mixed.people == ["donna", "Rick Breen"])
        #expect(mixed.bindings.map(\.index) == [1])
    }

    @Test func unboundPronounIsReportedNotGuessed() {
        let noOwner = HallieTurnExecutor.Speakers(ownerName: "", archivistName: "Hallie Mae")
        let bound = HallieTurnExecutor.bindPronouns(["me", "you"], speakers: noOwner)
        #expect(bound.unbound == ["me"])
        #expect(bound.people == ["me", "Hallie Mae"])
        #expect(HallieTurnExecutor.bindPronouns(["you"], speakers: .none).unbound == ["you"])
    }

    @Test func archivistNameLadderEndsWithHerFirstName() {
        #expect(speakers.archivistNameLadder == ["Hallie Mae", "Hallie"])
        let pinned = HallieTurnExecutor.Speakers(
            ownerName: "Rick Breen", archivistName: "Hallie Mae",
            archivistPersonName: "Hallie May McGill")
        #expect(pinned.archivistNameLadder == ["Hallie May McGill", "Hallie Mae", "Hallie"])
    }

    // MARK: 3. The literal question, end to end (executor level)

    @Test func howAmIRelatedToYouAnswersGreatGrandmother() async throws {
        let context = HallieTurnExecutor.Context(
            profiles: [], graph: graph, cyberBrain: nil, speakers: speakers)
        let intent = HallieTurnExecutor.Intent(
            originalQuestion: "how am I related to you?",
            ast: .graph(.init(people: ["me", "you"], operation: .relationship)))
        let result = try await HallieTurnExecutor.execute(.init(intent: intent), context: context)

        #expect(result.route == .graph)
        #expect(result.outcome == .answered, Comment(rawValue: result.prose))
        #expect(result.prose.contains("great-grandmother"), Comment(rawValue: result.prose))
        // Hallie speaks as herself, to the owner.
        #expect(result.prose == "I am your great-grandmother — your father's mother's mother.")
        // The binding is visible evidence …
        #expect(result.basisLine.contains("'me' = Rick Breen"))
        #expect(result.basisLine.contains("'you' = Hallie Mae"))
        // … including the ladder rung that matched her tree spelling …
        #expect(result.basisLine.contains("'you' = Hallie Mae (as “Hallie” in the family tree)"))
        // … and the GEDCOM path with ids, so a wrong link is visible.
        #expect(result.basisLine.contains("Rick Breen (@I8@) → father Al Breen (@I5@) → mother Grace Latta (@I3@) → mother Hallie May McGill (@I1@)"))
        #expect(result.queryDescription == "shape=graph operation=relationship person=Rick Breen,Hallie")
        // Offers: her tree, and "tell me about" the other person.
        #expect(result.offeredActions.contains(.openFamilyTree(personName: "Rick Breen")))
        #expect(result.offeredActions.contains(.ask(question: "who is Hallie May McGill?", label: "tell me about Hallie May McGill")))
    }

    @Test func reversedDirectionSpeaksFromTheArchivist() async throws {
        let context = HallieTurnExecutor.Context(
            profiles: [], graph: graph, cyberBrain: nil, speakers: speakers)
        let intent = HallieTurnExecutor.Intent(
            originalQuestion: "how are you related to me?",
            ast: .graph(.init(people: ["you", "me"], operation: .relationship)))
        let result = try await HallieTurnExecutor.execute(.init(intent: intent), context: context)
        #expect(result.outcome == .answered, Comment(rawValue: result.prose))
        #expect(result.prose == "You are my great-grandson — my daughter's son's son.")
    }

    @Test func thirdPersonQuestionsUseNamesAndSexAwareWords() async throws {
        let context = HallieTurnExecutor.Context(
            profiles: [], graph: graph, cyberBrain: nil, speakers: speakers)
        let cousin = try await HallieTurnExecutor.execute(
            .init(intent: relationship("cara", "tim")), context: context)
        #expect(cousin.prose == "Tim Breen is Cara Breen's first cousin once removed — Cara Breen's father's mother's son's son's son.", Comment(rawValue: cousin.prose))
        let inLaw = try await HallieTurnExecutor.execute(
            .init(intent: relationship("dawn", "al")), context: context)
        #expect(inLaw.prose == "Al Breen is Dawn Field's father-in-law — Dawn Field's husband's father.", Comment(rawValue: inLaw.prose))
        let spouse = try await HallieTurnExecutor.execute(
            .init(intent: relationship("me", "dawn")), context: context)
        #expect(spouse.prose == "Dawn Field is your wife.", Comment(rawValue: spouse.prose))
    }

    @Test func noPathIsAnHonestDeclineWithBothNames() async throws {
        let context = HallieTurnExecutor.Context(
            profiles: [], graph: graph, cyberBrain: nil, speakers: speakers)
        let result = try await HallieTurnExecutor.execute(
            .init(intent: relationship("me", "zed")), context: context)
        #expect(result.outcome == .declined)
        #expect(result.prose.hasPrefix("I couldn't find a family-tree link between you and Zed Solo in the GEDCOM I have"), Comment(rawValue: result.prose))
        #expect(result.basisLine.contains("no path found"))
        #expect(result.offeredActions.contains(.ask(question: "who is Zed Solo?", label: "tell me about Zed Solo")))
    }

    @Test func unknownOwnerNameDeclinesInsteadOfGuessing() async throws {
        let strangers = HallieTurnExecutor.Speakers(ownerName: "Nobody Here", archivistName: "Hallie Mae")
        let context = HallieTurnExecutor.Context(
            profiles: [], graph: graph, cyberBrain: nil, speakers: strangers)
        let result = try await HallieTurnExecutor.execute(
            .init(intent: relationship("me", "you")), context: context)
        #expect(result.outcome == .declined)
        #expect(result.prose.contains("Nobody Here"), Comment(rawValue: result.prose))
        #expect(result.basisLine.contains("'me' = Nobody Here"))
    }

    @Test func missingOwnerSettingIsSaidOutLoud() async throws {
        let context = HallieTurnExecutor.Context(
            profiles: [], graph: graph, cyberBrain: nil, speakers: .none)
        let result = try await HallieTurnExecutor.execute(
            .init(intent: relationship("me", "you")), context: context)
        #expect(result.outcome == .declined)
        #expect(result.prose.contains("don't know who “me” is yet"), Comment(rawValue: result.prose))
    }

    // MARK: 4. Binding also fixes the one-directional routes

    @Test func whoIsMyFatherBindsMeToTheOwner() async throws {
        let context = HallieTurnExecutor.Context(
            profiles: [], graph: graph, cyberBrain: nil, speakers: speakers)
        let intent = HallieTurnExecutor.Intent(
            originalQuestion: "who is my father?",
            ast: .graph(.init(people: ["me"], operation: .kinship, relation: .father)))
        let result = try await HallieTurnExecutor.execute(.init(intent: intent), context: context)
        #expect(result.outcome == .answered, Comment(rawValue: result.prose))
        #expect(result.prose == "Rick Breen's father: Al Breen.")
        #expect(result.basisLine.hasPrefix("Basis: 'me' = Rick Breen; "))
    }

    @Test func tellMeAboutYourselfBindsYouToTheArchivistLadder() async throws {
        // Biography of "yourself" → "Hallie Mae" → the tree spells her
        // "Hallie May McGill": the name ladder lands on "Hallie", so the
        // biography route answers about HER, and the basis says how.
        let context = HallieTurnExecutor.Context(
            profiles: [], graph: graph, cyberBrain: nil, speakers: speakers)
        let intent = HallieTurnExecutor.Intent(
            originalQuestion: "tell me about yourself",
            ast: .graph(.init(people: ["yourself"], operation: .biography)))
        let result = try await HallieTurnExecutor.execute(.init(intent: intent), context: context)
        #expect(result.outcome == .answered, Comment(rawValue: result.prose))
        #expect(result.prose.contains("Hallie May McGill"), Comment(rawValue: result.prose))
        #expect(result.basisLine.contains("'yourself' = Hallie Mae (as “Hallie” in the family tree)"), Comment(rawValue: result.basisLine))
    }

    // MARK: 5. Clarification for an ambiguous slot keeps the other slot pinned

    @Test func ambiguousSecondPersonAsksAndContinuesWithFirstPinned() async throws {
        // Two GEDCOM people answer to "Rick" (Sr. and Jr.); "you" is unique.
        let tree = Self.familyTree.replacingOccurrences(
            of: "1 NAME Al /Breen/", with: "1 NAME Rick /Breen/ Sr")
        let graph = GedcomFamilyGraph(gedcomText: tree)
        let context = HallieTurnExecutor.Context(
            profiles: [], graph: graph, cyberBrain: nil, speakers: speakers)
        let first = try await HallieTurnExecutor.execute(
            .init(intent: relationship("you", "rick")), context: context)
        #expect(first.outcome == .needsClarification, Comment(rawValue: first.prose))
        let pending = try #require(first.clarification)
        #expect(pending.candidates.count == 2)
        let junior = try #require(pending.candidates.first { $0.id == .gedcomPersonID("@I8@") })
        let continued = try await HallieTurnExecutor.continue(
            pending: pending, selecting: junior.id, context: context)
        #expect(continued.outcome == .answered, Comment(rawValue: continued.prose))
        // "rick" was typed by name, so he is third person; "you" is her.
        #expect(continued.prose == "Rick Breen is my great-grandson — my daughter's son's son.")
        #expect(continued.basisLine.contains("'you' = Hallie Mae"))
    }

    // MARK: 6. Pure graph executor contract (typed names, no pronouns)

    @Test func graphExecutorAnswersRelationshipByTypedNames() {
        let inputs = ArchivistGraphInputs(graph: graph)
        let result = ArchivistGraphExecutor.execute(
            .init(people: ["rick", "hallie"], operation: .relationship), inputs: inputs)
        #expect(result.conclusion == .answered)
        #expect(result.prose == "Hallie May McGill is Rick Breen's great-grandmother — Rick Breen's father's mother's mother.")
        #expect(result.evidence?.kinshipPaths.first?.hops.map(\.person.id) == ["@I5@", "@I3@", "@I1@"])
        #expect(result.evidence?.counterpart?.id == "@I1@")
        #expect(result.familyTreeFocus == .person(name: "Rick Breen"))

        let same = ArchivistGraphExecutor.execute(
            .init(people: ["rick", "rick breen"], operation: .relationship), inputs: inputs)
        #expect(same.conclusion == .missingFact)
        #expect(same.prose.contains("same person"))

        let three = ArchivistGraphExecutor.execute(
            .init(people: ["a", "b", "c"], operation: .relationship), inputs: inputs)
        #expect(three.conclusion == .unsupportedPeopleCount(3))
        let withRelation = ArchivistGraphExecutor.execute(
            .init(people: ["a", "b"], operation: .relationship, relation: .father), inputs: inputs)
        #expect(withRelation.conclusion == .unexpectedRelation)
    }
}
