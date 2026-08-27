import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

/// The respelling table Bella reads from: whole words only, possessives
/// intact, user file wins, and nothing in the displayed answer changes.
struct HalliePronunciationLexiconTests {
    private func scratchURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("HalliePronunciationLexiconTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Hallie", isDirectory: true)
            .appendingPathComponent(HalliePronunciationLexicon.fileName)
    }

    @Test func shippedTableCoversTheAuditedFamilyNames() {
        let written = Set(HalliePronunciationLexicon.shipped.entries.map(\.written))
        for name in ["McGill", "Edith", "McDonald", "McCarthy", "McLaughlin", "Latta", "Breen", "Ronan", "Lamb", "Hendour"] {
            #expect(written.contains(name), Comment(rawValue: name))
        }
        #expect(HalliePronunciationLexicon.shipped.entries.first { $0.written == "McLaughlin" }?.spoken == "muh-GLOCK-lin")
        #expect(HalliePronunciationLexicon.shipped.entries.first { $0.written == "McGill" }?.spoken == "muh-GILL")
    }

    @Test func substitutionIsWholeWordCaseInsensitiveAndKeepsPossessives() {
        let lexicon = HalliePronunciationLexicon.shipped
        let (spoken, fired) = lexicon.apply(to: "Ann McGill's son married Edith Latta; MCGILL Road; the Lambert Breens.")
        #expect(spoken == "Ann muh-GILL's son married EE-dith LAT-uh; muh-GILL Road; the Lambert Breens.")
        #expect(fired.map(\.written) == ["McGill", "Edith", "Latta"])
        // "Lambert" and "Breens" are untouched: whole words only.
        #expect(lexicon.apply(to: "Lambert Breens").fired.isEmpty)
        // Identity entries (Breen → Breen) are listed for the user but never fire.
        #expect(lexicon.apply(to: "Rick Breen and Mary Lamb").fired.isEmpty)
        #expect(lexicon.apply(to: "").fired.isEmpty)
        #expect(lexicon.apply(to: "McGill’s").spoken == "muh-GILL’s")
    }

    @Test func speakerUsesTheLexiconForSpeechOnlyAndDisplayedTextIsUntouched() {
        let displayed = "Patrick McGill is Rick Breen's great-great-grandfather."
        #expect(HallieSpeaker.spokenText(displayed) == "Patrick muh-GILL is Rick Breen's great-great-grandfather.")
        #expect(HallieSpeaker.sentences(displayed) == ["Patrick muh-GILL is Rick Breen's great-great-grandfather."])
        #expect(displayed == "Patrick McGill is Rick Breen's great-great-grandfather.")
        // An empty lexicon leaves names alone; suffix expansion still happens.
        let empty = HalliePronunciationLexicon(entries: [])
        #expect(HallieSpeaker.spokenText("Patrick McGill Jr.", lexicon: empty) == "Patrick McGill Junior")
    }

    @Test func missingFileIsCreatedFromTheShippedDefault() throws {
        let url = scratchURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
        let log = InMemoryLogSink(name: "test")
        let loaded = HalliePronunciationLexicon.load(from: url, log: log)
        #expect(loaded == .shipped)
        #expect(FileManager.default.fileExists(atPath: url.path))
        let reread = try HalliePronunciationLexicon(jsonData: Data(contentsOf: url))
        #expect(reread == .shipped)
        #expect(log.lines.contains { $0.contains("wrote default pronunciations") })
    }

    @Test func userFileReplacesTheShippedTableAndBadValuesAreDropped() throws {
        let url = scratchURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"Breen": "BRINE", "Edith": 7, " ": "x", "Dwyer": "  "}"#.utf8).write(to: url)
        let loaded = HalliePronunciationLexicon.load(from: url, log: nil)
        #expect(loaded.entries == [.init(written: "Breen", spoken: "BRINE")])
        #expect(loaded.apply(to: "Edith Breen").spoken == "Edith BRINE")
    }

    @Test func malformedFileFallsBackToShippedAndIsLeftForTheUserToFix() throws {
        let url = scratchURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        let log = InMemoryLogSink(name: "test")
        #expect(HalliePronunciationLexicon.load(from: url, log: log) == .shipped)
        #expect(try String(contentsOf: url, encoding: .utf8) == "not json")
        #expect(log.lines.contains { $0.contains("unreadable") })
    }
}

