import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

/// Military-service questions (Rick 2026-09-11: "I'd like Hallie to mention
/// my dad's Marine Corps service in the 1940s"). Live replay that day: 0 of
/// 8 phrasings answered — the resolved father was declined "one person at
/// a time", bare "dad" became Dafydd ab Einion, "marine corps" became a
/// surname, and a named ask answered with birth and death.
@MainActor
@Suite("Hallie military-service questions", .serialized)
struct HallieServiceQuestionTests {

    private func tree() -> GedcomFamilyGraph {
        GedcomFamilyGraph(gedcomText: """
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
        2 PLAC Boston, Massachusetts
        1 FAMS @P@
        0 @M@ INDI
        1 NAME Edna /Example/
        1 SEX F
        1 FAMS @P@
        0 @P@ FAM
        1 HUSB @D@
        1 WIFE @M@
        1 CHIL @R@
        0 TRLR
        """)
    }

    /// The father's CyberBrain record carries a GEDCOM pointer the tree does
    /// NOT know — the live archive's Ancestry pointers against the merged
    /// FamilySearch tree — so the bridge must be by name.
    private func cyberBrain() throws -> CyberBrainIndex {
        let told = Date(timeIntervalSince1970: 1_789_000_000)
        func item(_ id: String, _ text: String, subject: String) -> CyberBrainItem {
            CyberBrainItem(id: id, kind: .biography, text: text,
                           subjectPersonIDs: [subject], sourceIDs: ["source.rick"],
                           confidence: .confirmed, privacy: .family,
                           createdAt: told, updatedAt: told)
        }
        let archive = CyberBrainArchive(
            archiveID: "example-family", displayName: "Example",
            people: [
                CyberBrainPerson(
                    id: "person.harold", gedcomPersonID: "@I999999@",
                    canonicalName: "Harold Example", aliases: ["Grampa Example"],
                    biographyPassages: [
                        item("bio.harold.typewriters", "Harold Example repaired typewriters for a living.", subject: "person.harold"),
                        item("bio.harold.marines", "Harold Example, Rick's father, served in the United States Marine Corps in the 1940s.", subject: "person.harold"),
                    ]),
                CyberBrainPerson(
                    id: "person.edna", gedcomPersonID: "@M@",
                    canonicalName: "Edna Example", aliases: [],
                    biographyPassages: [
                        item("bio.edna.teacher", "Edna Example taught third grade for thirty years.", subject: "person.edna"),
                    ]),
            ],
            sources: [
                CyberBrainSource(id: "source.rick", type: .firstPerson,
                                 title: "Told by Rick Example", attribution: "Rick Example"),
            ])
        return try CyberBrainIndex(archive: archive)
    }

    private func context() throws -> HallieTurnExecutor.Context {
        try .init(graph: tree(), cyberBrain: cyberBrain(),
                  speakers: .init(ownerName: "Rick Example", archivistName: nil))
    }

    private func ask(_ question: String, context: HallieTurnExecutor.Context) async throws -> HallieTurnExecutor.Result {
        let pre = HallieTurnExecutor.preTranslation(
            question: question, playAfterAnswer: false, memory: .init(),
            isKnownPerson: { HallieTurnExecutor.isKnownPerson($0, context: context) })
        guard case .run(let intent) = pre else {
            Issue.record("service question escaped deterministic routing: \(question)")
            throw NSError(domain: "HallieServiceQuestionTests", code: 1)
        }
        return try await HallieTurnExecutor.execute(.init(intent: intent), context: context)
    }

