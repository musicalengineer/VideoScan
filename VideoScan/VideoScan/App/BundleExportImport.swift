// BundleExportImport.swift
// Overview / format documentation for the one-shot "whole shebang"
// export/import feature. The implementation was split out of this file in
// the 2026-06-25 refactor (it was over the 1000-line file_length cap):
//
//     BundleModels.swift    — Codable manifest/snapshot models, BundleError,
//                             BundleSize, the shared referencePhotoExts set
//     BundleExporter.swift  — BundleExporter + DossierDeltaPaths (export side)
//     BundleImporter.swift  — BundleImporter (import side, safe-swap install)
//
// This file is intentionally code-free; it keeps the format spec and the
// incident history in one canonical place that the split files point back to.
//
// One-shot "whole shebang" export/import so the user can move their entire
// VideoScan world from one Mac to another (Mac Studio → MacBook Pro is the
// driving scenario). The bundle is a directory `<name>.videoscanbundle/`.
// Bundle v2 (2026-10-19) — the catalog is the database, sealed:
//
//     <name>.videoscanbundle/
//     ├── manifest.json     // version 2, host, counts, sizes, and
//     │                     //   catalogDatabase {generation, highWater,
//     │                     //   files, quarantine, content, bytes, sha256}
//     ├── catalog.sqlite    // sealed VACUUM INTO copy (CatalogBackupSeal) —
//     │                     //   every row, removed rows and quarantine too
//     ├── catalog.cutover   // byte copy of the latch
//     ├── catalog.highwater // the high-water this Mac had written
//     ├── volumes.json      // per-volume metadata (role, trust, media, …)
//     ├── settings.json     // machine-portable PersonFinderSettings only
//     ├── deltas/ , catalog-manifest.sha256   (optional, as before)
//     └── people/<UUID>/…   // as below
//
// Import Catalog never merges into catalog.sqlite: a v2 bundle is refused
// (no safe Restore exists yet) and so is a v1 bundle under catalog.sqlite.
//
// Bundle v1 (before the database switch) — still readable by the legacy
// merge on a Mac whose catalog is catalog.json; never written any more:
//
//     <name>.videoscanbundle/
//     ├── manifest.json     // version, host, counts, total size
//     ├── catalog.json      // existing CatalogSnapshot — records
//     ├── volumes.json      // per-volume metadata (role, trust, media, …)
//     ├── settings.json     // machine-portable PersonFinderSettings only
//     └── people/
//         └── <UUID>/            // uuid-keyed since 2026-09-12; <sanitized-name>/ in older bundles
//             ├── profile.json
//             └── reference photos (jpg/heic/…)
//
// "Machine-portable" means we deliberately drop fields that mean different
// things on different machines: pythonPath, recognitionScript, referencePath
// (re-derived from POI folder layout on import), outputDir.
//
// IMPORT SAFETY (post May-2026 incident):
//   The previous version of installPOIs did a naive
//       removeItem(dest); copyItem(src, dest)
//   loop. When the bundle lived on iCloud Drive, iCloud-evicted reference
//   photos enumerated fine but copyItem produced an empty destination with no
//   thrown error — 5 of Rick's 13 POIs were destroyed on M5 import. The
//   importer now:
//     A. Materializes (downloads) iCloud-evicted POI contents before copying
//     B. Wraps each POI in try/catch so one failure doesn't kill the run
//     C. Copies to a sibling temp dir, validates, then atomically swaps;
//        the displaced original is moved to ~/dev/VideoScan/.trash/ rather
//        than rm -rf'd, per project policy
//     D. Validates profile.json decodes after copy before swapping in
//   Plus conflict resolution: when bundle and local both have a POI of the
//   same name, the side with MORE reference photos wins (with mtime tiebreak),
//   so a stale/empty bundle entry can never silently overwrite richer local
//   data.
//
// EXPORT SAFETY:
//   POI folders frequently contain symlinks pointing at Mac-Studio-only paths
//   (e.g. ~/dev/VideoScan/output/cluster_faces/...). copyItem preserves the
//   symlink, which is dead on every other machine. The exporter now resolves
//   symlinks and copies the target's bytes; unreachable targets are logged
//   and reported in the export result.
