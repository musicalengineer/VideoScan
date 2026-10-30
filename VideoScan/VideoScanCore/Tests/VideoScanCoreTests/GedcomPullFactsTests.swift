// GedcomPullFactsTests.swift
//
// "Breen GEDCOM 26 Aug 2026" under the Family Tree title (Rick, 2026-10-30):
// the export date of each pull the loaded tree was built from, read from the
// pull's own HEAD, labelled by the first person's surname, and shown only
// for a file whose full SHA-256 matches the one the tree recorded.
//
// Five dimensions:
//   1. Logic/truth — getmyancestors, Ancestry and VideoScan-merge headers;
//                    missing / malformed DATE → nil; DATE without TIME; a
//                    level-2 DATE under SOUR is never the export date; no
//                    INDI → no label; resolution by name AND hash; grouping.
//   2. Scale       — a 100 MB pull: the header read touches only the head
//                    (budgeted); a pull with no INDI stops at the byte cap.
//   3. Media       — n/a (text files).
//   4. Isolation   — temp dirs only (synthetic /Testsurname/ names, never
//                    App Support or the archive); binary garbage, a directory
//                    named *.ged, a symlink and a hidden folder are ignored.
//   5. Sensor      — the end-to-end shape of Rick's tree (merge artifact as
//                    the physical source, pulls as logical sources, one in
//                    pulls/, one gone from disk) through a real compiled store.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("GEDCOM pull dates — header facts, hash-confirmed files, pane lines")
struct GedcomPullFactsTests {

    // MARK: Fixtures (synthetic names only — privacy rule 13)

    /// A getmyancestors-style pull. The SOUR block carries a level-2 DATE
    /// BEFORE the real `1 DATE`, so a parser that takes "any DATE in HEAD"
    /// gets it wrong.
    static func pull(surname: String = "Testsurname", headDate: String? = "26 Aug 2026",
                     time: String? = "05:07:30", source: String = "getmyancestors",
                     firstName: String? = nil, people: Int = 2, filler: String = "") -> String {
        var s = "0 HEAD\n1 CHAR UTF-8\n1 GEDC\n2 VERS 5.5.1\n2 FORM LINEAGE-LINKED\n"
        s += "1 SOUR \(source)\n2 VERS 1.2.0\n2 NAME \(source)\n2 DATE 1 JAN 1999\n"
        if let headDate { s += "1 DATE \(headDate)\n" }
        if let time { s += "2 TIME \(time)\n" }
        s += "1 SUBM @SUBM@\n0 @SUBM@ SUBM\n1 NAME Test Submitter\n2 DATE 2 FEB 1998\n"
        s += filler
        for i in 1...max(people, 1) {
            let name = i == 1 ? (firstName ?? "Pat Example /\(surname)/ Jr") : "Kid\(i) /\(surname)/"
            s += "0 @I\(i)\(surname)@ INDI\n1 NAME \(name)\n1 SEX \(i % 2 == 0 ? "F" : "M")\n"
            s += "1 BIRT\n2 DATE \(10 + i) MAR 19\(50 + i)\n"
        }
        s += "0 TRLR\n"
        return s
    }

