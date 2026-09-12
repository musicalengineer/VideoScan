import Foundation
import Testing
@testable import VideoScanCore

/// GH #184 item 6: the writer's own line. A pronunciation key is SET only
/// when it is a word of the person's name (FamilyNameTokens); the by-name
/// variant never leaves a freshly minted person behind for a word it
/// refused. Live 2026-09-11: {"see": "KY | OK"} landed on Adam FitzHerbert
/// of Llanllowell through "Llanlowell Llan Hywel and see note".
struct CyberBrainWriterPronunciationGuardTests {

    private let adamName = "Adam FitzHerbert of Llanllowell"
    private let adamAliases = ["Llanlowell Llan Hywel and see note"]

    private func archive(with people: [CyberBrainPerson]) -> CyberBrainArchive {
        CyberBrainArchive(archiveID: "family", displayName: "Family", people: people, sources: [])
    }

    @Test func theByNameVariantRefusesACommonWordAndMintsNobody() throws {
        let empty = archive(with: [])
        #expect(throws: CyberBrainWriter.WriteError.unresolvedWord("see", adamName)) {
            try CyberBrainWriter.settingPronunciation(
                subjectName: adamName, gedcomPersonID: "@IB23862@", aliases: adamAliases,
                word: "see", saidAs: "KY | OK", in: empty)
        }
        for word in ["and", "note", "of"] {
            #expect(throws: CyberBrainWriter.WriteError.self, Comment(rawValue: word)) {
                try CyberBrainWriter.settingPronunciation(
                    subjectName: adamName, gedcomPersonID: "@IB23862@", aliases: adamAliases,
                    word: word, saidAs: "x", in: empty)
            }
        }
        // A word of his actual name still mints him and lands.
        let ok = try CyberBrainWriter.settingPronunciation(
            subjectName: adamName, gedcomPersonID: "@IB23862@", aliases: adamAliases,
            word: "FitzHerbert", saidAs: "fits-HER-bert", in: empty)
        #expect(ok.createdPerson)
        #expect(ok.archive.people.count == 1)
        #expect(ok.archive.people[0].pronunciations == ["FitzHerbert": "fits-HER-bert"])
    }

    @Test func thePersonIDVariantRefusesAWordThatIsNotInTheName() throws {
        let adam = CyberBrainPerson(id: "person.adam", gedcomPersonID: "@IB23862@",
                                    canonicalName: adamName, aliases: adamAliases)
        let existing = archive(with: [adam])
        #expect(throws: CyberBrainWriter.WriteError.unresolvedWord("see", adamName)) {
            try CyberBrainWriter.settingPronunciation(personID: "person.adam", word: "see", saidAs: "KY", in: existing)
        }
        #expect(throws: CyberBrainWriter.WriteError.self) {
            try CyberBrainWriter.settingPronunciation(personID: "person.adam", word: "Kentucky", saidAs: "ken-TUCK-ee", in: existing)
        }
        let ok = try CyberBrainWriter.settingPronunciation(personID: "person.adam", word: "Adam", saidAs: "AY-dum", in: existing)
        #expect(ok.archive.people[0].pronunciations == ["Adam": "AY-dum"])
        // The error reads honestly in the failure reply.
        let error = CyberBrainWriter.WriteError.unresolvedWord("see", adamName)
        #expect(error.errorDescription == "\"see\" is not a word of Adam FitzHerbert of Llanllowell's name")
    }

    @Test func removalIsAlwaysAllowedSoJunkCanBeCleanedOut() throws {
        // A junk key written before the guard existed.
        let junk = CyberBrainPerson(id: "person.adam", gedcomPersonID: "@IB23862@",
                                    canonicalName: adamName, aliases: adamAliases,
                                    pronunciations: ["see": "KY | OK", "Adam": "AY-dum"])
        let cleaned = try CyberBrainWriter.settingPronunciation(
            personID: "person.adam", word: "see", saidAs: nil, in: archive(with: [junk]))
        #expect(cleaned.archive.people[0].pronunciations == ["Adam": "AY-dum"])
        #expect(cleaned.saidAs == nil)
    }

    @Test func theTreeNameIsAcceptedThroughTheByNameVariantForALinkedRecord() throws {
        // The Family Tree inspector: the CyberBrain record is "Ma", linked
        // by pointer; the chip word comes from the TREE name "Eileen Latta".
        let ma = CyberBrainPerson(id: "person.ma", gedcomPersonID: "@I3@", canonicalName: "Ma", aliases: ["Mom"])
        let receipt = try CyberBrainWriter.settingPronunciation(
            subjectName: "Eileen Latta", gedcomPersonID: "@I3@", aliases: [],
            word: "Latta", saidAs: "LAT-uh", in: archive(with: [ma]))
        #expect(!receipt.createdPerson)
        #expect(receipt.personID == "person.ma")
        #expect(receipt.archive.people[0].pronunciations == ["Latta": "LAT-uh"])
        // But a common word in the tree name is still refused.
        #expect(throws: CyberBrainWriter.WriteError.self) {
            try CyberBrainWriter.settingPronunciation(
                subjectName: "Eileen of Chelsea", gedcomPersonID: "@I3@", aliases: [],
                word: "of", saidAs: "uv", in: archive(with: [ma]))
        }
    }

    @Test func theDurableByNameVariantWritesNothingForARefusedWord() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cyberbrain-guard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: CyberBrainWriter.WriteError.self) {
            try CyberBrainWriter.setPronunciation(
                subjectName: adamName, gedcomPersonID: "@IB23862@", aliases: adamAliases,
                token: "see", saidAs: "KY | OK", rootURL: root)
        }
        let contents = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(contents.isEmpty, Comment(rawValue: contents.joined(separator: ",")))
    }
}
