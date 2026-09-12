// UserPlaceTests.swift
// Hand-entered Place (Rick 2026-09-12) — five-dimension coverage, sized
// like UserDateTests:
//
//   - LOGIC: canonicalizer table (accept + reject), idempotence, town-of,
//     the EXACT-match rule, derived-status truth table, best-place
//     resolution (Rick's place is the only place → userPlace), roster
//     ordering (frequency then name), the "No place yet" predicate, the
//     Show-row words, CSV columns.
//   - CODABLE: legacy catalog JSON (no userPlace keys) decodes to nil and
//     re-encodes byte-identical with ZERO new keys; populated fields
//     survive DTO encode → class decode → clone.
//   - ISOLATION: entering/saving a place writes nothing to UserDefaults.
//   - SCALE: roster computation and the place-prefix search over 100k
//     synthetic records with explicit time budgets.
//   - SENSOR: `placeFieldSearchIsExactNotSubstringOfTranscript` — a
//     transcript that says "cape cod" must NOT satisfy a `place:` search;
//     that is the whole point of the field.
//
// Media matrix: not applicable (no probing).

import Testing
import Foundation
@testable import VideoScan

@Suite struct UserPlaceEntryTests {

    // MARK: Logic — acceptance table

    @Test("lenient entry forms normalize to canonical display form",
          arguments: [
            ("franklin, ma",        "Franklin, MA"),     // Rick's example
            ("Franklin, MA",        "Franklin, MA"),
            ("FRANKLIN, MA",        "Franklin, MA"),
            ("franklin,ma",         "Franklin, MA"),     // no space after comma
            ("franklin , ma",       "Franklin, MA"),     // space before comma
            ("cape cod",            "Cape Cod"),         // Rick's example
            ("  cape   cod ",       "Cape Cod"),         // whitespace collapsed
            ("Montana",             "Montana"),          // stays
            ("montana",             "Montana"),
            ("nh",                  "NH"),               // bare state code
            ("NH",                  "NH"),
            ("framingham ma",       "Framingham MA"),    // no comma: the state code still uppercases
            ("westford",            "Westford"),
            ("wilkes-barre, pa",    "Wilkes-Barre, PA"), // hyphenated town
            ("north conway, nh",    "North Conway, NH"),
            ("McGill's Farm",       "McGill's Farm"),    // mixed case kept
            ("usa",                 "Usa"),              // not a state code; plain word
            ("USA",                 "USA"),              // short all-caps kept
            ("cork, ireland",       "Cork, Ireland"),    // trailing segment longer than 2 → Title Case
            ("Cape Cod, MA, USA",   "Cape Cod, MA, USA"),// middle MA via the state rule, trailing USA kept
            ("cape\ncod",           "Cape Cod"),         // newline is whitespace
          ])
    func acceptedForms(input: String, expected: String) {
        #expect(UserPlaceEntry.canonicalize(input) == expected)
    }

    // MARK: Logic — rejection table

    @Test("empty and punctuation-only input is rejected",
          arguments: ["", "   ", "\n\t", ",", " , ", ",,,"])
    func rejectedForms(input: String) {
        #expect(UserPlaceEntry.canonicalize(input) == nil,
                "'\(input)' should have been rejected")
    }

    @Test("canonical output is a fixed point of the normalizer")
    func canonicalIdempotence() {
        for canonical in ["Franklin, MA", "Cape Cod", "Montana", "NH",
                          "Wilkes-Barre, PA", "McGill's Farm", "Cape Cod, MA, USA"] {
            #expect(UserPlaceEntry.canonicalize(canonical) == canonical)
        }
    }

    @Test("town(of:) is everything before the first comma")
    func townOf() {
        #expect(UserPlaceEntry.town(of: "Franklin, MA") == "Franklin")
        #expect(UserPlaceEntry.town(of: "Cape Cod") == "Cape Cod")
        #expect(UserPlaceEntry.town(of: "Cape Cod, MA, USA") == "Cape Cod")
        #expect(UserPlaceEntry.town(of: "NH") == "NH")
    }

    // MARK: Logic — the exact-match rule

    @Test("matches: whole phrase or town-only, case-insensitive, never substring",
          arguments: [
            ("Franklin, MA",   "franklin, ma",  true),   // whole phrase, any case
            ("Franklin, MA",   "Franklin",      true),   // town-only
            ("Franklin, MA",   "franklin",      true),
            ("Franklin, MA",   "Frank",         false),  // substring is NOT a match
            ("Franklin, MA",   "MA",            false),  // state alone is not the place
            ("Cape Cod",       "cape cod",      true),
            ("Cape Cod",       "Cod",           false),
            ("Cape Cod",       "Cape",          false),
            ("Cape Cod, MA",   "Cape Cod",      true),
            ("Montana",        "montana",       true),
            ("Montana",        "Mont",          false),
            ("NH",             "nh",            true),
            ("Franklin, MA",   "",              false),  // empty query never matches
          ])
    func exactMatchRule(canonical: String, query: String, expected: Bool) {
        #expect(UserPlaceEntry.matches(query, against: canonical) == expected,
                "'\(query)' vs '\(canonical)'")
    }
}

