# Codex review — #167 catalog versioning r2

- Range: `d4a678f6..feat/167-catalog-versioning`
- Credits spent: unavailable
- Tokens: 191291
- Finding count: 4
- Verdict: fix — version probing still fails open, numeric values can change, and latch timing gaps remain.
- Run: 2026-10-03T00:18:25Z (cycle #29, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 4
Verdict: fix — version probing still fails open, numeric values can change, and latch timing gaps remain.

Reviewed `b912eb4d` in the supplied worktree. Main remains on main. The reproductions below are source-derived; Swift execution was blocked by the read-only session.

| Question | Result |
|---|---|
| 1 — cycle #28 #1, queued writes | **Finding F2.** All five writers carry the gate. No mirror-lock deadlock found, but the gate can miss a latch fired during its probe. |
| 2 — cycle #28 #2, scanner | **Finding F1.** Unknown is still writable. |
| 3 — cycle #28 #5 plus load | **Finding F4**, also affected by F1. Ordinary recognized newer-at-load paths defer sidecar writes and skip rotation correctly. |
| 4 — cycle #28 #3, rescan refresh | **Closed.** Live unknown keys replace the stale snapshot before apply; the refresh does not assign known fields. |
| 5 — cycle #28 #4, number exactness | **Finding F3.** Loss remains below 38 significant digits. |
| 6 — test adequacy | **Finding: coverage gaps below.** The reported mutation kills do not cover these boundaries. |

**F1 — P1: unresolved versions still permit replacement of a newer catalog.**

[CatalogHeaderScanner.swift:135](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-a16539dd528cf8b68/VideoScan/VideoScan/Catalog/CatalogHeaderScanner.swift:135) aborts on a BOM. For a small file, line 267 nevertheless marks the result complete. [CatalogStore.swift:190](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-a16539dd528cf8b68/VideoScan/VideoScan/Catalog/CatalogStore.swift:190) then returns nil when neither stamp was found, or substitutes version zero when only generation was found. Both write gates permit those results.

Concrete reproduction: prepend UTF-8 BOM bytes to `{"version":8,"generation":0,"records":[]}`, then call `saveNow` without loading. Foundation accepts the BOM, but this probe returns nil; the save replaces v8. Foundation explicitly strips BOMs before decoding. [Foundation decoder source](https://github.com/swiftlang/swift-foundation/blob/swift-6.2-RELEASE/Sources/FoundationEssentials/JSON/JSONDecoder.swift#L367)

Suggested red test, using the existing helpers:

```swift
@Test @MainActor
func bomNewerCatalogCannotBeOverwritten() throws {
    let dir = scratch("bom")
    defer { try? FileManager.default.removeItem(at: dir) }
    let future = CatalogSnapshot.currentVersion + 1
    var bytes = Data([0xEF, 0xBB, 0xBF])
    bytes.append(Data(
        #"{"version":\#(future),"generation":0,"records":[]}"#.utf8
    ))
    #expect(try JSONDecoder()
        .decode(CatalogSnapshot.self, from: bytes).version == future)
    try bytes.write(to: catalogURL(dir))
    let before = everyFile(dir)
    let store = CatalogStore(directory: dir)
    #expect(store.saveNow(records: []) == false)
    #expect(everyFile(dir) == before)
}
```

Changing `records` to a string also exposes the undecodable-newer load path: the failed decode plus unresolved probe reaches sidecar persistence at [CatalogStore.swift:889](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-a16539dd528cf8b68/VideoScan/VideoScan/Catalog/CatalogStore.swift:889).

Escaped keys/quotes, strings containing `{"version":`, nested keys, overlapping windows, and middle-of-file integer versions appear correctly handled for valid UTF-8 objects. Unterminated strings, non-object roots, and trailing garbage are not validated into a refusal. **Unknown must remain distinct from a confirmed absent version.**

The whole-file pass uses bounded 1 MB chunks. It can repeat O(file) work on every snapshot or refused save against an unchanged middle-layout/no-version file; the main-actor preconditions also perform that work.

**F2 — P1: a latch fired during the disk probe is missed.**

[CatalogStore.swift:245](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-a16539dd528cf8b68/VideoScan/VideoScan/Catalog/CatalogStore.swift:245) samples the mirror once, before `headerProbe`. Its final return is unconditionally nil when the probed file is older.

Concrete interleaving:

1. Gate reads an empty mirror.
2. Probe starts a long whole-file scan of a v7 primary.
3. Main actor latches v8 and updates the mirror.
4. Probe finishes with v7.
5. Gate returns nil and writes despite the established latch.

A deterministic regression needs a barrier after the initial mirror read/before probe completion: latch while held, then resume and assert the gate refuses. Re-reading the mirror before returning permission closes this gap. This occurs **during** the potentially long probe, outside the accepted post-probe rename window.

The mirror itself does not regress or hold its lock across I/O or callbacks. No new lock deadlock found.

**F3 — P1: integer-first decoding destroys exact Decimal values near integers.**

[CatalogUnknownFields.swift:94](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-a16539dd528cf8b68/VideoScan/VideoScanCore/Sources/VideoScanCore/CatalogUnknownFields.swift:94) accepts any successful `Int64` decode before trying Decimal. Foundation’s integer slow path can round `"1.0000000000000001"` through Double to `1`, then accept it as an integer. The source explicitly identifies this behavior. [Foundation integer decoder](https://github.com/swiftlang/swift-foundation/blob/swift-6.2-RELEASE/Sources/FoundationEssentials/JSON/JSONDecoder.swift#L915)

That literal is canonical JSONEncoder output from Decimal, with only 17 significant digits. [Foundation Decimal encoder](https://github.com/swiftlang/swift-foundation/blob/swift-6.2-RELEASE/Sources/FoundationEssentials/JSON/JSONEncoder.swift#L1120)

Suggested core red test:

```swift
@Test
func decimalNearIntegerRemainsExact() throws {
    let encoder = JSONEncoder()
    let decimal = try #require(Decimal(string: "1.0000000000000001"))
    let source = try encoder.encode(decimal)
    let value = try JSONDecoder().decode(CatalogJSONValue.self, from: source)
    #expect(try encoder.encode(value) == source)
}
```

The inferred current output is `1`. Validate integer acceptance against the decimal value before selecting `.int`/`.uint`. The remaining-loss statement in `Catalog.md` is consequently incomplete.

**F4 — P2: deferred sibling writes can occur after a newer catalog arrives, including after latching.**

[CatalogStore.swift:668](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-a16539dd528cf8b68/VideoScan/VideoScan/Catalog/CatalogStore.swift:668) advances the sidecar on successful completion without checking the newer latch or current primary.

Concrete reproduction: hold a successful background save after verification but before its main-actor completion; replace the primary with v8, call `noteNewerCatalogOnDisk`, then release completion. `finishWrite` still changes `catalog.generation.max`. A post-verification completion barrier makes this regression deterministic.

The notes marker has the same deferred-write gap: the sole probe precedes the entire records scan, while [VideoScanModel+NotesRepair.swift:93](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-a16539dd528cf8b68/VideoScan/VideoScan/Catalog/VideoScanModel+NotesRepair.swift:93) writes the clean-plan marker without another check. Replace the primary after planning and before marker creation; the marker still appears. Recheck at the sidecar/marker mutation boundaries.

The supplied mutation results are consistent with the existing tests. Mutations I expect would survive, but did not run:

- Move `gate.newerVersion()` before encoding: queue delays precede both operations, and the sensor checks only that the gate precedes `data.write`.
- Remove escaped-key decoding from `slot(forKeyBytes:)`: the scoped fixtures exercise escaped values, not escaped header keys.
- Drop `unknownTopLevel` only from `writeSnapshotAsync`: `everyWritePathPreserves` checks the synchronous snapshot, while async snapshot coverage checks refusal/header behavior.

**Read, no independent findings:** `CatalogGenerationSidecar.swift`, `VideoScanModel+RescanPreservation.swift`, `VideoScanModel+LiveReload.swift`, and `CatalogGenerationProbeTests.swift`. The other scoped files are covered above. Foundation dependency source was consulted for numeric/BOM semantics; no wider repository code was explored.

## Brief

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
