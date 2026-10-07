// GedcomCompiledTree+Encoding.swift (VideoScanCore)
import CryptoKit
import Foundation

extension GedcomCompiledTree {
    public static func encode(_ graph: GedcomFamilyGraph) -> Data {
        // Canonical provenance (codec 4): list + local remainder, total
        // unchanged; `decode` restores exactly these two.
        let graph = graph.canonicalized()
        let index = graph.index
        var writer = Writer()
        // Everyone in ordinal order so the people table IS index.ids.
        let people = index.ids.map { graph.people[$0]! }
        let familyIDs = graph.familyTable.keys.sorted()
        let families = familyIDs.map { graph.familyTable[$0]! }

        writer.people(people)
        writer.families(families, ids: familyIDs)
        // Roots (a list, so a merged two-root tree fits the same layout)
        writer.refs(graph.rootPersonIDs)
        writer.familySearchIndex(graph.familySearchIndexTable)
        writer.provenance(graph)
        writer.index(index)
        return envelope(payload: writer.payload())
    }

    private static func envelope(payload: Data) -> Data {
        var out = Data(capacity: payload.count + 48)
        out.append(contentsOf: magic)
        out.append(le(codecVersion))
        out.append(le(GedcomFamilyGraph.TreeIndex.formatVersion))
        out.append(le(UInt64(payload.count)))
        out.append(payload)
        out.append(contentsOf: Array(SHA256.hash(data: payload)))
        return out
    }
}

private extension GedcomCompiledTree.Writer {
    mutating func people(_ people: [GedcomFamilyGraph.Person]) {
        // People (codec 5: chunked section — see `Writer.chunkedSection`).
        chunkedSection(count: people.count) { w, i in
            let p = people[i]
            w.ref(p.id)
            w.ref(p.name)
            w.ref(p.sex)
            w.ref(p.childOfFamily)
            w.ref(p.birthDate)
            w.ref(p.deathDate)
            w.ref(p.birthPlace)
            w.ref(p.deathPlace)
            w.ref(p.surname)
            w.ref(p.familySearchID)
            w.refs(p.alternateNames)
            w.refs(p.alternateSurnames)
            w.refs(p.childOfFamilies)
            w.refs(p.spouseOfFamilies)
            w.refs(p.militaryFacts.flatMap {   // codec 7
                [$0.tag, $0.value ?? "", $0.type ?? "", $0.date ?? "", $0.place ?? "", $0.note ?? ""]
            })
        }
    }

    mutating func families(_ families: [GedcomFamilyGraph.Family], ids: [String]) {
        // Families
        chunkedSection(count: families.count) { w, i in
            let f = families[i]
            w.ref(ids[i])
            w.ref(f.husband)
            w.ref(f.wife)
            w.ref(f.marriageDate)
            w.refs(f.children)
            w.ref(f.familySearchID)   // codec 6
        }
    }

    mutating func familySearchIndex(_ table: [String: String]) {
        // FamilySearch → pointer
        let fs = table.keys.sorted()
        u32(UInt32(fs.count))
        for key in fs { ref(key); ref(table[key]) }
    }

    mutating func provenance(_ graph: GedcomFamilyGraph) {
        // Provenance
        ref(graph.sourceFileName)
        ref(graph.sourceDirectory)
        f64(graph.sourceModifiedAt?.timeIntervalSince1970 ?? .nan)
        // Codec 2: merged-tree provenance (two-root merge, 2026-08-28).
        refs(graph.sourceFileNames)
        u32(graph.isMergedArtifact ? 1 : 0)
        // Graph-LOCAL loss (codec 4: the canonical remainder, 0 for a file parse).
        u32(UInt32(clamping: graph.droppedLineCount))
        ref(graph.headNote)
        // Positional source list (name, sha256, that source's dropped lines).
        let provenance = graph.sourceProvenance
        u32(UInt32(provenance.count))
        for p in provenance { ref(p.name); ref(p.sha256); u32(UInt32(clamping: p.droppedLineCount)) }
        // The graph's OWN file digest, its own scalar (see GedcomFamilyGraph.sourceFingerprint).
        ref(graph.sourceFingerprint)
    }

    mutating func index(_ index: GedcomFamilyGraph.TreeIndex) {
        // Index
        i32s(index.nameRank)
        i32s(index.parentStart)
        i32s(index.parents)
        i32s(index.motherOffset)
        i32s(index.childStart)
        i32s(index.children)
        i32s(index.spouseStart)
        i32s(index.spouses)
        for table in [index.tokens, index.likeTokens, index.surnames, index.givenNames, index.familySearchIDs] {
            refs(table.keys)
            i32s(table.start)
            i32s(table.postings)
        }
        i32s(index.recordStart)
        i32s(index.recordTokenStart)
        i32s(index.recordTokenIDs)
        i32s(index.recordLikeIDs)
        i32s(index.marriedStart)
        i32s(index.marriedIDs)
        i32s(index.surnameStart)
        i32s(index.surnameIDs)
        i32s(index.sidebarOrder)
        bytes(index.sidebarHaystack)
        i32s(index.sidebarStart)
        // Launch tables (TreeIndex formatVersion 2)
        refs(index.identityKeys)
        i32s(index.givenStart)
        i32s(index.givenIDs)
        i32s(index.surnameTokenStart)
        i32s(index.surnameTokenIDs)
        i32s(index.suffixIDs)
        refs(index.lifeYears)
    }

    func payload() -> Data {
        // Payload: string table (count, blob, offsets), then the record body.
        var payload = Data()
        payload.reserveCapacity(body.count + blob.count + offsets.count * 4 + 16)
        var head = GedcomCompiledTree.Writer()
        head.u32(UInt32(offsets.count - 1))
        head.u32(UInt32(blob.count))
        payload.append(contentsOf: head.body)
        payload.append(contentsOf: blob)
        var encodedOffsets = GedcomCompiledTree.Writer()
        encodedOffsets.i32s(offsets)
        payload.append(contentsOf: encodedOffsets.body)
        payload.append(contentsOf: body)

        return payload
    }
}
