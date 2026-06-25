// BundleImporter.swift
// The import half of the bundle "whole shebang" feature — extracted verbatim
// from BundleExportImport.swift (refactor 2026-06-25). Reads the bundle JSON,
// then safely installs POI folders with iCloud materialization, richer-wins
// conflict resolution, and copy-validate-swap semantics. The import-safety
// invariants (post May-2026 incident) are load-bearing and were moved
// byte-for-byte — see the file-header comment in BundleExportImport.swift.
// (Swift `enum` with only static members ≈ a C++ namespace of free functions.)

import Foundation
import AppKit

// MARK: - Importer

enum BundleImporter {

    struct Payload {
        var manifest: BundleManifest
        var catalog: CatalogSnapshot
        var volumes: VolumesSnapshot
        var settings: SettingsSnapshot
        var poiFoldersInBundle: [URL]
        /// Manifest export timestamp — falls back to manifest.exportedAt when
        /// per-file mtimes aren't available (e.g. all-iCloud-evicted source).
        var bundleExportedAt: Date
    }

    /// Per-POI conflict-resolution timeout for iCloud materialization.
    /// 60s per POI is generous; the typical POI is a few MB of HEIC photos.
    static let iCloudMaterializeTimeoutSeconds: TimeInterval = 60

    /// Read and decode a bundle directory. Returns the parsed payload — the
    /// caller (VideoScanModel) is responsible for merging into live state.
    /// Throws if the bundle is malformed or from a newer format version.
    ///
    /// Tolerates bundles without `manifest.json` (legacy or partial exports
    /// where the manifest write was interrupted): a placeholder manifest is
    /// synthesized so the rest of the import flow works. A bundle without
    /// `catalog.json` is still considered malformed and rejects below.
    static func read(from bundleURL: URL) throws -> Payload {
        let fm = FileManager.default

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let manifestURL = bundleURL.appendingPathComponent("manifest.json")
        let manifest: BundleManifest
        if fm.fileExists(atPath: manifestURL.path) {
            do {
                let data = try Data(contentsOf: manifestURL)
                manifest = try decoder.decode(BundleManifest.self, from: data)
            } catch {
                throw BundleError.decode("manifest.json — \(error.localizedDescription)")
            }
            guard manifest.bundleVersion <= BundleManifest.currentVersion else {
                throw BundleError.manifestVersionUnsupported(manifest.bundleVersion)
            }
        } else {
            manifest = synthesizeLegacyManifest(bundleURL: bundleURL, fm: fm)
        }

        let catalog: CatalogSnapshot = try decode(decoder, at: bundleURL.appendingPathComponent("catalog.json"),
                                                  label: "catalog.json")
        let volumes: VolumesSnapshot = try decode(decoder, at: bundleURL.appendingPathComponent("volumes.json"),
                                                  label: "volumes.json")
        let settings: SettingsSnapshot = try decode(decoder, at: bundleURL.appendingPathComponent("settings.json"),
                                                    label: "settings.json")

        // Resolve pairedWith back-references inside the imported records,
        // matching the standalone import path.
        let importedByID = Dictionary(uniqueKeysWithValues: catalog.records.map { ($0.id, $0) })
        for rec in catalog.records {
            if let pid = rec.pendingPairedWithID {
                rec.pairedWith = importedByID[pid]
                rec.pendingPairedWithID = nil
            }
        }

        // Enumerate people/* subfolders.
        let peopleDir = bundleURL.appendingPathComponent("people", isDirectory: true)
        let poiFolders: [URL]
        if let kids = try? fm.contentsOfDirectory(at: peopleDir,
                                                  includingPropertiesForKeys: [.isDirectoryKey]) {
            poiFolders = kids.filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            }
        } else {
            poiFolders = []
        }

