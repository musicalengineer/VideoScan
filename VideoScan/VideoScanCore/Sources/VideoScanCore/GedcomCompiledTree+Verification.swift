// GedcomCompiledTree+Verification.swift (VideoScanCore)
import Foundation

extension GedcomCompiledTree {
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

        verifyScalars(decoded: decoded, source: source, report: &report)
        let sourceIndex = source.index
        verifyPeople(decoded: decoded, source: source, index: sourceIndex, report: &report)
        verifyFamilies(decoded: decoded, source: source, report: &report)
        verifyFamilySearchIndex(decoded: decoded, source: source, report: &report)
        verifyIndex(decoded: decoded.index, source: sourceIndex, report: &report)
        verifyRootQueries(decoded: decoded, source: source, report: &report)
        return report.lines
    }

    private static func verifyScalars(decoded: GedcomFamilyGraph, source: GedcomFamilyGraph, report: inout MismatchReport) {
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
    }

    private static func verifyPeople(decoded: GedcomFamilyGraph, source: GedcomFamilyGraph, index: GedcomFamilyGraph.TreeIndex, report: inout MismatchReport) {
        // People: every record, every field, walked in ordinal order (the
        // index's id table) so the "first example" is deterministic.
        // Person is Equatable, so one compare per record; on a mismatch
        // name the first differing field.
        for id in index.ids {
            let sp = source.people[id]!
            guard let dp = decoded.people[id] else { report.miss("person missing in decoded", id); continue }
            if dp != sp { report.miss("person differs", "\(id): \(Self.firstDifference(dp, sp))") }
        }
        for id in decoded.people.keys where source.people[id] == nil { report.miss("person extra in decoded", id) }
    }

    private static func verifyFamilies(decoded: GedcomFamilyGraph, source: GedcomFamilyGraph, report: inout MismatchReport) {
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
    }

    private static func verifyFamilySearchIndex(decoded: GedcomFamilyGraph, source: GedcomFamilyGraph, report: inout MismatchReport) {
        // FamilySearch → pointer table.
        let sfs = source.familySearchIndexTable, dfs = decoded.familySearchIndexTable
        for key in sfs.keys.sorted() {
            let value = sfs[key]!
            guard let d = dfs[key] else { report.miss("familySearch entry missing in decoded", key); continue }
            if d != value { report.miss("familySearch entry differs", "\(key): \(d) ≠ \(value)") }
        }
        for key in dfs.keys.sorted() where sfs[key] == nil { report.miss("familySearch entry extra in decoded", key) }
    }

    private static func verifyIndex(decoded d: GedcomFamilyGraph.TreeIndex, source s: GedcomFamilyGraph.TreeIndex, report: inout MismatchReport) {
        // Derived index: exhaustive Equatable compare against a fresh build.
        report.check("edge counts", ok: d.parents.count == s.parents.count && d.children.count == s.children.count
                     && d.spouses.count == s.spouses.count,
                     example: "parents \(d.parents.count)/\(s.parents.count) children \(d.children.count)/\(s.children.count) spouses \(d.spouses.count)/\(s.spouses.count)")
        report.check("index differs from a fresh build", ok: d == s, example: "")
    }

    private static func verifyRootQueries(decoded: GedcomFamilyGraph, source: GedcomFamilyGraph, report: inout MismatchReport) {
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
        if a.militaryFacts != b.militaryFacts { return "militaryFacts" }
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

}