// MARK: - Layers (2026-08-26: per-person "said as" beside aliases)

extension HalliePronunciationLexiconTests {
    private func brainPeople() -> [CyberBrainPerson] {
        [
            CyberBrainPerson(id: "person.nathaniel", canonicalName: "Nathaniel McGill",
                             pronunciations: ["Nathaniel": "nah-THAN-yel", "McGill": "mick-GILL"]),
            CyberBrainPerson(id: "person.edith", canonicalName: "Edith Latta"),
            // A second record claiming the same word: the lower id wins.
            CyberBrainPerson(id: "person.zed", canonicalName: "Nathaniel Lamb",
                             pronunciations: ["nathaniel": "NAT-han-yel"]),
        ]
    }

    @Test func shippedTableCarriesNathanielAndBethiah() {
        let table = Dictionary(uniqueKeysWithValues: HalliePronunciationLexicon.shipped.entries.map { ($0.written, $0.spoken) })
        #expect(table["Nathaniel"] == "nuh-THAN-yul")
        #expect(table["Bethiah"] == "beh-THY-uh")
        #expect(table["Edith"] == "EE-dith")
        #expect(table["McGill"] == "muh-GILL")
        #expect(table["Latta"] == "LAT-uh")
    }

    @Test func mergeOrderIsPeopleThenFileThenShippedFirstMatchWins() {
        let people = HalliePronunciationLexicon.personLayer(people: brainPeople())
        #expect(people.entries.map(\.written).sorted() == ["McGill", "Nathaniel"])
        let file = HalliePronunciationLexicon(entries: [
            .init(written: "McGill", spoken: "FILE-gill"),
            .init(written: "Latta", spoken: "FILE-uh"),
        ])
        let merged = HalliePronunciationLexicon.merged([people, file, .shipped])

        let (spoken, fired) = merged.apply(to: "Nathaniel McGill's wife Edith Latta")
        #expect(spoken == "nah-THAN-yel mick-GILL's wife EE-dith FILE-uh")
        let sources = Dictionary(uniqueKeysWithValues: fired.map { ($0.written, merged.source(of: $0)) })
        #expect(sources["Nathaniel"] == .person(id: "person.nathaniel", name: "Nathaniel McGill"))
        #expect(sources["McGill"] == .person(id: "person.nathaniel", name: "Nathaniel McGill"))
        #expect(sources["Latta"] == .file)
        #expect(sources["Edith"] == .shipped)
        #expect(merged.logLine(for: fired).contains("Nathaniel→nah-THAN-yel (person Nathaniel McGill)"))
        #expect(merged.logLine(for: fired).contains("Edith→EE-dith (shipped)"))
        #expect(merged.logLine(for: fired).contains("Latta→FILE-uh (pronunciations.json)"))
        // Possessives and case still survive with a person-level entry.
        #expect(merged.apply(to: "NATHANIEL's").spoken == "nah-THAN-yel's")
        #expect(merged.apply(to: "Nathaniels").fired.isEmpty)
    }

    @Test func resolvedReadsTheBrainDirectoryAndTheCacheDropsOnInvalidate() throws {
        let fileURL = scratchURL()
        let brainRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("HalliePronunciationLexiconTests-brain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: brainRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent().deletingLastPathComponent())
            try? FileManager.default.removeItem(at: brainRoot)
        }
        // No brain yet → file (written from shipped) + shipped only.
        let before = HalliePronunciationLexicon.resolved(fileURL: fileURL, cyberBrainRootURL: brainRoot, log: nil)
        #expect(before.apply(to: "Nathaniel").spoken == "nuh-THAN-yul")

        _ = try CyberBrainWriter.setPronunciation(
            subjectName: "Nathaniel McGill", gedcomPersonID: "@I7@", token: "Nathaniel",
            saidAs: "nah-THAN-yel", rootURL: brainRoot)
        PersonPronunciationCache.shared.invalidate()
        let after = HalliePronunciationLexicon.resolved(fileURL: fileURL, cyberBrainRootURL: brainRoot, log: nil)
        let fired = after.apply(to: "Nathaniel").fired
        #expect(after.apply(to: "Nathaniel").spoken == "nah-THAN-yel")
        #expect(fired.first.map { after.source(of: $0) } == .person(id: "person.nathaniel-mcgill.i7", name: "Nathaniel McGill"))
        // The other layers are still there.
        #expect(after.apply(to: "Edith").spoken == "EE-dith")
    }

