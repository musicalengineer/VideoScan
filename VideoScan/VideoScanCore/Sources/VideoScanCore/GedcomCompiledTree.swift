// GedcomCompiledTree.swift (VideoScanCore)
// The compiled, preprocessed native form of a family tree: the parsed
// graph PLUS every derived structure (TreeIndex — name postings, CSR
// topology, sidebar order and haystack), in one flat little-endian blob
// that decodes as a string table and a handful of Int32 arrays.
//
// Rick (2026-08-28): huge GEDCOM pulls are rare — one per side, ever —
// so import is a ONE-TIME COMPILE step and launch reads the compiled
// artifact; the .ged stays the source of truth and is never rewritten.
// The app-side store (FamilyGraphCompiledStore) owns directories,
// generations, verification and promotion; this file is the codec and
// the verification checklist, both pure.
//
// Layout (all integers little-endian):
//   "VSFT" | u32 codec version | u32 TreeIndex.formatVersion
//   u64 payload length | payload | SHA-256(payload)
// Payload: string table (one UTF-8 blob + offsets), then people, families,
// roots, FamilySearch index, source provenance, then the index arrays.
// Strings are interned: every name/date/place/pointer is an Int32 into the
// table (−1 = nil). A corrupt or truncated file throws — never traps.

import CryptoKit
import Foundation

public enum GedcomCompiledTree {

    /// Bump when the encoding changes so older artifacts are recompiled.
    public static let codecVersion: UInt32 = 2
    static let magic: [UInt8] = Array("VSFT".utf8)

    public enum CodecError: Error, Equatable {
        case badMagic
        case versionMismatch(codec: UInt32, index: UInt32)
        case truncated
        case checksumMismatch
        case corrupt(String)
    }

    // MARK: Encode

    public static func encode(_ graph: GedcomFamilyGraph) -> Data {
        let index = graph.index
        var w = Writer()
        // Everyone in ordinal order so the people table IS index.ids.
        let people = index.ids.map { graph.people[$0]! }
        let familyIDs = graph.familyTable.keys.sorted()
        let families = familyIDs.map { graph.familyTable[$0]! }

        // People
        w.u32(UInt32(people.count))
        for p in people {
            w.ref(p.id); w.ref(p.name); w.ref(p.sex); w.ref(p.childOfFamily)
            w.ref(p.birthDate); w.ref(p.deathDate); w.ref(p.birthPlace); w.ref(p.deathPlace)
            w.ref(p.surname); w.ref(p.familySearchID)
            w.refs(p.alternateNames); w.refs(p.alternateSurnames)
            w.refs(p.childOfFamilies); w.refs(p.spouseOfFamilies)
        }
        // Families
        w.u32(UInt32(families.count))
        for (id, f) in zip(familyIDs, families) {
            w.ref(id); w.ref(f.husband); w.ref(f.wife); w.ref(f.marriageDate); w.refs(f.children)
        }
        // Roots (a list, so a merged two-root tree fits the same layout)
        w.refs(graph.rootPersonIDs)
        // FamilySearch → pointer
        let fs = graph.familySearchIndexTable.keys.sorted()
        w.u32(UInt32(fs.count))
        for key in fs { w.ref(key); w.ref(graph.familySearchIndexTable[key]) }
        // Provenance
        w.ref(graph.sourceFileName); w.ref(graph.sourceDirectory)
        w.f64(graph.sourceModifiedAt?.timeIntervalSince1970 ?? .nan)
        // Codec 2: merged-tree provenance (two-root merge, 2026-08-28).
        w.refs(graph.sourceFileNames)
        w.u32(graph.isMergedArtifact ? 1 : 0)
        w.u32(UInt32(clamping: graph.droppedLineCount))
        w.ref(graph.headNote)

        // Index
        w.i32s(index.nameRank)
        w.i32s(index.parentStart); w.i32s(index.parents); w.i32s(index.motherOffset)
        w.i32s(index.childStart); w.i32s(index.children)
        w.i32s(index.spouseStart); w.i32s(index.spouses)
        for table in [index.tokens, index.likeTokens, index.surnames, index.givenNames, index.familySearchIDs] {
            w.refs(table.keys); w.i32s(table.start); w.i32s(table.postings)
        }
        w.i32s(index.recordStart); w.i32s(index.recordTokenStart)
        w.i32s(index.recordTokenIDs); w.i32s(index.recordLikeIDs)
        w.i32s(index.marriedStart); w.i32s(index.marriedIDs)
        w.i32s(index.surnameStart); w.i32s(index.surnameIDs)
        w.i32s(index.sidebarOrder); w.bytes(index.sidebarHaystack); w.i32s(index.sidebarStart)

        // Assemble: header | string table | body | checksum
        var payload = Data()
        payload.reserveCapacity(w.body.count + w.blob.count + w.offsets.count * 4 + 16)
        var head = Writer()
        head.u32(UInt32(w.offsets.count - 1))
        head.u32(UInt32(w.blob.count))
        payload.append(contentsOf: head.body)
        payload.append(contentsOf: w.blob)
        var offsets = Writer()
        offsets.i32s(w.offsets)
        payload.append(contentsOf: offsets.body)
        payload.append(contentsOf: w.body)

        var out = Data(capacity: payload.count + 48)
        out.append(contentsOf: magic)
        out.append(le(codecVersion)); out.append(le(GedcomFamilyGraph.TreeIndex.formatVersion))
        out.append(le(UInt64(payload.count)))
        out.append(payload)
        out.append(contentsOf: Array(SHA256.hash(data: payload)))
        return out
    }

