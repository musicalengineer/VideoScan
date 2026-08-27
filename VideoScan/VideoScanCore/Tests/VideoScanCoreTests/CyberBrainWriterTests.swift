import Foundation
import Testing
@testable import VideoScanCore

/// The first writer for the family's knowledge file. Every test here is
/// about one promise: what a family member tells Hallie is kept EXACTLY,
/// attributed, unverified, and the file on disk is never torn or clobbered.
struct CyberBrainWriterTests {

    private let told = Date(timeIntervalSince1970: 1_787_300_000) // 2026-08-21

    private func testimony(
        _ text: String,
        subject: String = "Dad Breen",
        aliases: [String] = [],
        speaker: String = "Rick"
    ) -> CyberBrainWriter.Testimony {
        .init(subjectName: subject, subjectAliases: aliases,
              speakerName: speaker, text: text, date: told)
    }

    private func existingArchive() -> CyberBrainArchive {
        CyberBrainArchive(
            archiveID: "breen-family",
            displayName: "Breen Family CyberBrain",
            people: [
                CyberBrainPerson(
                    id: "person.rick-breen",
                    canonicalName: "Rick Breen",
                    aliases: ["Dicky"],
                    biographyPassages: [
                        CyberBrainItem(
                            id: "bio.rick.1", kind: .biography,
                            text: "Rick is a retired software engineer.",
                            subjectPersonIDs: ["person.rick-breen"],
                            sourceIDs: ["source.ctx"],
                            confidence: .confirmed, privacy: .family,
                            createdAt: told, updatedAt: told),
                    ]),
            ],
            sources: [
                CyberBrainSource(id: "source.ctx", type: .firstPerson,
                                 title: "Rick Breen project context",
                                 attribution: "Rick Breen"),
            ])
    }

    // MARK: - Pure appending

    @Test func newPersonIsCreatedWithTestimonyAttributedAndUnverified() throws {
        let receipt = try CyberBrainWriter.appending(
            testimony("He repaired typewriters for a living.",
                      aliases: ["Richard Breen Sr."]),
            to: existingArchive())

        #expect(receipt.createdPerson)
        #expect(receipt.personID == "person.dad-breen")
        #expect(receipt.canonicalName == "Dad Breen")
        let person = try #require(receipt.archive.people.first { $0.id == "person.dad-breen" })
        #expect(person.aliases == ["Richard Breen Sr."])
        let item = try #require(person.biographyPassages.first)
        #expect(item.text == "He repaired typewriters for a living.")
        #expect(item.confidence == .probable, "told in conversation ≠ verified")
        #expect(item.privacy == .family)
        #expect(item.status == .active)
        #expect(item.sourceIDs == [receipt.sourceID])
        let source = try #require(receipt.archive.sources.first { $0.id == receipt.sourceID })
        #expect(source.type == .familyWitness)
        #expect(source.attribution == "Rick")
        #expect(source.title.hasPrefix("Told to Hallie by Rick, "))
        // The existing person and source are untouched.
        #expect(receipt.archive.people.first?.id == "person.rick-breen")
        #expect(receipt.archive.sources.first?.id == "source.ctx")
    }

