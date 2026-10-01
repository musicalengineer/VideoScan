// GedcomParserPropertyTests.swift
// Generated-input properties for the two GEDCOM readers (Rick approved
// 2026-10-01): GedcomFamilyGraph(gedcomText:) and GedcomLifeDetails.
//
// The generator builds a small synthetic tree as DATA (people, families,
// notes, occupations), then renders it to GEDCOM text with the variety real
// exports have: LF / CRLF / CR line ends, indented lines, NOTE text split by
// CONC at arbitrary points (mid-word AND right after a space) and by CONT at
// its newlines, unknown tags with random nesting, unmodelled top-level
// records, duplicate ids, cycles (a self-parent, two-person cycles), random
// dangling pointers, and truncation. Properties:
//
//   G1  No crash or hang: both readers, and every graph walk the app runs
//       on a person, finish within a budget on any generated file —
//       including cyclic and truncated ones.
//   G2  CONC/CONT reproduce the note text exactly (outer whitespace aside,
//       which the reader trims by design) — inline notes, NOTE records by
//       pointer, and CONC-split occupations.
//   G3  The parse is the same whether the file uses LF, CRLF or CR.
//   G4  Unknown tags and unmodelled records never change what is read.
//   G5  Writer round trip: graph → gedcomText → graph keeps every person,
//       and a HEAD NOTE of any text reads back identically (the writer's
//       documented promise).
//
// Synthetic only: invented given names and surnames, real place names.

import Foundation
import Testing
@testable import VideoScanCore

// MARK: - The generated tree

struct GenNote {
    let text: String
    /// Inline under the person, or a NOTE record reached by pointer.
    let asRecord: Bool
}

struct GenPerson {
    let id: String
    var given: String
    var surname: String?
    var sex: String
    var birthDate: String?
    var birthPlace: String?
    var deathDate: String?
    var deathPlace: String?
    var famc: [String] = []
    var fams: [String] = []
    var notes: [GenNote] = []
    var occupation: String?
}

struct GenFamily {
    let id: String
    var husband: String?
    var wife: String?
    var children: [String] = []
    var marriageDate: String?
}

struct GenTree: CustomStringConvertible {
    var people: [GenPerson]
    var families: [GenFamily]
    /// Rendering choices, kept with the data so a seed reproduces a file.
    var noiseSeed: UInt64
    var splitSeed: UInt64
    var duplicateRecord: Bool

    var description: String {
        "\(people.count) people, \(families.count) families, notes: \(people.reduce(0) { $0 + $1.notes.count })"
    }
}

enum GedcomGenerator {
    static let givens = ["Ansel", "Brida", "Corwin", "Delphine", "Ewart", "Fenna", "Gideon", "Hesper", "Ivo", "Jessamy"]
    static let surnames = ["Quillfeather", "Larkspur", "Fenlane", "Polwenna", "Testerly", "Glendarroch", "Marrowby"]
    static let places = ["Boston, Suffolk, Massachusetts, USA", "Cork, County Cork, Ireland",
                         "Leeds, Yorkshire, England", "Derry, Rockingham, New Hampshire", "Glasgow, Lanarkshire, Scotland"]
    static let noteWords = ["the", "farm", "was", "sold", "in", "spring;", "letters", "survive.", "Mill", "St.",
                            "café", "naïve", "O’Brien’s", "no.", "12", "(see", "deed)", "—", "&", "x"]

    static func date(_ g: inout SeededGenerator) -> String {
        DateGenerator.gedcomDate(&g).text
    }

