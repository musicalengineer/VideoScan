// videoscan-tree-ingest — the ONE-TIME family-tree compile (Rick, 2026-08-28:
// "we are willing to pay a one-time price to ingest the file and connect
// everything between the trees so subsequent queries will be extremely fast").
//
//   videoscan-tree-ingest --out <compiled-root> [--report merge-report.json]
//                         [--dry-run] <pull1.ged> [<pull2.ged> …]
//
// parse each pull (timed) → merge by FamilySearch ID (first file wins field
// disagreements; every undecided item is reported) → compile (TreeIndex +
// flat codec) → VERIFY → promote into <compiled-root> via
// FamilyGraphCompiledStore (previous generation kept for rollback).
// The raw .ged files are never opened for writing. Exit 0 only when a
// generation was promoted (or --dry-run finished verification).

import Foundation
import VideoScanCore

struct Options {
    var out: URL?
    var report: URL?
    var dryRun = false
    var sources: [URL] = []
}

func usage(_ message: String? = nil) -> Never {
    if let message { FileHandle.standardError.write(Data("error: \(message)\n".utf8)) }
    FileHandle.standardError.write(Data("""
    usage: videoscan-tree-ingest --out <compiled-root> [--report <file.json>] [--dry-run] <pull.ged> […]

    """.utf8))
    exit(2)
}

func parseOptions() -> Options {
    var o = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let a = args.removeFirst()
        switch a {
        case "--out": guard !args.isEmpty else { usage("--out needs a path") }; o.out = URL(fileURLWithPath: args.removeFirst())
        case "--report": guard !args.isEmpty else { usage("--report needs a path") }; o.report = URL(fileURLWithPath: args.removeFirst())
        case "--dry-run": o.dryRun = true
        case "-h", "--help": usage()
        default:
            if a.hasPrefix("-") { usage("unknown option \(a)") }
            o.sources.append(URL(fileURLWithPath: a))
        }
    }
    guard !o.sources.isEmpty else { usage("at least one .ged is required") }
    guard o.out != nil || o.dryRun else { usage("--out is required unless --dry-run") }
    return o
}

func say(_ s: String) { print(s); fflush(stdout) }
func ms(_ start: Date) -> String { String(format: "%.0f ms", Date().timeIntervalSince(start) * 1000) }

let options = parseOptions()
let t0 = Date()

// ---- Parse
var graphs: [GedcomFamilyGraph] = []
for url in options.sources {
    let t = Date()
    guard var g = GedcomFamilyGraph(fileURL: url), !g.people.isEmpty else {
        FileHandle.standardError.write(Data("error: \(url.path) did not parse as a non-empty GEDCOM\n".utf8))
        exit(1)
    }
    // Real digest of the completed file: merge provenance + sameSource rule (codex #808).
    g.sourceFingerprint = try GedcomCompiledTree.fullSHA256(of: url)
    say("parsed \(url.lastPathComponent): \(g.people.count.formatted()) people, \(g.familyCount.formatted()) families, "
        + "root \(g.rootPerson?.name ?? "?") (\(g.rootPerson?.familySearchID ?? "no FSID")), "
        + "\(g.droppedLineCount.formatted()) lines not kept — \(ms(t))")
    graphs.append(g)
}

