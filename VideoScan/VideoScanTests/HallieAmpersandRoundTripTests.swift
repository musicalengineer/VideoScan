// HallieAmpersandRoundTripTests.swift
// Live 2026-08-27 03:27Z: a presence answer naming "DonnaRock&Piano.mov"
// was REPORTED as "DonnaRock&amp;Piano.mov". The private transcript for
// that turn holds the raw '&', the Mac chat uses Text(String) (verbatim,
// no markup), the web page sets textContent, and the speaker gets the
// String itself — none of them entity-escape. These sensors pin each hop
// so an escape can't creep into prose/transcript/speech; the web page is
// the ONLY place allowed to escape, and only at render time.

import Foundation
import Testing
@testable import VideoScan

@Suite("Ampersand survives every hop as '&'", .serialized)
struct HallieAmpersandRoundTripTests {
    private let name = "A&B.mov"

    @Test func presenceComposerKeepsTheRawAmpersand() {
        let citation = ArchivistEvidenceCitation(
            recordID: UUID(), fullPath: "/vol/\(name)", filename: name, playbackSeconds: nil,
            bases: [.keywordTokens(field: "filename", queryTerm: "a b", matchedTokens: ["a", "b"],
                                   alias: nil, matchedValue: name, timestamp: nil)])
        let result = ArchivistPresenceResult(
            conclusion: .present, interpretedQuery: "shape=presence keyword=a b",
            evidence: ArchivistEvidenceSet(citations: [citation], totalMatchCount: 1,
                                           isCitationListTruncated: false))
        let prose = ArchivistPresenceAnswerComposer.compose(result).prose
        #expect(prose.contains(name))
        #expect(!prose.contains("&amp;"))
    }

    @Test func transcriptEventRoundTripsTheRawAmpersand() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_hallie_amp_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Hallie")
        let store = HallieTranscriptFileStore(directoryURL: directory)
        let text = "The file is named \(name) [c1]."
        try store.append([HallieTranscriptEvent(
            timestamp: Date(timeIntervalSince1970: 1_786_838_400), sessionID: UUID(), eventID: UUID(),
            sequence: 1, client: .app, kind: .assistant, text: text, model: "fixture-model")])
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(files.count == 1)
        let raw = try String(contentsOf: files[0], encoding: .utf8)
        #expect(raw.contains(name), "JSONL must carry the literal '&'")
        #expect(!raw.contains("&amp;"))
        #expect(!raw.contains("\\u0026"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(HallieTranscriptEvent.self,
                                         from: Data(raw.trimmingCharacters(in: .newlines).utf8))
        #expect(decoded.text == text)
    }

    @Test func speechTextKeepsTheRawAmpersand() {
        let text = "The file is named \(name) [c1]."
        #expect(HallieSpeaker.spokenText(text) == text)
        #expect(HallieSpeaker.sentences(text) == ["The file is named \(name)."])
    }

    @Test func webPageEscapesOnlyAtRenderTime() {
        // The archivist's name lands in <title>/<meta>: escaped exactly once.
        let html = HallieWebPage.html(archivistName: "A&B")
        #expect(html.contains("<title>A&amp;B</title>"))
        #expect(!html.contains("&amp;amp;"))
        // Answer text is rendered with textContent — the browser shows the
        // raw string; nothing on the Swift side pre-escapes it.
        #expect(html.contains("d.textContent = text"))
        #expect(!html.contains("innerHTML = text"))
    }
}
