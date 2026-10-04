# Codex review — Delete-safety bundle #258 r6 (final)

- Range: `4cb59b04..fix/258-delete-planner-honours-angel`
- Credits spent: unavailable
- Tokens: 104673
- Finding count: 3
- Verdict: block — three P1 counterexamples remain; under the stop rule, split the bundle.
- Run: 2026-10-04T02:10:06Z (cycle #39, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 3
Verdict: block — three P1 counterexamples remain; under the stop rule, split the bundle.

Reviewed `4cb59b04..1be7dbf2` against `8aa4acde`. The scoped production files are unchanged by the final merge and have no worktree edits. Findings below are source-derived; no new tests were executed in this read-only session. The supplied passing suite and mutant results remain separate evidence.

| Round-5 finding | Result |
|---|---|
| r5-1 — recorded Trash preference | **Closed.** Decision-time value survives phase two and is OR’d with subsequent samples. |
| r5-2 — archive-door bypass | **Closed.** Run rows are excluded before archive insertion and `seenArchive` insertion. |
| r5-3 — legacy retained rows | **Closed.** Every other saved entry enters pending, leftAlone, or decided; all are excluded. |
| r5-4 — unavailable UUID | **Reopened, P1.** Two exceptions still permit protected-volume removal, detailed below. |
| r5-5 — batch symlinks / disconnected buffer | **Closed.** Both routes now return uncertainty and hold. |

1. **P1 — S1 changes sibling proving, so fewer initial candidates can still produce a more permissive removal than main.**

   [DeleteDuplicatesJob.swift:326](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-ace49c157d541ff27/VideoScan/VideoScan/MediaOps/DeleteDuplicatesJob.swift:326) proves additional siblings before gathering the decision facts. The boundary then rechecks each implementation’s resulting evidence at `DeleteDuplicatesPlan.swift:469`; the disposition is selected at `DeleteDuplicatesJob.swift:466`.

   **Concrete S1 reproduction:** resume a legacy plan containing settled retained A and pending B. Verify A again before resume. The family has verified K, A and Review sibling S, plus unverified Review sibling U. S and U occupy a second physical device. Prefer Trash is off.

   | Stage | Main | Branch |
   |---|---|---|
   | Initial survivors | K+A+S: three | K+S: two; A excluded |
   | Sibling proving | Stops at three | Reads U, obtaining three |
   | After B’s ticket save, rewrite A | A’s stamp fails; two remain | A was never counted; three remain |
   | B’s removal | **Trash** | **Permanent**, across two drives |

   Use `testHookAfterQuarantineSaved` for the rewrite. This happens before the final verdict, outside the accepted verdict-to-removal window.

   The whole bundle has a simpler variant without a legacy plan: verified K+S1+S2 on device A, unverified U on device B. Main stops at three; the branch’s F11 behavior reads U, explicitly demonstrated by `DeleteDuplicatesCodex258TierTests.swift:588`. Rewrite S1 after ticket saving: main falls to two and Trashes; branch falls from four to three and permanently deletes.

   **S1 is conservative with fixed evidence. Its universal no-weakening claim is false when candidate exclusion changes which siblings get proved.**

2. **P1 — an external custom mount beneath the Data subtree is incorrectly cleared as a boot mount.**

   [ArchiveVolumeProtection.swift:536](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-ace49c157d541ff27/VideoScan/VideoScan/Archive/ArchiveVolumeProtection.swift:536) accepts every mountpoint beginning `/System/Volumes/`. The new nil-UUID exceptions use this predicate on the raw mountpoint at archive `:464` and [ReadOnlyVolumeProtection.swift:279](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-ace49c157d541ff27/VideoScan/VideoScan/Archive/ReadOnlyVolumeProtection.swift:279).

   **Reproduction:** mark/designate `/Volumes/TestOld` with UUID `TEST-U`, then mount that external filesystem at `/System/Volumes/Data/Users/test/TestExternal`. Let file UUID reads fail while mount identity and file access remain available.

   Neither the old marked path nor its UUID identifies the file. Its distinct external mountpoint nevertheless satisfies the boot-prefix predicate:

   - Read-only verdict: **nil**.
   - Archive verdict: **`.clear`**.

   Minimal red assertions using the existing identity seam:

   ```swift
   let mount = "/System/Volumes/Data/Users/test/TestExternal"
   let file = mount + "/test_copy.mov"
   let identity: (String) -> MountIdentity? = {
       MountIdentity(resolvedPath: $0, mountPoint: mount)
   }

   // Protections retain TEST-U and the old /Volumes/TestOld spelling.
   #expect(readOnly.verdictAtRemoval(
       path: file, probe: { _ in nil }, identity: identity) != nil)
   #expect(archive.verdictAtRemoval(
       path: file, probe: { _ in nil }, identity: identity) == .unprovable)
   ```

   Both assertions fail by source evaluation. The exception must recognize actual boot-volume mount roots, not arbitrary descendants. This is P1 under the protected-drive criterion, independently of baseline weakening.

3. **P1 — “archive resolved” does not prove that the file’s current mount is another volume.**

   [ArchiveVolumeProtection.swift:466](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-ace49c157d541ff27/VideoScan/VideoScan/Archive/ArchiveVolumeProtection.swift:466) returns `.clear` when the snapshot resolved the archive but the file’s current mount is absent from `archiveRoots`.

   **Reproduction:** `make()` resolves UUID `TEST-U` at `/Volumes/TestArchive`. Before `verdictAtRemoval` finishes, that archive is remounted as `/Volumes/TestMoved`. A file reached through an intermediate symlink can retain its path spelling and refer to the same underlying file after the alias is updated. Let its UUID read fail and its fresh mount identity report `/Volumes/TestMoved`.

   The snapshot contains only the old root, but `isResolved` remains true. The actual archive file receives **`.clear`**.

   The deterministic seam assertion is:

   ```swift
   #expect(resolvedSnapshot.verdictAtRemoval(
       path: "/Volumes/TestMoved/test_copy.mov",
       probe: { _ in nil },
       identity: {
           MountIdentity(resolvedPath: $0, mountPoint: "/Volumes/TestMoved")
       }) == .unprovable) // actual: .clear
   ```

   This answers question 3: a stale resolved snapshot suffices; duplicate mounting is unnecessary. The change occurs during final-verdict construction/checking, before the verdict returns. A current UUID mismatch would prove another volume; a different mount spelling plus an earlier `isResolved` does not.

No run-row counting bypass was found in the scoped archive assembly, sibling standing, resume dispatch, or boundary recheck. Forecast/steward callers outside the named scope were not independently inspected. The failure in finding 1 is adaptive proving, rather than an `isRow` bypass.

`ArchiveAngelPlan.swift` and `ArchiveAngel.swift`: **read, no findings**. The changed round-5 tests were read; no separate findings. `MediaOps.md`’s universal S1 conservatism claim is contradicted by finding 1.

The whole-bundle no-weakening check therefore **fails**. This final-round verdict is **block and split**.

## Brief

Scoped data-risk RE-REVIEW (round 6 — FINAL under the stop rule) — delete-safety bundle (GH #258 + Read-only volumes + two-drives rule), 2026-10-03. Range 4cb59b04..fix/258-delete-planner-honours-angel (tip 8aae0e3b; the last commit is a merge of main that brought unrelated features — Footage Spectrum and Steward edits — ignore those files). Round 5: docs/reviews/codex/codex-review-delete-safety-bundle-258-r5-2026-10-03.md (block, 6 findings). Read the branch via `git diff 4cb59b04..1be7dbf2 -- <path>` (branch-only changes), `git show fix/258-delete-planner-honours-angel:<path>`, or the worktree .claude/worktrees/agent-ace49c157d541ff27. Do not check out the branch in ~/dev/VideoScan. Do not explore outside the files below. The "no weakening" baseline is main's behaviour at 8aa4acde.

This is the LAST round. If P1 data-loss findings remain, the bundle will not merge and will be split. Please rate each finding P1 (a file removed that main would keep, or unlinked where main would Trash; or a file on a Read-only / archive drive removed) vs P2/P3 (hardening, wording, conservatism), and give a clear merge verdict if only P2/P3 remain.

Round-5 changes (branch-only, 11 files, +303/−55):
- S1 — the survivor rule was SIMPLIFIED instead of patched: a family member is NEVER counted as a survivor for another row if it is a row of this run in any state (pending, left alone, decided — new or legacy plan) (`VideoScanModel+Duplicates.swift` ~425, `DuplicateRunScope.isRow` ~1366); and a planned row never enters `archiveCopies` (`deletionTierCandidates.noteArchive` ~822, ~835). Survivors are only the keeper and copies that are not rows of this run, judged by main's sibling rules. `notCountedWhy` is now wording only. Claimed strictly more conservative than main.
- r5-1 — `recordedPreferTrash` captured at the decision (`DeleteDuplicatesJob.swift` ~1315); phase two uses recorded || sample (~1361); the final verdict adds the fresh value.
- r5-4 — identity unavailable fails closed: Read-only (`ReadOnlyVolumeProtection.swift` ~275) holds when the file's UUID cannot be read and a mark carries a UUID, except boot/data volume or a non-local (network) mount; Master Archive (`ArchiveVolumeProtection.swift` ~457) with an unreadable file UUID → .clear for boot/network, .onArchiveVolume if the file's mount is an archive root, .clear if the archive was found by UUID and the file is on another mount, else .unprovable.
- r5-5 — a `batch-` symlink is uncertain (`ArchiveAngelPlan.swift` ~645); `bufferIsAbsent` (~675) requires the buffer's /Volumes drive to be a mount point (statfs) after resolving symlinks; leftover mount dir / dangling symlink → uncertain.
- MOPS-2 updated; findings-closed table updated.

Questions:
1. For each of r5-1 .. r5-5: closed, or re-open with a concrete reproduction (file:line; ideally a Swift Testing red test with synthetic data).
2. S1: confirm it is strictly more conservative than main for every input (no input where a copy is removed that main would keep, or unlinked where main would Trash). Find any survivor-assembly path that does NOT go through `isRow` / the archive-door check (forecast, steward proof, resume, removal-boundary recheck).
3. r5-4 Master Archive ".clear if the archive was found by UUID and the file is on another mount": can a file actually ON the archive drive be judged "another mount" (the archive mounted twice, a firmlink, a disk image of the archive, a stale mount table entry)?
4. Whole-bundle no-weakening re-check, now that S1 removes a class of interactions.
5. Anything that makes the bundle unsafe to merge tonight that earlier rounds missed (be specific; do not re-list accepted limits).

Known and accepted (do not report): hardware RAID = one device; two disks in one enclosure presenting as two devices count as two; two network shares on one server disk count as two; multi-store volumes keyed by the one store DiskArbitration reports; the window between the final verdict and unlink(2)/trash; latency of the main-actor hop; keeper election and target eligibility sampled at the turn; Catalog Rename and add-a-file verbs not blocked on a Read-only drive (ruling pending); the Angel's extraCopy exclusion is a switchable policy default; two-real-drives cases through the identity seam; source sensors check textual presence (GH #262, deferred); unprovable archive refusals mark the row Review when the archive drive is disconnected (main's behaviour for /Volumes paths, now extended to custom mounts — deliberate); SwiftLint warnings; gauntlet manifest not regenerated.

Evidence already run (Debug, by suite, counts confirmed nonzero): final run after merging main — 912 Swift Testing tests / 147 suites + 13 XCTest (4 skipped), 0 failures (10 known issues: 2 pre-existing SourceTreeTests, 8 deliberate stripper-refusal). 8 new round-5 tests, all red on 4cb59b04 for the intended reason; 8 mutants, all red. Three existing tests made deliberately stricter, each citing its rule.

Output contract (required):
- First line exactly: Credits spent: <amount> | Finding count: <N>
- A line: Verdict: <merge | fix | block> — <one-line reason>

Privacy: public repo — no real family names, addresses or dates in any suggested fixture.

## Closed

Closed by `rick-ruling-2026-10-04` at 2026-10-04T15:48:57Z. Merged per Rick's ruling (best effort, not perfection); residual edge cases tracked in GH #268.
