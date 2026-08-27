import Foundation
import Testing
@testable import VideoScanCore

/// Per-person "said as" table on the CyberBrain person record
/// (2026-08-26). Additive schema: an older file without the field loads
/// unchanged; a person without entries encodes without the key.
struct CyberBrainPronunciationTests {

    private let told = Date(timeIntervalSince1970: 1_787_300_000)

    private func archive(pronunciations: [String: String]? = nil) -> CyberBrainArchive {
        CyberBrainArchive(
            archiveID: "family", displayName: "Family",
            people: [
                CyberBrainPerson(
                    id: "person.nathaniel", canonicalName: "Nathaniel McGill",
                    aliases: ["Nate"],
                    notes: [CyberBrainItem(
                        id: "note.1", kind: .note, text: "Born in Belfast.",
                        subjectPersonIDs: ["person.nathaniel"], sourceIDs: ["src.1"],
                        confidence: .probable, privacy: .family,
                        createdAt: told, updatedAt: told)],
                    pronunciations: pronunciations),
                CyberBrainPerson(id: "person.edith", canonicalName: "Edith Latta"),
            ],
            sources: [CyberBrainSource(id: "src.1", type: .familyWitness, title: "Told by Rick")])
    }

    private func scratchRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CyberBrainPronunciationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Schema

