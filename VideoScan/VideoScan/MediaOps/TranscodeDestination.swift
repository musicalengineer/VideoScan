import Foundation

/// A pending sheet presentation. A fresh ID guarantees that choosing a
/// different menu entry while a prior sheet is dismissing creates a new
/// presentation cycle.
struct TranscodeRequest: Identifiable {
    let id = UUID()
    let record: VideoRecord
    let initialPreset: TranscodePreset
}

/// Pure naming plus persistence for the transcode configuration sheet.
@MainActor
enum TranscodeDestination {
    private static let lastDirectoryKey = "transcode.lastDestinationDirectory"

    static func suggestedFilename(for record: VideoRecord, preset: TranscodePreset) -> String {
        let sourceURL = URL(fileURLWithPath: record.fullPath)
        let stem = sourceURL.deletingPathExtension().lastPathComponent
        return "\(stem).vs.\(preset.purposeTag).\(preset.fileExtension)"
    }

    static func initialDirectory() -> URL? {
        if let savedPath = UserDefaults.standard.string(forKey: lastDirectoryKey) {
            let savedURL = URL(fileURLWithPath: savedPath, isDirectory: true)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: savedURL.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return savedURL
            }
        }

        // First use defaults to internal storage, not the source volume.
        return FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
    }

    static func remember(directory: URL) {
        UserDefaults.standard.set(directory.path, forKey: lastDirectoryKey)
    }

    static func outputURL(
        in directory: URL,
        record: VideoRecord,
        preset: TranscodePreset
    ) -> URL {
        directory.appendingPathComponent(suggestedFilename(for: record, preset: preset))
    }

    nonisolated static func isSameVolume(source: URL, destinationDirectory: URL) -> Bool {
        let fileManager = FileManager.default
        guard
            let sourceAttributes = try? fileManager.attributesOfFileSystem(
                forPath: source.path
            ),
            let destinationAttributes = try? fileManager.attributesOfFileSystem(
                forPath: destinationDirectory.path
            ),
            let sourceNumber = sourceAttributes[.systemNumber] as? NSNumber,
            let destinationNumber = destinationAttributes[.systemNumber] as? NSNumber
        else {
            return false
        }
        return sourceNumber == destinationNumber
    }

    nonisolated static func enforcingFileExtension(
        _ url: URL,
        preset: TranscodePreset
    ) -> URL {
        if url.pathExtension.caseInsensitiveCompare(preset.fileExtension) == .orderedSame {
            return url.standardizedFileURL
        }
        return url.deletingPathExtension()
            .appendingPathExtension(preset.fileExtension)
            .standardizedFileURL
    }
}
