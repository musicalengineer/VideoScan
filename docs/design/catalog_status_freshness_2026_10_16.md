# Catalog Status — freshness of what the catalog knows (Rick, 2026-10-16)

## 1. In Rick's words

> "On the catalog fingerprint and SHA hashes and really all catalog integrity + metadata,
> the catalog menu has no way to see what state (is it stale, when was it updated) these
> catalog items are in. … show date/time of each stat listed and yellow for old or green
> for recent, then a button to refresh whatever is out of date. … put the summary regarding
> freshness near the top so we know ahead of time if the catalog needs attention. … if I
> don't go to the content analysis window, I won't know."

What bit him the same morning: two byte-identical copies of `Christmas-c1990s.flv` carry
only a sampled (`v1:`) hash, so Compare Media could not use its byte-for-byte rung, called
them "two transfers", tied, and said "promote the longer one". Nothing anywhere said
"660 rows still have no full hash".

## 2. Ruling

- **One surface, grown — the Analyze panel** (⇧⌘O, "What the catalog keeps current…"),
  not a second window. A new Catalog menu item **Catalog Status…** opens the same panel.
- **A summary band at the top** of the panel: one colour, one sentence, the items behind
  it. "Catalog is current" · "2 things need a run: Full Hashes (660 files), Sound Prints
  (12)" · "Needs attention: 3 rows point at nothing under Projects/_staging…".
- **Three integrity rows join the registry**: File Presence (Audit Catalog tier 0),
  Full Hashes (SHA-256), Sound Prints (audio fingerprints). Each row's Run now starts the
  job that already exists (or the new tier-0 job). They are cyclers by Rick's own
  definition (2026-10-02): no "done", only "current".
- **Every row gets a freshness column**: last completed pass (date/time) + colour.
- **"Update everything stale"** at the top queues the yellow rows through the existing
  scheduler, integrity rows first.

### 2.1 Landing from the chip: what needs fixing, the buttons, and where progress lives (Rick, 10/16)

Clicking the chip opens Content Analysis with the band at the top. Each band item carries
ONE button: yellow → **Run now**; red → the door a person needs (**Fix Links…**,
**Fingerprint again**, …). **Update everything stale** queues every yellow item through the
scheduler, integrity rows first.

**Progress lives in MFO; the band mirrors it.** One job, one state, two views:
- The three integrity kinds (File Presence, Full Hashes, Sound Prints) read files for
  minutes to hours with per-file outcomes and must survive overnight → they are MFO jobs
  (they already are: chips SOUND PRINT, the hash backfill, now AUDIT). The MFO row is the
  source of truth for START, progress, the per-item detail and OUTCOME.
- Once a run starts, the band item becomes a mirror of the MFO row's collapsed line (what
  it is doing · N of M · time left · progress bar · the same Pause / Stop), read from the
  same job state the MFO window reads — never a second progress implementation. "See
  details" opens the MFO window at that row.
- The metadata cyclers (duplicates, footage, captions, OCR, transcripts, A/V pairs,
  signatures, dates) keep the Analyze-only progress of the 10/2 ruling; they are not MFO
  rows.

Rule of thumb: reads files for more than a minute with per-file outcomes → MFO holds the
job and the band mirrors its line; otherwise the band is the only progress.

## 3. Colours — and yes, red

The colour answers one question: *do I need to look, or just click?*

| Colour | Meaning | Example |
|---|---|---|
| green | current | every eligible row stamped; last pass within its cadence |
| yellow | **a run fixes it** — the button is the answer | 660 rows without a full hash; presence not checked for 3 days; never run |
| red | **a person has to look** — Update alone cannot fix it | presence found rows pointing at nothing on a mounted drive (→ Fix Links); the last pass failed or was killed; a sidecar that cannot be opened |
| grey | not asked | everything eligible is on drives that are not mounted |

"Way out of date" stays yellow: the button fixes it. Red is reserved for *known bad* or
*needs a decision*. Red > yellow > green; grey only when nothing else applies.

