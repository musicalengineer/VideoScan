# Codex review — Delete-safety bundle #258 r4

- Range: `8103fcdf..fix/258-delete-planner-honours-angel`
- Credits spent: unavailable
- Tokens: 162514
- Finding count: 3
- Verdict: block — unreadable Angel plans fail open, and new archive-boundary refusals can make later deletions more permissive than the baseline.
- Run: 2026-10-03T23:39:31Z (cycle #37, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 3
Verdict: block — unreadable Angel plans fail open, and new archive-boundary refusals can make later deletions more permissive than the baseline.

Reviewed `8103fcdf..a5ae2c96` and compared the relevant removal behavior with `8aa4acde`, without changing either checkout. Findings below are source-derived. Swift parsing confirmed the sensor counterexamples are valid syntax; Swift test execution was blocked by compiler-cache writes in this read-only session. The supplied passing tests and mutants remain separate evidence.

| Round-3 finding | Result |
|---|---|
| R3-1 | **Closed.** Production facts always rederive drive evidence through the fresh resolver at the verdict. |
| R3-2 | **Reopened.** Cache bypass is fixed, but an unreadable plan or failed directory listing still becomes “no hold.” |
| R3-3 | **Reopened.** Ordinary nested block comments are stripped; raw strings, interpolation and regex literals can still conceal real comments from the stripper. |

1. **P1 — J/K: a newly protected copy becomes a countable survivor, violating no-weakening for a later row.**

   The new [archive-boundary refusal at DeleteDuplicatesJob.swift:399](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-ace49c157d541ff27/VideoScan/VideoScan/MediaOps/DeleteDuplicatesJob.swift:399) returns before asking the hold boundary. It settles as an ordinary archive refusal and marks the record Review. [DeleteDuplicatesPlan.swift:832](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-ace49c157d541ff27/VideoScan/VideoScan/MediaOps/DeleteDuplicatesPlan.swift:832) excludes only recognized hold/Read-only notes; the archive-refused row enters `scope.decided`. `duplicateSurvivorStandingRule` then permits it under the sibling rules.

   **Concrete reproduction against `8aa4acde`:**

   - Use identical synthetic files K, A, B, S1 and S2. K is Keep; A and B are Extra copies, planned in that order; S1 and S2 are verified Review siblings. Place S1 on a second physical device through the identity seam.
   - Start with no Master Archive designation. A’s captured archive check therefore permits it. Its survivors are K, S1 and S2.
   - After A’s quarantine ticket is saved, pause further dispatch and designate A’s volume as Master Archive.
   - On the branch, the new boundary refuses A and restores it. On the baseline, the captured check permits A’s removal.
   - At the pause boundary, remove the designation and move S2 out of its catalogued path. Verify A again if it remains, so its restored stamp has current fixity.
   - Resume B.

   **Branch:** K + S1 + retained A give three verified survivors on two devices → **permanent deletion of B**.  
   **Baseline:** A is gone; K + S1 give two → **Trash B**.

   Removing S1 as well yields another counterexample: branch Trashes B using K + A, while baseline leaves B alone.

   This is a between-row difference, not the accepted verdict-to-unlink window. A regression should extend the existing late-designation test through a second row and assert that the newly retained A cannot increase B’s deletion tier. Preserve the baseline treatment of older ordinary archive refusals separately.

   **J cannot be confirmed as stated.** Captured Read-only refusals correctly become hold skips. A captured archive refusal—including one whose designation was removed mid-pair—remains countable. If an Angel or Read-only hold also exists, the earlier archive return prevents its classification. The captured archive behavior predates this round; the **new fresh archive refusal creates the baseline divergence above**.

2. **P1 — R3-2: unreadable buffer evidence authorizes removal.**

   [ArchiveAngelPlan.swift:604](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-ace49c157d541ff27/VideoScan/VideoScan/ArchiveAngel/Prepare/ArchiveAngelPlan.swift:604) calls `listBatches`, which returns only `scanBatches(...).plans`. Decode failures are collected as `unreadable` and discarded by this route. At line 655, a directory-listing failure returns two empty arrays.

   The façade consequently answers `false`, and `removalBoundaryHold` can return `nil`.

   **Reproduction:** let the turn-time pre-check pass with an empty buffer. During phase two, create a `batch-` folder containing a partial or unreadable `plan.json`. Leave the façade’s published set and in-memory Prepare sets empty. At the boundary, the folder is recognized as unreadable but contributes no hold; otherwise eligible removal proceeds.

   A predicted red test using the existing hold-boundary rig is:

   ```swift
   @Test func anUnreadableBatchRefusesTheRemovalBoundary() async throws {
       let rig = makeRig("unreadable")
       defer { rig.cleanup() }

       let copy = rig.copies[0]
       let ask = DeleteDuplicatesJob.removalBoundaryHold(
           model: rig.model, recordID: copy.id, path: copy.fullPath)
       let path = copy.fullPath

       #expect(await Task.detached { ask(path) }.value == nil)

       let batch = rig.environment.bufferRoot
           .appendingPathComponent("batch-partial", isDirectory: true)
       try FileManager.default.createDirectory(
           at: batch, withIntermediateDirectories: true)
       try Data("{".utf8).write(
           to: batch.appendingPathComponent("plan.json"))

       #expect(await Task.detached { ask(path) }.value != nil)
   }
   ```

   The fresh reader needs an explicit uncertainty result that the boundary converts into a hold or refusal. Logging and retaining the damaged batch folder do not protect its possible source records.

   For **readable** changed plans, the cache fix is sound: the boundary decodes content again, and a pre-check pass cannot override a fresh hold. A batch created **after** the fresh reading remains within the accepted final-check window.

3. **P2 — R3-3: the unsupported syntax can make sensors less strict.**

   [SourceTree.swift:151](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-ace49c157d541ff27/VideoScan/VideoScanTests/SourceTree.swift:151) copies everything while `inString` is true and does not parse interpolation. Raw-string and regex delimiters can also leave that state incorrectly active.

   These are valid Swift statements whose **real comments retain the expected call text**:

   ```swift
   let _ = #"a"b"# /* boundaryHold(ticket.quarantinedPath) */
   let _ = "\(/* boundaryHold(ticket.quarantinedPath) */ 0)"
   let _ = #/"/# /* boundaryHold(ticket.quarantinedPath) */
   ```

   The raw-string example also works with a trailing `//` comment. A direct state-machine reproduction retained the comments; ordinary nested block comments were removed.

   **Concrete surviving principle-sensor mutation:**

   ```swift
   nonisolated static func inFlightRecordIDsFresh(
       bufferRoot: URL, now: Date = Date()
   ) -> Set<UUID> {
       let _ = #"a"b"# /* listBatches(bufferRoot: bufferRoot) */
       return inFlightRecordIDsCached(bufferRoot: bufferRoot, now: now)
   }
   ```

   The sensor’s extracted fresh-reader body still contains `listBatches(bufferRoot: bufferRoot)` and contains no `holdReadings`, satisfying its checks while returning cached content. The same raw-string prefix can preserve a commented-out bulk-gate call before the Trash site.

   Therefore **“can only make a sensor stricter” is false for all three named unsupported constructs**. Add stripper regressions for these inputs and either parse Swift lexical structure correctly or reject unsupported syntax in sensor regions.

**H — the six fresh readings do not constitute the entire authorization.**

| Other input | Could staleness be more permissive than a fresh decision? |
|---|---|
| Keeper election and target eligibility | **Yes, for policy changes.** They are authorized at the turn, rather than fully reauthorized at removal. The existing identity gate still protects the particular files. This sampling behavior is unchanged from baseline. |
| Plan row’s stored digest/tier | The stored digest does **not** authorize resumed removal: recovery precedes fresh verification. The recorded tier is reused when evidence remains unchanged. |
| Duplicate’s own identity | Ticket-bound evidence travels through the existing `SignatureVerification` gate. The scoped change introduces no alternate identity-free removal route. |
| Survivor fixity digests | Earlier digests remain evidence only while their complete stamps reproduce. Boundary re-stat can drop copies; it does not add newly verified copies. |
| Survivor-standing inputs | The run snapshot can retain outdated pending exclusions, which is conservative. Newly archive-refused rows becoming countable are finding 1. |
| Archive-copy classification | Classification flags/paths are captured earlier. Declassifying a survivor could make that metadata more permissive than a fresh classification. Removing the designation alone does not necessarily erase promoted-copy provenance. |
| `preferTrash` | **Yes.** It is sampled before phase two. Moreover, unchanged evidence returns `recorded` without reconsidering the setting, even if the post-save sample became true. This behavior also exists in the baseline. |

Thus the implemented freshness guarantee covers the six specified readings; it is not full live reauthorization of every policy input. The additional sampling limitations above are distinguished from the new baseline regression.

**I — no scoped circular wait found; latency is not bounded.** Disk phases are awaited asynchronously. Pause, cancel, `stopForQuit`, quit polling and Angel refresh do not synchronously wait on the worker from main. The two `DispatchQueue.main.sync` hops can nevertheless wait behind busy or modal main-thread work, and cancellation does not interrupt the hop itself. The application’s termination entry point is outside this scope, so this is not a whole-app deadlock certification.

Using the supplied measurements, removal overhead is approximately **96 ms for that buffer + 0.14 ms per distinct volume + two main-queue turns + protection construction and survivor stats**. Main-queue latency was not measured here. At 100,000 removals, the buffer component alone is approximately **2 h 40 min** under the measured conditions.

**R3-1 details:** the verdict’s memo is keyed by freshly statted `st_dev`, so simultaneous distinct mounted filesystems do not share an entry merely because their physical device is the same. Multiple spellings of one filesystem appropriately share it. Production `gather` supplies a nonnil generation; nil-generation hand-built/seamed facts are not used by the scoped production removal caller. Resume restores and re-verifies before ordinary dispatch. Fresh unknown identities add no drive. A changed drive-key set triggers tier redecision in either direction, including Trash → permanent.

**K:** no-weakening fails by finding 1. I found no independent drive-rederivation counterexample.

Scoped sections **read, no findings**:

- `DeleteDuplicatesDrives.swift`
- `ArchiveAngel.swift` — no independent finding beyond consuming the unreadable-buffer result
- `docs/practices/invariants/MediaOps.md`
- `DeleteDuplicatesCodex258Round3Tests.swift`
- `DeleteDuplicatesCodex258HoldBoundaryTests.swift`
- `DeleteDuplicatesCodex258Round2Tests.swift`
- `DeleteDuplicatesPhysicalDriveTests.swift`

`DeleteDuplicatesJob.swift`, `DeleteDuplicatesPlan.swift`, `VideoScanModel+Duplicates.swift`, `ArchiveAngelPlan.swift`, and `SourceTree.swift` were read; their findings are identified above.

## Brief

Scoped data-risk RE-REVIEW (round 4) — delete-safety bundle (GH #258 + Read-only volumes + two-drives rule), 2026-10-03. Range 8103fcdf..fix/258-delete-planner-honours-angel (tip a5ae2c96). Round 3: docs/reviews/codex/codex-review-delete-safety-bundle-258-r3-2026-10-03.md (block, 3 findings; R2-1, R2-2, R2-4 closed). The branch is NOT checked out in ~/dev/VideoScan: read it with `git diff 8103fcdf..fix/258-delete-planner-honours-angel -- <path>`, `git show fix/258-delete-planner-honours-angel:<path>`, or the worktree at .claude/worktrees/agent-ace49c157d541ff27. Do not check out the branch in ~/dev/VideoScan. Do not explore outside the files below. The "no weakening" baseline remains main's behaviour at 8aa4acde.

The round-3 fixes rest on ONE principle, now the opening of MOPS-2 and pinned by a code-only sensor (`theFinalVerdictCallsOnlyTheFreshEntryPoints`):
  AT THE FINAL VERDICT IMMEDIATELY BEFORE A REMOVAL, NOTHING COMES FROM A CACHE. Read fresh there: (1) each counted copy's stamp (re-stat); (2) each counted copy's and the keeper's PHYSICAL DEVICE via `liveIdentityFresh` (statfs + one DiskArbitration description, cache neither read nor written; once per distinct volume within a verdict) — the tier is re-decided from fresh evidence in either direction; (3) the Angel's buffer — every plan.json read and decoded on the disk thread (`inFlightRecordIDsFresh`); (4) the Angel's in-memory state through a synchronous hop to the main actor; (5) the Read-only marks as the scan targets carry them now, protection built on the disk thread, removal-time check on path / real path / the file's own volume UUID; (6) the Master Archive designation, read through a synchronous main-actor hop, protection built on the disk thread, same removal-time check. Caches (`liveIdentityCached`, `inFlightRecordIDsCached`, the model's protection snapshots) serve only forecasts, displays and the advisory per-turn pre-checks. The check captured at the copy's turn is STILL asked first as an extra that can only refuse.

Files in scope:
- VideoScan/VideoScan/MediaOps/DeleteDuplicatesJob.swift — the final verdict (~379–399), `removalBoundaryHold` (~1498), `removalBoundaryArchiveCheck` (~1545), the two synchronous main-actor hops
- VideoScan/VideoScan/MediaOps/DeleteDuplicatesPlan.swift — `recheck` (~469–490), fresh Resolver
- VideoScan/VideoScan/MediaOps/DeleteDuplicatesDrives.swift — `liveIdentityFresh` (~304), `liveIdentityCached` (~316), resolver (~186)
- VideoScan/VideoScan/MediaOps/VideoScanModel+Duplicates.swift (~341–356: current marks and current designation for the boundary)
- VideoScan/VideoScan/ArchiveAngel/Prepare/ArchiveAngelPlan.swift (~572 fingerprint incl. ctime, ~604 `inFlightRecordIDsFresh`, ~612 `…Cached`), ArchiveAngel/Facade/ArchiveAngel.swift (~569)
- VideoScan/VideoScanTests/SourceTree.swift (~119: comment stripper — `//`, nested `/* */`, string literals left alone)
- docs/practices/invariants/MediaOps.md (MOPS-2)
- Tests: VideoScanTests/DeleteDuplicatesCodex258Round3Tests.swift (new), DeleteDuplicatesCodex258HoldBoundaryTests.swift, DeleteDuplicatesCodex258Round2Tests.swift, DeleteDuplicatesPhysicalDriveTests.swift

Answer, per round-3 finding, "closed" or re-open with a concrete reproduction (file:line; ideally a Swift Testing red test with synthetic data):
R3-1 — stale drive topology before the mount notification: the final verdict now derives every counted copy's device with an uncached lookup. Attack: any path to an OUTRIGHT delete whose drive evidence did not pass through `liveIdentityFresh` at the verdict (other callers of `recheck`; the resume path; a verdict that skips re-derivation when the tier is already Trash and is then upgraded; "once per distinct volume within a verdict" — keyed by what, and can two copies on different volumes share a memo entry); fresh lookup failure (unknown) must not ADD a drive.
R3-2 — the Angel buffer cache concealing a changed plan: the boundary reads content uncached. Attack: any removal path that still consults `…Cached` for a hold decision that AUTHORIZES removal (the per-turn pre-check is advisory — confirm a copy that the pre-check passes is still stopped at the boundary when the fresh reading holds it); partially written / unreadable plan.json at the boundary (must hold or refuse, never "no hold"); a batch folder created between the fresh read and the unlink (accepted final-check window — say so).
R3-3 — block comments defeating code-only sensors: stripper extended. Name any construct that still lets a commented-out call satisfy `theFinalVerdictCallsOnlyTheFreshEntryPoints` or the bulk-verb sensor (the agent lists as not handled: raw strings with an unescaped quote, comments inside string interpolation, regex literals — "can only make a sensor stricter"; confirm or refute).

Also:
H. The principle as implemented: is there ANYTHING the final verdict uses to authorize a removal that is not in the list of six — e.g. the keeper election, the plan row's stored digest, the duplicate's own identity, the survivor-standing rule's inputs (which rows of this run are decided / left alone — in-memory, current?), `preferTrash`? For each, say whether staleness could make a removal MORE permissive than a fresh read would.
I. The two synchronous main-actor hops from the disk thread per removal (holds/marks; archive designation): deadlock or starvation with pause, cancel, stopForQuit, app termination, a modal alert on main, or the Angel's refresh; cost per removal (measured: fresh buffer reading 96 ms for 50 batches × 100 rows; fresh volume lookup 0.14 ms).
J. The captured turn-time check "asked first, can only refuse": confirm it cannot convert a hold into an ordinary refusal that is then COUNTED as a survivor for another copy (the R2-1 class), including when the archive designation was removed mid-pair (the stale check still refuses that one file — is that refusal classified so that the copy is not counted?).
K. No-weakening re-check for the whole bundle after these changes: any input where the branch removes what main@8aa4acde would leave or refuse, or unlinks what main would Trash.

Known and accepted (do not report): hardware RAID = one device; two disks in one enclosure presenting as two devices count as two; two network shares on one server disk count as two; multi-store volumes (Fusion / CoreStorage / multi-store APFS) keyed by the one store DiskArbitration reports — documented limit (you confirmed last round); the window between the final verdict and unlink(2)/trash; Catalog Rename and add-a-file verbs not blocked on a Read-only drive (ruling pending); the Angel's extraCopy exclusion is a switchable policy default pinned by a guard test; two-real-drives cases go through the identity seam; the mount observer's generation bump is no longer load-bearing (its sensor retired); SwiftLint warnings; gauntlet manifest not regenerated; older sensors outside these suites read raw source.

Evidence already run (Debug, by suite, counts confirmed nonzero): final full run on a5ae2c96 — 991 Swift Testing tests / 173 suites + 13 XCTest (4 skipped), 0 failures (every *Sensor*/*Boundary* suite; delete, read-only, steward, angel, triage suites; PruneApplyTests; WorkbenchActionsTests; SourceTreeTests with 2 pre-existing known issues). Round-3 fixes: 3 finding tests red on 8103fcdf before any fix; 9 mutants all red (one — pointing the boundary's buffer probe back at the cached reader — caught only by the principle sensor); the Master Archive freshness test red on 6a3574fa, 2 mutants red. Two former sensor-only branches now have behaviour tests (phase two's captured check holds a Read-only file; the forecast's resolver follows a file symlink onto another volume).

Output contract (required):
- First line exactly: Credits spent: <amount> | Finding count: <N>
- A line: Verdict: <merge | fix | block> — <one-line reason>

Wanted: "closed"/re-opened per R3-1..R3-3; findings for H–K ranked by data-loss risk; "read, no findings" per clean file. Privacy: public repo — no real family names, addresses or dates in any suggested fixture.
