# VideoScan release notes

One entry per version, newest first. Plain words: what changed for the person using the app,
then what changed underneath. A version is bumped when it ships to Rick's daily build.

## Unreleased — 5.3 (the SQLite cutover)

**For the catalog**
- The catalog moves from one JSON file to a SQLite database (GRDB, behind a plugin seam).
  Every save is one transaction; the database refuses invalid writes itself; a restored older
  copy opens read-only until a person adopts it. The JSON catalog stays on disk, frozen
  read-only, as the reference.
- Catalog ▸ Import to SQLite (Dry Run)… and Import to SQLite… — one job that holds every save
  while it runs Audit Catalog, Verify Catalog and the import, then compares every row against
  the file again before it commits. Rows it cannot prove go to a quarantine table with their
  words; nothing is dropped.
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
