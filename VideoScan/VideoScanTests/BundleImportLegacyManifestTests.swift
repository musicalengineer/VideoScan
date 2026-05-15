import Testing
import Foundation
@testable import VideoScan

// Regression: bundles produced by the pre-manifest exporter (or by an
// interrupted export where the final manifest.json write never landed)
// must still be importable. The new importer used to throw
// BundleError.manifestMissing on any bundle without manifest.json; it
// now synthesizes a placeholder manifest so the rest of the import
// flow can proceed.
//
// Triggering case: 2026-05-15 MS→M5 import; bundle on iCloud was
// missing manifest.json and the importer rejected it outright.
struct BundleImportLegacyManifestTests {

    /// Construct a temp bundle dir with valid catalog/volumes/settings
    /// JSON but no manifest.json. Mirrors the failure case Rick hit.
    private func makeLegacyBundle() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-bundle-\(UUID().uuidString).videoscanbundle",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: tmp,
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("people"),
                                                withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let catalog = CatalogSnapshot(version: CatalogSnapshot.currentVersion,
                                      savedAt: Date(),
                                      records: [],
                                      savedFromHost: "test-host")
        try encoder.encode(catalog)
            .write(to: tmp.appendingPathComponent("catalog.json"))

        let volumes = VolumesSnapshot(version: 1, savedAt: Date(), volumes: [])
        try encoder.encode(volumes)
            .write(to: tmp.appendingPathComponent("volumes.json"))

        var settings = SettingsSnapshot(from: PersonFinderSettings())
        settings.savedAt = Date()
        try encoder.encode(settings)
            .write(to: tmp.appendingPathComponent("settings.json"))

        // No manifest.json — that's the whole point of this test.
        return tmp
    }

    @Test func readToleratesMissingManifest() throws {
        let bundleURL = try makeLegacyBundle()
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let payload = try BundleImporter.read(from: bundleURL)

        #expect(payload.manifest.bundleVersion == 0,
                "Synthesized manifest should be marked legacy (version 0)")
        #expect(payload.manifest.exportedFromHost.contains("legacy"),
                "Synthesized manifest should self-identify as legacy")
        #expect(payload.manifest.counts.people == 0,
                "Empty people/ dir should produce a count of 0")
        #expect(payload.poiFoldersInBundle.isEmpty)
    }

    @Test func readStillRejectsCatalogMissing() throws {
        let bundleURL = try makeLegacyBundle()
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        // Remove catalog.json — the importer should still reject this:
        // legacy-tolerance is only for the manifest, not for required
        // payload files.
        try FileManager.default.removeItem(at: bundleURL.appendingPathComponent("catalog.json"))

        #expect(throws: (any Error).self) {
            _ = try BundleImporter.read(from: bundleURL)
        }
    }
}
