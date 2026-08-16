import Foundation

/// Filesystem seam for Hallie's GEDCOM source. Production supplies the
/// Application Support originals directory; tests supply an isolated root.
/// No path outside that injected directory is consulted.
struct FamilyGraphFileLoader {
    let originalsDirectory: URL
    var fileManager: FileManager = .default

    func loadNewest() -> GedcomFamilyGraph? {
        let keys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]
        guard let files = try? fileManager.contentsOfDirectory(
            at: originalsDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]) else { return nil }

        let gedcomFiles = files.filter {
            guard $0.pathExtension.lowercased() == "ged",
                  let values = try? $0.resourceValues(forKeys: keys)
            else { return false }
            return values.isRegularFile == true
                && values.isSymbolicLink != true
        }
        let newest = gedcomFiles.max { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: keys))?
                .contentModificationDate ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: keys))?
                .contentModificationDate ?? .distantPast
            if lhsDate == rhsDate {
                return lhs.lastPathComponent < rhs.lastPathComponent
            }
            return lhsDate < rhsDate
        }
        return newest.flatMap { GedcomFamilyGraph(fileURL: $0) }
    }
}
