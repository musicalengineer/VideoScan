# Codex review — Committer refuse-and-name + row lock (closing #143)

- Range: `main..fix/committer-lost-writes-codex141`
- Credits spent: unavailable
- Tokens: 233606
- Finding count: 5
- Verdict: block — pending payloads, new same-content copies and purges can still overwrite saved state, and the amended scalar baseline can suppress a later edit.
- Run: 2026-10-26T03:28:54Z (cycle #145, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 5  
Verdict: block — pending payloads, new same-content copies and purges can still overwrite saved state, and the amended scalar baseline can suppress a later edit.

Reviewed `main..a77705346`; worktree unchanged. Existing Debug binaries passed **12 app tests / 6 suites** and **6 Core tests / 1 suite**. The new regressions below are source-derived and **not executed**.

1. **[P1] Another writer’s changed pending payload passes both checks and is overwritten.**  
   [CatalogRowLock.swift:171](/private/tmp/claude-501/-Users-rickb-dev-VideoScan/f3133caa-0511-403d-97d1-04039b7d554c/scratchpad/wt-committer/VideoScan/VideoScanCore/Sources/VideoScanCore/Commit/CatalogRowLock.swift:171)

   `.pending` carries no payload version; `.pendingOnly` proves only existence. Reopen and the commit door therefore accept a payload another writer changed. `putPendingRow` subsequently replaces its JSON.

   **Reproduction:** A holds record R without a digest. B saves a note or footage decision on the same pending R, still without a digest. A edits its stale R, encounters the generation refusal, then Reopens. R passes read-back; A’s retry replaces B’s payload without a HELD line.

   **Regression:** extend the materialisation test with a **pending → changed pending** case. Expect refusal/hold and B’s payload intact after relaunch. The present implementation instead commits A’s payload. Pending rows need an expected payload version, not merely an existence check.

2. **[P1] A new copy can overwrite the shared curation of a HELD row.**  
   [CatalogCommitBody.swift:151](/private/tmp/claude-501/-Users-rickb-dev-VideoScan/f3133caa-0511-403d-97d1-04039b7d554c/scratchpad/wt-committer/VideoScan/VideoScanCore/Sources/VideoScanCore/Commit/CatalogCommitBody.swift:151)

   A session-created item skips verification entirely. Its new-row diff includes its populated curated fields, which write existing **digest-keyed** display rows. Holding the original row does not protect those shared values.

   **Reproduction:** B saves `"B's note"` on R. A edits stale R to `"A's note"`; Reopen correctly holds R. A then adds a new-ID copy C with R’s digest and inherited `"A's note"`. Committing C writes that note over B’s saved note, although R remains held.

   This is reachable through Promote: `registerPromotedCopy` copies the source’s curation onto a new record; the later save can land that copy while holding the source.

   **Regression:** create C with `freshCopy`, give it R’s digest, append it after R is held, and commit. Assert R still reloads with `"B's note"`. Skipping a new row’s ID check must not exempt writes to existing shared curation.

3. **[P1] Purges bypass both row expectations and the HELD exclusion.**  
   [CatalogCommitBody.swift:150](/private/tmp/claude-501/-Users-rickb-dev-VideoScan/f3133caa-0511-403d-97d1-04039b7d554c/scratchpad/wt-committer/VideoScan/VideoScanCore/Sources/VideoScanCore/Commit/CatalogCommitBody.swift:150), [CatalogCommitter.swift:840](/private/tmp/claude-501/-Users-rickb-dev-VideoScan/f3133caa-0511-403d-97d1-04039b7d554c/scratchpad/wt-committer/VideoScan/VideoScan/Catalog/CatalogCommitter.swift:840)

   Verification visits only `plan.items`; `Plan.purges` contains bare IDs. Reopen examines records still in memory, while `duePurges` neither checks their locks nor excludes `conflicts`.

   **Reproduction:** A queues removal of R while writes are held. B saves a new Trash marker and recovery path on R. A’s first purge fails CAS. Reopen does not inspect absent R; the retry purges it, replacing B’s marker and clearing its current Trash path. R disappears from subsequent loads. Tombstone history remains, but the saved current state was overwritten.

   **Regression:** queue that purge, land B’s marker, fail CAS, Reopen and retry. Assert B’s marker remains current and R is not purged. Also test purging an already-held ID.

4. **[P1] Moving the scalar baseline without updating dirty detection suppresses a reversal.**  
   [CatalogCommitBaseline.swift:324](/private/tmp/claude-501/-Users-rickb-dev-VideoScan/f3133caa-0511-403d-97d1-04039b7d554c/scratchpad/wt-committer/VideoScan/VideoScan/Catalog/CatalogCommitBaseline.swift:324)

   The amended rule advances dirty B’s shared baseline but leaves its whole-record fingerprint at the original value. Returning B to that original value then looks completely clean—even though it differs from the new shared baseline and the store.

   **Reproduction:** copies A and B start with note `"base"`. Both change to `"shared"`. Save A only. B retains `"shared"`, its scalar baseline becomes `"shared"`, but its fingerprint baseline still represents `"base"`. Change B back to `"base"` before the next flush. `commitNow()` returns true without submitting B; relaunch restores `"shared"`.

   **Proposed regression**, after normalising both copies to `"base"` and saving:

   ```swift
   a.userNotes = "shared"
   b.userNotes = "shared"
   try #require(committer.commitNow(ids: [a.id]))

   b.userNotes = "base"
   try #require(committer.commitNow())

   #expect(try await scene.reloaded(.curatedConflictB).userNotes == "base")
   try await scene.relaunch()
   #expect(try scene.record(.curatedConflictB).userNotes == "base")
   ```

   Both final expectations should fail today. Advancing the scalar baseline needs corresponding dirty-detection bookkeeping.

5. **[P2] An undecodable stored row does not necessarily keep Reopen blocked.**  
   [CatalogRowLock.swift:165](/private/tmp/claude-501/-Users-rickb-dev-VideoScan/f3133caa-0511-403d-97d1-04039b7d554c/scratchpad/wt-committer/VideoScan/VideoScanCore/Sources/VideoScanCore/Commit/CatalogRowLock.swift:165)

   A lock mismatch returns `.rowChanged` before attempting decoding. With a matching lock, decoding happens only when a shared scalar was edited. Reopen can therefore report successful checking and allow saves despite an undecodable row.

   **Reproduction:** B appends JSON-valid but structurally invalid lineage knowledge for R. A edits R and Reopens. The changed lock produces an ordinary HELD result; `heldWords` swallows the decoding failure, and `becameWritable()` clears the block.

   **Regression:** inject that lineage value and assert `blockedReason != nil` after Reopen. The existing failed-read test covers a thrown repository read, not this case. The row remains protected from overwrite, but the stated failed-read-back contract is not met.

The six previous findings close as follows:

| Previous #143 finding | Status |
|---|---|
| Failed read-back becomes writable | Thrown reads fixed; undecodable-row case remains above. |
| Edit after read-back | Closed for existing locked rows: checked inside the transaction. |
| Held/pending records omitted | Materialisation fixed; changed pending payloads remain unprotected. |
| Stored pair erased during reconciliation | Closed: no destructive relinking; stored pair IDs participate in the lock. |
| Instance swap / Promote pointer / table cache | Closed: the replacement path and callback are gone. |
| Converged-edit stale `rebase` baseline | Original mechanism removed; the scoped scalar reversal above remains a separate baseline defect. |

The inspected hash includes file facts, row knowledge, archive/backup relations, markers, pair links, footage decisions, and duplicate membership/disposition. The excluded sound-print and derived fields are machine outputs; human footage decisions and confirmed/rejected people use separate protected paths.

I found no same-session lock-refresh omission in the traced Tidy, marker or Promote saves. Successful/partial row writes return their stored locks; rolled-back replacement results clear them. Relaunch installs fresh locks and clears held conflicts.

`verifyExpectations` adds no unconditional catalog-wide sweep. Its indexed readers still traverse the selected row’s history and associated content/group data; a very large duplicate group makes the member-count subquery proportional to that group. The prebuilt 100-row test took **0.173 s**.

Scope extensions were limited to the direct DTO/load/write helpers, CAS and schema definitions, fixture helpers, derived-value producers, and Tidy/Promote/purge/folder callers needed for these checks.

For the remaining scoped files:

- `CatalogSharedCurated.swift` — read, no findings.
- `CatalogRepository.swift` — read, no findings.
- `GRDBCatalogRepository+LivePending.swift` — read, no findings.
- `CatalogAuthorityFlip.swift` — read, no findings.
- `SQLiteCatalogLoader.swift` — read, no findings.
- `CatalogCodex141ReopenReconcileTests.swift` — read, no findings.
- `CatalogCodex143RefuseAndNameTests.swift` — read, no findings.
- `CatalogCodex143FailedReadBackTests.swift` — read, no findings.
- `CatalogCommitRowLockTests.swift` — read, no findings.

## Brief

# Codex review brief — Committer: refuse-and-name + per-row lock at the commit door (closing your #143 block)

**Workflow in one sentence (Rick's words):** "never lose a saved edit" — when another writer changed a row this session also changed, the row is held and named, never saved over and never rebuilt; every row a commit submits is checked against what the store holds inside the one transaction.

**Range:** `main..fix/committer-lost-writes-codex141` (three commits; the new design is the last, `a77705346`; the middle commit `75351ceb6` is the reconcile you blocked, kept for history and removed by the last) · **Worktree:** `/private/tmp/claude-501/-Users-rickb-dev-VideoScan/f3133caa-0511-403d-97d1-04039b7d554c/scratchpad/wt-committer` (read-only for you)

**What changed since your #143 verdict (block/6)** — docs/reviews/codex/codex-review-committer-lost-writes-2026-10-25.md:
- `reconcile`, `reconcileRow`, `relinkPair`, `rebase`, `onRecordsReconciled`, `showReconciledRecords` and the instance swap are GONE. Nothing in memory is rebuilt.
- **Reopen** always reads back, in one store snapshot, every record the next commit could submit (the commit's own rule: fingerprint ≠ baseline — edited, held and pending records alike; session-created rows skipped). A row still at its per-row lock AND its shared-scalar baseline may commit; otherwise it is HELD: out of every commit, dirty in memory with the person's values, named in catalog.log on every Reopen ("HELD <id> — the catalog changed under you: <file> — …; this session's edit of it was not saved; relaunch … then redo"), OUTCOME counts saved vs held, a marker request on it is refused at its door. Failed read-back (error, missing row, undecodable row) keeps saving blocked.
- **Door:** new `Commit/CatalogRowLock.swift` (`CatalogRowLock` = the store's own hash of a row's per-row parts, computed at load and read back after every landed row; `CatalogRowCheck` = the one comparison used by both the door and Reopen). `CatalogCommit.Item.expected`; `CatalogCommitBody.verifyExpectations` runs first inside the transaction and refuses the WHOLE commit (rollback, generation untouched, rows named) on any lock mismatch, on a held record's "still pending" expectation failing, or on a shared scalar this session edited that the store no longer holds at its baseline. The generation CAS still stands underneath.
- **F3 amended:** after a scoped save, a dirty sibling's SCALAR baseline now takes the committed value (sets keep the F3 guard). The worker says without this the scalar check falsely holds the session's own sibling. Look hard at this.
- Removal marker: when the other writer changed the same row, the row is HELD (marker stays in memory, not written) rather than writing the marker alone.

**In scope:** `VideoScan/VideoScanCore/Sources/VideoScanCore/Commit/CatalogRowLock.swift`, `CatalogCommit.swift`, `CatalogCommitBody.swift`, `CatalogSharedCurated.swift`; `Store/CatalogRepository.swift`, `GRDBCatalogRepository+LivePending.swift`; app `Catalog/CatalogCommitter.swift`, `CatalogCommitBaseline.swift`, `CatalogAuthorityFlip.swift`, `SQLiteCatalogLoader.swift`; tests `VideoScanTests/CatalogCodex141ReopenReconcileTests.swift`, `CatalogCodex143RefuseAndNameTests.swift`, `CatalogCodex143FailedReadBackTests.swift`, Core `Store/CatalogCommitRowLockTests.swift`.

**Invariants to attack:**
1. **Your six #143 findings** — for each, show it is closed or still open (failed read-back → writable; edit after read-back; held/pending records; pair erased; instance swap/Promote pointer/table cache; converged-edit stale baseline).
2. **The lock covers every per-row part a commit can write** (file facts, row knowledge, relations, marker, pair, footage decisions, dispositions, duplicate membership) — a part outside the lock that the door writes over is a lost write. The header says per-content machine facts (sound print, derived) follow the last writer and are outside: confirm they are regenerable, never human.
3. **The lock round-trips:** computed at load, read back after a landed row — show a write path (a commit door other than `CatalogCommit`, a job writer, an importer, Tidy, Promote's archive write, the marker door) that changes a row WITHOUT refreshing the session's lock, making every later commit of that row refuse forever (a stuck "another writer" that is really ourselves), or the reverse (lock refreshed while the row was not written).
4. **The amended F3 scalar rule** — construct both writers / two copies cases where the scalar baseline taking the committed value loses or resurrects a value.
5. **No false hold, no permanent block:** a row only this session wrote must never be held; a held row must become saveable after relaunch; refusal words must name rows a person can find.
6. **Cost:** verifyExpectations per submitted row inside the write transaction — anything O(catalog)?

**Evidence already run:** 167 app tests / 43 suites (Cutover, Committer, CommitBaseline, CatalogCommit, P0Truth, PhaseConsistency, Codex141, Codex143) green; Core `--filter Catalog` 437 / 67, only failure `theRealProbeRunsQuickCheckThroughThisReader` (machine load, GH #385); Core CatalogCommitRowLockTests 6/6 (3 door tests RED by removing verifyExpectations); every new test seen RED on 549a9b798; sensor lane GREEN 573; CCN ≤ 9 per new function; 100 submitted rows with expectations 0.24–0.32 s Debug.

**Known and accepted (do not report):** a held row's memory is not refreshed (the HELD line says relaunch); ledger atomicity is GH #384.

**Output contract:**
```
Credits spent: <amount> | Finding count: <N>
Verdict: merge | fix | block — <one sentence>
```
Then findings ranked by data-loss risk, each with `file:line`, a reproduction, and a RED test where possible. For every in-scope file with nothing to report write "read, no findings." Do not explore outside the files above unless a finding requires it, and say so.
