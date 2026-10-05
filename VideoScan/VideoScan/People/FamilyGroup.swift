//
//  FamilyGroup.swift
//  VideoScan
//
//  FAMILY GROUPS in the People tab (Rick 2026-10-04): "the videos are often
//  associated with family groups … we don't want to group all the Breen
//  family videos under Donna, we want it under Rick & Donna Breen Family."
//  A family is a card in the People tab (group icon) whose page holds the
//  videos picked for that family, by decade.
//
//  DELIBERATELY NOT A POIProfile: person profiles feed face matching,
//  Hallie's people/alias joins, kinship and tree identity — a family must
//  never be mistaken for a person by any of them. Families live in their
//  own small JSON files beside the people: POI/Families/<UUID>.json.
//  Test hosts get the same temp redirect as POIStorage.
//

import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VideoScanCore

struct FamilyGroup: Codable, Identifiable, Equatable, Hashable, Sendable {
    var uuid: UUID
    var name: String
    var featuredVideos: [FeaturedVideo]
    var createdAt: Date
    /// The card's photo, a file beside the family's JSON (nil = group icon).
    /// Only ever `<UUID>-photo.jpg` — see FamilyGroupStore.photoURL.
    var photoFilename: String?
    /// Pick rows this build could not read, kept verbatim (codex 2026-10-04).
    var featuredVideosQuarantined: [JSONValue] = []
    /// Card-photo crop (2026-10-05), the same three numbers a person's cover
    /// uses (CoverCropEditor / CroppedCircleImage): zoom ≥ 1, pan in points.
    var cropScale: Double = 1.0
    var cropOffsetX: Double = 0
    var cropOffsetY: Double = 0

    /// The one photo filename a family may own.
    var expectedPhotoFilename: String { "\(uuid.uuidString)-photo.jpg" }

    var id: UUID { uuid }

    init(name: String, uuid: UUID = UUID(), featuredVideos: [FeaturedVideo] = [], createdAt: Date = Date()) {
        self.uuid = uuid
        self.name = name
        self.featuredVideos = featuredVideos
        self.createdAt = createdAt
    }

    /// Tolerant: an older or damaged file still loads (a bad pick list
    /// degrades to empty).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(UUID.self, forKey: .uuid)
        name = try c.decode(String.self, forKey: .name)
        let picks = FeaturedVideos.decodeRows(try? c.decodeIfPresent(JSONValue.self, forKey: .featuredVideos))
        featuredVideos = picks.readable
        featuredVideosQuarantined = ((try? c.decodeIfPresent([JSONValue].self, forKey: .featuredVideosQuarantined)) ?? [])
            + picks.quarantined
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? Date(timeIntervalSince1970: 0)
        photoFilename = try? c.decodeIfPresent(String.self, forKey: .photoFilename)
        cropScale = ((try? c.decodeIfPresent(Double.self, forKey: .cropScale)) ?? 1.0) ?? 1.0
        cropOffsetX = ((try? c.decodeIfPresent(Double.self, forKey: .cropOffsetX)) ?? 0) ?? 0
        cropOffsetY = ((try? c.decodeIfPresent(Double.self, forKey: .cropOffsetY)) ?? 0) ?? 0
    }
}

enum FamilyGroupStore {

    static let defaultName = "Rick & Donna Breen Family"

    static var directory: URL {
        let dir = POIStorage.storeDir.appendingPathComponent("Families", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func url(for uuid: UUID) -> URL {
        directory.appendingPathComponent("\(uuid.uuidString).json")
    }

    /// Every family, oldest first. A file that will not decode is skipped
    /// and logged — never deleted.
    static func listAll() -> [FamilyGroup] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        var out: [FamilyGroup] = []
        for name in names where name.hasSuffix(".json") {
            let file = directory.appendingPathComponent(name)
            do {
                out.append(try JSONDecoder().decode(FamilyGroup.self, from: Data(contentsOf: file)))
            } catch {
                appLog.write("People: skipped unreadable family file \(name) — \(error.localizedDescription)")
            }
        }
        return out.sorted { $0.createdAt < $1.createdAt }
    }

    static func load(_ uuid: UUID) -> FamilyGroup? {
        guard let data = try? Data(contentsOf: url(for: uuid)) else { return nil }
        return try? JSONDecoder().decode(FamilyGroup.self, from: data)
    }

    /// Atomic write of one family's file.
    static func save(_ group: FamilyGroup) throws {
        try ViewerWriteGuard.check("FamilyGroupStore.save")
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(group).write(to: url(for: group.uuid), options: .atomic)
    }

    /// Where a family's card photo lives — nil when it has none, or when
    /// the stored name is anything but the family's own `<UUID>-photo.jpg`
    /// (codex 2026-10-04 P1: a crafted `../<person>/profile.json` must never
    /// be shown, replaced or trashed as the family's photo), or when that
    /// path is a symlink.
    static func photoURL(for group: FamilyGroup) -> URL? {
        guard let name = group.photoFilename, name == group.expectedPhotoFilename else { return nil }
        let url = directory.appendingPathComponent(name)
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { return nil }
        return url
    }

    /// Copy `source` in as the family's card photo: decoded, downsized to
    /// 1024 px on the long side, written as JPEG beside the family's JSON
    /// (`<UUID>-photo.jpg`). The original file is never modified.
    static func setPhoto(from source: URL, for uuid: UUID) throws -> FamilyGroup {
        // Permission FIRST (codex 2026-10-04 P1): a refused change must not
        // have touched the old photo.
        try ViewerWriteGuard.check("FamilyGroupStore.setPhoto")
        guard var group = load(uuid) else { throw CocoaError(.fileNoSuchFile) }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: 1024]
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let name = group.expectedPhotoFilename
        let dest = directory.appendingPathComponent(name)
        // Encode in memory, publish with AtomicFilePublish — never the
        // FileManager replace-item API (RENAME_SWAP can wedge Sandbox.kext when
        // two saves race onto one file: the 2026-09-14 P0;
        // AtomicFilePublishSensorTests). No staging file to clean up.
        let jpeg = NSMutableData()
        guard let out = CGImageDestinationCreateWithData(jpeg as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(out, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        guard CGImageDestinationFinalize(out) else { throw CocoaError(.fileWriteUnknown) }
        // Commit the JSON first; the old photo stays until it succeeds. The
        // name never changes, so a publish that fails afterwards leaves the
        // family pointing at its previous photo — never at nothing.
        group.photoFilename = name
        group.cropScale = 1.0; group.cropOffsetX = 0; group.cropOffsetY = 0   // a new photo starts uncropped
        try save(group)
        if (try? dest.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
            throw CocoaError(.fileWriteNoPermission)   // never write through a planted link
        }
        try AtomicFilePublish.write(jpeg as Data, to: dest)
        return group
    }

    /// Moves the family's file to the Trash (recoverable) — never a hard
    /// delete. The videos themselves are untouched; only the grouping goes.
    static func moveToTrash(_ uuid: UUID) throws {
        try ViewerWriteGuard.check("FamilyGroupStore.moveToTrash")
        let photo = load(uuid).flatMap { photoURL(for: $0) }
        try FileManager.default.trashItem(at: url(for: uuid), resultingItemURL: nil)
        if let photo, FileManager.default.fileExists(atPath: photo.path) {
            try? FileManager.default.trashItem(at: photo, resultingItemURL: nil)
        }
    }
}
