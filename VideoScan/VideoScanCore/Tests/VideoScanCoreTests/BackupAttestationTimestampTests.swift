// BackupAttestationTimestampTests.swift
// The TIMESTAMP RULE (codex #1414, 2026-09-12): `attestedAt` orders the
// merge, so its in-memory value must equal its own round trip through
// every store. REGRESSION for the escaped bug (a newer "no" that went
// through the whole-second manifest string lost to an older in-memory
// "yes" 0.7 s earlier), the codec's contract (format, tolerance, bit-
// exact round trip, encoder-strategy independence, the catalog's own
// DTO path), and a SCALE pin for 100k timestamps.

import XCTest
@testable import VideoScanCore

final class BackupAttestationTimestampTests: XCTestCase {

    /// 2025-09-12T18:00:00Z — the epoch the sibling suite uses.
    private let t: TimeInterval = 1_757_700_000
    private func d(_ offset: TimeInterval) -> Date { Date(timeIntervalSince1970: t + offset) }
    private typealias TS = BackupAttestation.Timestamp

    // MARK: REGRESSION — codex #1414

    func testNewerNoThroughTheManifestBeatsAnOlderFractionalYesFromTheCatalog() {
        // The catalog holds a full-precision "yes" at t+0.2 (never saved).
        let olderYes = BackupAttestation(kind: .cloud, answer: .yes, label: "iCloud", attestedAt: d(0.2))
        // A newer "no" at t+0.9 goes out through the manifest column and comes back.
        let newerNo = BackupAttestation(kind: .cloud, answer: .no, attestedAt: d(0.9))
        let viaManifest = BackupAttestation.fromJSONString(BackupAttestation.jsonString([newerNo]))
        XCTAssertEqual(viaManifest, [newerNo], "the manifest string is lossless")
        XCTAssertEqual(viaManifest.first?.attestedAt, newerNo.attestedAt, "bit-for-bit, not merely close")

        // The merge — in BOTH directions — keeps the newer "no".
        XCTAssertEqual(BackupAttestation.merged([olderYes], with: viaManifest).map(\.answer), [.no],
                       "catalog base + manifest incoming: NO wins")
        XCTAssertEqual(BackupAttestation.merged(viaManifest, with: [olderYes]).map(\.answer), [.no],
                       "manifest base + catalog incoming: NO wins")
        XCTAssertEqual(BackupAttestation.latestPerKind([olderYes] + viaManifest)[.cloud]?.answer, .no)
        let rec = VideoRecord(); rec.backupAttestations = [olderYes]
        XCTAssertTrue(rec.inheritBackupAttestations(from: { let o = VideoRecord(); o.backupAttestations = viaManifest; return o }()))
        XCTAssertEqual(rec.backupAttestations.map(\.answer), [.no])

        // The pre-rule shape is exactly what lost. A whole-second string
        // still DECODES (tolerance — nothing already written is lost) but
        // it is t, not t+0.9, so the older yes would have won it.
        let preRule = "[{\"answer\":\"no\",\"attestedAt\":\"2025-09-12T18:00:00Z\",\"by\":\"rick\",\"kind\":\"cloud\"}]"
        let truncated = BackupAttestation.fromJSONString(preRule)
        XCTAssertEqual(truncated.first?.attestedAt, d(0), "a pre-rule whole-second string decodes to the whole second")
        XCTAssertEqual(BackupAttestation.merged([olderYes], with: truncated).map(\.answer), [.yes],
                       "…which is the bug: whole-second persistence resurrected the older answer")
    }