// ---- Merge (left fold: first file is the authority for field disagreements)
var merged = graphs[0]
var reportLines: [String] = []
var reportJSON: [String: Any] = ["sources": options.sources.map(\.lastPathComponent), "merges": [[String: Any]]()]
for (i, next) in graphs.dropFirst().enumerated() {
    let t = Date()
    let outcome = merged.merge(with: next)
    merged = outcome.graph
    let line = "merged \(options.sources[i + 1].lastPathComponent): shared \(outcome.sharedPeopleCount.formatted()), "
        + "added \(outcome.addedPeopleCount.formatted()), unmatched (no FSID) \(outcome.unmatched.count), "
        + "field conflicts \(outcome.fieldConflictCount), other conflicts "
        + "\(outcome.conflicts.count - outcome.fieldConflictCount) — \(ms(t))"
    say(line)
    reportLines.append(line)
    var m = [String: Any]()
    m["file"] = options.sources[i + 1].lastPathComponent
    m["shared"] = outcome.sharedPeopleCount
    m["added"] = outcome.addedPeopleCount
    m["unmatched"] = outcome.unmatched.map { ["id": $0.id, "name": $0.name, "birth": $0.birthDate ?? ""] }
    m["conflicts"] = outcome.conflicts.map { ["kind": $0.kind.rawValue, "ids": $0.ids, "resolution": $0.resolution] }
    m["droppedLines"] = outcome.droppedLineCount
    var merges = reportJSON["merges"] as! [[String: Any]]
    merges.append(m); reportJSON["merges"] = merges
}
say("tree: \(merged.people.count.formatted()) people, \(merged.familyCount.formatted()) families, "
    + "roots \(merged.roots.map { "\($0.name) (\($0.familySearchID ?? "-"))" }.joined(separator: " | "))")

// ---- Index build (the cost we pay once)
let tIndex = Date()
_ = merged.index
say("index built — \(ms(tIndex))")

// ---- Sanity queries across the roots (what Hallie will be asked first)
if merged.roots.count >= 2 {
    let a = merged.roots[0], b = merged.roots[1]
    let t = Date()
    let common = merged.commonAncestors(of: a.id, and: b.id, limit: 5)
    if let c = common.first {
        say("common ancestors of \(a.name) and \(b.name): \(common.count)+; nearest \(c.person.name) "
            + "(\(c.person.birthDate ?? "?")) at \(c.depthA)/\(c.depthB) → \(c.kinshipTerm) — \(ms(t))")
    } else {
        say("no common ancestor between \(a.name) and \(b.name) in the merged tree — \(ms(t))")
    }
    reportJSON["rootsCommonAncestors"] = common.map {
        ["name": $0.person.name, "fsid": $0.person.familySearchID ?? "", "depthA": $0.depthA, "depthB": $0.depthB, "term": $0.kinshipTerm]
    }
}

// ---- Compile → verify → promote
if options.dryRun {
    let t = Date()
    let data = GedcomCompiledTree.encode(merged)
    let decoded = try GedcomCompiledTree.decode(data)
    let problems = GedcomCompiledTree.verify(decoded: decoded, against: merged)
    say("dry-run: artifact \(data.count / 1024 / 1024) MB, verify \(problems.isEmpty ? "PASS" : "FAIL: " + problems.joined(separator: "; ")) — \(ms(t))")
    if !problems.isEmpty { exit(1) }
} else {
    var store = FamilyGraphCompiledStore(root: options.out!)
    store.log = { say($0) }
    let t = Date()
    guard let promoted = store.ingest(graph: merged, sources: options.sources,
                                      mergeReport: reportLines.joined(separator: "\n"),
                                      progress: { say("  " + $0) }) else {
        FileHandle.standardError.write(Data("error: generation not promoted (see log above)\n".utf8))
        exit(1)
    }
    say("promoted: \(promoted.people.count.formatted()) people from \(promoted.sourceFileNames.joined(separator: " + ")) — \(ms(t))")
    // Prove the promoted artifact answers the cross-root question the same way.
    if promoted.roots.count >= 2 {
        let t2 = Date()
        let c = promoted.commonAncestors(of: promoted.roots[0].id, and: promoted.roots[1].id, limit: 1).first
        say("artifact query: nearest common ancestor \(c?.person.name ?? "none") → \(c?.kinshipTerm ?? "-") — \(ms(t2))")
    }
}

if let report = options.report {
    reportJSON["peopleCount"] = merged.people.count
    reportJSON["familyCount"] = merged.familyCount
    reportJSON["roots"] = merged.roots.map { ["id": $0.id, "name": $0.name, "fsid": $0.familySearchID ?? ""] }
    let data = try JSONSerialization.data(withJSONObject: reportJSON, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: report, options: .atomic)
    say("report: \(report.path)")
}
say("total \(ms(t0))")