    /// Note text: words joined by one to three spaces, an occasional
    /// newline (rendered as CONT) and blank line; no outer whitespace.
    static func noteText(_ g: inout SeededGenerator, maxWords: Int = 60) -> String {
        var s = ""
        for i in 0..<g.int(1...maxWords) {
            if i > 0 {
                if g.chance(0.08) {
                    s += g.chance(0.2) ? "\n\n" : "\n"
                    if g.chance(0.2) { s += "  " }          // an indented line
                } else {
                    s += String(repeating: " ", count: g.chance(0.15) ? g.int(2...3) : 1)
                }
            }
            s += g.pick(noteWords)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func tree(_ g: inout SeededGenerator) -> GenTree {
        let n = g.int(1...14)
        var people: [GenPerson] = (1...n).map { i in
            GenPerson(id: "@I\(i)@", given: g.pick(givens), surname: g.chance(0.85) ? g.pick(surnames) : nil,
                      sex: g.pick(["M", "F", "", "U"]))
        }
        for i in people.indices {
            if g.chance(0.8) { people[i].birthDate = date(&g) }
            if g.chance(0.6) { people[i].birthPlace = g.pick(places) }
            if g.chance(0.5) { people[i].deathDate = date(&g) }
            if g.chance(0.3) { people[i].deathPlace = g.pick(places) }
            for _ in 0..<g.int(0...2) { people[i].notes.append(GenNote(text: noteText(&g), asRecord: g.chance(0.3))) }
            if g.chance(0.3) { people[i].occupation = noteText(&g, maxWords: 6).replacingOccurrences(of: "\n", with: " ") }
        }
        // Families wired at random from the same pool: cycles (a person
        // their own parent, two people each other's parent) arise naturally
        // and are also forced now and then.
        let familyCount = g.int(0...max(1, n / 2 + 1))
        var families: [GenFamily] = []
        for f in 0..<familyCount {
            var fam = GenFamily(id: "@F\(f + 1)@")
            if g.chance(0.85) { fam.husband = g.pick(people).id }
            if g.chance(0.85) { fam.wife = g.pick(people).id }
            for _ in 0..<g.int(0...3) { fam.children.append(g.pick(people).id) }
            if g.chance(0.1), let h = fam.husband { fam.children.append(h) }          // self-parent
            if g.chance(0.3) { fam.marriageDate = date(&g) }
            families.append(fam)
        }
        if families.count >= 2, g.chance(0.2) {                                         // two-person cycle
            let a = people[0].id, b = people[people.count - 1].id
            families[0].husband = a; families[0].children.append(b)
            families[1].husband = b; families[1].children.append(a)
        }
        // Person pointers: mostly reciprocal, sometimes dangling.
        for fam in families {
            for spouse in [fam.husband, fam.wife].compactMap({ $0 }) {
                if let i = people.firstIndex(where: { $0.id == spouse }), g.chance(0.9) { people[i].fams.append(fam.id) }
            }
            for child in fam.children {
                if let i = people.firstIndex(where: { $0.id == child }), g.chance(0.9) { people[i].famc.append(fam.id) }
            }
        }
        if g.chance(0.1) { people[0].famc.append("@F999@") }                             // dangling
        return GenTree(people: people, families: families, noiseSeed: g.next(), splitSeed: g.next(),
                       duplicateRecord: g.chance(0.1))
    }

    // MARK: Rendering

    struct RenderOptions {
        var lineEnding = "\n"
        var noise = false
        var indent = false
    }

    /// The tree as GEDCOM lines (no line endings yet).
    static func lines(_ tree: GenTree, noise: Bool, indent: Bool = false) -> [String] {
        var split = SeededGenerator(seed: tree.splitSeed)
        var noiseG = SeededGenerator(seed: tree.noiseSeed)
        var out = ["0 HEAD", "1 SOUR Synthetic", "1 GEDC", "2 VERS 5.5.1", "1 CHAR UTF-8"]
        func noiseBlock() {
            guard noise, noiseG.chance(0.5) else { return }
            let tag = noiseG.pick(["_UID", "_XYZ", "CHAN", "RIN", "_PHOTO", "OBJE", "SOUR", "REFN"])
            out.append("1 \(tag) \(noiseG.pick(["", "x", "@S1@", "some value"]))".trimmingCharacters(in: .whitespaces))
            // Sub-lines: usually one level deeper, sometimes a jump (to 99).
            var level = 1
            for _ in 0..<noiseG.int(0...4) {
                level = noiseG.chance(0.7) ? level + 1 : noiseG.int(2...99)
                out.append("\(level) _SUB\(noiseG.int(0...9)) v\(noiseG.int(0...99))")
            }
        }
        func topLevelNoise() {
            guard noise, noiseG.chance(0.3) else { return }
            let kind = noiseG.pick(["SOUR", "OBJE", "REPO", "SUBM"])
            out.append("0 @\(kind.prefix(1))\(noiseG.int(1...9))@ \(kind)")
            for _ in 0..<noiseG.int(0...3) { out.append("1 TITL \(noiseG.pick(noteWords))") }
        }
        var records: [String: String] = [:]   // NOTE record id → text
        var renderedPeople = tree.people
        if tree.duplicateRecord, let first = tree.people.first { renderedPeople.append(first) }
        for p in renderedPeople {
            topLevelNoise()
            out.append("0 \(p.id) INDI")
            let surname = p.surname.map { " /\($0)/" } ?? ""
            out.append("1 NAME \(p.given)\(surname)")
            noiseBlock()
            if !p.sex.isEmpty { out.append("1 SEX \(p.sex)") }
            if p.birthDate != nil || p.birthPlace != nil {
                out.append("1 BIRT")
                if let d = p.birthDate { out.append("2 DATE \(d)") }
                if let pl = p.birthPlace { out.append("2 PLAC \(pl)") }
                if noise, noiseG.chance(0.3) { out.append("2 SOUR @S1@"); out.append("3 PAGE p. 4") }
            }
            if p.deathDate != nil || p.deathPlace != nil {
                out.append("1 DEAT")
                if let d = p.deathDate { out.append("2 DATE \(d)") }
                if let pl = p.deathPlace { out.append("2 PLAC \(pl)") }
            }
            noiseBlock()
            if let occu = p.occupation { appendSplit(occu, tag: "OCCU", level: 1, cont: false, into: &out, &split) }
            for (k, note) in p.notes.enumerated() {
                if note.asRecord {
                    let rid = "@N\(p.id.filter(\.isNumber))_\(k)@"
                    records[rid] = note.text
                    out.append("1 NOTE \(rid)")
                } else {
                    appendSplit(note.text, tag: "NOTE", level: 1, cont: true, into: &out, &split)
                }
            }
            for f in p.famc { out.append("1 FAMC \(f)") }
            for f in p.fams { out.append("1 FAMS \(f)") }
            noiseBlock()
        }
        for f in tree.families {
            topLevelNoise()
            out.append("0 \(f.id) FAM")
            if let h = f.husband { out.append("1 HUSB \(h)") }
            if let w = f.wife { out.append("1 WIFE \(w)") }
            for c in f.children { out.append("1 CHIL \(c)") }
            if let m = f.marriageDate { out.append("1 MARR"); out.append("2 DATE \(m)") }
            noiseBlock()
        }
        for (rid, text) in records.sorted(by: { $0.key < $1.key }) {
            // "0 @N1@ NOTE first line" + level-1 CONT/CONC.
            var lines: [String] = []
            appendSplit(text, tag: "NOTE", level: 0, cont: true, into: &lines, &split)
            if let first = lines.first { lines[0] = first.replacingOccurrences(of: "0 NOTE", with: "0 \(rid) NOTE") }
            out.append(contentsOf: lines)
        }
        out.append("0 TRLR")
        if indent { out = out.map { line in line.hasPrefix("0") ? line : "  " + line } }
        return out
    }

    /// `text` under `tag` at `level`: CONT (level+1) at each newline when
    /// `cont`, and CONC (level+1) cuts at random points — mid-word, right
    /// after a space, right before one. The chunk text is written after
    /// exactly one separating space, so a chunk's own leading space is data.
    static func appendSplit(_ text: String, tag: String, level: Int, cont: Bool,
                            into out: inout [String], _ g: inout SeededGenerator) {
        let logicalLines = cont ? text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) : [text]
        for (i, line) in logicalLines.enumerated() {
            var chars = Array(line)
            var first = true
            repeat {
                let take = chars.isEmpty ? 0 : min(chars.count, g.int(1...max(1, min(chars.count, 40))))
                let chunk = String(chars.prefix(take))
                chars.removeFirst(take)
                let lineTag = (i == 0 && first) ? tag : (first ? "CONT" : "CONC")
                let lineLevel = (i == 0 && first) ? level : level + 1
                out.append(chunk.isEmpty ? "\(lineLevel) \(lineTag)" : "\(lineLevel) \(lineTag) \(chunk)")
                first = false
            } while !chars.isEmpty
        }
    }

    static func render(_ lines: [String], ending: String) -> String {
        lines.joined(separator: ending) + ending
    }
}

// MARK: - Checks

enum GedcomChecks {

