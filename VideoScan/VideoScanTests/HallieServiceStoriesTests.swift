import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

/// Family military-service stories (Rick 2026-09-23: "I'd like hallie to be
/// able to answer those family queries re: american war for independence,
/// the american civil war, world war 1 and world war 2 … hallie could say
/// 'would you like to hear more about X and how they served their country'
/// … then we tell a brief story about their service").
///
/// Synthetic family only — the shapes mirror Rick's three records (a US
/// Marine counted a WWII veteran, never in combat; a British Army soldier
/// with no details; a Confederate soldier at Fort Wagner by family
/// tradition) under invented names. Every CyberBrain and tree here is built
/// in memory; nothing reads Rick's real files (see `isolation`).
@MainActor
@Suite("Hallie family military-service stories", .serialized)
struct HallieServiceStoriesTests {

    // MARK: - Fixtures

    static let told = Date(timeIntervalSince1970: 1_790_000_000)

    static let haroldStory = "Harold Example served in the United States Marine Corps. He enlisted in time to be counted a World War II veteran — the official wartime service period ran through December 31, 1946. He was never in combat, but he served when the danger was real."
    static let seamusStory = "Seamus Oakes, Rick's great-grandfather, served in the British Army. The family doesn't yet know when he served or in which regiment."
    static let josiahStory = "According to Rick's uncle Barry Lark, Josiah Lark served in the Confederate army and fought at both battles of Fort Wagner on Morris Island, South Carolina, on July 11 and July 18, 1863. Both were Union defeats. The second is remembered for the courage of the 54th Massachusetts Infantry, which lost many men in the assault. The family has not yet found documents to confirm his service."
    static let loneStory = "Lone Example served in the United States Navy."

    /// Walter (a WWI draft registration) and Nathaniel (a Revolutionary War
    /// private) exist only when `military` is true; Abigail, born in 1750,
    /// never has a military fact — she must never be listed.
    static func tree(military: Bool = false) -> GedcomFamilyGraph {
        var text = """
        0 HEAD
        0 @R@ INDI
        1 NAME Rick /Example/
        1 SEX M
        1 FAMC @P@
        0 @D@ INDI
        1 NAME Harold /Example/
        1 SEX M
        1 BIRT
        2 DATE 22 FEB 1929
        1 FAMS @P@
        0 @M@ INDI
        1 NAME Edna /Example/
        1 SEX F
        1 FAMS @P@
        0 @S@ INDI
        1 NAME Seamus /Oakes/
        1 SEX M
        1 BIRT
        2 DATE 1878
        0 @J@ INDI
        1 NAME Josiah /Lark/
        1 SEX M
        1 BIRT
        2 DATE 1840
        0 @A@ INDI
        1 NAME Abigail /Example/
        1 SEX F
        1 BIRT
        2 DATE 1750
        0 @P@ FAM
        1 HUSB @D@
        1 WIFE @M@
        1 CHIL @R@

        """
        if military {
            text += """
            0 @N@ INDI
            1 NAME Nathaniel /Example/
            1 SEX M
            1 BIRT
            2 DATE 1741
            1 _MILT Private in Revolutionary War
            0 @W@ INDI
            1 NAME Walter /Example/
            1 SEX M
            1 BIRT
            2 DATE 1890
            1 EVEN
            2 TYPE Military Draft Registration
            2 DATE 1917-1918
            2 PLAC Ohio, United States

            """
        }
        return GedcomFamilyGraph(gedcomText: text + "0 TRLR\n")
    }

