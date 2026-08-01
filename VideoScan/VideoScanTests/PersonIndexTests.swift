import Testing
import Foundation
@testable import VideoScan

// MARK: - Person index tests (archivist perf pass, 2026-08-01)
//
// The person inverted index + QueryPlan partition must be INVISIBLE
// semantically: `index.filter` must agree with the canonical
// per-record matcher on every people:-bearing query, including the
// substring subtleties ("people:don" → "donna") and the three source
// lists (detected / suspected / user-confirmed). These are the
// agreement sensors; ArchivistQueryBench pins the speed side.

@MainActor
private func makePeopleRecords() -> [VideoRecord] {
    func rec(_ path: String,
             detected: [String] = [],
             suspected: [String] = [],
             confirmed: [String] = [],
             year: String? = nil,
             stream: StreamType = .videoAndAudio) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = path
        r.filename = (path as NSString).lastPathComponent
        r.directory = (path as NSString).deletingLastPathComponent
        r.streamTypeRaw = stream.rawValue
        r.detectedPeople = detected
        r.suspectedPeople = suspected
        r.confirmedByUserPeople = confirmed.map {
            ConfirmedTag(name: $0, confirmedAt: Date(timeIntervalSince1970: 0))
        }
        if let year { r.filename = "\(year) \(r.filename)"; r.fullPath = r.directory + "/" + r.filename }
        return r
    }
    return [
        rec("/v/a/clip1.mov", detected: ["Donna"], year: "1992"),
        rec("/v/a/clip2.mov", suspected: ["donna"], year: "1994"),
        rec("/v/a/clip3.mov", confirmed: ["Dad Breen"], year: "1990"),
        rec("/v/a/clip4.mov", detected: ["Mark"], confirmed: ["Dan"]),
        rec("/v/a/clip5.mov", detected: ["Donna", "Dan"], year: "1995", stream: .videoOnly),
        rec("/v/a/clip6.mov"),                                   // nobody
        rec("/v/a/clip7.wav", confirmed: ["Donna"], stream: .audioOnly),
    ]
}

@MainActor
@Suite("Person index agreement + maintenance")
struct PersonIndexTests {

    /// Canonical truth: the pure per-record matcher over raw records.
    private func canonical(_ records: [VideoRecord], _ query: String) -> [String] {
        records.filter { pfRecordMatchesQuery($0, query: query) }.map(\.fullPath)
    }

