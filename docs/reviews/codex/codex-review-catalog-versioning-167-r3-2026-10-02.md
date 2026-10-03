# Codex review — #167 catalog versioning r3

- Range: `b912eb4d..feat/167-catalog-versioning`
- Credits spent: unavailable
- Tokens: 113712
- Finding count: 4
- Verdict: fix — the scanner can still permit replacement despite a later newer stamp, and two sibling-write paths bypass the requested hold policy.
- Run: 2026-10-03T01:25:16Z (cycle #30, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 4
Verdict: fix — the scanner can still permit replacement despite a later newer stamp, and two sibling-write paths bypass the requested hold policy.

Reviewed `c283af00` in the supplied worktree; scoped files have no uncommitted changes. Main was untouched. Reproductions below are source-derived; I did not rerun Swift tests in this read-only session.

1. **Cycle #29 F1 — finding R1, P1: early termination defeats duplicate-stamp protection and malformed-file refusal.**

   [CatalogHeaderScanner.swift:159](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-a16539dd528cf8b68/VideoScan/VideoScan/Catalog/CatalogHeaderScanner.swift:159) stops consuming bytes once both stamps are found. Thus:

   ```json
   {"version":7,"generation":0,"records":[],"version":8}
   ```

   returns `.version(7)`, permits `saveNow(records: [])`, and loses the later stamp. The `max` in `endCapture` never sees it. Across windows, [line 363](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-a16539dd528cf8b68/VideoScan/VideoScan/Catalog/CatalogHeaderScanner.swift:363) also keeps an existing head version instead of merging a higher tail version.

   The same early exit permits truncated or trailing-garbage files with an older header. Separately, `.confirmedAbsent` does **not** prove a completely parsed object: `{"records":]` reaches it because [line 264](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-a16539dd528cf8b68/VideoScan/VideoScan/Catalog/CatalogHeaderScanner.swift:264) treats either closing delimiter as closing the root.

   Suggested red test in `CatalogVersioningTests.swift`, using its existing helpers:

   ```swift
   @Test(arguments: [
       #"{"version":7,"generation":0,"records":[],"version":8}"#,
       #"{"version":7,"generation":0,"records":["#,
       #"{"version":7,"generation":0,"records":[]} garbage"#,
       #"{"records":]"#
   ])
   @MainActor
   func unsafeCatalogIsNotReplaced(_ text: String) throws {
       let dir = scratch("unsafe_header")
       defer { try? FileManager.default.removeItem(at: dir) }
       try Data(text.utf8).write(to: catalogURL(dir))
       let before = everyFile(dir)
       let header = try #require(CatalogSnapshot.header(at: catalogURL(dir)))
       #expect(CatalogWriteHold.from(header.version) != nil)
       #expect(!CatalogStore(directory: dir).saveNow(records: []))
       #expect(everyFile(dir) == before)
   }
   ```

   All four cases currently fail the expected hold. The explicit `.unknown → .versionUnknown` conversion is closed; producing the correct verdict remains incomplete.

2. **Cycle #29 F1 — finding R2, P2: a successful decode bypasses the scanner’s unknown hold during load.**

   [CatalogStore.swift:1010](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-a16539dd528cf8b68/VideoScan/VideoScan/Catalog/CatalogStore.swift:1010) proceeds to sidecar persistence, reconciliation, and `.prev` rotation after decoding an older/current version, without adopting the scanner’s `.unknown` verdict.

   Concrete reproduction: write UTF-16 LE BOM plus `{"version":7,"generation":0,"records":[]}`, seed a distinct `.prev`, and leave the generation sidecar absent. Assert:

   ```swift
   #expect(CatalogSnapshot.header(at: catalogURL(dir))?.version == .unknown)
   let before = everyFile(dir)
   _ = store.load()
   #expect(store.writeHold == .versionUnknown)
   #expect(everyFile(dir) == before)
   ```

   The last two assertions fail: `load()` creates the sidecar and replaces `.prev`; a subsequent save then discovers `.unknown` and holds.

   The full decode establishes that this particular file is current, so this is not a demonstrated newer-primary downgrade. It does violate the requested “unknown means no sibling writes” policy and gives load/save inconsistent treatment. Either honor the hold during load or explicitly define authoritative decoding as resolving it.

   **Requested decision table:** “held” below excludes the permitted refusal journal and advisory lock.

   | Input | Actual verdict → hold | Writes |
   |---|---|---|
   | UTF-8 BOM + valid v8 object | `.version(8)` → newer | Held |
   | UTF-16 BOM | `.unknown` → unknown | Gates hold; successful current/older **load writes siblings** (R2); decoded newer load holds |
   | Empty file | `.unknown` → unknown | Held |
   | Truncated object without a readable stamp | `.unknown` → unknown | Held |
   | Truncated object after v7 header | `.version(7)` → none | Replacement permitted (R1) |
   | Array root | `.unknown` → unknown | Held |
   | Trailing bytes without a stamp | `.unknown` → unknown | Held |
   | Trailing bytes after v7 header | `.version(7)` → none | Replacement permitted (R1) |
   | String-valued version | `.unknown` → unknown | Held |
   | Non-integer version | `.unknown` → unknown | Gates hold; an integral spelling accepted by full decoding can enter R2 |
   | Duplicate versions | Highest **visited**, not necessarily highest present | Later higher stamp can be overwritten (R1) |
   | Version only inside a nested object, otherwise valid | `.confirmedAbsent` → none | Normal upgrade writes permitted |
   | Version >4 KB from both ends | Whole pass → `.version(n)` | Newer holds; current/older permitted |
   | Directory at `catalog.json` | `nil` → none | Live write attempts and fails with EISDIR; sibling writers are not held |
   | Existing file whose open fails with EACCES | `.unknown` → unknown | Held; no primary write attempted |

   If inaccessible parent permissions make `fileExists` return false, the path takes the missing-file branch; an attempted write must report its filesystem failure honestly.

3. **Cycle #29 F4 — finding R3, P2: the observer still permits a deferred manifest write after holding the sidecar.**

   The sidecar check and both notes-marker boundary checks are **closed**. However, [CatalogStore.swift:1548](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-a16539dd528cf8b68/VideoScan/VideoScan/Catalog/CatalogStore.swift:1548) calls the observer whenever the earlier save succeeded, even after `finishWrite` discovers a newer/unknown replacement and refuses the sidecar. The acknowledged path does the same at [line 1466](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-a16539dd528cf8b68/VideoScan/VideoScan/Catalog/CatalogStore.swift:1466).

   Reproduction: extend `finishWriteDiscoversNewerPrimary` by installing a counting `CatalogStoreObserver` after parking the landed save. Replace the primary, release completion, and expect zero callbacks. Actual result: one.

   **Yes, manifest refresh is another deferred sibling write.** Hashing the actual disk bytes avoids a stale-payload checksum, so no catalog-content loss is demonstrated. It still breaks CAT-3’s stated restriction on which siblings may change while held. Gate the notification for all successful completions, independently of whether the generation floor needs advancing. I did not inspect `CatalogSync.swift`.

4. **Questions 6–7 — finding R4, P3: the test pin establishes a narrower bound than the documentation claims.**

   [CatalogVersioningTests.swift:1384](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-a16539dd528cf8b68/VideoScan/VideoScanTests/CatalogVersioningTests.swift:1384) proves one scan for repeated refusals against a roughly 12 KB **unknown** file. It supplies neither a production-scale fixture nor a time budget.

   A valid v0 object larger than both windows, with `generation:999`, causes repeated stale-generation refusals and repeated whole-file passes without latching. A successful v0 save can also scan twice before canonicalization: precondition, then write-queue gate.

   **Main-thread blocking exists:** [CatalogStore.swift:744](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-a16539dd528cf8b68/VideoScan/VideoScan/Catalog/CatalogStore.swift:744) and `refuseIfNewerCatalogOnDisk()` invoke the synchronous whole-file scanner on the main actor. Constant memory does not bound UI latency. Lock-held live saves are a useful exception: lock acquisition refuses **before** this probe.

   Add a scaled fixture with an explicit latency budget, and narrow the “once per session” claim to the scenario actually pinned.

**Question 2 / cycle #29 F2 — closed.** The post-probe mirror read honors a completed latch raised during probing. `latchWrites(off:)` means turning writes off; it does not clear the latch. Main state is assigned before the mirror, but there is no suspension or callback between them, and other main-actor callers cannot observe that intermediate state. Mirror-ahead disagreement is conservative. No additional finding beyond the accepted final-check/write window.

**Question 4 / cycle #29 F3 — closed.** Decimal-first plus equality validation fixes near-integer rounding. Canonical integers remain integer spellings (`5 → 5`); negative zero retains its sign. No additional loss found for the requested integer extremes, near-integers, `1e-128`, `1.5e300`, or decimals within the accepted precision boundary.

**Question 5 — two-line judgment:**

Holding preserves potentially salvageable or newer primary bytes instead of replacing them with an older backup.  
For a known interrupted zero-byte copy, automatic recovery can restore availability and preserve buffered edits; holding requires restoration **and relaunch**, so it is not strictly safer in every case.

**Question 7 — additional mutation predictions, not executed:**

- Make only the write-queue gate permit `.unknown`, leaving `CatalogWriteHold.from` unchanged. The unknown fixtures refuse before queueing; the queued replacement tests exercise newer versions.
- Replace duplicate-stamp `max` with “keep first.” The scoped fixtures do not test duplicates.
- Remove the dirty-plan marker’s final re-check. The new `testAfterPlan` fixture exercises the clean-plan branch.

The escaped-key fixture now proves itself: it constructs the backslash by character code, checks the escaped length and absence of the plain key, and confirms Foundation decodes it. The encoding-order pin and async-snapshot preservation assertions are sound.

**Read, no independent findings:** `VideoScanModel+NotesRepair.swift`, the scoped banner changes in `VideoScanModel.swift`, `CatalogUnknownFields.swift`, and `CatalogJSONValueExactNumberTests.swift`. CAT-7 is correctly implemented; CAT-3 needs the exceptions above resolved or documented.

## Brief

Scoped data-risk RE-REVIEW (round 3, final) — polite catalog versioning (GH #167), 2026-10-02. Range b912eb4d..feat/167-catalog-versioning (tip c283af00; 7 commits closing the 4 findings of cycle #29, docs/reviews/codex/codex-review-catalog-versioning-167-r2-2026-10-02.md). The branch is NOT checked out in ~/dev/VideoScan: read it via `git diff b912eb4d..feat/167-catalog-versioning`, `git show feat/167-catalog-versioning:<path>`, or the worktree at .claude/worktrees/agent-a16539dd528cf8b68. Do not check out the branch in ~/dev/VideoScan. Do not explore outside the files below.

Files in scope:
- VideoScan/VideoScan/Catalog/CatalogHeaderScanner.swift (rewritten) — `CatalogVersionVerdict {.version(n) | .confirmedAbsent | .unknown}`, `Found.verdict`, BOM skip, versionKeySeen/complete/aborted, trailing-bytes = aborted, non-integer version = unknown, duplicate stamps keep the higher, `wholeFilePasses` counter
- VideoScan/VideoScan/Catalog/CatalogStore.swift — `CatalogSnapshot.header(at:)`, `CatalogWriteHold {.newerVersion | .versionUnknown}` + `CatalogWriteHold.from(verdict)`, `CatalogNewerLatchMirror.hold`, `CatalogWriteGate.writeHold()` (post-probe mirror re-read), `latchWrites(off:)`, `pauseNotice`, writePrecondition / refuseIfNewerCatalogOnDisk / adoptOnDiskGenerationAfterReconcile / load() undecodable branch, `finishWrite` + `sidecarMayAdvance()`, encodeAndWrite ordering (encode → gate.writeHold() → data.write), test seams `testAfterProbe` / `testAfterVerifyBeforeCompletion`
- VideoScan/VideoScan/Catalog/VideoScanModel+NotesRepair.swift — boundary re-check before the clean-plan marker; `testAfterPlan`
- VideoScan/VideoScan/Model/VideoScanModel.swift — applyCatalogVersionPause via pauseNotice / writeHold (banner text for the unreadable case)
- VideoScan/VideoScanCore/Sources/VideoScanCore/CatalogUnknownFields.swift — Decimal-first number decoding
- docs/practices/invariants/Catalog.md (CAT-3, CAT-7, remaining-loss statement)
- Tests: VideoScan/VideoScanTests/CatalogVersioningTests.swift section 7 (CatalogVersionUnknownRefusesTests, CatalogGateLatchDuringProbeTests, CatalogDeferredSiblingWritesTests, escapedHeaderKeysRecognised, writeEntryPointsAreLatched ordering pin, everyWritePathPreserves async-snapshot assertion), VideoScanCore/Tests/VideoScanCoreTests/CatalogJSONValueExactNumberTests.swift

Questions, in priority order — answer each "closed" or a finding:
1. Cycle #29 F1 — is `.unknown` ever mapped to a writable state anywhere (any gate, any path, any default)? Enumerate the verdict decision table: BOM (UTF-8), UTF-16 BOM, empty file, truncated object, array root, trailing bytes, string-valued version, non-integer version, duplicate version keys, version only in a nested object, version > 4 KB from both ends, a DIRECTORY at catalog.json, unreadable (EACCES). For each: verdict → hold → which writes happen (expect: none beside the catalog for newer/unknown; EISDIR/EACCES fail honestly). Is `.confirmedAbsent` reachable ONLY when the whole top-level object parsed completely with no version key?
2. Cycle #29 F2 — `writeHold()` re-reads the mirror after the probe; can the main-actor latch and the mirror still disagree in a way that permits a write (ordering of `latchWrites` vs mirror update; latch cleared via `latchWrites(off:)` while a queued write is between probe and rename)?
3. Cycle #29 F4 — `sidecarMayAdvance()` and the notes-repair re-check: any remaining deferred sibling write after a newer/unknown primary (sidecar, marker, .prev, catalog.pre-*)? Specifically assess `observer?.catalogStoreDidWrite(self)` (CatalogSync manifest.sha256 refresh) firing after a landed save when `sidecarMayAdvance()` found the primary replaced — is that a sibling write of the same class, and does it matter (it hashes what is on disk)? CatalogSync.swift itself is OUT of scope; judge only whether the call site in CatalogStore should be gated.
4. Cycle #29 F3 — Decimal-first: can `encode(decode(x)) ≠ x` for any canonical JSONEncoder number output now (Int64/UInt64 extremes, near-integers like 1.0000000000000001, -0, 1e-128, 1.5e300, 38-digit decimals)? Does Decimal-first ever turn a canonical INTEGER literal into a non-integer spelling (e.g. 5 → 5.0) or change -0?
5. Behaviour change to judge, not just verify: a corrupt / truncated / EMPTY catalog.json used to be silently rewritten from .prev on the next save; it now HOLDS saving for the session with its own banner and asks the user to restore from .prev. Is holding strictly safer in every case, or is there a case (e.g. 0-byte file left by an interrupted copy) where the old behaviour protected data better? State the trade-off in two lines; Rick decides.
6. Perf bound: the (size,mtime,inode) probe cache was declined because every verdict that would re-run the whole-file pass either latches the session or is followed by a canonical save. Residual: a v0 file whose save is refused for ANOTHER reason (lock held, stale generation) re-scans per attempt. Is `wholeFilePassRunsOncePerSession` an adequate pin? Any main-thread blocking from the whole-file pass in `writePrecondition` / `refuseIfNewerCatalogOnDisk` (main-actor preconditions)?
7. Test adequacy: name any mutation you believe survives (the agent killed 10/10 including the three you predicted last round; the escaped-key test was rebuilt after its first version proved vacuous — check the fixture proves itself).

Known and accepted (do not report): microsecond probe→rename window (rename unconditional); exponent-form numbers come back in JSONEncoder spelling (value exact); >38 significant digits keep 38; SwiftLint length/complexity warnings; OUT OF SCOPE and already filed (#250): Relocate pre-snapshot, ArchiveLockJob marker, DateInference sidecars, viewer-mode .prev rotation/sidecar.

Evidence already run (Debug, by suite, counts confirmed nonzero): red commit c1bc7986 — app 11 tests / 4 suites, 76 issues; core 7 tests, 5 issues (control green). After fixes: #167 set 69 Swift Testing / 17 suites + 18 XCTest, 0 failures; broad catalog regression 2098 Swift Testing / 317 suites + XCTest 18/31/49, 0 failures; VideoScanCore swift test 850 / 138 suites + 228 XCTest, 0 failures (9 pre-existing known issues). Mutations 10/10 killed: F1a BOM skip → red 2; F1b .unknown→nil → red 59; F1c aborted→confirmedAbsent → red 52; F2 post-probe re-read removed → red 3; F3 Int64-first restored → core 5 / app 1; F4a sidecarMayAdvance→true → red 5; F4b post-plan re-check removed → red 4; predicted-surviving #1 encode/gate order → red 1; #2 escape decoding → red 1; #3 async snapshot unknownTopLevel → red 2.

Output contract (required):
- First line exactly: Credits spent: <amount> | Finding count: <N>
- A line: Verdict: <merge | fix | block> — <one-line reason>

Wanted: findings with file:line + a concrete reproduction (ideally a Swift Testing red test with synthetic data), "closed" per cycle-#29 finding, and your two-line judgement on question 5. Privacy: public repo — no real family names, addresses or dates in any suggested fixture.
