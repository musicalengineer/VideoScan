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
// handle carries that generation. Part 2b: the record readings are named
// refusals here (`CatalogRepositoryError.unsupported`) — this store has no
// tables; the importer decodes the file itself.
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

/// The JSON store's read handle. It answers the generation; every record
/// reading throws `CatalogRepositoryError.unsupported` — the JSON file is
/// the import SOURCE, it has no tables and nothing was ever imported into
/// it, so "what landed" has no truthful answer here.
struct JSONReader: CatalogReader {
    let generation: Int

    private var unsupported: CatalogRepositoryError {
        .unsupported("\(JSONCatalogRepository.readOnlyReason); it has no record tables to read")
    }

    func recordCounts() throws -> CatalogRow.TableCounts { throw unsupported }
    func rowLandings(run: String, _ visit: (CatalogRow.RowLanding) throws -> Void) throws { throw unsupported }
    func quarantineRawRows(run: String, _ visit: (Int, [String: CatalogJSONValue]) throws -> Void) throws { throw unsupported }
    func quarantineEntries(run: String, _ visit: (CatalogRow.QuarantineReading) throws -> Void) throws { throw unsupported }
    func contentDigests(_ visit: (String) throws -> Void) throws { throw unsupported }
    func knowledgeSources(run: String, _ visit: (CatalogRow.KnowledgeReading) throws -> Void) throws { throw unsupported }
    func derivedUnverifiedKeys(run: String, _ visit: (CatalogRow.DerivedKeyReading) throws -> Void) throws { throw unsupported }
    func soundPrintDigests(_ visit: (String) throws -> Void) throws { throw unsupported }
    func events(run: String, _ visit: (CatalogRow.Event) throws -> Void) throws { throw unsupported }
    func eventDecisions(run: String, _ visit: (CatalogRow.EventDecision) throws -> Void) throws { throw unsupported }
    func eventMembers(_ visit: (CatalogRow.EventMemberReading) throws -> Void) throws { throw unsupported }
    func listedMemberKeys(run: String, _ visit: (String) throws -> Void) throws { throw unsupported }
    func ledgerLines(run: String, _ visit: (CatalogRow.Ledger) throws -> Void) throws { throw unsupported }
    func ignoredEntries(run: String, _ visit: (CatalogRow.Ignored) throws -> Void) throws { throw unsupported }
    func jobMarkers(run: String, _ visit: (CatalogRow.MarkerReading) throws -> Void) throws { throw unsupported }
    func auditResults(run: String, _ visit: (CatalogRow.AuditResult) throws -> Void) throws { throw unsupported }
    func personSearchOrdinals(run: String, _ visit: (Int) throws -> Void) throws { throw unsupported }
    func importReconciliation(run: String) throws -> ImportReconciliation { throw unsupported }
    func loadedRows(_ visit: (CatalogLoadedRow) throws -> Void) throws { throw unsupported }
    func loadCounts() throws -> CatalogLoadCounts { throw unsupported }
    func finishedImports() throws -> Int { throw unsupported }
    func displayTablesEmpty() throws -> Bool { throw unsupported }
    func displaySources(_ visit: (DisplayValueDerivation.Source) throws -> Void) throws { throw unsupported }
    func storedRow(id: String) throws -> CatalogLoadedRow? { throw unsupported }
    func volumeCaseSensitive(_ volumeUUID: String) throws -> Bool { throw unsupported }
    func masterArchiveJSON() throws -> String? { throw unsupported }
    func lastFinishedImport() throws -> CatalogRow.FinishedImport? { throw unsupported }
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
        // Lossy decode on purpose: a 4 KB cut can split a multibyte sequence
        // and the failable initializer would nil the WHOLE window; the keys
        // searched for are ASCII and survive the replacement character.
        // swiftlint:disable:next optional_data_string_conversion
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
        // Lossy on purpose, same reason as the head window.
        // swiftlint:disable:next optional_data_string_conversion
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
