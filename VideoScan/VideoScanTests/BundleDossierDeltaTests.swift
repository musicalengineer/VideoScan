import Testing
import Foundation
@testable import VideoScan

// MARK: - Bundle dossier-delta inclusion tests
//
// Rick 2026-06-07 audit established that the .videoscanbundle export
// is THE belt-and-suspenders backup channel (typically goes to iCloud).
// Before this change, the bundle shipped catalog.json with dossier
// fields embedded per-record but did NOT include the worker JSONL
// deltas. If catalog.json itself were ever corrupt at restore time, the
// only recovery channel was the JSONLs on Crucial2TB — single-disk
// failure mode.
//
// These tests pin the contract that:
//   1. copyDossierDeltas picks up every *.jsonl in the source dir
//   2. line and byte counts are accurate (drive the post-export alert)
//   3. a missing source dir (Crucial2TB unmounted) emits a warning and
//      returns zero counts — the export still succeeds
//   4. non-JSONL files in the source dir are correctly ignored
//   5. blank lines aren't counted as deltas
//   6. catalog-manifest.sha256 is copied when present, skipped when not
//
// We test the pure static helpers (countJSONLLines, copyDossierDeltas,
// copyCatalogManifestIfPresent) rather than the full writeBundle path
// because the latter pulls from real POIStorage / records / scanTargets
// state on the dev machine.

@Suite("Bundle dossier-delta inclusion")
struct BundleDossierDeltaTests {

    // MARK: - Sandbox helpers

    private func makeTempDir(label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeJSONL(at dir: URL, name: String, lines: [String]) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - countJSONLLines

    @Test func countJSONLLines_counts_non_blank_lines() throws {
        let dir = try makeTempDir(label: "count")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try writeJSONL(at: dir, name: "m4.jsonl", lines: [
            #"{"fullPath": "/a", "fields": {}}"#,
            #"{"fullPath": "/b", "fields": {}}"#,
            #"{"fullPath": "/c", "fields": {}}"#,
        ])
        #expect(BundleExporter.countJSONLLines(at: file) == 3)
    }

    @Test func countJSONLLines_ignores_blank_lines() throws {
        // Blank or whitespace-only lines must NOT count as deltas — the
        // post-export alert would lie if it claimed deltas that aren't
        // really there.
        let dir = try makeTempDir(label: "count-blank")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try writeJSONL(at: dir, name: "m4.jsonl", lines: [
            #"{"fullPath": "/a", "fields": {}}"#,
            "",
            "   ",
            #"{"fullPath": "/b", "fields": {}}"#,
            "",
        ])
        #expect(BundleExporter.countJSONLLines(at: file) == 2)
    }

    @Test func countJSONLLines_handles_empty_file() throws {
        let dir = try makeTempDir(label: "count-empty")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try writeJSONL(at: dir, name: "m4.jsonl", lines: [])
        #expect(BundleExporter.countJSONLLines(at: file) == 0)
    }

    @Test func countJSONLLines_handles_final_line_without_newline() throws {
        // JSONL emitted with no trailing newline is common — workers
        // that flush per-record append "<json>\n" so the last line ends
        // with \n, but a partial write at the end could omit it. We
        // count the final segment iff non-blank.
        let dir = try makeTempDir(label: "count-tail")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("m4.jsonl")
        let content = #"{"a":1}"# + "\n" + #"{"b":2}"#
        try content.write(to: file, atomically: true, encoding: .utf8)
        #expect(BundleExporter.countJSONLLines(at: file) == 2)
    }

    @Test func countJSONLLines_returns_nil_for_missing_file() {
        let bogus = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).jsonl")
        #expect(BundleExporter.countJSONLLines(at: bogus) == nil)
    }

    // MARK: - copyDossierDeltas — happy path

