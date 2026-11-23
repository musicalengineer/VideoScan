# VideoScan release notes

One entry per version, newest first. Plain words: what changed for the person using the app,
then what changed underneath. A version is bumped when it ships to Rick's daily build.
(5.4 and 5.5 got no entry; `git log` holds them.)

## 5.6 — the testbed release (since the 5.5 bump, 2026-11-15)

**Catalog view**
- Show menu down to five ticks: Audio Only, Videos Missing Sound, Not Yet Archived, Needs a
  Date, Hide Other Versions (nothing ticked = everything). Show ▸ Videos with Sound is back.
  Every filter change is logged.
- One Show ▸ Folders switch in place of the three folder modes: your folders, then the
  machine's grey estimates, then loose files, in one list.
- The Showing box ends with the count: "… · 1,247 of 18,903".
- Not Yet Archived and Has Master Copy no longer go stale after Analyze Duplicates (#481).
- The thumbnail cache is sized from RAM (25 %, 8–32 GB) instead of a fixed 8 GB.

**Repair, sound and archive safety: verify first, then act**
- Transcode with Replace swaps in the new file only after it is verified (#500, P0).
- Preservation proves the master lossless BEFORE the replace; nothing is published, replaced
  or counted unverified (#501, #502, #506).
- A full-file hash is trusted only when the whole file was read (#504).
- Raw DV: Repair's combined rebuild works (#484); Balance and Rebuild Audio no longer write
  sound the copy stores but does not play (#482).
- New balanced-copy proof: it compares what plays (every frame, the kept sound) and runs after
  Prepare, report only.
- Promote sheet: mono is not a problem; one-sided sound goes through Prepare; the sound line
  follows the gate.

**Observations and Hallie**
- A newly indexed video is searchable without reopening the window; a refused Index Frames
  says why.
- Hallie cloud: a reply cut off at the token limit is not an answer; empty replies are fixed;
  the testbed compares several brains side by side.

**Underneath (refactoring)**
- External commands (ffmpeg and friends) go through one mockable `CommandExecutor` seam. The ten
  hand-rolled `Process()` sites moved onto it, and a sensor forbids new ones.
- Log capture is task-local (`LogScope`/`LogCapture`), and tests can state expectations on the
  log (`.once`, `.never`, `.inOrder`).
- Four process-global test hooks became task-local; there are fault seams for hash reads and
  atomic publish.

**Testbed**
- Tests never open the real catalog or real logs: each test host runs in a sealed home with a
  COPY of App Support.
- Tests free the disk they take, and can never trash real data.
- Faster: everything runs in parallel (app hosts, Core, Python, corpus). Ultra nightly went
  from 70 to 27 min; M4 full testbed from ~2 h 10 to 1 h 23.
- `scripts/run_tests.sh` runs on any fleet Mac, with `--config debug|release` and `--coverage`
  (HTML).
- The M4 real-data corpus has 6,351 files (~1.95 TB) on two roots.
- Fixed: a 117 GB leak of Swift module caches from the gauntlet.

**Known, not in 5.6**
- The app still logs "Volume mounted" for the testbed's disk images (fix is next).
- Two Archive Angel timestamp tests flake under heavy load (#509).

## Unreleased — 5.3 (the SQLite cutover)

**For the catalog**
- Retired (10/20, the cutover is done): Catalog ▸ Import to SQLite (Dry Run)…, Import to
  SQLite… and Switch Catalog to SQLite…, and the per-drive right-click Verify Catalog
  (Validate Catalog… is the one verb). Reopen SQLite Catalog, Adopt, Split Duplicate Groups
  by Full Hash (the door Verify's mixed-digest finding names), Rescan and Update Catalog… are
  unchanged.
- Catalog ▸ Validate Catalog… — ONE verb (10/20) in place of Audit Catalog… and Verify
  Catalog…: every file on disk first, then, only after a complete file check, the catalog
  against itself, as one Media File Operations row. A stopped or failed file check never
  runs the catalog check, and the row says so. The nightly's `--audit-catalog` (and the new
  `--validate-catalog`) run the same job. Underneath: `--audit-catalog` now also runs the
  catalog check, so it takes a little longer, its last stdout line is the Validate row's
  summary ("Validated — files: … · catalog: …"), and its exit code covers both steps (0 only
  when both completed). No in-repo or LaunchAgent caller depended on the old line (checked
  10/20).
- Catalog Status band, new meaning (10/20): green = the catalog reflects reality (integrity
  holds, the last Validate completed within 7 days, presence matches the disk — a file marked
  Missing that is missing is fine); yellow = it can't fully vouch (Validate overdue or never
  run, a large share not checked, unsettled rows); red = it is lying or the check broke.
  Under the band, "N to review" — Audio Tracks, But No Sound; sound prints to hear again;
  possible same footage; possible reference movies; missing with no other copy / another copy
  present — never changes the colour. Lineage links to removed rows are said as history.
- The catalog moves from one JSON file to a SQLite database (GRDB, behind a plugin seam).
  Every save is one transaction; the database refuses invalid writes itself; a restored older
  copy opens read-only until a person adopts it. The JSON catalog stays on disk, frozen
  read-only, as the reference.
- Catalog ▸ Import to SQLite (Dry Run)… and Import to SQLite… — one job that holds every save
  while it runs Audit Catalog, Verify Catalog and the import, then compares every row against
  the file again before it commits. Rows it cannot prove go to a quarantine table with their
  words; nothing is dropped.
- Catalog ▸ Switch Catalog to SQLite… — moves the rehearsal database aside (never deletes
  it), imports catalog.json once more, and only when that import finishes marks catalog.sqlite
  as the catalog. From the next launch every save commits the rows that changed into
  catalog.sqlite (2 s after the last edit, and at quit); a row the database cannot take yet is
  named in the log and kept in memory; if the database refuses, saving stops with its words
  until Catalog ▸ Reopen SQLite Catalog. The Master Archive designation moves into the database.
- Verify Catalog: the first real report (10/17) was mostly the tools' own errors — fixed:
  Fill In Full Hashes now hashes archived rows; the sound print never says "no audio" for a
  decode failure; QuickTime reference movies are flagged, not called broken; duplicate
  candidate groups are not called byte copies; files still being written are not catalogued.
- Catalog Status names its red rows instead of counting them.

**Catalog view**
- Show ▸ Events & Copies as Folders now looks like the Finder: event folders at the top
  level, double-click to open, Back / ⌘↑ to return; loose files sit beside the folders.

**About**
- Refreshed the About box lines.

## 5.2

- Integrity first (10/16): Audit Catalog tier 0, Verify Catalog slice 1, the P0 truth
  regression suite, Catalog Status chip and band, Footage folders (glyph view).
