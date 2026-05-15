import Testing
import Foundation
@testable import VideoScan

// Export-side safety net: catch POIs that ship without a usable
// profile.json BEFORE the bundle crosses machine boundaries. The
// motivating incident (2026-05-15 MS→M5) only surfaced the missing
// profile.json on the receiving side at import time, by which point
// recovery was a manual operation in Application Support. With this
// validator running at export time, the user sees the warning in the
// post-export alert and can re-export immediately.
//
// We test the pure helper (`BundleExporter.profileJSONValidationReason`)
// plus the `Summary.missingProfileJSONCount` derived field that drives
// the post-export alert banner. The full `writeBundle` path reads from
// real `POIStorage.allPOIFolders()` — exercising that here would
// pollute the dev machine's POI gallery, so we keep the test surface to
// the deterministic, side-effect-free contract.
struct BundleExportProfileValidatorTests {

    // MARK: - Sandbox

    /// Build a fake destination POI dir under a temp parent, populated
    /// per the `populate` closure. The caller decides whether
    /// profile.json is present / valid / corrupt.
    private func makeFakeDestPOI(populate: (URL) throws -> Void) throws -> URL {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-validator-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dest,
                                                withIntermediateDirectories: true)
        try populate(dest)
        return dest
    }

    // MARK: - profileJSONValidationReason

    @Test func export_warns_when_profile_json_missing() throws {
        // POI folder with photos but NO profile.json — exactly the bug
        // that bit Rick on May 15. The validator must flag this.
        let dest = try makeFakeDestPOI { dir in
            // Drop one photo stub. profile.json deliberately omitted.
            try Data([0xFF, 0xD8, 0xFF, 0xE0])
                .write(to: dir.appendingPathComponent("photo_0.jpg"))
        }
        defer { try? FileManager.default.removeItem(at: dest) }

        let reason = BundleExporter.profileJSONValidationReason(dest: dest)
        #expect(reason != nil,
                "Missing profile.json must produce a warning")
        #expect(reason?.contains(BundleExporter.Summary.missingProfileJSONReason) == true,
                "Reason must include the canonical missing-profile.json marker")
    }

    @Test func export_succeeds_when_all_profile_jsons_present() throws {
        // Healthy case: profile.json exists, is non-empty, decodes
        // cleanly. Validator should return nil.
        let dest = try makeFakeDestPOI { dir in
            let profile = POIProfile(name: "Donna",
                                     referencePath: dir.path)
            let data = try JSONEncoder().encode(profile)
            try data.write(to: dir.appendingPathComponent("profile.json"))
            try Data([0xFF, 0xD8, 0xFF, 0xE0])
                .write(to: dir.appendingPathComponent("photo_0.jpg"))
        }
        defer { try? FileManager.default.removeItem(at: dest) }

        #expect(BundleExporter.profileJSONValidationReason(dest: dest) == nil,
                "Valid POI dir should produce no warning")
    }

    @Test func export_warns_when_profile_json_is_empty() throws {
        // Touched-but-empty file. iCloud eviction stubs and interrupted
        // writes both produce 0-byte profile.json files; the validator
        // must catch this even though `fileExists` returns true.
        let dest = try makeFakeDestPOI { dir in
            try Data().write(to: dir.appendingPathComponent("profile.json"))
        }
        defer { try? FileManager.default.removeItem(at: dest) }

        let reason = BundleExporter.profileJSONValidationReason(dest: dest)
        #expect(reason != nil)
        #expect(reason?.contains(BundleExporter.Summary.missingProfileJSONReason) == true)
    }

    @Test func export_warns_when_profile_json_does_not_decode() throws {
        // Non-JSON garbage where profile.json should be. Catches the
        // "wrong file type slipped in" failure mode.
        let dest = try makeFakeDestPOI { dir in
            try Data("not a profile at all".utf8)
                .write(to: dir.appendingPathComponent("profile.json"))
        }
        defer { try? FileManager.default.removeItem(at: dest) }

        let reason = BundleExporter.profileJSONValidationReason(dest: dest)
        #expect(reason != nil)
        #expect(reason?.contains(BundleExporter.Summary.missingProfileJSONReason) == true)
    }

    // MARK: - Summary.missingProfileJSONCount

    /// Build a Summary with the supplied warnings — Summary's other fields
    /// are inert for this test.
    private func makeSummary(warnings: [(String, String)]) -> BundleExporter.Summary {
        BundleExporter.Summary(
            path: URL(fileURLWithPath: "/tmp/unused"),
            manifest: BundleManifest(
                bundleVersion: BundleManifest.currentVersion,
                exportedAt: Date(),
                exportedFromHost: "test",
                appVersion: "test",
                appBuild: "test",
                counts: .init(records: 0, volumes: 0, people: 0, referencePhotos: 0),
                sizes: .init(totalBytes: 0, referencePhotoBytes: 0)
            ),
            exportWarnings: warnings.map { (path: $0.0, reason: $0.1) }
        )
    }

    @Test func summary_counts_missing_profile_json_warnings() {
        let summary = makeSummary(warnings: [
            ("donna/profile.json",
             BundleExporter.Summary.missingProfileJSONReason),
            ("beth/profile.json",
             BundleExporter.Summary.missingProfileJSONReason + " (file empty)"),
            // Unrelated warning (dangling symlink) — must NOT count toward
            // the profile.json banner.
            ("timmy/old_photo.heic", "dangling symlink → /Volumes/MacStudio/…"),
        ])
        #expect(summary.missingProfileJSONCount == 2,
                "Should count entries containing the missing-profile marker (including the suffixed variants), exclude unrelated warnings")
    }

    @Test func summary_count_is_zero_for_clean_export() {
        let summary = makeSummary(warnings: [])
        #expect(summary.missingProfileJSONCount == 0)
    }

    @Test func summary_count_is_zero_when_only_symlink_warnings() {
        let summary = makeSummary(warnings: [
            ("donna/old_photo.heic", "dangling symlink → /Volumes/…"),
        ])
        #expect(summary.missingProfileJSONCount == 0,
                "Symlink warnings unrelated to profile.json must not trip the banner")
    }
}
