# Codex review — migrate_data catalog move

- Range: `1d21128da..working-tree`
- Credits spent: unavailable (meter not exposed)
- Tokens: 57007
- Finding count: 5
- Verdict: fix** — resolve the source-write and SQLite-set hazards before `--go`.
- Run: 2026-10-23T00:47:49Z (cycle #122, tools/codex_review.py)

## Codex answer

Credits spent: unavailable (meter not exposed) | Finding count: 5

Verdict: **fix** — resolve the source-write and SQLite-set hazards before `--go`.

All references below are to [migrate_data.sh](/Users/rickb/dev/VideoScan/install_videoscan_dev_dependencies/migrate_data.sh).

1. **P1 — Other SQLite databases can inherit unrelated destination WALs.** [L122](/Users/rickb/dev/VideoScan/install_videoscan_dev_dependencies/migrate_data.sh:122)  
   **Scenario:** The M4 has checkpointed `audio-fingerprints.sqlite` without a WAL; the Ultra has an older database with a hot WAL. Rsync replaces the database but retains the Ultra’s WAL because nothing deletes or moves it. Opening that mismatched pair risks corruption; catalog-only validation cannot detect it. SQLite explicitly documents this failure. [SQLite guidance](https://www.sqlite.org/howtocorrupt.html#_mispairing_database_files_and_hot_journals)  
   **Fix:** Stage and validate every database with its matching journal/WAL, preserving existing destination sets together and rebuilding SHM. Require all database users/helpers on both machines to remain stopped throughout migration: `pgrep -x VideoScan` does not establish that.

2. **P1 — The source can be written even during dry run.** [L134](/Users/rickb/dev/VideoScan/install_videoscan_dev_dependencies/migrate_data.sh:134)  
   **Scenario:** Source tracked-file stat information needs refreshing; remote `git status` creates an index lock and updates `.git/index`. Git documents this default behavior. [Git documentation](https://git-scm.com/docs/git-status#_background_refresh)  
   **Fix:** Use `git --no-optional-locks … status` for source inventory. Separately, dry run also creates, writes, and removes the local temporary list at L129–138; use an in-memory inventory if “truly dry” means zero local file writes.

3. **P2 — Catalog validation suppresses failures.** [L92](/Users/rickb/dev/VideoScan/install_videoscan_dev_dependencies/migrate_data.sh:92), [L174](/Users/rickb/dev/VideoScan/install_videoscan_dev_dependencies/migrate_data.sh:174)  
   **Scenario:** A schema-version-12 SQLite database without a `files` table passes `quick_check`; the count query fails, but `bad` remains zero. Reproduced using an in-memory fixture. Separately, failed hash commands return success through trailing `true`; equally incomplete manifests can compare equal.  
   **Fix:** Propagate every hashing/query failure, require successful hashes for mandatory files, explicitly represent absent optional files, and make a failed/non-numeric row count fatal.

4. **P2 — Failed source inventory silently skips family data.** [L134](/Users/rickb/dev/VideoScan/install_videoscan_dev_dependencies/migrate_data.sh:134)  
   **Scenario:** SSH fails while listing ignored paths; the pipeline’s `|| true` converts failure into an empty successful list. The subsequent rsync can transfer nothing and the script still finish successfully. Reproduced with SSH status 255.  
   **Fix:** Check SSH/Git completion separately from filtering. Accept “no matching paths” deliberately; abort on transport, Git, or filtering errors.

5. **P2 — Master reporting manufactures agreement and permits disagreement.** [L195](/Users/rickb/dev/VideoScan/install_videoscan_dev_dependencies/migrate_data.sh:195)  
   **Scenario:** Missing preferences—or failed remote SSH—become `RicksM4.local`, making unknown settings appear identical. Actual disagreement only prints a warning before the final instruction to open VideoScan.  
   **Fix:** Distinguish unset, unreadable, and explicit settings; require a verified common effective master before success. The correct defaults domain and application fallback cannot be established from this file alone.

`bash -n` passed. Bash 3.2 checks confirmed the remote loop’s quoting works. A stationary database plus its intact hot WAL is a valid copy even after a crash; excluding SHM is appropriate. Hash equality does not establish that helpers are stopped. [SQLite documentation](https://www.sqlite.org/howtocorrupt.html#_backup_or_restore_while_a_transaction_is_active)

Other reviewed paths: **read, no findings** in the pull-only rsync direction, receiver-side backup placement, or `mv -n` collision check. Nonempty directory replacement requires deletion/force behavior absent here. [Rsync documentation](https://www.samba.org/ftp/rsync/rsync.1)

No migration or filesystem fixture tests were run; no files were written.

## Brief

# Codex brief: migrate_data.sh — the catalog move M4 → M5 Ultra (2026-10-22; Rick approved this pass)

**Answer contract.** First line: `Credits spent: <amount> | Finding count: <N>`. A line `Verdict: <merge | fix | block> …`. Write no files; answer only. Under ~700 words.

**Range:** `1d21128da..working-tree`. One file: `install_videoscan_dev_dependencies/migrate_data.sh` (209 lines; the catalog-set handling in sections 0, 4 and 5 is new and uncommitted).

## What it is for
On Tue 10/27 Rick's new Mac Studio (M5 Ultra) arrives. After the dev tools are installed, this script PULLS VideoScan's irreplaceable data from the M4 over ssh with Homebrew rsync:
- `~/Library/Application Support/VideoScan/`: the SQLite catalog (`catalog.sqlite` + WAL, the `catalog.cutover` marker, and the frozen `catalog.json`), People, CyberBrain, the media ledger, archive journals, and other SQLite files such as `audio-fingerprints.sqlite`;
- the git-ignored family data inside `~/dev/VideoScan`.

It runs as a dry run by default, `--go` copies, it never deletes, and it keeps replaced files as `*.pre-migrate-<stamp>`. The app must be quit on both Macs. The M4 is never written.

## Invariants to attack (data loss = the catalog, the ledger, People data)
1. **The source is never written.** Look at every ssh and rsync, including `--backup` and the rsync-path. Does anything create, modify or lock a file on the M4?
2. **The copied catalog is consistent, or the script says it failed.**
   - SQLite in WAL mode: is copying `catalog.sqlite` + `-wal` (excluding `-shm`) with the app quit a consistent snapshot?
   - What if the M4 app was killed and left a hot WAL, or another process (a nightly job, `scripts/hallie`, a `--hallie` helper, sqlite3) has the DB open, given that `pgrep -x VideoScan` only matches the GUI process name?
   - Can the "hashes equal before and after" proof pass while the copy is still inconsistent?
3. **Other SQLite databases in App Support** (`audio-fingerprints.sqlite` with its own `-wal`/`-shm`, `metadata_cache.sqlite`, `personfinder_cache.sqlite`, older `catalog.pre-*.sqlite` backups) go through the generic rsync with no WAL handling or proof. Is that a corruption risk on the Ultra?
4. **Nothing on the Ultra is lost.** `--backup` with no `--delete`: is any file still replaced without a backup, for example by the `mv -n` of a leftover WAL, or by a directory replaced by a file?
5. **The dry run is truly dry.** Does any step write under the dry run, on either Mac?
6. **Exactly one master.** Section 5 reads `CatalogSyncMasterHostname` on both Macs. Is the defaults domain right? Is the fallback to "RicksM4.local" when unset misleading?
7. **bash 3.2 / `set -euo pipefail`.** Can a failing `grep` or `ssh`, an empty variable, or quoting in `catalog_hashes`' remote `for` loop abort the run part-way after the copy, or let a check silently pass? Look especially at paths with spaces ("Application Support").

## Evidence already run
- `bash -n` passes.
- The earlier dev-installer pass (#121) covered `install.sh` and its steps, which are not in scope here.
- No full `--go` run yet: VideoScan was running. The real run happens on 10/27 with `--from <M4 TB-bridge IP>`.

## Known and declared, NOT findings
- Ollama and HF caches are optional and re-downloadable.
- `preview-cache/` and `HallieKokoro*` are rebuilt.
- The STEAM symlink is recreated by hand.
- Whether the catalog identifies volumes by UUID or by device number is a separate check Rick does before the move.

At most FIVE findings, most serious first, each with a one-line failure scenario and the fix. P1 = data loss, a corrupt catalog on the Ultra, or the source written.

**Do not explore outside `install_videoscan_dev_dependencies/migrate_data.sh`.**

## Closure (2026-10-22 night, Claude)

Each finding checked against the source; all five held. Pinning tests: `tests/test_migrate_data.py`, a sandbox with two fake homes, stubbed ssh, pgrep and defaults, and real Homebrew rsync. All 6 tests are red on the pre-fix script and green after the fix.

1. **Other SQLite sets pair with stale WALs: fixed.**
   - Every `*.sqlite` on the source is now a set: any `-wal`, `-shm` or `-journal` beside it on this Mac is moved aside first, and every `-shm` is excluded from the copy.
   - All databases and their WALs, plus `catalog.cutover` and `catalog.json`, are SHA-256 proven after the copy, and each database is quick_checked.
   - Process check: `pgrep -f` now covers the app binary, the `--hallie` helper, `previewsweepd` and `findtagd`, and **lsof on every SQLite file in App Support on both Macs** refuses if anything has one open. An ssh failure is a refusal.
   - Tests: `test_go_copies_hot_wal_and_proves_it` and `test_database_open_on_source_refuses`.
2. **Source written by `git status`: fixed.**
   - `git --no-optional-locks`. Verified in the sandbox: a plain `git status` rewrote the source index, and the fixed form left it alone. Every test asserts the source `.git/index` is byte-unchanged.
   - The temporary list file is gone; the list is held in memory and passed to rsync by process substitution.
   - Test: `test_dry_run_writes_nothing_on_either_side`.
3. **Validation suppressed failures: fixed.**
   - Hashing fails if any set file is missing or unreadable; there is no trailing `true`.
   - The row count must be numeric.
   - Tests: `test_catalog_without_files_table_fails`, plus the hot-WAL test.
   - **Found by the sandbox, beyond codex:** `sqlite3 -readonly` cannot open a WAL database with no `-shm`, so every real `--go` would have reported FAILED. Checks now run on a scratch copy of the set; the copied bytes are never opened.
4. **Inventory failure skipped family data silently: fixed.** ssh and git failures abort. Only the filters may match nothing, and "0 paths" is reported explicitly. Test: `test_ssh_failure_listing_ignored_files_aborts`.
5. **Master agreement manufactured: fixed.**
   - States are now set, unset (the app default, `CatalogSync.swift:100`), or unreadable, which is fatal.
   - Disagreement exits 3, not success.
   - The defaults domain `Rick-Breen.VideoScan` is verified against `PRODUCT_BUNDLE_IDENTIFIER`.
   - Test: `test_masters_disagree_is_not_success`.

Not yet run: a real `--go` between two Macs. That happens on 10/27 with `--from <M4 TB-bridge IP>`.

## Closed

Closed by `HEAD` at 2026-10-23T00:54:18Z. 5/5 fixed; 6 sandbox tests red→green
