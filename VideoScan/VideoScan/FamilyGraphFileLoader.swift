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
    }

    let originalsDirectory: URL
    var fileManager: FileManager = .default

    func loadNewest() -> GedcomFamilyGraph? {
        loadNewestOutcome().graph
    }

    /// Newest valid, non-empty GEDCOM wins. A damaged newer export is
    /// retained in `rejectedURLs` so the UI can say what happened instead
    /// of pretending there was no file or displaying an empty live tree.
    func loadNewestOutcome() -> Outcome {
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
            guard let graph = GedcomFamilyGraph(fileURL: url),
                  !graph.people.isEmpty else {
                rejected.append(url)
                continue
            }
            return Outcome(graph: graph, selectedURL: url,
                           rejectedURLs: rejected,
                           candidateCount: newestFirst.count)
        }
        return Outcome(graph: nil, selectedURL: nil,
                       rejectedURLs: rejected,
                       candidateCount: newestFirst.count)
    }
}
