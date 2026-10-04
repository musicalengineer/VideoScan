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