    /// Every walk the app runs on a person, on every person (bounded by the
    /// tree size the generator makes). Returns nothing: a crash or a hang
    /// is the failure.
    static func exerciseGraph(_ graph: GedcomFamilyGraph) {
        let people = graph.people.values.sorted { $0.id < $1.id }
        for p in people.prefix(8) {
            _ = graph.ancestorLine(of: p, line: .both, generations: 12)
            _ = graph.descendants(of: p, depth: 8)
            _ = graph.ancestorDepth(of: p.id)
            _ = graph.originTrail(of: p)
            _ = graph.familyUnits(of: p)
            _ = graph.primaryMother(of: p)
            _ = graph.primaryFather(of: p)
            for r in GedcomFamilyGraph.Relation.allCases { _ = graph.relatives(r, of: p) }
            for q in people.prefix(6) where q.id != p.id {
                _ = graph.commonAncestors(of: p.id, and: q.id, limit: 5)
                _ = graph.relationshipPath(from: p, to: q)
                _ = graph.directAncestorLine(from: p, to: q)
                _ = graph.descentPath(from: p.id, to: q.id)
                _ = graph.bloodRelation(of: q.id, to: p.id)
                _ = graph.relationThroughMarriage(of: q.id, to: p.id)
                _ = graph.directRelation(between: p.id, and: q.id)
            }
        }
    }

