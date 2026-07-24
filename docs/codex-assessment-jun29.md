## Assessment

  The codebase has strong regression discipline and substantial defensive engineering. The main risks are not basic code quality; they are catalog ownership, path safety,
  mutable shared state, and cache coherence.

  ### Highest-priority findings

  1. “Remove from List” can delete catalog records without confirmation.

     The Catalog context menu calls removeScanTarget in VideoScan/VideoScan/CatalogView+VolumeTable.swift:447. That method removes every matching record in VideoScan/
     VideoScan/VideoScanModel+ScanTargets.swift:171.

     A newer, safer deleteScanTarget method correctly preserves records, but a UI path still invokes the old destructive implementation. Remove the legacy method or make
     it delegate to the safe behavior.

  2. Raw path-prefix matching can affect the wrong volume.

     Many destructive and state-changing operations use:

     record.fullPath.hasPrefix(target.searchPath)

     /Volumes/Drive Backup/a.mov therefore matches /Volumes/Drive. Rescan, catalog deletion, preservation, duplicate deletion, and volume accounting all use this pattern.
     A test explicitly documents and accepts the defect in VideoScan/VideoScanTests/PhaseConsistencyTests.swift:217.

     Introduce one tested PathScope.contains(path:) implementation that standardizes paths and enforces a component boundary. Reject empty roots. Add sibling-prefix tests
     to every destructive operation.

  3. The app and Python merger can lose each other’s catalog changes.

     Both independently read, modify, and atomically replace catalog.json. Atomic rename prevents partial files, but it does not prevent this sequence:
      - App snapshots catalog A.
      - Merger writes catalog B with new dossier data.
      - App writes its older snapshot A, losing B.

     Live reload occurs afterward and cannot recover data already overwritten. Use one writer. Best options:
      - App consumes the JSONL deltas itself.
      - SQLite/WAL becomes authoritative.
      - Interim: catalog revision/CAS plus an interprocess lock and retrying merge.

  4. Newer-schema refusal does not actually prevent later overwrite.

     CatalogStore.load() returns empty for a newer catalog version, but the store remains writable. VideoScanModel.init() can then backfill records from SQLite and
     schedule a save, replacing the newer catalog it intended to protect.

     Latch CatalogStore into a write-disabled recovery state after .refusedNewerVersion; test that subsequent scheduleSave and saveNow leave the original bytes unchanged.

  5. The search index becomes stale during normal editing.

     CatalogSearchIndex.update is only called by live dossier reload. Normal changes to people tags, transcripts, filenames, paths, and newly appended records do not
     update it. The inverted-index fast path can then omit valid results entirely.

     Route all catalog mutations through one catalog state/repository API that updates records, indexes, persistence dirtiness, and published revisions atomically. Add
     tests for:
      - Mutating a searchable field after index construction.
      - Adding a record containing an already-indexed word.
      - Renaming/moving a record.
      - Removing a record.

  6. POI persistence contains silent and nontransactional failures.

     Examples include deleting an old profile before a renamed profile successfully saves, migration reporting success after ignored copy/write failures, and photo imports
     swallowing writes. This is irreplaceable curated data.

     Stage writes, validate them, atomically install the new profile, and only then trash the old one. Return and surface detailed failures.

  ### Architecture

  The new VideoScanCore package is a good first boundary, but it currently contains only roughly 1,800 lines versus about 69,000 app-source lines. VideoScanModel still
  spans 34 extension files; extensions improve navigation but provide no dependency boundary. VideoRecord remains a public mutable class containing technical metadata,
  annotations, workflow state, relationships, and persistence concerns.

  Recommended incremental structure:

  - VideoScanCore: immutable domain values and identifiers.
  - CatalogRepository: actor-owned records, persistence, migrations, search indexing, mutation transactions.
  - MediaProbe: filesystem walk, ffprobe parsing, hashing, and injectable process execution.
  - Recognition: Vision/ArcFace engine protocols and value-type results.
  - App target: SwiftUI state and feature coordinators only.

  Keep VideoScanModel temporarily as a facade while moving one workflow at a time behind these services.

  Longer term, SQLite with WAL and FTS5 fits the current workload better than rewriting a 50–70 MB JSON snapshot after each editing burst. JSON can remain the export/
  backup format.

  ### Concurrency and current refactor

  A strict-concurrency build of main produced 149 unique warnings, 146 in app source. Many become errors under Swift 6: non-Sendable VideoRecord transfers, mutable
  captures, global shared state, CoreML/Vision values crossing actors, and actor-isolated protocol conformances.

  The 14 commits on refactor/videorecord-sendable are directionally correct. They introduce Sendable probe outcomes, combine specifications, relocate work items, and a
  persistence DTO, eliminating several unsafe crossings. The app built successfully at 03c264e.

  Continue subsystem-by-subsystem rather than applying @unchecked Sendable. Enable Swift 6 checking in VideoScanCore first, then persistence/probing, operations, and
  recognition.

  ### Testing recommendations

  The existing test suite is a major strength: approximately 1,888 tests and 162 marked regressions. Highest-value additions are:

  - Sibling-prefix and empty-path destructive-operation tests.
  - External-merger versus app-save lost-update test.
  - Newer-schema load followed by attempted save.
  - Search-index mutation coherence tests.
  - POI rename/migration fault injection.
  - Catalog crash points between catalog write, offset write, and manifest write.
  - State-machine tests for scan, relocate, cancellation, pause, and resume.
  - TSan nightly runs on self-hosted Apple Silicon; the workflow currently disables TSan.

  The new real-catalog search harness should require an explicit environment flag. Automatically decoding the user’s live catalog and enforcing wall-clock limits during
  every local unit run will make tests slower and vulnerable to concurrent app/merger writes.

  ### Measurements and verification

  - VideoScanCore: 14/14 tests passed on current main.
  - Debug app build succeeded on the Sendable refactor at 03c264e.
  - Focused search/persistence/probe/rescan/combine tests exited successfully, but the shared worktree switched branches during that run; rerun on a stable branch before
    merging.

  - SwiftLint: 74 warnings, including 59 size/complexity findings.
  - Largest production files remain PersonFinderModel+JobLifecycle.swift (1,343 lines) and VolumeCompare.swift (1,165 lines).
  - Current worktree: test/search-realdata-harness, with an uncommitted RealDataSearchTests.swift.
  