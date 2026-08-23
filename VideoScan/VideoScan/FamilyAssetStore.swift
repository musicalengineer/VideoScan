import Foundation
import CoreGraphics
import ImageIO
import VideoScanCore

/// Immutable authority captured before Hallie leaves the main actor.  Paths
/// alone are not permission: `access` carries the viewer/offline/UUID result
/// that was current when the snapshot was published.
struct FamilyAssetConfiguration: Sendable, Equatable {
    let roots: FamilyAssetStore.Roots
    let access: FamilyAssetStore.Access
    /// Read-only compatibility source used only when no Master Archive is
    /// designated.  A designated-but-offline archive must never fall back
    /// to a different tree on the internal disk.
    let legacyGEDCOMDirectory: URL?

    func makeStore() -> FamilyAssetStore {
        FamilyAssetStore(
            root: roots.assets,
            cacheRoot: roots.thumbnailCache,
            access: access)
    }

    func loadFamilyGraph() -> GedcomFamilyGraph? {
        guard access != .unavailable else { return nil }
        return FamilyGraphFileLoader(
            originalsDirectory: gedcomDirectory()).loadNewest()
    }

    /// Prefer the deployed assets/GEDCOM convention.  Older installations
    /// stored their only export in family-tree/originals; retain read access
    /// until they adopt a Master Archive, without copying or mutating it.
    func gedcomDirectory(fileManager: FileManager = .default) -> URL {
        let preferred = roots.assets.appendingPathComponent(
            "GEDCOM", isDirectory: true)
        guard !Self.hasGEDCOMCandidate(preferred, fileManager: fileManager),
              let legacyGEDCOMDirectory,
              Self.hasGEDCOMCandidate(legacyGEDCOMDirectory,
                                      fileManager: fileManager) else {
            return preferred
        }
        return legacyGEDCOMDirectory
    }

    private static func hasGEDCOMCandidate(
        _ directory: URL,
        fileManager: FileManager
    ) -> Bool {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]) else { return false }
        return files.contains { url in
            guard url.pathExtension.lowercased() == "ged",
                  let values = try? url.resourceValues(forKeys: keys) else {
                return false
            }
            return values.isRegularFile == true && values.isSymbolicLink != true
        }
    }
}

/// Small lock-protected bridge between the main-actor archive model and
/// Hallie's detached workers.  This replaces a `nonisolated(unsafe)` mutable
/// pathname; readers always receive one coherent value-type snapshot.
final class FamilyAssetConfigurationCenter: @unchecked Sendable {
    static let shared = FamilyAssetConfigurationCenter()

    private let lock = NSLock()
    private var value: FamilyAssetConfiguration

    private init() {
        value = Self.configuration(
            masterArchiveRoot: nil,
            masterIsSafelyAvailable: true,
            readOnly: true)
    }

    func snapshot() -> FamilyAssetConfiguration {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func publish(
        masterArchiveRoot: URL?,
        masterIsSafelyAvailable: Bool,
        readOnly: Bool
    ) {
        let next = Self.configuration(
            masterArchiveRoot: masterArchiveRoot,
            masterIsSafelyAvailable: masterIsSafelyAvailable,
            readOnly: readOnly)
        lock.lock()
        value = next
        lock.unlock()
    }

    static func configuration(
        masterArchiveRoot: URL?,
        masterIsSafelyAvailable: Bool,
        readOnly: Bool,
        applicationSupportRoot: URL? = nil
    ) -> FamilyAssetConfiguration {
        let support = applicationSupportRoot
            ?? FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        let roots = FamilyAssetStore.productionRoots(
            masterArchiveRoot: masterArchiveRoot,
            applicationSupportRoot: support)
        let access: FamilyAssetStore.Access
        if masterArchiveRoot != nil, !masterIsSafelyAvailable {
            access = .unavailable
        } else {
            access = readOnly ? .readOnly : .readWrite
        }
        let legacyGEDCOMDirectory = masterArchiveRoot == nil
            ? roots.thumbnailCache.deletingLastPathComponent()
                .appendingPathComponent("originals", isDirectory: true)
            : nil
        return FamilyAssetConfiguration(
            roots: roots,
            access: access,
            legacyGEDCOMDirectory: legacyGEDCOMDirectory)
    }
}

/// Content validation shared by archive assets and legacy POI covers.  It
/// reopens and identifies the file immediately before display; extensions
/// are not treated as proof that bytes are an image.
enum FamilyAssetImageValidator {
    static func revalidatedURL(_ url: URL) -> URL? {
        let fresh = URL(fileURLWithPath: url.path, isDirectory: false)
        guard FamilyAssetStore.allowedImageExtensions.contains(
                fresh.pathExtension.lowercased()),
              let values = try? fresh.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let source = CGImageSourceCreateWithURL(fresh as CFURL, nil),
              CGImageSourceGetCount(source) > 0
        else { return nil }
        return fresh
    }