    /// The notes a person must read back with, in reader order: inline
    /// notes as met, then NOTE records by pointer.
    static func expectedNotes(_ p: GenPerson) -> [String] {
        let inline = p.notes.filter { !$0.asRecord }.map(\.text)
        let records = p.notes.filter(\.asRecord).map(\.text)
        return (inline + records).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// Graph equality on everything the parser models.
    static func sameGraph(_ a: GedcomFamilyGraph, _ b: GedcomFamilyGraph) -> String? {
        if a.people != b.people {
            let ids = Set(a.people.keys).union(b.people.keys).filter { a.people[$0] != b.people[$0] }.sorted()
            return "people differ at \(ids.prefix(3)): \(ids.first.map { "\(String(describing: a.people[$0])) vs \(String(describing: b.people[$0]))" } ?? "")"
        }
        if a.rootPersonIDs != b.rootPersonIDs { return "roots \(a.rootPersonIDs) vs \(b.rootPersonIDs)" }
        if a.familyCount != b.familyCount { return "familyCount \(a.familyCount) vs \(b.familyCount)" }
        for (id, fa) in a.families {
            guard let fb = b.families[id] else { return "family \(id) missing" }
            if fa.husband != fb.husband || fa.wife != fb.wife || fa.children != fb.children || fa.marriageDate != fb.marriageDate {
                return "family \(id) differs"
            }
        }
        return nil
    }
}

// MARK: - Suite

@Suite("GEDCOM parsing — generated inputs")
struct GedcomParserPropertyTests {

    /// Per-case ceiling for G1 in Debug. A generated file is ≤ 15 people;
    /// anything near this means a walk is looping.
    static let caseBudget: Duration = .seconds(2)

