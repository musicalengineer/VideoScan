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

    /// Newest valid, non-empty GEDCOM wins. A damaged newer export is
    /// retained in `rejectedURLs` so the UI can say what happened instead
    /// of pretending there was no file or displaying an empty live tree.
    func loadNewestOutcome() -> Outcome {
        // A promoted multi-source generation (videoscan-tree-ingest) wins
        // outright while its sources are unchanged: that is the tree Rick
        // paid to compile. Single-file generations still go through the
        // newest-file path below so a newer pull replaces them.
        if let store = compiledStore, let current = store.loadCurrent(), current.manifest.sources.count > 1 {
            return Outcome(graph: current.graph,
                           selectedURL: current.manifest.sources.first.map { URL(fileURLWithPath: $0.path) },
                           rejectedURLs: [], candidateCount: current.manifest.sources.count, compiled: true)
        }
        let keys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]
        guard let files = try? fileManager.contentsOfDirectory(
            at: originalsDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]) else {
            return Outcome(graph: nil, selectedURL: nil,
                           rejectedURLs: [], candidateCount: 0)
        }

        let gedcomFiles = files.filter {
            guard $0.pathExtension.lowercased() == "ged",
                  let values = try? $0.resourceValues(forKeys: keys)
            else { return false }
            return values.isRegularFile == true
                && values.isSymbolicLink != true
        }
        let newestFirst = gedcomFiles.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: keys))?
                .contentModificationDate ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: keys))?
                .contentModificationDate ?? .distantPast
            if lhsDate == rhsDate {
                return lhs.lastPathComponent > rhs.lastPathComponent
            }
            return lhsDate > rhsDate
        }
        var rejected: [URL] = []
        for url in newestFirst {
            if let store = compiledStore, let compiled = store.load(sources: [url]) {
                return Outcome(graph: compiled, selectedURL: url,
                               rejectedURLs: rejected,
                               candidateCount: newestFirst.count, compiled: true)
            }
            progress("Reading \(url.lastPathComponent)…")
            guard let graph = GedcomFamilyGraph(fileURL: url),
                  !graph.people.isEmpty else {
                rejected.append(url)
                continue
            }
            if let store = compiledStore,
               let promoted = store.ingest(graph: graph, sources: [url], progress: progress) {
                return Outcome(graph: promoted, selectedURL: url,
                               rejectedURLs: rejected,
                               candidateCount: newestFirst.count, compiled: true)
            }
            // No store, or the compile did not verify: the parsed graph is
            // still the truth. Build its index here, off the caller's
            // thread, so install does no O(people) name work.
            _ = graph.index
            return Outcome(graph: graph, selectedURL: url,
                           rejectedURLs: rejected,
                           candidateCount: newestFirst.count)
        }
        return Outcome(graph: nil, selectedURL: nil,
                       rejectedURLs: rejected,
                       candidateCount: newestFirst.count)
    }
}