    static func thumbnail(_ url: URL, maxPixelSize: Int) -> CGImage? {
        guard maxPixelSize > 0,
              let verified = revalidatedURL(url),
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

    static func thumbnailJPEGData(
        _ url: URL,
        maxPixelSize: Int = 1200,
        quality: Double = 0.86
    ) -> Data? {
        guard let image = thumbnail(url, maxPixelSize: maxPixelSize) else {
            return nil
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

/// A person key used to locate presentation photos without making them
/// genealogical evidence. GEDCOM remains the source of family relationships.
struct FamilyAssetPerson: Sendable, Equatable {
    let gedcomID: String?
    let name: String
    let birthYear: Int?

    init(gedcomID: String? = nil, name: String, birthYear: Int? = nil) {
        self.gedcomID = gedcomID
        self.name = name
        self.birthYear = birthYear
    }

    init(_ person: GedcomFamilyGraph.Person) {
        self.init(
            gedcomID: person.id,
            name: person.name,
            birthYear: person.birthYear)
    }
}

struct FamilyCrest: Sendable, Equatable, Identifiable {
    var id: String { fileURL.path }
    let surname: String
    let fileURL: URL
}

/// Local-first storage for family-tree presentation assets.
///
/// `root` is normally `<Master Archive>/40_Family_Tree`. When no Master Archive
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
            $0.standardizedFileURL.appendingPathComponent("40_Family_Tree", isDirectory: true)
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

    /// Resolves the deployed `People/<Name>[_bYYYY][_I<GEDCOM-ID>]` convention.
    /// GEDCOM identity wins, then birth year, then an unambiguous name. Folder
    /// matching is case/diacritic-insensitive, but never recursive.
    func photoURLs(for person: FamilyAssetPerson) -> [URL] {
        guard access != .unavailable else { return [] }
        guard let folder = resolvedPersonFolder(for: person) else { return [] }
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
        if let rawID = person.gedcomID,
           !rawID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           Self.safeGEDCOMIDComponent(rawID).isEmpty {
            throw StoreError.invalidPerson
        }
        try ensureSafeDirectory(root)
        try ensureSafeDirectory(peopleDirectory)
        if let existing = resolvedPersonFolder(for: person, creatingRequest: true) {
            return existing
        }

        let component = try newPersonFolderComponent(for: person)
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

    @discardableResult
    func ensureGEDCOMDirectory() throws -> URL {
        try requireWriteAccess()
        try ensureSafeDirectory(root)
        try ensureSafeDirectory(gedcomDirectory)
        return gedcomDirectory
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
        return FamilyAssetImageValidator.revalidatedURL(url)
    }

    /// Decode a bounded presentation image rather than the full phone/scan.
    func makeThumbnail(for url: URL, maxPixelSize: Int = 440) -> CGImage? {
        guard access != .unavailable else { return nil }
        return FamilyAssetImageValidator.thumbnail(url, maxPixelSize: maxPixelSize)
    }

    /// Re-check a photo-request directory before Finder opens it.  The URL
    /// must still be a direct child of this store's People directory and the
    /// current snapshot must still authorize writes.
    func revalidatedPhotoRequestFolder(_ url: URL) -> URL? {
        guard access == .readWrite else { return nil }
        let fresh = URL(fileURLWithPath: url.path, isDirectory: true)
            .standardizedFileURL
        guard fresh.deletingLastPathComponent() == peopleDirectory,
              isSafeDirectory(fresh) else { return nil }
        return fresh
    }

    private func verifiedImages(in directory: URL) -> [URL] {
        guard isSafeDirectory(directory) else { return [] }
        return safeChildren(of: directory)
            .filter(isVerifiedImage)
            .sorted(by: Self.stableURLOrder)
    }

    private struct FolderIdentity {
        let nameKey: String
        let birthYear: Int?
        let gedcomIDKey: String?
    }

    private func safePersonFolders() -> [URL] {
        safeChildren(of: peopleDirectory)
            .filter(isSafeDirectory)
            .sorted(by: Self.stableURLOrder)
    }

    private func resolvedPersonFolder(
        for person: FamilyAssetPerson,
        creatingRequest: Bool = false
    ) -> URL? {
        let folders = safePersonFolders()
        let rawID = person.gedcomID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !rawID.isEmpty {
            // An unsafe pointer is corrupt identity data, not permission to
            // fall through to a shared human name.
            guard !Self.safeGEDCOMIDComponent(rawID).isEmpty else { return nil }
            let wantedID = Self.gedcomIDKey(rawID)
            let idMatches = folders.filter { folder in
                let direct = Self.gedcomIDKey(folder.lastPathComponent)
                let suffix = Self.folderIdentity(folder.lastPathComponent).gedcomIDKey
                return !wantedID.isEmpty && (direct == wantedID || suffix == wantedID)
            }
            if idMatches.count == 1 { return idMatches[0] }
            if idMatches.count > 1 { return nil }
        }

        let wantedName = Self.personNameKey(person.name)
        guard !wantedName.isEmpty else { return nil }
        let nameMatches = folders.filter {
            Self.folderIdentity($0.lastPathComponent).nameKey == wantedName
        }
        if let birthYear = person.birthYear {
            let yearMatches = nameMatches.filter {
                Self.folderIdentity($0.lastPathComponent).birthYear == birthYear
            }
            if yearMatches.count == 1 {
                // An ID-bearing write request with no matching ID means the
                // year-only folder may be a different same-name/same-year
                // person. Give the new request its explicit ID suffix.
                if creatingRequest, !rawID.isEmpty { return nil }
                return yearMatches[0]
            }
            if yearMatches.count > 1 { return nil }
            if creatingRequest, !nameMatches.isEmpty { return nil }
        }
        return nameMatches.count == 1 ? nameMatches[0] : nil
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
        FamilyAssetImageValidator.revalidatedURL(url) != nil
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

    private func newPersonFolderComponent(for person: FamilyAssetPerson) throws -> String {
        let base = Self.safePersonNameComponent(person.name)
        let rawID = person.gedcomID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let id = Self.gedcomIDKey(rawID)
        guard !base.isEmpty || !id.isEmpty else { throw StoreError.invalidPerson }

        let folders = safePersonFolders()
        let baseName = base.isEmpty ? id : base
        let sameName = folders.filter {
            Self.folderIdentity($0.lastPathComponent).nameKey
                == Self.personNameKey(person.name)
        }
        if sameName.isEmpty { return baseName }

        if let birthYear = person.birthYear {
            let withYear = "\(baseName)_b\(birthYear)"
            let sameYear = folders.filter {
                Self.lookupKey($0.lastPathComponent) == Self.lookupKey(withYear)
            }
            if sameYear.isEmpty { return withYear }
            if !id.isEmpty { return "\(withYear)_\(id)" }
            throw StoreError.invalidPerson
        }
        if !id.isEmpty { return "\(baseName)_\(id)" }
        throw StoreError.invalidPerson
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

    private static func safePersonNameComponent(_ raw: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:.\'’")
            .union(.controlCharacters)
        let cleaned = String(raw.unicodeScalars.compactMap { scalar -> Character? in
            if forbidden.contains(scalar) { return nil }
            return scalar == "_" ? " " : Character(String(scalar))
        })
        let words = cleaned.split(whereSeparator: { $0.isWhitespace })
        let component = words.joined(separator: "_")
        guard component != ".", component != ".." else { return "" }
        return String(component.prefix(120))
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

    private static func personNameKey(_ raw: String) -> String {
        let punctuation = CharacterSet(charactersIn: "/.\'’")
        let normalized = String(raw.unicodeScalars.compactMap { scalar -> Character? in
            if punctuation.contains(scalar) { return nil }
            return scalar == "_" ? " " : Character(String(scalar))
        })
        return lookupKey(normalized)
    }

    private static func gedcomIDKey(_ raw: String) -> String {
        raw.uppercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    private static func folderIdentity(_ raw: String) -> FolderIdentity {
        let punctuation = CharacterSet(charactersIn: "/.\'’")
        let cleaned = String(raw.unicodeScalars.compactMap { scalar -> Character? in
            if punctuation.contains(scalar) { return nil }
            return Character(String(scalar))
        })
        var parts = cleaned.split(whereSeparator: {
            $0 == "_" || $0.isWhitespace
        }).map(String.init)
        var id: String?
        if let last = parts.last {
            let candidate = gedcomIDKey(last)
            if candidate.hasPrefix("I"),
               candidate.dropFirst().contains(where: { $0.isNumber }) {
                id = candidate
                parts.removeLast()
            }
        }
        var year: Int?
        if let last = parts.last,
           last.count == 5,
           last.lowercased().hasPrefix("b"),
           let parsed = Int(last.dropFirst()) {
            year = parsed
            parts.removeLast()
        }
        return FolderIdentity(
            nameKey: personNameKey(parts.joined(separator: " ")),
            birthYear: year,
            gedcomIDKey: id)
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

    fileprivate static let allowedImageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic",
    ]
}
