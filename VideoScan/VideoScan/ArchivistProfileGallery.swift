// ArchivistProfileGallery.swift
// Every verified image in a People-tab person's reference folder, cover
// first (2026-09-10, "show all photos of X" for someone who is in the
// People tab but not in the family tree). The same safety rules as the
// biography cover (ArchivistBiographyPhoto): a unique profile by canonical
// name or alias, a regular non-symlink folder, regular non-symlink files
// directly inside it, and ImageIO must recognise each one as an image.
// Presentation only — never evidence, never shown to a model.

import Foundation
import ImageIO

struct ArchivistProfileGallery: Sendable, Equatable {
    let profileStableID: String
    let profileCanonicalName: String
    /// The reference folder, for "Show folder in Finder".
    let folderURL: URL
    /// Cover first (when the profile names one and it verifies), then
    /// every other verified image in filename order.
    let photoURLs: [URL]

    /// Files listed per folder. A People-tab reference folder holds a few
    /// dozen reference stills; a folder someone pointed at a whole photo
    /// library is cut here so a gallery answer stays bounded. Only image
    /// HEADERS are read (CGImageSourceGetCount) — no pixels are decoded.
    static let maxFiles = 200

    static let allowedExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "bmp", "gif",
    ]

    static func resolve(
        personName: String,
        profiles: [POIProfile],
        fileManager: FileManager = .default
    ) -> ArchivistProfileGallery? {
        let key = PersonResolver.normalize(personName)
        guard !key.isEmpty else { return nil }
        let matches = profiles.filter { profile in
            ([profile.name] + profile.aliases).contains {
                PersonResolver.normalize($0) == key
            }
        }
        guard matches.count == 1, let profile = matches.first else { return nil }

        let folder = URL(fileURLWithPath: profile.referencePath, isDirectory: true).standardizedFileURL
        guard let folderValues = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              folderValues.isDirectory == true, folderValues.isSymbolicLink != true,
              let children = try? fileManager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles])
        else { return nil }

        func verified(_ url: URL) -> URL? {
            let candidate = URL(fileURLWithPath: url.path, isDirectory: false).standardizedFileURL
            guard candidate.deletingLastPathComponent() == folder,
                  allowedExtensions.contains(candidate.pathExtension.lowercased()),
                  let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let source = CGImageSourceCreateWithURL(candidate as CFURL, nil),
                  CGImageSourceGetCount(source) > 0
            else { return nil }
            return candidate
        }

        let cover = ArchivistBiographyPhoto.resolve(personName: personName, profiles: profiles)?.fileURL
        let ordered = children
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .prefix(maxFiles)
        var photos: [URL] = []
        if let cover { photos.append(cover) }
        for child in ordered {
            guard let url = verified(child), url != cover else { continue }
            photos.append(url)
        }
        guard !photos.isEmpty else { return nil }
        return ArchivistProfileGallery(
            profileStableID: profile.id,
            profileCanonicalName: profile.name,
            folderURL: folder,
            photoURLs: photos)
    }
}
