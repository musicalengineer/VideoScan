import CryptoKit
import Foundation
import Testing
@testable import VideoScanCore

/// Frozen codec-7 contracts captured before the October 2026 decomposition.
/// All graphs and bytes are synthetic; no defaults, stores, or archive paths.
struct GedcomCompiledTreeCharacterizationTests {
    private func fixture() -> GedcomFamilyGraph {
        var graph = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        1 NOTE Synthetic codec fixture
        0 @I1@ INDI
        1 NAME Zoë /River/
        1 NAME Z /Brook/
        1 SEX F
        1 BIRT
        2 DATE 2 FEB 2000
        2 PLAC Montréal, Québec
        1 FAMC @F1@
        1 _FSFTID TEST-001
        0 @I2@ INDI
        1 NAME Alex /River/
        1 SEX M
        1 FAMS @F1@
        1 EVEN Naval service
        2 TYPE Military
        2 DATE 1970
        2 PLAC Boston
        2 NOTE Synthetic service fact
        0 @I3@ INDI
        1 NAME Sam /Brook/
        1 SEX F
        1 FAMS @F1@
        1 DEAT
        2 DATE 2020
        0 @F1@ FAM
        1 HUSB @I2@
        1 WIFE @I3@
        1 CHIL @I1@
        1 MARR
        2 DATE 1995
        1 _FSFTID TEST-FAM
        0 TRLR
        """)
        graph.sourceFileName = "synthetic.ged"
        graph.sourceDirectory = "/synthetic"
        graph.sourceModifiedAt = Date(timeIntervalSince1970: 1_700_000_000)
        graph.sourceFingerprint = "fixed-synthetic-fingerprint"
        return graph
    }

    @Test("codec 7 preserves its exact pre-refactor byte representation")
    func frozenEncoding() throws {
        let graph = fixture()
        let bytes = GedcomCompiledTree.encode(graph)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        // Like EXPECT_EQ in C++: a fixed external expectation, not another
        // call to the encoder under test. Changing this requires format review.
        #expect(digest == "ef42bb54d156f51f6f89021114f2bc56f93b2e177b1d3414f0d5180bb779e1b8")
        #expect(bytes == GedcomCompiledTree.encode(fixture()))
        let decoded = try GedcomCompiledTree.decode(bytes)
        #expect(GedcomCompiledTree.verify(decoded: decoded, against: graph).isEmpty)
        #expect(decoded.people["@I1@"]?.birthPlace == "Montréal, Québec")
        #expect(decoded.people["@I2@"]?.militaryFacts.count == 1)
        #expect(decoded.familyTable["@F1@"]?.familySearchID == "TEST-FAM")
    }

    @Test("checksum failure takes precedence over malformed section parsing")
    func checksumErrorPrecedence() throws {
        var bytes = GedcomCompiledTree.encode(fixture())
        let stringCount: UInt32 = bytes.readLE(at: 20)
        let stringBytes: UInt32 = bytes.readLE(at: 24)
        let peopleStart = 28 + Int(stringBytes) + 4 + (Int(stringCount) + 1) * 4
        // Force an independently invalid section header, retaining the old hash.
        bytes.replaceSubrange(peopleStart + 4..<peopleStart + 8, with: [0, 0, 0, 0])
        #expect(throws: GedcomCompiledTree.CodecError.checksumMismatch) {
            _ = try GedcomCompiledTree.decode(bytes)
        }
        // With a matching hash, surface the structural error instead.
        let checksum = Array(SHA256.hash(data: bytes[20..<bytes.count - 32]))
        bytes.replaceSubrange(bytes.count - 32..<bytes.count, with: checksum)
        #expect(throws: GedcomCompiledTree.CodecError.corrupt("chunk size 0")) {
            _ = try GedcomCompiledTree.decode(bytes)
        }
    }

    @Test("parallel chunk assembly matches serial ordinal order", arguments: [0, 1, 1023, 1024, 1025, 2051])
    func chunkBoundaryOrder(count: Int) throws {
        var writer = GedcomCompiledTree.Writer()
        writer.chunkedSection(count: count) { writer, index in writer.i32(Int32(index * 3)) }
        let decoded: [Int32] = try writer.body.withUnsafeBytes { raw in
            var reader = GedcomCompiledTree.Reader(bytes: raw)
            let records = try reader.chunkedSection { reader in try reader.i32() }
            #expect(reader.atEnd)
            return records
        }
        #expect(decoded == (0..<count).map { Int32($0 * 3) })
    }

    @Test("a chunk cannot consume its neighbor's bytes or leave unconsumed bytes")
    func chunkFences() throws {
        // Hand-built section: two records, one per chunk, with fixed offsets.
        // These bytes are independent of Writer.chunkedSection.
        let words: [UInt32] = [2, 1, 8, 10, 20, 0, 4]
        var bytes = Data()
        for word in words { withUnsafeBytes(of: word.littleEndian) { bytes.append(contentsOf: $0) } }
        #expect(throws: GedcomCompiledTree.CodecError.truncated) {
            try bytes.withUnsafeBytes { raw in
                var reader = GedcomCompiledTree.Reader(bytes: raw)
                let _: [Double] = try reader.chunkedSection { reader in try reader.f64() }
            }
        }
        #expect(throws: GedcomCompiledTree.CodecError.corrupt("chunk length")) {
            try bytes.withUnsafeBytes { raw in
                var reader = GedcomCompiledTree.Reader(bytes: raw)
                let _: [Int] = try reader.chunkedSection { _ in 0 }
            }
        }
    }
}