@Suite(.serialized) @MainActor
struct UserPlaceRecordTests {

    private static func goldenEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    /// A minimal legacy-shaped record (no userPlace keys anywhere).
    private static let legacyJSON = #"""
        {"id":"11111111-2222-3333-4444-555555555555","filename":"tape7.mkv",
         "ext":"mkv","streamTypeRaw":"Video+Audio","sizeBytes":107374182400,
         "durationSeconds":7205.5,"videoCodec":"ffv1","fullPath":"/Volumes/T/tape7.mkv",
         "directory":"/Volumes/T","userDate":"1992","userDateConfidence":"known"}
        """#

    // MARK: Logic — derived status truth table

    @Test("status derives from the two stored fields and nothing else")
    func statusTruthTable() {
        let rec = VideoRecord()
        rec.userPlace = nil; rec.userPlaceConfidence = nil
        #expect(rec.userPlaceStatus == .unplaced)

        // Confidence without a place is meaningless — still unplaced.
        rec.userPlace = nil; rec.userPlaceConfidence = "known"
        #expect(rec.userPlaceStatus == .unplaced)
        #expect(rec.userPlaceConfidenceValue == nil)

        rec.userPlace = "Cape Cod"; rec.userPlaceConfidence = "estimated"
        #expect(rec.userPlaceStatus == .estimated)

        rec.userPlace = "Cape Cod"; rec.userPlaceConfidence = "known"
        #expect(rec.userPlaceStatus == .known)

        // Missing / unrecognized confidence → conservative "estimated".
        rec.userPlace = "Cape Cod"; rec.userPlaceConfidence = nil
        #expect(rec.userPlaceStatus == .estimated)
        rec.userPlace = "Cape Cod"; rec.userPlaceConfidence = "positive!!"
        #expect(rec.userPlaceStatus == .estimated)
    }

    // MARK: Logic — best-place resolution

    @Test("Rick's place is the only place: display, sort key, help")
    func resolution() {
        let rec = VideoRecord()
        rec.audioTranscript = "we drove down to cape cod that summer"   // never a place
        #expect(rec.resolvedPlaceDisplay.isEmpty)
        #expect(rec.resolvedPlaceSortKey == "")
        #expect(rec.resolvedPlaceHelp.hasPrefix("No place yet"))

        rec.userPlace = "Franklin, MA"; rec.userPlaceConfidence = "estimated"
        #expect(rec.resolvedPlaceDisplay == "Franklin, MA (est.)")
        #expect(rec.resolvedPlaceSortKey == "franklin, ma")
        #expect(rec.resolvedPlaceHelp.contains("best guess"))

        rec.userPlaceConfidence = "known"
        #expect(rec.resolvedPlaceDisplay == "Franklin, MA")
        #expect(rec.resolvedPlaceHelp.contains("known"))
    }

    // MARK: Codable — additive-only, legacy byte identity

    @Test func legacyJSONDecodesWithNilUserPlaceFields() throws {
        let record = try JSONDecoder().decode(VideoRecord.self, from: Data(Self.legacyJSON.utf8))
        #expect(record.userPlace == nil)
        #expect(record.userPlaceConfidence == nil)
        #expect(record.userPlaceStatus == .unplaced, "absent fields derive to unplaced — no backfill")
        #expect(record.userDate == "1992", "the date beside it still decodes")
    }

    @Test func legacyRecordReencodesWithoutUserPlaceKeys() throws {
        let record = try JSONDecoder().decode(VideoRecord.self, from: Data(Self.legacyJSON.utf8))
        let encoded = String(decoding: try Self.goldenEncoder().encode(VideoRecordDTO(record)), as: UTF8.self)
        #expect(!encoded.contains("userPlace"),
                "userPlace keys leaked into a legacy record's JSON — additive-only contract broken")
        let second = try JSONDecoder().decode(VideoRecord.self, from: Data(encoded.utf8))
        let reencoded = String(decoding: try Self.goldenEncoder().encode(VideoRecordDTO(second)), as: UTF8.self)
        #expect(reencoded == encoded, "legacy record no longer round-trips byte-identical")
    }

    @Test func populatedUserPlaceRoundTripsThroughDTOAndClone() throws {
        let record = try JSONDecoder().decode(VideoRecord.self, from: Data(Self.legacyJSON.utf8))
        record.userPlace = "Cape Cod"
        record.userPlaceConfidence = "known"

        let encoded = try Self.goldenEncoder().encode(VideoRecordDTO(record))
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(text.contains(#""userPlace":"Cape Cod""#))
        #expect(text.contains(#""userPlaceConfidence":"known""#))
        let decoded = try JSONDecoder().decode(VideoRecord.self, from: encoded)
        #expect(decoded.userPlace == "Cape Cod")
        #expect(decoded.userPlaceConfidence == "known")
        #expect(decoded.userPlaceStatus == .known)

        let clone = record.snapshotClone()
        #expect(clone.userPlace == "Cape Cod")
        #expect(clone.userPlaceConfidence == "known")
    }

    // MARK: Isolation — no UserDefaults writes

    @Test func enteringAUserPlaceWritesNoDefaults() throws {
        let keysBefore = Set(UserDefaults.standard.dictionaryRepresentation().keys)
        let record = try JSONDecoder().decode(VideoRecord.self, from: Data(Self.legacyJSON.utf8))
        let canonical = try #require(UserPlaceEntry.canonicalize("franklin, ma"))
        record.userPlace = canonical
        record.userPlaceConfidence = UserPlaceConfidence.estimated.rawValue
        _ = try Self.goldenEncoder().encode(VideoRecordDTO(record))
        _ = record.resolvedPlaceDisplay
        _ = record.resolvedPlaceSortKey
        _ = UserPlaceRoster.compute(records: [record])
        let added = Set(UserDefaults.standard.dictionaryRepresentation().keys).subtracting(keysBefore)
        #expect(added.isEmpty, "user-place path polluted UserDefaults with: \(added.sorted())")
    }
}

@Suite @MainActor
struct UserPlaceRosterTests {

    private func placed(_ place: String?) -> VideoRecord {
        let r = VideoRecord()
        r.userPlace = place
        r.userPlaceConfidence = place == nil ? nil : "estimated"
        return r
    }

    @Test("roster is empty until Rick types a place — nothing is seeded")
    func nothingSeeded() {
        #expect(UserPlaceRoster.compute(records: []).isEmpty)
        #expect(UserPlaceRoster.compute(records: [placed(nil), placed(nil)]).isEmpty)
    }

    @Test("roster orders by frequency, then name; unplaced records are skipped")
    func ordering() {
        let records = [
            placed("Cape Cod"), placed("Cape Cod"), placed("Cape Cod"),
            placed("Franklin, MA"), placed("Franklin, MA"),
            placed("Westford"), placed("Westford"),
            placed("Ashland"),
            placed("Montana"),
            placed(nil), placed(nil),
        ]
        let roster = UserPlaceRoster.compute(records: records)
        #expect(roster.places == ["Cape Cod", "Franklin, MA", "Westford", "Ashland", "Montana"])
        #expect(roster.entries.first?.count == 3)
        #expect(roster.entries.map(\.count) == [3, 2, 2, 1, 1])
    }

    @Test("name tie-break is case-insensitive and stable")
    func tieBreak() {
        let roster = UserPlaceRoster.compute(records: [placed("montana"), placed("Ashland"), placed("cape Cod")])
        #expect(roster.places == ["Ashland", "cape Cod", "montana"])
    }

    @Test("scale: roster over 100k records within budget", .timeLimit(.minutes(1)))
    func scale100k() {
        let pool = ["Franklin, MA", "Framingham, MA", "Ashland", "Westford", "North Conway, NH",
                    "Montana", "Cape Cod", "Boston, MA", "Hyannis, MA", "Provincetown, MA"]
        var records: [VideoRecord] = []
        records.reserveCapacity(100_000)
        for i in 0..<100_000 {
            // Half unplaced; the other half skewed so the order is decided:
            // pool[0] 30%, pool[1] 20%, the rest ~6% each.
            let r = VideoRecord()
            if i % 2 == 0 {
                let k = (i / 2) % 100
                let idx = k < 30 ? 0 : (k < 50 ? 1 : 2 + (k % 8))
                r.userPlace = pool[idx]
                r.userPlaceConfidence = "estimated"
            }
            records.append(r)
        }
        let clock = ContinuousClock()
        var roster = UserPlaceRoster()
        let elapsed = clock.measure {
            roster = UserPlaceRoster.compute(records: records)
        }
        #expect(roster.entries.count == pool.count)
        #expect(roster.entries.reduce(0) { $0 + $1.count } == 50_000)
        #expect(roster.entries.first?.place == "Franklin, MA", "the skew puts index 0 first")
        // Tighter than the 1-minute suite guard: two linear passes and a
        // sort of ten entries. An accidental O(n²) or per-record
        // allocation storm blows past this by an order of magnitude.
        #expect(elapsed < .seconds(2), "roster took \(elapsed) for 100k records")
    }
}

@Suite @MainActor
struct UserPlaceCatalogTests {

    private func record(place: String?, transcript: String? = nil, filename: String = "clip.mov") -> VideoRecord {
        let r = VideoRecord()
        r.filename = filename
        r.fullPath = "/Volumes/T/\(filename)"
        r.directory = "/Volumes/T"
        r.userPlace = place
        r.userPlaceConfidence = place == nil ? nil : "estimated"
        r.audioTranscript = transcript
        return r
    }

    // MARK: "No place yet" filter

    @Test("No place yet predicate follows the derived status")
    func noPlaceYetPredicate() {
        #expect(pfRecordHasNoPlace(record(place: nil)))
        #expect(!pfRecordHasNoPlace(record(place: "Cape Cod")))
        #expect(CatalogViewFilter.allCases.contains(.noPlaceYet))
        #expect(CatalogShowingSummary.words(for: .noPlaceYet) == "No place yet")
        #expect(CatalogViewFilter(rawValue: "No Place Yet") == .noPlaceYet, "persisted filter round trip")
    }

    // MARK: Plain search matches the place (substring, like tags/notes)

    @Test("catalog-bar and universal search find rows by place substring")
    func plainSearchMatchesPlace() {
        let rec = record(place: "Cape Cod")
        #expect(pfCatalogTokenMatches(.substring("cape"), rec))
        #expect(pfCatalogTokenMatches(.substring("cape cod"), rec))
        #expect(!pfCatalogTokenMatches(.substring("montana"), rec))
        #expect(pfRecordMatchesQuery(rec, query: "cod"))
        #expect(CatalogSearchIndex.buildHaystack(rec).contains("cape cod"),
                "haystack must stay aligned with the substring matcher")
        #expect(!CatalogSearchIndex.buildHaystack(record(place: nil)).contains("cape"))
    }

    // MARK: `place:` prefix — the exact rule

    @Test("place: prefix parses under three spellings")
    func placePrefixParses() {
        #expect(SearchField.parse("place") == .place)
        #expect(SearchField.parse("where") == .place)
        #expect(SearchField.parse("location") == .place)
    }

    @Test("place: prefix is exact — whole phrase or town-only, never substring")
    func placePrefixExact() {
        let rec = record(place: "Franklin, MA")
        #expect(pfFieldTokenMatches(.place, "franklin", rec))
        #expect(pfFieldTokenMatches(.place, "franklin, ma", rec))
        #expect(pfFieldTokenMatches(.place, "FRANKLIN", rec))
        #expect(!pfFieldTokenMatches(.place, "frank", rec))
        #expect(!pfFieldTokenMatches(.place, "ma", rec))
        #expect(pfRecordMatchesQuery(rec, query: "place:franklin"))
        #expect(!pfRecordMatchesQuery(rec, query: "place:frank"))
        #expect(!pfFieldTokenMatches(.place, "franklin", record(place: nil)))
    }

    // SENSOR (2026-09-12): the whole point of the field. A transcript
    // that SAYS "cape cod" is not a place. `place:` consults userPlace
    // only; plain search still finds the transcript, as it always did.
    @Test func placeFieldSearchIsExactNotSubstringOfTranscript() {
        let saidIt = record(place: nil, transcript: "we drove down to cape cod that summer",
                            filename: "CapeCod1997.mov")
        let placedThere = record(place: "Cape Cod", filename: "tape12.mov")
        #expect(!pfFieldTokenMatches(.place, "cape cod", saidIt),
                "a transcript mention must NOT satisfy a place search")
        #expect(!pfRecordMatchesQuery(saidIt, query: "place:cape"))
        #expect(pfFieldTokenMatches(.place, "cape cod", placedThere))
        #expect(pfRecordMatchesQuery(saidIt, query: "cape"), "plain search still finds the transcript/filename")
        // Query-level, single-word (the tokenizer has no quoted field
        // values — pre-existing; multi-word places go through plain
        // search): the transcript-only row must not surface.
        let saidFranklin = record(place: nil, transcript: "back in franklin for the parade", filename: "parade.mov")
        let placedFranklin = record(place: "Franklin, MA", filename: "tape13.mov")
        let hits = pfRecordsMatchingQuery([saidIt, placedThere, saidFranklin, placedFranklin],
                                          query: "where:franklin")
        #expect(hits.map(\.filename) == ["tape13.mov"])
    }

    @Test("scale: place: prefix over 100k records within budget", .timeLimit(.minutes(1)))
    func placePrefixScale100k() {
        var records: [VideoRecord] = []
        records.reserveCapacity(100_000)
        for i in 0..<100_000 {
            let r = VideoRecord()
            r.audioTranscript = "cape cod"   // every row SAYS it; only a third IS it
            switch i % 3 {
            case 0: r.userPlace = "Cape Cod"; r.userPlaceConfidence = "known"
            case 1: r.userPlace = "Franklin, MA"; r.userPlaceConfidence = "estimated"
            default: break
            }
            records.append(r)
        }
        let clock = ContinuousClock()
        var hits = 0
        let elapsed = clock.measure {
            for r in records where pfFieldTokenMatches(.place, "cape cod", r) { hits += 1 }
        }
        #expect(hits == 33_334, "exactly the placed rows, none of the transcript-only rows")
        #expect(elapsed < .seconds(3), "place: match took \(elapsed) for 100k records")
    }

    // MARK: CSV

    @Test("CSV carries Place + Place Confidence before Notes, which stays last")
    func csvColumns() {
        let h = CatalogCSVWriter.headers
        #expect(h.suffix(3) == ["Place", "Place Confidence", "Notes"])
        let rec = record(place: "Franklin, MA")
        rec.userPlaceConfidence = "known"
        rec.notes = "n"
        let row = CatalogCSVWriter.row(for: rec).components(separatedBy: ",")
        // "Franklin, MA" is quoted (it contains a comma) — check the tail.
        #expect(CatalogCSVWriter.row(for: rec).hasSuffix("\"Franklin, MA\",known,n"))
        #expect(row.count == h.count + 1, "one extra split from the comma inside the quoted place")
        let bare = CatalogCSVWriter.row(for: record(place: nil))
        #expect(bare.hasSuffix(",,"), "unplaced → two empty cells before an empty Notes")
    }
}