    @Test("G1: no crash or hang on generated, cyclic and truncated files", arguments: Property.batches)
    func noCrashOrHang(batch: Int) {
        // 8 × 150 = 1,200 files: each case parses a whole file with both
        // readers and runs every walk on up to 8 × 6 person pairs, so the
        // case count is set by the Debug time budget (~4 s), not by 4k.
        Property.check("gedcom-no-hang", batch: batch, cases: 150, generate: { g -> (GenTree, String, Int) in
            let tree = GedcomGenerator.tree(&g)
            let ending = g.pick(["\n", "\r\n", "\r"])
            let text = GedcomGenerator.render(GedcomGenerator.lines(tree, noise: true, indent: g.chance(0.2)), ending: ending)
            // Truncate a fifth of the files at an arbitrary character.
            let cut = g.chance(0.2) ? g.int(0...text.count) : text.count
            return (tree, text, cut)
        }, describe: { "\($0.0); \($0.1.count) chars cut at \($0.2)" }) { input in
            let (_, full, cut) = input
            let text = String(full.prefix(cut))
            let clock = ContinuousClock()
            let start = clock.now
            let graph = GedcomFamilyGraph(gedcomText: text)
            _ = GedcomLifeDetails(gedcomText: text)
            GedcomChecks.exerciseGraph(graph)
            let ctx = LifeAndTimes.Context(graph: graph, options: LifeAndTimes.Options(currentYear: 2026))
            for p in graph.people.values { _ = LifeAndTimes.facts(for: p, in: ctx) }
            let elapsed = clock.now - start
            if elapsed > Self.caseBudget { return "took \(elapsed)" }
            // Never invents a person: every id read is a generated one.
            if let stray = graph.people.keys.first(where: { !$0.hasPrefix("@I") }) { return "invented person \(stray)" }
            return nil
        }
    }

    @Test("G2: CONC/CONT reproduce note and occupation text exactly", arguments: Property.batches)
    func continuationReproducesText(batch: Int) {
        Property.check("gedcom-conc-cont", batch: batch, generate: { g -> (GenTree, String) in
            let tree = GedcomGenerator.tree(&g)
            return (tree, GedcomGenerator.render(GedcomGenerator.lines(tree, noise: g.chance(0.5)),
                                                 ending: g.pick(["\n", "\r\n"])))
        }, describe: { "\($0.0)\n\($0.1)" }) { input in
            let (tree, text) = input
            let details = GedcomLifeDetails(gedcomText: text)
            for p in tree.people where !(tree.duplicateRecord && p.id == tree.people.first?.id) {
                let got = details[p.id]?.notes ?? []
                let want = GedcomChecks.expectedNotes(p)
                if got != want { return "\(p.id) notes \(got.debugDescription) != \(want.debugDescription)" }
                let occupation = details[p.id]?.occupations.first?.value
                let wantOccupation = p.occupation.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
                if occupation != wantOccupation {
                    return "\(p.id) occupation \(occupation.debugDescription) != \(wantOccupation.debugDescription)"
                }
            }
            return nil
        }
    }

    @Test("G3: LF, CRLF and CR files parse identically", arguments: Property.batches)
    func lineEndingStability(batch: Int) {
        // 8 × 150 = 1,200 files, six parses each (three line endings × two
        // readers): ~4 s in Debug.
        Property.check("gedcom-line-endings", batch: batch, cases: 150, generate: { g -> [String] in
            GedcomGenerator.lines(GedcomGenerator.tree(&g), noise: g.chance(0.5), indent: g.chance(0.2))
        }, shrink: Shrink.lines, describe: { $0.joined(separator: "⏎") }) { lines in
            let lf = GedcomGenerator.render(lines, ending: "\n")
            let graphLF = GedcomFamilyGraph(gedcomText: lf)
            let detailsLF = GedcomLifeDetails(gedcomText: lf)
            for ending in ["\r\n", "\r"] {
                let text = GedcomGenerator.render(lines, ending: ending)
                if let diff = GedcomChecks.sameGraph(graphLF, GedcomFamilyGraph(gedcomText: text)) {
                    return "graph LF vs \(ending.debugDescription): \(diff)"
                }
                if graphLF.droppedLineCount != GedcomFamilyGraph(gedcomText: text).droppedLineCount {
                    return "droppedLineCount differs for \(ending.debugDescription)"
                }
                if detailsLF.byPersonID != GedcomLifeDetails(gedcomText: text).byPersonID {
                    return "life details LF vs \(ending.debugDescription) differ"
                }
            }
            return nil
        }
    }

