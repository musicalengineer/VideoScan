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

import Foundation
import VideoScanCore

struct FamilyGroup: Codable, Identifiable, Equatable, Hashable, Sendable {
    var uuid: UUID
    var name: String
    var featuredVideos: [FeaturedVideo]
    var createdAt: Date

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
        featuredVideos = (try? c.decodeIfPresent([FeaturedVideo].self, forKey: .featuredVideos)) ?? []
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? Date(timeIntervalSince1970: 0)
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

    /// Moves the family's file to the Trash (recoverable) — never a hard
    /// delete. The videos themselves are untouched; only the grouping goes.
    static func moveToTrash(_ uuid: UUID) throws {
        try ViewerWriteGuard.check("FamilyGroupStore.moveToTrash")
        try FileManager.default.trashItem(at: url(for: uuid), resultingItemURL: nil)
    }
}
