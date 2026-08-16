import Foundation
import ImageIO
import CoreGraphics

/// A verified presentation attachment for a deterministic biography answer.
/// It is not factual evidence and is never passed to the query translator.
struct ArchivistBiographyPhoto: Sendable, Equatable {
    let profileStableID: String
    let profileCanonicalName: String
    let fileURL: URL
    let cropOffsetX: Double
    let cropOffsetY: Double
    let cropScale: Double

    /// Resolves only a unique POI whose canonical name or alias exactly
    /// matches the biography's canonical GEDCOM name. The cover must be a
    /// regular, non-symlink image directly inside that POI's reference folder.
    static func resolve(
        personName: String,
        profiles: [POIProfile],
        fileManager: FileManager = .default
    ) -> ArchivistBiographyPhoto? {
        let key = PersonResolver.normalize(personName)
        guard !key.isEmpty else { return nil }
        let matches = profiles.filter { profile in
            ([profile.name] + profile.aliases).contains {
                PersonResolver.normalize($0) == key
            }
        }
        guard matches.count == 1, let profile = matches.first,
              let filename = profile.coverImageFilename,
              filename == URL(fileURLWithPath: filename).lastPathComponent,
              !filename.isEmpty,
              allowedExtensions.contains(
                URL(fileURLWithPath: filename).pathExtension.lowercased())
        else { return nil }

        let folder = URL(fileURLWithPath: profile.referencePath,
                         isDirectory: true).standardizedFileURL
        let candidate = folder.appendingPathComponent(filename,
                                                       isDirectory: false)
            .standardizedFileURL
        guard candidate.deletingLastPathComponent() == folder,
              let folderValues = try? folder.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              folderValues.isDirectory == true,
              folderValues.isSymbolicLink != true,
              let values = try? candidate.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let imageSource = CGImageSourceCreateWithURL(
                candidate as CFURL, nil),
              CGImageSourceGetCount(imageSource) > 0
        else { return nil }

        return ArchivistBiographyPhoto(
            profileStableID: profile.id,
            profileCanonicalName: profile.name,
            fileURL: candidate,
            cropOffsetX: profile.coverCropOffsetX.clamped(to: -1...1),
            cropOffsetY: profile.coverCropOffsetY.clamped(to: -1...1),
            cropScale: profile.coverCropScale.clamped(to: 1...8))
    }

    /// Re-checks the attachment at the moment it is displayed or opened.
    /// The original profile filename is already flattened to one component;
    /// this closes the later regular-file→symlink/non-image replacement gap.
    func revalidatedURL() -> URL? {
        // Recreate the URL so Foundation cannot reuse resource values cached
        // when this attachment was first resolved as a regular file.
        let candidate = URL(fileURLWithPath: fileURL.path, isDirectory: false)
        let folder = candidate.deletingLastPathComponent()
        guard let folderValues = try? folder.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              folderValues.isDirectory == true,
              folderValues.isSymbolicLink != true,
              let values = try? candidate.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let source = CGImageSourceCreateWithURL(candidate as CFURL, nil),
              CGImageSourceGetCount(source) > 0
        else { return nil }
        return candidate
    }

    /// Decodes a bounded thumbnail rather than the full phone/scan image.
    /// 440px supplies a 2× backing image for the 220pt biography card.
    func makeThumbnail(maxPixelSize: Int = 440) -> CGImage? {
        guard !Task.isCancelled,
              maxPixelSize > 0, let verifiedURL = revalidatedURL(),
              let source = CGImageSourceCreateWithURL(verifiedURL as CFURL, nil)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard !Task.isCancelled else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary)
    }

    private static let allowedExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "bmp", "gif"
    ]
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
