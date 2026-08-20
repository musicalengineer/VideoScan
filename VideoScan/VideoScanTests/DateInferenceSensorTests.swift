import Testing
import Foundation
@testable import VideoScan

// MARK: - DateInferenceSensorTests (GH #166, 2026-08-20)
//
// Catalog-wide SENSOR for the content-evidence-vs-copy-stamp bug: on
// Clip 01.dv the OCR burn-in ("JUN 21 '97"), the transcript ("1997")
// and a scene caption ("1997") all agreed — and inferredRecordDate
// still said 2007, because the OCR parser only accepted 4-digit years
// and the copy-date mtime leaked through at 0.30.
//
// Two jobs:
//   1. REPORT — how many records still carry a STORED inferred date
//      ≥ 3 years away from what their own content evidence says
//      (146 of 320 content-evidenced records on 2026-08-20; the stored
//      values heal on the next dossier pass, so this count is a
//      surfaced number, not an assertion).
//   2. PIN — re-running pfInferRecordDate TODAY on each record's stored
//      signals must never produce a year that is absent from the
//      record's own content evidence. On the pre-fix code this fails
//      immediately (2007 ∉ {1997}). This is the production-scale
//      regression sensor.
//
// Same guarantees as RealDataSearchTests: NONDESTRUCTIVE (temp-copy +
// production decode path; load() only writes inside its own directory)
// and GRACEFUL SKIP via `.enabled(if:)` on machines without the real
// catalog.

private func realCatalogURL() -> URL {
    let appSupport = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
    ).first ?? URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support")
    return appSupport
        .appendingPathComponent("VideoScan", isDirectory: true)
        .appendingPathComponent("catalog.json")
}

private func realCatalogExists() -> Bool {
    FileManager.default.fileExists(atPath: realCatalogURL().path)
}

@MainActor
@Suite("DateInferenceSensor — GH #166", .enabled(if: realCatalogExists()))
struct DateInferenceSensorTests {

    @MainActor private static var cachedRecords: [VideoRecord]?

    private static func loadRealCatalogCopy() throws -> [VideoRecord] {
        if let r = cachedRecords { return r }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("DateInferenceSensorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.copyItem(at: realCatalogURL(),
                                         to: tmp.appendingPathComponent("catalog.json"))
        let records = CatalogStore(directory: tmp).load()
        cachedRecords = records
        return records
    }

    /// All years the record's CONTENT evidence names: parsed OCR years,
    /// or (no OCR) the unanimous transcript/caption mention year.
    private func contentYears(of rec: VideoRecord) -> Set<Int> {
        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = TimeZone(identifier: "UTC") ?? .current
        let ocrYears = rec.ocrDateCandidates.map(\.text)
            .compactMap(pfParseOcrDate(_:))
            .map { utcCal.component(.year, from: $0) }
        if !ocrYears.isEmpty { return Set(ocrYears) }
        if let y = pfContentEvidenceYear(ocrDateCandidates: [],
                                         audioTranscript: rec.audioTranscript,
                                         sceneCaptionTexts: rec.sceneCaptions.map(\.text)) {
            return [y]
        }
        return []
    }

    @Test("SENSOR report: count of records whose STORED inferred year is ≥ 3 years from their content-evidence year")
    func reportStaleStoredInferences() throws {
        let records = try Self.loadRealCatalogCopy()
        try #require(!records.isEmpty)
        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = TimeZone(identifier: "UTC") ?? .current
        var withEvidence = 0, stale = 0
        for rec in records {
            guard let cy = pfContentEvidenceYear(ocrDateCandidates: rec.ocrDateCandidates.map(\.text),
                                                 audioTranscript: rec.audioTranscript,
                                                 sceneCaptionTexts: rec.sceneCaptions.map(\.text))
            else { continue }
            withEvidence += 1
            guard let stored = rec.inferredRecordDate else { continue }
            let iy = utcCal.component(.year, from: stored)
            if abs(cy - iy) >= 3 { stale += 1 }
        }
        // Surfaced, not asserted: stored values heal on the next dossier
        // pass. 2026-08-20 baseline: 320 with evidence, 146 stale.
        print("GH#166 SENSOR: \(records.count) records, \(withEvidence) with content-evidence year, \(stale) stored inferred dates ≥3y off")
        #expect(withEvidence > 0, "the real catalog has dossiered records; zero means the extraction broke")
    }

    @Test("SENSOR pin: re-running today's triangulation never lands outside a record's own content evidence")
    func rerunNeverContradictsContentEvidence() throws {
        let records = try Self.loadRealCatalogCopy()
        try #require(!records.isEmpty)
        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = TimeZone(identifier: "UTC") ?? .current
        var violations: [String] = []
        for rec in records {
            let years = contentYears(of: rec)
            guard !years.isEmpty else { continue }
            let rerun = pfInferRecordDate(
                ocrDateCandidates: rec.ocrDateCandidates.map(\.text),
                audioTranscript: rec.audioTranscript,
                sceneCaptionTexts: rec.sceneCaptions.map(\.text),
                pathYearHints: pfPathYearHints(in: rec.fullPath),
                fileMtime: rec.dateModifiedRaw,
                containerCreationTime: rec.dateCreatedRaw)
            guard let d = rerun.date else { continue }
            let y = utcCal.component(.year, from: d)
            if !years.contains(y) {
                violations.append("\(rec.fullPath): inferred \(y), content says \(years.sorted())")
            }
        }
        #expect(violations.isEmpty,
                "content evidence must always outvote stamps/mtime:\n\(violations.prefix(10).joined(separator: "\n"))")
    }

    @Test("Clip 01.dv (the GH #166 case) re-infers to 1997, not the 2007 copy date")
    func clip01ReInfersTo1997() throws {
        let records = try Self.loadRealCatalogCopy()
        let clip01 = records.first {
            $0.fullPath == "/Volumes/LaCieWorkspace/from-Mini2TB/Videos from Cheesegrater/Clip 01.dv"
        }
        guard let rec = clip01 else { return }   // file may leave the catalog; sensor above still guards the class
        let rerun = pfInferRecordDate(
            ocrDateCandidates: rec.ocrDateCandidates.map(\.text),
            audioTranscript: rec.audioTranscript,
            sceneCaptionTexts: rec.sceneCaptions.map(\.text),
            pathYearHints: pfPathYearHints(in: rec.fullPath),
            fileMtime: rec.dateModifiedRaw,
            containerCreationTime: rec.dateCreatedRaw)
        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = TimeZone(identifier: "UTC") ?? .current
        #expect(rerun.date.map { utcCal.component(.year, from: $0) } == 1997)
        #expect(rerun.confidence >= 0.85, "OCR + transcript + caption agreement must clear the stamp-outvote tier")
    }
}
