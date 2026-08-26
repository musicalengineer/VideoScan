import Foundation
import Testing
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