    /// `josiahSources`: the ORDER of the tradition item's sources (QA
    /// P2-2, 2026-09-24 — the teller listed first must not become the
    /// tradition's attribution).
    static func cyberBrain(withStories: Bool = true,
                           josiahSources: [String] = ["source.lark-tradition", "source.rick"]) throws -> CyberBrainIndex {
        func passage(_ id: String, _ text: String, _ person: String,
                     kind: CyberBrainItem.Kind = .biography) -> CyberBrainItem {
            CyberBrainItem(id: id, kind: kind, text: text, subjectPersonIDs: [person],
                           sourceIDs: ["source.rick"], confidence: .confirmed, privacy: .family,
                           createdAt: told, updatedAt: told)
        }
        func story(_ id: String, _ text: String, _ person: String, _ record: CyberBrainServiceRecord,
                   sources: [String] = ["source.rick"],
                   confidence: CyberBrainItem.Confidence = .confirmed) -> [CyberBrainItem] {
            guard withStories else { return [] }
            return [CyberBrainItem(id: id, kind: .event, text: text, subjectPersonIDs: [person],
                                   sourceIDs: sources, confidence: confidence, privacy: .family,
                                   createdAt: told, updatedAt: told, service: record)]
        }
        let archive = CyberBrainArchive(
            archiveID: "example-family", displayName: "Example",
            people: [
                CyberBrainPerson(
                    id: "person.harold", gedcomPersonID: "@I999999@",   // a pointer the tree does not know
                    canonicalName: "Harold Example", aliases: ["Grampa Example"],
                    biographyPassages: [
                        passage("bio.harold.typewriters", "Harold Example repaired typewriters for a living.", "person.harold"),
                        passage("bio.harold.marines", "Harold Example, Rick's father, served in the United States Marine Corps in the 1940s.", "person.harold"),
                    ],
                    lifeEvents: story("event.harold.service", haroldStory, "person.harold",
                                      CyberBrainServiceRecord(
                                        conflict: .worldWarII, force: "United States Marine Corps",
                                        serviceDates: .init(value: "1946-12-31", precision: .day, qualifier: .before,
                                                            displayText: "before the end of 1946"),
                                        combat: .no, basis: .confirmedByFamily))),
                CyberBrainPerson(
                    id: "person.seamus", gedcomPersonID: "@S@",
                    canonicalName: "Seamus Oakes", aliases: ["Shay Oakes"],
                    lifeEvents: story("event.seamus.service", seamusStory, "person.seamus",
                                      CyberBrainServiceRecord(conflict: nil, force: "British Army",
                                                              basis: .confirmedByFamily))),
                CyberBrainPerson(
                    id: "person.josiah", gedcomPersonID: "@J@",
                    canonicalName: "Josiah Lark",
                    lifeEvents: story("event.josiah.service", josiahStory, "person.josiah",
                                      CyberBrainServiceRecord(
                                        conflict: .civilWar, force: "Confederate States Army",
                                        engagements: [
                                            .init(name: "First Battle of Fort Wagner",
                                                  date: .init(value: "1863-07-11", precision: .day, qualifier: .exact, displayText: "July 11, 1863"),
                                                  place: "Morris Island, South Carolina"),
                                            .init(name: "Second Battle of Fort Wagner",
                                                  date: .init(value: "1863-07-18", precision: .day, qualifier: .exact, displayText: "July 18, 1863"),
                                                  place: "Morris Island, South Carolina"),
                                        ],
                                        combat: .yes, basis: .familyTradition),
                                      sources: josiahSources, confidence: .uncertain),
                    notes: [passage("note.josiah", "According to Barry Lark, Josiah was at Fort Wagner on the Confederate side.",
                                    "person.josiah", kind: .note)]),
                CyberBrainPerson(
                    id: "person.lone", canonicalName: "Lone Example",
                    lifeEvents: story("event.lone.service", loneStory, "person.lone",
                                      CyberBrainServiceRecord(conflict: nil, force: "United States Navy",
                                                              basis: .confirmedByFamily))),
                CyberBrainPerson(
                    id: "person.edna", gedcomPersonID: "@M@", canonicalName: "Edna Example",
                    biographyPassages: [passage("bio.edna.teacher", "Edna Example taught third grade for thirty years.", "person.edna")]),
                // A research note about Seamus's wife that mentions HIS
                // soldiering (the live Ellen Ronan note, 2026-09-23): she
                // must never be listed as having served.
                CyberBrainPerson(
                    id: "person.nora", canonicalName: "Nora Oakes",
                    notes: [passage("note.nora.marriage", "Research note for Nora Oakes.\nNora Oakes married Seamus Oakes on 7 February 1904 in Cork. Seamus was a bachelor of full age, a soldier residing at 41 Gerald Street. Her father was a labourer.", "person.nora", kind: .note)]),
            ],
            sources: [
                CyberBrainSource(id: "source.rick", type: .familyWitness,
                                 title: "Told by Rick Example", attribution: "Rick Example"),
                CyberBrainSource(id: "source.lark-tradition", type: .familyWitness,
                                 title: "Family oral tradition from Barry Lark", attribution: "Barry Lark",
                                 notes: "Unverified family oral tradition."),
            ])
        return try CyberBrainIndex(archive: archive)
    }

    func context(military: Bool = false, withStories: Bool = true) throws -> HallieTurnExecutor.Context {
        try .init(graph: Self.tree(military: military), cyberBrain: Self.cyberBrain(withStories: withStories),
                  speakers: .init(ownerName: "Rick Example", archivistName: nil))
    }

    /// The deterministic road a typed question takes: the typo front door,
    /// then pre-translation, then the executor. A question that escapes to
    /// the model translator fails the test.
    func ask(_ question: String, context: HallieTurnExecutor.Context) async throws -> HallieTurnExecutor.Result {
        let door = HallieFrontDoor.prepare(question) { HallieFrontDoor.isProtectedName($0, context: context) }
        let pre = HallieTurnExecutor.preTranslation(
            question: door.routingText, playAfterAnswer: false, memory: .init(),
            isKnownPerson: { HallieTurnExecutor.isKnownPerson($0, context: context) })
        guard case .run(let intent) = pre else {
            Issue.record("escaped deterministic routing: \(question) → \(door.routingText)")
            throw CancellationError()
        }
        return try await HallieTurnExecutor.execute(.init(intent: intent), context: context)
    }

    // MARK: - Routing

