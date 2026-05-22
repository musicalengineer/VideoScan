// ScanCheckpoint.swift
// Persists scan progress so an interrupted overnight scan can resume
// from where it left off. Checkpoints are saved after directory walk
// completes and deleted on successful scan completion.

import Foundation

struct ScanCheckpoint: Codable {
    let volumePath: String
    let startedAt: Date
    let discoveredPaths: [String]
    let totalDiscovered: Int
    var skipChecksums: Bool = false

    static let directory: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
        let dir = appSupport
            .appendingPathComponent("VideoScan", isDirectory: true)
            .appendingPathComponent("scan_checkpoints", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
}

enum ScanCheckpointStorage {

    private static func fileURL(for volumePath: String) -> URL {
        let safe = volumePath
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return ScanCheckpoint.directory.appendingPathComponent("\(safe).json")
    }

    static func save(_ checkpoint: ScanCheckpoint) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(checkpoint)
            try data.write(to: fileURL(for: checkpoint.volumePath), options: .atomic)
        } catch {
            NSLog("VideoScan: failed to save scan checkpoint: %@", String(describing: error))
        }
    }

    static func load(for volumePath: String) -> ScanCheckpoint? {
        let url = fileURL(for: volumePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(ScanCheckpoint.self, from: data)
        } catch {
            NSLog("VideoScan: failed to load scan checkpoint: %@", String(describing: error))
            return nil
        }
    }

    static func delete(for volumePath: String) {
        let url = fileURL(for: volumePath)
        try? FileManager.default.removeItem(at: url)
    }

    static func listAll() -> [ScanCheckpoint] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: ScanCheckpoint.directory,
            includingPropertiesForKeys: nil
        ) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return files.compactMap { url -> ScanCheckpoint? in
            guard url.pathExtension == "json" else { return nil }
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(ScanCheckpoint.self, from: data)
        }
    }

    static func exists(for volumePath: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: volumePath).path)
    }

    static func age(for volumePath: String) -> TimeInterval? {
        guard let cp = load(for: volumePath) else { return nil }
        return Date().timeIntervalSince(cp.startedAt)
    }
}