    @Test func fileEntryWriteReplacesCaseInsensitivelyAndEmptyRemoves() throws {
        let url = scratchURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
        let set = try HalliePronunciationLexicon.setFileEntry(written: "Bethiah", spoken: "BETH-ee-uh", url: url, log: nil)
        #expect(set.apply(to: "Bethiah").spoken == "BETH-ee-uh")
        let reread = try HalliePronunciationLexicon(jsonData: Data(contentsOf: url))
        #expect(reread.entries.filter { $0.written.lowercased() == "bethiah" }.count == 1)
        #expect(reread.apply(to: "Bethiah").spoken == "BETH-ee-uh")
        // Lower-case key replaces rather than duplicates; the rest survives.
        let again = try HalliePronunciationLexicon.setFileEntry(written: "bethiah", spoken: "beh-THY-uh", url: url, log: nil)
        #expect(again.entries.filter { $0.written.lowercased() == "bethiah" } == [.init(written: "bethiah", spoken: "beh-THY-uh")])
        #expect(again.apply(to: "Edith").spoken == "EE-dith")
        let removed = try HalliePronunciationLexicon.setFileEntry(written: "Bethiah", spoken: "", url: url, log: nil)
        #expect(!removed.entries.contains { $0.written.lowercased() == "bethiah" })
        #expect(throws: (any Error).self) {
            try HalliePronunciationLexicon.setFileEntry(written: "two words", spoken: "x", url: url, log: nil)
        }
    }
}

// MARK: - Shared words (codex #700, 2026-08-26)

extension HalliePronunciationLexiconTests {
    /// Two records claim "nathaniel": the subject of the answer wins, else
    /// the newest record, else the lowest id — and the choice is logged.
    @Test func aSharedWordPrefersTheSubjectThenTheNewestRecordThenTheLowestId() {
        var people = brainPeople()
        let log = InMemoryLogSink(name: "test")

        // No subject, no items on either record → lowest id, logged.
        #expect(HalliePronunciationLexicon.personLayer(people: people, log: log)
                    .apply(to: "Nathaniel").spoken == "nah-THAN-yel")
        #expect(log.lines.contains { $0.contains("'Nathaniel' carried by 2 records") && $0.hasSuffix("(lowest id)") })

        // Subject by id, then by name; a subject who does not carry the
        // word changes nothing.
        #expect(HalliePronunciationLexicon.personLayer(people: people, subject: "person.zed")
                    .apply(to: "Nathaniel").spoken == "NAT-han-yel")
        let byName = HalliePronunciationLexicon.personLayer(people: people, subject: "nathaniel lamb", log: log)
        #expect(byName.apply(to: "Nathaniel's").spoken == "NAT-han-yel's")
        #expect(byName.source(of: byName.entries[0]) == .person(id: "person.zed", name: "Nathaniel Lamb"))
        #expect(log.lines.last?.hasSuffix("(subject of this answer)") == true)
        #expect(HalliePronunciationLexicon.personLayer(people: people, subject: "Edith Latta")
                    .apply(to: "Nathaniel").spoken == "nah-THAN-yel")

        // Without a subject, a record with a newer item outranks the lower id.
        let told = Date(timeIntervalSince1970: 1_787_300_000)
        people[2] = CyberBrainPerson(
            id: "person.zed", canonicalName: "Nathaniel Lamb",
            notes: [CyberBrainItem(id: "note.zed", kind: .note, text: "Born in Belfast.",
                                   subjectPersonIDs: ["person.zed"], sourceIDs: [],
                                   confidence: .probable, privacy: .family,
                                   createdAt: told, updatedAt: told)],
            pronunciations: ["nathaniel": "NAT-han-yel"])
        let newest = HalliePronunciationLexicon.personLayer(people: people, log: log)
        #expect(newest.apply(to: "Nathaniel").spoken == "NAT-han-yel")
        #expect(log.lines.last?.hasSuffix("(most recently updated)") == true)
        // The unshared word is untouched by any of this.
        #expect(newest.apply(to: "McGill").spoken == "mick-GILL")
    }
}
