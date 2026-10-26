# Codex review — Store durability closing pass (codex #141 F1/F4/F6)

- Range: `main..fix/store-durability-codex141`
- Credits spent: unavailable
- Tokens: 113973
- Finding count: 3
- Verdict: fix — F1 and F4 close for the supported workflow, but F6 still permits stale admission and changes to refused database files.
- Run: 2026-10-26T01:58:02Z (cycle #142, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 3  
Verdict: fix — F1 and F4 close for the supported workflow, but F6 still permits stale admission and changes to refused database files.

Reviewed `cfcde7ed2..749b2ae98`. No source edits. The test attempt stopped because the worktree lacked the built test binary: **0 tests executed**. All regression cases below are **proposed RED tests**, not observed failures.

**1. P1 — Admission can become stale, allowing a newer-schema database to open writable.**

Location: [GRDBCatalogRepository.swift:1075](/private/tmp/claude-501/-Users-rickb-dev-VideoScan/f3133caa-0511-403d-97d1-04039b7d554c/scratchpad/wt-store/VideoScan/VideoScanCore/Sources/VideoScanCore/Store/GRDBCatalogRepository.swift:1075).

`admit` closes its connection before pool construction. `prepare(admitted: true)` then skips both checks. `CatalogFileGuard` compares device/inode; it cannot detect an intervening schema change within the same file.

Reproduction:

1. Admission passes on a current fixture.
2. Before pool construction, another connection commits `catalog_state.schema_version = currentSchemaVersion + 1` and the corresponding `user_version`, preserving the inode.
3. Pool construction succeeds; the identity check passes.
4. `prepare` skips version validation. GRDB’s migrator does not reject unknown migration identifiers merely because they exist.
5. The repository can return `.readWrite` for the newer file.

**Proposed RED:** introduce an after-admission seam performing step 2; require `.refused`. A companion replacement test should swap in a newer rollback-mode fixture at that seam and require byte preservation: the existing identity guard refuses the replacement **after** pool construction has already changed it.

Admission must remain valid through the first potentially mutating operation.

**2. P2 — `.noVerdict` can recover and modify a newer database before refusing it.**

Location: [GRDBCatalogRepository.swift:1054](/private/tmp/claude-501/-Users-rickb-dev-VideoScan/f3133caa-0511-403d-97d1-04039b7d554c/scratchpad/wt-store/VideoScan/VideoScanCore/Sources/VideoScanCore/Store/GRDBCatalogRepository.swift:1054).

Every admission-connection initialization error becomes `.noVerdict`, authorizing a read-write pool. GRDB initialization reads `sqlite_master`; that read can encounter a hot rollback journal.

Reproduction: create a durable newer-schema rollback-mode fixture, then crash a child during a transaction after dirty pages have spilled. The read-only admission cannot perform recovery and throws during initialization. The fallback read-write connection can roll back the journal, change the main file, remove the journal, and activate WAL before the version check refuses it. This follows SQLite’s documented [hot-journal recovery sequence](https://www.sqlite.org/lockingv3.html#dealing_with_hot_journals).

**Proposed RED:** capture the crashed fixture’s main file and journal bytes; call `open`; require refusal and an identical file set and contents afterward.

For an existing file, failed admission must not automatically authorize a writer. A genuinely read-only directory without required WAL sidecars also reaches this fallback; filesystem permissions prevent sidecar creation, rather than admission enforcing the invariant.

**3. P2 — Read-only admission still creates WAL sidecars; the regression oracle misses this.**

Locations: [GRDBCatalogRepository.swift:1053](/private/tmp/claude-501/-Users-rickb-dev-VideoScan/f3133caa-0511-403d-97d1-04039b7d554c/scratchpad/wt-store/VideoScan/VideoScanCore/Sources/VideoScanCore/Store/GRDBCatalogRepository.swift:1053), [CatalogStoreDurabilityCodex141Tests.swift:84](/private/tmp/claude-501/-Users-rickb-dev-VideoScan/f3133caa-0511-403d-97d1-04039b7d554c/scratchpad/wt-store/VideoScan/VideoScanCore/Tests/VideoScanCoreTests/Store/CatalogStoreDurabilityCodex141Tests.swift:84).

A read-only SQLite connection can create `-wal` and `-shm` beside a WAL-mode database in a writable directory. [SQLite documents this explicitly](https://www.sqlite.org/wal.html#read_only_databases).

**Proposed RED:** create and cleanly close a newer-schema WAL-mode fixture with no sidecars; capture directory entries and file contents; call `open`; require refusal and exact preservation.

Under the brief’s **“left exactly as found”** requirement, sidecar creation is a violation. It is not evidence of lost catalog rows, but cannot be silently accepted. Comparing only the main file is insufficient; the existing DELETE-mode test proves only its narrower case.

Other invariant results:

- **F1:** the correction reaches the actual writer after GRDB’s reset. Read-only pools retain the configured setting; volatile pools retain NORMAL. No later lowering was found in the scoped paths. The pragma assignment itself is connection-local.
- **F4:** the display pass is the only current production `.migrate` writer. Pre-fix display passes already wrote that history value, so ordinary older catalogs already have the marker. Nonempty tables skip filling; `.nothingToFill` leaves initial evidence eligible later. Hypothetical additional import evidence would remain undisplayed after completion, but the production importer refuses existing targets.
- **Moved checks:** not byte-identical—an integrity failure now short-circuits before `foreign_key_check`. No additional acceptance-rule defect found. `admitted: true` originates only from successful admission; finding 1 concerns its subsequent validity.

Scoped file accounting:

| File | Result |
|---|---|
| `GRDBCatalogRepository.swift` | Read; findings 1–3 |
| `GRDBCatalogRepository+Display.swift` | read, no findings |
| `CatalogRepository.swift` | read, no findings |
| `CatalogLoad.swift` | read, no findings |
| `CatalogStoreDurabilityCodex141Tests.swift` | Read; missing F6 cases above |
| `GRDBCatalogRepositoryTests.swift` — writer half | read, no findings |

Necessary scope extensions: `CatalogFileGuard`, import admission, direct load callers, and pinned GRDB initialization/migration code. These establish the admission findings and resolve the later-import question.

## Brief

# Codex review brief — Catalog store durability: closing pass on findings 1, 4, 6 of cycle #141

**Workflow in one sentence (Rick's words):** "make sure the SQLite database is rock solid" — a saved edit is on the drive when the app says saved; a file this build must refuse is left exactly as found; a cleared note stays cleared after relaunch.

**Range:** `main..fix/store-durability-codex141` (three commits) · **Worktree:** `/private/tmp/claude-501/-Users-rickb-dev-VideoScan/f3133caa-0511-403d-97d1-04039b7d554c/scratchpad/wt-store` (read-only for you; the branch is rebased on main `cfcde7ed2`)

**Your own findings being closed** (docs/reviews/codex/codex-review-catalog-store-consistency-2026-10-25.md):
- **F1** — the archival writer ran `synchronous=NORMAL` after GRDB's WAL setup. Fix: `makePool` runs `pool.writeWithoutTransaction { PRAGMA synchronous = <durability> }` right after construction, before migration or any write; readers unchanged; test seam `writerPragmas()`; both pragma tests now assert on the writer.
- **F6** — a newer-schema file was switched to WAL before being refused. Fix: `admit(url)` opens a read-only `DatabaseQueue` and runs `integrity_check`, `foreign_key_check` and the schema-version check BEFORE the pool exists; `.refused` → words, no pool; `.admitted` → pool built, `prepare(admitted: true)` skips the O(file) checks; `.noVerdict` (no file yet / no read-only connection possible) → the read-write door runs the checks itself as before. `openForReading` / `openReadOnly` pass `admitted: false`.
- **F4** — clearing the last curated value brought the imported value back on the next load. Fix: `displayPassPending()` = curated display tables empty AND no `.migrate` row in append-only `generation_history` (the display pass's own completion marker; `.nothingToFill` writes no marker by design — a read-only store must not be written just to say so).

**In scope (read these and their direct callers; nothing else):**
- `VideoScan/VideoScanCore/Sources/VideoScanCore/Store/GRDBCatalogRepository.swift` — `makePool`, `admit`, `open`, `prepare(admitted:)`, the open-check extension, `writerPragmas()`
- `VideoScan/VideoScanCore/Sources/VideoScanCore/Store/GRDBCatalogRepository+Display.swift` — `displayPassPending()`
- `VideoScan/VideoScanCore/Sources/VideoScanCore/Store/CatalogRepository.swift` — protocol change
- `VideoScan/VideoScanCore/Sources/VideoScanCore/Load/CatalogLoad.swift` — the caller
- Tests: `Tests/VideoScanCoreTests/Store/CatalogStoreDurabilityCodex141Tests.swift` (new), `GRDBCatalogRepositoryTests.swift` (writer half)

**Invariants to attack:**
1. **F1 is complete, not cosmetic.** Is `PRAGMA synchronous` set on the connection that actually commits (GRDB's writer), on every pool the repository can create (read-write, read-only, volatile), and does nothing later lower it again (a checkpoint, a `journal_mode` change, a reopen after a write hold)? Does `writeWithoutTransaction` before migration risk anything on a file that then fails admission?
2. **F6 leaves no trace.** With the read-only admission connection: can it create `-shm`/`-wal`, change `journal_mode`, or bump anything on a WAL-mode file in a writable folder? (The worker notes `-shm` may appear — say whether that violates "never written to" or is acceptable, and whether the test's byte comparison of the MAIN file is the right oracle.) On a read-only folder with no `-shm`, does `.noVerdict` fall through to a path that writes? Can `.admitted` be stale by the time the pool opens (file replaced between admission and pool — the `CatalogFileGuard` identity check)?
3. **F4's marker is correct in every order.** `generation_history` rows with `writer = 'migrate'` — is the display pass the ONLY writer of that value, forever? What happens on a catalog imported before this fix (no marker, tables already filled → must not re-fill), on an empty catalog (`.nothingToFill`, no marker, then a first import), and on a catalog where the display pass ran, Rick cleared everything, then a NEW import run adds knowledge rows — does the new import's values ever get displayed?
4. **Nothing else moved.** The open-check statics moved into a same-file extension: byte-identical logic? `prepare(admitted: true)` skipping `integrity_check` — is there a path where admission did NOT run but `admitted: true` is passed?

**Evidence already run:** RED seen for each (F1: writer `PRAGMA synchronous` read 1, expected 2; F6: header bytes 18/19 read 2/2 (WAL) and a `-wal` appeared beside the refused file; F4: relaunch reported `.filled(rows: 1)` and the cleared note came back). Core `swift test --filter Catalog`: 419 tests / 66 suites green (13 pre-existing known issues, none in touched files); new suite 3 tests; manifest validator errors [].

**Known and accepted (do not report):** `GRDBCatalogRepository.swift` is over SwiftLint's file length (pre-existing); findings 2, 3 (committer / baseline) are on a separate branch; finding 5 is GH #384.

**Output contract:**
```
Credits spent: <amount> | Finding count: <N>
Verdict: merge | fix | block — <one sentence>
```
Then findings ranked by data-loss risk, each with `file:line`, a reproduction, and a RED test where possible. For every in-scope file with nothing to report write "read, no findings." Do not explore outside the files above unless a finding requires it, and say so.