    // MARK: Decode

    /// The graph, with its index installed. Throws on any malformed input.
    public static func decode(_ data: Data) throws -> GedcomFamilyGraph {
        guard data.count >= 4 + 4 + 4 + 8 + 32 else { throw CodecError.truncated }
        guard Array(data.prefix(4)) == magic else { throw CodecError.badMagic }
        let codec: UInt32 = data.readLE(at: 4), indexVersion: UInt32 = data.readLE(at: 8)
        guard codec == codecVersion, indexVersion == GedcomFamilyGraph.TreeIndex.formatVersion else {
            throw CodecError.versionMismatch(codec: codec, index: indexVersion)
        }
        let length: UInt64 = data.readLE(at: 12)
        let payloadStart = 20
        guard length <= UInt64(data.count - payloadStart - 32) else { throw CodecError.truncated }
        let payloadEnd = payloadStart + Int(length)
        let payload = data.subdata(in: payloadStart..<payloadEnd)
        let stored = Array(data[payloadEnd..<payloadEnd + 32])
        guard Array(SHA256.hash(data: payload)) == stored else { throw CodecError.checksumMismatch }
        return try payload.withUnsafeBytes { raw -> GedcomFamilyGraph in
            var r = Reader(bytes: raw)
            let stringCount = Int(try r.u32())
            let blobLength = Int(try r.u32())
            let blob = try r.slice(blobLength)
            let offsets = try r.i32s(expected: stringCount + 1)
            var strings: [String] = []
            strings.reserveCapacity(stringCount)
            for i in 0..<stringCount {
                let a = Int(offsets[i]), b = Int(offsets[i + 1])
                guard a >= 0, a <= b, b <= blobLength else { throw CodecError.corrupt("string table") }
                strings.append(String(decoding: UnsafeRawBufferPointer(rebasing: blob[a..<b]), as: UTF8.self))
            }
            r.strings = strings

            let personCount = Int(try r.u32())
            var people: [String: GedcomFamilyGraph.Person] = [:]
            people.reserveCapacity(personCount)
            var ids: [String] = []
            ids.reserveCapacity(personCount)
            for _ in 0..<personCount {
                let id = try r.string()
                var p = GedcomFamilyGraph.Person(id: id, name: try r.string(), sex: try r.string(),
                                                 childOfFamily: try r.optionalString())
                p.birthDate = try r.optionalString(); p.deathDate = try r.optionalString()
                p.birthPlace = try r.optionalString(); p.deathPlace = try r.optionalString()
                p.surname = try r.optionalString(); p.familySearchID = try r.optionalString()
                p.alternateNames = try r.stringArray(); p.alternateSurnames = try r.stringArray()
                p.childOfFamilies = try r.stringArray(); p.spouseOfFamilies = try r.stringArray()
                people[id] = p
                ids.append(id)
            }
            let familyCount = Int(try r.u32())
            var families: [String: GedcomFamilyGraph.Family] = [:]
            families.reserveCapacity(familyCount)
            for _ in 0..<familyCount {
                let id = try r.string()
                var f = GedcomFamilyGraph.Family()
                f.husband = try r.optionalString(); f.wife = try r.optionalString()
                f.marriageDate = try r.optionalString(); f.children = try r.stringArray()
                families[id] = f
            }
            let roots = try r.stringArray()
            let fsCount = Int(try r.u32())
            var fsIndex: [String: String] = [:]
            fsIndex.reserveCapacity(fsCount)
            for _ in 0..<fsCount { fsIndex[try r.string()] = try r.string() }
            let sourceFileName = try r.optionalString()
            let sourceDirectory = try r.optionalString()
            let modified = try r.f64()
            let sourceFileNames = try r.stringArray()
            let isMerged = try r.u32() != 0
            let droppedLines = Int(try r.u32())
            let headNote = try r.optionalString()

            let nameRank = try r.i32s(expected: personCount)
            let parentStart = try r.i32s(expected: personCount + 1)
            let parents = try r.i32s()
            let motherOffset = try r.i32s(expected: personCount)
            let childStart = try r.i32s(expected: personCount + 1)
            let children = try r.i32s()
            let spouseStart = try r.i32s(expected: personCount + 1)
            let spouses = try r.i32s()
            var tables: [GedcomFamilyGraph.PostingTable] = []
            for _ in 0..<5 {
                let keys = try r.stringArray()
                let start = try r.i32s(expected: keys.count + 1)
                let postings = try r.i32s()
                guard start.last.map(Int.init) == postings.count else { throw CodecError.corrupt("postings") }
                tables.append(.init(keys: keys, start: start, postings: postings))
            }
            let recordStart = try r.i32s(expected: personCount + 1)
            let recordTokenStart = try r.i32s()
            let recordTokenIDs = try r.i32s()
            let recordLikeIDs = try r.i32s(expected: recordTokenIDs.count)
            let marriedStart = try r.i32s(expected: personCount + 1)
            let marriedIDs = try r.i32s()
            let surnameStart = try r.i32s(expected: personCount + 1)
            let surnameIDs = try r.i32s()
            let sidebarOrder = try r.i32s(expected: personCount)
            let haystack = try r.byteArray()
            let sidebarStart = try r.i32s(expected: personCount + 1)
            guard r.atEnd else { throw CodecError.corrupt("trailing bytes") }
            // Cheap structural sanity: every ordinal in range.
            for list in [parents, children, spouses, sidebarOrder] {
                guard list.allSatisfy({ $0 >= 0 && Int($0) < personCount }) else { throw CodecError.corrupt("ordinal") }
            }

            let index = GedcomFamilyGraph.TreeIndex(
                ids: ids, nameRank: nameRank,
                parentStart: parentStart, parents: parents, motherOffset: motherOffset,
                childStart: childStart, children: children,
                spouseStart: spouseStart, spouses: spouses,
                tokens: tables[0], likeTokens: tables[1], surnames: tables[2],
                givenNames: tables[3], familySearchIDs: tables[4],
                recordStart: recordStart, recordTokenStart: recordTokenStart,
                recordTokenIDs: recordTokenIDs, recordLikeIDs: recordLikeIDs,
                marriedStart: marriedStart, marriedIDs: marriedIDs,
                surnameStart: surnameStart, surnameIDs: surnameIDs,
                sidebarOrder: sidebarOrder, sidebarHaystack: haystack, sidebarStart: sidebarStart)
            let graph = GedcomFamilyGraph(
                decodedPeople: people, families: families, rootPersonIDs: roots,
                personIDByFamilySearchID: fsIndex,
                sourceFileName: sourceFileName, sourceDirectory: sourceDirectory,
                sourceModifiedAt: modified.isNaN ? nil : Date(timeIntervalSince1970: modified),
                sourceFileNames: sourceFileNames, isMergedArtifact: isMerged,
                droppedLineCount: droppedLines, headNote: headNote)
            graph.indexBox.install(index)
            return graph
        }
    }

