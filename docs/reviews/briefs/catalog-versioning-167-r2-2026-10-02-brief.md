Scoped data-risk RE-REVIEW (round 2) — polite catalog versioning (GH #167), 2026-10-02. Range d4a678f6..feat/167-catalog-versioning (tip b912eb4d; 5 commits closing the 5 findings of cycle #28, docs/reviews/codex/codex-review-catalog-versioning-167-2026-10-02.md). The branch is NOT checked out in ~/dev/VideoScan (main stays on main for the 2 AM nightly): read it with `git diff d4a678f6..feat/167-catalog-versioning`, `git show feat/167-catalog-versioning:<path>`, or the worktree at .claude/worktrees/agent-a16539dd528cf8b68. Do not check out the branch in ~/dev/VideoScan.

Files in scope (do not explore outside these):
- VideoScan/VideoScan/Catalog/CatalogStore.swift — encodeAndWrite(gate:), CatalogWriteGate, CatalogNewerLatchMirror, refuseIfNewerCatalogOnDisk, load() sidecar deferral (persistBootstrappedFloorIfNeeded), writeSnapshot / writeSnapshotAsync, adoptOnDiskGenerationAfterReconcile
- VideoScan/VideoScan/Catalog/CatalogHeaderScanner.swift (new) — byte-level depth-1 key scanner, head/tail windows, whole-file streaming fallback
- VideoScan/VideoScan/Catalog/CatalogGenerationSidecar.swift — seedIfAbsent, load(persistBootstrap:)
- VideoScan/VideoScan/Catalog/VideoScanModel+RescanPreservation.swift — unknownFields refresh at apply time
- VideoScan/VideoScan/Catalog/VideoScanModel+NotesRepair.swift — refuseIfNewerCatalogOnDisk use
- VideoScan/VideoScan/Catalog/VideoScanModel+LiveReload.swift — read-only tick doc + adopt guard
- VideoScan/VideoScanCore/Sources/VideoScanCore/CatalogUnknownFields.swift — CatalogJSONValue number cases (.uint, .decimal, Double fallback, -0)
- docs/practices/invariants/Catalog.md
- Tests: VideoScan/VideoScanTests/CatalogVersioningTests.swift (section 6: CatalogQueuedWriteLatchTests, CatalogVersionProbeDepthTests, RescanUnknownFieldsLiveRefreshTests, CatalogUnknownNumberExactnessTests, CatalogSiblingWritersDiscoverNewerTests, CatalogReadOnlyLiveReloadTickTests; everyWritePathPreserves; writeEntryPointsAreLatched sensor), CatalogGenerationProbeTests.swift, VideoScanCore/Tests/VideoScanCoreTests/CatalogJSONValueExactNumberTests.swift (new)

Questions, in priority order — answer each with "closed" or a finding:
1. Cycle #28 #1: is the queue-side gate (gate.newerVersion() between encode and the atomic rename) complete for EVERY writer that reaches encodeAndWrite? Can the CatalogNewerLatchMirror disagree with the main-actor latch in a way that lets a write through? Any new deadlock / main-thread block from the lock-guarded mirror or the completion-on-main latch?
2. Cycle #28 #2: can CatalogHeaderScanner be fooled — escaped quotes in keys, `"`, a top-level "version" after >4 KB of records, a string containing `{"version":`, unterminated strings, a file where head and tail windows overlap, BOM, trailing garbage, a non-object root (array)? When version stays unknown after the whole-file pass, is the result a REFUSAL (never "old")? Is the whole-file fallback bounded in memory (1 MB chunks) and can it be driven to O(file) on every save?
3. Cycle #28 #5 + load(): is there now ANY byte written beside a newer catalog.json by the in-scope code — sidecar, .prev rotation, catalog.pre-*, notes-repair marker/backup — on the latch-at-load, undecodable-newer, and mid-session paths?
4. Cycle #28 #3: does the apply-time refresh of unknownFields ever REPLACE a live record's unknown keys with stale ones, or drop a key the live record gained during the scan? Does it ever overwrite a KNOWN field?
5. Cycle #28 #4: can encode(decode(x)) ≠ x for any canonical JSONEncoder number output (Int64/UInt64 extremes, Decimal 38 digits, -0, 1e-128, 1.5e300)? Is "value-exact but not spelling-exact for exponent forms" and "38 significant digits" the full statement of remaining loss?
6. Test adequacy: does each new suite actually fail if its fix is reverted (the agent reports mutation kills — name any mutation you believe would survive)?

Known and accepted (do not report): the microsecond window between the final probe and rename(2) (rename is unconditional); exponent-form numbers come back in JSONEncoder spelling (value exact); >38 significant digit literals (no Swift numeric writer can produce them); SwiftLint file/type-length warnings; OUT OF SCOPE and already filed as a follow-up issue: Relocate's snapshotCatalogPreRelocate, ArchiveLockJob catch-up marker, DateInference sidecars, and viewer-mode (.isReadOnly) .prev rotation / sidecar writes.

Evidence already run (Debug, by suite, counts confirmed nonzero): red-first commit f56bc185 — every new test red on d4a678f6 (6 suites, 36 issues; core 9); after fixes: broad catalog regression 2086 Swift Testing / 314 suites + 49 XCTest, 0 failures; VideoScanCore swift test 849 / 138 suites + 228 XCTest green (10 pre-existing timing/harness known issues). Mutations: #1 queue check removed → red (10 issues); #2 old probe restored → red (8), sidecar-before-decode → red (1); #3 refresh removed → red (2); #4 UInt64+Decimal removed → red (app 5, core 8); #5 notes-repair revert → red (4), snapshot pre-check alone → caught by writeEntryPointsAreLatched sensor (2), both layers → red (6).

Output contract (required):
- First line exactly: Credits spent: <amount> | Finding count: <N>
- A line: Verdict: <merge | fix | block> — <one-line reason>

Wanted: findings with file:line + a concrete reproduction (ideally a Swift Testing red test with synthetic data), and "closed" per cycle-#28 finding. Privacy: public repo — no real family names, addresses or dates in any suggested fixture.
