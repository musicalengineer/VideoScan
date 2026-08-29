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
    /// Who the group-folder name tokens mean (2026-08-26). Published by
    /// whoever holds the parsed tree; nil → name-only matching.
    var identity: FamilyAssetIdentityDirectory? = nil

    func makeStore() -> FamilyAssetStore {
        var store = FamilyAssetStore(
            root: roots.assets,
            cacheRoot: roots.thumbnailCache,
            access: access)
        store.identity = identity
        return store
    }

    /// Parse-or-decode the family tree for this configuration. Prefer
    /// `FamilyGraphSharedCache.shared.graph(for:store:)` on any repeated
    /// path (every Hallie turn): with a `compiledStore` the promoted
    /// artifact is decoded and NO GEDCOM parse happens (Rick 2026-08-28:
    /// one-time ingest; launch and queries never parse). `compiledStore ==
    /// nil` is the parse-every-time seam for tests and isolated callers.
    func loadFamilyGraph(compiledStore: FamilyGraphCompiledStore? = nil) -> GedcomFamilyGraph? {
        loadFamilyGraphOutcome(compiledStore: compiledStore)?.graph
    }

    /// Same as `loadFamilyGraph` with the loader's full outcome (`compiled`
    /// tells whether the promoted artifact served the load). Nil only when
    /// the archive authority is `.unavailable` — never fall back to a
    /// different tree when the designated Master is offline.
    func loadFamilyGraphOutcome(
        compiledStore: FamilyGraphCompiledStore? = nil,
        progress: @escaping (String) -> Void = { _ in }
    ) -> FamilyGraphFileLoader.Outcome? {
        guard access != .unavailable else { return nil }
        var loader = FamilyGraphFileLoader(originalsDirectory: gedcomDirectory())
        loader.compiledStore = compiledStore
        loader.progress = progress
        return loader.loadNewestOutcome()
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

/// One in-process family graph shared by every Hallie entry point
/// (HallieAppTurnCoordinator, ArchivistChatWindow's legacy path,
/// HallieShellCLI). Codex #792: those paths each called
/// `loadFamilyGraph()` with no store, so every Hallie turn re-parsed the
/// GEDCOM. Now the first caller decodes the promoted artifact (tens of
/// ms for 16 MB) and later callers get the same value back until the
/// world changes.
///
/// Staleness key — all cheap (no artifact decode, no parse):
///   • the configuration's GEDCOM directory and access (an archive
///     disconnect / UUID refusal changes `access` → miss → nil, so a
///     cached graph never survives a revoked authority);
///   • the store's pointer (`current.json`, a few hundred bytes): any
///     ingest, rollback or schema bump repoints → miss → re-decode;
///   • the (name, mtime) list of .ged files in the directory: a new or
///     touched pull → miss (the loader then decides compiled vs parse).
///
/// C++ analogy: a mutex-guarded memo of `(key, value)`; `graph(for:)` is
/// `key == memo.key ? memo.value : (memo = load(), memo.value)`. The lock
/// is held across the load on purpose so two concurrent turns cannot
/// both decode the artifact.
final class FamilyGraphSharedCache: @unchecked Sendable {
    static let shared = FamilyGraphSharedCache(log: { appLog.write($0) })

    struct Loaded {
        let graph: GedcomFamilyGraph
        /// True when the promoted compiled artifact served the load
        /// (no GEDCOM parse). Carried from the loader's outcome.
        let compiled: Bool
        /// Identity of the cached load: two `Loaded` values with equal
        /// tokens came from ONE decode/parse (the graph is a value type,
        /// so this is how a test proves the instance was reused).
        let token: UUID
        /// True when this call did no loading at all.
        let reused: Bool
    }

    private struct Key: Equatable {
        let directory: URL
        let access: FamilyAssetStore.Access
        let storeRoot: URL?
        let pointer: FamilyGraphCompiledStore.Pointer?
        let gedcomFiles: [String]
    }

    private let lock = NSLock()
    private var entry: (key: Key, graph: GedcomFamilyGraph, compiled: Bool, token: UUID,
                        outcome: FamilyGraphFileLoader.Outcome)?
    private var loadCount = 0
    private let log: (String) -> Void

    init(log: @escaping (String) -> Void = { _ in }) { self.log = log }

    /// How many times the loader actually ran (decode or parse). Tests use
    /// this to prove consecutive turns did not reload.
    var loaderRuns: Int { lock.withLock { loadCount } }

    /// The graph for `configuration`, loading through `store` on a miss.
    func graph(for configuration: FamilyAssetConfiguration,
               store: FamilyGraphCompiledStore?) -> GedcomFamilyGraph? {
        load(for: configuration, store: store)?.graph
    }

    func load(for configuration: FamilyAssetConfiguration,
              store: FamilyGraphCompiledStore?,
              progress: ((String) -> Void)? = nil) -> Loaded? {
        outcome(for: configuration, store: store, progress: progress).loaded
    }

    /// The loader's full outcome plus the cached `Loaded` when a graph came
    /// back (2026-08-29: the Family Tree tab loads through here too, so the
    /// tab, Hallie and the People-tab probe share ONE decode). A hit
    /// returns the memo without touching the loader; a miss runs the
    /// loader under the lock. An outcome without a graph (nothing on disk,
    /// or `needsRecompile`) is returned but never cached. `outcome` is nil
    /// only when the archive authority is `.unavailable`.
    func outcome(for configuration: FamilyAssetConfiguration,
                 store: FamilyGraphCompiledStore?,
                 progress: ((String) -> Void)? = nil)
        -> (outcome: FamilyGraphFileLoader.Outcome?, loaded: Loaded?) {
        guard configuration.access != .unavailable else {
            // Revoked authority: drop what we had so a later republish
            // cannot hand out a tree from before the disconnect.
            lock.withLock { entry = nil }
            return (nil, nil)
        }
        let key = Key(directory: configuration.gedcomDirectory(),
                      access: configuration.access,
                      storeRoot: store?.root,
                      pointer: store?.readPointer(),
                      gedcomFiles: Self.gedcomStamps(in: configuration.gedcomDirectory()))
        return lock.withLock {
            if let entry, entry.key == key {
                let loaded = Loaded(graph: entry.graph, compiled: entry.compiled, token: entry.token, reused: true)
                return (entry.outcome, loaded)
            }
            loadCount += 1
            let report: (String) -> Void = { [log] phase in
                log("[hallie] family graph: \(phase)")
                progress?(phase)
            }
            guard let outcome = configuration.loadFamilyGraphOutcome(compiledStore: store, progress: report) else {
                entry = nil
                return (nil, nil)
            }
            guard let graph = outcome.graph else {
                entry = nil
                return (outcome, nil)
            }
            let token = UUID()
            entry = (key, graph, outcome.compiled, token, outcome)
            log("[hallie] family graph loaded (compiled: \(outcome.compiled), \(graph.people.count) people, "
                + "\(outcome.selectedURL?.lastPathComponent ?? "no source"))")
            return (outcome, Loaded(graph: graph, compiled: outcome.compiled, token: token, reused: false))
        }
    }

    /// The pulls a refused compiled generation was built from (live miss
    /// #8, 2026-08-29): non-empty when there is NO graph only because this
    /// version refused an older generation (codec/schema) and its sources
    /// are on disk unchanged. Empty with a graph, or with genuinely no
    /// tree. Never cached — the loader's version check is cheap and the
    /// next promote clears it.
    func needsRecompile(for configuration: FamilyAssetConfiguration,
                        store: FamilyGraphCompiledStore?) -> [URL] {
        let result = outcome(for: configuration, store: store)
        guard result.loaded == nil else { return [] }
        return result.outcome?.needsRecompile ?? []
    }

    /// Forget the cached graph (tests; or after an in-app ingest when the
    /// caller wants the next turn to see it without waiting for a key miss —
    /// the pointer change already forces one).
    func invalidate() { lock.withLock { entry = nil } }

    /// "name|mtime" for every regular .ged in `directory`, sorted — the
    /// part of the newest-file rule that can change under us.
    private static func gedcomStamps(in directory: URL) -> [String] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { return [] }
        return files.compactMap { url -> String? in
            guard url.pathExtension.lowercased() == "ged",
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { return nil }
            let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
            return "\(url.lastPathComponent)|\(mtime)"
        }.sorted()
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
        // Identity is derived from the tree, not the roots; it survives a
        // roots/authority republish and is replaced when the tree reloads.
        var carried = next
        carried.identity = value.identity
        value = carried
        lock.unlock()
    }

    /// Replace the identity directory (tree reload, or a Hallie turn that
    /// just built a fuller one from CyberBrain + People-tab aliases).
    func publishIdentity(_ identity: FamilyAssetIdentityDirectory?) {
        lock.lock()
        value.identity = identity
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
    /// FamilySearch ID ("G2CL-86B") when the record carries one. The key of
    /// the one-photo-per-person folder (`People/<FSID>/`, 2026-08-29): a
    /// re-pull renumbers `@I` pointers but never this.
    let familySearchID: String?

    init(gedcomID: String? = nil, name: String, birthYear: Int? = nil,
         familySearchID: String? = nil) {
        self.gedcomID = gedcomID
        self.name = name
        self.birthYear = birthYear
        self.familySearchID = familySearchID
    }

    init(_ person: GedcomFamilyGraph.Person) {
        self.init(
            gedcomID: person.id,
            name: person.name,
            birthYear: person.birthYear,
            familySearchID: person.familySearchID)
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
    /// Optional identity-aware attribution for group folders. Nil keeps the
    /// name-only rule (`groupFolderMatches(_:person:)`).
    var identity: FamilyAssetIdentityDirectory? = nil

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
        // The explicit choice leads (2026-08-29), then the FamilySearch-ID
        // folder, then the name/pointer folder, then group folders.
        var own: [URL] = []
        var seen: Set<URL> = []
        func add(_ urls: [URL]) {
            for url in urls where seen.insert(url).inserted { own.append(url) }
        }
        if let chosen = chosenPhoto(for: person) { add([chosen.url]) }
        if let folder = familySearchIDFolder(for: person) { add(verifiedImages(in: folder)) }
        if let folder = resolvedPersonFolder(for: person) { add(verifiedImages(in: folder)) }
        let all = own + groupPhotoURLs(for: person).filter { !seen.contains($0) }
        return all.filter { !isPhotoExcluded($0, for: person) }
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
            .filter { groupFolderMatches($0.lastPathComponent, person: person) }
            .flatMap(verifiedImages(in:))
            .filter { !isPhotoExcluded($0, for: person) }
    }

    /// Identity-aware when the store carries a directory AND the person is a
    /// tree record it knows (2026-08-26: "rick" must not reach Richard Sr);
    /// otherwise the name-only rule.
    func groupFolderMatches(_ folderName: String, person: FamilyAssetPerson) -> Bool {
        if let identity, let member = identity.member(person.gedcomID) {
            guard let tokens = Self.groupFolderTokens(folderName) else { return false }
            return identity.folderNames(member.gedcomID, folderTokens: tokens)
        }
        return Self.groupFolderMatches(folderName, person: person.name)
    }

    // MARK: Per-photo exclusions (2026-08-26: "this photo is … me and my family")

    /// Sidecar beside a photo naming the tree people it is NOT of:
    /// `SouthEastMontana1995.jpg.notof.json` → `{"notOf":["@I2@"], …}`.
    /// Travels with the photo, human-readable, additive; nothing else in
    /// the archive is touched.
    static let exclusionSidecarSuffix = ".notof.json"

    struct PhotoExclusion: Codable, Sendable, Equatable {
        var notOf: [String]
        var notedBy: String?
        var notedAt: Date?
        var caption: String?
    }

    static func exclusionSidecarURL(for photo: URL) -> URL {
        photo.deletingLastPathComponent()
            .appendingPathComponent(photo.lastPathComponent + exclusionSidecarSuffix)
    }

    /// GEDCOM IDs (normalised like `gedcomIDKey`) the photo is recorded as
    /// not showing. Empty when no sidecar exists or it is unreadable.
    func photoExclusions(for photo: URL) -> Set<String> {
        let sidecar = Self.exclusionSidecarURL(for: photo)
        guard let values = try? sidecar.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let data = try? Data(contentsOf: sidecar),
              data.count <= 64 << 10,
              let record = try? Self.sidecarDecoder.decode(PhotoExclusion.self, from: data)
        else { return [] }
        return Set(record.notOf.map(Self.gedcomIDKey).filter { !$0.isEmpty })
    }

    private func isPhotoExcluded(_ photo: URL, for person: FamilyAssetPerson) -> Bool {
        guard let id = person.gedcomID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty else { return false }
        let key = Self.gedcomIDKey(id)
        guard !key.isEmpty else { return false }
        return photoExclusions(for: photo).contains(key)
    }

    /// Record that `photo` does not show `gedcomID`. The photo must be a
    /// verified image under `People/`; the sidecar is written atomically and
    /// merged with any earlier exclusions. Requires write access.
    @discardableResult
    func excludePhoto(_ photo: URL, from gedcomID: String,
                      notedBy: String? = nil, caption: String? = nil,
                      at date: Date = Date()) throws -> URL {
        try requireWriteAccess()
        let id = gedcomID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !Self.safeGEDCOMIDComponent(id).isEmpty else {
            throw StoreError.invalidPerson
        }
        let canonicalPhoto = Self.canonicalized(photo, fileManager: fileManager)
        let parent = canonicalPhoto.deletingLastPathComponent()
        guard parent.deletingLastPathComponent().standardizedFileURL == peopleDirectory.standardizedFileURL,
              isSafeDirectory(parent),
              isVerifiedImage(canonicalPhoto) else {
            throw StoreError.sourceIsNotARegularImage(photo)
        }
        let sidecar = Self.exclusionSidecarURL(for: canonicalPhoto)
        if let values = try? sidecar.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]),
           values.isSymbolicLink == true || values.isDirectory == true {
            throw StoreError.unsafeDirectory(sidecar)
        }
        var record = (try? Data(contentsOf: sidecar))
            .flatMap { try? Self.sidecarDecoder.decode(PhotoExclusion.self, from: $0) }
            ?? PhotoExclusion(notOf: [])
        if !record.notOf.contains(where: { Self.gedcomIDKey($0) == Self.gedcomIDKey(id) }) {
            record.notOf.append(id)
        }
        record.notedBy = notedBy ?? record.notedBy
        record.notedAt = date
        record.caption = caption ?? record.caption
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try encoder.encode(record).write(to: sidecar, options: .atomic)
        } catch {
            throw StoreError.createFailed(sidecar.lastPathComponent, errno: errno)
        }
        return sidecar
    }

    private static let sidecarDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

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
        return try writePersonPhotoData(data, stem: stem, ext: ext, into: target)
    }

    // MARK: Card photo (Adjust Photo…, 2026-08-26)

    /// A card photo is the cropped/centred portrait the card prefers:
    /// `<stem>-card.<ext>` next to the original in the person's folder.
    static func isCardPhoto(_ url: URL) -> Bool {
        cardStem(url.deletingPathExtension().lastPathComponent) != nil
    }

    /// "portrait-card" / "portrait-card-2" → "portrait"; nil when the stem
    /// is not a card name at all.
    static func cardStem(_ stem: String) -> String? {
        var base = stem
        // Drop the never-overwrite counter first ("-2", "-17").
        if let dash = base.lastIndex(of: "-"),
           base[base.index(after: dash)...].allSatisfy(\.isNumber),
           base.index(after: dash) < base.endIndex {
            base = String(base[..<dash])
        }
        guard base.lowercased().hasSuffix("-card"), base.count > 5 else { return nil }
        return String(base.dropLast(5))
    }

    /// Precedence rule for the card: the NEWEST `*-card.*` image in the
    /// person's own folder, else nil (callers fall back to `photoURLs.first`).
    /// The original is never removed or renamed, so "Adjust" is reversible
    /// by deleting the card file in Finder.
    func cardPhotoURL(for person: FamilyAssetPerson) -> URL? {
        guard access != .unavailable else { return nil }
        // The explicit choice (either view, newest wins) beats any crop
        // found by convention — a provider never overrides a choice.
        if let chosen = chosenPhoto(for: person) { return chosen.url }
        guard let folder = resolvedPersonFolder(for: person) else { return nil }
        let cards = verifiedImages(in: folder).filter(Self.isCardPhoto)
        // FileManager, not URL.resourceValues: NSURL caches resource values
        // per instance and a just-touched file can read back stale.
        func modified(_ url: URL) -> Date {
            (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
                ?? .distantPast
        }
        return cards.max { lhs, rhs in
            let l = modified(lhs), r = modified(rhs)
            return l == r ? Self.stableURLOrder(lhs, rhs) : l < r
        }
    }

    /// The photo "Adjust" starts from: the first non-card image in the
    /// person's own folder (never a previous crop of a crop).
    func originalPhotoURL(for person: FamilyAssetPerson) -> URL? {
        guard access != .unavailable else { return nil }
        if let chosen = chosenPhoto(for: person), !Self.isCardPhoto(chosen.url) {
            return chosen.url
        }
        guard let folder = resolvedPersonFolder(for: person) else { return nil }
        return verifiedImages(in: folder).first { !Self.isCardPhoto($0) }
    }

    // MARK: One photo per person (2026-08-29: "it keeps reverting")

    /// The explicit portrait choice for a person — ONE per person, shared by
    /// the Family Tree card and the People tab. A sidecar
    /// `People/<FamilySearch ID>/chosen-photo.json` (tree-keyed: survives a
    /// re-pull that renumbers `@I` pointers; a record without an FSID uses
    /// its own name/pointer folder) names the image: a file in that folder,
    /// or in another People/ folder (an Adjust crop saved beside its
    /// original). Precedence against the People-tab cover is by
    /// `chosenAt` — the most recent explicit choice wins in both views.
    struct PersonPhotoChoice: Codable, Sendable, Equatable {
        /// Image path relative to People/, exactly `<folder>/<file>`.
        let file: String
        let chosenAt: Date
        /// Where it was chosen: `tree.pick`, `tree.applePhotos`,
        /// `tree.adjust`, `people.cover`.
        let source: String
    }

    static let chosenPhotoSidecarName = "chosen-photo.json"

    /// `People/<FSID>/` for a record with a safe FamilySearch ID (it need
    /// not exist yet), else nil.
    func familySearchIDFolder(for person: FamilyAssetPerson) -> URL? {
        guard access != .unavailable,
              let component = Self.safeFamilySearchIDComponent(person.familySearchID) else { return nil }
        let folder = peopleDirectory.appendingPathComponent(component, isDirectory: true)
            .standardizedFileURL
        guard folder.deletingLastPathComponent() == peopleDirectory else { return nil }
        return folder
    }

    /// Where this person's choice sidecar lives (read side).
    func chosenPhotoFolder(for person: FamilyAssetPerson) -> URL? {
        guard access != .unavailable else { return nil }
        return familySearchIDFolder(for: person) ?? resolvedPersonFolder(for: person)
    }

    /// The explicit choice, re-verified at read time: sidecar is a regular
    /// file, the named image is a verified regular image directly inside
    /// one People/ folder. Anything else is "no choice", never a guess.
    func chosenPhoto(for person: FamilyAssetPerson) -> (url: URL, choice: PersonPhotoChoice)? {
        guard let folder = chosenPhotoFolder(for: person), isSafeDirectory(folder) else { return nil }
        let sidecar = URL(fileURLWithPath: folder.appendingPathComponent(Self.chosenPhotoSidecarName).path,
                          isDirectory: false)
        guard let values = try? sidecar.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let data = try? Data(contentsOf: sidecar), data.count <= 8192,
              let choice = try? Self.sidecarDecoder.decode(PersonPhotoChoice.self, from: data),
              let url = photoURL(relativeToPeople: choice.file) else { return nil }
        return (url, choice)
    }

    /// Choose NEW image bytes (Pick a photo / Apple Photos / a People-tab
    /// cover copy): validated in memory, written never-overwrite into the
    /// person's FSID folder, then recorded as the choice.
    @discardableResult
    func choosePhoto(_ data: Data, fileExtension: String, for person: FamilyAssetPerson,
                     source: String, chosenAt: Date? = nil) throws -> URL {
        try requireWriteAccess()
        let folder = try writableChosenPhotoFolder(for: person)
        guard let target = revalidatedPhotoRequestFolder(folder) else {
            throw StoreError.unsafeDirectory(folder)
        }
        let ext = fileExtension.lowercased()
        guard Self.allowedImageExtensions.contains(ext) else {
            throw StoreError.sourceIsNotARegularImage(target.appendingPathComponent("portrait.\(ext)"))
        }
        guard data.count <= Self.maxImportBytes else {
            throw StoreError.imageTooLarge(bytes: data.count)
        }
        guard FamilyAssetImageValidator.isVerifiedImageData(data) else {
            throw StoreError.sourceIsNotARegularImage(target.appendingPathComponent("portrait.\(ext)"))
        }
        let when = chosenAt ?? importClock()
        let stamp: String = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyyMMdd-HHmmss"
            return f.string(from: when)
        }()
        let url = try writePersonPhotoData(data, stem: "portrait-" + stamp, ext: ext, into: target)
        try recordPhotoChoice(url, for: person, source: source, chosenAt: when)
        return url
    }

    /// Record an image ALREADY in a People/ folder (an Adjust crop) as the
    /// choice. The sidecar goes in the person's choice folder; the image
    /// stays where it is.
    func recordPhotoChoice(_ url: URL, for person: FamilyAssetPerson,
                           source: String, chosenAt: Date? = nil) throws {
        try requireWriteAccess()
        let folder = try writableChosenPhotoFolder(for: person)
        let file = URL(fileURLWithPath: url.path, isDirectory: false).standardizedFileURL
        let parent = file.deletingLastPathComponent()
        guard parent.deletingLastPathComponent() == peopleDirectory,
              isSafeDirectory(parent),
              FamilyAssetImageValidator.revalidatedURL(file) != nil else {
            throw StoreError.sourceIsNotARegularImage(file)
        }
        let choice = PersonPhotoChoice(
            file: parent.lastPathComponent + "/" + file.lastPathComponent,
            chosenAt: chosenAt ?? importClock(),
            source: source)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let sidecar = folder.appendingPathComponent(Self.chosenPhotoSidecarName, isDirectory: false)
        do {
            try encoder.encode(choice).write(to: sidecar, options: .atomic)
        } catch {
            throw StoreError.createFailed(sidecar.lastPathComponent, errno: errno)
        }
        PersonPhotoLog.chose(person: person, source: source, chosenAt: choice.chosenAt)
    }

    /// Choice folder for writing: `People/<FSID>/` created on demand, else
    /// the ordinary photo-request folder.
    private func writableChosenPhotoFolder(for person: FamilyAssetPerson) throws -> URL {
        if let folder = familySearchIDFolder(for: person) {
            try ensureSafeDirectory(root)
            try ensureSafeDirectory(peopleDirectory)
            try ensureSafeDirectory(folder)
            return folder
        }
        return try folderForPhotoRequest(person: person)
    }

    /// `<folder>/<file>` under People/, both components plain, the file a
    /// verified image. Nil for anything else (a traversal, a link, a
    /// vanished file).
    private func photoURL(relativeToPeople relative: String) -> URL? {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") }) else { return nil }
        let folder = peopleDirectory.appendingPathComponent(parts[0], isDirectory: true).standardizedFileURL
        guard folder.deletingLastPathComponent() == peopleDirectory, isSafeDirectory(folder) else { return nil }
        let file = folder.appendingPathComponent(parts[1], isDirectory: false).standardizedFileURL
        guard file.deletingLastPathComponent() == folder else { return nil }
        return FamilyAssetImageValidator.revalidatedURL(file)
    }

    /// "G2CL-86B" → "G2CL-86B"; anything that is not a short
    /// alphanumeric-with-dashes token is not a folder name.
    static func safeFamilySearchIDComponent(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmed.isEmpty, trimmed.count <= 32,
              trimmed.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" }),
              trimmed.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        return trimmed
    }

    /// Write cropped JPEG bytes as `<stem>-card.jpg` beside `original` (or
    /// into the person's request folder when there is no original on disk
    /// yet). Same hardening as `importPersonPhoto`: bytes validated in
    /// memory first, descriptor-anchored write, never overwrites — a second
    /// adjust yields `-card-2.jpg`, and `cardPhotoURL` picks the newest.
    @discardableResult
    func saveCardPhoto(_ data: Data, for person: FamilyAssetPerson,
                       nextTo original: URL?) throws -> URL {
        try requireWriteAccess()
        let folder: URL
        if let original,
           let live = revalidatedPhotoRequestFolder(original.deletingLastPathComponent()) {
            folder = live
        } else {
            folder = try folderForPhotoRequest(person: person)
        }
        guard let target = revalidatedPhotoRequestFolder(folder) else {
            throw StoreError.unsafeDirectory(folder)
        }
        guard data.count <= Self.maxImportBytes else {
            throw StoreError.imageTooLarge(bytes: data.count)
        }
        guard FamilyAssetImageValidator.isVerifiedImageData(data) else {
            throw StoreError.sourceIsNotARegularImage(target.appendingPathComponent("card.jpg"))
        }
        let rawStem = original.map { $0.deletingPathExtension().lastPathComponent }
            ?? target.lastPathComponent
        let stem = Self.cardStem(rawStem) ?? rawStem
        return try writePersonPhotoData(data, stem: stem + "-card", ext: "jpg", into: target)
    }

    /// Descriptor-anchored, never-overwrite write of validated image bytes
    /// into a live People/ folder. Shared by Photos import and card save.
    private func writePersonPhotoData(_ data: Data, stem: String, ext: String,
                                      into target: URL) throws -> URL {
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
