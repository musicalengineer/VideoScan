// CatalogJSONValueExactNumberTests.swift
// GH #167, codex review 2026-10-02 (cycle #28) finding 4: numbers inside
// keys this build does not know must come back with their exact VALUE.
// Before the fix every number outside Int64 fell through to Double, so
// UInt64.max (18446744073709551615) was re-written as 18446744073709551616.
//
// What "exact" means here (see docs/practices/invariants/Catalog.md):
// the JSON number's value is preserved; its spelling is normalised the way
// JSONEncoder spells it (`1e3` → `1000`, `1.0` → `1`). Canonically spelled
// integers and decimals therefore round-trip byte for byte.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("CatalogJSONValue keeps unknown numbers exact")
struct CatalogJSONValueExactNumberTests {

    private func roundTrip(_ text: String) throws -> String {
        let value = try JSONDecoder().decode(CatalogJSONValue.self, from: Data(text.utf8))
        // .sortedKeys: JSONEncoder's object key order is per-process random
        // (GH #165) and key order is not what these tests are about.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    @Test("codex's reproduction: UInt64.max round-trips byte for byte")
    func unknownUInt64RetainsExactValue() throws {
        let source = try JSONEncoder().encode(UInt64.max)
        let value = try JSONDecoder().decode(CatalogJSONValue.self, from: source)
        #expect(try JSONEncoder().encode(value) == source)
    }

    @Test("canonical integers and decimals beyond Int64 / Double precision are byte-exact",
          arguments: [
            "18446744073709551615",                     // UInt64.max
            "9223372036854775808",                      // Int64.max + 1
            "-9223372036854775808",                     // Int64.min
            "-9223372036854775809",                     // Int64.min - 1
            "-99999999999999999999999",                 // large negative
            "3.14159265358979323846264338327950288",    // 36 significant digits
            "12345678901234567890.123456789",
            "0.1", "-7", "0", "42",
          ])
    func canonicalNumbersAreByteExact(_ literal: String) throws {
        #expect(try roundTrip(literal) == literal)
    }

    @Test("exponents and values outside Decimal's range keep their exact value",
          arguments: ["1e3", "2.5e-7", "1.5e300", "5e-324", "1.7976931348623157e308", "-1E+2"])
    func exponentValuesExact(_ literal: String) throws {
        let back = try roundTrip(literal)
        let da = try JSONDecoder().decode(Double.self, from: Data(literal.utf8))
        let db = try JSONDecoder().decode(Double.self, from: Data(back.utf8))
        #expect(da == db, "\(literal) → \(back)")
        // Where Decimal can hold it, compare in base 10 too (no binary rounding).
        if let a = try? JSONDecoder().decode(Decimal.self, from: Data(literal.utf8)) {
            let b = try? JSONDecoder().decode(Decimal.self, from: Data(back.utf8))
            #expect(b == a, "\(literal) → \(back)")
        }
    }

    @Test("negative zero keeps its sign")
    func negativeZero() throws {
        let back = try roundTrip("-0.0")
        let d = try JSONDecoder().decode(Double.self, from: Data(back.utf8))
        #expect(d == 0 && d.sign == .minus, "-0.0 → \(back)")
    }

    @Test("exact inside arrays and objects, nested")
    func nestedExact() throws {
        let text = #"{"a":[18446744073709551615,{"b":-99999999999999999999999}],"c":3.14159265358979323846264338327950288}"#
        #expect(try roundTrip(text) == text)
    }

    @Test("bools, null and Int64 values keep their case (no shape drift)")
    func shapesUnchanged() throws {
        func decode(_ s: String) throws -> CatalogJSONValue {
            try JSONDecoder().decode(CatalogJSONValue.self, from: Data(s.utf8))
        }
        #expect(try decode("true") == .bool(true))
        #expect(try decode("null") == .null)
        #expect(try decode("-7") == .int(-7))
        #expect(try decode("1.5") != .int(1))
    }
}
