// FamilyTreePullDates.swift
// The two small lines under the "Family Tree ✦" title (Rick, 2026-10-30):
//
//     Breen GEDCOM 26 Aug 2026
//     Hudson GEDCOM 28 Aug 2026
//
// One line per pull label (the first person's surname in that pull), the
// pull's own HEAD export date. The ingest date and file names are in the
// tooltip only. Each tree load also writes one `[family-tree] gedcom pull`
// line per source to the app log (label, header date, file, size, mtime,
// short sha, ingest, generation) — or NOT ON DISK.
//
// The facts come from VideoScanCore (GedcomPullFacts.swift): the file is
// found by name under the GEDCOM folder and confirmed by full SHA-256
// against the hash the tree recorded. Nothing here is hard-coded to a
// family name.
//
// THE VIEW COMPUTES NOTHING. `refresh` is called once per tree load by
// FamilyTreeLiveModel (never from a body); the work runs detached at
// utility priority after the tree is installed, so it never delays the
// tree. The hash cache (by path, size, mtime) makes a re-load a stat per
// file; the first load hashes each pull once (~0.2 s per 100 MB).
//
// (For Rick: an ObservableObject with @Published ≈ a model class that emits
// a changed-signal; the small view below re-draws when `lines` changes.)

import Combine
import SwiftUI
import VideoScanCore

@MainActor
final class FamilyTreePullDates: ObservableObject {
    struct Shown: Equatable, Identifiable, Sendable {
        let id: String
        let text: String
        let help: String
    }

    @Published private(set) var lines: [Shown] = []
    /// Where the per-source lines go (tests capture them).
    var log: @Sendable (String) -> Void = { appLog.write($0) }
    private let cache = GedcomPullHashCache()
    private var generation = 0

    /// Describe the pulls behind `graph`. Called once per tree load. A
    /// newer call supersedes an older one still running.
    func refresh(graph: GedcomFamilyGraph?, store: FamilyGraphCompiledStore?, gedcomDirectory: URL) async {
        generation &+= 1
        let token = generation
        guard let graph else {
            lines = []
            return
        }
        let cache = self.cache
        let log = self.log
        let shown = await Task.detached(priority: .utility) {
            let result = Self.describe(graph: graph, store: store, gedcomDirectory: gedcomDirectory, cache: cache)
            for line in result.log { log(line) }
            return result.lines
        }.value
        guard token == generation else { return }
        lines = shown
    }

    /// Pure apart from file reads: which pulls, found and hash-confirmed,
    /// grouped into pane lines, plus the log lines.
    nonisolated static func describe(graph: GedcomFamilyGraph, store: FamilyGraphCompiledStore?,
                                     gedcomDirectory: URL, cache: GedcomPullHashCache)
        -> (lines: [Shown], log: [String]) {
        let manifest = store?.manifest(describing: graph)
        // The GEDCOM folder (pulls/ included, the walk is recursive) plus the
        // folder of each physical source the generation recorded.
        var roots = [gedcomDirectory]
        for source in manifest?.sources ?? [] {
            roots.append(URL(fileURLWithPath: source.path).deletingLastPathComponent())
        }
        var seen = Set<String>()
        roots = roots.filter { seen.insert($0.standardizedFileURL.path).inserted }

        let sources = GedcomPullSource.describing(graph)
        guard !sources.isEmpty else {
            return ([], ["[family-tree] gedcom pull: the loaded tree names no hashed source file; "
                         + "no pull dates shown (generation=\(manifest?.generation ?? "unknown"))"])
        }
        let facts = GedcomPullDescriber(searchRoots: roots, cache: cache).describe(sources)
        let log = facts.map { $0.logLine(ingest: manifest?.createdAt, generation: manifest?.generation) }
        let lines = GedcomPullLine.lines(from: facts).map {
            Shown(id: $0.label, text: $0.text, help: $0.helpText(ingest: manifest?.createdAt))
        }
        return (lines, log)
    }
}

/// The lines themselves: caption font, secondary colour, one per label.
struct FamilyTreePullDatesView: View {
    @ObservedObject var pullDates: FamilyTreePullDates

    var body: some View {
        if !pullDates.lines.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(pullDates.lines) { line in
                    Text(line.text)
                        .help(line.help)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("ft.pullDates")
        }
    }
}