    @Test func agreementWithCanonicalMatcherOnPeopleQueries() {
        let records = makePeopleRecords()
        let index = CatalogSearchIndex()
        index.rebuild(records: records)

        // Substring semantics, source-list coverage, mixed tokens,
        // provably-empty, multi-word names, case-insensitivity.
        let queries = [
            "people:donna", "people:Donna", "people:don", "people:dan",
            "people:dad", "people:breen", "people:zzz",
            "people:donna year:1990..1993",
            "people:donna type:video",
            "people:dan people:donna",
            "people:donna clip5",
            "people:d",
        ]
        for query in queries {
            let indexed = index.filter(records: records, query: query).map(\.fullPath)
            #expect(indexed == canonical(records, query),
                    "disagreement on '\(query)'")
            #expect(index.count(records: records, query: query) == indexed.count,
                    "count/filter disagree on '\(query)'")
        }
    }

    /// A provably-unknown person short-circuits to zero regardless of
    /// how broad the other tokens are.
    @Test func unknownPersonShortCircuits() {
        let records = makePeopleRecords()
        let index = CatalogSearchIndex()
        index.rebuild(records: records)
        #expect(index.filter(records: records, query: "people:nobody clip").isEmpty)
        #expect(index.count(records: records, query: "people:nobody") == 0)
    }

    /// The Inspector confirm → update() → people: searchable NOW.
    /// This is the tag-cultivation loop Rick uses daily; it must never
    /// require a rebuild or relaunch.
    @Test func updateMakesFreshTagSearchableAndRetractsRemoved() {
        let records = makePeopleRecords()
        let index = CatalogSearchIndex()
        index.rebuild(records: records)

        let target = records[5]   // clip6 — nobody
        #expect(index.filter(records: records, query: "people:timmy").isEmpty)

        target.confirmedByUserPeople.append(
            ConfirmedTag(name: "Timmy", confirmedAt: Date(timeIntervalSince1970: 1)))
        index.update(target)
        #expect(index.filter(records: records, query: "people:timmy").map(\.fullPath)
                == [target.fullPath])

        target.confirmedByUserPeople.removeAll()
        index.update(target)
        #expect(index.filter(records: records, query: "people:timmy").isEmpty)
    }

    @Test func removeDropsRecordFromPersonBuckets() {
        let records = makePeopleRecords()
        let index = CatalogSearchIndex()
        index.rebuild(records: records)
        index.remove(fullPath: records[0].fullPath)   // clip1 — Donna (detected)
        let hits = index.filter(records: records, query: "people:donna").map(\.fullPath)
        #expect(!hits.contains(records[0].fullPath))
        #expect(hits.count == 3)   // clip2 (suspected), clip5, clip7 remain
    }

    /// knownPeople(): family vocabulary, most-tagged first — the
    /// archivist's autocomplete/hint source.
    @Test func knownPeopleVocabularyAndCounts() {
        let index = CatalogSearchIndex()
        index.rebuild(records: makePeopleRecords())
        let vocab = index.knownPeople()
        #expect(vocab.first?.name == "donna")
        #expect(vocab.first?.count == 4)
        #expect(vocab.map(\.name).contains("dad breen"))
        #expect(vocab.map(\.name).contains("dan"))
    }

    /// Malformed v4 (missing "people" key — truncation/corruption) must
    /// REJECT, not load an empty person index: under QueryPlan an empty
    /// index is a provably-zero answer for every people: query, so
    /// acceptance would silently blank person search (codex #71).
    @Test func malformedV4WithoutPeopleKeyIsRejected() throws {
        let records = makePeopleRecords()
        let index = CatalogSearchIndex()
        index.rebuild(records: records)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("person-index-malformed-\(ProcessInfo.processInfo.processIdentifier).plist")
        defer { try? FileManager.default.removeItem(at: url) }
        try index.saveToDisk(at: url)

        var payload = try #require(PropertyListSerialization.propertyList(
            from: Data(contentsOf: url), format: nil) as? [String: Any])
        payload.removeValue(forKey: "people")
        try PropertyListSerialization.data(fromPropertyList: payload, format: .binary, options: 0)
            .write(to: url)

        let reloaded = CatalogSearchIndex()
        #expect(!reloaded.loadFromDisk(at: url, catalogModifiedAt: nil, expectedRecordCount: records.count))
        // Rejection must leave the index untouched (parse-then-commit).
        #expect(reloaded.recordCount() == 0)
    }

    /// A previous-version file (v3 — no person payload) must reject on
    /// the version gate, forcing the one rebuild that populates people.
    @Test func previousVersionFileIsRejected() throws {
        let records = makePeopleRecords()
        let index = CatalogSearchIndex()
        index.rebuild(records: records)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("person-index-v3-\(ProcessInfo.processInfo.processIdentifier).plist")
        defer { try? FileManager.default.removeItem(at: url) }
        try index.saveToDisk(at: url)

        var payload = try #require(PropertyListSerialization.propertyList(
            from: Data(contentsOf: url), format: nil) as? [String: Any])
        payload["version"] = CatalogSearchIndex.persistedVersion - 1
        try PropertyListSerialization.data(fromPropertyList: payload, format: .binary, options: 0)
            .write(to: url)

        let reloaded = CatalogSearchIndex()
        #expect(!reloaded.loadFromDisk(at: url, catalogModifiedAt: nil, expectedRecordCount: records.count))
    }

    /// v4 persistence round-trip: the person index must survive
    /// relaunch (load) with identical query behavior and vocabulary.
    @Test func persistenceRoundTripKeepsPersonIndex() throws {
        let records = makePeopleRecords()
        let index = CatalogSearchIndex()
        index.rebuild(records: records)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("person-index-roundtrip-\(ProcessInfo.processInfo.processIdentifier).plist")
        defer { try? FileManager.default.removeItem(at: url) }
        try index.saveToDisk(at: url)

        let reloaded = CatalogSearchIndex()
        #expect(reloaded.loadFromDisk(at: url, catalogModifiedAt: nil, expectedRecordCount: records.count))
        for query in ["people:donna", "people:don", "people:breen", "people:zzz"] {
            #expect(reloaded.filter(records: records, query: query).map(\.fullPath)
                    == index.filter(records: records, query: query).map(\.fullPath),
                    "reloaded index disagrees on '\(query)'")
        }
        #expect(reloaded.knownPeople().map(\.name) == index.knownPeople().map(\.name))
    }
}