Cadences (yellow when older): presence 1 day (it runs nightly); hashes / sound prints —
no clock, stale whenever an eligible reachable row lacks a stamp (a scan adding files is
what makes them stale); the metadata cyclers keep their existing "current" notion.

## 4. "If I don't go to the window, I won't know" — the attention signal

All three derive from ONE equality-gated snapshot (the existing `AnalyzeCoverageSnapshot`
pattern — published once per debounced catalog change, never per record):

1. **A status chip on the Catalog tab's totals strip** (Rick's option 1, 2026-10-16, from his
   screenshot): far left of "TOTAL CATALOG 7.5 TB", in line with UNIQUE and ARCHIVED — the
   catalog's vital signs, and "is it current" is the fourth. A coloured dot + a short
   sentence: green "Catalog current · checked 02:14" in quiet secondary text (calm by
   default); yellow "2 things need a run"; red "Needs attention: 3 rows point at nothing".
   Click → opens Content Analysis (the Analyze panel) with the band at the top, so the fact
   and the door agree. The **Content Analysis toolbar button carries the same dot** when not
   green. (Rejected: a fifth button in the upper-right toolbar — it would fight the yellow
   Backup Catalog highlight for attention.)
2. **The Analyze menu's first row IS the summary sentence** ("Needs attention: 1 thing"),
   above the per-cycler rows; the Catalog ▸ Catalog Status… item carries the colour word
   in its title when not green.
3. **At launch and after the nightly**, a red summary is one console/log line (the same
   way the unfinished full-hash run announces itself today). A macOS notification is a
   later option, not in this cut.

## 5. Build order

1. **Audit Catalog tier 0** (docs/design/audit_archive_2026_10_15.md §2a) — safety-critical
   protocol; the prerequisite for the File Presence row. See §6.
2. **Freshness model** — pure VideoScanCore: rows in → colour + words + summary out.
3. Registry rows (presence, hashes, sound prints) + freshness column + summary band +
   dot + menu row + Catalog Status… item + Update everything stale.
4. Nightly: the audit runs before the metrics publish (launch argument, like `--find-tag`).

## 6. Audit Catalog tier 0 — safety-critical cut

**One sentence:** check that every catalog row on a connected drive still points at its
file, and mark the ones that are gone as Missing.

**Cut:** Fix Links (§2b, its own review sheet, later); identity stamps the record does not
carry (no inode on `VideoRecord` today — "changed" means size differs); any marking of
"changed" rows (reported and counted, never marked — that is a decision); per-record
stamps (one small `catalog-audit.json` beside catalog.json records the last run, like
`fullhash-backfill.json`); anything on media (the job only stats).

**One writer:** a gone file is marked through `VideoScanModel.stampRemoval` with
`RemovalMarker.missing(noticedAt:lastSeen:reason:)` and a reason that names the audit; a
`.missing` row whose file is back at its path goes live through `clearRemoval` (validates
first). Saves are batched and acknowledged.

**Outcomes per row:** present · changed (size differs; reported, not marked) · gone →
marked Missing · came back → restored · not asked (drive not mounted) · could not check
(any stat error but "no such file": permission, I/O — never marked) · skipped (already
removed / in the Trash).
**Outcomes per run:** completed · stopped (partial: marks so far are saved; the summary
says partial) · refused (read-only catalog; test-host shared catalog) · failed (save not
acknowledged → the unsaved marks are undone, compare-and-set, as the fingerprint job does).

**Invariants codex attacks:** (1) never marks a row whose volume root is not mounted;
(2) never marks on any error but ENOENT/ENOTDIR; (3) every mark goes through
`stampRemoval` and lands only after an acknowledged save; (4) a result is applied only to
the row it was asked about (same id, same path) — a row rescanned or edited while the stats
ran is left alone; (5) nothing opens a media file for writing, nothing touches the archive;
(6) a stopped or crashed run leaves no half-marked state.