    @Test("the shape and its subject, across the phrasings Rick used")
    func detection() {
        let cases: [(String, String)] = [
            ("did my dad serve in the marines?", "my dad"),
            ("was my father in the military?", "my father"),
            ("tell me about my dad's military service", "my dad"),
            ("what branch of the service was dad in?", "dad"),
            ("was grampa breen a marine?", "grampa breen"),
            ("when was dad in the marines?", "dad"),
            ("tell me about richard breen sr's time in the marine corps", "richard breen sr"),
            ("Did Dad fight in WWII?", "Dad"),
            ("where was my father stationed?", "my father"),
            ("what did dad do in the war?", "dad"),
            ("is my dad a veteran?", "my dad"),
        ]
        for (question, subject) in cases {
            #expect(HallieServiceQuestion.subject(in: question) == subject, "\(question)")
        }
        for question in ["did my dad serve dinner at the wedding?", "tell me about my dad",
                         "was my father in the kitchen?", "what branch of the family is donna from?",
                         "when was dad born?"] {
            #expect(HallieServiceQuestion.subject(in: question) == nil, "\(question)")
            #expect(!HallieServiceQuestion.isFamilyWideAsk(question), "\(question)")
        }
        #expect(HallieServiceQuestion.isFamilyWideAsk("who in the family served in the marine corps?"))
        #expect(HallieServiceQuestion.isFamilyWideAsk("did anyone in the family serve in the military?"))
        #expect(HallieServiceQuestion.isFamilyWideAsk("who in our family was a veteran?"))
        #expect(HallieServiceQuestion.mentionsService("He served in the United States Marine Corps in the 1940s."))
        #expect(!HallieServiceQuestion.mentionsService("Edward was warm and always had a reward ready."))
    }

    @Test("a possessive relative: the passage, quoted and attributed — never 'one person at a time'")
    func possessiveFather() async throws {
        let context = try context()
        for question in ["did my dad serve in the marines?", "was my father in the military?",
                         "tell me about my dad's military service"] {
            let result = try await ask(question, context: context)
            #expect(result.route == .graph, "\(question)")
            #expect(result.outcome == .answered, "\(question)")
            #expect(result.prose.contains("Marine Corps"), "\(question): \(result.prose)")
            #expect(result.prose.contains("Rick Example told me"), "\(question): \(result.prose)")
            #expect(!result.prose.contains("one person at a time"))
            #expect(!result.prose.contains("1929"), "not the tree biography: \(result.prose)")
            #expect(result.knowledgeCitations.map(\.id) == ["source.rick"])
            #expect(result.answerPlan?.shape == .fixed)
        }
    }

    @Test("a bare kin word follows the tree to the owner's father, then bridges to CyberBrain by NAME")
    func bareKinWord() async throws {
        let context = try context()
        for question in ["what branch of the service was dad in?", "when was dad in the marines?"] {
            let result = try await ask(question, context: context)
            #expect(result.outcome == .answered, "\(question)")
            #expect(result.prose.contains("Marine Corps"), "\(question): \(result.prose)")
            #expect(result.prose.contains("1940s"), "\(question): \(result.prose)")
            #expect(result.basisLine.contains("Resolved relative"), "\(question): \(result.basisLine)")
        }
    }

    @Test("a typed name or a CyberBrain alias goes straight to the passage")
    func namedSubject() async throws {
        let context = try context()
        for question in ["tell me about harold example's time in the marine corps",
                         "was grampa example a marine?"] {
            let result = try await ask(question, context: context)
            #expect(result.outcome == .answered, "\(question)")
            #expect(result.prose.contains("Marine Corps"), "\(question): \(result.prose)")
            #expect(result.queryDescription?.contains("topic=military-service") == true)
        }
    }

    @Test("no service passage: an honest decline that names the person, not the tree biography")
    func nothingRecorded() async throws {
        let context = try context()
        let result = try await ask("did my mom serve in the military?", context: context)
        #expect(result.route == .graph)
        #expect(result.outcome == .declined)
        #expect(result.prose.contains("Edna Example's military service"), "\(result.prose)")
        #expect(result.prose.contains("let me tell you about"))
        #expect(!result.prose.contains("Marine"))
    }

    @Test("the whole family: everyone with a service passage, nobody without one")
    func familyWide() async throws {
        let context = try context()
        let result = try await ask("who in the family served in the marine corps?", context: context)
        #expect(result.outcome == .answered)
        #expect(result.prose.contains("Harold Example"), "\(result.prose)")
        #expect(!result.prose.contains("Edna"), "\(result.prose)")
        #expect(!result.prose.contains("surname"), "\(result.prose)")
        #expect(result.queryDescription?.contains("scope=family") == true)
    }

    @Test("an ordinary biography ask is untouched")
    func plainBiographyUnchanged() async throws {
        let context = try context()
        let result = try await ask("tell me about my dad", context: context)
        #expect(result.outcome == .answered)
        #expect(!result.prose.contains("told me"), "\(result.prose)")
        #expect(result.queryDescription?.contains("topic=") != true)
    }
}
