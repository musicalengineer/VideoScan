import Foundation
import Testing
@testable import VideoScan

// MARK: - Catalog scope × exports (QA BLOCKER 1, 2026-07-15)
//
// Set-aside contract: "stays in the catalog, just hidden." Backups and
// exports are CATALOG carriers, not view carriers — they must include
// set-aside records WITH their setAsideReason so a bundle restore or a
// catalog re-import round-trips them. Purged records remain LOCAL-ONLY
// (the deliberate "local trash never travels" policy) — that negative is
// pinned here too.
//
// RED phase: the round-trip tests below FAIL against the unfixed code
// (exportCatalog / BundleExporter.writeBundle filtered through
// pfActiveRecords, which silently drops set-aside records). GREEN once
// exports route through the export-specific predicate that keeps
// set-aside and excludes only purged.
//
// The bundle assertions drive the exporter's filter + codec pipeline
// directly rather than the full writeBundle — same precedent as
// CatalogPurgeTests.bundleExport_stripsPurgedRecords: writeBundle pulls
// from the REAL POIStorage tree on the dev machine (isolation rule).

@MainActor
private func exportRec(
    _ filename: String,
    stream: StreamType = .videoAndAudio,
    dir: String = "/Volumes/T/media",
    md5: String,
    setAside: String? = nil,
    purged: Bool = false
) -> VideoRecord {
    let r = VideoRecord()
    r.filename = filename
    r.ext = (filename as NSString).pathExtension.uppercased()
    r.streamTypeRaw = stream.rawValue
    r.directory = dir
    r.fullPath = dir + "/" + filename
    r.sizeBytes = 1_000_000
    r.partialMD5 = md5
    r.setAsideReason = setAside
    if purged { r.purgedAt = Date(timeIntervalSince1970: 1_000_000) }
    return r
}

@MainActor
@Suite("Catalog scope — exports carry set-aside records")
struct CatalogScopeExportTests {

    @Test("catalog export → import round-trips a set-aside record with its reason; purged stays local")
    func exportImportRoundTripPreservesSetAside() throws {
        let source = VideoScanModel()
        source.records = [
            exportRec("family_1987.mov", md5: "aaaa1111"),
            exportRec("donna_song.mp3", stream: .audioOnly, md5: "bbbb2222",
                      setAside: "music-format"),
            exportRec("trash.mov", md5: "cccc3333", purged: true),
        ]

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vs_scope_export_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try source.exportCatalog(to: url)

        let dest = VideoScanModel()
        let result = try dest.importCatalog(from: url)
        #expect(result.added == 2, "export must carry active + set-aside, never purged")

        let imported = dest.records.first { $0.filename == "donna_song.mp3" }
        #expect(imported != nil,
                "set-aside record was silently dropped by the export (RED pre-fix)")
        #expect(imported?.setAsideReason == "music-format",
                "the set-aside REASON must round-trip, not just the record")
        #expect(dest.records.first { $0.filename == "trash.mov" } == nil,
                "purged records are local-only and must never travel")
    }

    @Test("bundle filter+codec pipeline: set-aside record survives with its reason")
    func bundlePipelineCarriesSetAside() throws {
        // Drives writeBundle's exact pipeline: pfExportableRecords → DTO
        // encode → decode (CatalogPurgeTests #18 precedent — full
        // writeBundle reads the real POIStorage tree).
        let active = exportRec("family_1987.mov", md5: "aaaa1111")
        let setAside = exportRec("donna_song.mp3", stream: .audioOnly,
                                 md5: "bbbb2222", setAside: "music-format")
        let purged = exportRec("trash.mov", md5: "cccc3333", purged: true)

        let toEncode = pfExportableRecords([active, setAside, purged])
        #expect(Set(toEncode.map(\.id)) == [active.id, setAside.id],
                "bundle must carry active + set-aside; purged only stays local")

        let snapshot = CatalogSnapshot(
            version: CatalogSnapshot.currentVersion,
            savedAt: Date(), records: toEncode, savedFromHost: "TestHost")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try CatalogSnapshotDTO(snapshot).encoded(using: encoder)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = try decoder.decode(CatalogSnapshot.self, from: data)

        let loadedSetAside = loaded.records.first { $0.id == setAside.id }
        #expect(loadedSetAside?.setAsideReason == "music-format",
                "setAsideReason must survive the bundle codec round-trip")
        #expect(loaded.records.first { $0.id == purged.id } == nil,
                "negative pin: purged records never cross the bundle boundary")
    }

    @Test("pfExportableRecords vs pfActiveRecords: the two predicates differ exactly on set-aside")
    func predicatesDifferOnlyOnSetAside() {
        let active = exportRec("a.mov", md5: "01")
        let setAside = exportRec("b.mp3", stream: .audioOnly, md5: "02",
                                 setAside: "music-format")
        let purged = exportRec("c.mov", md5: "03", purged: true)
        let all = [active, setAside, purged]
        #expect(pfActiveRecords(all).map(\.filename) == ["a.mov"])
        #expect(pfExportableRecords(all).map(\.filename) == ["a.mov", "b.mp3"])
    }
}
