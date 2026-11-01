# Cleanup and operations — the proposals waiting on Rick

Status: in flight — 2026-11-01. Three proposals, none executed: the 10/31 disk cleanup inventory (Rick reviews, then `.trash/` first; nothing has been moved or deleted), Audit Archive (proposed 2026-10-15, not built), and the `VideoScanModel` split (#337, plan waiting on Rick's go on its §6). The removal machinery they lean on is built; its contracts are in `docs/ARCHITECTURE.md` §10.3–§10.4.

This is where operational proposals wait for Rick's word: what to clear off the disks (Part I, ≈ 118 GB reclaimable if every DELETE is accepted), an overnight health check of the Master Archive that audits and never fixes (Part II), and how to split the god object without changing behaviour (Part III). The last section summarises the built designs for letting copies go — one removal marker, one Trash engine, Cleanup, PrunePlan — whose full texts are archived.

**Contents:** Part I — Cleanup proposal (inventory, 2026-10-31) · Part II — Audit Archive (proposed 2026-10-15) · Part III — Splitting `VideoScanModel` (#337, 2026-10-19) · Built: letting copies go (summaries).

# Part I — Cleanup proposal, 2026-10-31 (inventory only; nothing moved or deleted)

*Rick, 2026-10-31: "cleanup application files, backup files, old catalogs we don't need… tomorrow I will review and then eventually we can delete. We always have git."*

This is the list Rick reviews before anything is removed. Every row carries a recommendation
(**KEEP** / **ARCHIVE** elsewhere / **DELETE** after review) and the reason. Sizes are `du -sh` on the
M5 Ultra on the evening of 2026-10-31; dates are file mtimes. No `rm`, `mv`, `git worktree remove`
or `git branch -d` was run to produce this document; the live `catalog.sqlite` was not opened.

**Where the space is (≈ 157 GB inventoried):** DerivedData per worktree 48 GB · worktrees 37 GB ·
Hugging Face model cache 27 GB · `~/Library/Logs/VideoScan` 20 GB (18 GB of it is *build output* that
the gauntlet runner left inside its run folders) · App Support 10 GB · Xcode DerivedData 5.7 GB ·
nightly DerivedData 5.2 GB.

**If Rick accepts every DELETE below: ≈ 118 GB reclaimed; ≈ 0.6 GB moves to cold storage (ARCHIVE).**

---

## 1. `~/Library/Application Support/VideoScan/` — 10 GB

### 1a. Why the JSON catalog copies are dead

- `docs/DECISIONS.md` 2026-10-17 ("Import, don't babysit the JSON"): *cut over, freeze the JSON read-only.*
- `docs/DECISIONS.md` 2026-10-18: *Cutover executed. `catalog.sqlite` is the authority.* The latch
  `catalog.cutover` reads `switchedAt 2026-10-18T15:39:47Z`, `sourceGeneration 4900`,
  `sourceSHA256 749df382…`.
- `docs/DECISIONS.md` 2026-10-20: *import verbs retired; remove Core `Import/`, the JSON read path and
  `JSONCatalogRepository`; the frozen JSON stays as history.*
- `docs/DECISIONS.md` 2026-10-21 (#354): *No quarter for old JSON — no JSON fallbacks or compat paths.*
- `docs/ARCHITECTURE.md` §Catalog store: *The frozen `catalog.json` is history.*

So exactly one JSON file is history worth keeping: **`catalog.json`** — its whole-file SHA-256 is
`749df382a6b25200e32ccab430eef6794846e930223b3439f59fdd45c8ddaef0`, byte-for-byte the
`sourceSHA256` in `catalog.cutover`. It is the file the SQLite catalog was imported from, and
`install_videoscan_dev_dependencies/migrate_data.sh` carries it with `catalog.sqlite` and
`catalog.cutover` as a matched set (DECISIONS 2026-10-05/22). Every other `catalog.*.json` beside it
is an older safety copy of a format no code path can read any more.

**rg check (what the repo still reads).** Before calling a name dead I searched the repo (excluding
`docs/archive/`, `.scratch/`, logs, venvs) for each prefix:

| Name / prefix | Still written by | Still read by | Verdict |
|---|---|---|---|
| `catalog.json` | nothing | `migrate_data.sh` copies it as part of the matched set | KEEP (the frozen source; SHA matches `catalog.cutover`) |
| `catalog.json.prev` | `CatalogStore.swift` JSON-era rotate (dead path, step G) | tests only, in temp dirs | DELETE — byte-identical to `catalog.json` (same SHA-256 `749df382…`) |
| `catalog.pre-*.json` (65 files) | JSON-era `snapshotCatalog` (relocate, merge, purge, dedup, target-removal, show-again, notes-repair…) | nothing; tests create their own in temp dirs | DELETE — all dated 2026-05-30 … 2026-10-14, every one before the 10/18 cutover |
| `catalog.manual-*.json`, `catalog.snapshot_*.json`, `catalog.preserved-*.json` | hand-made (Rick / agents) | nothing | DELETE — Jun–Aug JSON-era |
| `catalog.recovery-*.json` | `App/CatalogQuitRecovery.swift` (still live) | nothing merges them; the app only *counts* them in a quit log line | DELETE — the 10/18 one was written 3 min after cutover; the 10/22 one by the viewer-quit bug fixed in `CatalogPhaseHoldAndQuitTests` |
| `catalog.pre-dup-split.*.sqlite` | `MediaOps/VideoScanModel+DuplicateDigestSplit.swift` (`snapshotCatalog(prefix:)`, write-only) | nothing | ARCHIVE — the only pre-split SQLite copy; DECISIONS 2026-10-20 says the split loses nothing, and `backups/pre-p0-restore-2026-10-23` is newer |
| `catalog.search-index.v1.plist.pre-*` / `.poisoned-*` | nothing | nothing | DELETE |
| `*.pre-migrate-20261027-163522` | `migrate_data.sh` (`--backup --suffix`) | nothing; the Ultra has run green since 10/27 | DELETE |
| `catalog-sqlite-rehearsal-20261018-113849/` | the 10/17–18 import rehearsal | nothing (rg: no hits) | DELETE — superseded by the live store the same morning |
| `one_time_cleanup_2026_10_11/` | the cleanup v1 dry run | nothing; `CleanupTrashPlanTests.swift` says the Python test was ported case by case | ARCHIVE the two small CSVs + summary if Rick wants the record; DELETE the 69 MB JSON copy |
| `POI-backup-20260913-141614/`, `POI-backup-20260919-displaynames/` | `People/POIStorage.swift` writes `POI-backup-<stamp>` before a migration | nothing reads them back | DELETE after review — recognition is frozen (DECISIONS 2026-10-23); APFS clones, so freed space may be less than `du` shows |
| `backups/pre-p0-restore-2026-10-23/` | the P0 restore on 10/23 (`catalog.sqlite` `.backup` + highwater) | nothing automatic | KEEP — the one SQLite-era safety copy; 8 days old |
| `.sync-previous/` | `Catalog/CatalogSync.swift` keeps one generation back and resets it on every sync | the sync itself | KEEP — app-owned, self-rotating (950 MB) |
| `viewer-catalog/` | `CatalogViewerSnapshot.swift` (`VACUUM INTO` seal for the viewers) | viewers | KEEP — live |
| `web-proxies/` | `Hallie/Web/HallieWebProxy.swift` | Hallie web answers (frozen feature) | DELETE after review — two proxy renders from 2026-08-30, regenerable |
| `hallie-e1/snapshots/` | `scripts/hallie_demo/snapshot.py` | `scripts/hallie_e1/runner.py` reads the newest | KEEP (38 MB) |
| `findtag-journal/` (425 entries, 572 MB) | `findtagd` daemon via `FindTagJournal.swift` ("journal accretes") | the app on next launch | KEEP, but **no bound was found in the code** — propose a retention rule (an issue, not an edit) |
| `_retired/` (team-channel, channel-watcher 2026-10-02) | nothing | nothing | DELETE (6 MB) |
| `_POI_quarantine/<first-name>_2026-06-17/` | the June POI quarantine | nothing (rg: no hits) | ARCHIVE or DELETE (804 KB; recognition frozen) |

### 1b. The table

| Path (under App Support/VideoScan) | Size | Last changed | Recommendation | Why |
|---|---|---|---|---|
| `catalog.sqlite` (+`-wal`, `-shm`), `catalog.cutover`, `catalog.highwater(.log)`, `catalog.generation.max`, `catalog.lock` | 305 MB | 2026-10-31 | **KEEP** | the live catalog and its latch/witness |
| `catalog.json` | 76 MB | 2026-10-18 | **KEEP** | frozen cutover source; SHA matches `catalog.cutover`; migrate_data carries it |
| `catalog.json.prev` | 76 MB | 2026-10-18 | **DELETE** | byte-identical to `catalog.json` |
| `catalog.pre-relocate.*.json` ×28 | 1.18 GB | 2026-05-30 → 2026-08-27 | **DELETE** | JSON-era relocate safety copies; two of them (06-19 pair) are byte-identical to each other |
| `catalog.pre-dup-crossvolume.*.json` ×13 | 0.76 GB | 2026-08-18 → 2026-10-03 | **DELETE** | JSON-era duplicate-job safety copies |
| other `catalog.pre-*.json` ×24 (coverart/nonvideo/nostream/fragment purge, dedup, merge, target-removal, volume-rename, show-again, notes-repair, rawvalue, salvagestage, retire-backfill, triage, restore-merge, danglingrepair/purge) | 2.11 GB | 2026-06-01 → 2026-10-14 | **DELETE** | JSON-era; the four 2026-07-21/14 files are 204–210 MB each (pre-purge catalog with cover-art blobs) |
| `catalog.manual-backup-*.json` ×2, `catalog.manual-snapshot.*.json`, `catalog.snapshot_2026-06-17_prewipe.json`, `catalog.preserved-pre-target-removal.*.json` | 0.49 GB | 2026-06-17 → 2026-08-18 | **DELETE** | hand-made JSON-era copies |
| `catalog.recovery-20261018-114107.json`, `catalog.recovery-20261022-190512.json` | 151 MB | 2026-10-18, 10-22 | **DELETE** | quit-recovery copies of the frozen JSON; nothing merges them |
| `catalog.pre-dup-split.2026-10-20T18-21-35Z.sqlite` | 193 MB | 2026-10-20 | **ARCHIVE** | SQLite-era pre-split copy; keep cold, off the boot drive |
| `backups/pre-p0-restore-2026-10-23/` | 286 MB | 2026-10-23 | **KEEP** | newest SQLite safety copy (`.backup`) |
| `catalog-sqlite-rehearsal-20261018-113849/` | 218 MB | 2026-10-18 | **DELETE** | import rehearsal, superseded the same morning |
| `one_time_cleanup_2026_10_11/` | 75 MB | 2026-10-12 | **DELETE** (ARCHIVE the 3 MB of CSV/summary if wanted) | cleanup v1 dry-run artefacts; test ported to Swift |
| `POI-backup-20260913-141614/`, `POI-backup-20260919-displaynames/` | 207 MB + 207 MB | 2026-09-13, 09-19 | **DELETE** after review | pre-migration clones of `POI/`; nothing reads them; recognition frozen |
| `catalog.search-index.v1.plist.pre-*` ×2, `.poisoned-2026-07-19`, `.pre-migrate-*` | 80 MB | 2026-07 / 10-27 | **DELETE** | dead search-index snapshots; the live `.plist` is rebuilt by the app |
| `metadata_cache.sqlite*.pre-migrate-20261027-163522` ×3 | 48 KB | 2026-10-27 | **DELETE** | migrate_data leftovers; Ultra green since |
| `web-proxies/` | 295 MB | 2026-08-30 | **DELETE** after review | two Hallie web proxy renders + posters; regenerable; feature frozen |
| `events-decisions.manual-backup-*.json` ×2, `events-decisions.json.prev` | 44 KB | 2026-10-19 | **DELETE** | the `-1850` copy is byte-identical to the live `events-decisions.json` |
| `integrity-2026-10-{17,18,20,22}.json` | 1.4 MB | Oct | **DELETE** | `integrity-latest.json` == `integrity-2026-10-28.json` (same SHA); older runs are not needed once the latest exists |
| `fragment-purge-report.*.txt`, `nostream-purge-report.*.txt` | 540 KB | 2026-07-23 | **ARCHIVE** | JSON-era purge receipts; small, human-readable, worth a cold copy |
| `_retired/` | 6 MB | 2026-10-02 | **DELETE** | retired team-channel / channel-watcher state |
| `_POI_quarantine/` | 804 KB | 2026-06-17 | **ARCHIVE** | June quarantine of one person's POI folder |
| `.sync-previous/` | 950 MB | 2026-10-31 | **KEEP** | CatalogSync's one-generation-back; the app resets it itself |
| `viewer-catalog/` | 262 MB | 2026-10-31 | **KEEP** | sealed viewer snapshot, live |
| `findtag-journal/` | 572 MB | 2026-10-31 | **KEEP** (needs a bound) | daemon journal, in use; no retention rule in `FindTagJournal.swift` — file an issue |
| `family-tree/` (assets 377 MB, compiled 87 MB) | 473 MB | 2026-10-30 | **KEEP** | Rick's tree; data-risk path |
| `preview-cache/` (9,568 entries) | 434 MB | 2026-10-28 | **KEEP** | regenerable cache, in use by `previewsweepd` |
| `HallieKokoro/` | 369 MB | 2026-10-27 | **KEEP** | TTS runtime installed 10/27 by `install_dev_tools.sh` |
| `audio-fingerprints.sqlite`, `metadata_cache.sqlite`, `personfinder_cache.sqlite` | 289 + 97 + 17 MB | Oct | **KEEP** | live side stores (fingerprints feed Find Master by sound) |
| `POI/`, `cyberbrain/`, `ledger/`, `archive-angel/`, `archivist/`, `date-inference/`, `review-cycles/`, `scan_checkpoints/`, `Hallie/`, `hallie-e1/`, `private-docs/`, `portrait/`, `diagnostics/`, `label-repairs/`, `relocate-audit/`, `delete-duplicates/`, `events-prototype/`, `demo/`, `gh-codex/`, `people-audit/`, `scan_jobs/`, small JSON state files | ≈ 250 MB | various | **KEEP** | app-owned state; not reviewed file by file tonight |

**App Support subtotal — DELETE ≈ 5.9 GB · ARCHIVE ≈ 0.19 GB (+ 4 MB of reports) · KEEP ≈ 4.0 GB.**

No `.trash/` folder exists under App Support. The repo checkout's `.trash/` (128 KB) holds 27
`POI-zztestperson-*` folders written by tests between 10/27 and 10/31 — test fixtures, DELETE.

---

## 2. DerivedData

### 2a. `/Users/rickb/dev/VideoScan-dd/` — 48 GB (agents' per-worktree DerivedData)

| Path | Size | Last changed | Worktree / branch | Merged? | Recommendation | Why |
|---|---|---|---|---|---|---|
| `fix-402/` | 8.1 GB | 2026-10-30 | fix-402 · `fix/nightly-card-lanes` | yes | **DELETE** | branch landed |
| `confirmed-date-filter/` | 7.0 GB | 2026-10-31 | confirmed-date-filter · `feat/confirmed-date-filter` | yes | **DELETE** | landed today |
| `sensors-push/` | 6.5 GB | 2026-10-31 20:18 | main (sensor lane) | — | **KEEP** | the newest warm main build; saves 5–8 min on the next sensor run |
| `ui-smoke/` | 6.1 GB | 2026-10-31 | main (today's testbed UI smoke) | — | **DELETE** | results are in `docs/STATUS.md`; Release rebuilds in minutes |
| `main-lane/` | 6.0 GB | 2026-10-30 | main (earlier sensor lane) | — | **DELETE** | duplicate of `sensors-push/`'s purpose; keep one |
| `bg-service-0/` | 6.0 GB | 2026-10-31 | bg-service-0 · `fix/timing-strict-pinned` | yes | **DELETE** | landed |
| `fix-401/` + `fix-401-core/` | 5.3 + 1.1 GB | 2026-10-30 | fix-401 · `fix/401-location-volume` | yes | **DELETE** | landed |
| `main-core-build/` | 1.1 GB | 2026-10-30 | main (Core package build) | — | **DELETE** | regenerable in ~2 min |
| `full-ultra-results.xcresult`, `full-ultra-results-2.xcresult` | 671 + 651 MB | 2026-10-31 | today's Ultra testbed runs | — | **DELETE** after review | numbers already recorded in `docs/STATUS.md`; keep if Rick wants to open the 1 failure in Xcode |
| `full-ultra-tests*.log` (2 × 44 MB), 60 small `*.log`, `rename-list.txt` | ≈ 90 MB | Oct 30–31 | agent build/merge logs | — | **DELETE** | transient |
| `model-lab-core/` | 0 B | 2026-10-30 | empty folder | — | **DELETE** | empty |

**Subtotal — DELETE ≈ 41.5 GB · KEEP 6.5 GB.**

### 2b. `~/Library/Caches/videoscan-nightly-dd` — 5.2 GB

**KEEP.** `scripts/nightly_local_tests.sh:1045` builds there (`NIGHTLY_DD`); the script `rm -rf`s it
itself when it needs a clean build.

### 2c. `~/Library/Developer/Xcode/DerivedData` — 5.7 GB

| Path | Size | Last changed | Recommendation | Why |
|---|---|---|---|---|
| `VideoScan-awdqzabjhjsdepacsmfxmodpxedx/` | 4.1 GB | 2026-10-31 21:10 | **KEEP** | `info.plist` → `WorkspacePath = /Users/rickb/dev/VideoScan/VideoScan/VideoScan.xcodeproj`: Rick's own Xcode build (rule 11) |
| `VideoScan-gvoeumujlewivjaqtxbjyyuxbptb/` | 568 MB | 2026-10-28 23:09 | **DELETE** after review | no `info.plist`, only `Logs/` + `SourcePackages/`; an orphan from an Xcode session on 10/28 |
| `ModuleCache.noindex`, `SDKExplicitPrecompiledModules`, `SymbolCache.noindex`, `SDKStatCaches.noindex`, `CompilationCache.noindex` | ≈ 1.1 GB | Oct | **KEEP** | Xcode-managed shared caches |

### 2d. DerivedData hiding inside worktrees (counted in §3's sizes)

`gedcom-pull-dates/.dd` 5.4 GB · `hallie-baselines-1029/.dd` 5.2 GB + `.dd-release` 3.1 GB ·
`hallie-grade/.dd` 5.8 GB. These go when their worktrees go.

### 2e. DerivedData hiding inside `~/Library/Logs/VideoScan/gauntlet*` (counted in §5)

Each gauntlet run folder carries its own `DerivedData/` (4.7–4.8 GB) and `PackageBuild/` (1.2 GB).
Three run folders → **≈ 18 GB of build products in the Logs folder.** See §5.

---

## 3. `/Users/rickb/dev/VideoScan-wt/` — 37 GB (worktrees)

"Merged" = `git branch --merged main` lists the branch (or the detached HEAD is an ancestor of
main). "Dirty" = `git -C <wt> status --short | wc -l`.

| Worktree | Branch | Merged | Dirty | Size | `.scratch/` | Recommendation | Why |
|---|---|---|---|---|---|---|---|
| `hallie-baselines-1029` | `bench/hallie-baselines-2026-10-29` | yes | 1 (`.dd-release/` untracked) | 9.7 GB | 314 MB: `bench-logs/` 13 MB, `harvest-ultra-20261029.json`, `m4-catalog/` (301 MB copy of the catalog) | **DELETE** after moving `bench-logs/` + harvest JSON (13 MB) to `.scratch/` of main or `.trash/` | landed 10/29; 8.3 GB of it is `.dd` + `.dd-release` |
| `hallie-grade` | `night/hallie-grade-2026-10-29` | yes | 0 | 6.9 GB | 88 KB: 12 Codex briefs/reviews for the Hallie split | **DELETE** after moving the 12 briefs | landed 10/29; 5.8 GB is `.dd` |
| `gedcom-pull-dates` | `feat/gedcom-pull-dates` | yes | 0 | 6.6 GB | none | **DELETE** | landed; 5.4 GB is `.dd` |
| `bench-a1` | `feat/video-llm-bench-a1` | yes | 0 | 3.3 GB | 3.2 GB: `weights-m4/` 2.9 GB (a second copy of the 3B weights, same snapshot id `46d4cf06…` as the HF cache), `catalog-copy.sqlite` 301 MB, `runs/` 6.6 MB | **DELETE** after moving `runs/` (6.6 MB) | landed; the A1 record is in `docs/reviews/video_llm_benchmarks.md` |
| `model-lab-bench` | `feat/video-llm-bench` | yes | 0 | 3.3 GB | 3.2 GB: same shape as bench-a1 (`weights-m4/` 2.9 GB, catalog copy, `runs/` 3.7 MB) | **DELETE** after moving `runs/` + `smoke-summary.md` (4 MB) | landed (A0) |
| `bg-service-0` | `fix/timing-strict-pinned` | yes | 0 | 2.1 GB | 8.8 MB of build/test logs | **DELETE** | landed today |
| `confirmed-date-filter` | `feat/confirmed-date-filter` | yes | 0 | 1.2 GB | none | **DELETE** | landed today |
| `fix-402` | `fix/nightly-card-lanes` | yes | 0 | 1.2 GB | 1.8 MB `review.log` | **DELETE** | landed today |
| `model-lab-core` | `feat/model-lab-core-types` | yes | 0 | 1.2 GB | none | **DELETE** | landed |
| `bench-a2` | `feat/video-llm-review` | yes | 0 | 774 MB | 692 MB: **`runs/` 391 MB with Rick's review verdicts (`verdicts.jsonl`) and the A2/A3 run records; `full-a3-py-r3-n8-rickdated` still being written at 21:24 tonight**; `catalog-copy.sqlite` 301 MB | **KEEP** for now | the review page (`bench.py watch`) runs from here; A3 not yet closed. When it is: move `runs/` and `summary-*.json` somewhere permanent (e.g. `.scratch/bench/` on main or an external folder), then remove. **Never delete `runs/`.** |
| `household-roster` | `feat/household-roster-feasibility` | yes | 0 | 383 MB | 301 MB catalog copy + `results.json`, `preview.md` (70 KB) | **DELETE** after moving the two small files | landed (A7 feasibility published) |
| `fix-401` | `fix/401-location-volume` | yes | 0 | 81 MB | none | **DELETE** | landed |
| `m4-gedcom` | `fix/m4-hallie-gedcom` | yes | 0 | 81 MB | none | **DELETE** | landed |
| `ultra-testbed` | detached at `e3dcdd4e` (in main) | yes | 0 | 80 MB | none | **DELETE** | testbed checkout; nothing of its own |
| `attended-model-review` | `experiment/attended-model-review` | HEAD in main, **5 uncommitted changes** (a new `models_research/` folder under docs, `tools/model-fitness/attended_review.py`, `tests/test_attended_review.py`, two edits) | 5 | 81 MB | 120 KB `models_research/` | **KEEP** | Codex's unmerged pilot, as briefed |
| `process-modes` | `process-modes` (under the `docs/` branch prefix) | **no** (1 commit ahead) | 0 | 81 MB | none | **KEEP** | draft for Rick's review, as briefed |
| `docs-consolidation` | `consolidation-2026-10-31` (`docs/` prefix) | at main tip (no commits yet) | 0 | 82 MB | none | **KEEP** | another agent's task, in flight tonight |
| `file-locations` | `file-locations-2026-10-31` (`docs/` prefix) | at main tip (no commits yet) | 0 | ≈ 80 MB | none | **KEEP** | another agent's task, in flight tonight |
| `cleanup-proposal` | `cleanup-proposal-2026-10-31` (`docs/` prefix) | this document | — | 82 MB | none | **KEEP** until merged | — |

Two worktrees live outside `VideoScan-wt/` and are **KEEP**: `/private/tmp/nightly-metrics-wt`
(branch `metrics`, 3.3 MB — the nightly publisher's; `nightly_local_tests.sh` recreates it) and
`~/Library/Caches/VideoScan/complexity-baseline-wt` (detached, 81 MB — the complexity baseline
script's checkout).

Note on the catalog copies: five worktrees hold a 301 MB `catalog-copy.sqlite` / `catalog-ultra-20261029.sqlite`
under `.scratch/` (bench-a1, bench-a2, model-lab-bench, household-roster, hallie-baselines-1029).
They are git-ignored, but they are full copies of family metadata sitting outside App Support; they
leave with their worktrees.

**Subtotal — DELETE ≈ 33.4 GB (14 worktrees) · KEEP ≈ 1.2 GB (bench-a2, attended-model-review,
process-modes, the three docs worktrees).** The ~30 MB of `.scratch/` records named above move first.

Local branches: once the 14 worktrees are removed, their 14 branches plus the 12 other merged local
branches (`provenance-grade-note`, `status-1030`, `video-llm-review-notes` — all three under the `docs/`
prefix — `feat/background-service-step0`, `feat/video-llm-bench-a2`, `feat/video-llm-bench-a3`,
`fix/402-degenerate-captions`, `fix/406-bench-watchdog`, `fix/gauntlet-manifest-hallie-py`,
`fix/hallie-watch-spacing`, `fix/jobsupervisor-pause-race`, `night/hallie-grade-2026-10-29`) are all in
`git branch --merged main` → `git branch -d` is safe (it refuses an unmerged branch by design).
Keep `metrics`, the `docs/`-prefixed `process-modes`, and `experiment/attended-model-review`.

---

## 4. `~/.cache/huggingface/` — 27 GB

| Path (under `hub/`) | Size | Last changed | Recommendation | Why |
|---|---|---|---|---|
| `models--mlx-community--Qwen3-VL-8B-Instruct-4bit` (snapshot `defcdea7…`) | 5.4 GB | 2026-10-30 | **KEEP** | A2 — "seat the 8B as the era expert" (`docs/STATUS.md`); step 1 builds on it |
| `models--mlx-community--Qwen2.5-VL-3B-Instruct-4bit` (snapshot `46d4cf06…`) | 2.9 GB | 2026-10-30 | **KEEP** | A0/A1 captioner, still the production captioner until step 2 moves captions to the 8B |
| `models--mlx-community--Qwen3-VL-32B-Instruct-4bit` (snapshot `6e5644d3…`) | 18 GB | 2026-10-31 12:56 | **DELETE after the A3 record closes** | benchmarked, "does not earn its cost on era"; `STATUS` says finish the last 24 clips for the record, then park. Re-downloadable (`hf-download-32b.log` shows the command). Parked ≠ cached: the record is the asset, not the weights |
| `xet/` | 4.5 MB | 2026-10-30 | KEEP | downloader cache |

Nothing else is in the cache — no stray models. Two more copies of the 3B weights (2.9 GB each) sit in
`bench-a1/.scratch/bench/weights-m4/` and `model-lab-bench/.scratch/bench/weights-m4/` (§3); they were
rsynced for the M4 and leave with those worktrees.

**Subtotal — DELETE 18 GB (deferred until A3 closes) · KEEP 8.3 GB.**

---

## 5. `~/Library/Logs/VideoScan/` — 20 GB

| Path | Size | Last changed | Recommendation | Why |
|---|---|---|---|---|
| `gauntlet-ultra/2026-10-27T23-12-05Z-8D551690/` | 6.4 GB (DerivedData 4.8 + PackageBuild 1.2 + xcresults 0.35 + logs) | 2026-10-31 (touched) | **DELETE `DerivedData/`, `PackageBuild/`, `caches/`, `swift-cache/`, `tmp/`**; keep `*.xcresult`, `*.log`, `home/` (≈ 0.4 GB) | build products, not evidence |
| `gauntlet-ultra/2026-10-27T23-40-20Z-41157934/` | 6.6 GB (same shape) | 2026-10-27 | same | same |
| `gauntlet/2026-10-29T16-03-01Z-97B0C2DE/` | 6.4 GB (same shape) | 2026-10-29 | same | same (this is the run whose numbers are in `STATUS`) |
| `gauntlet*/history.jsonl`, `pending-metrics.*` | 400 KB | Oct | **KEEP** | the gauntlet's own record and the metrics hand-off |
| `nightly_test_2026103{0,1}_*.log`, `nightly_test_202610{28,29}_*.log` | 4 × 44 MB | 10/28–10/31 | **KEEP the newest 2, DELETE older** | the publisher has already read them; `core-hang-sample.txt` (100 KB) is evidence for a fixed bug — keep |
| `hallie-eval/` (113 files: 76 from 10/28, then 10–15 a night) | 40 MB | 2026-10-31 | **KEEP 14 days** | nightly Hallie grades; the alert script reads the newest |
| `Hallie/hallie-conversation-*.jsonl` (6 files; 10/29 is 20 MB) | 29 MB | 2026-10-31 | **KEEP** | Rick's conversations, one file per day |
| `ollama.log` | 9 MB | — | **KEEP, truncate at 50 MB** | Ollama's own log, appended forever |
| `videoscan.log`, `catalog.log`, `findtagd.log`, `previewsweepd.log` | 4 + 0.1 + 1.8 + 0.2 MB | 2026-10-31 | **KEEP** | the one log sink (rule 5) |
| `scan-audit-2026-10-30T19-05-*.json` ×2 | 8 KB | 2026-10-30 | KEEP | tiny; `DiscoveryAudit.swift` writes one per scan — rotation below covers growth |
| `install/`, `hallie-voice/`, `nightly-*.state/pending`, `toolchain_update*`, `disk_check.log`, `complexity_baseline_commit.json`, `dossier_smear_quarantine_*.json` | < 100 KB | Oct | KEEP | small state and receipts |

No retention rule exists today: `scripts/nightly_local_tests.sh` writes `nightly_test_<stamp>.log` and
never prunes; the gauntlet runner leaves its whole `DerivedData/` in the run folder; nothing rotates
`ollama.log`. **One proposed rule** (for `docs/PROCESS.md`, as an issue): *a run that ends deletes its
own `DerivedData/`, `PackageBuild/`, `caches/`, `swift-cache/`; the Logs folder keeps the newest 3
gauntlet run folders, 14 days of `nightly_test_*.log`, `hallie-eval/*` and `scan-audit-*`, and truncates
any single `*.log` over 50 MB — everything else goes to `~/Library/Logs/VideoScan/.trash/` first.*

**Subtotal — DELETE ≈ 18.2 GB (build products in 3 run folders + 2 old nightly logs) · KEEP ≈ 1.3 GB.**

---

## 6. Remote branches not merged into main (`git branch -r --no-merged main`)

`cherry` = `git cherry main <branch>`: "+N" commits whose patch is not in main, "−N" whose patch is
(landed by another route). "tag first" = `git tag archive/<name> <sha>` before deleting, so the
commits stay reachable — "we always have git" only holds if something still points at them.

| Branch | Last commit | Ahead | cherry | Recommendation | Why |
|---|---|---|---|---|---|
| `origin/metrics` | 2026-10-31 | orphan (2,308) | — | **KEEP** | the nightly publisher's branch |
| `origin/trial/decision-tables` | 2026-10-20 `fcecac71` | 1 | +0 / −0 (merge commit; diff is in main) | **DELETE** | schema-12 decisions merge landed via main |
| `origin/design/provenance-retroactive` | 2026-10-26 `d3428885` | 1 | +0 / −1 | **DELETE** | the design doc landed on main as an equivalent patch |
| `origin/cloud/N1019-R-week` | 2026-10-19 `f069e141` | 1 | +1 | **DELETE after cherry-picking the one file** | a 111-line Codex review (`docs/reviews/`) never merged; two P3s |
| `origin/fix/ci-main-green` | 2026-10-23 `4cd573ac` | 1 | +1 | **DELETE after review** (tag first) | 3 files / 8 lines; main has been green since by other fixes — confirm the Substring-concat fix is on main, then drop |
| `origin/feat/167-catalog-versioning` | 2026-10-02 `406983cc` | 25 | +25 | **DELETE after review** (tag first) | JSON-catalog versioning (GH #167), superseded wholesale by the SQLite cutover (DECISIONS 2026-10-16/18) |
| `origin/wip/r4-untested` | 2026-10-07 `bacd2242` | 6 | +2 / −4 | **DELETE after review** (tag first) | WIP, untested by its own name; 4 of 6 landed another way |
| `origin/parked/show-again-review-2026-10-11` | 2026-10-11 `94625cbd` | 2 | +1 / −1 | **KEEP** (or tag + delete) | parked by name; the check-copies engine (full-hash "check these copies") never landed — Rick's call |
| `origin/feature/metrics-work-board` | 2026-10-20 `8a7f3935` | 2 | +2 | **ASK RICK** | engineering-room metrics work board, 23 files, never merged; unclear whether wanted |
| `origin/fix/committer-lost-writes-codex141` | 2026-10-26 `12a58baf` | 7 | +7 | **ASK RICK** (tag first) | Codex #141/#145 committer fixes, 22 files; `overnight/2026-10-25` says #143 closed as "refuse-and-name" — the 7 commits may be the rejected route, but I did not verify each |
| `origin/worktree-agent-a141c9eca386487e3` | 2026-10-22 `6f977595` | 2 | +2 | **ASK RICK** (tag first) | "Avid pair releases: safety copy + journal before any release" — 41 files on a data-risk path, never merged, no PR |

Merged remotes, safe to delete now: `origin/claude/awesome-gates-o8bcfo` (10/29), `origin/claude/clever-babbage-s18oz7` (10/30),
`origin/overnight/2026-10-25`, `origin/overnight/2026-10-26` — all in `git branch -r --merged main`.

Observed while here: local `main` is **2 commits ahead of `origin/main`** (`67bf4d4d`, `d3d46db0`,
both `tools(data_organization)`), not pushed as of 21:30.

---

## Totals if Rick accepts every DELETE

| Area | DELETE | ARCHIVE (move, don't delete) | KEEP |
|---|---|---|---|
| App Support | 5.9 GB | 0.2 GB | 4.0 GB |
| `VideoScan-dd/` | 41.5 GB | — | 6.5 GB |
| Xcode DerivedData | 0.6 GB | — | 5.2 GB |
| Nightly DerivedData | — | — | 5.2 GB |
| Worktrees | 33.4 GB | 0.03 GB (`.scratch/` records) | 1.2 GB (bench-a2 `runs/` inside it) |
| Hugging Face | 18 GB (after A3 closes) | — | 8.3 GB |
| Logs | 18.2 GB | — | 1.3 GB |
| **Total** | **≈ 118 GB** | **≈ 0.25 GB** | **≈ 32 GB** |

The five largest single items: gauntlet build products in Logs (3 × ~6 GB), the 32B weights (18 GB),
`hallie-baselines-1029` worktree (9.7 GB), `VideoScan-dd/fix-402` (8.1 GB), `VideoScan-dd/confirmed-date-filter` (7.0 GB).

---

## How to execute safely (only after Rick's word, item by item)

1. **Nothing is unlinked.** Every file or folder marked DELETE is *moved* into a `.trash/` folder beside
   its parent (`~/Library/Application Support/VideoScan/.trash/2026-11-01/`, `~/dev/VideoScan-dd/.trash/`,
   `~/Library/Logs/VideoScan/.trash/`), dated, and emptied by Rick a week later. Same disk → the move is a
   rename, instant, no copy.
2. **Order inside App Support:** quit VideoScan and the daemons first (`findtagd`, `previewsweepd` hold
   locks in that folder); never touch `catalog.sqlite*`, `catalog.cutover`, `catalog.highwater*`,
   `.sync-previous/`, `viewer-catalog/`. Re-run the rg table in §1a on the day (one `rg` per name) so a
   reader added since tonight is caught. Move `catalog.pre-dup-split.*.sqlite` and the two purge reports
   to the ARCHIVE location (an external or RAID folder Rick names) before anything else moves.
3. **Worktrees:** for each DELETE row, first copy the named `.scratch/` records (bench `runs/`, Codex
   briefs, roster results, bench-logs) to one place — proposal: `~/dev/VideoScan/.scratch/kept-2026-10-31/<worktree>/`.
   Then `git -C /Users/rickb/dev/VideoScan worktree remove <path>` (it refuses a dirty worktree — that is
   the safety), then `git -C /Users/rickb/dev/VideoScan branch -d <branch>` (lower-case `-d` refuses an
   unmerged branch). `bench-a2` stays until A3 is written up and its `runs/` is copied out and verified
   (`shasum -a 256` both sides).
4. **DerivedData:** move each folder into `VideoScan-dd/.trash/`; keep `sensors-push/`. A later
   `scripts/run_sensors.sh --derived-data` on a fresh path simply rebuilds.
5. **Logs:** move only the `DerivedData/`, `PackageBuild/`, `caches/`, `swift-cache/`, `tmp/` subfolders of
   each gauntlet run into `~/Library/Logs/VideoScan/.trash/`; the `*.xcresult`, `*.log`, `home/` and
   `history.jsonl` stay where the metrics publisher expects them.
6. **Hugging Face:** after the A3 record is in `docs/reviews/video_llm_benchmarks.md`, move
   `hub/models--mlx-community--Qwen3-VL-32B-Instruct-4bit` to `~/.cache/huggingface/.trash/` (or
   `huggingface-cli delete-cache`). Keep the `.locks/` entry harmless; it is tiny.
7. **Remote branches:** `git tag archive/<short-name> <sha>` and `git push origin archive/<short-name>` for
   every tag-first row, then `git push origin --delete <branch>`. Never on `main`, never `--force`.
8. **Then** file two issues from this review: a retention rule for `~/Library/Logs/VideoScan` (one line,
   §5) and a bound for `findtag-journal/` (§1a).

*Inventory produced read-only on 2026-10-31 21:00–21:40 ET by Claude; branch `cleanup-proposal-2026-10-31` under the `docs/` prefix.*

# Part II — Audit Archive (proposed 2026-10-15)

*From `design/audit_archive_2026_10_15.md`, whole; archived at `docs/archive/design/`. Not built (no Audit Archive job in the source on 2026-11-01). Its §2a, tier 0 presence ("every row points at a real file"), is the tier 0 that Verify Catalog runs today (ARCHITECTURE §10.2).*


**Status:** PROPOSED 2026-10-15 (Rick + Claude). No code yet. Reuses Archive ▸ Verify
(fixity), Check Media (ffprobe + the audio diagnosis), the Fingerprint Sound stamps (decode
outcome, audible seconds), and the one Repair door (`repair_center_one_door`). Serves goal 1
(preserve) and goal 5 (repair) in `docs/project_goals.md`.

### 1. In Rick's words

"What if we have a Verify Archive that I can kick off at bed time and let it run overnight …
verifies the catalog is robust and correct, every file pointed to exists and has audible
audio, can be played, video can be verified … in the past I had files that I kept for many
years on a computer, then one day I clicked play and got zilch: the OS was updated and the
codec was obsoleted … Doing this manually by playing every file in the archive with a human
sitting in front of every frame, verifying audio sounds good, well, that's a lot to ask."
"If it is intense we can do it by decade or subsections."

### 2. Principle: audit, never fix

The job reads; it moves, rewrites and transcodes nothing. Every finding is a flag in words
on the record, with the door that fixes it (Repair, Update…, or Promote a better transfer).
The archive stays read-only to background jobs (Rick 2026-09-27).

### 2a. Tier 0 — Audit Catalog: every row points at a real file (Rick, 2026-10-15 evening)

The staging copy of a VHS capture vanished from Projects on October 4 — outside the app, no
receipt, no ledger line — and for eleven days its catalog row posed as a live copy: the
duplicates job held its twin ("could not read the keeper", correctly), and Compare Media's
band said "byte for byte" from the stored hashes while the tiers could not read the file.
Rick: "if by some weird turn of events … someone moved the file or deleted the file, the
catalog has no knowledge … run an audit overnight or periodically or prior to doing a backup
catalog … ensure the catalog entries all have links to real media."

So the first tier is cheap and catalog-wide, not archive-only:
- **What:** stat every live row on every mounted volume (device + inode + size against the
  record's identity stamp where one exists). ~10,000 stats, seconds.
- **Outcome per row:** present · present but changed (size or identity differ: "replaced
  since cataloged") · gone → the existing removal marker `.missing` through the one engine,
  with the audit as the reason; a row whose drive is not mounted is "not asked", never
  marked.
- **When:** every night before the metrics publish; before any catalog backup / export;
  from Catalog ▸ Audit Catalog… on demand. One START / OUTCOME pair; the OUTCOME names the
  counts and the folders where files went missing ("3 gone under Projects/_staging_…").
- **Why it is separate from Rescan:** Rescan asks one volume when you ask; the audit is a
  standing guarantee over the whole catalog and marks nothing but presence.
- **Build first:** it is the smallest piece of this design and it closes the hole that was
  open for eleven days. Compare Media now refuses a verdict for a file that is not on disk
  (RelatedLadder.notOnDisk) — the audit is what keeps that case rare.

### 2b. What to do with the holes — Fix Links (Rick, 2026-10-15 evening)

"So we run an audit and it reports 115 files are no longer where we said … what to do? …
rescan sounds expensive and may reingest stuff we don't want, but we could search for the
missing or moved files and, after reporting the changes or missing links, have at-the-ready
a fix-links with a review."

1. **Group by folder.** One line per vanished folder ("38 gone under Projects/_staging_…"),
   because a folder move or a cleaned staging area is the common cause.
2. **Search before asking, cheapest first, no media read:**
   a. another live catalog row with the same whole-file SHA-256 and size (the file was moved
      and its new place was already scanned) — proven already;
   b. the same file name and size on any mounted drive through Spotlight (`NSMetadataQuery`
      on name + size; instant) — a candidate, confirmed by a full hash before it is called
      the same file;
   c. the vanished folder's name elsewhere on the same drive (the moved-folder case) —
      candidates per file as in b.
3. **Fix Links — one review sheet:** old path · found at · how proven (same SHA-256 /
   name + size, hashed now / not found) · choice per row and per folder: **Relink** (the
   row points at the new path and keeps its hand marks: stars, people, dates, notes;
   when the file was found as a second row the two MERGE — hand marks to the survivor, the
   old row marked "moved, now at …", never deleted) · **Mark missing** (the removal marker
   `.missing`, reason "audit"; visible under Show Removed; relinkable later when a drive
   comes back) · **Leave**. Applied through the one marker engine with a receipt.
4. **Never rescan to fix a hole.** Rescan ingests; Fix Links moves pointers. Nothing enters
   the catalog from the audit.

Outcomes: relinked · merged · marked missing · left · could not prove (a name + size
candidate whose hash differs: shown, never relinked).

### 3. The job: Archive ▸ Audit Archive…

An MFO job (chip AUDIT), overnight, resumable, scoped to the whole archive or one decade.
Confirm sheet: files to audit, bytes to read, time at the archive drive's rate, what will be
skipped (audited since its bytes last changed). Pause / Stop as every MFO job. START /
progress / OUTCOME through the one sink. Finished row: "N audited · M flagged (k audio,
j video, i codec risk, h missing) · X skipped as current".

#### The checks, cheapest first, each with its own stamp

| # | Check | How | Reused from | Flag words |
|---|---|---|---|---|
| 1 | present | the file is at its path, device + inode + size as recorded | FileIdentityStamp | "not at its path" / "replaced since promotion" |
| 2 | fixity | whole-file SHA-256 equals archiveFixity | Archive ▸ Verify | "bytes changed since promotion" |
| 3 | facts | ffprobe streams match the record (duration, codecs, frame size) | Check Media | "the file's streams no longer match the catalog" |
| 4 | decodes | ffmpeg decodes video AND audio to the last frame (`-f null`), errors and early EOF counted | new; the fingerprint decoder's ProcessRunner shape | "video stops at 12:40 of 38:00" / "audio stream can't be decoded" |
| 5 | audio heard | audible seconds / duration from the fingerprint's audible map | Fingerprint Sound stamp | "no sound" / "silent after 2:10" |
| 6 | audio quality | from the same decode: clipping ratio, spectral flatness (noise), 50/60 Hz hum, DC offset, channel imbalance | the audio diagnosis + a small new analyzer | "mostly noise" / "clipped" / "hum" / "one channel dead" |
| 7 | codec risk | video/audio codec against the list of formats Apple has dropped or deprecated (Sorenson Video, Cinepak, Indeo, Animation/RLE, Graphics, QDesign, MACE, IMA4 in old containers, Apple Intermediate…) and containers that need QuickTime 7 | new table, versioned | "codec Apple no longer plays — make a preservation copy (FFV1 / ProRes)" |
| 8 | transcript sanity | audible sound but an empty or gibberish transcript (low dictionary ratio) | audioTranscript | "the transcript doesn't match the sound — re-transcribe or listen" |
| 9 | thumbnails | a preview frame exists and is not black | preview cache | "no usable preview" |

Checks 4–6 are one decode per file, shared. A file is skipped when its identity and the
checks' version match its last audit stamp.

#### The stamp

`VideoRecord.archiveAudit: ArchiveAuditStamp?` — auditedAt, checksVersion, identity, outcome
(.healthy / .flagged([Finding]) / .couldNotAudit(reason)), each Finding = check, words,
severity (needs a fix / worth a look / note). The Archive tab shows per-decade counts and a
"Flagged" list; the inspector shows the findings with their doors.

### 4. Cost

Rick's archive 10/15: 653 files / 3.2 TB. One full read at the Pegasus's rate (≈ 400–600 MB/s)
is 1.5–2.5 h; incremental after that. RAM: the decode is streamed (`-f null`), the audio
analyzer works per block; the job keeps the fingerprint job's 1.5 GB / 4-decode budget.

### 5. What it is not

- Not a repair: Repair stays the one door; the audit hands it the file and the finding.
- Not a promotion gate: Promote keeps its own vetting; the audit catches what slipped
  through and what the years do to a format.
- Not a judgement of content: a boring minute is not a finding.

### 6. Tests (five dimensions)

Logic: each check against synthetic good / bad inputs (truncated file, dead audio stream,
noise, clipped, hum, obsolete codec, gibberish transcript). Scale: 100k stamps, skip logic
O(1) per record. Media matrix: mp4/h264, mov/prores, mkv/ffv1+pcm, mxf, avi/dv, plus one
Cinepak and one Sorenson fixture. Isolation: never touches a non-archive path; a test host
audits only fixtures. Sensor: nothing in the audit writes under the archive root (the
one-writer rule), the view body does no O(records) work.

### 7. Order

After the Event Analyzer's engines (RelatedScore, EventRecommendation). The codec-risk table
and the decode-to-end check are the two pieces that do not exist anywhere yet and carry the
"clicked play, got zilch" value; build those first, then fold the reused checks in.

# Part III — Splitting `VideoScanModel` (GH #337)

*From `design/vsm_split_plan_2026_10_19.md` (plan agent, 2026-10-19), whole; archived at `docs/archive/design/`. Still waiting on Rick's §6 decisions (STATUS 2026-11-01: "VideoScanModel split #337 (plan → Rick's go)"). The "JSON gone by Friday" section is dated: the cutover landed 10/18; step G is in progress.*


Plan agent (Fable), read-only, main @ fccceeaee, 2026-10-19. Saved by the Manager. **Nothing starts before Rick's go on the §6 decisions.**

### 1. Measured scope
- `Model/VideoScanModel.swift`: 1,857 lines, **90 `@Published`**, plus 115 other stored members (caches, tasks, snapshots, test hooks).
- **134 `extension VideoScanModel` files:** MediaOps 37, Catalog 28, Archive 20, Volumes 15, Media 11, People 6, ArchiveAngel 4, others 1–2 each.
- **73 view files bind the model** (65 `@EnvironmentObject`, 8 `@ObservedObject`); 43 of them read `records` directly.
- `records` is read in 472 app files and 698 test files, and 257 test files assign it. **It stays on the model as the facade**; every other store is pulled out around it.
- The `records` didSet fans out to 9 callees (VideoScanModel.swift:18-41). The comment at :23-29 records a real data-loss mode: a stale path index lost a dossier write-back. **Index invalidation must stay synchronous.**
- Precedent: `MediaFileOperationsCenter`, `PersonFinderModel` and `DashboardState` are already separate objects injected through the environment. The app has no `@Observable` classes today.

### 2. Mechanism (behaviour-preserving)
- Each slice moves its members into a new `@Observable @MainActor final class XStore`, which the model holds as `let x = XStore()`.
- The old names stay on the model as computed forwarders. In C++ terms: a pimpl per feature with inline forwarding accessors.
- So all 134 extension files and ~1,000 test files compile unchanged, and the 73 views keep working.
- Moving each view onto its store directly is a separate, optional PR per store, done later.
- Copy the shape of the exemplar: `VideoScanCore/.../Commit/CatalogCommit.swift` (outcomes as enums, value state in structs).

### 3. Slices
| # | Slice | Files | Data-loss path | Codex | Effort |
|---|---|---|---|---|---|
| 0 | Guard rails: sensor (extension count ≤ 134, `@Published` ≤ 90, numbers only fall); measure full-suite wall time | +1 test | no | no | 0.5 night |
| 1 | PreviewService (Media/ +Thumbnail, +Filmstrip, +PreviewSweep) | 3 | no | no | 1 night |
| 2 | ScanStore (Volumes/: scanTargets, isScanning, volume caches, rename migration, scanOptions, perfSettings) | 15 (+58 readers) | **yes** (ScanMerge, DeleteScanTarget, Retire) | yes | 2 nights |
| 3 | RelocateQueue | 3 | **yes** (moves media) | yes | 1 night |
| 4 | NavigationStore (18 pending/sheet props) | 0 ext | no | no | 1 night, after Rick's folder UI settles |
| 5 | ArchiveStore (masterArchive, promote state, audit revision) | 20 | **yes** | yes | 2–3 nights |
| 6 | DuplicateJobs (correlate, analyze, delete duplicates, combine) | 11 | **yes** | yes | 2 nights; Q4 first |
| 7 | Change bus replacing the `records` didSet (a synchronous subscriber list, not AsyncStream) | model | **yes** | yes | 1 night, after 1, 2, 5 |
| 8 | RemovalStore (Cleanup, purge, junk, prune) | 14 | **yes** | yes | 2 nights; **blocked on Q4** |
| 9 | CatalogStore (the `records` owner) + People/Events/Steward | ~40 | **yes** | yes | 4+ nights, last |
| — | Activity enum (flag soup) | — | behaviour-*changing* | — | parked: needs a table of flag combinations first |

**Parallel-safe pairs:** 1 ∥ 2, 2 ∥ 3, 5 ∥ 6. **Serial:** 0 first, 7 after 1/2/5, 9 last. At most two move-slices in flight at once; the third worktree is for tests.

**Resources:**
- Claude worktree agents do every move and proof run.
- codex gets one bundled pass after 2+3, one after 5, and one after 7.
- qwen triages each night's diff and log in the morning.
- CC cloud drafts the move manifests only (it can't build the app).
- The M5 Ultra, from 10/27, takes slices 5, 6 and 9.

### 4. Estimate
- **By Fri 10/23: not the whole split.** The coherent, achievable stopping point:
  - slice 0 (Mon), slice 1 (Tue), slice 2 (Wed–Thu, codex Fri), plus slice 3 if there's room;
  - that moves ~21 of 134 extensions and ~25 of 90 properties, puts the sensors in force, and proves the pattern on one no-risk store and one data-risk store.
  - Confidence: moderate-high for 0–1, moderate for 2.
- **Whole programme (0–9, without the Activity enum and RemovalStore until Q4):** ~14–18 agent-nights. That's **3–4 calendar weeks, finishing around 11/13**, with moderate confidence. The biggest unknown is the full-suite wall time per night, which slice 0 measures.

### 5. Guard rails
- **Standing rule:** no new `extension VideoScanModel` and no new `@Published` on the model. The sensor enforces this in CI.
- **Day/night protocol:**
  - Daytime work doesn't edit the model's property declarations, and merges to main by evening.
  - Night slices start by rebasing and touch only their folder plus the model file.
  - The Catalog and MediaOps slices wait for the daytime UI burst to end.
- **Rollback:** one squash-merge per slice; revert the merge commit.

### 6. Rick's decisions (before slice 1)
1. **The forwarder approach** (callers untouched) instead of a hard cut (73 views + ~1,000 tests). Recommended.
2. **`@Observable` for the new stores**, an architecture change. macOS 26 target, mixing with ObservableObject is supported, and settings keep their explicit `save()` because of the didSet gotcha.
3. **Threading: no change.** Every store is `@MainActor`.
4. **Change bus:** synchronous inline calls, not a queue.
5. **The Activity enum** is outside this programme.
6. **Retrospective Q4 (removal lanes) and Q8 (Angel)** must be decided before slices 6 and 8.

### 7. Interaction with "JSON gone by Friday"
Added by the Manager. The JSON retirement (step G plus Import removal) touches the ~150 save-wrapper sites, and many of them are in model extensions. It runs as its own track; see `docs/archive/reviews/cutover_acceptance_audit_2026_10_19.md`. Merges are sequenced so the two tracks never touch the same files in the same night.

# Built: letting copies go

*Summaries of three built designs; the full texts are under `docs/archive/design/` with their names. The rules they established are contracts in `docs/ARCHITECTURE.md` §10.3 (removal) and §10.4 (archive); DECISIONS 2026-10-11 and 2026-10-12 record the rulings.*

- **One removal marker, one Trash engine** (GH #143, Rick's rulings 2026-10-11; `docs/archive/design/one_removal_marker_and_trash_engine.md`). Rows are never deleted: `VideoRecord.removal: RemovalMarker?` is `nil` when live, otherwise `inTrash` (since, the path macOS returned, and when the Trash was seen emptied) · `removedFromCatalog` (the file untouched, the row hidden, restore is one click) · `missing` (vanished outside the app), each with an open-string `reason`. Markers are built only through factories and written only by `VideoScanModel+RemovalMarker`; older catalogs migrate at load. `MediaTrash.move` is the only call to `FileManager.trashItem`; the test host routes it to a scratch Trash. Codex round 1 closed 2026-10-12.
- **Cleanup, from scratch (KISS)** (v2 built and merged 2026-10-12 after QA and two Codex rounds; the "copies the archive already holds" lane folded in 2026-10-15; `docs/archive/design/cleanup_kiss_2026_10_12.md`). Triage ▸ Cleanup answers one question — "Which files are extra, and can go to the Trash?" — where *extra* means an identical copy (full SHA-256 and size) stays somewhere else. One table, one button; unsure files, A/V pair halves and Avid media are never in it; a file without a stored full hash is never deleted; a fresh full read of both files proves the copy at the moment of the move.
- **PrunePlan, simplified** (designed 2026-10-21 for Rick's decision, rebuilt 2026-10-22; `docs/archive/design/pruneplan_simple_2026-10-21.md`). Rick's rule: check for duplicates and copies and offer to delete; if none, say so; if it is too hard to tell, do not prune — say "no obvious choices". In one sentence: once a file is promoted, offer its byte-identical extra copies for the Trash; for everything else say "no obvious choices" and why. It replaced ~6,260 production lines (`PrunePlan.plan` at CCN 52).
