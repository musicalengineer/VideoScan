// ImportSidecarsJSONTests.swift
// Bug 1 (Rick's first dry run, 2026-10-17 17:52:41): the importer's audit
// result words were the contract's shorthand (present / gone / neverSeen /
// couldNotCheck / changed / link); the app writes `CatalogAuditResult`'s raw
// words (present / changed / gone / cameBack / stillMissing / goneArchived /
// neverSeenByAnAudit / couldNotCheck / recordChanged). 360 of Rick's rows
// were refused as "a word this importer does not know".
//   LOGIC     — every app word parses, maps to its gate class, and the N1
//               judged-path rule applies to the mapped class; `couldNotCheck`
//               whose detail names a link is the `link` class.
//   ISOLATION — a word outside the app's set (including the old shorthand)
//               still refuses the run naming ordinal + word (codex D′ #4).
//   SENSOR    — the app side (VideoScanTests/ImportAuditVocabularySensorTests)
//               pins `knownResultWords` == CatalogAuditResult's per-row cases.
// One condition per #expect.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("AuditMarkerJSON — the words the app writes")
struct AuditMarkerJSONTests {

    /// One app word with a detail the app really writes and the gate class it must become.
    struct Word: CustomTestStringConvertible, Sendable {
        let word: String
        let detail: String?
        let gateClass: CatalogDDL.AuditResult
        var testDescription: String { "\(word) → \(gateClass.rawValue)" }
    }

    static let linkDetail = "not at its path, but that is not proof here: a link in the path — not provable — not marked"

    static let appWords: [Word] = [
        Word(word: "present", detail: nil, gateClass: .present),
        Word(word: "cameBack", detail: "the file is back — live again", gateClass: .present),
        Word(word: "changed", detail: "on disk 1 KB, the catalog says 2 KB", gateClass: .changed),
        Word(word: "recordChanged", detail: "changed in the catalog meanwhile", gateClass: .changed),
        Word(word: "gone", detail: "not at its path — marked Missing", gateClass: .gone),
        Word(word: "stillMissing", detail: "already marked Missing (2 days ago)", gateClass: .gone),
        Word(word: "goneArchived", detail: "archived copy gone (reported, not marked)", gateClass: .gone),
        Word(word: "neverSeenByAnAudit", detail: "not at its path, never seen by an audit (not marked — Fix Links decides)", gateClass: .neverSeen),
        Word(word: "couldNotCheck", detail: "stat failed: EIO", gateClass: .couldNotCheck),
        Word(word: "couldNotCheck", detail: linkDetail, gateClass: .link),
    ]

    static let rowID = "00000000-0000-4000-8000-0000000000AA"
    static let rowPath = "/Volumes/Fixture/Clips/row.mov"

    static func marker(_ rows: [AuditMarkerJSON.Row]) -> AuditMarkerJSON {
        var counts: [String: Int] = [:]
        for r in rows { counts[r.result, default: 0] += 1 }
        return AuditMarkerJSON(startedAt: CatalogJSONDate(unixSeconds: 1_000), finishedAt: CatalogJSONDate(unixSeconds: 2_000),
                               outcome: "completed", partial: false, counts: counts, marked: 0, rows: rows, savedGeneration: 41)
    }

    static func row(_ w: Word, judgedPath: String? = rowPath) -> AuditMarkerJSON.Row {
        AuditMarkerJSON.Row(id: rowID, result: w.word, detail: w.detail, judgedPath: w.gateClass == .present ? nil : judgedPath)
    }

    // MARK: - Logic

    @Test("every word the app writes is a known word", arguments: appWords)
    func everyAppWordIsKnown(w: Word) {
        #expect(Self.marker([Self.row(w)]).unknownResultWords.isEmpty)
    }

    @Test("every app word maps to its gate class", arguments: appWords)
    func everyAppWordMapsToItsClass(w: Word) {
        #expect(Self.marker([Self.row(w)]).evidenceByID()[Self.rowID]?.result == w.gateClass)
    }