    func testCatalogDTORoundTripAgreesWithTheManifestByteForByte() throws {
        // CatalogStore encodes with `.iso8601`; the manifest sets no
        // strategy; a future writer might use the default. All three must
        // produce the SAME attestedAt bytes and decode to the SAME Date.
        let a = BackupAttestation(kind: .offsite, answer: .no, attestedAt: d(0.9))
        let rec = VideoRecord(); rec.filename = "x.mov"; rec.backupAttestations = [a]
        let catalogEnc = JSONEncoder(); catalogEnc.dateEncodingStrategy = .iso8601; catalogEnc.outputFormatting = [.sortedKeys]
        let catalogDec = JSONDecoder(); catalogDec.dateDecodingStrategy = .iso8601
        let catalogBytes = try catalogEnc.encode(VideoRecordDTO(rec))
        let back = try catalogDec.decode(VideoRecord.self, from: catalogBytes)
        XCTAssertEqual(back.backupAttestations, [a])
        XCTAssertEqual(back.backupAttestations.first?.attestedAt, a.attestedAt, "the catalog round trip is exact")
        let catalogText = String(decoding: catalogBytes, as: UTF8.self)
        XCTAssertTrue(catalogText.contains("\"attestedAt\":\"2025-09-12T18:00:00.900Z\""), catalogText)
        XCTAssertTrue(BackupAttestation.jsonString([a]).contains("\"attestedAt\":\"2025-09-12T18:00:00.900Z\""))

        // Encoder-strategy independence: identical bytes under every strategy.
        func bytes(_ strategy: JSONEncoder.DateEncodingStrategy) throws -> Data {
            let e = JSONEncoder(); e.dateEncodingStrategy = strategy; e.outputFormatting = [.sortedKeys]
            return try e.encode([a])
        }
        let reference = try bytes(.iso8601)
        XCTAssertEqual(try bytes(.deferredToDate), reference)
        XCTAssertEqual(try bytes(.secondsSince1970), reference)
        XCTAssertEqual(try bytes(.millisecondsSince1970), reference)
        // …and decodable under every strategy too (the type never asks the decoder for a Date).
        for strategy in [JSONDecoder.DateDecodingStrategy.deferredToDate, .iso8601, .secondsSince1970] {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = strategy
            XCTAssertEqual(try dec.decode([BackupAttestation].self, from: reference), [a])
        }
    }

    // MARK: The codec

    func testStringFormatAlwaysThreeFractionalDigitsUTC() {
        XCTAssertEqual(TS.string(d(0)), "2025-09-12T18:00:00.000Z")
        XCTAssertEqual(TS.string(d(0.123)), "2025-09-12T18:00:00.123Z")
        XCTAssertEqual(TS.string(d(0.9)), "2025-09-12T18:00:00.900Z")
        XCTAssertEqual(TS.string(d(0.0005)), "2025-09-12T18:00:00.001Z", "rounds to nearest ms")
        XCTAssertEqual(TS.string(d(0.9996)), "2025-09-12T18:00:01.000Z", "carries into the next second")
        XCTAssertEqual(TS.string(d(-0.25)), "2025-09-12T17:59:59.750Z", "floor split below a whole second")
    }

    func testDateParsesFractionalWholeSecondAndOddDigitCounts() {
        XCTAssertEqual(TS.date("2025-09-12T18:00:00.123Z"), d(0.123))
        XCTAssertEqual(TS.date("2025-09-12T18:00:00Z"), d(0), "pre-rule whole-second string")
        XCTAssertEqual(TS.date("2025-09-12T18:00:00.5Z"), d(0.5), "one digit = 500 ms")
        XCTAssertEqual(TS.date("2025-09-12T18:00:00.12Z"), d(0.12), "two digits")
        XCTAssertEqual(TS.date("2025-09-12T18:00:00.1234Z"), d(0.123), "fourth digit < 5 truncates")
        XCTAssertEqual(TS.date("2025-09-12T18:00:00.1235Z"), d(0.124), "fourth digit ≥ 5 rounds up")
        XCTAssertEqual(TS.date("2025-09-12T18:00:00.123456789Z"), d(0.123))
        XCTAssertEqual(TS.date("  2025-09-12T18:00:00.123Z\n"), d(0.123), "surrounding whitespace")
        XCTAssertEqual(TS.date("2025-09-12T18:00:00+00:00"), d(0), "zone offset form")
        XCTAssertEqual(TS.date("2025-09-12T19:00:00.250+01:00"), d(0.25), "non-UTC offset normalizes")
        XCTAssertNil(TS.date(""))
        XCTAssertNil(TS.date("yesterday"))
        XCTAssertNil(TS.date("2025-09-12"))
        XCTAssertNil(TS.date("2025-13-45T99:00:00Z"))
    }

