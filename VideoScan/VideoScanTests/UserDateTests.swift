// UserDateTests.swift
// Estimated Date (GH #117 v1) — five-dimension coverage, sized for v1:
//
//   - LOGIC: lenient-entry parse table (accept + reject), canonical
//     idempotence, Julian-day date(from:) cross-checked against
//     Calendar, derived-status truth table, best-date resolution
//     ranking (user > inferred > container > nothing).
//   - CODABLE: legacy catalog JSON (no userDate keys) decodes to nil
//     and re-encodes byte-identical with ZERO new keys (the
//     encodeIfPresent discipline — same pattern as TrimProvenanceTests);
//     populated fields survive DTO encode → class decode → clone.
//   - ISOLATION: entering/saving a user date writes nothing to
//     UserDefaults (the documented settings-pollution class).
//   - SCALE + SENSOR: resolvedDateSortKey/Display back a table column,
//     so both are exercised over 100k synthetic records with an
//     explicit time budget, pinning "user estimate outranks container
//     date" and "absent fields = unconfirmed" at production scale.
//
// Search facets (`c.1992`, `date:unconfirmed`) are v2 — no index tests.

import Testing
import Foundation
@testable import VideoScan

@Suite struct UserDateParserTests {

    // MARK: Logic — acceptance table

    @Test("lenient entry forms normalize to canonical reduced ISO",
          arguments: [
            ("1992",        "1992"),
            (" 1992 ",      "1992"),            // whitespace trimmed
            ("6/1992",      "1992-06"),         // US month/year
            ("06/1992",     "1992-06"),
            ("12/1992",     "1992-12"),
            ("6/14/1992",   "1992-06-14"),      // US month/day/year
            ("6/1/1992",    "1992-06-01"),
            ("12/31/1949",  "1949-12-31"),      // 1940s footage exists
            ("2/29/1992",   "1992-02-29"),      // leap day, leap year
            ("2/29/2000",   "2000-02-29"),      // century leap (÷400)
            ("1992-06",     "1992-06"),         // ISO passthrough
            ("1992-6",      "1992-06"),         // ISO, padding optional
            ("1992-06-14",  "1992-06-14"),
            ("1992-6-4",    "1992-06-04"),
          ])
    func acceptedForms(input: String, expected: String) {
        #expect(UserDateEntry.canonicalize(input) == expected)
    }

    // MARK: Logic — rejection table