    static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0) -> Date {
        GedcomHeaderFacts.utcCalendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: mi, second: s))!
    }

    final class Dir {
        let root: URL
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("GedcomPullFacts-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        @discardableResult
        func write(_ text: String, _ relative: String) throws -> URL {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            return url
        }
        deinit { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: 1. Header facts — logic and truth

    @Test("getmyancestors header: DATE + TIME, program, first person's surname (and print them)")
    func getmyancestorsHeader() throws {
        let dir = try Dir()
        let url = try dir.write(Self.pull(), "familysearch-tree-test.ged")
        let facts = try #require(GedcomHeaderFacts.read(from: url))
        // Rick: "perhaps the test prints it out".
        print("GEDCOM header facts: export=\(facts.exportText ?? "nil") program=\(facts.sourceProgram ?? "nil") "
              + "surname=\(facts.firstPersonSurname ?? "nil") pane=\"\(facts.firstPersonSurname ?? "?") GEDCOM "
              + "\(facts.exportDate.map(GedcomHeaderFacts.dayText) ?? "?")\"")
        #expect(facts.exportDate == Self.date(2026, 8, 26, 5, 7, 30))
        #expect(facts.exportDateHasTime)
        #expect(facts.exportText == "26 Aug 2026 05:07:30")
        #expect(facts.sourceProgram == "getmyancestors")
        #expect(facts.firstPersonSurname == "Testsurname")
    }

    @Test("Ancestry header: one-digit day, no TIME")
    func ancestryHeader() {
        let text = "0 HEAD\n1 SOUR Ancestry.com Family Trees\n2 VERS 2025.08\n1 DATE 6 Aug 2026\n1 GEDC\n2 VERS 5.5.1\n"
            + "0 @P1@ INDI\n1 NAME Lee /Ancestrytest/\n0 TRLR\n"
        let facts = GedcomHeaderFacts.parse(lines: text.split(separator: "\n"))
        #expect(facts.exportDate == Self.date(2026, 8, 6))
        #expect(!facts.exportDateHasTime)
        #expect(facts.exportText == "6 Aug 2026")
        #expect(facts.sourceProgram == "Ancestry.com Family Trees")
        #expect(facts.firstPersonSurname == "Ancestrytest")
    }

    @Test("VideoScan merge header: uppercase month parses")
    func videoScanMergeHeader() {
        let facts = GedcomHeaderFacts.parse(lines: Self.pull(headDate: "17 SEP 2026", time: nil, source: "VideoScan")
            .split(separator: "\n"))
        #expect(facts.exportDate == Self.date(2026, 9, 17))
        #expect(facts.sourceProgram == "VideoScan")
        #expect(GedcomHeaderFacts.dayText(facts.exportDate!) == "17 Sep 2026")
    }

    @Test("Missing HEAD DATE → nil, never today; the SOUR's level-2 DATE is not taken")
    func missingHeadDate() {
        let facts = GedcomHeaderFacts.parse(lines: Self.pull(headDate: nil, time: "05:07:30").split(separator: "\n"))
        #expect(facts.exportDate == nil)
        #expect(facts.exportText == nil)
        #expect(facts.firstPersonSurname == "Testsurname")
    }

    @Test("Malformed HEAD DATEs → nil", arguments: [
        "26 August 2026", "Aug 26 2026", "32 Aug 2026", "29 FEB 2025", "26 Aug 26", "ABT 2026",
        "26 Aug 2026 extra", "", "0 Aug 2026", "2026-08-26", "26 Xyz 2026", "1x Aug 2026"])
    func malformedDate(_ text: String) {
        let facts = GedcomHeaderFacts.parse(lines: Self.pull(headDate: text, time: nil).split(separator: "\n"))
        #expect(facts.exportDate == nil, "\(text)")
    }

    @Test("Leap day and lowercase month are valid")
    func validEdges() {
        #expect(GedcomHeaderFacts.exportDate(date: "29 feb 2024", time: nil)?.date == Self.date(2024, 2, 29))
        #expect(GedcomHeaderFacts.exportDate(date: "01 Jan 2026", time: "23:59")?.date == Self.date(2026, 1, 1, 23, 59))
        #expect(GedcomHeaderFacts.exportDate(date: "1 Jan 2026", time: "05:07:30.123")?.date == Self.date(2026, 1, 1, 5, 7, 30))
    }

    @Test("A malformed TIME keeps the file's own day and drops only the time")
    func malformedTime() {
        let parsed = GedcomHeaderFacts.exportDate(date: "26 Aug 2026", time: "25:99")
        #expect(parsed?.date == Self.date(2026, 8, 26))
        #expect(parsed?.hasTime == false)
    }

    @Test("No INDI → surname nil; INDI without NAME → nil; NAME without slashes → nil")
    func noLabel() {
        let noIndi = "0 HEAD\n1 SOUR x\n1 DATE 1 Jan 2026\n0 @F1@ FAM\n0 TRLR\n"
        #expect(GedcomHeaderFacts.parse(lines: noIndi.split(separator: "\n")).firstPersonSurname == nil)
        #expect(GedcomHeaderFacts.parse(lines: noIndi.split(separator: "\n")).exportDate == Self.date(2026, 1, 1))
        let noName = "0 HEAD\n1 DATE 1 Jan 2026\n0 @I1@ INDI\n1 SEX M\n0 @I2@ INDI\n1 NAME Later /Notfirst/\n0 TRLR\n"
        #expect(GedcomHeaderFacts.parse(lines: noName.split(separator: "\n")).firstPersonSurname == nil,
                "the label is the FIRST person's; a later person's surname is a guess")
        let bare = Self.pull(firstName: "Plainname Nosurname")
        #expect(GedcomHeaderFacts.parse(lines: bare.split(separator: "\n")).firstPersonSurname == nil)
        #expect(GedcomHeaderFacts.parse(lines: Self.pull(firstName: "/Onlysurname/").split(separator: "\n"))
            .firstPersonSurname == "Onlysurname")
    }

    @Test("CRLF line ends, a BOM and indented lines read the same")
    func lineEndings() throws {
        let dir = try Dir()
        let text = "\u{FEFF}" + Self.pull().replacingOccurrences(of: "\n", with: "\r\n")
            .replacingOccurrences(of: "\r\n1 DATE", with: "\r\n  1 DATE")
        let facts = try #require(GedcomHeaderFacts.read(from: try dir.write(text, "crlf.ged")))
        #expect(facts.exportDate == Self.date(2026, 8, 26, 5, 7, 30))
        #expect(facts.firstPersonSurname == "Testsurname")
    }

    @Test("Only the first HEAD counts; a TIME under a different level-1 tag is not the export time")
    func headScoping() {
        let text = "0 HEAD\n1 DATE 3 Mar 2026\n1 SOUR p\n2 TIME 11:11:11\n0 HEAD\n1 DATE 4 Apr 2027\n"
            + "0 @I1@ INDI\n1 NAME A /Firsthead/\n"
        let facts = GedcomHeaderFacts.parse(lines: text.split(separator: "\n"))
        #expect(facts.exportDate == Self.date(2026, 3, 3))
        #expect(!facts.exportDateHasTime)
    }

    // MARK: 2. Resolution — name AND hash

    @Test("A logical source in a subdirectory is found by name and confirmed by SHA-256")
    func foundInSubdirectory() throws {
        let dir = try Dir()
        let url = try dir.write(Self.pull(surname: "Testsurname"), "pulls/test-20generations.ged")
        let sha = try GedcomCompiledTree.fullSHA256(of: url)
        let facts = GedcomPullDescriber(searchRoots: [dir.root])
            .describe([GedcomPullSource(fileName: "test-20generations.ged", sha256: sha)])
        #expect(facts.count == 1)
        #expect(facts[0].status == .verified)
        #expect(facts[0].url?.lastPathComponent == "test-20generations.ged")
        #expect(facts[0].size == Self.pull().utf8.count)
        #expect(facts[0].label == "Testsurname")
        #expect(GedcomPullLine.lines(from: facts).map(\.text) == ["Testsurname GEDCOM 26 Aug 2026"])
    }

    @Test("Same name, different bytes → not described (no pane line)")
    func wrongHash() throws {
        let dir = try Dir()
        try dir.write(Self.pull(surname: "Testsurname"), "a.ged")
        let facts = GedcomPullDescriber(searchRoots: [dir.root])
            .describe([GedcomPullSource(fileName: "a.ged", sha256: String(repeating: "0", count: 64))])
        #expect(facts[0].status == .hashMismatch(candidates: 1))
        #expect(facts[0].label == nil)
        #expect(GedcomPullLine.lines(from: facts).isEmpty)
        #expect(facts[0].logLine(ingest: nil, generation: "gen-x").contains("NOT ON DISK file=a.ged"))
    }

    @Test("Missing file → not on disk, logged, no pane line")
    func missingFile() throws {
        let dir = try Dir()
        let facts = GedcomPullDescriber(searchRoots: [dir.root])
            .describe([GedcomPullSource(fileName: "gone.ged", sha256: "f0351347" + String(repeating: "a", count: 56))])
        #expect(facts[0].status == .notOnDisk)
        #expect(GedcomPullLine.lines(from: facts).isEmpty)
        let line = facts[0].logLine(ingest: Self.date(2026, 10, 21, 21, 10, 45), generation: "gen-1")
        #expect(line == "[family-tree] gedcom pull NOT ON DISK file=gone.ged sha=f0351347 "
                + "ingest=2026-10-21T21:10:45Z generation=gen-1")
    }

    @Test("Two copies with the same name: the one with the recorded bytes is described")
    func duplicateNames() throws {
        let dir = try Dir()
        try dir.write(Self.pull(surname: "Wrongcopy"), "old/x.ged")
        let right = try dir.write(Self.pull(surname: "Rightcopy"), "pulls/x.ged")
        let facts = GedcomPullDescriber(searchRoots: [dir.root])
            .describe([GedcomPullSource(fileName: "x.ged", sha256: try GedcomCompiledTree.fullSHA256(of: right))])
        #expect(facts[0].label == "Rightcopy")
    }

    @Test("Two pulls with the same surname → one line with the newer date; order is first appearance")
    func grouping() throws {
        let dir = try Dir()
        let old = try dir.write(Self.pull(surname: "Testsurname", headDate: "20 Aug 2026"), "3gen.ged")
        let new = try dir.write(Self.pull(surname: "Testsurname", headDate: "26 Aug 2026"), "20gen.ged")
        let other = try dir.write(Self.pull(surname: "Othersurname", headDate: "28 Aug 2026"), "pulls/other.ged")
        let sources = try [new, old, other].map { GedcomPullSource(fileName: $0.lastPathComponent,
                                                                   sha256: try GedcomCompiledTree.fullSHA256(of: $0)) }
        let lines = GedcomPullLine.lines(from: GedcomPullDescriber(searchRoots: [dir.root]).describe(sources))
        #expect(lines.map(\.text) == ["Testsurname GEDCOM 26 Aug 2026", "Othersurname GEDCOM 28 Aug 2026"])
        #expect(lines[0].facts.count == 2)
        let help = lines[0].helpText(ingest: Self.date(2026, 10, 21))
        #expect(help.hasPrefix("Ingested into this tree 21 Oct 2026"))
        #expect(help.contains("20gen.ged — exported 26 Aug 2026 05:07:30") && help.contains("3gen.ged — exported 20 Aug 2026"))
    }

    @Test("A verified pull with no header date still draws its label, saying so")
    func noDateLine() throws {
        let dir = try Dir()
        let url = try dir.write(Self.pull(headDate: nil, time: nil), "n.ged")
        let facts = GedcomPullDescriber(searchRoots: [dir.root])
            .describe([GedcomPullSource(fileName: "n.ged", sha256: try GedcomCompiledTree.fullSHA256(of: url))])
        #expect(GedcomPullLine.lines(from: facts).map(\.text) == ["Testsurname GEDCOM, no date in file"])
    }

    @Test("Sources: logical sources with a hash; a single-file graph describes its own file")
    func whichSources() throws {
        typealias P = GedcomFamilyGraph.SourceProvenance
        let logical = [P(name: "a.ged", sha256: "AA", droppedLineCount: 0), P(name: "b.ged", sha256: nil, droppedLineCount: 0)]
        let physical = [P(name: "merged.ged", sha256: "mm", droppedLineCount: 0)]
        #expect(GedcomPullSource.describing(logical: logical, physical: physical).map(\.fileName) == ["a.ged"])
        #expect(GedcomPullSource.describing(logical: logical, physical: physical)[0].sha256 == "aa")
        #expect(GedcomPullSource.describing(logical: [], physical: physical).map(\.fileName) == ["merged.ged"])

        let dir = try Dir()
        let url = try dir.write(Self.pull(), "single.ged")
        let graph = try #require(GedcomFamilyGraph(fileURL: url))
        let sources = GedcomPullSource.describing(graph)
        #expect(sources == [GedcomPullSource(fileName: "single.ged", sha256: try GedcomCompiledTree.fullSHA256(of: url))])
    }

    @Test("Re-describing an unchanged file does not rehash it; a changed mtime does")
    func hashCache() throws {
        let dir = try Dir()
        let url = try dir.write(Self.pull(), "c.ged")
        let sha = try GedcomCompiledTree.fullSHA256(of: url)
        let counter = Counter()
        var describer = GedcomPullDescriber(searchRoots: [dir.root])
        describer.hasher = { counter.bump(); return try GedcomCompiledTree.fullSHA256(of: $0) }
        let source = GedcomPullSource(fileName: "c.ged", sha256: sha)
        #expect(describer.describe([source])[0].status == .verified)
        #expect(describer.describe([source])[0].status == .verified)
        #expect(counter.value == 1)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: url.path)
        #expect(describer.describe([source])[0].status == .verified)
        #expect(counter.value == 2)
    }

    @Test("The hash cache is bounded")
    func cacheBound() {
        let cache = GedcomPullHashCache()
        for i in 0..<(GedcomPullHashCache.capacity * 3) {
            _ = cache.sha(path: "/p\(i)", size: i, mtime: 0, compute: { "x" })
            #expect(cache.count <= GedcomPullHashCache.capacity)
        }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.withLock { n += 1 } }
        var value: Int { lock.withLock { n } }
    }

    // MARK: 2. Scale

    @Test("100 MB pull: the header read touches only the head (budget 100 ms)")
    func scaleHugePull() throws {
        let dir = try Dir()
        let url = dir.root.appendingPathComponent("huge.ged")
        let head = Self.pull(people: 3).replacingOccurrences(of: "0 TRLR\n", with: "")
        FileManager.default.createFile(atPath: url.path, contents: Data(head.utf8))
        let handle = try FileHandle(forWritingTo: url)
        let block = Data(String(repeating: "0 @Ix@ INDI\n1 NAME Filler /Filler/\n1 SEX U\n", count: 25_000).utf8)
        var written = head.utf8.count
        while written < 100_000_000 { try handle.seekToEnd(); handle.write(block); written += block.count }
        try handle.close()
        let loadBefore = TimingBudget.sampleLoad()
        let clock = ContinuousClock()
        let start = clock.now
        let facts = try #require(GedcomHeaderFacts.read(from: url))
        let elapsed = clock.now - start
        print("GEDCOM header read on a \(written / 1_000_000) MB pull: \(elapsed)")
        #expect(facts.firstPersonSurname == "Testsurname")
        #expect(facts.exportDate == Self.date(2026, 8, 26, 5, 7, 30))
        // Reads one 64 KiB chunk: ~2 ms idle. A busy machine is a known
        // issue, not a red (GH #208).
        expectWithinTimingBudget("GEDCOM header read, 100 MB pull", measured: elapsed,
                                 budget: .milliseconds(100), loadBefore: loadBefore)
    }

    @Test("No INDI within the byte cap: surname nil, not a guess; a larger cap reaches it")
    func byteCap() throws {
        let dir = try Dir()
        let filler = String(repeating: "0 @N1@ NOTE filler text that is not a person\n", count: 20_000)  // ~0.9 MB
        let url = try dir.write("0 HEAD\n1 DATE 2 Jan 2026\n" + filler + "0 @I1@ INDI\n1 NAME Far /Toofar/\n", "noindi.ged")
        let capped = try #require(GedcomHeaderFacts.read(from: url, byteCap: 256 << 10))
        #expect(capped.exportDate == Self.date(2026, 1, 2))
        #expect(capped.firstPersonSurname == nil, "past the byte cap is not read")
        #expect(GedcomHeaderFacts.read(from: url)?.firstPersonSurname == "Toofar", "inside the default 8 MiB cap")
        #expect(GedcomHeaderFacts.defaultByteCap == 8 << 20)
    }

    // MARK: 4. Isolation — poisoned inputs

    @Test("Binary garbage, a directory named .ged, a symlink and a hidden folder are ignored")
    func poisoned() throws {
        let dir = try Dir()
        let garbage = dir.root.appendingPathComponent("garbage.ged")
        try Data((0..<70_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: garbage)
        let g = try #require(GedcomHeaderFacts.read(from: garbage))
        #expect(g == GedcomHeaderFacts())
        #expect(GedcomHeaderFacts.read(from: dir.root.appendingPathComponent("absent.ged")) == nil)

        try FileManager.default.createDirectory(at: dir.root.appendingPathComponent("folder.ged"), withIntermediateDirectories: true)
        let real = try dir.write(Self.pull(surname: "Hiddensurname"), ".hidden/h.ged")
        try FileManager.default.createSymbolicLink(at: dir.root.appendingPathComponent("h.ged"), withDestinationURL: real)
        let sha = try GedcomCompiledTree.fullSHA256(of: real)
        let facts = GedcomPullDescriber(searchRoots: [dir.root]).describe([
            GedcomPullSource(fileName: "h.ged", sha256: sha),
            GedcomPullSource(fileName: "folder.ged", sha256: sha),
        ])
        #expect(facts.map(\.status) == [.notOnDisk, .notOnDisk])
        // A root that does not exist is not an error.
        #expect(GedcomPullDescriber(searchRoots: [dir.root.appendingPathComponent("nope")])
            .describe([GedcomPullSource(fileName: "h.ged", sha256: sha)])[0].status == .notOnDisk)
    }

    // MARK: 5. Sensor — the shape of Rick's live tree

    @Test("Merge artifact + three logical pulls (one in pulls/, one deleted): two lines, one NOT ON DISK, manifest matched")
    func liveShape() throws {
        let dir = try Dir()
        let a = try dir.write(Self.pull(surname: "Alphasurname", headDate: "26 Aug 2026"), "tree-20generations.ged")
        let a3 = try dir.write(Self.pull(surname: "Alphasurname", headDate: "20 Aug 2026", people: 1), "tree-3gen.ged")
        let b = try dir.write(Self.pull(surname: "Betasurname", headDate: "28 Aug 2026"), "pulls/beta-20generations.ged")
        let graphs = try [a, a3, b].map { try #require(GedcomFamilyGraph(fileURL: $0)) }
        let merged = graphs[0].merged(with: graphs[1]).merged(with: graphs[2])
        let artifact = try dir.write(merged.gedcomText(provenance: "test artifact"), "merged-test.ged")
        try FileManager.default.removeItem(at: a3)                     // the 3-gen pull is gone from disk
        let parsed = try #require(GedcomFamilyGraph(fileURL: artifact))
        let store = FamilyGraphCompiledStore(root: dir.root.appendingPathComponent("compiled"))
        let promoted = try #require(store.ingest(graph: parsed, sources: [artifact]))

        let manifest = try #require(store.manifest(describing: promoted))
        #expect(manifest.sources.map(\.fileName) == ["merged-test.ged"])
        let sources = GedcomPullSource.describing(promoted)
        #expect(sources.map(\.fileName) == ["tree-20generations.ged", "tree-3gen.ged", "beta-20generations.ged"])

        let facts = GedcomPullDescriber(searchRoots: [dir.root]).describe(sources)
        #expect(facts.map(\.status) == [.verified, .notOnDisk, .verified])
        let lines = GedcomPullLine.lines(from: facts)
        #expect(lines.map(\.text) == ["Alphasurname GEDCOM 26 Aug 2026", "Betasurname GEDCOM 28 Aug 2026"])
        for fact in facts { print(fact.logLine(ingest: manifest.createdAt, generation: manifest.generation)) }
        #expect(facts[0].logLine(ingest: manifest.createdAt, generation: manifest.generation)
            .contains("label=Alphasurname header=26 Aug 2026 05:07:30 file=tree-20generations.ged"))
        #expect(facts[0].logLine(ingest: manifest.createdAt, generation: manifest.generation)
            .contains("generation=\(manifest.generation)"))

        // A graph the store never compiled has no manifest: ingest stays unknown.
        #expect(store.manifest(describing: graphs[0]) == nil)
    }
}
