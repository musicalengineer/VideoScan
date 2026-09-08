import Foundation

/// Copies reference photos — one file or a folder of them — into a
/// person's local photo folder, and says what happened.
///
/// Extracted from PersonEditSheet for GH #151 ("can't add new photos to a
/// person"): the sheet's copy loop was a private view method with `try?`
/// on every copy and "skip duplicates by name", so a photo that failed to
/// copy or shared a file name with an earlier export (IMG_0001.jpg twice)
/// vanished without a trace. Pure over FileManager so it can be tested.
enum ReferencePhotoImporter {
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "bmp"]

    struct Outcome: Equatable {
        /// Destination file names written (renamed ones carry their new name).
        var copied: [String] = []
        /// Same name AND same bytes already present — nothing to do.
        var skippedIdentical: [String] = []
        /// Same name, different bytes — copied under a suffixed name.
        var renamed: [String: String] = [:]
        /// Files in the source that are not images by extension.
        var ignoredNonImages: Int = 0
        /// Source file name → error text.
        var failures: [String: String] = [:]

        var addedCount: Int { copied.count }
        var summary: String {
            var parts = ["\(copied.count) added"]
            if !skippedIdentical.isEmpty { parts.append("\(skippedIdentical.count) already there") }
            if !renamed.isEmpty { parts.append("\(renamed.count) renamed (same name, different photo)") }
            if ignoredNonImages > 0 { parts.append("\(ignoredNonImages) non-image skipped") }
            if !failures.isEmpty { parts.append("\(failures.count) FAILED") }
            return parts.joined(separator: ", ")
        }
    }

    static func isImage(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    /// `source` may be a single image or a directory (non-recursive).
    /// `destination` is created if needed.
    static func copy(from source: URL, into destination: URL,
                     fileManager fm: FileManager = .default) -> Outcome {
        var outcome = Outcome()
        do {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            outcome.failures[destination.lastPathComponent] = "could not create folder: \(error.localizedDescription)"
            return outcome
        }

        var isDir: ObjCBool = false
        let sources: [URL]
        if fm.fileExists(atPath: source.path, isDirectory: &isDir), isDir.boolValue {
            let listed = (try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)) ?? []
            sources = listed.filter { url in
                if isImage(url) { return true }
                outcome.ignoredNonImages += 1
                return false
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } else if isImage(source) {
            sources = [source]
        } else {
            outcome.ignoredNonImages = 1
            return outcome
        }

        for file in sources {
            let name = file.lastPathComponent
            var target = destination.appendingPathComponent(name)
            if fm.fileExists(atPath: target.path) {
                if fm.contentsEqual(atPath: file.path, andPath: target.path) {
                    outcome.skippedIdentical.append(name)
                    continue
                }
                target = freeName(for: file, in: destination, fileManager: fm)
                outcome.renamed[name] = target.lastPathComponent
            }
            do {
                try fm.copyItem(at: file, to: target)
                outcome.copied.append(target.lastPathComponent)
            } catch {
                outcome.failures[name] = error.localizedDescription
                outcome.renamed[name] = nil
            }
        }
        return outcome
    }

    /// `IMG_0001.jpg` → `IMG_0001-2.jpg`, `-3`, … first free slot.
    static func freeName(for file: URL, in directory: URL,
                         fileManager fm: FileManager = .default) -> URL {
        let stem = file.deletingPathExtension().lastPathComponent
        let ext = file.pathExtension
        var n = 2
        while true {
            let candidate = directory.appendingPathComponent("\(stem)-\(n)")
                .appendingPathExtension(ext)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }
}
