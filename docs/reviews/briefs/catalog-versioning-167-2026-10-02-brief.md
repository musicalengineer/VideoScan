Scoped data-risk pass — polite catalog versioning (GH #167), 2026-10-02. Range c32167f8..feat/167-catalog-versioning (d4a678f6; 5 commits). The branch is NOT checked out in the main repo (main stays on main for the 2 AM nightly): read it with `git diff c32167f8..feat/167-catalog-versioning` and `git show feat/167-catalog-versioning:<path>`, or the worktree at .claude/worktrees/agent-a16539dd528cf8b68. Do not check out the branch in ~/dev/VideoScan.

Files in scope (do not explore outside these; named callers are for reading only):
- VideoScan/VideoScanCore/Sources/VideoScanCore/CatalogUnknownFields.swift (new) — capture/merge of unknown top-level + per-record keys, CatalogJSONValue
- VideoScan/VideoScanCore/Sources/VideoScanCore/VideoRecord+Codable.swift, VideoRecord.swift, VideoRecordDTO.swift, VideoRecord+Clone.swift — unknown-key carry on decode/encode/clone
- VideoScan/VideoScan/Catalog/CatalogStore.swift — currentVersion 6→7, load (newer-version latch, undecodable-newer → .prev shown read-only), quick version peek, writePrecondition, saveNow / saveAsync / saveAcknowledged, onNewerCatalogLatched
- VideoScan/VideoScan/Catalog/CatalogGenerationSidecar.swift — no sidecar write beside a newer catalog
- VideoScan/VideoScan/Catalog/VideoScanModel+LiveReload.swift — read-only tick is a no-op
- VideoScan/VideoScan/Catalog/VideoScanModel+RescanPreservation.swift — unknown keys survive rescan carry-over
- VideoScan/VideoScan/Catalog/VideoScanModel+NotesRepair.swift — refuses while newer catalog latched
- VideoScan/VideoScan/People/VideoScanModel+FindTagHelper.swift — background held
- VideoScan/VideoScan/Model/VideoScanModel.swift — isReadOnly wiring, load-time migrations / Analyze auto-resume held
- VideoScan/VideoScan/Catalog/CatalogVersionPauseBanner.swift (new), App/ContentView.swift, App/VideoScanApp.swift — banner only
- docs/practices/invariants/Catalog.md (new)
- Tests: VideoScan/VideoScanTests/CatalogVersioningTests.swift (new) + the v7 edits in CatalogStoreHardeningTests, CatalogStoreAsyncSaveTests, CatalogGenerationProbeTests, RelocateSchemaTests, SceneCaptionsTests

Invariants to attack (rank by data-loss risk):
1. ZERO WRITES beside a newer catalog: when catalog.json carries version > 7 (found at load, undecodable, or appearing mid-session), no path writes, renames, rotates or creates anything in the catalog folder except the refusal journal and catalog.lock — catalog.json, .prev, catalog.pre-*, generation sidecar, notes-repair backup/marker all byte-identical. Hunt for any save/write entry point that bypasses the gate (5 entry points claimed; byte writer claimed to have exactly 5 call sites).
2. NO SILENT FIELD LOSS: unknown keys (top-level, per-record, nested) survive load → edit → save → rescan → live reload → clone, byte-exact for values; an unknown key can never overwrite or shadow a known field; records without unknown keys encode byte-identically to v6 output.
3. MIGRATION ONCE: v0–v6 upgrade to v7 exactly once, original bytes preserved in .prev, no re-migration, nothing dropped.
4. Mid-session latch: the async save checks the version under the advisory lock but writes later on a queue — is there a window where a newer build's file is overwritten? Is isReadOnly flipped before any background job can start a write?
5. The quick version peek (first/last 4 KB, first "version" key): can a legitimate v7+ file written by our own encoder ever be misread as older (e.g. a record field named "version" appearing first, huge files, escaped strings)?
6. Concurrency: no deadlock or main-thread blocking introduced by the latch callback; no data race on the latch flag.

Known and accepted (do not report): builds older than 2026-08-14 can still damage a v7 catalog (no version gate existed — Rick told not to run them); importCatalog has no version check but has no callers; a few in-memory load steps (migrateVolumeRoles, phase repairs) still run on a newer catalog and write only UserDefaults/scan targets, not catalog.json; Find and Tag background / Analyze auto-resume gating is covered only indirectly via isReadOnly.

Evidence already run (Debug, by suite, counts confirmed): #167 suites 23 tests / 6 suites green (100k records with unknown keys: save 2.19 s, load 5.30 s vs 20 s budget); 244 catalog-related suites — 1431 Swift Testing + 48 XCTest, 0 failures (two Real* suites excluded: they read real user data); VideoScanCore swift test 843 + 228 XCTest green (9 pre-existing known issues). Mutations: disabling the live-reload read-only no-op and the mid-session latch each turn a test red; the load-time sidecar write was caught red by the poisoned-state test before its fix.

Also check, per Rick's standing directive: new-code test coverage of each invariant (name gaps vs tests run) and logging (actionable START/OUTCOME, no flooding, no person names or full paths of family media in logs).

Output contract (required):
- First line exactly: Credits spent: <amount> | Finding count: <N>
- A line: Verdict: <merge | fix | block> — <one-line reason>

Wanted: findings with file:line + a concrete reproduction (ideally a Swift Testing red test with synthetic data), and "read, no findings" per clean file. Privacy: public repo — no real family names, addresses or dates in any suggested fixture.