    @Test("garbage and impossible dates are rejected",
          arguments: [
            "",                 // empty is the UI's "clear", not a date
            "banana",
            "circa 1992",
            "92",               // 2-digit year — ambiguous, refuse
            "992",              // 3-digit year
            "19923",            // 5 digits
            "-1992",            // signs are not dates
            "13/1992",          // month 13
            "0/1992",           // month 0
            "6/0/1992",         // day 0
            "6/32/1992",        // day 32
            "2/30/1991",        // Feb 30
            "2/29/1991",        // Feb 29, non-leap year
            "2/29/1900",        // century non-leap (÷100, not ÷400)
            "14/6/1992",        // day/month order — refuse, don't guess
            "6/14/92",          // 2-digit year in full form
            "1992-13",          // ISO month 13
            "1992-00",          // ISO month 0
            "1992-04-31",       // April 31
            "1992/06",          // slash form must be M/yyyy
            "06-1992",          // ISO must lead with 4-digit year
            "992-06",           // short year in ISO form
            "1992-06-14-3",     // too many components
            "6//1992",          // empty component
            "1992-",            // trailing separator
            "6/14/1992 pm",     // trailing junk
            "1992-06/14",       // mixed separators
          ])
    func rejectedForms(input: String) {
        #expect(UserDateEntry.canonicalize(input) == nil,
                "'\(input)' should have been rejected")
    }

    @Test("canonical output is a fixed point of the parser")
    func canonicalIdempotence() {
        for canonical in ["1992", "1992-06", "1992-06-14", "1949-12-31", "2000-02-29"] {
            #expect(UserDateEntry.canonicalize(canonical) == canonical)
        }
    }

    // MARK: Logic — Julian-day date(from:) vs Calendar oracle

    @Test("period-start dates agree with Calendar for every precision")
    func dateFromCanonicalMatchesCalendar() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try #require(TimeZone(identifier: "UTC"))
        // (canonical, expected y/m/d of the period start)
        let cases: [(String, Int, Int, Int)] = [
            ("1992",       1992, 1, 1),
            ("1992-06",    1992, 6, 1),
            ("1992-06-14", 1992, 6, 14),
            ("1949-12-31", 1949, 12, 31),
            ("2000-02-29", 2000, 2, 29),
            ("1900-03-01", 1900, 3, 1),   // straddles the century non-leap
        ]
        for (canonical, y, m, d) in cases {
            let got = try #require(UserDateEntry.date(from: canonical),
                                   "'\(canonical)' should produce a date")
            var dc = DateComponents()
            (dc.year, dc.month, dc.day) = (y, m, d)
            let oracle = try #require(cal.date(from: dc))
            #expect(got == oracle,
                    "'\(canonical)': Julian-day math (\(got)) diverged from Calendar (\(oracle))")
        }
        #expect(UserDateEntry.date(from: "not-a-date") == nil)
    }

    // MARK: Logic — derived status truth table

    @Test("status derives from the two stored fields and nothing else")
    func statusTruthTable() {
        let rec = VideoRecord()

        // (userDate, confidence) → status
        rec.userDate = nil; rec.userDateConfidence = nil
        #expect(rec.userDateStatus == .unconfirmed)

        // Confidence without a date is meaningless — still unconfirmed.
        rec.userDate = nil; rec.userDateConfidence = "known"
        #expect(rec.userDateStatus == .unconfirmed)
        #expect(rec.userDateConfidenceValue == nil)

        rec.userDate = "1992"; rec.userDateConfidence = "estimated"
        #expect(rec.userDateStatus == .estimated)

        rec.userDate = "1992"; rec.userDateConfidence = "known"
        #expect(rec.userDateStatus == .known)

        // Date with missing/unrecognized confidence → conservative
        // "estimated" (matches the entry UI's default).
        rec.userDate = "1992"; rec.userDateConfidence = nil
        #expect(rec.userDateStatus == .estimated)
        rec.userDate = "1992"; rec.userDateConfidence = "positive!!"
        #expect(rec.userDateStatus == .estimated)
    }

    // MARK: Logic — best-date resolution ranking

    @Test("user date (either confidence) outranks inferred, which outranks container")
    func resolutionRanking() throws {
        let rec = VideoRecord()
        let containerDate = Date(timeIntervalSince1970: 1_700_000_000)  // 2023 — transfer date
        let inferredDate = Date(timeIntervalSince1970: 800_000_000)     // 1995 — OCR consensus
        rec.dateCreatedRaw = containerDate
        rec.dateCreated = "2023-11-14"

        // Nothing but the file date → container wins, display = raw string.
        #expect(rec.resolvedDateSortKey == containerDate)
        #expect(rec.resolvedDateDisplay == "2023-11-14")

        // Inferred beats container.
        rec.inferredRecordDate = inferredDate
        #expect(rec.resolvedDateSortKey == inferredDate)
        #expect(rec.resolvedDateDisplay.hasPrefix("1995-"))

        // Rick's ESTIMATE beats both machine dates (the
        // 2026-on-a-VHS-conversion case).
        rec.userDate = "1992"
        rec.userDateConfidence = "estimated"
        let userStart = try #require(UserDateEntry.date(from: "1992"))
        #expect(rec.resolvedDateSortKey == userStart)
        #expect(rec.resolvedDateDisplay == "1992 (est.)")

        // Known renders bare, same ranking.
        rec.userDateConfidence = "known"
        #expect(rec.resolvedDateSortKey == userStart)
        #expect(rec.resolvedDateDisplay == "1992")

        // No signals at all → distant past, em-dash-able empty display.
        let empty = VideoRecord()
        #expect(empty.resolvedDateSortKey == .distantPast)
        #expect(empty.resolvedDateDisplay.isEmpty)
        #expect(empty.userDateStatus == .unconfirmed)
    }
}

@Suite(.serialized) @MainActor
struct UserDateProvenanceTests {

