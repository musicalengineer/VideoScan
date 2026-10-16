# Getting back on our feet — the plan as of 2026-10-16, 21:00 (for Rick, after dinner)

## Where we stand tonight

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

1. Start the first real Audit Catalog run (it marks nothing; it stamps and lists)? Yes/no.
2. Paste the regression brief to the cloud, or run it locally on the ~$90? (Cloud recommended.)
3. Plan v2 §9a: one cutover instead of two, and certifying sidecars moved before cutover — agree?
4. The contract freeze (step B) overlapping integrity work now, read-only — agree?
5. Credits: each integrity step is one bounded brief; codex on every batch; say if you want a
   different spend shape.

## Open issues from today
#323 headless audit vs GUI launch · #324 sibling proof's link blind spot · #325 ladder "different
events" from no evidence · #326 scanner catalogues through symlinks · #327 P0 unverified facts ·
#328 P0 JSON → SQLite.
