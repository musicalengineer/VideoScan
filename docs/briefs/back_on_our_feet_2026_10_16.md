# Getting back on our feet — the plan as of 2026-10-16, 21:15 (for Rick, after dinner)

## Tonight's results (21:15)

- **First real Audit Catalog run (your Release build, ~3 s):** 10,831 rows present and stamped with where
  they were seen · 144 never seen by an audit (audio-project backups, a Chrome cache, Immich, photo sets,
  NH_Christmas.mov — nothing under Breen_Family_Archive/30_Video) · 216 still missing · 2 could not be
  checked (the two symlink rows) · **marked 0**, as designed. "Update everything stale": hashes 0 of 114
  (all 114 are gone rows; 10,236 rows hashed; 628 archived rows carry fixity); sound prints 45 new ·
  142 missing · 26 failed · 6 never hashed.
- **Verify Catalog, slice 1, is on main** (`Catalog ▸ Verify Catalog…`, an MFO job, read-only): tier 5
  constraints (11 rules + the stale-stamp rule), the catalog file's own SHA-256 + generation, the dated
  report beside catalog.json, the Integrity row in Catalog Status; 40 tests. Codex found 6 (3 P1): a
  pause between tiers can let the findings and the file hash describe different generations; a
  completed run can mask a tier that could not check; tier 3 counts stale sound stamps; three P2. **All
  six closed red-first** (10 new tests; 65 green in 10 suites), merged and pushed; three new tier-5 rules
  (path alias by case, supersession cycle, dup-group digests agree); report schema 2. Closure in
  `docs/reviews/codex/codex-review-verify-catalog-slice-1-2026-10-16.md`.
- **The P0 truth-regression suite is on main** (written in the cloud, proven on the M4): the poisoned
  fixture catalog + 13 regression tests (9 falls + 4 source sensors). Green 18 tests; red at the three
  pre-fix commits (22 / 27 / 37 issues) and under a folder mutant (exactly the 2 mutant assertions).
  Run sheet: `docs/reviews/p0-regression-2026-10-17.md`. It sits in the `regression` stage of the
  gauntlet manifest, **blocked** pending the isolation audit (temp dirs + ffmpeg fixtures) — decision 6.
- **Main is pushed** through all of tonight's merges (Verify Catalog slice 1 + its codex closure, the P0 suite).

## Where we stood at 21:00

- **Nothing was lost.** Every file you thought was gone is where the ledger says: the Christmas 1990
  master is on FamilyArchive with its SHA-256 fixity; the m4v has its MP3 sound. What failed was
  five doors stating facts they had not checked. GH #327 (P0) names them; all five are fixed on
  main, each shown red first, 63 tests green, codex reading the fix now.
- **The audit is cleared** (Audit Catalog tier 0, six codex rounds in one day, the last with zero
  findings). First real run stamps every present row and lists the ~135 gone rows for a decision;
  it marks nothing until a second run. Not yet run on your catalog.
- **Catalog Status** (chip, band, three integrity rows) and the **Footage folders** view are on
  main behind Show ▸ Events & Copies as Folders; the folder view's codex findings (a hidden
  selection reaching ⌘⌫) are fixed and merged.
- **Rulings recorded:** integrity first (`docs/design/integrity_first_2026_10_16.md`), P0 = any
  unverified fact (GH #327), outgrew JSON → verify, then SQLite (GH #328).

## The plan, in order (integrity only until the trust gate)

1. **Tonight / tomorrow morning — the P0 regression suite.** Paste
   `docs/briefs/cloud/P0_REGRESSION_SUITE.md` into Claude Code in the cloud (credits expire 11/05).
   It builds the poisoned fixture catalog with tonight's six shapes and one named test per fall,
   each shown red against the commit before its fix. The rule from now: a P0 fix is not closed
   without its row in the fixture and its line in that suite.
2. **This week — Verify Catalog, tiers 0–6** (`integrity_first` §3): nightly cheap, weekly deep,
   on demand; the report with per-tier "verified at"; the chip reads it. Pieces exist: tier 0
   (built), fixity (archive), Verify Media, sound prints, Check Totals. New: the constraints pass,
   the catalog-file hash, per-writer reconciliation lines, the restore test, the truth sweep.
3. **Hashes to 100 %** (660 rows still sampled-only) and the sensor that a sampled hash is never a
   verdict.
4. **The surface audit** — every fact-bearing surface rewritten to the FileFact contract, one per
   commit, codex on each: journey (done), ladder (done), player (done), Archive doors (done),
   Compare Media band, folder relation words, Catalog columns, inspector, Catalog Status rows.
5. **Trust gate**: seven clean nights · tier 1 at 100 % · one weekly archive pass · surfaces pinned
   · your spot test says "true".
6. **Then the SQLite port**, plan v2 (`docs/design/catalog_sqlite_migration_2026_10_16.md` §9):
   contract freeze (can start now, read-only) → the seam + dirty tracking → shadow dual-write with
   an independent drift comparator → certifying sidecars in → sealed-generation sync → ONE cutover
   → constraints become the engine's. Codex reviewed it tonight (14 findings, all folded in).

## Decisions I need from you tomorrow

1. ~~Start the first real Audit Catalog run~~ — done tonight (numbers above). The 144 never-seen and
   216 missing rows wait for Fix Links; nothing was marked.
2. ~~Paste the regression brief to the cloud~~ — done; I launch cloud routines directly now.
3. Plan v2 §9a: one cutover instead of two, and certifying sidecars moved before cutover — agree?
4. The contract freeze (step B) overlapping integrity work now, read-only — agree?
5. Credits: each integrity step is one bounded brief; codex on every batch; say if you want a
   different spend shape.
6. Unblock the P0 suite in the nightly gauntlet once its isolation audit is done (it writes only under
   a temp dir and reads the ffmpeg fixtures) — or run it blocked-but-reported first for a few nights?
7. Rebuild (Debug or Release) and run `Catalog ▸ Verify Catalog…` once — the first real integrity report.

## One local thing before you commit your project file
Your uncommitted `project.pbxproj` (Xcode 27's upgrade check) flips the TEST target's Release
`SWIFT_COMPILATION_MODE` from `singlefile` to `wholemodule`: it fails
`tests/test_nightly_build_speed_settings.py` locally (the only local Python red) and would slow every
nightly Release test compile. Keep `singlefile` on the test target; the 5.1 → 5.2 bump is fine.

## Open issues from today
#323 headless audit vs GUI launch · #324 sibling proof's link blind spot · #325 ladder "different
events" from no evidence · #326 scanner catalogues through symlinks · #327 P0 unverified facts ·
#328 P0 JSON → SQLite · #329 Events membership lost on merge.