    @Test func existingPersonFoundByAliasGetsThePassageAppended() throws {
        let receipt = try CyberBrainWriter.appending(
            testimony("Dicky loved his Stratocaster.", subject: "Dicky"),
            to: existingArchive())

        #expect(!receipt.createdPerson)
        #expect(receipt.personID == "person.rick-breen")
        #expect(receipt.canonicalName == "Rick Breen")
        let person = try #require(receipt.archive.people.first { $0.id == "person.rick-breen" })
        #expect(person.biographyPassages.count == 2)
        #expect(person.biographyPassages.last?.text == "Dicky loved his Stratocaster.")
        #expect(person.biographyPassages.first?.text == "Rick is a retired software engineer.",
                "appending never edits what was already there")
    }

    @Test func secondPassageSameDayGetsDistinctIDAndSharesTheSource() throws {
        let first = try CyberBrainWriter.appending(testimony("He was a Marine."), to: nil)
        let second = try CyberBrainWriter.appending(
            testimony("He fixed typewriters."), to: first.archive)

        #expect(first.itemID != second.itemID)
        #expect(first.sourceID == second.sourceID, "one source per speaker per day")
        #expect(second.archive.sources.count == 1)
        let person = try #require(second.archive.people.first)
        #expect(person.biographyPassages.map(\.text) == ["He was a Marine.", "He fixed typewriters."])
    }

    @Test func anecdoteAndEventKindsLandInTheirOwnLists() throws {
        var receipt = try CyberBrainWriter.appending(
            .init(subjectName: "Dad Breen", speakerName: "Rick",
                  text: "He once drove through a blizzard to fix a school's typewriters.",
                  kind: .anecdote, date: told),
            to: nil)
        receipt = try CyberBrainWriter.appending(
            .init(subjectName: "Dad Breen", speakerName: "Rick",
                  text: "He enlisted in the Marines.", kind: .event, date: told),
            to: receipt.archive)
        let person = try #require(receipt.archive.people.first)
        #expect(person.anecdotes.count == 1)
        #expect(person.lifeEvents.count == 1)
        #expect(person.biographyPassages.isEmpty)
    }

    @Test func emptyTextOrSubjectIsRefused() {
        #expect(throws: CyberBrainWriter.WriteError.emptyText) {
            try CyberBrainWriter.appending(testimony("   "), to: nil)
        }
        #expect(throws: CyberBrainWriter.WriteError.emptySubject) {
            try CyberBrainWriter.appending(testimony("He was tall.", subject: " "), to: nil)
        }
    }

    @Test func ambiguousSubjectIsRefusedRatherThanGuessed() throws {
        let archive = CyberBrainArchive(
            archiveID: "x", displayName: "x",
            people: [
                CyberBrainPerson(id: "person.tim-a", canonicalName: "Tim Breen", aliases: ["Tim"]),
                CyberBrainPerson(id: "person.tim-b", canonicalName: "Timothy Smith", aliases: ["Tim"]),
            ],
            sources: [])
        #expect(throws: CyberBrainWriter.WriteError.ambiguousSubject(["Tim Breen", "Timothy Smith"])) {
            try CyberBrainWriter.appending(testimony("He was tall.", subject: "Tim"), to: archive)
        }
    }

    @Test func theAppendedArchiveAlwaysPassesTheStrictValidator() throws {
        let receipt = try CyberBrainWriter.appending(
            testimony("Born in Boston.", subject: "Mémé Côté", aliases: ["Meme"]),
            to: existingArchive())
        #expect(throws: Never.self) { try CyberBrainValidator.validate(receipt.archive) }
        #expect(throws: Never.self) { _ = try CyberBrainIndex(archive: receipt.archive) }
        #expect(receipt.personID == "person.meme-cote", "ids are ascii slugs")
    }

    // MARK: - Durable write

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cyberbrain-writer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func recordCreatesTheFileAndTheLoaderReadsItBackIdentically() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let receipt = try CyberBrainWriter.record(
            testimony("He repaired typewriters."), rootURL: root)
        let reloaded = try CyberBrainLoader(rootURL: root).load()
        #expect(reloaded == receipt.archive, "ISO-8601 dates and every field round-trip")
        let index = try CyberBrainIndex(archive: reloaded)
        guard case .resolved(let person) = index.resolve("dad breen") else {
            Issue.record("the subject must be findable by the name the speaker used")
            return
        }
        #expect(index.evidence(for: person.id, privacyCeiling: .family).map(\.text)
                == ["He repaired typewriters."])
        // No temp or probe debris left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(leftovers.sorted() == ["cyberbrain.json"], "\(leftovers)")
    }

    @Test func secondRecordAppendsAndKeepsABackupOfThePreviousFile() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try CyberBrainWriter.record(testimony("He was a Marine."), rootURL: root)
        let before = try Data(contentsOf: root.appendingPathComponent("cyberbrain.json"))
        _ = try CyberBrainWriter.record(testimony("He fixed typewriters."), rootURL: root)

        let reloaded = try CyberBrainLoader(rootURL: root).load()
        #expect(reloaded.people.first?.biographyPassages.count == 2)
        let backups = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("backups"), includingPropertiesForKeys: nil)
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: backups[0]) == before, "the backup is the exact previous bytes")
    }

    @Test func aCorruptExistingFileIsNeverReplaced() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("cyberbrain.json")
        try Data("{ not json".utf8).write(to: file)

        #expect(throws: (any Error).self) {
            try CyberBrainWriter.record(testimony("He was tall."), rootURL: root)
        }
        #expect(try Data(contentsOf: file) == Data("{ not json".utf8),
                "a corrupt archive is a problem to surface, not to overwrite")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("backups").path))
    }

    @Test func aSymlinkedRootIsRefused() throws {
        let real = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: real) }
        let link = FileManager.default.temporaryDirectory
            .appendingPathComponent("cyberbrain-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: link) }

        #expect(throws: CyberBrainWriter.WriteError.unsafeRoot(link.path)) {
            try CyberBrainWriter.record(testimony("He was tall."), rootURL: link)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: real.path).isEmpty)
    }

    @Test func slugsAreStableAsciiAndUniqueIDsNeverCollide() {
        #expect(CyberBrainWriter.slug("Dad Breen") == "dad-breen")
        #expect(CyberBrainWriter.slug("  Mémé  Côté!! ") == "meme-cote")
        #expect(CyberBrainWriter.slug("???") == "unnamed")
        #expect(CyberBrainWriter.uniqueID(base: "a", taken: []) == "a")
        #expect(CyberBrainWriter.uniqueID(base: "a", taken: ["a", "a.2"]) == "a.3")
    }
}

