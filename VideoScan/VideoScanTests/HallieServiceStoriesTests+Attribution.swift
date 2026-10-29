import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

/// strict-052 (nightly 2026-10-28): "anyone in the American Revolution"
/// listed a soldier's WIFE as having served. Her married-surname alias
/// (a single token) matched her husband's name in her own note — "Wife of
/// <husband>, a … Revolutionary War soldier". A service sentence belongs to
/// a person only when it is about that person: their own full name (or a
/// pronoun whose antecedent is still them) as the one who served — never a
/// shared surname, never a relative named in the sentence.
///
/// Synthetic names only; the shapes mirror the live notes.
extension HallieServiceStoriesTests {

    // MARK: - Fixture

    /// The soldier: a passage in the live shape (full name, then a record
    /// transcription with the surname-first form), no structured record.
    static let soldierPassage = "Nathaniel Ezra Wexley served in the American War for Independence from 1776 to 1780. Here is a section from the Massachusetts soldiers and sailors of the revolutionary war record: “Wexley, Ezra, Halden MA: 1776 marched to Manchester VT on alarm, discharged at Bennington; Jul–Dec 1780 six-months in Continental Army, goes by Ezra”."
    /// His wife's note, in the live shape: she is never named in it.
    static let wifeNote = "Wife of Ezra Wexley, a Halden Revolutionary War soldier (married 29 May 1781, Halden). Followed him to Brattleboro VT and then Stukely, Quebec, where she died in 1849."

    static func revolutionBrain() throws -> CyberBrainIndex {
        func item(_ id: String, _ text: String, _ person: String, kind: CyberBrainItem.Kind) -> CyberBrainItem {
            CyberBrainItem(id: id, kind: kind, text: text, subjectPersonIDs: [person],
                           sourceIDs: ["source.rick"], confidence: .confirmed, privacy: .family,
                           createdAt: told, updatedAt: told)
        }
        let archive = CyberBrainArchive(
            archiveID: "example-family", displayName: "Example",
            people: [
                CyberBrainPerson(
                    id: "person.nathaniel", canonicalName: "Nathaniel Ezra Wexley",
                    aliases: ["Nathaniel Wexley", "Ezra Wexley", "(Capt) Ezra Wexley"],
                    lifeEvents: [item("research.nathaniel", soldierPassage, "person.nathaniel", kind: .event)]),
                CyberBrainPerson(
                    id: "person.mercy", canonicalName: "Mercy Thorne", aliases: ["Wexley"],
                    notes: [item("note.mercy", wifeNote, "person.mercy", kind: .note)]),
                CyberBrainPerson(
                    id: "person.asa", canonicalName: "Asa Wexley",
                    notes: [item("note.asa", "Son of Ezra Wexley, who served in the Revolutionary War. Asa Wexley farmed in Stukely.",
                                 "person.asa", kind: .note)]),
            ],
            sources: [CyberBrainSource(id: "source.rick", type: .familyWitness,
                                       title: "Told by Rick Example", attribution: "Rick Example")])
        return try CyberBrainIndex(archive: archive)
    }

    static func person(_ name: String, _ aliases: [String] = []) -> CyberBrainPerson {
        CyberBrainPerson(id: "person.\(name)", canonicalName: name, aliases: aliases)
    }

    // MARK: - End to end (the strict-052 answer)

