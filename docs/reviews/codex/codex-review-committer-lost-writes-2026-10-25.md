# Codex review — Committer lost writes closing pass (codex #141 F2/F3)

- Range: `main..fix/committer-lost-writes-codex141`
- Credits spent: unavailable
- Tokens: 187177
- Finding count: 6
- Verdict: block — F3’s scoped-save guard is sound, but F2 still permits lost writes and unsafe instance replacement.
- Run: 2026-10-26T02:07:05Z (cycle #143, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 6  
Verdict: block — F3’s scoped-save guard is sound, but F2 still permits lost writes and unsafe instance replacement.

Reviewed `6906d4e45..549a9b798`. No source changes. Executed: app **4 tests / 2 suites / 7 cases**, Core **62 tests / 10 suites**, all passed. The regressions below are source-derived and **not executed**.

1. **[P1] Failed reconciliation immediately becomes writable again.**  
   [CatalogCommitter.swift:525](/private/tmp/claude-501/-Users-rickb-dev-VideoScan/f3133caa-0511-403d-97d1-04039b7d554c/scratchpad/wt-committer/VideoScan/VideoScan/Catalog/CatalogCommitter.swift:525)

   A failed row read sets `blockedReason` at line 570 and returns. `reopen` then advances `knownGeneration` and calls `becameWritable`, which clears that refusal and schedules the stale retry. A failed generation read also substitutes the old generation at line 670, potentially skipping reconciliation despite the repository having reopened at the newer generation.

   **Reproduction:** B commits a footage decision; A changes the note and encounters CAS refusal. Inject a one-shot failure into Reopen’s row read, then allow subsequent reads/writes. Reopen reports success; A’s retry deletes B’s decision.

   **Regression:** a `CutoverScene` repository decorator failing that read must leave `blockedReason != nil`, `commitNow() == false`, and B’s decision intact. Reconciliation must return an explicit success/failure result that gates reopening.

2. **[P1] A row edited after reconciliation can overwrite the other writer’s saved changes.**  
   [CatalogCommitter.swift:560](/private/tmp/claude-501/-Users-rickb-dev-VideoScan/f3133caa-0511-403d-97d1-04039b7d554c/scratchpad/wt-committer/VideoScan/VideoScan/Catalog/CatalogCommitter.swift:560)

   The changed-row list is captured before an `await`; no protection remains for omitted rows after Reopen accepts the generation. A clean row can become dirty during that suspension or between Reopen returning and its debounced retry. Its stale non-shared fields then participate in `CatalogRecordDiff`.

   **Reproduction:** B saves a decision on row Y; A edits row X and gets blocked. Reopen checks X only. Before retry, A edits Y’s note. The retry saves the note **and deletes B’s decision**. The accepted stale-memory behavior becomes a write here.

   Proposed regression, added inside `CatalogReopenReconcileTests`:

   ```swift
   @Test
   func editAfterReopenKeepsOtherWritersDecision() async throws {
       let scene = try CutoverScene.make("reopen_late_edit")
       defer { scene.cleanup() }
       try await scene.launchOnSQLite()
       let committer = try scene.committer()
       try #require(committer.commitNow())

       let x = try scene.record(.healthy)
       let y = try scene.record(.stalePrint)
       try await scene.otherWriterDecides(rowOf: y, about: x.id)

       x.userNotes = "before Reopen"
       try #require(!committer.commitNow())
       await committer.reopen(at: scene.databaseURL)

       y.userNotes = "after Reopen, before retry"
       try #require(committer.commitNow())

       let saved = try await scene.reloaded(.stalePrint)
       #expect(saved.footageDecisions.contains { $0.otherID == x.id })

       try await scene.relaunch()
       let relaunched = try scene.record(.stalePrint)
       #expect(relaunched.footageDecisions.contains { $0.otherID == x.id })
   }
   ```

3. **[P1] Held records are excluded even when another writer has materialized their rows.**  
   [CatalogCommitter.swift:594](/private/tmp/claude-501/-Users-rickb-dev-VideoScan/f3133caa-0511-403d-97d1-04039b7d554c/scratchpad/wt-committer/VideoScan/VideoScan/Catalog/CatalogCommitter.swift:594)

   `changedSinceBaseline` requires `baseline.prints[id]`. Held records have an entry in `held`, without ordinary fingerprint/shared baselines. Normal commit detection nevertheless includes them.

   **Reproduction:** A holds a pending record without its full hash. B supplies the hash, materializes that same ID, and saves a footage decision. A subsequently supplies the same hash and edits its stale record. After CAS refusal, Reopen skips it; retry compares the stale record against B’s row and removes B’s decision.

   **Regression:** construct that pending→materialized transition in `CutoverScene`; assert B’s decision survives retry and relaunch. Every row the retry could submit needs reconciliation coverage, including rows lacking an ordinary baseline.

4. **[P1] Reconciliation can erase a valid stored pair before comparing or logging it.**  
   [CatalogCommitter.swift:625](/private/tmp/claude-501/-Users-rickb-dev-VideoScan/f3133caa-0511-403d-97d1-04039b7d554c/scratchpad/wt-committer/VideoScan/VideoScan/Catalog/CatalogCommitter.swift:625)

   `relinkPair` resolves partners only from this session’s array. An absent partner causes it to clear the partner ID, group and confidence **before** computing `storedPrint` and `differingParts`.

   **Reproduction:** B adds partner C and pairs existing row R with C. A, whose array lacks C, edits R’s note. Reopen converts B’s valid pair into no pair; retry writes that absence. If the pair was B’s only change, the normalized fingerprint can even equal the original baseline, bypassing the reconciliation log entirely.

   **Regression:** after retry, read `storedRow(R).pair?.pairedWithID` directly and expect C’s ID; repeat after relaunch. Preserve the stored link or refuse when its partner cannot be resolved.

5. **[P1] The instance swap detaches active writers and leaves a table cache holding old records.**  
   [CatalogAuthorityFlip.swift:346](/private/tmp/claude-501/-Users-rickb-dev-VideoScan/f3133caa-0511-403d-97d1-04039b7d554c/scratchpad/wt-committer/VideoScan/VideoScan/Catalog/CatalogAuthorityFlip.swift:346)

   Promote’s `finishPublished` retains `source` across awaits at lines 555 and 567, then passes it to `registerPromotedCopy` at line 630. That function writes source fixity, notes, archive stage, stars and location through the retained pointer ([VideoScanModel+MasterArchive.swift:1385](/private/tmp/claude-501/-Users-rickb-dev-VideoScan/f3133caa-0511-403d-97d1-04039b7d554c/scratchpad/wt-committer/VideoScan/VideoScan/Archive/VideoScanModel+MasterArchive.swift:1385)). The save reads the replacement from `model.records`, so source changes can disappear while the job completes successfully. `owns` only governs the marker path.

   **Reproduction:** suspend Promote during reprobe; make its source dirty, cause a competing commit, and Reopen that row; resume Promote. The old source advances while the live source does not.

   **Regression:** use that pause ordering and assert the live source’s promotion fields survive save/relaunch.

   There is also an unhandled UI holder: `CatalogTableState.tableData` retains instances. The plain Catalog table refreshes on count and `volumeAggregatesRevision`, neither changed by this swap ([CatalogContent+Table.swift:208](/private/tmp/claude-501/-Users-rickb-dev-VideoScan/f3133caa-0511-403d-97d1-04039b7d554c/scratchpad/wt-committer/VideoScan/VideoScan/Catalog/CatalogContent+Table.swift:208)). It can continue displaying the detached row.

6. **[P1] A converged edit leaves a stale shared baseline that suppresses the next reversal.**  
   [CatalogCommitBaseline.swift:103](/private/tmp/claude-501/-Users-rickb-dev-VideoScan/f3133caa-0511-403d-97d1-04039b7d554c/scratchpad/wt-committer/VideoScan/VideoScan/Catalog/CatalogCommitBaseline.swift:103)

   `rebase` installs the stored fingerprint while retaining old values for every locally edited group. When the reconstructed record already equals the store, normal detection considers it clean, so no commit settles those old shared baselines.

   **Reproduction:** baseline tags `{base}`. Both writers add `x`; B also adds a footage decision, ensuring A’s attempted save encounters CAS refusal. Reopen produces exactly B’s stored record, but retains `{base}` as A’s tag baseline. A then removes `x`. Current tags now equal that obsolete baseline, so `restrictShared` excludes the removal. Save succeeds; relaunch restores `x`.

   **Regression:** parameterize this converged-edit→reversal case over tags, people and attestations; expect `{base}` in memory, store and relaunch. Retaining pending deltas is correct only while those deltas remain outstanding.

For successfully rebuilt rows, the conflict behavior is:

| Record part | Winner and logging |
|---|---|
| Stars, user notes, media disposition, date/confidence, place/confidence, family music | Locally edited group wins; otherwise catalog. Group named in the row log. |
| Tags, confirmed/rejected people, attestations | Local delta against retained baseline; intended to preserve other additions. Finding 6 breaks subsequent edits. |
| Row-scoped knowledge: lineage, supersession, repair confirmation, archived date, set-aside | Catalog wins; corresponding knowledge/file differences named. |
| File/probe/fixity facts, machine notes, lifecycle/archive/workspace fields | Catalog wins; logged as file facts, with applicable knowledge labels. |
| Removal marker | Catalog wins; marker named and `markerDirty` cleared. |
| Archive-copy and backup relations, footage decisions | Catalog wins; corresponding parts named. |
| Duplicate membership/disposition, sound print, derived analysis | Catalog wins; duplicate/sound/derived categories named. |
| Pair link | Intended catalog winner; finding 4 can destroy it before logging. |

**Generation and isolation:** a third commit after read-back still fails the repository’s generation CAS and rolls back its database writes. No new `nonisolated(unsafe)` was introduced. Rebuilding and the callback are synchronous on the main actor, but the preceding read suspends; actor isolation does not freeze the changed-row set. Repeated Reopen therefore does not establish safety for findings 2, 3 and 6.

Inspector selection and Triage resolve IDs through the invalidated model index. The inspected undo holders also use IDs/snapshots. Find Duplicates checks live object identity before applying results. Those protections do not cover the Promote pointer or Catalog table cache.

**Judgment:** data-loss risk favors **retaining the refusal and naming the unresolved rows**. “Catalog wins + name it” discards the only retained local value even when the writers changed different parts. The log records categories, not a recoverable copy of the abandoned edits.

Read, no findings:

- `CatalogSharedCurated.swift`
- `CatalogRecordDiff.swift`
- `CatalogCodex141ScopedBaselineTests.swift`
- `CatalogCodex141ReopenReconcileTests.swift`

`CatalogCommitBaseline.share(_:onto:)`: read, no findings.

Scope extensions were limited to the loader, commit/repository implementations, fixture helpers, and model/UI/job/undo consumers needed to establish the findings above. The app test teardown emitted SQLite open-file/unlink warnings despite the passing assertions.

## Brief

# Codex review brief — Committer lost writes: closing pass on findings 2 and 3 of cycle #141 (data-risk, rule 10)

**Workflow in one sentence (Rick's words):** "never lose a saved edit" — when a second writer (another process, or a second connection) has committed to the catalog, this session's Reopen must keep BOTH writers' changes; a scoped save of one copy must never turn another copy's addition into a later deletion.

**Range:** `main..fix/committer-lost-writes-codex141` (two commits) · **Worktree:** `/private/tmp/claude-501/-Users-rickb-dev-VideoScan/f3133caa-0511-403d-97d1-04039b7d554c/scratchpad/wt-committer` (read-only for you; rebased on main `6906d4e45`)

**Your own findings being closed** (docs/reviews/codex/codex-review-catalog-store-consistency-2026-10-25.md):
- **F3** — a scoped save (`commitNow(ids:)`) replaced a dirty sibling's baseline. Fix: `CatalogCommitBaseline.share(_:onto:)` — a copy whose group is NOT clean keeps its value AND its baseline (`guard now.same(group, as: mine) else { continue }`), so B's delta stays `+b` only. Test `CatalogScopedSaveBaselineTests` × 3 (tags, people, attestations), relaunch included.
- **F2** — Reopen accepted the new generation and retried with stale records, deleting the other writer's footage decision. Fix: `CatalogCommitter.reopen` RECONCILES when the store's generation ≠ `knownGeneration`: one `repository.read` of the stored row for every record changed since baseline; stored fingerprint == baseline → commit as is; otherwise the record is rebuilt from the store (`VideoRecord(row:dateFormatter:)`, pair relinked), this session's shared-curated edits re-applied (`CatalogSharedCurated.edited(since:)`), the baseline rebased (`CatalogCommitBaseline.rebase`; edited SET groups keep the old baseline), `markerDirty` cleared for those ids, and the model swaps the instance in through the one new seam `onRecordsReconciled` (wired in `CatalogAuthorityFlip.swift` → `showReconciledRecords`). Parts the baseline cannot attribute (row-scoped knowledge, relations, marker, file facts) keep the CATALOG's value and the row is named in catalog.log. A failed read-back leaves the committer blocked with words.

**In scope (read these and their direct callers; nothing else):**
- `VideoScan/VideoScan/Catalog/CatalogCommitter.swift` — `reopen`, `reconcile`, `changedSinceBaseline`, `reconcileRow`, `relinkPair`, `differingParts`
- `VideoScan/VideoScan/Catalog/CatalogCommitBaseline.swift` — `share(_:onto:)`, `rebase`
- `VideoScan/VideoScan/Catalog/CatalogAuthorityFlip.swift` — `onRecordsReconciled`, `showReconciledRecords`
- `VideoScan/VideoScanCore/Sources/VideoScanCore/Commit/CatalogSharedCurated.swift`, `CatalogRecordDiff.swift` (read for the contract; unchanged)
- Tests: `VideoScan/VideoScanTests/CatalogCodex141ScopedBaselineTests.swift`, `CatalogCodex141ReopenReconcileTests.swift`

**Invariants to attack:**
1. **No edit of this session is lost silently.** Enumerate every part of a record (shared-curated groups, row-scoped knowledge, relations, removal marker, file facts, pair link, footage decisions, dispositions). For each: when both writers changed it, who wins, and is the loss NAMED in the log with the row? Show a part that is dropped without a log line, or a log line that names the wrong part.
2. **No edit of the other writer is lost.** After reconcile + retry, is there any path where the retry's diff still deletes a stored value (`CatalogRecordDiff` treating "missing in memory" as an edit) — e.g. a part reconcile did not rebuild, a pair relink that re-points to a stale instance, a record changed by the other writer that this session did NOT touch (deliberately not refreshed) but that is pulled into the commit by propagation (`share`) from a sibling copy?
3. **Instance swap safety.** Rebuilt records replace instances in `model.records`. What holds the old instance: the inspector selection, the Triage table, a running job (Find Duplicates, Analyze, Promote), `pairedWith`, undo stacks, `markerDirty` sets, baseline keys? Show a holder that writes through the detached object after a Reopen, or a `@Published` consumer that misses the swap.
4. **Baseline rebase correctness.** `rebase` keeps the OLD baseline for edited SET groups (so the delta stays the session's own) and takes the store's value for the rest. Construct a case where the next commit's delta removes something the other writer added, or re-adds something this session removed.
5. **Generation / CAS.** After reconcile, `knownGeneration` becomes the store's; between the read-back and the retry a THIRD commit can land. Does the retry still fail the generation check (no lost write), and does a second Reopen reconcile again correctly (idempotent)? Debounce window and write hold: the rule-8 cases the tests parameterise — any third ordering (edit after the read-back, before the retry)?
6. **Swift 6 isolation.** The new seam and the read-back: any `nonisolated(unsafe)`, any actor hop that lets `records` mutate mid-reconcile?

**Judgement call to assess explicitly:** "catalog wins + name it" for unattributable parts, versus keeping the CAS refusal and telling the person which rows' edits were not saved (refuse rather than guess, CLAUDE.md rule 2). Say which the data-loss risk favours and why.

**Evidence already run:** RED seen (F3: stored `{b, base}` vs expected `{a, b, base}` across memory, store and relaunch, 18 issues; F2: B's decision `[]` after A's retry, debounce and write-hold cases; `setAsideReason == "damaged"` stored with no log line before the fix). App suites matching Cutover/Committer/CommitBaseline/CatalogCommit/P0Truth/PhaseConsistency + the two new: 159 tests / 39 suites green; Core CatalogCommit*: 62 / 10 green; sensor lane GREEN 573; CCN gate 0 excess.

**Known and accepted (do not report):** clean rows the other writer changed are NOT refreshed in memory on Reopen (never written back; OUTCOME says "relaunch to refresh"); per-part baselines were rejected for cost (~1.1–1.7 ms per record at launch); finding 5 (ledger atomicity) is GH #384.

**Output contract:**
```
Credits spent: <amount> | Finding count: <N>
Verdict: merge | fix | block — <one sentence>
```
Then findings ranked by data-loss risk, each with `file:line`, a reproduction, and a RED test where possible (Swift Testing, `CutoverScene`). For every in-scope file with nothing to report write "read, no findings." Do not explore outside the files above unless a finding requires it, and say so.
