# Codex brief: P0 purge fix, second verify pass (2026-10-23; Rick approved this pass)

**Answer contract.** First line: `Credits spent: <amount> | Finding count: <N>`. A line `Verdict: <merge | fix | block> …`. Write no files; answer only. Under ~700 words.

**Range:** `4c7810861..868c8d2ae` (branch `worktree-agent-a8bd550582aa69e8e`). One code commit. It answers your cycle #124 (3 findings on `3197ef431`). The closure table is in `docs/reviews/codex/codex-review-p0-purge-relation-verify-2026-10-23.md`.

## Workflow in one sentence
A rescan replaces an old catalog row with a fresh one; the old row may go only when the fresh row is actually stored (or held awaiting its full hash).

## What changed
1. (#124 F1) `CatalogCommitBody.replace`: after ALL of a group's snapshots, the purges stand only if `storedRecordPresent(B)`; otherwise the whole group rolls back, A is `keptForReplacement`, B's undone snapshots report refused.
   **`storedRecordPresent` was widened**: it used to require `removal_state IS NULL`; it now accepts any `files` row EXCEPT one carrying the purge marker, plus an un-purged pending row. Reason: a rescan's fresh record inherits a Trash/missing marker, and the old check would have kept A forever.
2. (#124 F2) `CatalogCommitter.purge` reconciles kept relations over every id a door names BEFORE filtering to stored ids (`reconcileKept`): B→C retargets A→C; a plain purge of B releases A's dependency and request — A is NOT purged on B's account, it stays live and `KEPT <A> …` is logged. `noteUnresolved` names a replacement that left memory without a door's purge.
3. (#124 F3) `incidentShapeLosesNothing` adds pending predecessors and two-snapshot refusals; counts 100 written / 100 held / 200 refused rows / 100 kept / 100 `.purged(revision: 1)` / 100 `.pendingPurged`.

## Files in scope (do not explore outside them)
- `VideoScan/VideoScanCore/Sources/VideoScanCore/Commit/CatalogCommitBody.swift`
- `VideoScan/VideoScanCore/Sources/VideoScanCore/Store/GRDBCatalogRepository+LivePending.swift`
- `VideoScan/VideoScanCore/Sources/VideoScanCore/Store/CatalogRepository.swift`
- `VideoScan/VideoScan/Catalog/CatalogCommitter.swift`
- Tests: `VideoScan/VideoScanCore/Tests/VideoScanCoreTests/Store/CatalogCommitRelationTests.swift`, `VideoScan/VideoScanTests/CatalogKeptPurgeRetryTests.swift`

## Invariants to attack
1. **Your #124 findings are closed**, including variants (B written then marked removed by any marker, not just purge; B unchanged but already purged; B→C→D chains; C also refused).
2. **The widened `storedRecordPresent`.** Can B count as present while it is not a usable live row for the file — e.g. a Trash/missing/quarantine marker on a file that IS on disk, so A goes and the file has no live, visible row? Is that the same state the app reached before the incident for a trashed-file rescan (i.e. no regression), or new loss?
3. **Release on plain purge of B.** Can releasing A ever turn into purging A without A's own proof? Can a released A then block or collide with a later fresh record at its path?
4. **Rollback completeness.** When the group rolls back after successful writes, are ledger/tombstone/pending rows and the committer's in-memory baseline consistent with "B refused", so B is retried and not treated as saved?
5. **Tests are real**: would each new test fail on `3197ef431`?

## Evidence already run
Each fix red first (core 9 tests / 2 failed before; app CatalogKeptPurgeRetry 4 / 2 failed before; F3 by mutation: 100 paths lost under the old blind spots, old test passed). Final: core `--filter CatalogCommit` 56 tests / 9 suites green; app Debug 154 tests / 22 suites green; sensor lane green (555).

## Known and declared, NOT findings
- A released A stays live in-session, named in the log (conservative by design).
- `replaceArchiveCopy` still refuses re-created import-era copies (~95 `NOT REMOVED` per FamilyArchive rescan). Separate provenance decision.
- Recovery of the 95 already-purged rows is a separate, not-yet-run tool.

At most FIVE findings, most serious first, each with a one-line failure scenario and the fix. P1 = any path that still loses a catalog row of a file that's on disk.

**Do not explore outside the files listed above.**