    @Test func copyDossierDeltas_copies_every_jsonl_and_records_counts() throws {
        let src = try makeTempDir(label: "delta-src")
        let bundle = try makeTempDir(label: "delta-bundle")
        defer {
            try? FileManager.default.removeItem(at: src)
            try? FileManager.default.removeItem(at: bundle)
        }

        _ = try writeJSONL(at: src, name: "m1.jsonl", lines: [
            #"{"fullPath": "/a", "fields": {}}"#,
        ])
        _ = try writeJSONL(at: src, name: "m4.jsonl", lines: [
            #"{"fullPath": "/b", "fields": {}}"#,
            #"{"fullPath": "/c", "fields": {}}"#,
            #"{"fullPath": "/d", "fields": {}}"#,
        ])
        _ = try writeJSONL(at: src, name: "m5.jsonl", lines: [
            #"{"fullPath": "/e", "fields": {}}"#,
            #"{"fullPath": "/f", "fields": {}}"#,
        ])

        var warnings: [(String, String)] = []
        let summary = BundleExporter.copyDossierDeltas(from: src, into: bundle, warnings: &warnings)

        #expect(summary.lineCount == 6,
                "All three JSONLs should contribute their line totals.")
        #expect(summary.byteCount > 0)
        #expect(warnings.isEmpty,
                "Happy path produces no warnings.")

        // Verify every JSONL landed in the bundle's deltas/ subdir.
        let fm = FileManager.default
        let deltasDir = bundle.appendingPathComponent("deltas")
        for name in ["m1.jsonl", "m4.jsonl", "m5.jsonl"] {
            #expect(fm.fileExists(atPath: deltasDir.appendingPathComponent(name).path),
                    "Expected deltas/\(name) inside the bundle.")
        }
    }

    @Test func copyDossierDeltas_only_copies_jsonl_files() throws {
        // The deltas dir might accumulate stray files (a worker logfile,
        // an editor swap file). We must only copy *.jsonl — anything
        // else is noise and could bloat the bundle.
        let src = try makeTempDir(label: "delta-mixed")
        let bundle = try makeTempDir(label: "delta-mixed-bundle")
        defer {
            try? FileManager.default.removeItem(at: src)
            try? FileManager.default.removeItem(at: bundle)
        }

        _ = try writeJSONL(at: src, name: "m4.jsonl", lines: [#"{"x":1}"#])
        try "not a jsonl".write(to: src.appendingPathComponent("README.txt"),
                                atomically: true, encoding: .utf8)
        try "junk".write(to: src.appendingPathComponent("worker.log"),
                         atomically: true, encoding: .utf8)
        try "{}".write(to: src.appendingPathComponent("offsets.json"),
                       atomically: true, encoding: .utf8)

        var warnings: [(String, String)] = []
        let summary = BundleExporter.copyDossierDeltas(from: src, into: bundle, warnings: &warnings)

        let fm = FileManager.default
        let deltasDir = bundle.appendingPathComponent("deltas")
        let kids = (try fm.contentsOfDirectory(at: deltasDir, includingPropertiesForKeys: nil))
            .map { $0.lastPathComponent }
            .sorted()
        #expect(kids == ["m4.jsonl"],
                "Only *.jsonl files should be bundled, got \(kids)")
        #expect(summary.lineCount == 1)
    }

    // MARK: - copyDossierDeltas — failure modes

    @Test func copyDossierDeltas_missing_source_dir_warns_but_does_not_throw() throws {
        // Crucial2TB unmounted while exporting from MBP — the export
        // must still succeed (catalog.json has dossier fields embedded)
        // but the user should know the JSONL belt is missing.
        let bundle = try makeTempDir(label: "delta-no-src-bundle")
        defer { try? FileManager.default.removeItem(at: bundle) }

        let bogus = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString)")
        var warnings: [(String, String)] = []
        let summary = BundleExporter.copyDossierDeltas(from: bogus,
                                                       into: bundle,
                                                       warnings: &warnings)

        #expect(summary.lineCount == 0)
        #expect(summary.byteCount == 0)
        #expect(warnings.count == 1)
        #expect(warnings.first?.0 == "deltas/")
        #expect(warnings.first?.1.contains("not available") == true,
                "Warning text must convey that the dir is missing.")
    }

    @Test func copyDossierDeltas_when_source_is_a_file_not_a_dir_warns() throws {
        // Edge case: someone points the override at a file by mistake.
        let parent = try makeTempDir(label: "delta-not-dir")
        let bundle = try makeTempDir(label: "delta-not-dir-bundle")
        defer {
            try? FileManager.default.removeItem(at: parent)
            try? FileManager.default.removeItem(at: bundle)
        }
        let asFile = parent.appendingPathComponent("imafile.txt")
        try "hi".write(to: asFile, atomically: true, encoding: .utf8)

        var warnings: [(String, String)] = []
        let summary = BundleExporter.copyDossierDeltas(from: asFile,
                                                       into: bundle,
                                                       warnings: &warnings)

        #expect(summary.lineCount == 0)
        #expect(!warnings.isEmpty,
                "Must warn when src 'dir' isn't actually a directory.")
    }

    @Test func copyDossierDeltas_empty_dir_returns_zero_no_warnings() throws {
        // Fresh install: deltas/ dir exists but no workers have written
        // yet. Not an error — just zero contribution.
        let src = try makeTempDir(label: "delta-empty")
        let bundle = try makeTempDir(label: "delta-empty-bundle")
        defer {
            try? FileManager.default.removeItem(at: src)
            try? FileManager.default.removeItem(at: bundle)
        }
        var warnings: [(String, String)] = []
        let summary = BundleExporter.copyDossierDeltas(from: src,
                                                       into: bundle,
                                                       warnings: &warnings)
        #expect(summary.lineCount == 0)
        #expect(summary.byteCount == 0)
        #expect(warnings.isEmpty,
                "Empty source dir is normal, not a warning.")
    }

    // MARK: - copyCatalogManifestIfPresent

    @Test func copyCatalogManifestIfPresent_copies_when_source_exists() throws {
        let src = try makeTempDir(label: "manifest-src")
        let bundle = try makeTempDir(label: "manifest-bundle")
        defer {
            try? FileManager.default.removeItem(at: src)
            try? FileManager.default.removeItem(at: bundle)
        }
        let manifest = src.appendingPathComponent("manifest.sha256")
        try "abc123  catalog.json\n".write(to: manifest, atomically: true, encoding: .utf8)

        BundleExporter.copyCatalogManifestIfPresent(from: manifest, into: bundle)

        let dest = bundle.appendingPathComponent("catalog-manifest.sha256")
        #expect(FileManager.default.fileExists(atPath: dest.path))
        let text = try String(contentsOf: dest, encoding: .utf8)
        #expect(text.contains("abc123"))
    }

    @Test func copyCatalogManifestIfPresent_silent_when_source_missing() throws {
        // No-op, no throw. Many fresh installs won't have a manifest yet.
        let bundle = try makeTempDir(label: "manifest-noop-bundle")
        defer { try? FileManager.default.removeItem(at: bundle) }
        let bogus = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).sha256")

        BundleExporter.copyCatalogManifestIfPresent(from: bogus, into: bundle)

        let dest = bundle.appendingPathComponent("catalog-manifest.sha256")
        #expect(!FileManager.default.fileExists(atPath: dest.path),
                "Nothing should be created when the source manifest is absent.")
    }
}
