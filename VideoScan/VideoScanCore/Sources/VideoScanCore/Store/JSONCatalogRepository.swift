// JSONCatalogRepository.swift (VideoScanCore/Store)
// The EXISTING catalog.json seen through the CatalogRepository seam —
// read-only. It is the import source for step D′ and the frozen backup
// after cutover (§10a F′); nothing writes it through this type, ever. The
// app's CatalogStore keeps writing it until the cutover; this file does
// not touch that code.
//
// What it answers: the file's generation (the cheap head/tail header probe,
// same rule as CatalogSnapshot.headerProbe — see JSONCatalogHeader below),
// the `catalog.generation.max` sidecar as its high-water, and a read whose
// handle carries that generation. Part 2 adds record reads for the
// importer.
//
// For Rick: this is the "null object" implementation of the interface —
// every mutating call returns a named refusal instead of doing work.

import Foundation

public actor JSONCatalogRepository: CatalogRepository {

    public static let readOnlyReason = "JSON store is the import source"

    /// The JSON store's own high-water sidecar (GH #165), beside catalog.json.
    static let sidecarFileName = "catalog.generation.max"

    private var catalogURL: URL?
    private var loadedGeneration = 0

    public init() {}

    public var generation: Int { loadedGeneration }

    public func open(at url: URL) async -> CatalogOpenOutcome {
        guard catalogURL == nil else {
            return .refused(reason: "already open at \(catalogURL?.path ?? "?")")
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .refused(reason: "no catalog at \(url.path)")
        }
        guard let header = JSONCatalogHeader.probe(at: url) else {
            return .refused(reason: "\(url.lastPathComponent) carries no version/generation header")
        }
        catalogURL = url
        loadedGeneration = header.generation
        return .readOnly(reason: Self.readOnlyReason)
    }

    public func write(as door: CatalogWriter,
                      _ body: @Sendable (any CatalogTransaction) throws -> Void) async -> CatalogWriteOutcome {
        .refused(reason: "\(Self.readOnlyReason); it is never written through the repository")
    }

    public func read<T: Sendable>(_ body: @Sendable (any CatalogReader) throws -> T) async throws -> T {
        guard catalogURL != nil else { throw CatalogRepositoryError.notOpen }
        return try body(JSONReader(generation: loadedGeneration))
    }

    public func verify() async -> CatalogVerifyOutcome {
        guard let catalogURL else { return .problems(["not open"]) }
        guard let header = JSONCatalogHeader.probe(at: catalogURL) else {
            return .problems(["\(catalogURL.lastPathComponent) no longer carries a header"])
        }
        let sidecar = catalogURL.deletingLastPathComponent().appendingPathComponent(Self.sidecarFileName)
        let recorded = (try? String(contentsOf: sidecar, encoding: .utf8))
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? header.generation
        return .ok(generation: header.generation, highWater: max(recorded, header.generation))
    }

    public func adopt(toHighWater highWater: Int) async -> CatalogAdoptOutcome {
        .refused(reason: "\(Self.readOnlyReason); a JSON catalog is adopted by importing it")
    }

    public func close() async {
        catalogURL = nil
    }
}

struct JSONReader: CatalogReader {
    let generation: Int
}

// MARK: - Header probe

/// `version` + `generation` from catalog.json WITHOUT decoding the records:
/// the first 4 KB, then the last 4 KB (JSONEncoder's key order is
/// per-process random, so an old file may carry the header after 36 MB
/// of records — GH #165). Same rule as the app's
/// `CatalogSnapshot.headerProbe`; kept here because this package cannot
/// see the app target. When the JSON store moves behind this seam for
/// good, the app's copy goes and this is the one.
enum JSONCatalogHeader {

    static let probeWindowBytes = 4096

    static func probe(at url: URL) -> (version: Int, generation: Int)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: probeWindowBytes) else { return nil }
        // Lossy decode on purpose: a cut mid-UTF-8 would nil the whole window.
        let headText = String(decoding: head, as: UTF8.self)
        var version = intValue(forKey: "version", in: headText, last: false)
        var generation = intValue(forKey: "generation", in: headText, last: false)
        if version == nil || generation == nil, let tailText = tail(of: handle, after: head.count) {
            if version == nil { version = intValue(forKey: "version", in: tailText, last: true) }
            if generation == nil { generation = intValue(forKey: "generation", in: tailText, last: true) }
        }
        guard version != nil || generation != nil else { return nil }
        return (version ?? 0, generation ?? 0)
    }

    private static func tail(of handle: FileHandle, after headCount: Int) -> String? {
        guard let size = try? handle.seekToEnd(), size > UInt64(headCount) else { return nil }
        let start = size > UInt64(probeWindowBytes) ? size - UInt64(probeWindowBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let tail = try? handle.readToEnd() else { return nil }
        return String(decoding: tail, as: UTF8.self)
    }

    /// `"key" : 123`, whitespace optional. `last` picks the final
    /// occurrence (the tail's top-level keys come after the records).
    private static func intValue(forKey key: String, in text: String, last: Bool) -> Int? {
        let needle = "\"\(key)\""
        guard let found = last ? text.range(of: needle, options: .backwards) : text.range(of: needle) else {
            return nil
        }
        let blank: (Character) -> Bool = { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }
        var rest = text[found.upperBound...].drop(while: blank)
        guard rest.first == ":" else { return nil }
        rest = rest.dropFirst().drop(while: blank)
        return Int(rest.prefix(while: { $0.isNumber }))
    }
}
