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
    /// 4 (2026-08-28, codex #812/#814): provenance is written in the
    /// CANONICAL shape — the positional source list plus the graph-local
    /// remainder — so a one-source graph's loss is carried once (codec 3
    /// wrote it both in the list and as the local count: 2× after decode).
    /// 5 (2026-08-29): the people and family sections carry a chunk
    /// offset table so they decode in parallel (one chunk per core), and
    /// TreeIndex formatVersion 2 adds the launch tables. Older blobs are
    /// refused with `versionMismatch` and the store recompiles.
    public static let codecVersion: UInt32 = 5
    static let magic: [UInt8] = Array("VSFT".utf8)
    /// Records per parallel decode chunk (written into the section header;
    /// the reader honours whatever the file says). 39k people → 39
    /// chunks; 100k → 98: enough to balance 16 cores, large enough that
    /// the per-chunk dispatch is noise.
    static let chunkSize = 1024

    public enum CodecError: Error, Equatable {
        case badMagic
        case versionMismatch(codec: UInt32, index: UInt32)
        case truncated
        case checksumMismatch
        case corrupt(String)
    }

    // MARK: Encode

    public static func encode(_ graph: GedcomFamilyGraph) -> Data {
        // Canonical provenance (codec 4): list + local remainder, total
        // unchanged; `decode` restores exactly these two.
        let graph = graph.canonicalized()
        let index = graph.index
        var w = Writer()
        // Everyone in ordinal order so the people table IS index.ids.
        let people = index.ids.map { graph.people[$0]! }
        let familyIDs = graph.familyTable.keys.sorted()
        let families = familyIDs.map { graph.familyTable[$0]! }

        // People (codec 5: chunked section — see `Writer.chunkedSection`).
        w.chunkedSection(count: people.count) { w, i in
            let p = people[i]
            w.ref(p.id); w.ref(p.name); w.ref(p.sex); w.ref(p.childOfFamily)
            w.ref(p.birthDate); w.ref(p.deathDate); w.ref(p.birthPlace); w.ref(p.deathPlace)
            w.ref(p.surname); w.ref(p.familySearchID)
            w.refs(p.alternateNames); w.refs(p.alternateSurnames)
            w.refs(p.childOfFamilies); w.refs(p.spouseOfFamilies)
        }
        // Families
        w.chunkedSection(count: families.count) { w, i in
            let f = families[i]
            w.ref(familyIDs[i]); w.ref(f.husband); w.ref(f.wife); w.ref(f.marriageDate); w.refs(f.children)
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
        // Graph-LOCAL loss (codec 4: the canonical remainder, 0 for a file parse).
        w.u32(UInt32(clamping: graph.droppedLineCount))
        w.ref(graph.headNote)
        // Positional source list (name, sha256, that source's dropped lines).
        let provenance = graph.sourceProvenance
        w.u32(UInt32(provenance.count))
        for p in provenance { w.ref(p.name); w.ref(p.sha256); w.u32(UInt32(clamping: p.droppedLineCount)) }
        // The graph's OWN file digest, its own scalar (see GedcomFamilyGraph.sourceFingerprint).
        w.ref(graph.sourceFingerprint)

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
        // Launch tables (TreeIndex formatVersion 2)
        w.refs(index.identityKeys)
        w.i32s(index.givenStart); w.i32s(index.givenIDs)
        w.i32s(index.surnameTokenStart); w.i32s(index.surnameTokenIDs)
        w.i32s(index.suffixIDs)
        w.refs(index.lifeYears)

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
    ///
    /// Uses every core (2026-08-29): the payload checksum runs on one
    /// thread while the sections parse on the others; the string table
    /// and the chunked people/family sections parse with
    /// `DispatchQueue.concurrentPerform`. Every reader is bounds-checked,
    /// so parsing ahead of the checksum can only throw, never trap — and
    /// a checksum failure is still reported as `checksumMismatch`
    /// whatever the parse made of the bytes. The result is identical to
    /// a sequential decode by construction (each chunk reads a disjoint
    /// byte range into a disjoint slot; assembly is in ordinal order).
    public static func decode(_ data: Data) throws -> GedcomFamilyGraph {
        guard data.count >= 4 + 4 + 4 + 8 + 32 else { throw CodecError.truncated }
        guard Array(data.prefix(4)) == magic else { throw CodecError.badMagic }
        let codec: UInt32 = data.readLE(at: 4), indexVersion: UInt32 = data.readLE(at: 8)
        guard codec == codecVersion, indexVersion == GedcomFamilyGraph.TreeIndex.formatVersion else {
            throw CodecError.versionMismatch(codec: codec, index: indexVersion)
        }
        let length: UInt64 = data.readLE(at: 12)
        let payloadStart = 20
        // The file is exactly header | payload | checksum (codex #797-5):
        // shorter = truncated, longer = something appended after the
        // checksum that the hash would never have covered. Both refuse.
        let available = UInt64(data.count - payloadStart - 32)
        guard length <= available else { throw CodecError.truncated }
        guard length == available else { throw CodecError.corrupt("trailing bytes after checksum") }
        let payloadEnd = payloadStart + Int(length)
        return try data.withUnsafeBytes { whole -> GedcomFamilyGraph in
            let payload = UnsafeRawBufferPointer(rebasing: whole[payloadStart..<payloadEnd])
            let stored = Array(whole[payloadEnd..<payloadEnd + 32])
            // Checksum on a worker while this thread parses.
            let hashGroup = DispatchGroup()
            var checksumOK = false
            DispatchQueue.global(qos: .userInitiated).async(group: hashGroup) {
                checksumOK = Array(SHA256.hash(data: payload)) == stored
            }
            defer { hashGroup.wait() }
            let parsed: GedcomFamilyGraph
            do {
                parsed = try parsePayload(payload)
            } catch {
                hashGroup.wait()
                if !checksumOK { throw CodecError.checksumMismatch }
                throw error
            }
            let waited = PhaseClock()
            hashGroup.wait()
            var c = waited; c.lap("checksum wait")
            guard checksumOK else { throw CodecError.checksumMismatch }
            return parsed
        }
    }

    /// Payload = string table | people | families | roots | FS index |
    /// provenance | index arrays. Trusts nothing: every length and every
    /// reference is checked before use.
    private static func parsePayload(_ raw: UnsafeRawBufferPointer) throws -> GedcomFamilyGraph {
        var clock = PhaseClock()
        var r = Reader(bytes: raw)
        let stringCount = Int(try r.u32())
        let blobLength = Int(try r.u32())
        let blob = try r.slice(blobLength)
        let offsets = try r.i32s(expected: stringCount + 1)
        // String table: offsets must be monotonic within the blob (one
        // sequential pass of integer compares), then the Strings are made
        // in parallel chunks — each slot written exactly once.
        guard offsets.first == 0 || stringCount == 0 else { throw CodecError.corrupt("string table") }
        for i in 0..<stringCount where !(offsets[i] >= 0 && offsets[i] <= offsets[i + 1] && Int(offsets[i + 1]) <= blobLength) {
            throw CodecError.corrupt("string table")
        }
        let strings = [String](unsafeUninitializedCapacity: stringCount) { buffer, initialized in
            let chunks = Self.chunkCount(stringCount)
            DispatchQueue.concurrentPerform(iterations: chunks) { c in
                let lo = c * chunkSize, hi = min(stringCount, lo + chunkSize)
                for i in lo..<hi {
                    let a = Int(offsets[i]), b = Int(offsets[i + 1])
                    (buffer.baseAddress! + i).initialize(
                        to: String(decoding: UnsafeRawBufferPointer(rebasing: blob[a..<b]), as: UTF8.self))
                }
            }
            initialized = stringCount
        }
        r.strings = strings
        clock.lap("strings")

        // People (chunked section, parallel), then the id → record map.
        let peopleInOrder: [GedcomFamilyGraph.Person] = try r.chunkedSection { r in
            let id = try r.string()
            var p = GedcomFamilyGraph.Person(id: id, name: try r.string(), sex: try r.string(),
                                             childOfFamily: try r.optionalString())
            p.birthDate = try r.optionalString(); p.deathDate = try r.optionalString()
            p.birthPlace = try r.optionalString(); p.deathPlace = try r.optionalString()
            p.surname = try r.optionalString(); p.familySearchID = try r.optionalString()
            p.alternateNames = try r.stringArray(); p.alternateSurnames = try r.stringArray()
            p.childOfFamilies = try r.stringArray(); p.spouseOfFamilies = try r.stringArray()
            return p
        }
        clock.lap("people parse")
        let personCount = peopleInOrder.count
        var people: [String: GedcomFamilyGraph.Person] = [:]
        people.reserveCapacity(personCount)
        var ids: [String] = []
        ids.reserveCapacity(personCount)
        for p in peopleInOrder {
            people[p.id] = p
            ids.append(p.id)
        }
        clock.lap("people map")
        // Families
        let familiesInOrder: [(String, GedcomFamilyGraph.Family)] = try r.chunkedSection { r in
            let id = try r.string()
            var f = GedcomFamilyGraph.Family()
            f.husband = try r.optionalString(); f.wife = try r.optionalString()
            f.marriageDate = try r.optionalString(); f.children = try r.stringArray()
            return (id, f)
        }
        clock.lap("families parse")
        var families: [String: GedcomFamilyGraph.Family] = [:]
        families.reserveCapacity(familiesInOrder.count)
        for (id, f) in familiesInOrder { families[id] = f }
        clock.lap("families map")
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
        let provenanceCount = Int(try r.u32())
        var provenance: [GedcomFamilyGraph.SourceProvenance] = []
        provenance.reserveCapacity(provenanceCount)
        for _ in 0..<provenanceCount {
            provenance.append(.init(name: try r.string(), sha256: try r.optionalString(), droppedLineCount: Int(try r.u32())))
        }
        let sourceFingerprint = try r.optionalString()
        clock.lap("fs index + provenance")

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
        // Launch tables (TreeIndex formatVersion 2)
        let identityKeys = try r.stringArray()
        let givenStart = try r.i32s(expected: personCount + 1)
        let givenIDs = try r.i32s()
        let surnameTokenStart = try r.i32s(expected: personCount + 1)
        let surnameTokenIDs = try r.i32s()
        let suffixIDs = try r.i32s(expected: personCount)
        let lifeYears = try r.stringArray()
        guard lifeYears.count == personCount else { throw CodecError.corrupt("lifeYears length") }
        guard r.atEnd else { throw CodecError.corrupt("trailing bytes") }
        clock.lap("index arrays")
        // Cheap structural sanity: every ordinal / key position in range.
        for list in [parents, children, spouses, sidebarOrder] {
            guard list.allSatisfy({ $0 >= 0 && Int($0) < personCount }) else { throw CodecError.corrupt("ordinal") }
        }
        let keyCount = Int32(identityKeys.count)
        guard givenIDs.allSatisfy({ $0 >= 0 && $0 < keyCount }),
              surnameTokenIDs.allSatisfy({ $0 >= 0 && $0 < keyCount }),
              suffixIDs.allSatisfy({ $0 >= -1 && $0 < keyCount }),
              givenStart.last.map(Int.init) == givenIDs.count,
              surnameTokenStart.last.map(Int.init) == surnameTokenIDs.count
        else { throw CodecError.corrupt("identity table") }

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
            sidebarOrder: sidebarOrder, sidebarHaystack: haystack, sidebarStart: sidebarStart,
            identityKeys: identityKeys, givenStart: givenStart, givenIDs: givenIDs,
            surnameTokenStart: surnameTokenStart, surnameTokenIDs: surnameTokenIDs,
            suffixIDs: suffixIDs, lifeYears: lifeYears)
        var graph = GedcomFamilyGraph(
            decodedPeople: people, families: families, rootPersonIDs: roots,
            personIDByFamilySearchID: fsIndex,
            sourceFileName: sourceFileName, sourceDirectory: sourceDirectory,
            sourceModifiedAt: modified.isNaN ? nil : Date(timeIntervalSince1970: modified),
            sourceFileNames: sourceFileNames, isMergedArtifact: isMerged,
            droppedLineCount: droppedLines, headNote: headNote)
        graph.sourceProvenance = provenance
        graph.sourceFingerprint = sourceFingerprint
        graph.indexBox.install(index)
        clock.lap("sanity + assemble")
        return graph
    }

    static func chunkCount(_ records: Int) -> Int { (records + chunkSize - 1) / chunkSize }

    /// `VS_DECODE_TIMING=1` prints one line per decode phase (perf work).
    static let phaseTiming = ProcessInfo.processInfo.environment["VS_DECODE_TIMING"] != nil
    struct PhaseClock {
        let t0 = DispatchTime.now().uptimeNanoseconds
        var last: UInt64
        init() { last = t0 }
        mutating func lap(_ label: String) {
            guard GedcomCompiledTree.phaseTiming else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            print("DECODE-PHASE \(label): +\(Double(now - last) / 1e6) ms (\(Double(now - t0) / 1e6) ms)")
            last = now
        }
    }

    // MARK: Verification (the ingest gate)

    /// What a compiled artifact must prove before it is promoted: it
    /// decodes to EXACTLY the tree it was built from — every person (all
    /// fields), every family, roots, FamilySearch index, provenance (the
    /// canonical list, the local remainder, the total and the fingerprint)
    /// and the merge fields — and answers a fixed set of queries the
    /// way the source graph does. `source` is compared in its canonical
    /// shape, which is what `encode` wrote. Exhaustive by design (Rick 2026-08-28:
    /// ingest is one-time, integrity beats a few hundred ms). Empty = pass.
    ///
    /// Each mismatch CLASS is reported once with a count and its first
    /// example, so a systematically broken encoder yields a handful of
    /// bounded lines rather than 100k of them.
    public static func verify(decoded: GedcomFamilyGraph, against source: GedcomFamilyGraph) -> [String] {
        var report = MismatchReport()
        let source = source.canonicalized()

        // Scalars / provenance
        report.equal("person count", decoded.people.count, source.people.count)
        report.equal("family count", decoded.familyCount, source.familyCount)
        report.equal("rootPersonIDs", decoded.rootPersonIDs, source.rootPersonIDs)
        report.equal("sourceFileNames", decoded.sourceFileNames, source.sourceFileNames)
        report.equal("isMergedArtifact", decoded.isMergedArtifact, source.isMergedArtifact)
        report.equal("droppedLineCount", decoded.droppedLineCount, source.droppedLineCount)
        report.equal("totalDroppedLineCount", decoded.totalDroppedLineCount, source.totalDroppedLineCount)
        report.equal("headNote", decoded.headNote, source.headNote)
        report.equal("sourceProvenance", decoded.sourceProvenance, source.sourceProvenance)
        report.equal("sourceFingerprint", decoded.sourceFingerprint, source.sourceFingerprint)
        report.equal("sourceFileName", decoded.sourceFileName, source.sourceFileName)
        report.equal("sourceDirectory", decoded.sourceDirectory, source.sourceDirectory)
        // Stored as a Double of seconds-since-1970; allow the last-ulp wobble
        // of the epoch conversion, nothing more.
        let dm = decoded.sourceModifiedAt?.timeIntervalSince1970, sm = source.sourceModifiedAt?.timeIntervalSince1970
        let modifiedOK: Bool = {
            switch (dm, sm) {
            case (nil, nil): return true
            case let (a?, b?): return abs(a - b) < 1e-3
            default: return false
            }
        }()
        report.check("sourceModifiedAt", ok: modifiedOK, example: "\(String(describing: dm)) ≠ \(String(describing: sm))")

        // People: every record, every field, walked in ordinal order (the
        // index's id table) so the "first example" is deterministic.
        // Person is Equatable, so one compare per record; on a mismatch
        // name the first differing field.
        let s = source.index
        for id in s.ids {
            let sp = source.people[id]!
            guard let dp = decoded.people[id] else { report.miss("person missing in decoded", id); continue }
            if dp != sp { report.miss("person differs", "\(id): \(Self.firstDifference(dp, sp))") }
        }
        for id in decoded.people.keys where source.people[id] == nil { report.miss("person extra in decoded", id) }

        // Families: every record, every field.
        let sf = source.familyTable, df = decoded.familyTable
        for id in sf.keys.sorted() {
            let f = sf[id]!
            guard let d = df[id] else { report.miss("family missing in decoded", id); continue }
            if d.husband != f.husband { report.miss("family husband differs", id) }
            if d.wife != f.wife { report.miss("family wife differs", id) }
            if d.marriageDate != f.marriageDate { report.miss("family marriageDate differs", id) }
            if d.children != f.children { report.miss("family children differ", id) }
        }
        for id in df.keys.sorted() where sf[id] == nil { report.miss("family extra in decoded", id) }

        // FamilySearch → pointer table.
        let sfs = source.familySearchIndexTable, dfs = decoded.familySearchIndexTable
        for key in sfs.keys.sorted() {
            let value = sfs[key]!
            guard let d = dfs[key] else { report.miss("familySearch entry missing in decoded", key); continue }
            if d != value { report.miss("familySearch entry differs", "\(key): \(d) ≠ \(value)") }
        }
        for key in dfs.keys.sorted() where sfs[key] == nil { report.miss("familySearch entry extra in decoded", key) }

        // Derived index: exhaustive Equatable compare against a fresh build.
        let d = decoded.index
        report.check("edge counts", ok: d.parents.count == s.parents.count && d.children.count == s.children.count
                     && d.spouses.count == s.spouses.count,
                     example: "parents \(d.parents.count)/\(s.parents.count) children \(d.children.count)/\(s.children.count) spouses \(d.spouses.count)/\(s.spouses.count)")
        report.check("index differs from a fresh build", ok: d == s, example: "")

        // Behavioural spot checks from the root.
        if let root = source.rootPerson {
            report.check("root FSID", ok: decoded.rootPerson?.familySearchID == root.familySearchID, example: root.id)
            report.check("root found by its own name",
                         ok: decoded.people(matching: root.name).contains { $0.id == root.id }
                             == source.people(matching: root.name).contains { $0.id == root.id },
                         example: root.name)
            if let surname = root.surname {
                report.check("people(withSurname:) empty", ok: !decoded.people(withSurname: surname).isEmpty, example: surname)
            }
            let sourceDepth = source.ancestorLine(of: root, line: .both, generations: 200).count
            report.check("ancestor depth from root",
                         ok: decoded.ancestorLine(of: root, line: .both, generations: 200).count == sourceDepth,
                         example: "\(sourceDepth)")
            report.check("ancestorDepth(root) not > 0",
                         ok: sourceDepth == 0 || GedcomFamilyGraph.AncestorIndex(graph: decoded, descendantID: root.id)
                            .generations(from: decoded.ancestorLine(of: root, line: .both, generations: 1).first?.people.first?.id ?? "") == 1,
                         example: root.id)
        }
        return report.lines
    }

    /// Name of the first field that differs between two Person records
    /// (for the verify report; both are known to be unequal).
    static func firstDifference(_ a: GedcomFamilyGraph.Person, _ b: GedcomFamilyGraph.Person) -> String {
        if a.name != b.name { return "name" }
        if a.sex != b.sex { return "sex" }
        if a.childOfFamily != b.childOfFamily { return "childOfFamily" }
        if a.birthDate != b.birthDate { return "birthDate" }
        if a.deathDate != b.deathDate { return "deathDate" }
        if a.birthPlace != b.birthPlace { return "birthPlace" }
        if a.deathPlace != b.deathPlace { return "deathPlace" }
        if a.surname != b.surname { return "surname" }
        if a.familySearchID != b.familySearchID { return "familySearchID" }
        if a.alternateNames != b.alternateNames { return "alternateNames" }
        if a.alternateSurnames != b.alternateSurnames { return "alternateSurnames" }
        if a.childOfFamilies != b.childOfFamilies { return "childOfFamilies" }
        if a.spouseOfFamilies != b.spouseOfFamilies { return "spouseOfFamilies" }
        return "(unknown field)"
    }

    /// Mismatch classes → (count, first example), rendered as bounded lines
    /// in first-seen order. Like a std::map<string, pair<int,string>> with
    /// an insertion-order vector beside it.
    struct MismatchReport {
        static let exampleLimit = 160
        private var order: [String] = []
        private var counts: [String: Int] = [:]
        private var firstExample: [String: String] = [:]

        mutating func miss(_ cls: String, _ example: @autoclosure () -> String) {
            if counts[cls] == nil {
                order.append(cls)
                counts[cls] = 0
                firstExample[cls] = String(example().prefix(Self.exampleLimit))
            }
            counts[cls]! += 1
        }
        mutating func check(_ cls: String, ok: Bool, example: @autoclosure () -> String) {
            if !ok { miss(cls, example()) }
        }
        mutating func equal<T: Equatable>(_ cls: String, _ decoded: T, _ source: T) {
            if decoded != source {
                miss(cls, "\(String(describing: decoded).prefix(60)) ≠ \(String(describing: source).prefix(60))")
            }
        }
        var lines: [String] {
            order.map { cls in
                let n = counts[cls]!, ex = firstExample[cls]!
                let suffix = ex.isEmpty ? "" : " (first: \(ex))"
                return n == 1 ? "\(cls)\(suffix)" : "\(cls) ×\(n)\(suffix)"
            }
        }
    }

    // MARK: Source identity

    /// Identity of a source file for invalidation = its FULL SHA-256, hex
    /// (codex #792/#797, requirement #771). Size and mtime are deliberately
    /// NOT part of the key: a same-size, mtime-preserving edit in the
    /// middle of the file must be a miss, and a `touch` with identical
    /// bytes may stay a hit. Costs one streaming read of the file
    /// (~0.2 s per 100 MB on the M4); the store logs the measured time.
    public static func sourceKey(for url: URL) throws -> String {
        try fullSHA256(of: url)
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

        /// Codec 5 chunked section:
        ///   u32 count | u32 chunkSize | u32 recordsByteLength |
        ///   records… | u32 byteOffset[chunk] (relative to the first record)
        /// The offsets come AFTER the records (they are known only once the
        /// records are written); the reader jumps over the records by
        /// `recordsByteLength` to find them.
        mutating func chunkedSection(count: Int, _ record: (inout Writer, Int) -> Void) {
            u32(UInt32(count))
            u32(UInt32(GedcomCompiledTree.chunkSize))
            let lengthSlot = body.count
            u32(0)                                   // patched below
            let recordsStart = body.count
            var chunkOffsets: [UInt32] = []
            for i in 0..<count {
                if i % GedcomCompiledTree.chunkSize == 0 { chunkOffsets.append(UInt32(body.count - recordsStart)) }
                record(&self, i)
            }
            let recordsLength = UInt32(body.count - recordsStart)
            withUnsafeBytes(of: recordsLength.littleEndian) { body.replaceSubrange(lengthSlot..<lengthSlot + 4, with: $0) }
            for offset in chunkOffsets { u32(offset) }
        }
    }

    struct Reader {
        let bytes: UnsafeRawBufferPointer
        var cursor = 0
        /// One past the last readable byte (a chunk reader is fenced to
        /// its own chunk so a corrupt offset table cannot read a neighbour).
        var limit: Int
        var strings: [String] = []
        init(bytes: UnsafeRawBufferPointer) { self.bytes = bytes; self.limit = bytes.count }
        var atEnd: Bool { cursor == bytes.count }

        mutating func need(_ n: Int) throws {
            guard n >= 0, cursor + n <= limit else { throw CodecError.truncated }
        }

        /// Read a codec-5 chunked section (see `Writer.chunkedSection`):
        /// the chunks parse concurrently, each fenced to its byte range,
        /// and every chunk must consume EXACTLY its range. Returns the
        /// records in file order.
        mutating func chunkedSection<T>(_ record: (inout Reader) throws -> T) throws -> [T] {
            let count = Int(try u32())
            let size = Int(try u32())
            guard size > 0, size <= 1 << 20 else { throw CodecError.corrupt("chunk size \(size)") }
            let recordsLength = Int(try u32())
            let recordsStart = cursor
            _ = try slice(recordsLength)
            let chunks = (count + size - 1) / size
            var starts: [Int] = []
            starts.reserveCapacity(chunks + 1)
            for _ in 0..<chunks { starts.append(recordsStart + Int(try u32())) }
            starts.append(recordsStart + recordsLength)
            for c in 0..<chunks where !(starts[c] <= starts[c + 1] && starts[c] >= recordsStart) {
                throw CodecError.corrupt("chunk offsets")
            }
            if chunks > 0, starts[0] != recordsStart { throw CodecError.corrupt("chunk offsets") }
            let template = self
            var slots = [[T]](repeating: [], count: chunks)
            var failures = [CodecError?](repeating: nil, count: chunks)
            slots.withUnsafeMutableBufferPointer { slotBuffer in
                failures.withUnsafeMutableBufferPointer { failureBuffer in
                    DispatchQueue.concurrentPerform(iterations: chunks) { c in
                        var r = template
                        r.cursor = starts[c]
                        r.limit = starts[c + 1]
                        let lo = c * size, hi = min(count, lo + size)
                        var out: [T] = []
                        out.reserveCapacity(hi - lo)
                        do {
                            for _ in lo..<hi { out.append(try record(&r)) }
                            guard r.cursor == r.limit else { throw CodecError.corrupt("chunk length") }
                            slotBuffer[c] = out
                        } catch let error as CodecError {
                            failureBuffer[c] = error
                        } catch {
                            failureBuffer[c] = .corrupt("chunk \(c)")
                        }
                    }
                }
            }
            if let failure = failures.compactMap({ $0 }).first { throw failure }
            var all: [T] = []
            all.reserveCapacity(count)
            for slot in slots { all.append(contentsOf: slot) }
            return all
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
