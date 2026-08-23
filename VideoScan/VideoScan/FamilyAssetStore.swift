import Foundation
import CoreGraphics
import ImageIO
import VideoScanCore

/// A person key used to locate presentation photos without making them
/// genealogical evidence. GEDCOM remains the source of family relationships.
struct FamilyAssetPerson: Sendable, Equatable {
    let gedcomID: String?
    let name: String

    init(gedcomID: String? = nil, name: String) {
        self.gedcomID = gedcomID
        self.name = name
    }

    init(_ person: GedcomFamilyGraph.Person) {
        self.init(gedcomID: person.id, name: person.name)
    }
}

struct FamilyCrest: Sendable, Equatable, Identifiable {
    var id: String { fileURL.path }
    let surname: String
    let fileURL: URL
}

/// Local-first storage for family-tree presentation assets.
///
/// `root` is normally `<Master Archive>/Family Tree`. When no Master Archive
/// is designated it is Application Support's `family-tree/assets` directory.
/// `cacheRoot` is always Application Support's `family-tree/thumbs` and may
/// contain only derived, replaceable thumbnails.
struct FamilyAssetStore {
    struct Roots: Sendable, Equatable {
        let assets: URL
        let thumbnailCache: URL
    }

    enum StoreError: LocalizedError, Equatable {
        case invalidPerson
        case invalidSurname
        case unsafeDirectory(URL)
        case sourceIsNotARegularImage(URL)
        case crestAlreadyExists(URL)
        case sourceUnavailable
        case readOnly

        var errorDescription: String? {
            switch self {
            case .invalidPerson:
                return "This person needs a name or GEDCOM identifier before a photo folder can be created."
            case .invalidSurname:
                return "Enter a surname for this crest."
            case .unsafeDirectory:
                return "The family-assets folder is not a safe regular directory."
            case .sourceIsNotARegularImage:
                return "Choose a regular image file, not an alias, folder, or unsupported file."
            case .crestAlreadyExists:
                return "A crest for that surname is already present."
            case .sourceUnavailable:
                return "The designated Master Archive is not safely available. Connect the correct archive volume and try again."
            case .readOnly:
                return "Family assets are read-only in this session."
            }
        }
    }

    enum Access: Sendable, Equatable {
        case readWrite
        case readOnly
        /// A Master is designated but offline or mounted with the wrong UUID.
        /// Never fall back to another originals directory in this state.
        case unavailable
    }

    let root: URL
    let cacheRoot: URL
    let access: Access
    private let fileManager: FileManager

    init(
        root: URL,
        cacheRoot: URL,
        access: Access = .readWrite,
        fileManager: FileManager = .default
    ) {
        // Canonicalize the deepest existing prefix (`/var` → `/private/var`)
        // and then restore any not-yet-created tail components. FileManager
        // enumeration otherwise returns URLs that compare unequal to ours.
        self.root = Self.canonicalized(root, fileManager: fileManager)
        self.cacheRoot = Self.canonicalized(cacheRoot, fileManager: fileManager)
        self.access = access
        self.fileManager = fileManager
    }

    static func productionRoots(
        masterArchiveRoot: URL?,
        applicationSupportRoot: URL
    ) -> Roots {
        let familySupport = applicationSupportRoot
            .appendingPathComponent("VideoScan", isDirectory: true)
            .appendingPathComponent("family-tree", isDirectory: true)
        let assets = masterArchiveRoot.map {
            $0.standardizedFileURL.appendingPathComponent("Family Tree", isDirectory: true)
        } ?? familySupport.appendingPathComponent("assets", isDirectory: true)
        return Roots(
            assets: assets,
            thumbnailCache: familySupport.appendingPathComponent("thumbs", isDirectory: true))
    }

    var peopleDirectory: URL {
        root.appendingPathComponent("People", isDirectory: true)
    }

    var crestsDirectory: URL {
        root.appendingPathComponent("Crests", isDirectory: true)
    }

    var gedcomDirectory: URL {
        root.appendingPathComponent("GEDCOM", isDirectory: true)
    }

    func crestURL(surname: String) -> URL? {
        guard access != .unavailable else { return nil }
        let wanted = Self.lookupKey(surname)
        guard !wanted.isEmpty else { return nil }
        let matches = crests().filter {
            Self.lookupKey($0.surname) == wanted
        }
        // A case/diacritic collision is ambiguous, so fail closed.
        return matches.count == 1 ? matches[0].fileURL : nil
    }