    @Test("family-wide asks name their war — every everyday name, and none")
    func familyAskDetection() {
        let cases: [(String, HallieServiceQuestion.War?)] = [
            ("who in our family served in the civil war", .civilWar),
            ("Who in the family fought in the War Between the States?", .civilWar),
            ("did anybody in the family fight for the confederacy", .civilWar),
            ("was anyone in the family in world war 2", .worldWarII),
            ("Was anyone in our family in WWII?", .worldWarII),
            ("were any of my relatives in the second world war", .worldWarII),
            ("did anyone in our family serve in the great war", .worldWarI),
            ("any family members serve in WW1?", .worldWarI),
            ("was anyone in the family in world war one", .worldWarI),
            ("anyone in the American Revolution", .americanRevolution),
            ("did any of our ancestors fight in the revolutionary war", .americanRevolution),
            ("was anyone in our family in the war for independence", .americanRevolution),
            ("did anyone in the family fight in the Revolution?", .americanRevolution),
            ("tell me about the family's military history", nil),
            ("who in the family served", nil),
            ("did anyone in the family serve in the military?", nil),
            ("who in our family was a veteran?", nil),
            ("which of us served", nil),
            ("was anyone in the family in the war", nil),
            // The 2026-09-11 shapes, kept verbatim (corpus fam-073 / fam-076).
            ("who served in the marines", nil),
            ("who was a marine", nil),
            ("who in the family was in the us marine corps?", nil),
        ]
        for (question, war) in cases {
            let ask = HallieServiceQuestion.familyAsk(question)
            #expect(ask != nil, "\(question)")
            #expect(ask?.war == war, "\(question) → \(String(describing: ask))")
        }
        #expect(HallieServiceQuestion.familyAsk("was anyone in the family in the Korean War")?.otherWar == "the Korean War")
    }

    @Test("not a family service ask: world history, a war as a date, media, other services, one person")
    func familyAskNegatives() {
        for question in [
            "tell me about the civil war", "who won world war 2", "when did world war II end",
            "who fought in the civil war",              // no family in it: general knowledge
            "who in the family was born during the civil war",
            "who in our family died after the war",
            "show me videos of the family at the civil war reenactment",
            "did anyone in the family go to the church service",
            "what branch of the family is donna from", "tell me about our family history",
            "tell me latta pronunciations",
            "did my dad serve in the marines",           // one person
            "tell me about the English civil war in our family",
        ] {
            #expect(HallieServiceQuestion.familyAsk(question) == nil, "\(question)")
        }
        #expect(HallieServiceQuestion.war(in: "the english civil war") == nil)
        #expect(HallieServiceQuestion.war(in: "world war i") == .worldWarI)
        #expect(HallieServiceQuestion.war(in: "world war ii") == .worldWarII)
    }