    /// Deterministic encoder — same rationale as CatalogStoreAsyncSaveTests.
    private static func goldenEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    /// A minimal legacy-shaped record: captured from the pre-#117 schema
    /// (no userDate / userDateConfidence keys anywhere).
    private static let legacyJSON = #"""
        {"id":"11111111-2222-3333-4444-555555555555","filename":"tape7.mkv",
         "ext":"mkv","streamTypeRaw":"Video+Audio","sizeBytes":107374182400,
         "durationSeconds":7205.5,"videoCodec":"ffv1","fullPath":"/Volumes/T/tape7.mkv",
         "directory":"/Volumes/T","derivedFrom":"99999999-9999-9999-9999-999999999999"}
        """#

    // MARK: Codable — additive-only, legacy byte identity

    @Test func legacyJSONDecodesWithNilUserDateFields() throws {
        let record = try JSONDecoder().decode(VideoRecord.self,
                                              from: Data(Self.legacyJSON.utf8))
        #expect(record.userDate == nil)
        #expect(record.userDateConfidence == nil)
        #expect(record.userDateStatus == .unconfirmed,
                "absent fields must derive to unconfirmed — no backfill")
        // Sanity: the rest of the record decoded normally.
        #expect(record.filename == "tape7.mkv")
    }

    @Test func legacyRecordReencodesWithoutUserDateKeys() throws {
        let record = try JSONDecoder().decode(VideoRecord.self,
                                              from: Data(Self.legacyJSON.utf8))
        let encoded = String(decoding: try Self.goldenEncoder()
            .encode(VideoRecordDTO(record)), as: UTF8.self)
        #expect(!encoded.contains("userDate"),
                "userDate keys leaked into a legacy record's JSON — additive-only contract broken")
        #expect(!encoded.contains("userDateConfidence"))

        // Byte-stability fixed point: decode(encode(x)) re-encodes to the
        // SAME bytes — proves the new decode lines are lossless no-ops
        // for legacy data.
        let second = try JSONDecoder().decode(VideoRecord.self, from: Data(encoded.utf8))
        let reencoded = String(decoding: try Self.goldenEncoder()
            .encode(VideoRecordDTO(second)), as: UTF8.self)
        #expect(reencoded == encoded,
                "legacy record no longer round-trips byte-identical through the #117 schema")
    }

    // MARK: Codable — populated round trip + clone parity

    @Test func populatedUserDateRoundTripsThroughDTOAndClone() throws {
        let record = try JSONDecoder().decode(VideoRecord.self,
                                              from: Data(Self.legacyJSON.utf8))
        record.userDate = "1992-06"
        record.userDateConfidence = "known"

        // DTO encode → class decode.
        let encoded = try Self.goldenEncoder().encode(VideoRecordDTO(record))
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(text.contains(#""userDate":"1992-06""#))
        #expect(text.contains(#""userDateConfidence":"known""#))
        let decoded = try JSONDecoder().decode(VideoRecord.self, from: encoded)
        #expect(decoded.userDate == "1992-06")
        #expect(decoded.userDateConfidence == "known")
        #expect(decoded.userDateStatus == .known)

        // snapshotClone carries the fields (the off-main save path).
        let clone = record.snapshotClone()
        #expect(clone.userDate == "1992-06")
        #expect(clone.userDateConfidence == "known")
    }

    // MARK: Isolation — no UserDefaults writes (poisoned-state class)

    @Test func enteringAUserDateWritesNoDefaults() throws {
        let keysBefore = Set(UserDefaults.standard.dictionaryRepresentation().keys)

        let record = try JSONDecoder().decode(VideoRecord.self,
                                              from: Data(Self.legacyJSON.utf8))
        // Everything the entry UI's save path does, minus the SwiftUI
        // shell: parse, stamp, encode a DTO (as the debounced save would).
        let canonical = try #require(UserDateEntry.canonicalize("6/14/1992"))
        record.userDate = canonical
        record.userDateConfidence = UserDateConfidence.estimated.rawValue
        _ = try Self.goldenEncoder().encode(VideoRecordDTO(record))
        _ = record.resolvedDateDisplay
        _ = record.resolvedDateSortKey

        let added = Set(UserDefaults.standard.dictionaryRepresentation().keys)
            .subtracting(keysBefore)
        #expect(added.isEmpty,
                "user-date path polluted UserDefaults with: \(added.sorted())")
    }

    // MARK: Scale + sensor — resolution is O(1) per row at 100k records

    @Test("resolved date stays cheap and correctly ranked over 100k records",
          .timeLimit(.minutes(1)))
    func scaleSensorResolutionAt100k() throws {
        let containerDate = Date(timeIntervalSince1970: 1_700_000_000)  // 2023
        let inferredDate = Date(timeIntervalSince1970: 800_000_000)     // 1995
        let userStart = try #require(UserDateEntry.date(from: "1992-06"))

        // Thirds: user-dated (must beat everything), inferred-only,
        // container-only. Every user-dated record ALSO carries the
        // machine dates so the sensor proves the outranking, not just
        // the fallback.
        var records: [VideoRecord] = []
        records.reserveCapacity(100_000)
        for i in 0..<100_000 {
            let r = VideoRecord()
            r.dateCreatedRaw = containerDate
            r.dateCreated = "2023-11-14"
            switch i % 3 {
            case 0:
                r.inferredRecordDate = inferredDate
                r.userDate = "1992-06"
                r.userDateConfidence = (i % 2 == 0) ? "estimated" : "known"
            case 1:
                r.inferredRecordDate = inferredDate
            default:
                break
            }
            records.append(r)
        }

        let clock = ContinuousClock()
        var userWins = 0
        var inferredWins = 0
        var containerWins = 0
        var estimatedSuffixes = 0
        let elapsed = clock.measure {
            for r in records {
                let key = r.resolvedDateSortKey
                if key == userStart { userWins += 1 }
                else if key == inferredDate { inferredWins += 1 }
                else if key == containerDate { containerWins += 1 }
                if r.resolvedDateDisplay.hasSuffix("(est.)") { estimatedSuffixes += 1 }
            }
        }

        // SENSOR: the user estimate outranks the container (and
        // inferred) date on every single user-dated record; absent
        // fields fall through the ranking untouched.
        #expect(userWins == 33_334)
        #expect(inferredWins == 33_333)
        #expect(containerWins == 33_333)
        #expect(estimatedSuffixes == 16_667,
                "every estimated-confidence record (and only those) shows the (est.) marker")

        // Time budget: 200k O(1) accessor calls (sort key + display) at
        // production scale. Generous bound — the point is catching an
        // accidental O(records) or DateFormatter regression, which would
        // blow past this by an order of magnitude.
        #expect(elapsed < .seconds(2),
                "resolved-date accessors took \(elapsed) for 100k records — no longer O(1)-cheap per row")
    }
}
