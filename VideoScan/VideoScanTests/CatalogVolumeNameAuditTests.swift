import Testing
import Foundation
@testable import VideoScan

/// Audit test that reads the real catalog and verifies every record has a
/// stored volume name from ScanContext. Records scanned before the
/// volumeName field was added will have an empty value — this test flags
/// them so Rick knows which volumes need a rescan.
///
/// The test is expected to fail until all volumes have been rescanned at
/// least once with the new code. Each rescan backfills the volume name
/// automatically.
@Suite("Catalog Volume Name Audit")
struct CatalogVolumeNameAuditTests {

    private static let catalogURL: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
        return appSupport
            .appendingPathComponent("VideoScan", isDirectory: true)
            .appendingPathComponent("catalog.json")
    }()

    private func loadRecords() throws -> [VideoRecord] {
        let data = try Data(contentsOf: Self.catalogURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CatalogSnapshot.self, from: data).records
    }

    private func pathVolume(_ path: String) -> String {
        let parts = (path as NSString).pathComponents
        if parts.count >= 3, parts[1] == "Volumes" { return parts[2] }
        if parts.count >= 3, parts[1] == "Users" { return "Users/\(parts[2])" }
        if parts.count >= 2 { return parts[1] }
        return "(root)"
    }

    @Test(.disabled("Enable after rescanning all volumes"))
    func allRecordsHaveStoredVolumeName() throws {
        let records = try loadRecords()
        #expect(!records.isEmpty, "Catalog is empty — nothing to audit")

        var missingByVolume: [String: Int] = [:]
        for rec in records where rec.scanContext.volumeName.isEmpty {
            let vol = pathVolume(rec.fullPath)
            missingByVolume[vol, default: 0] += 1
        }

        if !missingByVolume.isEmpty {
            let sorted = missingByVolume.sorted { $0.value > $1.value }
            var msg = "Records missing volume name (\(sorted.map(\.value).reduce(0,+)) total):\n"
            for (vol, count) in sorted {
                msg += "  \(String(format: "%5d", count))  \(vol)\n"
            }
            Issue.record(Comment(rawValue: msg))
        }
    }

    @Test func noRecordHasFilenameAsVolumeName() throws {
        guard FileManager.default.fileExists(atPath: Self.catalogURL.path) else { return }
        let records = try loadRecords()

        var suspicious: [(filename: String, volumeName: String, path: String)] = []
        for rec in records {
            let displayed = rec.volumeName
            if displayed == rec.filename && !rec.filename.isEmpty {
                suspicious.append((rec.filename, displayed, rec.fullPath))
            }
        }

        if !suspicious.isEmpty {
            var msg = "\(suspicious.count) record(s) show filename as volume name:\n"
            for s in suspicious.prefix(10) {
                msg += "  \(s.filename) — \(s.path)\n"
            }
            if suspicious.count > 10 { msg += "  ... and \(suspicious.count - 10) more\n" }
            Issue.record(Comment(rawValue: msg))
        }
        #expect(suspicious.isEmpty, "Some records still show filename as volume name (see details above)")
    }

    @Test func volumeNameIsNeverEmpty() throws {
        guard FileManager.default.fileExists(atPath: Self.catalogURL.path) else { return }
        let records = try loadRecords()

        var emptyCount = 0
        for rec in records {
            if rec.volumeName.isEmpty { emptyCount += 1 }
        }
        #expect(emptyCount == 0, "\(emptyCount) record(s) have completely empty volume names")
    }

    @Test func recentlyScannedRecordsHaveStoredName() throws {
        guard FileManager.default.fileExists(atPath: Self.catalogURL.path) else { return }
        let records = try loadRecords()
        let cutoff = Calendar.current.date(byAdding: .day, value: -1, to: Date())!

        var recentMissing: [String] = []
        for rec in records {
            guard let scanned = rec.scanContext.scannedAt, scanned > cutoff else { continue }
            if rec.scanContext.volumeName.isEmpty {
                recentMissing.append(rec.fullPath)
            }
        }

        if !recentMissing.isEmpty {
            var msg = "\(recentMissing.count) recently-scanned record(s) missing volume name:\n"
            for p in recentMissing.prefix(5) { msg += "  \(p)\n" }
            Issue.record(Comment(rawValue: msg))
        }
        #expect(recentMissing.isEmpty, "Records scanned in the last 24h should have volume names")
    }
}