    @Test("one person's service: the subject, as typed")
    func personSubjects() {
        let cases: [(String, String)] = [
            ("did my dad serve", "my dad"),
            ("did my dad serve?", "my dad"),
            ("how did Josiah Lark serve his country", "Josiah Lark"),
            ("which side did Josiah Lark fight on?", "Josiah Lark"),
            ("was Josiah Lark in the civil war?", "Josiah Lark"),
            ("did Seamus Oakes serve in the British Army", "Seamus Oakes"),
            ("tell me about Josiah Lark's civil war service", "Josiah Lark"),
            ("tell me how Harold Example served his country", "Harold Example"),
        ]
        for (question, subject) in cases {
            #expect(HallieServiceQuestion.subject(in: question) == subject, "\(question)")
        }
        #expect(HallieServiceQuestion.subject(in: "did anyone serve in the civil war") == nil,
                "a family subject is the family-wide ask")
    }

    @Test("typos reach the same lanes through the front door")
    func typoFrontDoor() {
        let cases: [(String, String)] = [
            ("who in our famly servd in the civl war", "who in our family served in the civil war"),
            ("was anyone in the famliy in wolrd war 2", "was anyone in the family in world war 2"),
            ("anyone in the American Revolutoin", "anyone in the American Revolution"),
            // "familys" stays as typed (the possessive rule is for names);
            // the family-wide detector reads it as "family's".
            ("tell me about the familys militray history", "tell me about the familys military history"),
            ("who in the family fought in the Civl War", "who in the family fought in the Civil War"),
        ]
        for (typed, expected) in cases {
            let door = HallieFrontDoor.prepare(typed)
            #expect(door.routingText.lowercased() == expected.lowercased(), "\(typed) → \(door.routingText)")
            #expect(HallieServiceQuestion.familyAsk(door.routingText) != nil, "\(typed)")
        }
    }

    @Test("Rick's seven phrasings stay deterministic — never the translator")
    func corpusRouting() throws {
        let context = try context()
        let expectations: [(String, [String])] = [
            ("who in our family served in the civil war", []),
            ("was anyone in the family in world war 2", []),
            ("tell me about Josiah Lark", ["Josiah Lark"]),
            ("did my dad serve", ["my dad"]),
            ("what did Seamus Oakes do", ["Seamus Oakes"]),
            ("tell me about the family's military history", []),
            ("anyone in the American Revolution", []),
        ]
        for (question, people) in expectations {
            let pre = HallieTurnExecutor.preTranslation(
                question: question, playAfterAnswer: false, memory: .init(),
                isKnownPerson: { HallieTurnExecutor.isKnownPerson($0, context: context) })
            guard case .run(let intent) = pre, case .graph(let graph) = intent.ast else {
                Issue.record("not a graph intent: \(question) → \(pre)")
                continue
            }
            #expect(graph.operation == .biography, "\(question)")
            #expect(graph.people == people, "\(question) → \(graph.people)")
        }
    }

    @Test("the 2026-09-11 family-wide shapes still reach the service lane (corpus fam-073 / fam-076)")
    func legacyFamilyWideRouting() throws {
        let context = try context()
        for question in ["who served in the marines", "who was a marine",
                         "who in the family was in the us marine corps?"] {
            let door = HallieFrontDoor.prepare(question) { HallieFrontDoor.isProtectedName($0, context: context) }
            // The clients' full call (every oracle the shell and app pass).
            let pre = HallieTurnExecutor.preTranslationClassified(
                question: door.routingText, playAfterAnswer: false, memory: .init(),
                isKnownPerson: { HallieTurnExecutor.isKnownPerson($0, context: context) },
                isInnerCircleName: { HallieTurnExecutor.isInnerCircleName($0, context: context) },
                rosterAnswer: { HallieTurnExecutor.PeopleTab.rosterAnswer(context: context, scope: $0) },
                lineageAnswer: { HallieLineageAnswer.answer($0, context: context) },
                relationshipsOverview: { HallieRelationshipsOverview.answer($0, context: context) },
                researchAnswer: { HallieResearchQuestion.answer($0, context: context) },
                identity: HallieTurnExecutor.nameIdentity { context },
                isTreePersonID: { context.graph?.people[$0] != nil }).decision
            guard case .run(let intent) = pre, case .graph(let graph) = intent.ast else {
                Issue.record("not a graph intent: \(question) → \(door.routingText) → \(pre)")
                continue
            }
            #expect(graph.people.isEmpty, "\(question) → \(graph.people)")
        }
    }

    // MARK: - Composition

    @Test("did my dad serve: the brief story, then who told us — nothing else")
    func dadStory() async throws {
        let result = try await ask("did my dad serve", context: try context())
        #expect(result.route == .graph)
        #expect(result.outcome == .answered)
        #expect(result.prose == Self.haroldStory + " Rick Example told me this.")
        #expect(result.knowledgeCitations.map(\.id) == ["source.rick"])
        #expect(result.answerPlan?.shape == .fixed, "never re-phrased by the model")
        #expect(!result.prose.contains("typewriters"))
        #expect(!result.prose.contains("in the 1940s"), "the older passage is not repeated beside the story")
        #expect(result.queryDescription?.contains("topic=military-service") == true)
    }

    @Test("family tradition says so, and names who passed it down")
    func traditionStory() async throws {
        let result = try await ask("tell me about Josiah Lark's civil war service", context: try context())
        #expect(result.outcome == .answered)
        #expect(result.prose == Self.josiahStory + " That's family tradition, from Barry Lark; no document confirms it yet.")
        #expect(result.knowledgeCitations.map(\.id) == ["source.lark-tradition", "source.rick"])
        #expect(!result.prose.contains("was at Fort Wagner on the Confederate side"), "the older note is not quoted beside the story")
    }

    @Test("details unknown stay unknown")
    func unknownDetailsStory() async throws {
        let result = try await ask("did Seamus Oakes serve in the British Army", context: try context())
        #expect(result.prose == Self.seamusStory + " Rick Example told me this.")
    }

    @Test("the one-line summaries use only the record's fields")
    func summaryLines() throws {
        let index = try Self.cyberBrain()
        func line(_ id: String) throws -> String {
            let person = try #require(index.person(id: id))
            let record = try #require(index.serviceItems(for: id, privacyCeiling: .family).first?.service)
            return HallieServiceStory.summaryLine(name: person.canonicalName, record: record)
        }
        #expect(try line("person.harold") == "Harold Example served in the United States Marine Corps (World War II; before the end of 1946; never in combat).")
        #expect(try line("person.josiah") == "Josiah Lark fought with the Confederate States Army at the First Battle of Fort Wagner and the Second Battle of Fort Wagner (the Civil War; family tradition).")
        #expect(try line("person.seamus") == "Seamus Oakes served in the British Army (the details aren't known yet).")
    }

    // MARK: - The offer

    @Test("a biography ends by offering the story, which is not in the biography")
    func biographyOffer() async throws {
        let context = try context()
        let offers: [(String, String)] = [
            ("tell me about Harold Example", "Would you like to hear how Harold Example served his country?"),
            ("tell me about Josiah Lark", "Would you like to hear the family story of Josiah Lark's service in the Civil War?"),
            ("tell me about Seamus Oakes", "Would you like to hear about Seamus Oakes' service in the British Army?"),
        ]
        for (question, offer) in offers {
            let result = try await ask(question, context: context)
            #expect(result.outcome == .answered, "\(question)")
            #expect(result.prose.hasSuffix(" " + offer), "\(question): \(result.prose)")
            let clarification = try #require(result.clarification, "\(question)")
            #expect(clarification.stage == .serviceOffer)
            #expect(clarification.candidates.count == 1)
            #expect(result.answerPlan?.trailingOffer == " " + offer, "the offer survives composition")
            #expect(result.answerPlan?.fallbackText.hasSuffix(offer) == true)
            #expect(result.needsNoChoice, "the photo / kind word still belong to this biography")
        }
        let harold = try await ask("tell me about Harold Example", context: context)
        #expect(!harold.prose.contains("the danger was real"), "the story waits for yes")
        #expect(harold.prose.contains("typewriters"))
    }

    @Test("yes tells the story; no closes the offer")
    func offerYesAndNo() async throws {
        let context = try context()
        let biography = try await ask("tell me about Harold Example", context: context)
        let pending = try #require(biography.clarification)
        for reply in ["yes", "Yes!", "sure", "ok", "yes please", "I'd like that", "go ahead", "tell me"] {
            guard case .selected(let id) = HallieTurnExecutor.clarificationReply(reply, from: pending.candidates) else {
                Issue.record("\(reply) did not take the offer")
                continue
            }
            #expect(id == .cyberBrainPersonID("person.harold"))
        }
        let story = try await HallieTurnExecutor.continue(
            pending: pending, selecting: .cyberBrainPersonID("person.harold"), context: context)
        #expect(story.outcome == .answered)
        #expect(story.prose == Self.haroldStory + " Rick Example told me this.")
        #expect(story.clarification == nil)
        #expect(HallieClarificationDecline.matches("no thanks"))
        #expect(HallieClarificationDecline.reply(for: .serviceOffer) == "Okay.")
        #expect(HallieTurnExecutor.ClarificationStage.serviceOffer.isOffer)
        #expect(!HallieTurnExecutor.ClarificationStage.gedcomPerson.isOffer)
    }

    @Test("a person whose only knowledge is the story hears it as the biography — no offer")
    func storyIsTheBiography() async throws {
        let result = try await ask("tell me about Lone Example", context: try context())
        #expect(result.outcome == .answered)
        #expect(result.prose.contains(Self.loneStory))
        #expect(result.clarification == nil)
        #expect(result.answerPlan?.trailingOffer == nil)
    }

    @Test("no story, no offer: an ordinary biography is untouched")
    func noStoryNoOffer() async throws {
        let result = try await ask("tell me about Edna Example", context: try context())
        #expect(result.outcome == .answered)
        #expect(result.clarification == nil)
        #expect(!result.prose.contains("Would you like"))
    }

    @Test("a model-phrased biography still ends with the offer (plan → phrase → verify)")
    func offerSurvivesComposition() async throws {
        let result = try await ask("tell me about Harold Example", context: try context())
        let plan = HallieAnswerPlan.derive(from: result)
        #expect(plan.isComposable)
        let reply = plan.claims.map { "\($0.text) [\($0.id)]" }.joined(separator: " ")
        let outcome = await HallieGroundedComposer(personaName: "Hallie Mae") { _, _ in reply }
            .compose(plan: plan, history: [])
        let phrased = result.applying(outcome)
        #expect(phrased.prose.hasSuffix("Would you like to hear how Harold Example served his country?"),
                "\(outcome.note): \(phrased.prose)")
        #expect(phrased.clarification?.stage == .serviceOffer)
    }

    @Test("a provenance note on an offered answer goes in BEFORE the offer")
    func provenanceBeforeOffer() async throws {
        let result = try await ask("tell me about Harold Example", context: try context())
        let noted = result.carryingProvenance(" (taking Grampa as Harold Example)")
        #expect(noted.prose.hasSuffix("(taking Grampa as Harold Example) Would you like to hear how Harold Example served his country?"))
        #expect(noted.answerPlan?.fallbackText.hasSuffix("served his country?") == true)
    }

    @Test("kind words still apply to the biography and land before the offer")
    func kindWordBeforeOffer() async throws {
        let context = try context()
        let result = try await ask("tell me about Harold Example", context: context)
        let uuid = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let book = HallieKindWordsBook(people: [uuid: .init(display: "Harold", lines: ["Harold could fix anything with a screwdriver."])])
        let profile = HallieTurnExecutor.ProfileSnapshot(
            stableID: uuid.uuidString, canonicalName: "Harold Example", aliases: [], uuid: uuid)
        let ast = ArchivistQueryAST.graph(.init(people: ["Harold Example"], operation: .biography))
        #expect(HallieKindWords.isBiographyAnswer(result, ast: ast))
        let offer = try #require(HallieKindWords.biographyOffer(
            result: result, ast: ast, profiles: [profile], graph: context.graph, loadBook: { book }))
        #expect(!offer.anchor.contains("Would you like"))
        let with = result.insertingKindWord(offer.lines[0], after: offer.anchor)
        #expect(with.prose.hasSuffix("Harold could fix anything with a screwdriver. Would you like to hear how Harold Example served his country?"))
    }

    // MARK: - The whole family, by war

    @Test("who served in the Civil War: the one-line summary and a yes/no offer")
    func civilWarAsk() async throws {
        let result = try await ask("who in our family served in the civil war", context: try context())
        #expect(result.outcome == .answered)
        #expect(result.prose == "The family has told me about one person who served in the Civil War: Josiah Lark fought with the Confederate States Army at the First Battle of Fort Wagner and the Second Battle of Fort Wagner (the Civil War; family tradition). Would you like to hear his story?")
        #expect(result.clarification?.stage == .serviceOffer)
        #expect(result.clarification?.candidates.map(\.id) == [.cyberBrainPersonID("person.josiah")])
        #expect(!result.prose.contains("Harold"))
    }

    @Test("World War II lists only World War II")
    func worldWarTwoAsk() async throws {
        let result = try await ask("was anyone in the family in world war 2", context: try context())
        #expect(result.prose.hasPrefix("The family has told me about one person who served in World War II: Harold Example served in the United States Marine Corps"))
        #expect(!result.prose.contains("Josiah"))
        #expect(!result.prose.contains("Seamus"))
    }

    @Test("the family's military history: everyone, and a pick of whose story")
    func militaryHistoryAsk() async throws {
        let result = try await ask("tell me about the family's military history", context: try context())
        #expect(result.outcome == .answered)
        for name in ["Harold Example", "Josiah Lark", "Seamus Oakes", "Lone Example"] {
            #expect(result.prose.contains(name), "\(name): \(result.prose)")
        }
        #expect(!result.prose.contains("Edna"))
        #expect(result.prose.hasSuffix("Whose story would you like to hear?"))
        #expect(result.clarification?.candidates.count == 4)
    }

    @Test("a branch filters: 'who served in the marines' lists the Marine Corps only")
    func branchFilter() async throws {
        let context = try context()
        let marines = try await ask("who served in the marines", context: context)
        #expect(marines.prose.hasPrefix("The family has told me about one person who served in the Marine Corps: Harold Example served in the United States Marine Corps"), "\(marines.prose)")
        #expect(!marines.prose.contains("Seamus"))
        #expect(!marines.prose.contains("Josiah"))
        #expect(marines.queryDescription?.contains("branch=marines") == true)
        let british = try await ask("did anyone in the family serve in the British Army", context: context)
        #expect(british.prose.contains("Seamus Oakes served in the British Army"))
        #expect(!british.prose.contains("Harold"))
        let navyNone = try await ask("did anyone in the family serve in the coast guard", context: context)
        #expect(navyNone.outcome == .declined)
        #expect(navyNone.prose.hasPrefix("Nobody in the family has told me about service in the Coast Guard, and the family tree I have records none."))
    }

    @Test("a passage that mentions SOMEONE ELSE's service never lists its subject")
    func otherPersonsServiceNotListed() async throws {
        let result = try await ask("tell me about the family's military history", context: try context())
        #expect(!result.prose.contains("Nora"), "\(result.prose)")
        let index = try Self.cyberBrain()
        let nora = try #require(index.person(id: "person.nora"))
        #expect(HallieTurnExecutor.ServiceAnswer.servicePassages(for: nora, index: index).isEmpty)
        let harold = try #require(index.person(id: "person.harold"))
        #expect(HallieTurnExecutor.ServiceAnswer.serviceSentences(
            in: "Harold Example, Rick's father, served in the United States Marine Corps in the 1940s.", about: harold).count == 1)
        #expect(HallieTurnExecutor.ServiceAnswer.serviceSentences(
            in: "He enlisted in 1946.", about: harold).count == 1, "a sentence-initial pronoun counts")
    }

    @Test("no record for the Revolution or WWI: said plainly, the stories we DO have named, an invitation")
    func noRecordHonesty() async throws {
        let context = try context()
        for (question, war) in [("anyone in the American Revolution", "the American Revolution"),
                                ("was anyone in the family in world war 1", "World War I")] {
            let result = try await ask(question, context: context)
            #expect(result.outcome == .declined, "\(question)")
            #expect(result.prose.hasPrefix("Nobody in the family has told me about service in \(war), and the family tree I have records no military service from those years."), "\(result.prose)")
            #expect(result.prose.contains("I do have family stories from the Civil War and World War II"))
            #expect(result.prose.contains("say “let me tell you about” and their name"))
            #expect(!result.prose.contains("Abigail"), "a birth year is never service")
        }
        let korea = try await ask("was anyone in the family in the Korean War", context: context)
        #expect(korea.prose.hasPrefix("Nobody in the family has told me about service in the Korean War"))
    }

    // MARK: - Facts the family tree records

    @Test("the tree's own military facts: listed under their war by their words or date, cited, never a birth year")
    func treeFacts() async throws {
        let context = try context(military: true)
        let revolution = try await ask("anyone in the American Revolution", context: context)
        #expect(revolution.outcome == .answered)
        #expect(revolution.prose == "The family tree records a military fact tied to the American Revolution by its own words or date for one person: Nathaniel Example (b. 1741) — “Private in Revolutionary War”.")
        #expect(revolution.knowledgeCitations.map(\.id) == [HallieTurnExecutor.ServiceAnswer.treeCitationID])
        #expect(!revolution.prose.contains("Abigail"))

        let wwi = try await ask("was anyone in the family in world war 1", context: context)
        #expect(wwi.prose.contains("Walter Example (b. 1890) — a military draft registration dated 1917-1918 in Ohio, United States"))
        #expect(!wwi.prose.contains("Walter Example served"), "a registration is not service")

        let one = try await ask("did Nathaniel Example serve", context: context)
        #expect(one.outcome == .answered)
        #expect(one.prose == "The family tree records “Private in Revolutionary War” for Nathaniel Example.")
        #expect(one.knowledgeCitations.map(\.id) == ["gedcom:@N@"])
    }

    @Test("a war named in a tree note must be possible by date — England's Civil War is not America's")
    func treeWarSanity() {
        typealias Fact = GedcomFamilyGraph.MilitaryFact
        let english = Fact(tag: "_MILT", value: "He was prominent in the Eastern Association during the Civil War")
        #expect(HallieServiceStory.war(of: english, birthYear: 1480) == nil, "born 1480: not the American Civil War")
        #expect(HallieServiceStory.war(of: english, birthYear: 1840) == .civilWar)
        #expect(HallieServiceStory.war(of: english) == .civilWar, "no dates at all: the words stand")
        let dated = Fact(tag: "_MILT", value: "Civil War service", date: "1643")
        #expect(HallieServiceStory.war(of: dated, birthYear: 1840) == nil, "the fact's own date rules")
        #expect(HallieServiceStory.war(of: Fact(tag: "_MILT", date: "6 July 1780")) == .americanRevolution)
        #expect(HallieServiceStory.war(of: Fact(tag: "_MILT", date: "1790")) == nil)
        let long = String(repeating: "a long FamilySearch note ", count: 20)
        let phrase = HallieServiceStory.phrase(Fact(tag: "_MILT", value: long))
        #expect(phrase.count < 170)
        #expect(phrase.hasSuffix("…”"))
    }

    @Test("the front door never splits a proper adjective against a tree given name")
    func properAdjectivesSurviveTheFrontDoor() {
        // Rick's 20-generation pull has a given name "Ameri": "American" was
        // read as "Ameri can" and the Revolution question went to the model.
        let door = HallieFrontDoor.prepare("anyone in the American Revolution") { $0 == "Ameri" || $0 == "Brit" }
        #expect(door.routingText == "anyone in the American Revolution")
        #expect(HallieFrontDoor.prepare("who served in the British Army") { $0 == "Brit" }.routingText
                == "who served in the British Army")
    }

    // MARK: - QA findings (2026-09-24)

    /// P2-1: the 2026-09-23 family-wide shapes took any family word plus a
    /// bare "fight"/"served in the"/"navy" as a service ask — ahead of the
    /// person-fact and lineage lanes.
    @Test("a family word plus fight / served in / a branch word is not enough on its own")
    func familyAskNeedsAMilitaryNoun() {
        for question in [
            "who in the family fought cancer",
            "did anyone in the family fight cancer",
            "why did my grandparents fight so much",
            "who in the family served in the peace corps",
            "which relatives worked at the navy yard",
            "did anyone in the family fight with their siblings",
            "who in our family served in the church choir",
        ] {
            #expect(HallieServiceQuestion.familyAsk(question) == nil, "\(question)")
        }
        for question in [
            "who in the family served in the military",
            "did anyone fight in WWII",
            "who was in the navy",
            "did anyone in the family fight in the army",
            "who in our family fought with the marines",
            "did any of my relatives serve in the navy",
            "was anyone in the family drafted",
            "any veterans in the family",
        ] {
            #expect(HallieServiceQuestion.familyAsk(question) != nil, "\(question)")
        }
    }

    /// P2-2: the tradition's source line came from `sourceIDs.first`; with
    /// the teller listed first it named the teller as the tradition.
    @Test("a tradition's source line names the tradition's source whatever the order")
    func traditionSourceOrder() async throws {
        let context = try HallieTurnExecutor.Context(
            graph: Self.tree(),
            cyberBrain: Self.cyberBrain(josiahSources: ["source.rick", "source.lark-tradition"]),
            speakers: .init(ownerName: "Rick Example", archivistName: nil))
        let result = try await ask("did Josiah Lark serve", context: context)
        #expect(result.prose.contains("That's family tradition, from Barry Lark;"), "\(result.prose)")
        #expect(!result.prose.contains("from Rick Example"))
    }

    @Test("an engagement's article: 'the' before a battle, none before a bare place")
    func engagementArticles() {
        func line(_ names: [String]) -> String {
            HallieServiceStory.summaryLine(name: "Josiah Lark", record: CyberBrainServiceRecord(
                conflict: .civilWar, force: "Confederate States Army",
                engagements: names.map { .init(name: $0) }, combat: .yes, basis: .familyTradition))
        }
        #expect(line(["Fort Wagner"]).hasPrefix("Josiah Lark fought with the Confederate States Army at Fort Wagner ("))
        #expect(line(["Fort Wagner", "Gettysburg"]).hasPrefix("Josiah Lark fought with the Confederate States Army at Fort Wagner and Gettysburg ("))
        #expect(line(["Battle of Gettysburg"]).hasPrefix("Josiah Lark fought with the Confederate States Army at the Battle of Gettysburg ("))
        #expect(line(["First Battle of Fort Wagner", "Siege of Petersburg"]).hasPrefix(
            "Josiah Lark fought with the Confederate States Army at the First Battle of Fort Wagner and the Siege of Petersburg ("))
        #expect(line(["the Battle of the Crater"]).hasPrefix("Josiah Lark fought with the Confederate States Army at the Battle of the Crater ("))
    }

    @Test("with no family tree loaded, Hallie never says the tree records none")
    func noTreeNoTreeClaim() async throws {
        let context = try HallieTurnExecutor.Context(
            graph: nil, cyberBrain: Self.cyberBrain(),
            speakers: .init(ownerName: "Rick Example", archivistName: nil))
        let edna = try await ask("did Edna Example serve", context: context)
        #expect(edna.outcome == .declined)
        #expect(!edna.prose.contains("family tree"), "\(edna.prose)")
        #expect(!edna.basisLine.contains("family tree"), "\(edna.basisLine)")
        let coast = try await ask("did anyone in the family serve in the coast guard", context: context)
        #expect(coast.outcome == .declined)
        #expect(coast.prose.hasPrefix("Nobody in the family has told me about service in the Coast Guard."), "\(coast.prose)")
        #expect(!coast.prose.contains("family tree"), "\(coast.prose)")
        let none = try await ask("was anyone in the family in world war 1", context: context)
        #expect(!none.prose.contains("family tree"), "\(none.prose)")
        // With a tree, the tree WAS checked and says so.
        let withTree = try await ask("did Edna Example serve", context: try self.context())
        #expect(withTree.prose.contains("the family tree records none"), "\(withTree.prose)")
    }

    @Test("one story among several listed people: the offer names whose story")
    func offerNamesThePersonInAList() async throws {
        let tree = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @J@ INDI
        1 NAME Josiah /Lark/
        1 SEX M
        1 BIRT
        2 DATE 1840
        0 @C@ INDI
        1 NAME Caleb /Example/
        1 SEX M
        1 BIRT
        2 DATE 1835
        1 _MILT Private in Civil War
        0 TRLR

        """)
        let context = try HallieTurnExecutor.Context(
            graph: tree, cyberBrain: Self.cyberBrain(),
            speakers: .init(ownerName: "Rick Example", archivistName: nil))
        let result = try await ask("who in our family served in the civil war", context: context)
        #expect(result.prose.contains("Caleb Example"), "\(result.prose)")
        #expect(result.prose.hasSuffix("Would you like to hear Josiah Lark's story?"), "\(result.prose)")
        #expect(result.clarification?.candidates.map(\.id) == [.cyberBrainPersonID("person.josiah")])
    }

    // MARK: - Isolation and scale

    /// POISONED STATE: this machine may hold Rick's real CyberBrain, which
    /// has a Marine Corps story. The executor must answer from the injected
    /// index ONLY — with no stories injected, nothing about the Marines.
    @Test("isolation: answers come only from the injected CyberBrain and tree")
    func isolation() async throws {
        let context = try context(withStories: false)
        let result = try await ask("was anyone in the family in world war 2", context: context)
        #expect(!result.prose.contains("Harold Example served"))
        #expect(!result.prose.contains("Richard"))
        let biography = try await ask("tell me about Seamus Oakes", context: context)
        #expect(biography.clarification == nil, "no story, no offer")
    }

    /// SCALE: a 100,000-person tree, 1% with military facts. The family-wide
    /// ask walks it once and caps what it lists.
    @Test("scale: a family-wide ask over 100k tree people stays fast and bounded")
    func scale() async throws {
        var text = "0 HEAD\n"
        text.reserveCapacity(100_000 * 60)
        for i in 0..<100_000 {
            text += "0 @I\(i)@ INDI\n1 NAME Person\(i) /Scale/\n1 BIRT\n2 DATE \(1700 + i % 300)\n"
            if i % 100 == 0 { text += "1 _MILT\n2 DATE 4 JUL \(1775 + i % 9)\n" }
        }
        let graph = GedcomFamilyGraph(gedcomText: text + "0 TRLR\n")
        let context = try HallieTurnExecutor.Context(
            graph: graph, cyberBrain: Self.cyberBrain(),
            speakers: .init(ownerName: "Rick Example", archivistName: nil))
        // Production loads the tree with its index precompiled; warm the
        // lazy one here so the budget measures the ask, not the build.
        _ = try await ask("anyone in the American Revolution", context: context)
        let started = Date()
        let result = try await ask("anyone in the American Revolution", context: context)
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 2.0, "family-wide ask took \(elapsed)s (Debug budget 2 s)")
        #expect(result.prose.contains("military facts tied to the American Revolution by its own words or date for 1000 people, including:"))
        #expect(result.prose.components(separatedBy: " — ").count - 1 == HallieTurnExecutor.ServiceAnswer.maximumListed)
    }
}
