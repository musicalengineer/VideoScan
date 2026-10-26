# Codex review — Committer round 3 (closing #145)

- Range: `main..fix/committer-lost-writes-codex141`
- Credits spent: unavailable
- Tokens: 190982
- Finding count: 3
- Verdict: block — same-content inserts can still overwrite saved curation, and scalar edits can still disappear or produce a false hold.
- Run: 2026-10-26T04:32:43Z (cycle #147, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 3  
Verdict: block — same-content inserts can still overwrite saved curation, and scalar edits can still disappear or produce a false hold.

Reviewed through `12a58baf0`; worktree unchanged. Existing Debug binaries passed **19 app tests / 11 suites** and **11 Core tests / 2 suites**. The proposed RED regressions below are source-derived, **not executed**; standalone Swift compilation was denied by the read-only profile.

1. **[P1] F2 remains open: some same-content inserts bypass both shared-value checks and write restrictions.**

   [CatalogCommitBody.swift:169](/private/tmp/claude-501/-Users-rickb-dev-VideoScan/f3133caa-0511-403d-97d1-04039b7d554c/scratchpad/wt-committer/VideoScan/VideoScanCore/Sources/VideoScanCore/Commit/CatalogCommitBody.swift:169), [CatalogCommitBaseline.swift:178](/private/tmp/claude-501/-Users-rickb-dev-VideoScan/f3133caa-0511-403d-97d1-04039b7d554c/scratchpad/wt-committer/VideoScan/VideoScan/Catalog/CatalogCommitBaseline.swift:178)

   The worker’s gap **(a) is a saved-edit-loss bug**. Without an in-memory sibling baseline, `newCopyMismatch` returns immediately at line 183. The insert then writes its populated shared fields over existing digest-keyed values.

   There is another route **even when the sibling remains in memory**: a pending record acquiring its digest. Its `.pending` expectation excludes it from `newCopies`; `CatalogRowCheck.check` validates the pending payload and returns without checking the existing content. It also never enters `readRows.newCopies`, so its insert is unrestricted.

   **Reproduction:** R has note `"base"`. Save new copy C without a digest into `pending_rows`. Another writer changes R’s shared note to `"B's note"`. Give C R’s digest, fail CAS, Reopen, retry. C’s unchanged pending payload passes; its inherited `"base"` overwrites B’s saved note.

   **Proposed RED test**, using the existing new-copy suite’s helpers:

   ```swift
   let (scene, committer) = try await Base.launched("pending_copy")
   defer { scene.cleanup() }
   let r = try scene.record(.healthy)
   r.userNotes = "base"
   try #require(committer.commitNow())
   let digest = try #require(CatalogCommit.digest(of: r))

   let c = try scene.freshCopy(
       of: .healthy, path: "/Volumes/Fixture/fresh/pending-copy.mov")
   scene.model.records.append(c)
   try #require(committer.commitNow())
   try #require(committer.heldIDs.contains(c.id))

   try await scene.otherWriterNotes(rowOf: r, "B's note")
   CutoverScene.giveDigest(c, digest)
   #expect(!committer.commitNow())
   await committer.reopen(at: scene.databaseURL)
   _ = committer.commitNow()

   #expect(try await scene.reloaded(.healthy).userNotes == "B's note")
   ```

   Also pin the no-baseline route: replace R with fresh C in memory, queue `R → C` as a replacement, then Reopen after B’s note lands. Assert C reloads with B’s note. Checking the purge’s row lock does not protect this shared scalar.

2. **[P1] F4 remains open when the sibling was dirty in a different field.**

   [CatalogCommitBaseline.swift:397](/private/tmp/claude-501/-Users-rickb-dev-VideoScan/f3133caa-0511-403d-97d1-04039b7d554c/scratchpad/wt-committer/VideoScan/VideoScan/Catalog/CatalogCommitBaseline.swift:397)

   `stale` is inserted only when the **propagated scalar group itself** was dirty. If B was dirty elsewhere, propagation changes B’s scalar value and baseline, but neither updates its fingerprint nor inserts `stale`. Returning B to its original whole-record state therefore suppresses a real scalar edit.

   **Reproduction / proposed RED variant**, after normalising A and B to note `"base"`:

   ```swift
   let originalAside = b.setAsideReason
   b.setAsideReason = "pending change"
   a.userNotes = "shared"
   try #require(committer.commitNow(ids: [a.id]))
   #expect(b.userNotes == "shared")

   b.setAsideReason = originalAside
   b.userNotes = "base"
   try #require(committer.commitNow())

   #expect(try await scene.reloaded(.curatedConflictB).userNotes == "base")
   ```

   The final assertion should fail: B matches its old fingerprint, so nothing submits it; the store retains `"shared"`. Repeat the assertion after relaunch.

3. **[P1] Clearing an inherited scalar on a new copy is reported saved, then its next edit can be falsely held.**

   [CatalogCommitBody.swift:387](/private/tmp/claude-501/-Users-rickb-dev-VideoScan/f3133caa-0511-403d-97d1-04039b7d554c/scratchpad/wt-committer/VideoScan/VideoScanCore/Sources/VideoScanCore/Commit/CatalogCommitBody.swift:387)

   A new-row diff starts with `current.curatedFields`, which excludes cleared/default values. `restrictShared` only removes fields; it cannot add an explicit clear detected against the new copy’s baseline. The insert succeeds without clearing the shared value, and `settle` nevertheless adopts the cleared snapshot as saved.

   **Reproduction / proposed RED test:** save R with note `"base"`, then:

   ```swift
   let c = try scene.freshCopy(
       of: .healthy, path: "/Volumes/Fixture/fresh/cleared-copy.mov")
   CutoverScene.giveDigest(c, try #require(CatalogCommit.digest(of: r)))
   c.userNotes = ""
   scene.model.records.append(c)

   try #require(committer.commitNow())
   #expect(try await scene.reloadedRecord(c.id).userNotes.isEmpty)

   c.userNotes = "next note"
   #expect(committer.commitNow(), "only this session wrote this content")
   ```

   Both expectations should fail. The first reload shows `"base"`. The next save compares C’s adopted empty baseline against stored `"base"` and reports another writer’s change, although no other writer participated. Reopen then holds C. The same omission applies to other scalar clears, such as removing stars.

Original **F1, F3 and F5 close** for their stated pending-payload, purge and undecodable-`files`-row cases. **F2 and F4 remain open** above. Relaunch reconstructs the baselines and clears session conflicts/staleness; finding 3 is a same-session false hold.

The worker’s remaining gaps rank as follows:

| Gap | Assessment |
|---|---|
| **(a)** No in-memory content baseline | **High risk; blocking finding 1.** |
| **(b)** Held new copy disappears at relaunch | Acceptable under the stated refusal policy: it was never saved, the file remains safe, and the HELD message explicitly requires a rescan. |
| **(c)** No inherited shared `row_knowledge` | No runtime reader dependency found. Shared values load from display tables; row-knowledge loading selects row-scoped fields and pair links. |
| **(d)** Dirty copy omits sibling set additions in memory | Store remains correct for the traced delta paths. Preserving that copy’s original set baseline prevents the omitted addition becoming a removal. |

There is **no unconditional full-catalog sweep added inside the transaction**. However, `storedContentRow` scans the matching digest’s copies to satisfy `ORDER BY id LIMIT 1`; `files_by_digest` does not cover that ordering. An in-memory SQLite check showed `USE TEMP B-TREE FOR ORDER BY`: 100 lookups took **0.0058 / 0.054 / 0.541 seconds** for **1k / 10k / 100k** matching copies. Thus cost is proportional to copies of that content and can reach catalog size. The existing 100-row Core commit test passed in **0.244 seconds**.

Scope extensions were limited to direct diff/DTO/load/write helpers, schema/index definitions, and fixture helpers needed for these findings and the reader/cost checks.

For scoped files without findings:

- `CatalogCommit.swift` — read, no findings.
- `CatalogSharedCurated.swift` — read, no findings.
- `CatalogRepository.swift` — read, no findings.
- `GRDBCatalogRepository+LivePending.swift` — read, no findings; lookup cost described above.
- `CatalogCommitter.swift` — read, no findings.
- `CatalogCommitReadBack.swift` — read; shares finding 1’s omitted pending-content check.
- `CatalogAuthorityFlip.swift` — read, no findings.
- `SQLiteCatalogLoader.swift` — read, no findings.
- `CatalogCommit+Copies.swift` — read, no findings.
- `CatalogCodex141ReopenReconcileTests.swift` — read, no findings.
- `CatalogCodex141ScopedBaselineTests.swift` — read, no findings.
- `CatalogCodex143RefuseAndNameTests.swift` — read, no findings.
- `CatalogCodex143FailedReadBackTests.swift` — read, no findings.
- `CatalogCodex145NewCopyTests.swift` — read, no findings.
- `CatalogCodex145PendingPayloadTests.swift` — read, no findings.
- `CatalogCodex145PurgeTests.swift` — read, no findings.
- `CatalogCodex145ScalarRevertTests.swift` — read, no findings.
- `CatalogCodex145UndecodableReadBackTests.swift` — read, no findings.
- `CatalogCommitRowLockTests.swift` — read, no findings.
- `CatalogStoreDurabilityCodex141Tests.swift` — read, no findings.

## Brief

# Codex review brief — Committer round 3: closing your #145 block (5 findings)

**Workflow in one sentence (Rick's words):** "never lose a saved edit" — a row another writer changed is held and named, never saved over; every row, purge and new copy a commit submits is checked against the store inside the one transaction.

**Range:** `main..fix/committer-lost-writes-codex141` (seven commits; the five new ones `8668263d7..12a58baf0`; `1dc31d9ac` is the reconcile you blocked in #143, removed by `d3550840d`) · **Worktree:** `/private/tmp/claude-501/-Users-rickb-dev-VideoScan/f3133caa-0511-403d-97d1-04039b7d554c/scratchpad/wt-committer` (read-only for you). The original F3 scoped-save guard is already on main (`fef4bab06`).

**Your #145 findings and the fixes** (docs/reviews/codex/codex-review-committer-refuse-and-name-2026-10-25.md):
1. Pending payload unversioned → `Expectation.pending(lock:)` carries `CatalogRowLock.ofPending(json:)`; new reader `storedPendingJSON(id:)` in the same transaction; mismatch `.pendingChanged` → held/named.
2. New copy overwrote a held row's shared curation → a new record whose content this session holds gets that content's scalar baseline (`scalarsOnly`); door `checkNewCopy` via `storedContentRow(digest:excluding:)`; the insert writes only fields the copy edited; conflict → refuse, Reopen holds and names the copy.
3. Purges bypassed checks → `Plan.purgeExpectations` verified in-transaction (lock-only); `duePurges` never sends a held id; Reopen's read-back covers queued purges.
4. Scalar baseline moved without dirty detection → amendment kept; a copy whose scalar baseline a sibling's save moved joins `stale` and counts as changed until its own save settles; `baseline.changed(_:fingerprints:)` is the one dirty test.
5. Undecodable stored row → read-back decodes every row regardless of lock; undecodable keeps saving blocked.
Reopen's read-back moved to new `Catalog/CatalogCommitReadBack.swift`.

**In scope:** Core `Commit/CatalogRowLock.swift`, `CatalogCommit.swift`, `CatalogCommitBody.swift`, `CatalogSharedCurated.swift`, `Store/CatalogRepository.swift`, `GRDBCatalogRepository+LivePending.swift` (and any new reader); app `Catalog/CatalogCommitter.swift`, `CatalogCommitReadBack.swift`, `CatalogCommitBaseline.swift`, `CatalogAuthorityFlip.swift`, `SQLiteCatalogLoader.swift`; the Codex141/143/145 test files and Core `CatalogCommitRowLockTests.swift`.

**Invariants to attack:**
1. Each of the five closed, or show the residual.
2. **The worker's stated gaps — rank their data-loss risk:** (a) F2 applies only when a copy of that content in memory has a baseline: a content held only by another writer, or a rescan replacement whose old record left memory, still writes all its shared values; (b) a held NEW copy is not in the catalog at all and drops out of memory at relaunch (the file is safe; Promote's archive-copy row would wait for a rescan) — acceptable under "refuse rather than guess"?; (c) a new copy of stored content no longer appends `row_knowledge` for inherited shared values — any reader that relied on it?; (d) sets (tags/people) in a dirty copy's memory can omit a sibling's addition until relaunch — store correct?
3. **No permanent block, no false hold** across these new mechanisms (`stale`, `pendingLocks`, `newCopies`): a row only this session wrote is never held; every held state clears at relaunch.
4. Anything O(catalog) inside the write transaction.

**Evidence already run:** each new test RED first (app: pending payload replaced, B's note overwritten by a new copy ×2, R purged with B's marker gone ×2, your verbatim scalar-revert regression + relaunch, undecodable row left `blockedReason` nil; Core door tests RED by mutation ×3); app suites Cutover/Committer/CommitBaseline/CatalogCommit/P0Truth/PhaseConsistency/Codex141/143/145: 174 / 48 green; Core `--filter Catalog` 442 / 68 green (9 pre-existing known issues); sensor lane GREEN 573; CCN ≤ 15; manifest errors [].

**Known and accepted (do not report):** a held row's memory is not refreshed (HELD line says relaunch); ledger atomicity is GH #384; store admission is GH #387.

**Output contract:**
```
Credits spent: <amount> | Finding count: <N>
Verdict: merge | fix | block — <one sentence>
```
Then findings ranked by data-loss risk, each with `file:line`, a reproduction, and a RED test where possible. For every in-scope file with nothing to report write "read, no findings." Do not explore outside the files above unless a finding requires it, and say so.
