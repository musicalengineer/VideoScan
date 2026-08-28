import Foundation

/// Filesystem seam for Hallie's GEDCOM source. Production supplies the
/// Application Support originals directory; tests supply an isolated root.
/// No path outside that injected directory is consulted.
struct FamilyGraphFileLoader {
    struct Outcome {
        let graph: GedcomFamilyGraph?
        let selectedURL: URL?
        let rejectedURLs: [URL]
        let candidateCount: Int
        /// True when `graph` came from a promoted compiled artifact
        /// (no GEDCOM parse happened on this load).
        var compiled = false
    }

    let originalsDirectory: URL
    var fileManager: FileManager = .default
    /// Compiled-artifact store (2026-08-28). Nil = parse every time (tests,
    /// and callers that must not touch Application Support). With a
    /// store: promoted artifact for the newest .ged → no parse; otherwise
    /// parse, compile, verify, promote, and return the promoted copy.
    var compiledStore: FamilyGraphCompiledStore? = nil
    /// Phase captions for the UI while a compile runs (>1 s on a big pull).
    var progress: (String) -> Void = { _ in }

    func loadNewest() -> GedcomFamilyGraph? {
        loadNewestOutcome().graph
    }

    /// Precedence (codex #822, 2026-08-28):
    ///   1. A `.ged` in the originals folder that is NOT one of the current
    ///      generation's physical sources and is NEWER than that
    ///      generation (`manifest.createdAt`) supersedes it — the app's
    ///      "Add to current tree" artifact, or a fresh pull. It is parsed,
    ///      ingested as ONE physical source (its logical provenance rides
    ///      along) and promoted.
    ///   2. Otherwise the current generation wins while every physical
    ///      source it records is unchanged on disk — CLI multi-pull or
    ///      single-file alike; no parse.
    ///   3. No usable generation: newest valid, non-empty `.ged` wins
    ///      (compiled on the way through when a store is present).
    /// A damaged newer export is retained in `rejectedURLs` so the UI can
    /// say what happened instead of pretending there was no file or
    /// displaying an empty live tree.
    func loadNewestOutcome() -> Outcome {
        let keys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]
        let files = (try? fileManager.contentsOfDirectory(
            at: originalsDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles])) ?? []

        let gedcomFiles = files.filter {
            guard $0.pathExtension.lowercased() == "ged",
                  let values = try? $0.resourceValues(forKeys: keys)
            else { return false }
            return values.isRegularFile == true
                && values.isSymbolicLink != true
        }
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: keys))?.contentModificationDate ?? .distantPast
        }
        let newestFirst = gedcomFiles.sorted { lhs, rhs in
            let lhsDate = modified(lhs), rhsDate = modified(rhs)
            if lhsDate == rhsDate {
                return lhs.lastPathComponent > rhs.lastPathComponent
            }
            return lhsDate > rhsDate
        }
        var rejected: [URL] = []

        if let store = compiledStore, let current = store.loadCurrent() {
            // Rule 1: anything installed AFTER this generation was compiled,
            // that it was not compiled from, supersedes it. Compare by the
            // standardized path: the manifest recorded the URL it was
            // given; the directory listing is what is there now.
            let sourcePaths = Set(current.manifest.sources.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path })
            let superseders = newestFirst.filter {
                !sourcePaths.contains($0.standardizedFileURL.path) && modified($0) > current.manifest.createdAt
            }
            for url in superseders {
                if let outcome = parseAndPromote(url, store: store, rejected: rejected, candidateCount: newestFirst.count) {
                    return outcome
                }
                rejected.append(url)
            }
            // Rule 2: the generation, with any damaged newer files reported.
            if !superseders.isEmpty {
                store.log("[family-tree] \(superseders.count) newer .ged file\(superseders.count == 1 ? "" : "s") did not parse; keeping compiled generation \(current.manifest.generation)")
            }
            return Outcome(graph: current.graph,
                           selectedURL: current.manifest.sources.first.map { URL(fileURLWithPath: $0.path) },
                           rejectedURLs: rejected,
                           candidateCount: max(newestFirst.count, current.manifest.sources.count),
                           compiled: true)
        }

        // Rule 3: newest valid file wins.
        for url in newestFirst {
            if let store = compiledStore, let compiled = store.load(sources: [url]) {
                return Outcome(graph: compiled, selectedURL: url,
                               rejectedURLs: rejected,
                               candidateCount: newestFirst.count, compiled: true)
            }
            if let outcome = parseAndPromote(url, store: compiledStore, rejected: rejected, candidateCount: newestFirst.count) {
                return outcome
            }
            rejected.append(url)
        }
        return Outcome(graph: nil, selectedURL: nil,
                       rejectedURLs: rejected,
                       candidateCount: newestFirst.count)
    }

    /// Parse `url`; nil when it is not a non-empty GEDCOM (the caller
    /// records it as rejected). With a store, ingest it as ONE physical
    /// source — for a merge artifact the graph's logical provenance is
    /// preserved by the store — and return the promoted copy; when the
    /// compile did not verify (or there is no store), the parsed graph is
    /// still the truth: build its index here, off the caller's thread, so
    /// install does no O(people) name work.
    private func parseAndPromote(_ url: URL, store: FamilyGraphCompiledStore?, rejected: [URL],
                                 candidateCount: Int) -> Outcome? {
        progress("Reading \(url.lastPathComponent)…")
        guard let graph = GedcomFamilyGraph(fileURL: url), !graph.people.isEmpty else { return nil }
        if let store, let promoted = store.ingest(graph: graph, sources: [url], progress: progress) {
            return Outcome(graph: promoted, selectedURL: url,
                           rejectedURLs: rejected, candidateCount: candidateCount, compiled: true)
        }
        _ = graph.index
        return Outcome(graph: graph, selectedURL: url,
                       rejectedURLs: rejected, candidateCount: candidateCount)
    }
}
