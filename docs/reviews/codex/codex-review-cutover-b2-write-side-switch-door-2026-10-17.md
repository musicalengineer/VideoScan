# Codex review — Cutover B2 write side + Switch door

- Range: `b34f86c62..3f6e17025`
- Credits spent: unavailable (metering not exposed)
- Tokens: 79761
- Finding count: 7
- Verdict: block** — do not enable real-user cutover at `3f6e17025`.
- Run: 2026-10-18T01:36:29Z (cycle #100, tools/codex_review.py)

## Codex answer

Credits spent: unavailable (metering not exposed) | Finding count: 7

Verdict: **block** — do not enable real-user cutover at `3f6e17025`.

1. **P1 — A dirty sibling can overwrite an untouched curated value.** [CatalogRecordDiff.swift:54](/Users/rickb/dev/VideoScan/VideoScan/VideoScanCore/Sources/VideoScanCore/Commit/CatalogRecordDiff.swift:54), [CatalogCommitBody.swift:82](/Users/rickb/dev/VideoScan/VideoScan/VideoScanCore/Sources/VideoScanCore/Commit/CatalogCommitBody.swift:82). Each row compares all curated fields against the store’s current state, including earlier writes in this transaction. **Failure:** same-content A changes notes; B changes only resolution but still carries old notes; processing A then B writes B’s stale notes over A’s edit. A per-field baseline is needed to distinguish edits from stale copies.

2. **P1 — Copy propagation destroys edits made during a commit.** [CatalogCommitter.swift:341](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/Catalog/CatalogCommitter.swift:341). Propagation reads the live source and overwrites siblings without checking whether their fields changed since the snapshot; line 348 can also advance their baseline using values never committed. **Failure:** snapshot A’s new note, edit sibling B’s note while hashing, then complete A’s commit—B’s newer note is overwritten. Propagate committed snapshot values and preserve subsequent edits.

3. **P1 — Quit and acknowledged saves can overlap an existing commit and falsely report durability.** [CatalogCommitter.swift:134](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/Catalog/CatalogCommitter.swift:134), [CatalogCommitter.swift:144](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/Catalog/CatalogCommitter.swift:144). Only the timer checks `inFlight`. **Failure:** baseline is 0; an async commit writes 1 but has not absorbed its result; the user reverts to 0 and quits. Quit compares against baseline 0, returns “clean,” and leaves SQLite holding 1. All three doors must serialize snapshot, write and baseline adoption.

4. **P1 — Switch’s SHA proof misses pending in-memory edits.** [CatalogSwitchToSQLite.swift:205](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/Catalog/CatalogSwitchToSQLite.swift:205). Freeze precedes any pending-save drain; the subsequent check covers disk bytes only. **Failure:** edit shortly before import finishes, with JSON’s debounce still pending; freeze prevents that save, the old JSON hash passes, and the latch selects SQLite without the edit. Quiesce mutations and establish that the imported snapshot includes every accepted edit.

5. **P1 — Switch can restore an obsolete Master Archive designation.** [CatalogSwitchToSQLite.swift:280](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/Catalog/CatalogSwitchToSQLite.swift:280), [CatalogSwitchToSQLite.swift:217](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/Catalog/CatalogSwitchToSQLite.swift:217). The designation is captured before asynchronous readiness/import and written afterward. **Failure:** capture A, change and save B before the fresh import snapshots JSON, then finish Switch; SHA passes for B’s JSON, but `catalog_state` receives A. The designation guard permits nonnil-to-nonnil replacement.

6. **P1 — An unrelated people edit clears existing conflict flags.** [GRDBCatalogRepository+Live.swift:225](/Users/rickb/dev/VideoScan/VideoScan/VideoScanCore/Sources/VideoScanCore/Store/GRDBCatalogRepository+Live.swift:225). Changing either people list deletes both confirmed/rejected sets and reinserts everything with `conflict = 0`. **Failure:** Donna has an unresolved confirmed/rejected conflict; add confirmed Bob; Donna’s untouched conflict is removed or rewritten as resolved. Preserve unresolved entries unless that conflict was explicitly resolved.

7. **P2 — A rejected derived write still advances the whole-record baseline and reports success.** [CatalogCommitBody.swift:179](/Users/rickb/dev/VideoScan/VideoScan/VideoScanCore/Sources/VideoScanCore/Commit/CatalogCommitBody.swift:179), [CatalogCommitter.swift:307](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/Catalog/CatalogCommitter.swift:307). **Failure:** a derived replacement throws; its savepoint rolls back and produces a note, but the row returns `.written`, adopts the fingerprint containing the unstored value, and an acknowledged save returns true. Subsequent unchanged saves never resend it. Retain a partial-failure dirty state.

The **declared gaps**, ranked by loss risk, are:

| Rank | Gap and failure scenario | Before real flip |
|---|---|---|
| 1 | Digestless new rows remain memory-only ([CatalogCommitBody.swift:67](/Users/rickb/dev/VideoScan/VideoScan/VideoScanCore/Sources/VideoScanCore/Commit/CatalogCommitBody.swift:67)); restart loses the row and its edits. | Durable retention, or disable affected ingestion. |
| 2 | Two marker transitions permanently leave the row beyond `storedRevision + 1` ([CatalogCommitBody.swift:152](/Users/rickb/dev/VideoScan/VideoScan/VideoScanCore/Sources/VideoScanCore/Commit/CatalogCommitBody.swift:152)); later edits keep failing too. | Preserve/replay transitions. |
| 3 | Direct JSON saves bypass SQLite ([VideoScanModel.swift:1222](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/Model/VideoScanModel.swift:1222), also 1245/1255); changes wait for an unrelated funnel call. | Route every caller. |
| 4 | Any `holder: true` bypasses the hold ([CatalogCommitter.swift:222](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/Catalog/CatalogCommitter.swift:222)); an unrelated owner can write during another job’s hold. | Compare owner identity. |
| 5 | Removed IDs never enter detection ([CatalogChangeDetector.swift:83](/Users/rickb/dev/VideoScan/VideoScan/VideoScanCore/Sources/VideoScanCore/Commit/CatalogChangeDetector.swift:83)); purged rows resurrect after restart. | Fix or disable purge. |

Row-refusal savepoint rollback and existing-row tombstone-before-marker ordering **hold**. Switch moves all five existing rehearsal files, unfreezes on mismatch, and requests full fsync for the final latch. Its pre-latch freeze is process-local: a crash leaves no persistent freeze; under the supplied launch rule, JSON remains authoritative.

`HashingEncoder`, `CatalogRepository`, `CatalogLiveWritesSchema`, importer pair-link changes, `CatalogCutoverState`, and the scoped tests: **read, no independent findings**. Tests were not executed under the no-files constraint; atomic-publish and launch internals were outside scope.

## Brief

# Codex brief: cutover B2 — the SQLite write side and the Switch door (2026-10-17 night; data-risk: every catalog save after the flip)

**Answer contract.** First line: `Credits spent: <amount> | Finding count: <N>`. A line `Verdict: <merge | fix | block> …`. Write no files; answer only. Under ~1,000 words.

**One sentence:** after the flip, every catalog save commits exactly the records that changed into catalog.sqlite (one transaction, a savepoint per row, tombstone before any removal-marker move), loses nothing it cannot store (it keeps it in memory and says so), and the Switch door writes the latch only after a fresh import passed and catalog.json's SHA-256 equals the import's source hash.

**Design:** `docs/design/catalog_cutover_f_prime_2026_10_17.md` §3, §7, §10. **Range:** `b34f86c62..3f6e17025` on main (merge of B2 `a237e2be5` + one test fix). Files under `VideoScan/`: Core `VideoScanCore/Sources/VideoScanCore/Commit/*` (CatalogChangeDetector, HashingEncoder, CatalogCommit, CatalogCommitBody, CatalogRecordDiff), `VideoScanCore/Sources/VideoScanCore/Store/GRDBCatalogRepository+Live*.swift`, `Store/CatalogRepository.swift` (CatalogLiveReading + transaction doors), the v3_live_writes migration (row_knowledge), `Import/CatalogImporter+Rows.swift` (pair link); app `VideoScan/Catalog/CatalogCommitter.swift`, `Catalog/CatalogSwitchToSQLite.swift`, `Catalog/CatalogCutoverState.swift`, the funnels in `Model/VideoScanModel.swift`; tests `VideoScanTests/CatalogCutoverWriteSideTests.swift` + Core `Tests/VideoScanCoreTests/Commit/*`.

**Attack (prove with file:line or say it holds):**
1. NO SILENT LOSS: an edit to a record that the detector misses (a field the encoder doesn't cover; a change made between snapshot and baseline update; two edits inside one debounce where the second reverts the first); the baseline moving for a row that was NOT written; a deferred/refused row whose later edit is never resent.
2. ROW ATOMICITY: savepoint per row — can a refused row leave display rows, row_knowledge, derived rows or a tombstone behind? Tombstone-before-marker under every marker transition.
3. CURATED KNOWLEDGE: the agent copies changed curated fields onto every same-content in-memory record — can that overwrite a value the user set on a sibling in the same window? Is an untouched conflict ever written over? Does `row_knowledge` get a row for every curated change (and never for derived)?
4. THE SWITCH: refusals before anything moves; the rehearsal MOVE (never delete) of all five files; the re-import; freeze + SHA proof + un-freeze on mismatch; designation into catalog_state; latch last with fsync; what if the app crashes between each step — what does the next launch see (latch absent → JSON, but catalog.json frozen? stuck?).
5. CONCURRENCY: the committer on the main actor + hashing off it — can a record mutate during hashing and the stale fingerprint become the baseline? Two commits overlapping (debounce + quit)?
6. The known gaps the agent declared (new rows without a digest deferred; marker changing twice in 2 s refused; purged records never deleted from SQLite; direct scheduleSave callers; owner token not compared) — rank them by data-loss risk and say which must close before a real user flips.
**Do only this:** findings (P1 first) with file:line + a one-line failure scenario; at most three P2/P3. **Do not explore outside the files listed above and their tests.**
