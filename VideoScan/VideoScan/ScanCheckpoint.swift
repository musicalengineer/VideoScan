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
    /// True when the walk that produced this checkpoint hit directory-
    /// enumeration errors (checkpoint honesty, QA 2026-07-02). A resumed
    /// scan never re-walks, so the ORIGINAL walk's incompleteness must ride
    /// along: resume marks its audit from this flag and finalize refuses
    /// to call the scan complete (upsert, never prune). Additive field —
    /// decoded with decodeIfPresent so pre-existing checkpoint JSON
    /// (no such key) still loads with the safe default `false`.
    var walkHadEnumerationErrors: Bool = false

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

extension ScanCheckpoint {
    /// Custom decode so ADDITIVE fields tolerate older checkpoint JSON:
    /// `skipChecksums` and `walkHadEnumerationErrors` decode via
    /// decodeIfPresent with their safe defaults. (Synthesized Codable would
    /// throw keyNotFound and a stale-but-valid resume checkpoint would be
    /// silently unloadable.) Lives in an extension so the synthesized
    /// memberwise initializer survives. Encoding stays synthesized — new
    /// checkpoints always carry every field.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        volumePath = try c.decode(String.self, forKey: .volumePath)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        discoveredPaths = try c.decode([String].self, forKey: .discoveredPaths)
        totalDiscovered = try c.decode(Int.self, forKey: .totalDiscovered)
        skipChecksums = try c.decodeIfPresent(Bool.self, forKey: .skipChecksums) ?? false
        walkHadEnumerationErrors = try c.decodeIfPresent(Bool.self, forKey: .walkHadEnumerationErrors) ?? false
    }
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