    @Test func olderFileWithoutTheFieldLoadsUnchangedAndEncodesWithoutIt() throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // A pre-field file: exactly what the older writer produced.
        let old = try CyberBrainWriter.encode(archive())
        #expect(!String(decoding: old, as: UTF8.self).contains("pronunciations"))
        try old.write(to: root.appendingPathComponent(CyberBrainLoader.defaultFilename))
        let loaded = try CyberBrainLoader(rootURL: root).load()
        #expect(loaded == archive())
        #expect(loaded.people[0].pronunciations == nil)
        // Re-encoding a field-less archive is byte-identical to the old form.
        #expect(try CyberBrainWriter.encode(loaded) == old)
    }

    @Test func fieldRoundTripsThroughEncodeAndLoad() throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let withTable = archive(pronunciations: ["Nathaniel": "nuh-THAN-yul", "McGill": "muh-GILL"])
        try CyberBrainWriter.encode(withTable)
            .write(to: root.appendingPathComponent(CyberBrainLoader.defaultFilename))
        let loaded = try CyberBrainLoader(rootURL: root).load()
        #expect(loaded.people[0].pronunciations == ["Nathaniel": "nuh-THAN-yul", "McGill": "muh-GILL"])
        #expect(loaded.people[1].pronunciations == nil)
        // An empty table normalises to nil so it never writes `{}`.
        #expect(archive(pronunciations: [:]).people[0].pronunciations == nil)
    }

    @Test func validatorRejectsMultiWordKeysAndEmptyValues() {
        #expect(throws: CyberBrainError.self) {
            try CyberBrainValidator.validate(archive(pronunciations: ["Nathaniel McGill": "x"]))
        }
        #expect(throws: CyberBrainError.self) {
            try CyberBrainValidator.validate(archive(pronunciations: ["Nathaniel": "  "]))
        }
        #expect(throws: Never.self) {
            try CyberBrainValidator.validate(archive(pronunciations: ["Nathaniel": "nuh-THAN-yul"]))
        }
    }

    // MARK: - Writer (pure)

    @Test func settingReplacesCaseInsensitivelyAndEmptyRemoves() throws {
        var receipt = try CyberBrainWriter.settingPronunciation(
            personID: "person.nathaniel", word: " Nathaniel ", saidAs: "nuh-THAN-yul", in: archive())
        #expect(receipt.word == "Nathaniel")
        #expect(receipt.saidAs == "nuh-THAN-yul")
        #expect(receipt.canonicalName == "Nathaniel McGill")
        #expect(receipt.archive.people[0].pronunciations == ["Nathaniel": "nuh-THAN-yul"])
        // Everything else on the person is untouched.
        #expect(receipt.archive.people[0].withPronunciations(nil) == archive().people[0])

        receipt = try CyberBrainWriter.settingPronunciation(
            personID: "person.nathaniel", word: "nathaniel", saidAs: "nah-THAN-yel", in: receipt.archive)
        #expect(receipt.archive.people[0].pronunciations == ["nathaniel": "nah-THAN-yel"])

        receipt = try CyberBrainWriter.settingPronunciation(
            personID: "person.nathaniel", word: "Nathaniel", saidAs: "", in: receipt.archive)
        #expect(receipt.saidAs == nil)
        #expect(receipt.archive.people[0].pronunciations == nil)

        #expect(throws: CyberBrainWriter.WriteError.self) {
            try CyberBrainWriter.settingPronunciation(
                personID: "person.nobody", word: "X", saidAs: "y", in: archive())
        }
        #expect(throws: CyberBrainWriter.WriteError.self) {
            try CyberBrainWriter.settingPronunciation(
                personID: "person.nathaniel", word: "Nathaniel McGill", saidAs: "y", in: archive())
        }
    }

    @Test func byNameResolvesAnExistingPersonOrMintsOneWithOnlyThePronunciation() throws {
        // Alias hit → existing person.
        let existing = try CyberBrainWriter.settingPronunciation(
            subjectName: "Nate", gedcomPersonID: nil, word: "Nathaniel", saidAs: "nuh-THAN-yul", in: archive())
        #expect(!existing.createdPerson)
        #expect(existing.personID == "person.nathaniel")

        // Unknown tree person → minted with pointer, no passages.
        let minted = try CyberBrainWriter.settingPronunciation(
            subjectName: "Bethiah Hendour", gedcomPersonID: "@I9@", word: "Bethiah",
            saidAs: "beh-THY-uh", in: archive())
        #expect(minted.createdPerson)
        let person = try #require(minted.archive.people.first { $0.id == minted.personID })
        #expect(person.gedcomPersonID == "@I9@")
        #expect(person.items.isEmpty)
        #expect(person.pronunciations == ["Bethiah": "beh-THY-uh"])
        #expect(minted.archive.people.count == 3)

        // No archive at all → a fresh one with one person.
        let fresh = try CyberBrainWriter.settingPronunciation(
            subjectName: "Edith", gedcomPersonID: nil, word: "Edith", saidAs: "EE-dith", in: nil)
        #expect(fresh.createdPerson)
        #expect(fresh.archive.people.count == 1)
    }

    // MARK: - Writer (durable)

    @Test func durableWriteIsAtomicKeepsABackupAndReloads() throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try CyberBrainWriter.encode(archive())
            .write(to: root.appendingPathComponent(CyberBrainLoader.defaultFilename))

        let receipt = try CyberBrainWriter.setPronunciation(
            personID: "person.nathaniel", token: "Nathaniel", saidAs: "nuh-THAN-yul", rootURL: root)
        #expect(receipt.archive.people[0].pronunciations == ["Nathaniel": "nuh-THAN-yul"])
        let reloaded = try CyberBrainLoader(rootURL: root).load()
        #expect(reloaded == receipt.archive)
        let backups = try FileManager.default.contentsOfDirectory(
            atPath: root.appendingPathComponent("backups").path)
        #expect(backups.count == 1)
        let stray = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(".") }
        #expect(stray.isEmpty)

        // By name, durable, on a directory with no archive yet.
        let empty = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: empty) }
        let minted = try CyberBrainWriter.setPronunciation(
            subjectName: "Bethiah Hendour", gedcomPersonID: "@I9@", token: "Bethiah",
            saidAs: "beh-THY-uh", rootURL: empty)
        #expect(minted.createdPerson)
        #expect(try CyberBrainLoader(rootURL: empty).load() == minted.archive)
    }
}
