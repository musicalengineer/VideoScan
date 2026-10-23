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