    // MARK: Verification (the ingest gate)

    /// What a compiled artifact must prove before it is promoted: it
    /// decodes to the same tree it was built from and answers a fixed
    /// set of queries the way the source graph does. Empty = pass.
    public static func verify(decoded: GedcomFamilyGraph, against source: GedcomFamilyGraph) -> [String] {
        var problems: [String] = []
        func check(_ ok: Bool, _ what: @autoclosure () -> String) { if !ok { problems.append(what()) } }
        check(decoded.people.count == source.people.count,
              "person count \(decoded.people.count) ≠ \(source.people.count)")
        check(decoded.familyCount == source.familyCount,
              "family count \(decoded.familyCount) ≠ \(source.familyCount)")
        check(decoded.rootPersonIDs == source.rootPersonIDs, "roots differ")
        check(decoded.sourceFileNames == source.sourceFileNames, "source file names differ")
        check(decoded.isMergedArtifact == source.isMergedArtifact, "merged flag differs")
        if let root = source.rootPerson {
            check(decoded.rootPerson?.familySearchID == root.familySearchID, "root FSID differs")
            check(decoded.people(matching: root.name).contains { $0.id == root.id }
                  == source.people(matching: root.name).contains { $0.id == root.id },
                  "root not found by its own name")
            if let surname = root.surname {
                check(!decoded.people(withSurname: surname).isEmpty, "people(withSurname: \(surname)) empty")
            }
            let sourceDepth = source.ancestorLine(of: root, line: .both, generations: 200).count
            check(decoded.ancestorLine(of: root, line: .both, generations: 200).count == sourceDepth,
                  "ancestor depth from root differs")
            check(sourceDepth == 0 || GedcomFamilyGraph.AncestorIndex(graph: decoded, descendantID: root.id)
                    .generations(from: decoded.ancestorLine(of: root, line: .both, generations: 1).first?.people.first?.id ?? "") == 1,
                  "ancestorDepth(root) not > 0")
        }
        let d = decoded.index, s = source.index
        check(d.parents.count == s.parents.count && d.children.count == s.children.count
              && d.spouses.count == s.spouses.count, "edge counts differ")
        check(d == s, "index differs from a fresh build")
        for id in source.people.keys.sorted().prefix(64) {
            check(decoded.people[id] == source.people[id], "person \(id) differs")
        }
        return problems
    }

