# Codex review — Store durability third pass (F6 admission)

- Range: `main..fix/store-durability-codex141`
- Credits spent: unavailable
- Tokens: 85163
- Finding count: 4
- Verdict: block — cleanup can unlink live SQLite sidecars, and admission still permits an unchecked state to reach a writer.
- Run: 2026-10-26T03:13:22Z (cycle #144, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 4
Verdict: block — cleanup can unlink live SQLite sidecars, and admission still permits an unchecked state to reach a writer.

These are source-level findings with reproducible test recipes, **not executed RED tests**. The read-only sandbox prevented fixture creation; 0 tests executed.

1. **P1 — Cleanup can delete another connection’s live WAL/SHM.**  
   [GRDBCatalogRepository.swift:1158](/private/tmp/claude-501/-Users-rickb-dev-VideoScan/f3133caa-0511-403d-97d1-04039b7d554c/scratchpad/wt-store/VideoScan/VideoScanCore/Sources/VideoScanCore/Store/GRDBCatalogRepository.swift:1158), especially line 1161.

   Absence before opening does not prove ownership afterward. WAL commits need not change the main file, so its unchanged fingerprint does not exclude another writer. Moreover, SHM removal is **independent of the WAL-size check**: a nonempty WAL prevents WAL deletion but does not prevent SHM deletion.

   Reproduction: record the footprint of a WAL database without sidecars; let another process open it, commit a small transaction without checkpointing, and remain connected; invoke cleanup. The main fingerprint remains unchanged, yet the live SHM is removed. New connections can then use a different shared-memory file from existing connections. Separately, a commit or pathname replacement between the WAL stat and unlink can cause deletion of a now-nonempty or unrelated WAL. SQLite documents the resulting lost-transaction/corruption risk when WAL state is separated from its database. [SQLite WAL documentation](https://sqlite.org/wal.html#the_wal_file)

   **RED test:** `foreignSidecarsSurviveAdmissionCleanup` should keep the other process connected and assert both sidecar identities survive cleanup. The SHM assertion fails without requiring the narrower stat/unlink race.

   **Recommendation for Rick:** remove this cleanup and leave sidecars in place, with accurate refusal wording. Moving live sidecars to `.trash/` is also unsafe. The current unlink violates rule 11 and lacks the ownership/exclusion proof needed for an exception.

2. **P1 — Stale admission still publishes a writer after FK integrity changes.**  
   [GRDBCatalogRepository.swift:1250](/private/tmp/claude-501/-Users-rickb-dev-VideoScan/f3133caa-0511-403d-97d1-04039b7d554c/scratchpad/wt-store/VideoScan/VideoScanCore/Sources/VideoScanCore/Store/GRDBCatalogRepository.swift:1250).

   The version recheck closes the supplied version-bump example. It does not preserve the admission verdict: `.admitted` skips both engine checks after their connection and transaction have ended.

   **RED test:** reuse `injectAdmittedHook` on a current fixture. Through a separate queue with foreign keys disabled, execute:

   ```sql
   CREATE TABLE admission_fk_probe (
       generation INTEGER REFERENCES generations(id)
   );
   INSERT INTO admission_fk_probe VALUES (999);
   ```

   Leave `catalog_state.schema_version` unchanged. Assert open refuses with `foreign_key_check`. The traced path instead passes the version check, performs no pending migration, and publishes `.readWrite` despite the violation.

   Validation needs protection against changes through the transition to writer authority. Rechecking only the version does not establish that.

3. **P2 — The second look can checkpoint a refused database on close.**  
   [GRDBCatalogRepository.swift:1207](/private/tmp/claude-501/-Users-rickb-dev-VideoScan/f3133caa-0511-403d-97d1-04039b7d554c/scratchpad/wt-store/VideoScan/VideoScanCore/Sources/VideoScanCore/Store/GRDBCatalogRepository.swift:1207), with deferred close at line 1222.

   `nothingToRecover` describes an unlocked observation, not a guarantee covering the connection’s lifetime. A plain read-write queue need not execute write SQL to modify the main file: SQLite can checkpoint when the last connection closes. [SQLite checkpoint behavior](https://sqlite.org/wal.html#automatic_checkpoint)

   Reproduction: start with the newer-schema WAL fixture without sidecars. Pause the second look inside its read transaction. Another connection commits a small change with automatic checkpointing disabled, then closes while admission remains connected. Resume admission: it refuses the newer schema, ends its transaction, and closes last. That close can checkpoint the other connection’s frames into the main file.

   **RED test:** add barriers around the admission read and close; snapshot the main file after the other writer closes but before admission closes. Assert admission’s refusal leaves those bytes unchanged.

   The same unlocked check also cannot exclude a journal or changed database appearing before the read-write open. “Nothing was written” is therefore not justified by this predicate.

4. **P2 — Admission drops the existing five-second lock tolerance.**  
   [GRDBCatalogRepository.swift:1213](/private/tmp/claude-501/-Users-rickb-dev-VideoScan/f3133caa-0511-403d-97d1-04039b7d554c/scratchpad/wt-store/VideoScan/VideoScanCore/Sources/VideoScanCore/Store/GRDBCatalogRepository.swift:1213).

   Admission leaves GRDB’s `busyMode` at `.immediateError`. The pool’s existing `busy_timeout = 5000` is reached only afterward.

   **RED test:** another process holds `BEGIN EXCLUSIVE` on a healthy current DELETE-mode catalog, releasing it after 250 ms. Call `open` while locked and expect `.readWrite`. Previously pool setup could wait; admission now returns `.unverified(SQLITE_BUSY)` and refuses immediately in a writable folder. Apply the existing timeout to admission.

The opening-path audit is:

| Entry/outcome | Pool path |
|---|---|
| `open`: `.admitted` | Read-write attempt; version rechecked; engine checks skipped |
| `open`: `.noVerdict` | Read-write attempt; engine and version checks |
| `open`: `.unverified` | Writable folder refuses; unwritable folder attempts read-only with full checks |
| `open`: `.refused` | No pool |
| `openReadOnly` | Read-only pool; admission itself can take the read-write second look |
| `openForReading` | Read-only pool; full checks |

I found **no successfully published read-write pool that skips both admission and the pool-side version check**. That does not establish “untouched on refusal”: pool construction precedes the latter check. Extending the existing admitted hook to bump the version **and switch to DELETE mode** exposes this—the pool switches it back to WAL before refusing.

For the five specified quiescent cases, the traced `open` outcomes remain: fresh → read-write; older → migrate/read-write; current with empty sidecars → read-write; shell-closed without sidecars → second look/read-write; read-only folder with usable sidecars → read-only. Finding 4 supplies the legitimate-content regression under contention.

`CatalogStoreDurabilityCodex141Tests.swift`: **read, no findings** against its existing assertions; the additional cases above are uncovered.

Scope expansion was limited to the required guidance, `CatalogFileGuard`, GRDB’s connection/configuration implementation, the named repository test’s read-only-folder case, and official SQLite documentation. No files changed.

## Brief

# Codex review brief — Catalog store durability: third pass on F6 (admission before the pool)

**Workflow in one sentence (Rick's words):** "make sure the SQLite database is rock solid" — a catalog file this build must refuse is left exactly as found, and an unverified file never gets a writer.

**Range:** `main..fix/store-durability-codex141` (seven commits; the four new ones are `24d46abdd..1a81e22b2`) · **Worktree:** `/private/tmp/claude-501/-Users-rickb-dev-VideoScan/f3133caa-0511-403d-97d1-04039b7d554c/scratchpad/wt-store` (read-only for you)

**Your closing-pass findings being closed** (docs/reviews/codex/codex-review-store-durability-closing-2026-10-25.md):
- **F6-1 stale admission** → `prepare(admitted:)` always re-runs the schema-version check on the pool's own connection before migration; only integrity/FK checks are skipped when admitted. Test seam `injectAdmittedHook`.
- **F6-2 `.noVerdict` authorised a writer** → admission now has four outcomes: `.admitted`, `.refused(words)`, `.unverified(why)` (file exists, could not be checked), `.noVerdict` (no file). `.unverified` in a writable folder → refused ("could not be verified before opening — it was not opened; nothing was written"); in a read-only folder → a read-only pool with all checks, never read-write. Deterministic hot-journal fixture built by hand.
- **F6-3 sidecars** → (a) when the read-only look fails with a WAL header and no `-wal`/`-journal`, `admit` takes a second look through a plain read-write sqlite connection that runs no pragma and no GRDB setup write (creates only an empty `-wal` and a `-shm`), then the same checks; (b) after a refusal, `AdmissionFootprint` (stat snapshots taken before the open) removes ONLY the `-wal` and `-shm` this open created, only when the main file's dev/inode/size/mtime/ctime are unchanged, the `-wal` did not exist before and is 0 bytes, and the `-shm` did not exist before; each removal is logged. `openReadOnly` (viewer door) gets the same verdict-before-pool; `openForReading` unchanged.

**In scope:** `VideoScan/VideoScanCore/Sources/VideoScanCore/Store/GRDBCatalogRepository.swift` (`admit`, `AdmissionFootprint`, `open`, `openReadOnly`, `prepare(admitted:)`), `Tests/VideoScanCoreTests/Store/CatalogStoreDurabilityCodex141Tests.swift`.

**Invariants to attack:**
1. **The second look writes nothing but two empty sidecars.** A plain read-write connection on an EXISTING file: can it play back a hot journal, run WAL recovery that rewrites the main file, or checkpoint? Prove it cannot, or show the sequence.
2. **The cleanup deletes only what this open made.** The repo's hard rule 11 is "never delete" (move to `.trash/`). Is removing a 0-byte `-wal` and a fresh `-shm` that this process created safe against: another process (VideoScan viewer, Hallie shell, preview helper, `sqlite3` shell, Time Machine) opening the same catalog inside the window between creation and removal; a `-shm` with live lock state; a different file now at that path? Would you instead leave the sidecars and only make the refusal words say so? Give a recommendation Rick can rule on.
3. **No outcome reaches a writer that should not.** Enumerate every path from `open` / `openReadOnly` / `openForReading` to a read-write pool; show one that skips both admission and the pool-side version check.
4. **Nothing legitimate is refused.** A fresh catalog (no file), an older file that must migrate, a current WAL file whose last closer left 0-byte sidecars, a current file whose last closer was a `sqlite3` shell (no sidecars — GH #386), a read-only folder with sidecars: each must reach the same mode as before this branch. Show one that regressed.

**Evidence already run:** each new test seen RED first (stale admission returned `.readWrite`; hot journal played back — main 544768 → 540672 bytes, `-journal` gone, `-wal`/`-shm` created; refused WAL file left `-shm` + 12392-byte `-wal`); new suite 7/7; with OpenCorner + GRDBCatalogRepositoryTests 52 / 3 suites (4 pre-existing known issues); Core `--filter Catalog` 423 / 66 suites, only failure `theRealProbeRunsQuickCheckThroughThisReader` (machine load, GH #385); sensor lane GREEN 573.

**Known and accepted (do not report):** `GRDBCatalogRepository.swift` file length; GH #386 (Apple SQLite refuses read-only WAL open without `-wal`) is a separate ruling; F1 and F4 closed in your last pass.

**Output contract:**
```
Credits spent: <amount> | Finding count: <N>
Verdict: merge | fix | block — <one sentence>
```
Then findings ranked by data-loss risk, each with `file:line`, a reproduction, and a RED test where possible. For every in-scope file with nothing to report write "read, no findings." Do not explore outside the files above unless a finding requires it, and say so.