    /// Verified crest images directly inside `Crests`, in deterministic order.
    func crests() -> [FamilyCrest] {
        guard access != .unavailable else { return [] }
        return verifiedImages(in: crestsDirectory).map {
            FamilyCrest(
                surname: $0.deletingPathExtension().lastPathComponent,
                fileURL: $0)
        }
    }

    func photoURLs(for person: GedcomFamilyGraph.Person) -> [URL] {
        photoURLs(for: FamilyAssetPerson(person))
    }

    /// Looks in both `People/<GEDCOM ID>` and `People/<name>`. Directory
    /// matching is case/diacritic-insensitive, but never recursive.
    func photoURLs(for person: FamilyAssetPerson) -> [URL] {
        guard access != .unavailable else { return [] }
        if let id = person.gedcomID,
           !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // An unsafe GEDCOM pointer is data corruption, not permission to
            // drop to a possibly shared name folder.
            guard !Self.safeGEDCOMIDComponent(id).isEmpty else { return [] }
            if let folder = uniqueSafePersonFolder(matching: id) {
                // GEDCOM identity wins. Never combine it with a same-name
                // folder, which could belong to another person with that name.
                return verifiedImages(in: folder)
            }
        }
        guard let folder = uniqueSafePersonFolder(matching: person.name) else {
            return []
        }
        return verifiedImages(in: folder)
    }

    /// Creates a human-readable person folder under `People`. Raw GEDCOM IDs
    /// and names are never appended as paths without component sanitization.
    @discardableResult
    func folderForPhotoRequest(person: GedcomFamilyGraph.Person) throws -> URL {
        try folderForPhotoRequest(person: FamilyAssetPerson(person))
    }

    @discardableResult
    func folderForPhotoRequest(person: FamilyAssetPerson) throws -> URL {
        try requireWriteAccess()
        let component = Self.safePersonFolderComponent(person)
        guard !component.isEmpty else { throw StoreError.invalidPerson }
        try ensureSafeDirectory(root)
        try ensureSafeDirectory(peopleDirectory)
        let folder = peopleDirectory.appendingPathComponent(component, isDirectory: true)
            .standardizedFileURL
        guard folder.deletingLastPathComponent() == peopleDirectory else {
            throw StoreError.unsafeDirectory(folder)
        }
        try ensureSafeDirectory(folder)
        return folder
    }

    @discardableResult
    func ensureCrestsDirectory() throws -> URL {
        try requireWriteAccess()
        try ensureSafeDirectory(root)
        try ensureSafeDirectory(crestsDirectory)
        return crestsDirectory
    }

    func readableCrestsDirectory() -> URL? {
        guard access != .unavailable, isSafeDirectory(crestsDirectory) else {
            return nil
        }
        return crestsDirectory
    }

    /// Copies a verified image into `Crests/<Surname>.<extension>` without
    /// replacing an existing crest. Replacement should remain an explicit UI
    /// action rather than an accidental consequence of a second import.
    @discardableResult
    func importCrest(from source: URL, surname: String) throws -> URL {
        try requireWriteAccess()
        let component = Self.safeSurnameComponent(surname)
        guard !component.isEmpty else { throw StoreError.invalidSurname }
        let source = source.standardizedFileURL
        guard isVerifiedImage(source) else {
            throw StoreError.sourceIsNotARegularImage(source)
        }
        let folder = try ensureCrestsDirectory()
        let ext = source.pathExtension.lowercased()
        let destination = folder
            .appendingPathComponent(component, isDirectory: false)
            .appendingPathExtension(ext)
            .standardizedFileURL
        guard destination.deletingLastPathComponent() == folder else {
            throw StoreError.unsafeDirectory(destination)
        }
        guard crestURL(surname: surname) == nil,
              !fileManager.fileExists(atPath: destination.path) else {
            throw StoreError.crestAlreadyExists(destination)
        }
        try fileManager.copyItem(at: source, to: destination)
        guard isVerifiedImage(destination),
              let imported = crestURL(surname: surname) else {
            try? fileManager.removeItem(at: destination)
            throw StoreError.sourceIsNotARegularImage(source)
        }
        return imported
    }

    /// Re-check a previously returned URL immediately before display/open.
    func revalidatedImageURL(_ url: URL) -> URL? {
        guard access != .unavailable else { return nil }
        let fresh = URL(fileURLWithPath: url.path, isDirectory: false)
        return isVerifiedImage(fresh) ? fresh : nil
    }

    /// Decode a bounded presentation image rather than the full phone/scan.
    func makeThumbnail(for url: URL, maxPixelSize: Int = 440) -> CGImage? {
        guard maxPixelSize > 0,
              let verified = revalidatedImageURL(url),
              let source = CGImageSourceCreateWithURL(verified as CFURL, nil)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary)
    }

    private func verifiedImages(in directory: URL) -> [URL] {
        guard isSafeDirectory(directory) else { return [] }
        return safeChildren(of: directory)
            .filter(isVerifiedImage)
            .sorted(by: Self.stableURLOrder)
    }

    private func uniqueSafePersonFolder(matching raw: String) -> URL? {
        let wanted = Self.lookupKey(raw)
        guard !wanted.isEmpty else { return nil }
        let matches = safeChildren(of: peopleDirectory).filter {
            isSafeDirectory($0) && Self.lookupKey($0.lastPathComponent) == wanted
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func safeChildren(of directory: URL) -> [URL] {
        guard isSafeDirectory(directory) else { return [] }
        return (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [
                .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
            ],
            options: [.skipsHiddenFiles])) ?? []
    }

    private func isSafeDirectory(_ url: URL) -> Bool {
        let fresh = URL(fileURLWithPath: url.path, isDirectory: true)
        guard let values = try? fresh.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private func isVerifiedImage(_ url: URL) -> Bool {
        let fresh = URL(fileURLWithPath: url.path, isDirectory: false)
        guard Self.allowedImageExtensions.contains(fresh.pathExtension.lowercased()),
              let values = try? fresh.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let source = CGImageSourceCreateWithURL(fresh as CFURL, nil),
              CGImageSourceGetCount(source) > 0
        else { return false }
        return true
    }

    private func ensureSafeDirectory(_ directory: URL) throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue, isSafeDirectory(directory) else {
                throw StoreError.unsafeDirectory(directory)
            }
            return
        }
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        guard isSafeDirectory(directory) else {
            throw StoreError.unsafeDirectory(directory)
        }
    }

    private func requireWriteAccess() throws {
        switch access {
        case .readWrite: return
        case .readOnly: throw StoreError.readOnly
        case .unavailable: throw StoreError.sourceUnavailable
        }
    }

    private static func safePersonFolderComponent(_ person: FamilyAssetPerson) -> String {
        if let rawID = person.gedcomID,
           !rawID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return safeGEDCOMIDComponent(rawID)
        }
        return safeDisplayComponent(person.name)
    }

    private static func safeGEDCOMIDComponent(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 120,
              trimmed != ".", trimmed != "..",
              trimmed.unicodeScalars.allSatisfy({ scalar in
                  CharacterSet.alphanumerics.contains(scalar)
                      || "@._-".unicodeScalars.contains(scalar)
              })
        else { return "" }
        return trimmed
    }

    private static func safeSurnameComponent(_ surname: String) -> String {
        safeDisplayComponent(surname)
    }

    private static func safeDisplayComponent(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
        let replaced = raw.unicodeScalars.map { scalar -> Character in
            invalid.contains(scalar) ? " " : Character(String(scalar))
        }
        var collapsed = String(replaced)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while collapsed.first == "." { collapsed.removeFirst() }
        collapsed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed != ".", collapsed != ".." else { return "" }
        return String(collapsed.prefix(120))
    }

    private static func lookupKey(_ raw: String) -> String {
        raw.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func stableURLOrder(_ lhs: URL, _ rhs: URL) -> Bool {
        let left = lookupKey(lhs.lastPathComponent)
        let right = lookupKey(rhs.lastPathComponent)
        return left == right ? lhs.path < rhs.path : left < right
    }

    private static func canonicalized(_ raw: URL, fileManager: FileManager) -> URL {
        var existing = raw.standardizedFileURL
        var tail: [String] = []
        while !fileManager.fileExists(atPath: existing.path),
              existing.pathComponents.count > 1 {
            tail.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var result = existing.resolvingSymlinksInPath()
        for component in tail {
            result.appendPathComponent(component)
        }
        return result.standardizedFileURL
    }

    private static let allowedImageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic",
    ]
}
