# Cutover morning — 2026-10-18 (for Rick)

## 🔴 Go / no-go for this afternoon's flip — recommendation: GO, after your spot test on a copy
**Status (≈ 02:15):** code complete on main `25d4dc548`. Every cutover, regression and import suite green
(174 app + 148 Core tests on the last full re-prove). Codex reviewed the write side **seven times**;
findings went 12 → 7 → 5 → 2 → 2 → 2 → 1, and the last was a function-level edge case nothing in
production reaches — fixed and pinned anyway (B2.7). I stopped the loop there per our rule (core path
covered, nothing left above the data-loss line that a caller can reach). The M5 is running the full
~14,000-test suite against the final main; its result is at the bottom.

## What happened overnight (all on main, all pushed)

| Batch | What it does | Codex |
|---|---|---|
| One-job import + hold fixes | Import to SQLite runs audit → verify → import under one write hold; quit mid-import never loses an edit (recovery copy or stay open); imports stage in a folder and publish by atomic rename only after commit + verify | 3 rounds → closed |
| Store close checkpoint | a copy of catalog.sqlite alone held **no tables** (all data in the write-ahead log); close now folds the log in | found by an agent; pinned red→green |
| B1 read side | the app loads its records from SQLite (100k rows 3.6 s); copies that disagree show empty + a conflicts count | — |
| B2 → B2.7 write side | every save commits only the changed rows, synchronously on the main thread (~0.06 s for one row, ~1 s for 1,000); Trash/Undo/purge/new files/curated copies/jobs landing all covered; **Switch Catalog to SQLite…** door | 7 rounds: 12 → 7 → 5 → 2 → 2 → 2 → 1 (closed) |
| Cloud regression suite | 10 first-week scenarios written by Claude Code in the cloud, proven on the M4; it found **3 real bugs** (Undo of a committed Trash refused; copies edited in one window; purge doors dead) — all fixed | — |

## How the flip works (you click once)
1. Quit and relaunch VideoScan on the morning's build (I'll say Debug or Release).
2. **Catalog ▸ Switch Catalog to SQLite…** — it:
   - moves last night's rehearsal `catalog.sqlite` (and its 4 companion files) aside into a dated folder — never deletes,
   - re-imports from your latest catalog.json (audit → verify → import, ~1 minute, saves held),
   - freezes catalog.json and proves the import used exactly those bytes,
   - writes the switch marker, then asks you to quit.
3. Relaunch: the app is on SQLite. Catalog Status shows the store, generation, conflicts and quarantine counts.

**Rollback:** delete `catalog.sqlite` and its companions (or move them aside) → the app opens catalog.json **read-only**, with a door to resume writing it.

## Your spot test (before and after)
Before the switch, write down for ~10 rows: filename, star, your date, place, notes, people, archive stage.
After the relaunch: the same rows show the same values. Then: change a star, a note, Trash + Undo one
row, quit, relaunch — all there. Rescan one small drive — rows stay, nothing duplicated.

## Known and accepted (not blockers)
- 93 present files on the Mac's internal drive land in quarantine (the audit doesn't stamp the internal
  drive); the first rescan matches them back by hash. Fix after the cutover.
- Edits made in the last 2 s before a crash are lost (same as JSON today).
- #332: the in-app player is silent on many archived files (the FILES have sound) — after the cutover.
- Two copies of the same content edited differently within one 2 s window → a conflict (both values kept,
  field shows empty, you pick later) — your call if you want "latest wins" instead.

## Machines
RAM disk `VideoScanNight` (32 GB) is mine for the night — I eject it and restore your 16 GB XcodeRAM before
you open Xcode. M5: full suite run (Metal toolchain installed there overnight). Disk: ~188 GB free.

## Decisions waiting for you (none block the flip)
1. **Copies of the same content edited differently within 2 s** → a conflict, both values kept, field
   shows empty until you pick (my call overnight). Alternative: "latest wins" — needs an edit timestamp.
2. **Reject vs re-confirm of one person on two copies in the same 2 s** → both rows stay (Donna shows as
   both confirmed and rejected). Should that be a conflict, or the later word wins?
3. **Same-content heir keeps its own value** when a job's output and the record it replaces differ
   (the old value is saved first and kept in history, and the log names both).

## Also fixed overnight, not on the cutover path
- The Archive Angel boundary sensor: Import to SQLite now asks the Angel's public face.
- An October 6 Angel batch ("Untitled1-video-only", Christmas 2006) that you cleared last night — it
  blocked the import correctly.

## M5 full suite
(filled in when it finishes)