    @Test("G4: unknown tags and unmodelled records never change what the graph reads", arguments: Property.batches)
    func noiseInvariance(batch: Int) {
        Property.check("gedcom-noise-invariance", batch: batch, cases: 250, generate: GedcomGenerator.tree,
                       describe: { "\($0)" }) { tree in
            let clean = GedcomFamilyGraph(gedcomText: GedcomGenerator.render(GedcomGenerator.lines(tree, noise: false), ending: "\n"))
            let noisyText = GedcomGenerator.render(GedcomGenerator.lines(tree, noise: true), ending: "\n")
            let noisy = GedcomFamilyGraph(gedcomText: noisyText)
            if let diff = GedcomChecks.sameGraph(clean, noisy) { return diff + "\n" + noisyText }
            if noisy.droppedLineCount < clean.droppedLineCount { return "noise LOWERED the dropped-line count" }
            return nil
        }
    }

    @Test("G5a: writer round trip keeps every person", arguments: Property.batches)
    func writerRoundTrip(batch: Int) {
        Property.check("gedcom-writer-roundtrip", batch: batch, cases: 300, generate: GedcomGenerator.tree,
                       describe: { "\($0)" }) { tree in
            let graph = GedcomFamilyGraph(gedcomText: GedcomGenerator.render(GedcomGenerator.lines(tree, noise: true), ending: "\r\n"))
            let again = GedcomFamilyGraph(gedcomText: graph.gedcomText(now: Date(timeIntervalSince1970: 0)))
            if graph.people != again.people {
                let id = graph.people.keys.sorted().first { graph.people[$0] != again.people[$0] } ?? "?"
                return "\(id): \(String(describing: graph.people[id])) → \(String(describing: again.people[id]))"
            }
            return nil
        }
    }

    @Test("G5b: a HEAD NOTE of any text reads back identically through the writer", arguments: Property.batches)
    func headNoteRoundTrip(batch: Int) {
        Property.check("gedcom-head-note", batch: batch, cases: 300, generate: { g -> String in
            // Long runs (> 200 characters, the writer's CONC chunk) included.
            var s = GedcomGenerator.noteText(&g, maxWords: g.chance(0.3) ? 300 : 40)
            if g.chance(0.1) { s += String(repeating: " ", count: g.int(1...3)) + "end" }
            // A line that ends in a space before its newline.
            if g.chance(0.1), let nl = s.firstIndex(of: "\n") { s.insert(" ", at: nl) }
            return s
        }, shrink: { Shrink.text($0).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } },
           describe: { $0.debugDescription }) { note in
            let graph = GedcomFamilyGraph(gedcomText: "0 HEAD\n0 @I1@ INDI\n1 NAME Ansel /Fenlane/\n0 TRLR\n")
            let back = GedcomFamilyGraph(gedcomText: graph.gedcomText(provenance: note, now: Date(timeIntervalSince1970: 0)))
            return back.headNote == note ? nil : "read back \(back.headNote.debugDescription)"
        }
    }