    func testRoundTripIsBitExactAndIdempotent() {
        // Deterministic pseudo-random offsets across ±30 years with
        // sub-millisecond noise: date(string(x)) == quantized(x) exactly,
        // and string is a fixed point after one round trip.
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        for _ in 0..<2_000 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            let seconds = Double(Int64(bitPattern: state) % 946_708_560)          // ±30 years
            let noise = Double(state % 1_000_000) / 1_000_000                     // [0, 1) s
            let x = Date(timeIntervalSince1970: t + seconds + noise)
            let q = TS.quantized(x)
            let s = TS.string(x)
            XCTAssertEqual(TS.date(s), q, s)
            XCTAssertEqual(TS.string(q), s, "string is stable after quantization")
            XCTAssertEqual(TS.quantized(q), q, "quantized is idempotent")
            XCTAssertEqual(TS.milliseconds(q), TS.milliseconds(x))
        }
    }

    func testInitQuantizesSoInMemoryEqualsPersisted() {
        let raw = d(0.123_456_7)
        let a = BackupAttestation(kind: .cloud, answer: .yes, attestedAt: raw)
        XCTAssertNotEqual(a.attestedAt, raw)
        XCTAssertEqual(a.attestedAt, TS.quantized(raw))
        XCTAssertEqual(a.attestedAt, d(0.123))
        // Two answers 0.4 ms apart are the SAME instant after quantization —
        // then the list/tie rules decide, deterministically, not float noise.
        let first = BackupAttestation(kind: .cloud, answer: .yes, attestedAt: d(0.1231))
        let second = BackupAttestation(kind: .cloud, answer: .no, attestedAt: d(0.1235))
        XCTAssertEqual(first.attestedAt, d(0.123))
        XCTAssertEqual(second.attestedAt, d(0.124), "0.1235 rounds up — still ordered")
        XCTAssertEqual(BackupAttestation.merged([first], with: [second]).map(\.answer), [.no])
    }

    func testDecodeToleratesNumberAndRefusesGarbage() throws {
        // Foundation's default `.deferredToDate` writes seconds since the
        // reference date; accepted, never thrown away.
        let numeric = "{\"answer\":\"no\",\"attestedAt\":123456.5,\"kind\":\"cloud\"}"
        let a = try JSONDecoder().decode(BackupAttestation.self, from: Data(numeric.utf8))
        XCTAssertEqual(a.attestedAt, TS.quantized(Date(timeIntervalSinceReferenceDate: 123456.5)))
        // Garbage in the manifest column → [] (a rebuild never fails on it).
        XCTAssertEqual(BackupAttestation.fromJSONString("[{\"answer\":\"no\",\"attestedAt\":\"yesterday\",\"kind\":\"cloud\"}]"), [])
        XCTAssertEqual(BackupAttestation.fromJSONString("[{\"answer\":\"no\",\"attestedAt\":true,\"kind\":\"cloud\"}]"), [])
        XCTAssertThrowsError(try JSONDecoder().decode(BackupAttestation.self,
                                                       from: Data("{\"answer\":\"no\",\"attestedAt\":\"nope\",\"kind\":\"cloud\"}".utf8)))
    }

    // MARK: SCALE — 100k timestamps

    func testScale100kTimestampsFormatParseAndJSONUnderBudget() throws {
        var dates: [Date] = []
        dates.reserveCapacity(100_000)
        for i in 0..<100_000 { dates.append(d(Double(i) * 37.123)) }

        let start = Date()
        var mismatches = 0
        for x in dates where TS.date(TS.string(x)) != TS.quantized(x) { mismatches += 1 }
        let codec = Date().timeIntervalSince(start)
        XCTAssertEqual(mismatches, 0)
        XCTAssertLessThan(codec, 3.0, "100k format+parse round trips took \(codec)s")

        // The catalog-save shape: 100k attestations through JSONEncoder /
        // JSONDecoder (what a fully attested 50k-record catalog costs).
        let list = dates.map { BackupAttestation(kind: .cloud, answer: .yes, label: "iCloud", attestedAt: $0) }
        let jsonStart = Date()
        let data = try JSONEncoder().encode(list)
        let back = try JSONDecoder().decode([BackupAttestation].self, from: data)
        let json = Date().timeIntervalSince(jsonStart)
        XCTAssertEqual(back, list)
        XCTAssertLessThan(json, 3.0, "100k attestations encode+decode took \(json)s")
    }
}
