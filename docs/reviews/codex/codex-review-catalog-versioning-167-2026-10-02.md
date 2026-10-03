# Codex review — #167 catalog versioning

- Range: `c32167f8..feat/167-catalog-versioning`
- Credits spent: unavailable
- Tokens: 66803
- Finding count: 5
- Verdict: block — newer catalogs can still be overwritten, and unknown values can silently change.
- Run: 2026-10-02T23:34:18Z (cycle #28, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 5
Verdict: block — newer catalogs can still be overwritten, and unknown values can silently change.

Reviewed `d4a678f6`; main remains checked out. Swift reproductions below are **proposed, not executed**: the sandbox is read-only. Your supplied green runs remain the test evidence.

1. **P1 — A queued save can write after the newer-catalog latch fires.** [CatalogStore.swift:1265](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-a16539dd528cf8b68/VideoScan/VideoScan/Catalog/CatalogStore.swift:1265)

   `writePrecondition()` checks on the main actor, but the queued closure proceeds directly to encoding and writing. It never observes a subsequent latch.

   **Reproduction:** save a healthy catalog; set `testWriteDelay = 0.25`; call `saveAsync`; immediately atomically replace the primary with `{"version":8,"generation":1,"records":[]}` and call `noteNewerCatalogOnDisk(version: 8)`. After the queued write completes, expect the replacement bytes unchanged. They are overwritten with v7 despite the model already being read-only.

   The held advisory lock protects a single save against cooperating writers. This reproduction models a sync/file replacement outside that lock. The acknowledged path has the same deferred-check limitation at line 1208.

2. **P1 — The version probe accepts a record’s version as the catalog version.** [CatalogStore.swift:215](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-a16539dd528cf8b68/VideoScan/VideoScan/Catalog/CatalogStore.swift:215)

   The first string match has no object-depth check. This valid catalog probes as **v1**:

   ```json
   {"records":[{"version":1}],"version":8,"generation":0}
   ```

   **Reproduction:** write those bytes into a scratch catalog, construct a store, and call `saveNow(records: [])` without loading. Expect refusal and unchanged bytes; the gate permits replacement with v7. Calling `load()` instead creates the generation sidecar before the authoritative decode latches v8.

   The current hand-built encoder always puts the real version first, so its own output avoids this bug—even with large records and escaped strings. Reordered valid JSON remains unsafe.

3. **P1 — Rescan replaces live-reloaded unknown fields with the scan-start snapshot.** [VideoScanModel+RescanPreservation.swift:465](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-a16539dd528cf8b68/VideoScan/VideoScan/Catalog/VideoScanModel+RescanPreservation.swift:465)

   Unknown fields are restored unconditionally. The apply-time refresh at line 535 refreshes only fixity.

   **Reproduction:** start a same-path rescan with `future="old"`. During the scan, live reload changes it to `"new"` and adds `futureAdded=true`. Complete the rescan. The replacement record contains `"old"` and lacks `futureAdded`; the next save persists that loss. Also test a record acquiring its **first** unknown field during the scan.

4. **P1 — Unknown numbers lose their exact value.** [CatalogUnknownFields.swift:76](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-a16539dd528cf8b68/VideoScan/VideoScanCore/Sources/VideoScanCore/CatalogUnknownFields.swift:76)

   Numbers outside `Int64` fall through to `Double`. `18446744073709551615` becomes binary64 value `18446744073709551616`. Nested unknown values have the same problem.

   Proposed red test:

   ```swift
   @Test func unknownUInt64RetainsExactValue() throws {
       let source = try JSONEncoder().encode(UInt64.max)
       let value = try JSONDecoder().decode(CatalogJSONValue.self, from: source)
       #expect(try JSONEncoder().encode(value) == source)
   }
   ```

   `Catalog.md:32` calls this accepted. Your review brief explicitly requires exact values, so I treated the brief as controlling.

5. **P2 — Snapshot and notes-repair paths check only an existing latch.** [CatalogStore.swift:1327](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-a16539dd528cf8b68/VideoScan/VideoScan/Catalog/CatalogStore.swift:1327), [VideoScanModel+NotesRepair.swift:72](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-a16539dd528cf8b68/VideoScan/VideoScan/Catalog/VideoScanModel+NotesRepair.swift:72)

   **Reproduction:** load/save v7, replace the primary with canonical v8, then call `writeSnapshot` or `writeSnapshotAsync` before another live save/reload discovers it. Both create `catalog.pre-*` files. On a model with empty records, `repairMachineTextInUserNotes()` creates `notes-repair.v1.done` through its clean-plan branch.

   All must discover the newer primary and refuse before modifying siblings. Counting five byte-writer call sites does not establish that their gates are sufficient.

Coverage assessment:

| Invariant | Evidence and remaining gaps |
|---|---|
| Zero writes | Poisoned load coverage is strong. Missing mid-session snapshot/marker and queued-write attacks above. Undecodable coverage excludes sidecar/marker bytes. |
| Unknown preservation | Ordinary round trips, cloning and scale covered. Missing numeric boundaries, live-reload-during-rescan, disk top-level reload→save, and async snapshot preservation. Unknown additions inside **known nested objects** remain unverified. |
| Migration once | v0–v6 fixtures check original `.prev` bytes and stable second-save records; no finding. |
| Immediate latch | Synchronous model callback covered; outstanding writer cancellation/refusal is not. |
| Version peek | Canonical encoder header covered; nested-key decoy is not. |
| Concurrency | Latch state and callback are main-actor isolated; no new latch data race or blocking wait found. Deferred writing remains finding 1. |

[CatalogVersioningTests.swift:240](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-a16539dd528cf8b68/VideoScan/VideoScanTests/CatalogVersioningTests.swift:240) also has a coverage weakness: removing `saveAsync` still lets the preservation assertion pass against the preceding acknowledged save. Require generation/completion advancement and an async-specific edit.

The claimed read-only live-reload **no-op** evidence does not match this SHA: the poll has no such early return, and `everyPathIsHeld` explicitly expects read-only reload to merge a transcript.

New latch/refusal logging is actionable, one-shot, and contains no person names or full family-media paths. No independent logging finding.

Read, no findings in these scoped files/edits:

- `VideoRecord.swift`
- `VideoRecord+Codable.swift`
- `VideoRecordDTO.swift`
- `VideoRecord+Clone.swift`
- `CatalogGenerationSidecar.swift`
- `VideoScanModel+LiveReload.swift`
- `VideoScanModel.swift`
- `VideoScanModel+FindTagHelper.swift`
- `CatalogVersionPauseBanner.swift`
- `ContentView.swift`
- `VideoScanApp.swift`
- `CatalogStoreHardeningTests.swift`
- `CatalogStoreAsyncSaveTests.swift`
- `CatalogGenerationProbeTests.swift`
- `RelocateSchemaTests.swift`
- `SceneCaptionsTests.swift`

Remaining scoped files were read and are addressed by the findings or coverage notes above, including `Catalog.md`.

## Brief

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