    @Test("strict-052: a soldier's wife is never listed as having served; the soldier still is")
    func soldiersWifeNotListed() async throws {
        let context = try HallieTurnExecutor.Context(
            graph: Self.tree(), cyberBrain: Self.revolutionBrain(),
            speakers: .init(ownerName: "Rick Example", archivistName: nil))
        let result = try await ask("anyone in the American Revolution", context: context)
        #expect(result.outcome == .answered, "\(result.prose)")
        #expect(result.prose.contains("Nathaniel Ezra Wexley — "), "\(result.prose)")
        #expect(!result.prose.contains("Mercy Thorne"), "\(result.prose)")
        #expect(!result.prose.contains("Asa Wexley"), "\(result.prose)")
        #expect(result.prose.hasPrefix("The family has told me about one person who served in the American Revolution: "),
                "\(result.prose)")
        let index = try Self.revolutionBrain()
        for id in ["person.mercy", "person.asa"] {
            let relative = try #require(index.person(id: id))
            #expect(HallieTurnExecutor.ServiceAnswer.servicePassages(for: relative, index: index).isEmpty, "\(id)")
        }
    }

    // MARK: - The attribution matrix

    @Test("a relative's service is not the person's: married/maiden alias, spouse, child, parent, sibling, Sr/Jr")
    func relativesServiceNotAttributed() {
        typealias S = HallieTurnExecutor.ServiceAnswer
        let mercyAliasSurname = Self.person("Mercy Thorne", ["Wexley"])
        let mercyAliasFull = Self.person("Mercy Thorne", ["Mercy Wexley"])
        let asa = Self.person("Asa Wexley")
        let nathaniel = Self.person("Nathaniel Ezra Wexley", ["Ezra Wexley", "(Capt) Ezra Wexley"])
        let cases: [(String, CyberBrainPerson, String)] = [
            ("live shape, married-surname alias", mercyAliasSurname, Self.wifeNote),
            ("live shape, married full-name alias", mercyAliasFull, Self.wifeNote),
            ("she is named, she married the soldier", mercyAliasFull,
             "Mercy Thorne married Ezra Wexley, a Revolutionary War soldier, in 1781."),
            ("her husband served", mercyAliasFull, "Mercy Thorne's husband served in the Continental Army."),
            ("her husband served, pronoun", mercyAliasFull, "Her husband served in the Continental Army."),
            ("a pronoun after she married names him", mercyAliasFull,
             "She married Ezra Wexley in 1781. He served at Bennington in the army."),
            ("widow of a soldier", mercyAliasFull, "She was the widow of a soldier."),
            ("child: son of a soldier", asa, "Son of Ezra Wexley, who served in the Revolutionary War."),
            ("shared surname, sibling served", asa, "Jonah Wexley served at Bennington."),
            ("parent: named as the father in his son's sentence", nathaniel,
             "Asa Wexley, son of Ezra Wexley, enlisted in 1812."),
            ("parent: his son enlisted", nathaniel, "Nathaniel Ezra Wexley's son enlisted in 1812."),
            ("Sr is not Jr", Self.person("Richard Example Jr"), "Richard Example Sr served in the Navy."),
            ("Jr is not a suffix-less namesake", Self.person("Richard Example"), "Richard Example Jr served in the Navy."),
            ("a given name alone is not a full name", mercyAliasFull, "Mercy enlisted in the army in 1942."),
        ]
        for (label, person, sentence) in cases {
            #expect(S.serviceSentences(in: sentence, about: person).isEmpty, "\(label): \(sentence)")
        }
    }

    @Test("true attributions stay: full name, alias, record inversion, appositive, pronoun, two soldiers")
    func ownServiceStillAttributed() {
        typealias S = HallieTurnExecutor.ServiceAnswer
        let nathaniel = Self.person("Nathaniel Ezra Wexley", ["Nathaniel Wexley", "Ezra Wexley", "(Capt) Ezra Wexley"])
        let cases: [(String, CyberBrainPerson, String, Int)] = [
            ("live soldier passage", nathaniel, Self.soldierPassage, 2),
            ("alias", nathaniel, "Ezra Wexley enlisted in 1776.", 1),
            ("given + surname", nathaniel, "In the Revolutionary War, Nathaniel Wexley marched to Bennington.", 1),
            ("record inversion", nathaniel, "Wexley, Ezra, Halden: enlisted 1776", 1),
            ("pronoun continues the person", nathaniel,
             "Nathaniel Ezra Wexley served in the Revolution. He enlisted again in 1780.", 2),
            ("two soldiers, first", Self.person("Ezra Wexley"), "Ezra Wexley and Jonah Wexley served at Bennington.", 1),
            ("two soldiers, second", Self.person("Jonah Wexley"), "Ezra Wexley and Jonah Wexley served at Bennington.", 1),
            ("appositive kin describes the person", Self.person("Harold Example"),
             "Harold Example, Rick's father, served in the United States Marine Corps in the 1940s.", 1),
            ("apposed kin before the name", Self.person("Asa Wexley"), "His son Asa Wexley enlisted in 1812.", 1),
            ("own suffix", Self.person("Richard Example Sr"), "Richard Example Sr served in the Navy.", 1),
            ("married full-name alias, her own service", Self.person("Mercy Thorne", ["Mercy Wexley"]),
             "Mercy Wexley served as a nurse in the army.", 1),
        ]
        for (label, person, text, count) in cases {
            #expect(S.serviceSentences(in: text, about: person).count == count, "\(label): \(text)")
        }
    }
}
