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
              let data = try? Data(contentsOf: fresh, options: .mappedIfSafe),
              isVerifiedImageData(data)
        else { return nil }
        return fresh
    }

    /// Bytes-in-memory validation shared by display-time revalidation and
    /// Photos imports (codex #663: "accepts truncated images without
    /// forcing decode"). Measured 2026-08-25: ImageIO reports a PNG cut to
    /// a THIRD of its bytes as `statusComplete` with a decodable frame —
    /// status and forced decode cannot tell a whole file from a stump. What
    /// can is the container: PNG ends in IEND, JPEG in the EOI marker, and
    /// HEIF/HEIC box lengths must sum exactly to the byte count. Both
    /// checks run — structure proves the file is whole, the decode proves
    /// the bytes are an image at all.
    static func isVerifiedImageData(_ data: Data) -> Bool {
        guard isStructurallyComplete(data),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0
        else { return false }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) != nil
    }

    /// Container-level "is this file whole?" for the formats the store
    /// admits. Unknown magic is NOT complete — the extension allow-list is
    /// jpg/jpeg/png/heic, and anything else is refused by content too.
    static func isStructurallyComplete(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        let head = [UInt8](data.prefix(12))
        // PNG: signature, and the last chunk is IEND + its fixed CRC.
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return [UInt8](data.suffix(8)) == [0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82]
        }
        // JPEG: SOI first; EOI must be the final marker (a few bytes of
        // padding after EOI is tolerated — some writers add it).
        if head.starts(with: [0xFF, 0xD8]) {
            let tail = [UInt8](data.suffix(64))
            guard let eoi = tail.lastIndex(of: 0xD9), eoi > 0, tail[eoi - 1] == 0xFF else { return false }
            return tail[(eoi + 1)...].allSatisfy { $0 == 0x00 || $0 == 0xFF || $0 == 0x0A || $0 == 0x20 }
        }
        // HEIF/HEIC (ISO BMFF): walk top-level boxes; they must land
        // exactly on the end of the data.
        if String(decoding: head[4..<8], as: UTF8.self) == "ftyp" {
            var offset = 0
            let count = data.count
            while offset + 8 <= count {
                var size = Int(data[offset]) << 24 | Int(data[offset + 1]) << 16
                    | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
                if size == 1 {
                    guard offset + 16 <= count else { return false }
                    size = 0
                    for i in 8..<16 { size = size << 8 | Int(data[offset + i]) }
                } else if size == 0 {
                    size = count - offset
                }
                guard size >= 8, offset <= count - size else { return false }
                offset += size
            }
            return offset == count
        }
        return false
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
        case imageTooLarge(bytes: Int)
        case createFailed(String, errno: Int32)

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
            case .imageTooLarge(let bytes):
                let mb = Double(bytes) / 1_048_576
                return String(format: "That photo is %.0f MB; the archive accepts photos up to %d MB.",
                              mb, FamilyAssetStore.maxImportBytes / 1_048_576)
            case .createFailed(let name, let errno):
                return "Couldn’t create \(name) in the archive (\(String(cString: strerror(errno))))."
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

    /// Names imported photos; injectable so tests can predict a destination
    /// (the symlink-swap test plants a link exactly where the import lands).
    var importClock: @Sendable () -> Date = { Date() }

    /// Largest photo the Photos picker may hand us (codex #663: the old
    /// path loaded unbounded `Data`). 48 MB covers any camera JPEG/HEIC;
    /// a scan bigger than that belongs in the folder by hand, not through
    /// a picker that holds the whole file in memory.
    static let maxImportBytes = 48 << 20

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
        let own = resolvedPersonFolder(for: person).map(verifiedImages(in:)) ?? []
        return own + groupPhotoURLs(for: person).filter { !own.contains($0) }
    }

    /// GEDCOM IDs that People/ folder names are keyed to (`_I42` suffix or a
    /// bare ID folder), normalised like `gedcomIDKey`. Used by the Get
    /// Family Tree replace prompt: a new export renumbers people, so these
    /// folders stop matching by ID (names still match). Read-only.
    func personFolderGEDCOMIDs() -> Set<String> {
        guard access != .unavailable else { return [] }
        var ids: Set<String> = []
        for folder in safePersonFolders() {
            let name = folder.lastPathComponent
            if let suffix = Self.folderIdentity(name).gedcomIDKey { ids.insert(suffix) }
            let direct = Self.gedcomIDKey(name)
            if direct.hasPrefix("I"), direct.count > 1, direct.dropFirst().allSatisfy(\.isNumber) { ids.insert(direct) }
        }
        return ids
    }

    // MARK: Group folders (Rick 2026-08-25: "RickDonnaBreenFamily")

    /// Photos from `People/` folders that name SEVERAL people — a couple or
    /// a family shot filed once instead of copied into every subject's
    /// folder. A folder is a group folder when its name carries a `Family`
    /// or `And` marker (`RickDonnaBreenFamily`, `Rick_and_Donna`); the
    /// remaining CamelCase/underscore tokens are the people. See
    /// `groupFolderMatches` for the matching rule. Presentation only, like
    /// every asset here; never evidence.
    func groupPhotoURLs(for person: FamilyAssetPerson) -> [URL] {
        guard access != .unavailable else { return [] }
        return safePersonFolders()
            .filter { Self.groupFolderMatches($0.lastPathComponent, person: person.name) }
            .flatMap(verifiedImages(in:))
    }

    /// Tokens of a group folder's name, lowercased, markers removed — or nil
    /// when the folder is not a group folder at all.
    static func groupFolderTokens(_ folderName: String) -> [String]? {
        // Split on underscores/spaces, then on CamelCase humps.
        var tokens: [String] = []
        for chunk in folderName.split(whereSeparator: { $0 == "_" || $0 == "-" || $0.isWhitespace }) {
            var current = ""
            for ch in chunk {
                if ch.isUppercase, !current.isEmpty { tokens.append(current); current = "" }
                current.append(ch)
            }
            if !current.isEmpty { tokens.append(current) }
        }
        let lowered = tokens.map { $0.lowercased() }
        let markers: Set<String> = ["family", "and", "the", "&"]
        guard lowered.contains(where: { markers.contains($0) }) else { return nil }
        let people = lowered.filter { !markers.contains($0) && !$0.isEmpty }
        return people.isEmpty ? nil : people
    }

    /// A person is in a group folder when their SURNAME is a token and
    /// either their first name — or its formal form through the curated
    /// diminutives (rick → richard) — is a token, or the folder names no
    /// one but the surname (`Breen_Family` → every Breen). Generational
    /// suffixes (jr/sr/ii) never count as surnames.
    static func groupFolderMatches(_ folderName: String, person: String) -> Bool {
        guard let tokens = groupFolderTokens(folderName) else { return false }
        let suffixes: Set<String> = ["jr", "sr", "ii", "iii", "iv"]
        let nameTokens = personNameKey(person).split(separator: " ").map(String.init)
            .filter { !suffixes.contains($0) }
        guard let first = nameTokens.first, let surname = nameTokens.last, nameTokens.count >= 2,
              tokens.contains(surname) else { return false }
        func formal(_ t: String) -> String { GedcomFamilyGraph.diminutives[t] ?? t }
        let formalTokens = Set(tokens.map(formal))
        if formalTokens.contains(formal(first)) { return true }
        // Surname-only group: nothing left once the surname is removed.
        return tokens.allSatisfy { $0 == surname }
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

    /// Save image bytes chosen in Apple Photos into a person's request
    /// folder (Rick 2026-08-24: "I want the Photos option too"). Same
    /// hardening as importCrest: write access required, the folder must be
    /// a live People/ child, the bytes must decode as an image BEFORE they
    /// land in the archive, never overwrite, re-verify after the copy.
    func importPersonPhoto(_ data: Data,
                           fileExtension: String,
                           into folder: URL) throws -> URL {
        try requireWriteAccess()
        guard let target = revalidatedPhotoRequestFolder(folder) else {
            throw StoreError.unsafeDirectory(folder)
        }
        let ext = fileExtension.lowercased()
        // Same set the store will later DISCOVER — an importable-but-
        // invisible TIFF was codex #663's "contradictory TIFF support".
        guard Self.allowedImageExtensions.contains(ext) else {
            throw StoreError.sourceIsNotARegularImage(folder.appendingPathComponent("photo.\(ext)"))
        }
        guard data.count <= Self.maxImportBytes else {
            throw StoreError.imageTooLarge(bytes: data.count)
        }
        // Validate the BYTES, in memory, before anything touches disk. The
        // old cache-root staging file was a symlink-swap window (codex
        // #663): a link planted between write and copy would have been
        // followed into the archive. No staging file, no window.
        guard FamilyAssetImageValidator.isVerifiedImageData(data) else {
            throw StoreError.sourceIsNotARegularImage(folder.appendingPathComponent("photo.\(ext)"))
        }
        let stamp: String = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyyMMdd-HHmmss"
            return f.string(from: importClock())
        }()
        let stem = target.lastPathComponent + "-from-Photos-" + stamp

        // Anchor on descriptors, not paths (codex #675: the folder could be
        // swapped for a symlink between `revalidatedPhotoRequestFolder`
        // and the write). Root is opened O_DIRECTORY|O_NOFOLLOW, every
        // component below it is openat(O_DIRECTORY|O_NOFOLLOW) relative to
        // its parent, and the file is openat(O_CREAT|O_EXCL|O_NOFOLLOW) —
        // the same walk ArchivePromoteEngine uses for the archive proper.
        let rootPath = root.path
        guard target.path.hasPrefix(rootPath + "/") else {
            throw StoreError.unsafeDirectory(target)
        }
        let components = target.path.dropFirst(rootPath.count + 1)
            .split(separator: "/").map(String.init)
        let rootFD: Int32
        let dirFD: Int32
        do {
            rootFD = try ArchivePromoteEngine.openDirectory(rootPath)
        } catch {
            throw StoreError.unsafeDirectory(root)
        }
        defer { Darwin.close(rootFD) }
        do {
            dirFD = try ArchivePromoteEngine.descend(
                from: rootFD, components: components, create: false, displayRoot: rootPath)
        } catch {
            throw StoreError.unsafeDirectory(target)
        }
        defer { Darwin.close(dirFD) }

        // Only EEXIST advances the suffix (codex #675: a disk-full or
        // permission error must surface at once, not after 50 masks).
        for suffix in 1...50 {
            let name = (suffix == 1 ? stem : "\(stem)-\(suffix)") + "." + ext
            let fd = openat(dirFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
            if fd < 0 {
                let e = errno
                if e == EEXIST { continue }
                throw StoreError.createFailed(name, errno: e)
            }
            var written = false
            defer {
                Darwin.close(fd)
                if !written { unlinkat(dirFD, name, 0) }
            }
            try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                var offset = 0
                while offset < buffer.count {
                    let n = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                    if n < 0 {
                        let e = errno
                        if e == EINTR { continue }
                        throw StoreError.createFailed(name, errno: e)
                    }
                    offset += n
                }
            }
            _ = fsync(fd)
            // What is on disk is what was validated: same length, regular
            // file, on the descriptor we wrote — not on a path.
            var sb = stat()
            guard fstat(fd, &sb) == 0, (sb.st_mode & S_IFMT) == S_IFREG,
                  Int(sb.st_size) == data.count else {
                throw StoreError.createFailed(name, errno: EIO)
            }
            written = true
            return target.appendingPathComponent(name, isDirectory: false).standardizedFileURL
        }
        throw StoreError.createFailed(stem + "." + ext, errno: EEXIST)
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