// MARK: - Additive-field sensor (#167 class, QA 2026-08-26)

extension CyberBrainWriterTests {

    /// Every rebuild of a CyberBrainPerson must carry EVERY field, including
    /// ones added after the writer was first written. #167 lost designation
    /// and fixity records to exactly this: an older-schema writer rebuilt a
    /// record without the newer fields. `pronunciations` is the newest
    /// field; this pins that both appenders keep it.
    @Test func appendingTestimonyAndCaptionKeepAnExistingPronunciationTable() throws {
        let base = existingArchive()
        let table = ["Breen": "BREEN", "Rick": "RICK"]
        let seeded = CyberBrainArchive(
            archiveID: base.archiveID, displayName: base.displayName,
            people: base.people.map { $0.withPronunciations(table) },
            sources: base.sources)

        let afterTestimony = try CyberBrainWriter.appending(
            testimony("He still plays the Strat.", subject: "Rick Breen"), to: seeded)
        #expect(!afterTestimony.createdPerson)
        #expect(afterTestimony.archive.people.first { $0.id == "person.rick-breen" }?.pronunciations == table)

        let caption = CyberBrainWriter.PhotoCaption(
            subjects: [.init(name: "Rick Breen")], speakerName: "Rick",
            text: "me at the bench", photoPath: "/nonexistent/bench.jpg", date: told)
        let afterCaption = try CyberBrainWriter.appending(caption: caption, to: afterTestimony.archive)
        let rick = try #require(afterCaption.archive.people.first { $0.id == "person.rick-breen" })
        #expect(rick.pronunciations == table)
        #expect(rick.biographyPassages.count == 2)   // the testimony landed too
        #expect(rick.notes.count == 1)               // and the caption
        // Round trip through the codec: the field is still there on disk.
        let data = try JSONEncoder().encode(afterCaption.archive)
        let decoded = try JSONDecoder().decode(CyberBrainArchive.self, from: data)
        #expect(decoded.people.first { $0.id == "person.rick-breen" }?.pronunciations == table)
    }
}