    /// The generator really makes the hard cases — otherwise a green G2 /
    /// G3 / G4 could be vacuous.
    @Test("generator coverage: splits after spaces, cycles, dangling and duplicate ids all occur")
    func generatorCoverage() {
        var afterSpace = 0, beforeSpace = 0, blankCont = 0, selfParent = 0, twoCycle = 0, dangling = 0, duplicate = 0
        for index in 0..<400 {
            var g = SeededGenerator(seed: Property.seed(property: "coverage", batch: 0, index: index))
            let tree = GedcomGenerator.tree(&g)
            for line in GedcomGenerator.lines(tree, noise: true) {
                if line.hasPrefix("2 CONC") || line.hasPrefix("1 CONC") {
                    if line.hasSuffix(" ") { afterSpace += 1 }
                    if line.dropFirst(7).hasPrefix(" ") { beforeSpace += 1 }
                }
                if line == "2 CONT" || line == "1 CONT" { blankCont += 1 }
            }
            let parentOf = Dictionary(grouping: tree.families.flatMap { f in
                f.children.flatMap { c in [f.husband, f.wife].compactMap { $0 }.map { (c, $0) } }
            }, by: \.0).mapValues { Set($0.map(\.1)) }
            if parentOf.contains(where: { $0.value.contains($0.key) }) { selfParent += 1 }
            if parentOf.contains(where: { child, parents in parents.contains { $0 != child && parentOf[$0]?.contains(child) == true } }) {
                twoCycle += 1
            }
            if tree.people.contains(where: { $0.famc.contains("@F999@") }) { dangling += 1 }
            if tree.duplicateRecord { duplicate += 1 }
        }
        #expect(afterSpace > 100, "CONC chunks ending in a space: \(afterSpace)")
        #expect(beforeSpace > 100, "CONC chunks starting with a space: \(beforeSpace)")
        #expect(blankCont > 10, "blank CONT lines: \(blankCont)")
        #expect(selfParent > 10, "trees with a self-parent: \(selfParent)")
        #expect(twoCycle > 10, "trees with a two-person cycle: \(twoCycle)")
        #expect(dangling > 10, "trees with a dangling FAMC: \(dangling)")
        #expect(duplicate > 10, "trees with a duplicated INDI record: \(duplicate)")
    }

    /// A NOTE of about `bytes` bytes, rendered with random CONC / CONT.
    static func noteFile(bytes: Int, seed: UInt64) -> (note: String, text: String, lines: Int) {
        var g = SeededGenerator(seed: seed)
        var note = ""
        while note.utf8.count < bytes { note += GedcomGenerator.noteText(&g, maxWords: 200) + " " }
        note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = ["0 HEAD", "0 @I1@ INDI", "1 NAME Ansel /Fenlane/"]
        GedcomGenerator.appendSplit(note, tag: "NOTE", level: 1, cont: true, into: &lines, &g)
        lines.append("0 TRLR")
        return (note, GedcomGenerator.render(lines, ending: "\r\n"), lines.count)
    }

    /// Best of three — the least-disturbed run on a loaded machine.
    static func bestOf3(_ body: () -> Void) -> Duration {
        let clock = ContinuousClock()
        return (0..<3).map { _ in clock.measure(body) }.min()!
    }

    @Test("G2 at scale: a 1 MB NOTE in ~80k CONC/CONT lines reads back exactly, in linear time")
    func hugeNote() {
        let big = Self.noteFile(bytes: 1_000_000, seed: 0x1D0C)
        let small = Self.noteFile(bytes: 62_500, seed: 0x1D0C)
        let details = GedcomLifeDetails(gedcomText: big.text)
        let graph = GedcomFamilyGraph(gedcomText: big.text)
        #expect(details["@I1@"]?.notes == [big.note])
        #expect(graph.people["@I1@"]?.name == "Ansel Fenlane")
        // 16× the bytes must cost well under 16² — a RATIO, so a loaded
        // machine (other suites parse in parallel) cannot fail it; an
        // absolute ceiling did (11.5 s under load vs 0.4 s alone, Debug).
        let detailsRatio = Self.bestOf3 { _ = GedcomLifeDetails(gedcomText: big.text) }
            / Self.bestOf3 { _ = GedcomLifeDetails(gedcomText: small.text) }
        let graphRatio = Self.bestOf3 { _ = GedcomFamilyGraph(gedcomText: big.text) }
            / Self.bestOf3 { _ = GedcomFamilyGraph(gedcomText: small.text) }
        #expect(detailsRatio < 48, "GedcomLifeDetails: 16× input cost \(detailsRatio)× (\(big.lines) lines)")
        #expect(graphRatio < 48, "GedcomFamilyGraph: 16× input cost \(graphRatio)× (\(big.lines) lines)")
    }
}