    // MARK: Source identity

    /// Cheap, order-of-microseconds identity for a source file: SHA-256
    /// over (size, mtime, first MiB, last MiB). A re-export changes size
    /// and mtime; an in-place edit changes bytes. Hex string.
    public static func sourceKey(for url: URL) throws -> String {
        // FileManager, not URL.resourceValues: the latter caches per URL
        // value within a run-loop turn, so a just-touched file could be
        // keyed with its OLD mtime (caught by the rollback test 2026-08-28).
        let (size, mtime) = try sourceStat(url)
        var hasher = SHA256()
        hasher.update(data: le(UInt64(size)))
        hasher.update(data: le(mtime.bitPattern))
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let window = 1 << 20
        hasher.update(data: try handle.read(upToCount: window) ?? Data())
        if size > window {
            try handle.seek(toOffset: UInt64(max(0, size - window)))
            hasher.update(data: try handle.read(upToCount: window) ?? Data())
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// (size, mtime) straight from the filesystem.
    public static func sourceStat(_ url: URL) throws -> (size: Int, mtime: TimeInterval) {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return (size, mtime)
    }

    /// Full-file SHA-256 (the sidecar / provenance hash). Streams in 4 MiB.
    public static func fullSHA256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Byte helpers

    static func le<T: FixedWidthInteger>(_ v: T) -> Data {
        withUnsafeBytes(of: v.littleEndian) { Data($0) }
    }

    struct Writer {
        var body: [UInt8] = []
        var blob: [UInt8] = []
        var offsets: [Int32] = [0]
        private var intern: [String: Int32] = [:]

        mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { body.append(contentsOf: $0) } }
        mutating func i32(_ v: Int32) { withUnsafeBytes(of: v.littleEndian) { body.append(contentsOf: $0) } }
        mutating func f64(_ v: Double) { withUnsafeBytes(of: v.bitPattern.littleEndian) { body.append(contentsOf: $0) } }
        mutating func ref(_ s: String?) {
            guard let s else { i32(-1); return }
            if let existing = intern[s] { i32(existing); return }
            let id = Int32(offsets.count - 1)
            blob.append(contentsOf: s.utf8)
            offsets.append(Int32(blob.count))
            intern[s] = id
            i32(id)
        }
        mutating func refs(_ list: [String]) { u32(UInt32(list.count)); for s in list { ref(s) } }
        mutating func i32s(_ list: [Int32]) {
            u32(UInt32(list.count))
            list.withUnsafeBufferPointer { body.append(contentsOf: UnsafeRawBufferPointer($0)) }
        }
        mutating func bytes(_ list: [UInt8]) { u32(UInt32(list.count)); body.append(contentsOf: list) }
    }

    struct Reader {
        let bytes: UnsafeRawBufferPointer
        var cursor = 0
        var strings: [String] = []
        init(bytes: UnsafeRawBufferPointer) { self.bytes = bytes }
        var atEnd: Bool { cursor == bytes.count }

        mutating func need(_ n: Int) throws {
            guard n >= 0, cursor + n <= bytes.count else { throw CodecError.truncated }
        }
        mutating func u32() throws -> UInt32 {
            try need(4); defer { cursor += 4 }
            return UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: cursor, as: UInt32.self))
        }
        mutating func i32() throws -> Int32 {
            try need(4); defer { cursor += 4 }
            return Int32(littleEndian: bytes.loadUnaligned(fromByteOffset: cursor, as: Int32.self))
        }
        mutating func f64() throws -> Double {
            try need(8); defer { cursor += 8 }
            return Double(bitPattern: UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: cursor, as: UInt64.self)))
        }
        mutating func slice(_ n: Int) throws -> UnsafeRawBufferPointer {
            try need(n); defer { cursor += n }
            return UnsafeRawBufferPointer(rebasing: bytes[cursor..<cursor + n])
        }
        mutating func i32s(expected: Int? = nil) throws -> [Int32] {
            let n = Int(try u32())
            if let expected, n != expected { throw CodecError.corrupt("array length \(n) ≠ \(expected)") }
            let raw = try slice(n * 4)
            return [Int32](unsafeUninitializedCapacity: n) { buffer, count in
                raw.copyBytes(to: UnsafeMutableRawBufferPointer(buffer))
                count = n
            }
        }
        mutating func byteArray() throws -> [UInt8] {
            let n = Int(try u32())
            return Array(try slice(n))
        }
        mutating func optionalString() throws -> String? {
            let ref = try i32()
            if ref == -1 { return nil }
            guard ref >= 0, Int(ref) < strings.count else { throw CodecError.corrupt("string ref") }
            return strings[Int(ref)]
        }
        mutating func string() throws -> String {
            guard let s = try optionalString() else { throw CodecError.corrupt("nil string") }
            return s
        }
        mutating func stringArray() throws -> [String] {
            let n = Int(try u32())
            try need(n * 4)
            var out: [String] = []
            out.reserveCapacity(n)
            for _ in 0..<n { out.append(try string()) }
            return out
        }
    }
}

extension Data {
    func readLE<T: FixedWidthInteger>(at offset: Int) -> T {
        let raw: T = self.withUnsafeBytes { buffer in
            buffer.loadUnaligned(fromByteOffset: offset, as: T.self)
        }
        return T(littleEndian: raw)
    }
}