        return Payload(manifest: manifest,
                       catalog: catalog,
                       volumes: volumes,
                       settings: settings,
                       poiFoldersInBundle: poiFolders,
                       bundleExportedAt: manifest.exportedAt)
    }

    private static func decode<T: Decodable>(_ decoder: JSONDecoder,
                                             at url: URL,
                                             label: String) throws -> T {
        do {
            let data = try Data(contentsOf: url)
            return try decoder.decode(T.self, from: data)
        } catch {
            throw BundleError.decode("\(label) — \(error.localizedDescription)")
        }
    }

    /// Build a placeholder `BundleManifest` for a bundle that lacks one. Used
    /// for legacy bundles produced before the manifest was added, and for
    /// bundles whose export was interrupted before the final manifest write.
    /// Fields are populated from filesystem inspection so the rest of the
    /// import flow has reasonable values (counts/sizes drive the success
    /// alert; `exportedAt` is the mtime tiebreaker on the bundle side).
    private static func synthesizeLegacyManifest(bundleURL: URL,
                                                 fm: FileManager) -> BundleManifest {
        let peopleDir = bundleURL.appendingPathComponent("people", isDirectory: true)
        var peopleCount = 0
        var refPhotoCount = 0
        var refPhotoBytes: Int64 = 0
        if let kids = try? fm.contentsOfDirectory(at: peopleDir,
                                                  includingPropertiesForKeys: [.isDirectoryKey]) {
            for kid in kids where (try? kid.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                peopleCount += 1
                if let enumerator = fm.enumerator(at: kid,
                                                  includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
                    for case let url as URL in enumerator {
                        let rv = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                        guard rv?.isRegularFile == true else { continue }
                        if url.lastPathComponent == "profile.json" { continue }
                        refPhotoCount += 1
                        refPhotoBytes += Int64(rv?.fileSize ?? 0)
                    }
                }
            }
        }

        let totalBytes = BundleExporter.directorySize(bundleURL)
        let bundleMtime = (try? bundleURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date()

        return BundleManifest(
            bundleVersion: 0,
            exportedAt: bundleMtime,
            exportedFromHost: "unknown (legacy bundle, no manifest)",
            appVersion: "legacy",
            appBuild: "legacy",
            counts: BundleManifest.Counts(records: 0,
                                          volumes: 0,
                                          people: peopleCount,
                                          referencePhotos: refPhotoCount),
            sizes: BundleManifest.Sizes(totalBytes: totalBytes,
                                        referencePhotoBytes: refPhotoBytes)
        )
    }

    // MARK: - Result types

    /// Per-POI installation outcome from `installPOIs`. The caller folds
    /// these into a user-facing alert and an audit log line.
    struct POIInstallResult {
        /// Names that were copied into POIStorage.storeDir (bundle won).
        var installed: [String]
        /// Names where the local copy was preferred (kept untouched).
        var skipped: [(name: String, reason: String)]
        /// Names that errored during materialize/copy/validate.
        var failed: [(name: String, reason: String)]
        /// Per-POI decisions, in bundle-iteration order, suitable for an
        /// audit log line. One string per POI.
        var auditLines: [String]
    }

    // MARK: - Public entry point

    /// Copy the bundle's POI folders into ~/Library/Application Support/
    /// VideoScan/POI/, applying iCloud-aware safe-swap and richer-wins
    /// conflict resolution. The previous implementation destroyed local POIs
    /// when bundle sources were iCloud-evicted — see file-header comment.
    ///
    /// This is `async` because iCloud materialization is a polling wait that
    /// MUST NOT block the main actor. Callers `await` it from a Task.
    static func installPOIs(from poiFoldersInBundle: [URL],
                            bundleExportedAt: Date) async -> POIInstallResult {
        let fm = FileManager.default
        var installed: [String] = []
        var skipped: [(String, String)] = []
        var failed: [(String, String)] = []
        var auditLines: [String] = []

        for src in poiFoldersInBundle {
            let folderName = src.lastPathComponent
            let dest = POIStorage.storeDir.appendingPathComponent(folderName,
                                                                  isDirectory: true)

            // -- Part 1.A: materialize iCloud-evicted contents --
            //
            // Only relevant if the bundle was opened from iCloud Drive. Local
            // paths skip this step entirely (cheap check).
            do {
                try await materializeIfUbiquitous(at: src)
            } catch {
                let reason = "iCloud materialize failed: \(error.localizedDescription)"
                failed.append((folderName, reason))
                auditLines.append("[import] POI \(folderName): FAILED — \(reason)")
                continue
            }

            // -- Part 2: conflict resolution --
            let bundleRefCount = countReferencePhotos(under: src)
            let localRefCount = fm.fileExists(atPath: dest.path)
                ? countReferencePhotos(under: dest)
                : 0
            let bundleMtime = effectiveMTime(of: src, fallback: bundleExportedAt)
            let localMtime: Date? = fm.fileExists(atPath: dest.path)
                ? effectiveMTime(of: dest, fallback: nil)
                : nil

            let decision = decideWinner(
                bundleRefCount: bundleRefCount,
                localRefCount: localRefCount,
                bundleMtime: bundleMtime,
                localMtime: localMtime,
                localExists: fm.fileExists(atPath: dest.path)
            )

            let auditPrefix = "[import] POI \(folderName): " +
                "bundle=(\(bundleRefCount) photos, \(formatMTime(bundleMtime))) " +
                "local=(\(localRefCount) photos, \(formatMTime(localMtime)))"

            switch decision {
            case .preferLocal(let reason):
                skipped.append((folderName, reason))
                auditLines.append("\(auditPrefix) → chose LOCAL (\(reason))")
                continue
            case .preferBundle(let reason):
                auditLines.append("\(auditPrefix) → chose BUNDLE (\(reason))")
            }

            // -- Part 1.C: copy-then-rename with .trash/ safe-swap + 1.D validate --
            do {
                try safeInstallPOI(src: src, dest: dest, folderName: folderName)
                installed.append(folderName)
            } catch {
                failed.append((folderName, error.localizedDescription))
                auditLines.append("[import]   ↳ install failed: \(error.localizedDescription)")
            }
        }

        return POIInstallResult(installed: installed,
                                skipped: skipped,
                                failed: failed,
                                auditLines: auditLines)
    }

    // MARK: - Part 1.A: iCloud materialization

    /// If `dir` lives on iCloud Drive, recursively start downloads on any
    /// non-current files and poll until they reach `.current` or we hit the
    /// per-POI timeout. No-op for local files.
    ///
    /// We do this per-POI rather than for the whole bundle so memory and
    /// time stay bounded — only one POI's worth of files are in-flight at
    /// any moment. Worst-case in-memory footprint: a URL list for one POI
    /// (typically <100 entries).
    private static func materializeIfUbiquitous(at dir: URL) async throws {
        let fm = FileManager.default
        guard fm.isUbiquitousItem(at: dir) else { return }

        // Enumerate every file in the POI dir, kick off downloads on
        // anything not-current.
        guard let it = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey, .ubiquitousItemDownloadingStatusKey],
            options: []
        ) else { return }

        var pending: [URL] = []
        for case let url as URL in it {
            guard
                let vals = try? url.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .ubiquitousItemDownloadingStatusKey
                ]),
                vals.isRegularFile == true
            else { continue }

            if vals.ubiquitousItemDownloadingStatus != .current {
                // Try to start the download — even on a current file this is
                // a cheap no-op.
                try? fm.startDownloadingUbiquitousItem(at: url)
                pending.append(url)
            }
        }
        if pending.isEmpty { return }

        // Poll until every pending file reaches .current, or we exceed the
        // timeout. The poll interval is short enough to feel responsive but
        // not so tight that we burn CPU.
        let deadline = Date().addingTimeInterval(iCloudMaterializeTimeoutSeconds)
        while Date() < deadline {
            var stillPending: [URL] = []
            for url in pending {
                let status = (try? url.resourceValues(
                    forKeys: [.ubiquitousItemDownloadingStatusKey]
                ).ubiquitousItemDownloadingStatus) ?? .notDownloaded
                if status != .current { stillPending.append(url) }
            }
            if stillPending.isEmpty { return }
            pending = stillPending

            // `Task.sleep` is the async equivalent of usleep — releases the
            // thread back to the executor instead of blocking.
            try await Task.sleep(nanoseconds: 250_000_000) // 0.25s
        }

        // Timed out — surface the first still-pending path so the caller
        // logs something useful.
        if let stuck = pending.first {
            throw BundleError.iCloudDownloadTimeout(stuck.path)
        }
    }

    // MARK: - Part 1.C & 1.D: safe-swap install

    /// Copy `src` to a sibling temp dir, validate, then atomically swap into
    /// `dest`. The displaced original is moved to ~/dev/VideoScan/.trash/
    /// rather than rm -rf'd so Rick can recover.
    ///
    /// On any failure between copy and swap, the temp dir is removed and
    /// `dest` is left untouched. This is what was missing before — the old
    /// path destroyed `dest` first and then a no-op copy left an empty hole.
    private static func safeInstallPOI(src: URL, dest: URL, folderName: String) throws {
        let fm = FileManager.default
        let temp = dest.deletingLastPathComponent()
            .appendingPathComponent("\(folderName).import-\(UUID().uuidString)",
                                    isDirectory: true)

        // Copy.
        do {
            try fm.copyItem(at: src, to: temp)
        } catch {
            // Make sure we don't leave a half-copied temp around.
            try? fm.removeItem(at: temp)
            throw error
        }

        // Validate.
        do {
            try validatePOIDir(temp)
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }

        // Swap. Move-aside (NOT rm -rf) any existing dest, then move temp into place.
        if fm.fileExists(atPath: dest.path) {
            let trashURL = trashTarget(forPOI: folderName)
            try fm.createDirectory(at: trashURL.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            do {
                try fm.moveItem(at: dest, to: trashURL)
            } catch {
                // If we can't move the existing dest aside, ABORT — don't
                // proceed to wipe it. Leave temp around so a human can
                // inspect it.
                throw BundleError.validationFailed(
                    "could not move existing POI aside to \(trashURL.path): \(error.localizedDescription)"
                )
            }
        }
        do {
            try fm.moveItem(at: temp, to: dest)
        } catch {
            // Catastrophic but recoverable: temp still exists at its sibling
            // path; the prior dest is in .trash/. Surface both paths in the
            // error so Rick can recover by hand if needed.
            throw BundleError.validationFailed(
                "swap-in failed; temp left at \(temp.path): \(error.localizedDescription)"
            )
        }
    }

    /// Validate a freshly-copied POI directory before swapping it into place.
    /// Requires profile.json to exist, be non-empty, and decode as POIProfile.
    /// Reference photo count is NOT required (>= 0 is fine) — the structure
    /// just needs to be intact.
    private static func validatePOIDir(_ dir: URL) throws {
        let fm = FileManager.default
        let profileURL = dir.appendingPathComponent("profile.json")
        guard fm.fileExists(atPath: profileURL.path) else {
            throw BundleError.validationFailed("profile.json missing after copy")
        }
        let data: Data
        do {
            data = try Data(contentsOf: profileURL)
        } catch {
            throw BundleError.validationFailed("profile.json unreadable: \(error.localizedDescription)")
        }
        guard !data.isEmpty else {
            throw BundleError.validationFailed("profile.json is empty (likely iCloud-evicted)")
        }
        do {
            _ = try JSONDecoder().decode(POIProfile.self, from: data)
        } catch {
            throw BundleError.validationFailed("profile.json failed to decode: \(error.localizedDescription)")
        }
        // Reference photo count >= 0 is implicit; we don't require any photos.
    }

    /// Build a unique target inside the project-local .trash/ for the
    /// displaced POI dir. Format: ~/dev/VideoScan/.trash/POI-<name>-<isoTimestamp>/
    private static func trashTarget(forPOI folderName: String) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let stamp = isoStamp(Date())
        return home
            .appendingPathComponent("dev/VideoScan/.trash", isDirectory: true)
            .appendingPathComponent("POI-\(folderName)-\(stamp)", isDirectory: true)
    }

    // MARK: - Part 2: conflict resolution

    fileprivate enum Decision {
        case preferLocal(reason: String)
        case preferBundle(reason: String)
    }

    /// Pure decision function — easy to unit-test independently.
    fileprivate static func decideWinner(bundleRefCount: Int,
                                         localRefCount: Int,
                                         bundleMtime: Date?,
                                         localMtime: Date?,
                                         localExists: Bool) -> Decision {
        // Fast path: nothing local → bundle always wins.
        if !localExists {
            return .preferBundle(reason: "no local copy")
        }

        // Photo-count comparison is the primary signal because "newer" via
        // mtime is too easy to spoof by an accidental touch / iCloud sync
        // metadata change. More data wins.
        if bundleRefCount > localRefCount {
            return .preferBundle(reason: "more reference photos (\(bundleRefCount) > \(localRefCount))")
        }
        if localRefCount > bundleRefCount {
            return .preferLocal(reason: "local has more reference photos (\(localRefCount) > \(bundleRefCount))")
        }

        // Tie on count — mtime decides, with bundle winning a true tie.
        let bm = bundleMtime ?? .distantPast
        let lm = localMtime ?? .distantPast
        if bm > lm {
            return .preferBundle(reason: "equal photo count, bundle is newer")
        }
        if lm > bm {
            return .preferLocal(reason: "equal photo count, local is newer")
        }
        return .preferBundle(reason: "equal photo count and mtime; bundle wins by default")
    }

    /// Recursively count reference photos under `dir`. Used by conflict
    /// resolution and as a smoke-test for "did the iCloud download actually
    /// produce real files."
    private static func countReferencePhotos(under dir: URL) -> Int {
        let fm = FileManager.default
        guard let it = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        ) else { return 0 }
        var count = 0
        for case let url as URL in it {
            guard referencePhotoExts.contains(url.pathExtension.lowercased()) else { continue }
            // Require non-zero size — an iCloud placeholder is technically a
            // file but it's a 0-byte stub.
            let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if vals?.isRegularFile == true, (vals?.fileSize ?? 0) > 0 {
                count += 1
            }
        }
        return count
    }

    /// Pick the most-recent mtime under `dir`. We use the max of mtimes
    /// across the whole subtree — that captures "this POI was last
    /// meaningfully touched at T" better than the folder's own mtime, which
    /// is just last-directory-mutation.
    ///
    /// Returns `fallback` if the directory exists but no usable mtimes can
    /// be read. Returns nil only if `fallback` is also nil.
    private static func effectiveMTime(of dir: URL, fallback: Date?) -> Date? {
        let fm = FileManager.default
        guard let it = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return fallback }
        var best: Date? = nil
        for case let url as URL in it {
            if let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate {
                if best == nil || d > best! { best = d }
            }
        }
        return best ?? fallback
    }

    private static func formatMTime(_ d: Date?) -> String {
        guard let d else { return "n/a" }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    private static func isoStamp(_ d: Date) -> String {
        let f = DateFormatter()
        // Filename-safe: ISO-ish but no colons (which trip the Finder).
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f.string(from: d)
    }
}
