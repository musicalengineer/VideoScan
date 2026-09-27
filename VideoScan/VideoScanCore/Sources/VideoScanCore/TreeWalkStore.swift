// TreeWalkStore.swift (VideoScanCore)
// The decorations sidecar: `~/Library/Application Support/VideoScan/
// family-tree/decorations.json` —
//   { walkerVersion, sourceKey, generatedAt, starts, maxGenerations,
//     people: { "@I1@": decoration, … }, checks: [ … ], summary (coverage) }
//
// STALE when the walker version or the source key differs from the tree now
// loaded (the key hashes every fact the walker reads — see
// TreeWalkSnapshot.sourceKey — so a FamilySearch refresh, a merge or an
// identity ruling makes the old file stale). Stale or unreadable = absent:
// the caller walks again. The file is a CACHE of a pure function of the
// tree; losing it costs one walk, never data.
//
// Written atomically (temp file + rename), sorted keys so two runs over the
// same tree give identical bytes apart from `generatedAt`.
//
// Size: ~120 bytes per person with the short keys (39k → ~5 MB).

import Foundation

public struct TreeWalkStored: Sendable, Codable, Equatable {
    public let walkerVersion: Int
    public let sourceKey: String
    public let generatedAt: Date
    public let starts: [TreeWalk.Start]
    public let maxGenerations: Int?
    public let people: [String: TreeWalk.Decoration]
    public let checks: [TreeWalk.Check]
    public let summary: TreeWalk.Summary

    public init(_ r: TreeWalk.Result) {
        walkerVersion = r.walkerVersion
        sourceKey = r.sourceKey
        generatedAt = r.generatedAt
        starts = r.starts
        maxGenerations = r.maxGenerations
        var people: [String: TreeWalk.Decoration] = [:]
        people.reserveCapacity(r.ids.count)
        for (o, id) in r.ids.enumerated() where r.visible[o] { people[id] = r.decorations[o] }
        self.people = people
        checks = r.checks
        summary = r.summary
    }

    /// Checks about one person (indexes stored on the decoration).
    public func checks(for id: String) -> [TreeWalk.Check] {
        (people[id]?.checks ?? []).compactMap { checks.indices.contains($0) ? checks[$0] : nil }
    }
}

public enum TreeWalkStore {
    public static let fileName = "decorations.json"

    /// `<Application Support>/VideoScan/family-tree/decorations.json`.
    public static func defaultURL(fileManager: FileManager = .default) -> URL? {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("VideoScan", isDirectory: true)
            .appendingPathComponent("family-tree", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    /// The key a loaded graph must match (see the header).
    public static func sourceKey(of graph: GedcomFamilyGraph) -> String {
        TreeWalkSnapshot.sourceKey(graph: graph)
    }

    public static func encode(_ stored: TreeWalkStored) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(stored)
    }

    /// Atomic replace; creates the directory.
    public static func save(_ result: TreeWalk.Result, to url: URL) throws {
        let data = try encode(TreeWalkStored(result))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    public enum LoadOutcome: Sendable, Equatable {
        case current(TreeWalkStored)
        case absent
        case unreadable(String)
        case stale(reason: String)
    }

    /// Load and judge. Never throws: a damaged file is `.unreadable` and
    /// the caller walks again.
    public static func load(from url: URL, expectedSourceKey: String?) -> LoadOutcome {
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { return .unreadable(error.localizedDescription) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Version FIRST: a file from an older walker may not decode as
        // today's shape (v1 summaries lack the v2 fields) — that is stale,
        // not damaged.
        struct VersionProbe: Decodable { let walkerVersion: Int }
        if let probe = try? decoder.decode(VersionProbe.self, from: data), probe.walkerVersion != TreeWalk.walkerVersion {
            return .stale(reason: "made by walker v\(probe.walkerVersion); this build is v\(TreeWalk.walkerVersion)")
        }
        let stored: TreeWalkStored
        do { stored = try decoder.decode(TreeWalkStored.self, from: data) } catch {
            return .unreadable("decorations.json could not be read (\(String(describing: error).prefix(120)))")
        }
        if stored.walkerVersion != TreeWalk.walkerVersion {
            return .stale(reason: "made by walker v\(stored.walkerVersion); this build is v\(TreeWalk.walkerVersion)")
        }
        if let expectedSourceKey, stored.sourceKey != expectedSourceKey {
            return .stale(reason: "the tree has changed since the last walk")
        }
        return .current(stored)
    }
}