    @Test("a non-present app word without a judged path is an N1 fault (the mapped class decides)", arguments: appWords.filter { $0.gateClass != .present })
    func aNonPresentAppWordNeedsAJudgedPath(w: Word) {
        #expect(RowPreflight.violations(auditRow: Self.row(w, judgedPath: nil)).count == 1)
    }

    @Test("a present-class app word needs no judged path", arguments: appWords.filter { $0.gateClass == .present })
    func aPresentClassWordNeedsNoJudgedPath(w: Word) {
        #expect(RowPreflight.violations(auditRow: Self.row(w, judgedPath: nil)).isEmpty)
    }

    @Test func aCouldNotCheckWhoseDetailNamesALinkIsTheLinkClass() {
        let link = Word(word: "couldNotCheck", detail: "symlink in the path", gateClass: .link)
        #expect(Self.marker([Self.row(link)]).evidenceByID()[Self.rowID]?.result == .link)
    }

    @Test func aCouldNotCheckWithoutADetailIsCouldNotCheck() {
        let plain = Word(word: "couldNotCheck", detail: nil, gateClass: .couldNotCheck)
        #expect(Self.marker([Self.row(plain)]).evidenceByID()[Self.rowID]?.result == .couldNotCheck)
    }

    @Test func theMarkerInTheAppsExactShapeDecodes() throws {
        let json = """
        {"counts":{"gone":1,"planned":2,"present":1},"finishedAt":"2026-10-16T02:01:00Z","marked":1,"outcome":"completed",
         "partial":false,"rows":[{"id":"\(Self.rowID)","result":"present"},
         {"detail":"not at its path — marked Missing","id":"00000000-0000-4000-8000-0000000000AB","result":"gone",
          "seenOn":{"deviceKey":"k","mountFrom":"/dev/disk9s1","seenAt":"2026-10-16T02:00:30Z","volumeUUID":"ABC"}}],
         "startedAt":"2026-10-16T02:00:00Z"}
        """
        let marker = try AuditMarkerJSON.decode(Data(json.utf8))
        #expect(marker.facts.hasRowResults)
        #expect(marker.unknownResultWords.isEmpty)
        #expect(marker.rows?[1].seenOn?.volumeUUID == "ABC")
        // 2026-10-16T02:00:00Z / 02:01:00Z
        #expect(marker.window == ImportGate.AuditWindow(startedAt: 1_792_116_000, finishedAt: 1_792_116_060))
    }

    // MARK: - Isolation: strictness stays

    @Test("a word outside the app's set refuses the run naming ordinal and word", arguments: ["vanished", "neverSeen", "link", "Present", ""])
    func anUnknownWordRefusesTheRun(word: String) {
        let present = AuditMarkerJSON.Row(id: Self.rowID, result: "present")
        let marker = Self.marker([present, AuditMarkerJSON.Row(id: "00000000-0000-4000-8000-0000000000AB", result: word, judgedPath: Self.rowPath)])
        #expect(marker.unknownResultWords == [2: word])
    }

    @Test func anUnknownWordIsARunLevelRefusalWithTheOrdinalAndTheWord() {
        let marker = Self.marker([AuditMarkerJSON.Row(id: Self.rowID, result: "vanished", judgedPath: Self.rowPath)])
        let run = ImportGate.RunInput(catalogVersion: 6, catalogGeneration: 41, catalogSHA256: "", report: nil, audit: marker.facts)
        #expect(ImportGate.auditRefusals(run).contains(.auditResultUnknownWord(ordinal: 1, word: "vanished")))
    }

    @Test func anUnknownWordIsNotEvidence() {
        let marker = Self.marker([AuditMarkerJSON.Row(id: Self.rowID, result: "vanished", judgedPath: Self.rowPath)])
        #expect(marker.evidenceByID().isEmpty)
    }
}
